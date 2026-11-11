import CryptoKit
import Foundation
import Observation

/// 转录模型的下载、续传、验证（design §7、§18.2、R10.3）。Breeze 给中文、英文会议；日文会议用 Whisper large-v3-turbo；
/// 语言检测用 Whisper base（design §18.8）。每个模型各自下载、暂停、删除
@MainActor
@Observable
final class ModelStore: NSObject {
    enum Model: String, CaseIterable, Sendable {
        case breeze, japanese, languageDetection, qwen, qwenEncoder
    }

    struct ModelInfo: Sendable {
        let name: String
        let filename: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    enum State: Equatable {
        case missing
        case downloading(received: Int64, total: Int64)
        case paused(received: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying: return true
            default: return false
            }
        }
    }

    /// 社区转档的 Breeze ASR 25 GGML q8_0，固定 commit（design §7）
    nonisolated static let breeze = ModelInfo(
        name: String(localized: "Breeze ASR 25（q8_0）"),
        filename: "breeze-asr-25-q8_0.bin",
        url: URL(string: "https://huggingface.co/shdennlin/breeze-asr-25-ggml/resolve/36c726093efe1760d1dd39c3cfe8b6a7282437d1/ggml-breeze-asr-25-q8_0.bin")!,
        size: 1_656_129_691,
        sha256: "d4b187c40ffbf1f620734b77821e2ca8a97c8ecf5754d02b2a175069348cafcf")

    /// whisper.cpp 官方转档的 Whisper large-v3-turbo q5_0，固定 commit（design §18.2、D19）
    nonisolated static let japanese = ModelInfo(
        name: String(localized: "\(MeetingLanguage.uiNames(model: "turbo"))转录模型 Whisper large-v3-turbo（q5_0）"),
        filename: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin")!,
        size: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")

    /// 语言检测用的 Whisper base q5_1（design §18.8、D21）
    nonisolated static let languageDetection = ModelInfo(
        name: String(localized: "语言检测模型 Whisper base（q5_1）"),
        filename: "ggml-base-q5_1.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base-q5_1.bin")!,
        size: 59_707_625,
        sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898")

    /// llama.cpp 官方转档的 Qwen3-ASR 1.7B q8_0 和它的音频编码器（mmproj），固定 commit（design §32.3、D105）
    nonisolated static let qwen = ModelInfo(
        name: String(localized: "Qwen3-ASR 1.7B（q8_0）"),
        filename: "qwen3-asr-1.7b-q8_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/Qwen3-ASR-1.7B-Q8_0.gguf")!,
        size: 2_165_034_944,
        sha256: "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57")

    nonisolated static let qwenEncoder = ModelInfo(
        name: String(localized: "Qwen3-ASR 音频编码器（q8_0）"),
        filename: "qwen3-asr-1.7b-mmproj-q8_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf")!,
        size: 355_709_344,
        sha256: "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d")

    nonisolated static func info(_ model: Model) -> ModelInfo {
        switch model {
        case .breeze: return breeze
        case .japanese: return japanese
        case .languageDetection: return languageDetection
        case .qwen: return qwen
        case .qwenEncoder: return qwenEncoder
        }
    }

    /// 正式转录用哪个模型（design §32.3、§41.3）：语言档的 transcription.model；engineSetting 的语言（中文、英文）依设置用
    /// Breeze（默认）或 Qwen3-ASR。`.japanese` 就是 Whisper large-v3-turbo（日文以外的语言也用）
    nonisolated static func transcription(for language: MeetingLanguage) -> Model {
        let t = language.profile.transcription
        switch t.model {
        case "turbo": return .japanese
        case "qwen": return .qwen
        default: return t.engineSetting && t.qwen != nil && AppSettings.transcriptionEngine == "qwen" ? .qwen : .breeze
        }
    }

    /// 这个模型要的文件：Qwen3-ASR 是语言模型加音频编码器两个档，一起下载、一起算装好
    nonisolated static func files(of model: Model) -> [Model] { model == .qwen ? [.qwen, .qwenEncoder] : [model] }

    nonisolated static func path(_ model: Model) -> URL { Paths.modelsDir.appendingPathComponent(info(model).filename) }

    /// 这个模型的文件都下载好了（下载完、验证过才会出现在这个路径）
    nonisolated static func isDownloaded(_ model: Model) -> Bool {
        files(of: model).allSatisfy { FileManager.default.fileExists(atPath: path($0).path) }
    }

    /// 这个语言的转录模型下载好了没
    nonisolated static func hasTranscriptionModel(for language: MeetingLanguage) -> Bool { isDownloaded(transcription(for: language)) }
    nonisolated static var breezePath: URL { path(.breeze) }
    nonisolated private static func resumeDataPath(_ model: Model) -> URL {
        Paths.modelsDir.appendingPathComponent(".\(info(model).filename).resume")
    }

    #if DEBUG
    /// 只在 DEBUG：改从别的网址下载，测下载出错（shiyinctl modelurl）
    @ObservationIgnored var debugURLs: [Model: URL] = [:]
    #endif

    private(set) var states: [Model: State] = [:]
    private(set) var diarizerState: State = .missing
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [Model: URLSessionDownloadTask] = [:]

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        refresh()
    }

    /// Breeze 的状态（中文、英文会议）
    var state: State { state(.breeze) }
    var isReady: Bool { isInstalled(.breeze) }

    func state(_ model: Model) -> State { states[model] ?? .missing }
    func isInstalled(_ model: Model) -> Bool { state(model) == .installed }
    /// 这个语言的转录模型（Qwen3-ASR 的两个档都要）装好了
    func isInstalled(transcriptionFor language: MeetingLanguage) -> Bool {
        Self.files(of: Self.transcription(for: language)).allSatisfy { isInstalled($0) }
    }

    /// 多个档的模型合成一列显示（设置页、引导）：都装好才算装好；有一个失败就显示失败；任一个在下载就显示下载中（字节加总）
    func combinedState(_ model: Model) -> State {
        let files = Self.files(of: model)
        if files.count == 1 { return state(model) }
        let states = files.map { state($0) }
        if states.allSatisfy({ $0 == .installed }) { return .installed }
        if let failed = states.first(where: { if case .failed = $0 { return true } else { return false } }) { return failed }
        if states.contains(.verifying) { return .verifying }
        var received: Int64 = 0, total: Int64 = 0, downloading = false, paused = false
        for (file, s) in zip(files, states) {
            let size = Self.info(file).size
            switch s {
            case .downloading(let r, let t): received += r; total += t > 0 ? t : size; downloading = true
            case .paused(let r, let t): received += r; total += t > 0 ? t : size; paused = true
            case .installed: received += size; total += size
            default: total += size
            }
        }
        if downloading { return .downloading(received: received, total: total) }
        if paused { return .paused(received: received, total: total) }
        return .missing
    }

    func startAll(_ model: Model) { for file in Self.files(of: model) { start(file) } }
    func pauseAll(_ model: Model) { for file in Self.files(of: model) { pause(file) } }
    func deleteAll(_ model: Model) { for file in Self.files(of: model) { delete(file) } }
    /// 这个语言的转录模型还没下载过就开始下载（Qwen3-ASR 两个档一起）
    func autoStartTranscription(for language: MeetingLanguage) {
        for file in Self.files(of: Self.transcription(for: language)) { autoStart(file) }
    }

    func refresh() {
        let fm = FileManager.default
        for model in Model.allCases where !state(model).isBusy {
            let info = Self.info(model)
            if let size = (try? fm.attributesOfItem(atPath: Self.path(model).path))?[.size] as? Int64, size == info.size {
                states[model] = .installed
            } else if fm.fileExists(atPath: Self.resumeDataPath(model).path) {
                states[model] = .paused(received: 0, total: info.size)
            } else if case .failed = state(model) {
                // 保留错误消息，用户按「继续下载」才重来
            } else {
                states[model] = .missing
            }
        }
        if !diarizerState.isBusy { diarizerState = Diarizer.isInstalled ? .installed : .missing }
    }

    // MARK: 下载

    func start(_ model: Model = .breeze) {
        guard !state(model).isBusy, state(model) != .installed else { return }
        try? Paths.ensureDirectories()
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: Self.resumeDataPath(model)) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var url = Self.info(model).url
            #if DEBUG
            url = debugURLs[model] ?? url
            #endif
            task = session.downloadTask(with: url)
        }
        task.taskDescription = model.rawValue
        tasks[model] = task
        states[model] = .downloading(received: 0, total: Self.info(model).size)
        task.resume()
        log.info("model download started: \(model.rawValue, privacy: .public)")
    }

    /// 需要时自动下载（日文会议第一次转录）：只在还没下载过时开始，用户暂停或下载失败就不自动重来
    func autoStart(_ model: Model) {
        if state(model) == .missing { start(model) }
    }

    func pause(_ model: Model = .breeze) {
        guard case .downloading(let received, let total) = state(model), let task = tasks[model] else { return }
        task.cancel { [weak self] data in
            Task { @MainActor in
                if let data { try? data.write(to: Self.resumeDataPath(model)) }
                self?.states[model] = .paused(received: received, total: total)
            }
        }
        tasks[model] = nil
    }

    func delete(_ model: Model = .breeze) {
        tasks[model]?.cancel()
        tasks[model] = nil
        try? FileManager.default.removeItem(at: Self.path(model))
        try? FileManager.default.removeItem(at: Self.resumeDataPath(model))
        states[model] = .missing
    }

    // MARK: 说话者识别模型（由 FluidAudio 下载，见 design §6.3）

    func prepareDiarizer() {
        guard !diarizerState.isBusy else { return }
        diarizerState = .downloading(received: 0, total: 0)
        Task {
            do {
                _ = try await Diarizer.prepare()
                diarizerState = .installed
            } catch {
                diarizerState = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ model: Model, downloadedFile: URL) {
        states[model] = .verifying
        let destination = Self.path(model)
        Task.detached(priority: .utility) {
            let result = Result { try Self.verify(downloadedFile, model: model) }
            await MainActor.run {
                switch result {
                case .success(true):
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.moveItem(at: downloadedFile, to: destination)
                        try? FileManager.default.removeItem(at: Self.resumeDataPath(model))
                        self.states[model] = .installed
                        log.info("model installed: \(model.rawValue, privacy: .public)")
                        AppModel.shared.runner.wake()
                    } catch {
                        self.states[model] = .failed(String(localized: "无法存放模型：\(error.localizedDescription)"))
                    }
                case .success(false):
                    try? FileManager.default.removeItem(at: downloadedFile)
                    try? FileManager.default.removeItem(at: Self.resumeDataPath(model))
                    self.states[model] = .failed(String(localized: "下载的模型档验证失败（SHA-256 不符），请重新下载"))
                case .failure(let error):
                    self.states[model] = .failed(String(localized: "验证模型失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    /// 串流计算 SHA-256，不一次读进整个模型档
    nonisolated static func verify(_ file: URL, model: Model = .breeze) throws -> Bool {
        try sha256(file) == info(model).sha256
    }

    /// 文件的 SHA-256（小写十六进位）；更新器验证下载的 DMG 也用这个
    nonisolated static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated private static func model(of task: URLSessionTask) -> Model {
        Model(rawValue: task.taskDescription ?? "") ?? .breeze
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let model = Self.model(of: downloadTask)
        MainActor.assumeIsolated {
            guard case .downloading = state(model) else { return }
            states[model] = .downloading(received: totalBytesWritten,
                                         total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.info(model).size)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let model = Self.model(of: downloadTask)
        // 服务器回传错误页（404、500…）也会「下载完成」，不要拿去验 SHA-256（会误报成文件损坏）
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard code == 200 || code == 206 else {
            MainActor.assumeIsolated {
                try? FileManager.default.removeItem(at: Self.resumeDataPath(model))
                tasks[model] = nil
                states[model] = .failed(String(localized: "下载失败：服务器回传 HTTP \(code)，请稍后再试"))
            }
            return
        }
        // location 在这个方法结束后就会被删掉，先搬到 tmp
        let kept = Paths.tmpDir.appendingPathComponent("model-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            MainActor.assumeIsolated { finish(model, downloadedFile: kept) }
        } catch {
            MainActor.assumeIsolated { states[model] = .failed(String(localized: "无法存放下载的文件：\(error.localizedDescription)")) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        let model = Self.model(of: task)
        let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            if error.code == NSURLErrorCancelled { return }  // 暂停或删除
            // 没有新的续传资料就丢掉旧的：旧的可能已经不能用，留着的话每次「继续下载」都会一样失败
            if let resume { try? resume.write(to: Self.resumeDataPath(model)) } else { try? FileManager.default.removeItem(at: Self.resumeDataPath(model)) }
            tasks[model] = nil
            // 系统的错误说明本身可能已经有句号
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "。. "))  // l10n-skip
            states[model] = .failed(resume != nil
                ? String(localized: "下载中断：\(reason)。按「继续下载」会从中断的地方接着下载")
                : String(localized: "下载中断：\(reason)。按「继续下载」会重新下载"))
        }
    }
}
