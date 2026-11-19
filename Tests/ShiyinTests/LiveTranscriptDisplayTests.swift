import XCTest
@testable import Shiyin

final class LiveTranscriptDisplayTests: XCTestCase {
    func testReviewReplacesCoveredDraftsButKeepsLaterText() {
        var display = LiveTranscriptDisplay()
        display.addDraft(start: 0, end: 4, text: "快稿一")
        display.addDraft(start: 4, end: 10, text: "快稿二")
        display.addDraft(start: 10, end: 16, text: "下一句")

        display.addReview(start: 0, end: 10, text: "复核后的内容")

        XCTAssertEqual(display.lines.map(\.text), ["复核后的内容", "下一句"])
        XCTAssertEqual(display.lines.map(\.reviewed), [true, false])
    }

    func testBoundaryDraftRemainsUntilConsecutiveReviewsCoverIt() {
        var display = LiveTranscriptDisplay()
        display.addDraft(start: 0, end: 8, text: "前面")
        display.addDraft(start: 8, end: 22, text: "跨边界的句子")
        display.addReview(start: 0, end: 18, text: "第一段复核")
        XCTAssertEqual(display.lines.map(\.text), ["第一段复核", "跨边界的句子"])

        display.addReview(start: 18, end: 30, text: "第二段复核")
        XCTAssertEqual(display.lines.map(\.text), ["第一段复核", "第二段复核"])
    }

    func testLateDraftCannotOverwriteReviewAndBoundaryTextIsRetained() {
        var display = LiveTranscriptDisplay()
        display.addReview(start: 0, end: 18, text: "先完成的复核")
        display.addDraft(start: 2, end: 8, text: "迟到的旧快稿")
        display.addDraft(start: 16, end: 22, text: "仍含新内容的快稿")

        XCTAssertEqual(display.lines.map(\.text), ["先完成的复核", "仍含新内容的快稿"])
        display.addReview(start: 18, end: 25, text: "接下来的复核")
        XCTAssertEqual(display.lines.map(\.text), ["先完成的复核", "接下来的复核"])
    }

    func testEmptyReviewAndGapsNeverHideDrafts() {
        var display = LiveTranscriptDisplay()
        display.addDraft(start: 4, end: 24, text: "跨过未复核范围的快稿")
        display.addReview(start: 0, end: 10, text: "第一段复核")
        display.addReview(start: 10, end: 18, text: " \n")
        display.addReview(start: 18, end: 30, text: "第三段复核")

        XCTAssertEqual(display.lines.map(\.text), ["第一段复核", "跨过未复核范围的快稿", "第三段复核"])
    }

    func testOutOfOrderAdjacentReviewsStillCoverBoundaryDraft() {
        var display = LiveTranscriptDisplay()
        display.addDraft(start: 8, end: 22, text: "跨界快稿")
        display.addReview(start: 18, end: 30, text: "后面的复核")
        XCTAssertTrue(display.lines.contains { $0.text == "跨界快稿" })
        display.addReview(start: 0, end: 18, text: "前面的复核")
        XCTAssertEqual(display.lines.map(\.text), ["前面的复核", "后面的复核"])
    }

    func testPreviewHidesOnlyWhileItsEntireRangeIsReviewed() {
        var display = LiveTranscriptDisplay()
        display.setPreview(start: 8, end: 18, text: "暂定文字")
        XCTAssertEqual(display.visiblePreview, "暂定文字")
        display.addReview(start: 0, end: 18, text: "复核文字")
        XCTAssertEqual(display.visiblePreview, "")
        display.setPreview(start: 8, end: 20, text: "暂定文字与新内容")
        XCTAssertEqual(display.visiblePreview, "暂定文字与新内容")
        display.setPreview(start: 0, end: 0, text: "")
        XCTAssertEqual(display.visiblePreview, "")
    }

    func testUnusableTimestampsDoNotHidePreviewOrDraft() {
        var display = LiveTranscriptDisplay()
        display.addReview(start: 0, end: 18, text: "复核文字")
        display.addDraft(start: 4, end: 4, text: "没有时间长度的快稿")
        display.setPreview(start: .nan, end: .nan, text: "时间未知的暂定文字")

        XCTAssertTrue(display.lines.contains { $0.text == "没有时间长度的快稿" })
        XCTAssertEqual(display.visiblePreview, "时间未知的暂定文字")
    }

    @MainActor
    func testRecorderPublishesReviewAndResetsForNextMeeting() {
        let recorder = Recorder()
        recorder.addLiveDraft(start: 0, end: 8, text: "原来的快稿")
        recorder.setLivePreview(start: 8, end: 18, text: "暂定内容")
        recorder.addLiveReview(start: 0, end: 18, text: "完整复核内容")
        XCTAssertEqual(recorder.liveLines.map(\.text), ["完整复核内容"])
        XCTAssertEqual(recorder.volatileText, "")

        recorder.resetLiveDisplay()
        recorder.addLiveDraft(start: 0, end: 8, text: "新会议")
        XCTAssertEqual(recorder.liveLines.map(\.text), ["新会议"])
        XCTAssertEqual(recorder.volatileText, "")
    }

    @MainActor
    func testOldMeetingCallbacksSaveToOldMeetingWithoutChangingCurrentDisplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let old = try db.insertMeeting(Meeting(meetingDate: "2026-11-19", sourceFilename: "old"), audioExtension: nil).id!
        let current = try db.insertMeeting(Meeting(meetingDate: "2026-11-19", sourceFilename: "current"), audioExtension: nil).id!
        let recorder = Recorder()
        recorder.onLiveFinal = { id, start, end, text in try? db.appendLiveSegment(id, start: start, end: end, text: text) }
        recorder.onReviewed = { id, start, end, text in try db.appendReviewedSegment(id, start: start, end: end, text: text) }
        recorder.addLiveDraft(start: 0, end: 8, text: "新会议")

        recorder.receiveLiveFinal(meetingId: old, start: 0, end: 8, text: "旧会议快稿", current: false)
        recorder.receiveLiveReview(meetingId: old, start: 0, end: 18, text: "旧会议复核", current: false)

        XCTAssertEqual(recorder.liveLines.map(\.text), ["新会议"])
        XCTAssertEqual(try db.segments(old, kind: "live").map(\.text), ["旧会议快稿"])
        XCTAssertEqual(try db.segments(old, kind: "reviewed").map(\.text), ["旧会议复核"])
        XCTAssertTrue(try db.segments(current, kind: "reviewed").isEmpty)
    }

    @MainActor
    func testFailedReviewSaveKeepsTheDraftVisible() {
        enum SaveFailure: Error { case failed }
        let recorder = Recorder()
        recorder.addLiveDraft(start: 0, end: 6, text: "快稿")
        recorder.onReviewed = { _, _, _, _ in throw SaveFailure.failed }
        recorder.receiveLiveReview(meetingId: 1, start: 0, end: 18, text: "未保存的复核", current: true)
        XCTAssertEqual(recorder.liveLines.map(\.text), ["快稿"])
        XCTAssertFalse(recorder.reviewStatus.isEmpty)
    }
}
