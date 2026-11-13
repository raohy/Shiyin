import Foundation

@MainActor
final class QwenLiveTranscriber: LiveTranscribing {
    var onVolatile: ((String) -> Void)?
    var onFinal: ((Double, Double, String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onReviewed: ((Double, Double, String) -> Void)?
    var onReviewFailure: ((Error) -> Void)?
    let buffersBeforeStart = true

    private let language: MeetingLanguage
    private let glossary: [String]
    private let reviewOnly: Bool
    private let feeder = QwenLiveFeed()
    private let control = WhisperEngine.Control(onProgress: { _ in })
    private var worker: Task<Void, Never>?
    private var finished = false

    init(language: MeetingLanguage, glossary: [String], reviewOnly: Bool = false) {
        self.language = language
        self.glossary = glossary
        self.reviewOnly = reviewOnly
    }

    var feedHandler: ([Float]) -> Void {
        let feeder = feeder
        return { feeder.feed($0) }
    }

    func start() async throws {
        guard !finished else { throw WhisperError.cancelled }
        guard language.profile.transcription.qwen != nil else { throw QwenLiveError.unsupportedLanguage }
        guard ModelStore.isDownloaded(.qwen) else { throw QwenLiveError.missingModel }
        let (feeder, control, language, glossary, reviewOnly) = (feeder, control, language, glossary, reviewOnly)
        let modelPath = ModelStore.path(.qwen).path
        let encoderPath = ModelStore.path(.qwenEncoder).path
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            worker = Task.detached(priority: .userInitiated) { [weak self] in
                var started = false
                do {
                    // 常驻到收尾完成；构造、推理、释放都在同一个后台任务中顺序执行。
                    let session = try QwenEngine.LiveSession(modelPath: modelPath, encoderPath: encoderPath,
                                                           language: language, glossary: glossary, control: control)
                    if control.isCancelled { throw WhisperError.cancelled }
                    started = true
                    ready.resume()
                    var buffer = QwenLiveBuffer()
                    var precedingAudio: [Float] = []
                    var precedingText = ""
                    var reviewBuffer = QwenLiveBuffer(reviewing: true)
                    var reviewedAudio: [Float] = []
                    var reviewedText = ""
                    var draftFailed = reviewOnly
                    var reviewFailed = false
                    func drain(_ buffer: inout QwenLiveBuffer, audio: inout [Float], text: inout String,
                               reviewing: Bool, finishing: Bool) async throws {
                        while let request = buffer.next(finishing: finishing) {
                            if control.isCancelled { throw WhisperError.cancelled }
                            let result = try session.transcribe(request.samples, precedingAudio: audio, precedingText: text)
                            await self?.receive(request, text: language.outputScript(result.text), reviewing: reviewing)
                            if request.isFinal {
                                // 空结果不作为下一段的音文锚点；避免要求模型跳过没有对应文字的音频。
                                audio = result.text.isEmpty ? [] : request.samples
                                text = result.text.isEmpty ? "" : result.raw
                                buffer.commit(request)
                            }
                        }
                    }
                    func process(finishing: Bool) async throws {
                        let samples = try feeder.take()
                        if !draftFailed {
                            buffer.append(samples)
                            do {
                                try await drain(&buffer, audio: &precedingAudio, text: &precedingText, reviewing: false, finishing: finishing)
                            } catch {
                                if control.isCancelled { throw error }
                                draftFailed = true
                                buffer = QwenLiveBuffer()
                                precedingAudio = []; precedingText = ""
                                await self?.onFailure?(error)
                            }
                        }
                        if !reviewFailed {
                            reviewBuffer.append(samples)
                            do {
                                try await drain(&reviewBuffer, audio: &reviewedAudio, text: &reviewedText, reviewing: true, finishing: finishing)
                            } catch {
                                if control.isCancelled { throw error }
                                reviewFailed = true
                                reviewBuffer = QwenLiveBuffer(reviewing: true)
                                reviewedAudio = []; reviewedText = ""
                                await self?.onReviewFailure?(error)
                            }
                        }
                        if draftFailed && reviewFailed { feeder.finish() }
                    }
                    for await _ in feeder.events {
                        try await process(finishing: false)
                    }
                    try await process(finishing: true)
                } catch {
                    feeder.finish()
                    if !started { ready.resume(throwing: error) }
                    else if !control.isCancelled {
                        if !reviewOnly { await self?.onFailure?(error) }
                        await self?.onReviewFailure?(error)
                    }
                }
            }
        }
    }

    private func receive(_ request: QwenLiveBuffer.Request, text: String, reviewing: Bool) {
        guard !control.isCancelled else { return }
        if reviewing {
            // 包括空结果：表示这段已复核，不能用快稿补上模型没有听到的内容。
            onReviewed?(request.start, request.end, text)
            return
        }
        if request.isFinal {
            if !text.isEmpty { onFinal?(request.start, request.end, text) }
            onVolatile?("")
        } else {
            onVolatile?(text)
        }
    }

    func finish() async {
        finished = true
        feeder.finish()
        await worker?.value
        worker = nil
    }

    func cancel() {
        finished = true
        control.cancel()
        feeder.finish()
    }
}
