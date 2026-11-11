import CryptoKit
import Foundation

/// 转录交给企业服务器时，画面上进度后面的说明（排队第几、为什么在等）；有值就显示「改在这台电脑转录」（R50.3、R50.5）
struct ServerNote: Equatable {
    var text: String
    /// 在等服务器（连不上、登录失效）：不显示百分比
    var waiting = false
}

/// 用企业服务器转录（design §36.3、R50）：写成 16-bit WAV → 建工作 → 分块上传（可以接着传）→ 等结果 → 删掉服务器上的工作。
/// 说话者识别、声纹在 Mac 本机做（D122），这里只拿逐字稿的段落。
/// 连不上、服务器忙、登录失效时不算失败：一直等、自动再试（R50.5、R49.4），用户可以按「改在这台电脑转录」
@MainActor
struct ServerTranscriber {
    struct Remote {
        var segments: [TranscribedSegment]
        var seams: [Double]
        /// 服务器用的引擎：breeze、qwen、japanese（写进 transcribed_with）
        var engine: String
    }

    /// 用户按了「改在这台电脑转录」
    struct SwitchToLocal: Error {}

    /// 服务器转录失败（例如录音太长）：不是暂时的问题，工作算失败
    struct Failed: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    var options: TranscriptionOptions
    var stage: (String) -> Void
    /// 0～1：上传 0～0.1、服务器转录 0.1～0.9（之后的 0.9～1 是本机的说话者识别）
    var progress: @Sendable (Double) -> Void
    var shouldContinue: () -> Bool
    var switchToLocal: () -> Bool
    /// 服务器的状态（nil：服务器的部分做完了）
    var onServer: (ServerNote?) -> Void
    /// 服务器的工作 id 换了（创建、完成、重建）：JobRunner 记进工作的 payload，app 重开时接着做
    var onRemoteId: (String?) -> Void

    static let chunkSize = 8 * 1024 * 1024
    /// 服务器给的时间的上限（design §36.2）：一天的录音再多一成（24 × 3600 × 1.1 秒）。超过的段落、接缝不收（太大的值换成 Int 会当掉）
    nonisolated static let maxSeconds: Double = 95_040
    private var server: EnterpriseServer { .shared }

    // MARK: WAV

    /// 16 kHz、16-bit、单声道的 WAV（服务器只收这种，D120）；边换算边写，不在内存多留一份
    nonisolated static func writeWAV(_ samples: [Float], to url: URL) throws -> (bytes: Int64, sha256: String) {
        let dataBytes = samples.count * 2
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes)); header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        try handle.write(contentsOf: header)
        hasher.update(data: header)
        let block = 160_000
        var index = 0
        while index < samples.count {
            let end = min(index + block, samples.count)
            var chunk = Data(count: (end - index) * 2)
            chunk.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in index..<end {
                    let v = max(-1, min(1, samples[i])) * 32767
                    out[i - index] = Int16(v.rounded()).littleEndian
                }
            }
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            index = end
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (Int64(header.count + dataBytes), digest)
    }

    // MARK: 流程

    /// 回传 nil 表示被取消（服务器上的工作也删掉）
    func transcribe(wav: URL, bytes: Int64, sha256: String, remoteId: String?) async throws -> Remote? {
        var id = remoteId
        var waited = 0
        var rejectedUploads = 0
        onServer(ServerNote(text: ""))
        defer { onServer(nil) }
        while true {
            guard shouldContinue() else { await delete(id); return nil }
            if switchToLocal() { await delete(id); onRemoteId(nil); throw SwitchToLocal() }
            do {
                if id == nil {
                    id = try await create(bytes: bytes, sha256: sha256)
                    onRemoteId(id)
                }
                let state = try await status(id!)
                if waited > 0 { onServer(ServerNote(text: "")); waited = 0 }
                switch state.status {
                case "uploading":
                    if try await upload(id!, wav: wav, bytes: bytes) == false {
                        // 服务器说收到的文件不对，从头再传；连续两次就放弃
                        rejectedUploads += 1
                        if rejectedUploads > 2 { throw Failed(message: String(localized: "录音一直没办法完整传到企业服务器")) }
                    }
                case "queued", "running":
                    report(state)
                    try await Task.sleep(for: .seconds(state.status == "running" ? 2 : 5))
                case "done":
                    progress(0.9)
                    let remote = try await result(id!)
                    await delete(id)
                    onRemoteId(nil)
                    return remote
                case "failed":
                    await delete(id)
                    onRemoteId(nil)
                    if state.errorKind == "empty" { throw WhisperError.empty }
                    throw Failed(message: state.errorMessage ?? String(localized: "企业服务器转录失败"))
                default:
                    // 取消、过期（服务器清掉了）：重新建一个工作，从头上传
                    id = nil
                    onRemoteId(nil)
                }
            } catch let failure as EnterpriseServer.Failure where failure.isTemporary || failure.isSetupProblem {
                if case .server(let kind, _) = failure, kind == "not_found" {
                    id = nil
                    onRemoteId(nil)
                    continue
                }
                waited += 1
                try await waitForServer(failure, attempt: waited)
            } catch let failure as EnterpriseServer.Failure {
                if case .server(let kind, _) = failure, kind == "not_found" {
                    id = nil
                    onRemoteId(nil)
                    continue
                }
                await delete(id)
                onRemoteId(nil)
                throw Failed(message: failure.errorDescription ?? "")
            }
        }
    }

    /// 等服务器（R50.5）：30 秒、1 分钟、2 分钟…最长 5 分钟再试；登录失效时等用户重新登录（每 5 秒看一次）
    private func waitForServer(_ failure: EnterpriseServer.Failure, attempt: Int) async throws {
        let setup = failure.isSetupProblem
        let seconds = setup ? 5 : min(300, 30 * (1 << min(attempt - 1, 4)))
        let text: String
        if setup { text = failure.errorDescription ?? "" }
        else if case .server(let kind, _) = failure { text = kind == "busy" ? String(localized: "等企业服务器：服务器忙，\(seconds) 秒后再试")
                                                                            : String(localized: "等企业服务器：服务器出错，\(seconds) 秒后再试") }
        else { text = String(localized: "等企业服务器：连不上，\(seconds) 秒后再试") }
        onServer(ServerNote(text: text, waiting: true))
        stage(String(localized: "等企业服务器"))
        log.info("waiting for enterprise server: \(failure.isSetupProblem ? "login" : "unreachable", privacy: .public)")
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            guard shouldContinue() else { return }
            if switchToLocal() { return }
            // 重新登录了就马上再试
            if setup && server.isSignedIn { return }
        }
    }

    /// 阶段的文字会接「中 N%」（「企业服务器转录中 42%」），排队第几放在后面的说明
    private func report(_ state: JobState) {
        if state.status == "queued" {
            stage(String(localized: "企业服务器排队"))
            if state.stage == "waiting_models" { onServer(ServerNote(text: String(localized: "服务器正在准备模型"))) }
            else if let ahead = state.queueAhead, ahead > 0 { onServer(ServerNote(text: String(localized: "前面还有 \(ahead) 场"))) }
            else { onServer(ServerNote(text: "")) }
            progress(0.1)
        } else {
            stage(String(localized: "企业服务器转录"))
            onServer(ServerNote(text: ""))
            progress(0.1 + 0.8 * (state.progress ?? 0))
        }
    }

    // MARK: API（M§36.2）

    struct JobState {
        var status: String
        var queueAhead: Int?
        var stage: String?
        var progress: Double?
        var errorKind: String?
        var errorMessage: String?
    }

    /// 建工作时送的 settings（M§36.2；标准答案 server/settings.json）：说话者在本机识别（D122），分声道不送（服务器收的是混好的单声道）
    nonisolated static func settings(language: MeetingLanguage, glossary: [String], audioSource: String, minSpeakers: Int?) -> [String: Any] {
        var settings: [String: Any] = ["language": language.rawValue, "glossary": glossary, "diarize": false,
                                       "splitChannels": false, "audioSource": audioSource]
        if let minSpeakers { settings["minSpeakers"] = minSpeakers }
        return settings
    }

    private func create(bytes: Int64, sha256: String) async throws -> String {
        let settings = Self.settings(language: options.language, glossary: options.glossary, audioSource: options.audioSource,
                                     minSpeakers: options.minSpeakers)
        let (data, response) = try await server.call("POST", "api/v1/transcriptions", json: [
            "settings": settings,
            "audio": ["format": "wav", "sampleRate": 16000, "channels": 1, "bytes": bytes, "sha256": sha256],
        ])
        guard response.statusCode == 201, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { throw EnterpriseServer.failure(data, response) }
        log.info("enterprise job created")
        return id
    }

    private func status(_ id: String) async throws -> JobState {
        let (data, response) = try await server.call("GET", "api/v1/transcriptions/\(id)", timeout: 30)
        guard response.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else { throw EnterpriseServer.failure(data, response) }
        let error = json["error"] as? [String: Any]
        // 进度限在 0～1：画面拿来算百分比（Int 换不了的值会当掉）
        let progress = (json["progress"] as? Double).map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        return JobState(status: status, queueAhead: json["queueAhead"] as? Int, stage: json["stage"] as? String,
                      progress: progress, errorKind: error?["kind"] as? String, errorMessage: error?["message"] as? String)
    }

    /// 从服务器收到的地方接着传（HEAD 问位置），一次 8 MB。回传 false 表示服务器说文件不对、要从头传。
    /// 服务器给的位置不合理（负的、比文件大）就从头传；位置一直不往前就算失败，不会一直重送（design §36.2）
    private func upload(_ id: String, wav: URL, bytes: Int64) async throws -> Bool {
        let (_, head) = try await server.call("HEAD", "api/v1/transcriptions/\(id)/audio", timeout: 30)
        guard head.statusCode == 200 else { throw EnterpriseServer.Failure.server(kind: "not_found", message: "") }
        var offset = Self.offset(head, bytes: bytes) ?? 0
        let file = try FileHandle(forReadingFrom: wav)
        defer { try? file.close() }
        stage(String(localized: "上传录音"))
        let chunks = Int((bytes + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))
        var sent = 0
        var stalled = 0
        while offset < bytes {
            guard shouldContinue(), !switchToLocal() else { return true }
            sent += 1
            if stalled >= 3 || sent > chunks * 2 + 3 {
                log.error("enterprise upload offset not advancing")
                throw Failed(message: String(localized: "录音一直没办法完整传到企业服务器"))
            }
            try file.seek(toOffset: UInt64(offset))
            let chunk = try file.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty { break }
            let (data, response) = try await server.call("PATCH", "api/v1/transcriptions/\(id)/audio", body: chunk, headers: [
                "Upload-Offset": String(offset), "Content-Type": "application/offset+octet-stream",
            ], timeout: 300)
            let before = offset
            switch response.statusCode {
            case 204:
                offset = Self.offset(response, bytes: bytes) ?? offset + Int64(chunk.count)
            case 409:
                offset = Self.offset(response, bytes: bytes) ?? 0
            case 400:
                log.error("enterprise upload rejected, restarting")
                return false
            default:
                throw EnterpriseServer.failure(data, response)
            }
            stalled = offset > before ? 0 : stalled + 1
            progress(0.1 * Double(offset) / Double(max(bytes, 1)))
        }
        return true
    }

    /// 服务器回的 Upload-Offset：没有、不是数字是 nil；负的、比文件大当成 0（从头传）
    private static func offset(_ response: HTTPURLResponse, bytes: Int64) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Upload-Offset").flatMap({ Int64($0) }) else { return nil }
        return (0...bytes).contains(value) ? value : 0
    }

    private func result(_ id: String) async throws -> Remote {
        let (data, response) = try await server.call("GET", "api/v1/transcriptions/\(id)/result", timeout: 120)
        guard response.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["segments"] is [[String: Any]] else { throw EnterpriseServer.failure(data, response) }
        return try Self.parse(json)
    }

    /// 服务器的结果换成段落（M§36.2；标准答案 server/result.json）：少了开始、结束、文字的段落略过；一段都没有是「没有识别出文字」。
    /// 时间不合理的段落也略过（不是有限的数字、开始是负的、结束比开始早、超过 maxSeconds），接缝只留 0～maxSeconds（同 Windows）。
    /// 说话者在本机识别，结果里的 speaker、voices 不用
    nonisolated static func parse(_ json: [String: Any]) throws -> Remote {
        let items = json["segments"] as? [[String: Any]] ?? []
        let segments = items.compactMap { item -> TranscribedSegment? in
            guard let start = item["start"] as? Double, let end = item["end"] as? Double, let text = item["text"] as? String,
                  start.isFinite, end.isFinite, start >= 0, end >= start, end <= maxSeconds else { return nil }
            return TranscribedSegment(start: start, end: end, text: text, lowConfidence: item["lowConfidence"] as? Bool ?? false)
        }
        if segments.isEmpty { throw WhisperError.empty }
        let seams = (json["seams"] as? [Any] ?? []).compactMap { $0 as? Double }.filter { $0.isFinite && $0 >= 0 && $0 <= maxSeconds }
        return Remote(segments: segments, seams: seams,
                      engine: json["transcribedWith"] as? String ?? json["engine"] as? String ?? "breeze")
    }

    private func delete(_ id: String?) async {
        guard let id else { return }
        _ = try? await server.call("DELETE", "api/v1/transcriptions/\(id)", timeout: 15)
    }
}
