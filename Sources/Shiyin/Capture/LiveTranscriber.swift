@preconcurrency import AVFoundation
import Foundation
import Speech

@MainActor
protocol LiveTranscribing: AnyObject {
    var onVolatile: ((String) -> Void)? { get set }
    var onFinal: ((Double, Double, String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var buffersBeforeStart: Bool { get }
    var feedHandler: ([Float]) -> Void { get }
    func start() async throws
    func finish() async
    func cancel()
}

/// 录音中的实时逐字稿（design §5.3）：SpeechAnalyzer，语言依会议语言（§16.4），暂定结果约 0 秒、定稿约 2 秒
@MainActor
final class LiveTranscriber: LiveTranscribing {
    let language: MeetingLanguage
    var onVolatile: ((String) -> Void)?
    var onFinal: ((Double, Double, String) -> Void)?
    var onFailure: ((Error) -> Void)?
    let buffersBeforeStart = false
    private var finished = false

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private let feeder = Feeder()

    init(language: MeetingLanguage) {
        self.language = language
    }

    /// 送音频的部分，可以从写档的线程调用
    final class Feeder: @unchecked Sendable {
        private let lock = NSLock()
        private var builder: AsyncStream<AnalyzerInput>.Continuation?
        private var converter: AVAudioConverter?
        private var format: AVAudioFormat?

        func configure(builder: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
            lock.withLock {
                self.builder = builder
                self.format = format
                converter = format == CaptureFormat.mono ? nil : AVAudioConverter(from: CaptureFormat.mono, to: format)
            }
        }

        func feed(_ samples: [Float]) {
            lock.withLock {
                guard let builder, let format, !samples.isEmpty,
                      let input = AVAudioPCMBuffer(pcmFormat: CaptureFormat.mono, frameCapacity: AVAudioFrameCount(samples.count))
                else { return }
                input.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                guard let converter else {
                    builder.yield(AnalyzerInput(buffer: input))
                    return
                }
                let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / CaptureFormat.sampleRate + 64)
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                var fed = false
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return input
                }
                if error == nil, output.frameLength > 0 { builder.yield(AnalyzerInput(buffer: output)) }
            }
        }

        func finish() {
            lock.withLock {
                builder?.finish()
                builder = nil
            }
        }
    }

    nonisolated var feedHandler: ([Float]) -> Void {
        let feeder = feeder
        return { feeder.feed($0) }
    }


    /// 准备 SpeechAnalyzer；系统还没有会议语言的模型（中文是 zh_CN）时先下载（并入首次使用引导，design §11）
    func start() async throws {
        let transcriber = SpeechTranscriber(locale: language.speechLocale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await Self.ensureAssets(language, for: transcriber)
        guard !finished else { throw WhisperError.cancelled }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptureError.unsupportedFormat
        }
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        feeder.configure(builder: builder, format: format)
        try await analyzer.start(inputSequence: stream)
        guard !finished else {
            feeder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            throw WhisperError.cancelled
        }
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let raw = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    let text = self?.language.outputScript(raw) ?? raw
                    if result.isFinal {
                        if !text.isEmpty { self?.onFinal?(result.range.start.seconds, result.range.end.seconds, text) }
                        self?.onVolatile?("")
                    } else {
                        self?.onVolatile?(text)
                    }
                }
            } catch {
                log.error("live transcription ended: \(error.localizedDescription, privacy: .public)")
                if self?.finished == false { self?.onFailure?(error) }
            }
        }
    }

    func finish() async {
        finished = true
        feeder.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        analyzer = nil
        resultsTask = nil
    }

    func cancel() {
        finished = true
        feeder.finish()
    }

    static func isLocaleInstalled(_ language: MeetingLanguage) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier == language.speechLocale.identifier }
    }

    /// 系统还没有这个语言的识别模型时先下载（实时逐字稿和 macOS 内置识别共用）
    static func ensureAssets(_ language: MeetingLanguage, for transcriber: SpeechTranscriber? = nil) async throws {
        let module = transcriber ?? SpeechTranscriber(locale: language.speechLocale, preset: .transcription)
        if await isLocaleInstalled(language) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }
}
