import XCTest
@testable import Shiyin

final class LiveReviewTests: XCTestCase {
    private let rate = QwenLiveBuffer.sampleRate
    private func voice(_ seconds: Double) -> [Float] { .init(repeating: 0.02, count: Int(seconds * Double(rate))) }
    private func silence(_ seconds: Double) -> [Float] { .init(repeating: 0, count: Int(seconds * Double(rate))) }

    func testReviewWaitsForLongerContextWithoutPublishingPreviews() throws {
        var draft = QwenLiveBuffer()
        var review = QwenLiveBuffer(reviewing: true)
        let first = voice(6) + silence(1.3)
        draft.append(first)
        review.append(first)
        XCTAssertTrue(try XCTUnwrap(draft.next(finishing: false)).isFinal)
        XCTAssertNil(review.next(finishing: false))
        review.append(voice(12) + silence(1.3))
        let request = try XCTUnwrap(review.next(finishing: false))
        XCTAssertTrue(request.isFinal)
        XCTAssertEqual(request.start, 0)
        XCTAssertGreaterThan(request.end, 18)
        XCTAssertLessThanOrEqual(request.end, 30)
    }

    func testReviewFlushesTailAndDoesNotDropOrDuplicateContinuousSpeech() throws {
        var review = QwenLiveBuffer(reviewing: true)
        let input = voice(83.27)
        review.append(input)
        var reconstructed: [Float] = []
        while let request = review.next(finishing: true) {
            XCTAssertTrue(request.isFinal)
            XCTAssertEqual(request.startSample, reconstructed.count)
            XCTAssertLessThanOrEqual(request.samples.count, 30 * rate)
            reconstructed += request.samples
            review.commit(request)
        }
        XCTAssertEqual(reconstructed, input)
    }

    func testReviewSkipsSilenceAndRetainsShortLastSentenceTimestamp() throws {
        var review = QwenLiveBuffer(reviewing: true)
        review.append(silence(60))
        XCTAssertNil(review.next(finishing: false))
        review.append(voice(0.2))
        XCTAssertNil(review.next(finishing: false))
        let last = try XCTUnwrap(review.next(finishing: true))
        XCTAssertEqual(last.end, 60.2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(last.start, 59.7)
    }

    func testCoachReadsOnlyReviewedTextAcrossInterleavedDraftsAndMeetings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let first = try db.insertMeeting(Meeting(meetingDate: "2026-11-13", sourceFilename: "test", source: "recording"), audioExtension: nil).id!
        let second = try db.insertMeeting(Meeting(meetingDate: "2026-11-13", sourceFilename: "other", source: "recording"), audioExtension: nil).id!
        try db.appendLiveSegment(first, start: 0, end: 6, text: "快稿误识别：月底全部免费交付")
        XCTAssertTrue(try db.reviewedCoachLines(first, from: 0).isEmpty, "Never fall back to the quick transcript")
        try db.appendReviewedSegment(first, start: 0, end: 18, text: "月底交付，接口费用还需要评估。")
        try db.appendLiveSegment(first, start: 18, end: 24, text: "仍在等待复核的另一段快稿")
        try db.appendReviewedSegment(second, start: 0, end: 18, text: "另一个会议")
        var state = MeetingAssistance()
        let batch = CoachBatch(lines: try db.reviewedCoachLines(first, from: state.nextSeq), state: state)
        XCTAssertEqual(batch.lines.map(\.text), ["月底交付，接口费用还需要评估。"])
        let prompt = try MeetingCoachPrompt.input(state: state, batch: batch)
        XCTAssertTrue(prompt.contains("audio_review"))
        XCTAssertFalse(prompt.contains("全部免费"))
        state.merge(CoachOutput(summary: "接口费用待确认", questions: [
            .init(text: "接口费用什么时候确认？", reason: "仍需要评估", segment: batch.lines[0].seq, priority: 1)
        ]), batch: batch)
        XCTAssertEqual(state.questions.first?.time, 0)
        XCTAssertEqual(state.questions.first?.quote, batch.lines[0].text)
        XCTAssertTrue(try db.reviewedCoachLines(first, from: state.nextSeq).isEmpty)
        try db.appendReviewedSegment(first, start: 18, end: 35, text: "明天确认费用。")
        XCTAssertEqual(try db.reviewedCoachLines(first, from: state.nextSeq).map(\.text), ["明天确认费用。"])
        XCTAssertEqual(try db.segments(first, kind: "live").count, 2, "Review must retain original drafts")
        XCTAssertTrue(try db.segments(first).isEmpty, "Review must not replace the formal transcript")
    }

    func testEmptyReviewDoesNotPromoteDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let id = try db.insertMeeting(Meeting(meetingDate: "2026-11-13", sourceFilename: "test"), audioExtension: nil).id!
        try db.appendLiveSegment(id, start: 0, end: 10, text: "只有快稿猜到的文字")
        try db.appendReviewedSegment(id, start: 0, end: 18, text: "  \n")
        XCTAssertTrue(try db.reviewedCoachLines(id, from: 0).isEmpty)
    }

    func testReviewTapCanContinueAfterDraftFailsAndDetachesOnCleanup() {
        let tap = MixTap()
        var draft: [Float] = [], review: [Float] = []
        tap.setLive { draft += $0 }
        tap.setReview { review += $0 }
        tap.handler([1, 2])
        tap.setLive(nil)
        tap.handler([3])
        tap.setReview(nil)
        tap.handler([4])
        XCTAssertEqual(draft, [1, 2])
        XCTAssertEqual(review, [1, 2, 3])
    }
}
