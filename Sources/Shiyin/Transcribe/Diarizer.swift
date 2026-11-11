import FluidAudio
import Foundation

/// 说话者识别（design §6.3）：FluidAudio 的离线识别（pyannote + VBx，在 ANE 上跑）
@MainActor
enum Diarizer {
    struct Turn: Equatable {
        var speaker: Int      // 1 开始，依第一次出现的顺序编号
        var start: Double
        var end: Double
    }

    /// 说话者识别的结果：每段谁在讲，加上每位说话者的声纹（256 维）和说话的总秒数（design §21.4）
    struct Output {
        var turns: [Turn]
        var voiceprints: [Int: [Float]]
        var speechSeconds: [Int: Double]
        /// 分得准不准的线索（design §24.3）
        var quality: Quality? = nil
        #if DEBUG
        /// 评估用（shiyinctl voiceprint-eval 的 dump）：每个片段里每位说话者的声纹
        var chunks: [ChunkEmbedding] = []
        #endif
    }

    /// 分得准不准的自我检查（design §24.5）。
    /// 碰撞率：一个片段里模型听到两个以上的人时，不同的人被分到同一群的比例。分群时同一片段的人会被强制分开，
    /// 所以只有分出 1 群时才会碰撞。凝聚度：每个片段的声纹跟它那一群平均声纹的相似度（依片段数平均），
    /// 不同的人被并在同一群时会变低
    struct Quality: Equatable {
        var collisionRate: Double
        var multiSpeakerChunks: Int
        var cohesion: Double
        var clusters: Int
        var chunks: Int

        /// 超过这个分数就提示「说话者可能分得不够」：凝聚度低于 0.6（评估时一般会议最低 0.71，麻将录音 0.48）
        static let hintThreshold = 0.4

        /// 越大越可能把不同的人并在一起：只分出 1 群、但至少 10 个片段听得出两个人时是 1；其他看凝聚度。
        /// 片段太少（不到 30 个，大约 1 分钟的说话）时不判断
        var mergeRisk: Double {
            guard chunks >= 30 else { return 0 }
            if clusters <= 1 && multiSpeakerChunks >= 10 && collisionRate >= 0.5 { return 1 }
            return max(0, 1 - cohesion)
        }
    }

    static var modelsDirectory: URL { Paths.modelsDir.appendingPathComponent("fluidaudio", isDirectory: true) }

    private static var manager: OfflineDiarizerManager?

    static var isInstalled: Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        return !items.isEmpty
    }

    /// 拾音用的设置（design §6.3.2、R34、D92）：
    /// - 每个片段的声纹也拿回来，用来算分得准不准（design §24.3），不影响分群的结果
    /// - 一个人在一个窗口里说 0.3 秒以上就算声纹（默认 1 秒），没人认领的片段重新算声纹、判给最像的人：
    ///   很短的一句不会因为没有声纹，被并进旁边那个人（AMI 2 秒内的句子标对 24% → 52%）
    static func config(clustering: OfflineDiarizerConfig.Clustering = .community) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig(clustering: clustering, exposeChunkEmbeddings: true)
        #if DEBUG
        // -debugDiarizerLegacy YES：改之前的设置（FluidAudio 的默认），用同一段录音比较
        if UserDefaults.standard.bool(forKey: "debugDiarizerLegacy") { return config }
        #endif
        config.embedding.minSegmentDurationSeconds = 0.3
        config.zeroVoteReembed = .init(enabled: true, minDurationSeconds: 0.4)
        return config
    }

    /// 模型不在就下载并编译（第一次约数十 MB）
    static func prepare() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let manager = OfflineDiarizerManager(config: config())
        try await manager.prepareModels(directory: modelsDirectory)
        // 短句再确认的声纹模型（R34）一起准备好；下载不了不挡说话者识别
        _ = try? await SpeakerRecheck.prepare()
        self.manager = manager
        return manager
    }

    /// minSpeakers：至少分出几个人（design §23.2），nil 自动判断；clustering：评估时换分群的设置（门槛、人数）
    /// config：评估时整份换掉（DEBUG 的 voiceprint-eval，短句的实验 design §6.3.2）
    static func diarize(samples: [Float], minSpeakers: Int? = nil, clustering: OfflineDiarizerConfig.Clustering? = nil,
                        config: OfflineDiarizerConfig? = nil,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        var clustering = clustering
        if clustering == nil, let minSpeakers {
            clustering = .community
            clustering?.minSpeakers = minSpeakers
        }
        let manager: OfflineDiarizerManager
        if let config {
            manager = OfflineDiarizerManager(config: config)
            try await manager.prepareModels(directory: modelsDirectory)
        } else if let clustering {
            manager = OfflineDiarizerManager(config: Self.config(clustering: clustering))
            try await manager.prepareModels(directory: modelsDirectory)
        } else {
            manager = try await prepare()
        }
        let result = try await manager.process(audio: samples) { done, total in
            if total > 0 { onProgress(Double(done) / Double(total)) }
        }
        var numbering: [String: Int] = [:]
        let turns = result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { segment in
                let number = numbering[segment.speakerId] ?? {
                    let next = numbering.count + 1
                    numbering[segment.speakerId] = next
                    return next
                }()
                return Turn(speaker: number, start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds))
            }
        // 声纹：离线识别的 speakerDatabase（每位说话者一个），跟着上面的编号
        var voiceprints: [Int: [Float]] = [:]
        for (id, embedding) in result.speakerDatabase ?? [:] {
            if let number = numbering[id], !embedding.isEmpty { voiceprints[number] = embedding }
        }
        var seconds: [Int: Double] = [:]
        for turn in turns { seconds[turn.speaker, default: 0] += max(0, turn.end - turn.start) }
        var output = Output(turns: turns, voiceprints: voiceprints, speechSeconds: seconds, quality: result.chunkEmbeddings.map(quality))
        #if DEBUG
        output.chunks = result.chunkEmbeddings ?? []
        #endif
        return output
    }

    nonisolated static func quality(_ chunks: [ChunkEmbedding]) -> Quality {
        var multi = 0, collided = 0
        for (_, items) in Dictionary(grouping: chunks, by: \.chunkIndex) {
            let locals = Set(items.map(\.speakerIndex))
            guard locals.count >= 2 else { continue }
            multi += 1
            if Set(items.map(\.speakerId)).count < locals.count { collided += 1 }
        }
        func normalized(_ v: [Float]) -> [Float] {
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? v.map { $0 / norm } : v
        }
        var total = 0.0, count = 0
        let groups = Dictionary(grouping: chunks, by: \.speakerId)
        for (_, items) in groups {
            let vectors = items.map { normalized($0.embedding256) }
            guard let width = vectors.first?.count else { continue }
            var sum = [Float](repeating: 0, count: width)
            for v in vectors { for i in 0..<width { sum[i] += v[i] } }
            let centroid = normalized(sum)
            for v in vectors { total += Double(zip(v, centroid).reduce(0) { $0 + $1.0 * $1.1 }); count += 1 }
        }
        return Quality(collisionRate: multi > 0 ? Double(collided) / Double(multi) : 0, multiSpeakerChunks: multi,
                       cohesion: count > 0 ? total / Double(count) : 1, clusters: groups.count, chunks: chunks.count)
    }

    /// 每段逐字稿标上跟它重叠最多的说话者；完全没重叠就用时间最接近的。
    /// 最后依逐字稿里出现的顺序重新编号，没分到任何段落的说话者就不会留下空的编号
    nonisolated static func assign(_ turns: [Turn], to segments: [TranscribedSegment]) -> [Int?] {
        assignNumbering(turns, to: segments).speakers
    }

    /// 同 assign，另外回传说话者识别的编号 → 逐字稿上的编号（声纹跟着换编号，design §21.4）
    nonisolated static func assignNumbering(_ turns: [Turn], to segments: [TranscribedSegment]) -> (speakers: [Int?], numbering: [Int: Int]) {
        guard !turns.isEmpty else { return (segments.map { _ in nil }, [:]) }
        let raw: [Int?] = segments.map { segment in
            var overlap: [Int: Double] = [:]
            for turn in turns where turn.end > segment.start && turn.start < segment.end {
                overlap[turn.speaker, default: 0] += min(turn.end, segment.end) - max(turn.start, segment.start)
            }
            if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
            let middle = (segment.start + segment.end) / 2
            return turns.min(by: { abs(($0.start + $0.end) / 2 - middle) < abs(($1.start + $1.end) / 2 - middle) })?.speaker
        }
        var numbering: [Int: Int] = [:]
        let speakers: [Int?] = raw.map { speaker in
            guard let speaker else { return nil }
            if let number = numbering[speaker] { return number }
            numbering[speaker] = numbering.count + 1
            return numbering.count
        }
        return (speakers, numbering)
    }
}
