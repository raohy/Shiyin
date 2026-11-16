import AVFoundation

/// 录音的前段复制成暂存档（design §35.3）：没人说话太久而自动停止的录音，只转录到最后说话的地方；分割会议切成两个档（§64）
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

    /// 从 seconds 切成前段、后段两个暂存档（design §64，分割会议）：WAV 照原本的格式逐个采样切；其他格式（录音压缩成的 m4a、
    /// 导入的 mp3、mp4、aiff…）各自压成 m4a（D172，同 Windows：AVAudioFile 写不了 mp3、视频）。声道数不变。切点不在录音里面时回传 nil
    static func split(_ url: URL, at seconds: Double) async throws -> (head: URL, tail: URL)? {
        if url.pathExtension.lowercased() == "wav" { return try splitWAV(url, at: seconds) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let cut = CMTime(seconds: seconds, preferredTimescale: 48_000)
        guard seconds > 0, cut < duration else { return nil }
        let dir = try Paths.makeTempDirectory()
        let head = dir.appendingPathComponent("head.m4a"), tail = dir.appendingPathComponent("tail.m4a")
        do {
            for (output, range) in [(head, CMTimeRange(start: .zero, end: cut)), (tail, CMTimeRange(start: cut, end: duration))] {
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                export.timeRange = range
                try await export.export(to: output, as: .m4a)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return (head, tail)
    }

    private static func splitWAV(_ url: URL, at seconds: Double) throws -> (head: URL, tail: URL)? {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let cut = AVAudioFramePosition(seconds * format.sampleRate)
        guard cut > 0, cut < input.length else { return nil }
        let dir = try Paths.makeTempDirectory()
        let ext = url.pathExtension.lowercased()
        let head = dir.appendingPathComponent("head.\(ext)"), tail = dir.appendingPathComponent("tail.\(ext)")
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw CocoaError(.fileWriteUnknown) }
            for (output, frames) in [(head, cut), (tail, input.length - cut)] {
                // 每段一个 AVAudioFile，离开这一圈就关档（m4a 在关档时才写完）
                let file = try AVAudioFile(forWriting: output, settings: input.fileFormat.settings, commonFormat: format.commonFormat,
                                           interleaved: format.isInterleaved)
                var remaining = frames
                while remaining > 0 {
                    try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(65_536), remaining)))
                    if buffer.frameLength == 0 { break }
                    try file.write(from: buffer)
                    remaining -= AVAudioFramePosition(buffer.frameLength)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return (head, tail)
    }
}
