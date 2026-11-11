import AVFoundation

enum AudioDecoderError: LocalizedError {
    case noAudioTrack
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return String(localized: "这个文件里没有声音")
        case .unreadable(let reason): return String(localized: "读不到这个录音档，可能文件已损坏或不是支持的格式（\(reason)）")
        }
    }
}

/// 把任何 AVFoundation 读得到的音频或视频档，解码成 16 kHz 单声道 Float32（design §6.1）。取代第二版的 ffmpeg。
enum AudioDecoder {
    static let sampleRate: Double = 16_000

    static func decode(_ url: URL) async throws -> [Float] {
        try await read(url, channels: 1)
    }

    /// 保留声道解码（design §17.3）：双声道录音的麦克风、电脑声音分开转录用。每个声道一个数组；单声道的文件回传一个
    static func decodeChannels(_ url: URL) async throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioDecoderError.noAudioTrack }
        let formats = try await track.load(.formatDescriptions)
        let count = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map(Int.init) ?? 1
        guard count > 1 else { return [try await decode(url)] }
        let interleaved = try await read(url, channels: count)
        var channels = [[Float]](repeating: [], count: count)
        for c in 0..<count { channels[c].reserveCapacity(interleaved.count / count) }
        for (i, sample) in interleaved.enumerated() { channels[i % count].append(sample) }
        return channels
    }

    /// 解码成 16 kHz Float32；channels 大于 1 时是交错排列（左右左右…）
    private static func read(_ url: URL, channels: Int) async throws -> [Float] {
        let stream = try await Stream(url, channels: channels)
        var samples: [Float] = []
        samples.reserveCapacity((stream.estimatedCount + 16_000) * channels)
        try stream.fill(&samples, upTo: .max)
        return samples
    }

    /// 依序读出 16 kHz Float32，不用一次解码整段（长录音分段转录，design §21.16）。只能在同一个线程依序用
    final class Stream {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        /// 依文件长度估计的采样数（每个声道），算进度用
        let estimatedCount: Int
        private(set) var finished = false

        init(_ url: URL, channels: Int = 1) async throws {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioDecoderError.noAudioTrack }
            do { reader = try AVAssetReader(asset: asset) } catch { throw AudioDecoderError.unreadable(error.localizedDescription) }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw AudioDecoderError.unreadable(reader.error?.localizedDescription ?? String(localized: "无法开始读取"))
            }
            if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
                estimatedCount = Int(duration * sampleRate)
            } else {
                estimatedCount = 0
            }
        }

        /// 接着读，直到 samples 至少有 count 个采样或读完
        func fill(_ samples: inout [Float], upTo count: Int) throws {
            while samples.count < count, !finished {
                guard let buffer = output.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        throw AudioDecoderError.unreadable(reader.error?.localizedDescription ?? String(localized: "读取中断"))
                    }
                    finished = true
                    return
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length >= 4 else { continue }
                // block buffer 不一定连续，用复制的方式最保险
                var chunk = [Float](repeating: 0, count: length / 4)
                let status = chunk.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (length / 4) * 4, destination: $0.baseAddress!)
                }
                if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
            }
        }
    }

    /// 写成 16 kHz 单声道 16-bit WAV（导出 wav、macOS 内置识别的暂存档都用这个）
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var index = 0
        while index < samples.count {
            let count = min(160_000, samples.count - index)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples[index..<(index + count)].withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count)
            }
            try file.write(from: buffer)
            index += count
        }
        file.close()
    }
}
