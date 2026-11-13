import XCTest
@testable import Shiyin

final class QwenLiveTests: XCTestCase {
    private let rate = QwenLiveBuffer.sampleRate
    private func voice(_ seconds: Double) -> [Float] { .init(repeating: 0.02, count: Int(seconds * Double(rate))) }
    private func silence(_ seconds: Double) -> [Float] { .init(repeating: 0, count: Int(seconds * Double(rate))) }

    func testPreviewCanBeRevisedUntilPause() throws {
        var buffer = QwenLiveBuffer()
        buffer.append(voice(6))
        let first = try XCTUnwrap(buffer.next(finishing: false))
        XCTAssertFalse(first.isFinal)
        XCTAssertNil(buffer.next(finishing: false))
        buffer.append(voice(4))
        let second = try XCTUnwrap(buffer.next(finishing: false))
        XCTAssertFalse(second.isFinal)
        XCTAssertEqual(first.startSample, second.startSample)
        XCTAssertEqual(second.samples.count, 10 * rate)
        buffer.append(silence(1.3))
        let final = try XCTUnwrap(buffer.next(finishing: false))
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.startSample, 0)
        XCTAssertGreaterThanOrEqual(final.end, 11.2)
        buffer.commit(final)
        XCTAssertNil(buffer.next(finishing: false))
    }

    func testLongSpeechHasNoDroppedOrDuplicatedSamples() throws {
        var buffer = QwenLiveBuffer()
        let input = voice(71.37)
        // 模拟推理落后，音频已积压多段；收尾必须依序处理每一段。
        buffer.append(input)
        var reconstructed: [Float] = []
        var end = 0
        while let request = buffer.next(finishing: true) {
            XCTAssertTrue(request.isFinal)
            XCTAssertEqual(request.startSample, end)
            XCTAssertLessThanOrEqual(request.samples.count, QwenLiveBuffer.maxSamples)
            reconstructed += request.samples
            end += request.samples.count
            buffer.commit(request)
        }
        XCTAssertEqual(reconstructed, input)
        XCTAssertEqual(end, input.count)
    }

    func testSpeechAfterLongSilenceIsFlushed() throws {
        var buffer = QwenLiveBuffer()
        buffer.append(silence(48) + voice(0.27))
        let request = try XCTUnwrap(buffer.next(finishing: true))
        XCTAssertTrue(request.isFinal)
        XCTAssertEqual(request.end, 48.27, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(request.start, 47)
        buffer.commit(request)
        XCTAssertNil(buffer.next(finishing: true))
    }

    func testSilenceDoesNotGenerateRequestsAndKeepsPreroll() throws {
        var buffer = QwenLiveBuffer()
        for _ in 0..<300 { buffer.append(silence(0.1)); XCTAssertNil(buffer.next(finishing: false)) }
        XCTAssertLessThanOrEqual(buffer.samples.count, rate * 3 / 10)
        buffer.append(voice(0.03))
        let request = try XCTUnwrap(buffer.next(finishing: true))
        XCTAssertEqual(request.end, 30.03, accuracy: 0.001)
    }

    func testFeederCoalescesWakeupsWithoutDroppingAudio() async throws {
        let feed = QwenLiveFeed()
        feed.feed([1, 2])
        feed.feed([3])
        feed.finish()
        XCTAssertEqual(try feed.take(), [1, 2, 3])
        feed.feed([4])
        XCTAssertEqual(try feed.take(), [])
        var events = 0
        for await _ in feed.events { events += 1 }
        XCTAssertEqual(events, 1)
    }

    func testFeederReportsOverflow() throws {
        let feed = QwenLiveFeed()
        feed.feed(voice(121))
        XCTAssertThrowsError(try feed.take()) { XCTAssertTrue($0 is QwenLiveError) }
    }

    @MainActor
    func testCancelledBeforeStartDoesNotLoadModel() async {
        let live = QwenLiveTranscriber(language: .en, glossary: [])
        live.cancel()
        do { try await live.start(); XCTFail("Cancelled transcriber started") }
        catch { XCTAssertTrue(error is WhisperError) }
        await live.finish()
    }

    /// 可选真实模型验证：QWEN_LIVE_TEST_AUDIO=/absolute/path.wav swift test --filter QwenLiveTests/testRealModel
    /// 只读取本机模型和指定音频，不启动 AppModel、不写会议数据库。
    @MainActor
    func testRealModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["QWEN_LIVE_TEST_AUDIO"] else {
            throw XCTSkip("Set QWEN_LIVE_TEST_AUDIO to run local model integration")
        }
        guard ModelStore.isDownloaded(.qwen) else { throw XCTSkip("Qwen model not installed") }
        let audio = try await AudioDecoder.decode(URL(fileURLWithPath: path))
        let language = MeetingLanguage(rawValue: ProcessInfo.processInfo.environment["QWEN_LIVE_TEST_LANGUAGE"] ?? "en") ?? .en
        let reviewOnly = ProcessInfo.processInfo.environment["QWEN_LIVE_TEST_REVIEW_ONLY"] == "1"
        let live = QwenLiveTranscriber(language: language, glossary: ["release", "validation"], reviewOnly: reviewOnly)
        var finals: [(Double, Double, String)] = []
        var reviewed: [(Double, Double, String)] = []
        var previews: [String] = []
        var failure: Error?
        live.onFinal = { finals.append(($0, $1, $2)) }
        live.onVolatile = { if !$0.isEmpty { previews.append($0) } }
        live.onFailure = { failure = $0 }
        live.onReviewed = { reviewed.append(($0, $1, $2)) }
        live.onReviewFailure = { failure = $0 }
        // 冷启动前入队，覆盖模型加载和停止录音时尾句仍在队列中的情况。
        let stream = !reviewOnly && ProcessInfo.processInfo.environment["QWEN_LIVE_TEST_STREAM"] == "1"
        let initial = stream ? min(6 * rate, audio.count) : audio.count
        live.feedHandler(Array(audio.prefix(initial)))
        try await live.start()
        if stream {
            let deadline = Date().addingTimeInterval(30)
            while previews.isEmpty && finals.isEmpty && failure == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(previews.isEmpty, "Expected a revisable preview before finalization")
            // 模拟麦克风不规则大小的 callback，并在仍有待处理音频时停止。
            for start in stride(from: initial, to: audio.count, by: 7_031) {
                live.feedHandler(Array(audio[start..<min(start + 7_031, audio.count)]))
            }
        }
        await live.finish()
        XCTAssertNil(failure)
        if reviewOnly { XCTAssertTrue(finals.isEmpty); XCTAssertTrue(previews.isEmpty) }
        else { XCTAssertFalse(finals.isEmpty) }
        XCTAssertFalse(reviewed.isEmpty)
        for (index, segment) in reviewed.enumerated() {
            XCTAssertGreaterThan(segment.1, segment.0)
            if index > 0 { XCTAssertGreaterThanOrEqual(segment.0, reviewed[index - 1].1) }
            print("QWEN REVIEW [\(segment.0)–\(segment.1)] \(segment.2)")
        }
        XCTAssertLessThanOrEqual(reviewed.last?.1 ?? 0, Double(audio.count) / Double(rate) + 0.01)
        for (index, segment) in finals.enumerated() {
            XCTAssertGreaterThan(segment.1, segment.0)
            if index > 0 { XCTAssertGreaterThanOrEqual(segment.0, finals[index - 1].1) }
            print("QWEN LIVE [\(segment.0)–\(segment.1)] \(segment.2)")
        }
        XCTAssertLessThanOrEqual(finals.last?.1 ?? 0, Double(audio.count) / Double(rate) + 0.01)
        if let expected = ProcessInfo.processInfo.environment["QWEN_LIVE_TEST_EXPECT"] {
            let text = reviewed.map(\.2).joined(separator: " ").lowercased()
            for term in expected.components(separatedBy: "|") { XCTAssertTrue(text.contains(term.lowercased()), "Missing: \(term)") }
        }
    }
}
