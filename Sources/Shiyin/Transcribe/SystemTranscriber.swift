import AVFoundation
import Foundation
import Speech

/// 正式转录改用 macOS 内置识别（design §6.2.1、D11）：不需要 Breeze 模型，速度快很多，但没有词汇提示
enum SystemTranscriber {
    static func transcribe(samples: [Float], language: MeetingLanguage,
                           onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscribedSegment] {
        let duration = Double(samples.count) / AudioDecoder.sampleRate
        // 解码后的 16 kHz 单声道写成暂存 WAV，格式转换交给 SpeechAnalyzer 处理
        let dir = try Paths.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.wav")
        try AudioDecoder.writeWAV(samples, to: url)

        // 跟实时逐字稿共用系统的识别模型，还没有就先下载
        try await LiveTranscriber.ensureAssets(language)
        let transcriber = SpeechTranscriber(locale: language.speechLocale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscribedSegment] in
            var segments: [TranscribedSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscribedSegment(start: result.range.start.seconds, end: result.range.end.seconds,
                                                   text: text, lowConfidence: false))
                if duration > 0 { onProgress(min(1, result.range.end.seconds / duration)) }
            }
            return segments
        }
        let file = try AVAudioFile(forReading: url)
        try await withTaskCancellationHandler {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            _ = try await collector.value
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        return try await collector.value
    }
}
