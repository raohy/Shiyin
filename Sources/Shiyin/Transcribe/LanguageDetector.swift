import Foundation
import whisper

/// 自动检测会议的主要语言（design §18.8、R16、D21）：开始录音后收集约 10 秒有声音的片段，
/// 用 Whisper base 在语言档里可以检测的语言之间判断（design §41.4）
enum LanguageDetector {
    /// 要收集几秒有声音的片段
    static let seconds: Double = 10
    /// 可以检测的语言的概率加总成 1 之后，最高的超过这个才切换
    static let threshold = 0.7

    /// 回传可以检测的语言各自的概率（加总为 1）。blocking，在背景执行
    nonisolated static func detect(_ samples: [Float], modelPath: String) throws -> [MeetingLanguage: Double] {
        guard FileManager.default.fileExists(atPath: modelPath) else { throw WhisperError.modelMissing }
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else { throw WhisperError.loadFailed }
        WhisperContexts.opened()
        defer { whisper_free(ctx); WhisperContexts.closed() }
        let threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        let mel = samples.withUnsafeBufferPointer { whisper_pcm_to_mel(ctx, $0.baseAddress, Int32($0.count), threads) }
        guard mel == 0 else { throw WhisperError.failed(Int32(mel)) }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let top = whisper_lang_auto_detect(ctx, 0, threads, &probs)
        guard top >= 0 else { throw WhisperError.failed(Int32(top)) }
        var result: [MeetingLanguage: Double] = [:]
        for language in MeetingLanguage.allCases {
            guard let code = language.profile.detect else { continue }
            let id = Int(whisper_lang_id(code))
            result[language] = probs.indices.contains(id) ? Double(probs[id]) : 0
        }
        let total = result.values.reduce(0, +)
        return total > 0 ? result.mapValues { $0 / total } : result
    }

    /// 录音时收集有声音的片段：每 0.1 秒一段，比背景噪音大 2.5 倍（至少 -54 dBFS）才算，凑满 `seconds` 秒就交出去；
    /// 录了 45 秒还凑不满（小声、远距收音）但有 5 秒以上，也先交出去。只交一次。feed 在写档的线程上调用
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var voiced: [Float] = []
        private var pending: [Float] = []
        private var seen = 0
        /// 背景噪音的估计：遇到更小的就马上降下来，平常慢慢往上爬（换到比较吵的环境也跟得上）
        private var floor: Float?
        private var finished = false
        private let target = Int(LanguageDetector.seconds * CaptureFormat.sampleRate)
        private let window = Int(CaptureFormat.sampleRate / 10)
        private let onReady: @Sendable ([Float]) -> Void

        init(onReady: @escaping @Sendable ([Float]) -> Void) { self.onReady = onReady }

        func feed(_ samples: [Float]) {
            let ready: [Float]? = lock.withLock {
                guard !finished else { return nil }
                pending += samples
                while pending.count >= window {
                    let chunk = pending[..<window]
                    pending.removeFirst(window)
                    seen += window
                    var sum: Float = 0
                    for s in chunk { sum += s * s }
                    let rms = (sum / Float(window)).squareRoot()
                    let current = floor ?? rms
                    floor = rms < current ? rms : current + (rms - current) * 0.002
                    if rms > max(0.002, current * 2.5) { voiced += chunk }
                }
                let enough = voiced.count >= target
                    || (seen >= Int(45 * CaptureFormat.sampleRate) && voiced.count >= target / 2)
                guard enough else { return nil }
                finished = true
                return voiced
            }
            if let ready { onReady(ready) }
        }
    }
}
