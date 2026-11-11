import AVFoundation

/// 录音的前段复制成暂存档（design §35.3）：没人说话太久而自动停止的录音，只转录到最后说话的地方
enum AudioTrim {
    /// 前 seconds 秒写成 32-bit float 的 WAV（声道、采样率不变），放在新的暂存文件夹；录音本来就没有比这长时回传 nil
    static func prefix(of url: URL, seconds: Double) throws -> URL? {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let frames = AVAudioFramePosition(seconds * format.sampleRate)
        guard frames > 0, frames < input.length else { return nil }
        let dir = try Paths.makeTempDirectory()
        let output = dir.appendingPathComponent("until.wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw CocoaError(.fileWriteUnknown) }
            var remaining = frames
            while remaining > 0 {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(65_536), remaining)))
                if buffer.frameLength == 0 { break }
                try file.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return output
    }
}
