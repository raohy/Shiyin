import Foundation
import XCTest
@testable import Shiyin

final class MeetingEditAssistanceTests: XCTestCase {
    private func withDatabase(_ body: (AppDatabase) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(AppDatabase(path: dir.appendingPathComponent("test.sqlite").path))
    }

    private func meeting(_ db: AppDatabase, times: [Double]) throws -> Int64 {
        let value = Meeting(meetingDate: "2026-11-19", sourceFilename: "test", durationSeconds: 60, source: "recording")
        let id = try XCTUnwrap(db.insertMeeting(value, audioExtension: nil).id)
        try db.savePreparation(id, MeetingPreparation(background: "项目评审", goals: "确认结果", role: "", initialQuestions: "", enabled: true))
        for (index, time) in times.enumerated() {
            try db.appendReviewedSegment(id, start: time, end: time + 1, text: "复核依据 \(index)")
        }
        let state = try XCTUnwrap(db.assistance(id))
        let batch = CoachBatch(lines: try db.reviewedCoachLines(id, from: 0), state: state)
        let candidates = ["接口费用何时确认？", "谁负责最终验收？", "交付日期是哪一天？"]
        let output = CoachOutput(summary: "会议摘要", questions: batch.lines.enumerated().map { index, line in
            .init(text: candidates[index], reason: "需要确认", segment: line.seq, priority: 1)
        })
        try db.mergeCoachOutput(id, output: output, batch: batch)
        return id
    }

    func testTrimAndSplitRemapEvidenceAndRestoreOnlyOriginalTimes() throws {
        try withDatabase { db in
            let id = try meeting(db, times: [5, 20, 45])
            let original = try XCTUnwrap(db.assistance(id))
            XCTAssertEqual(original.questions.map(\.time), [5, 20, 45])
            let plan = EditPlan(pieces: [.init(meetingId: id, start: 10, end: 50)])
            let edit = try XCTUnwrap(db.applyEdit(id, plan: plan, cut: 25, splitTitle: "后半场", audioExtension: nil))
            XCTAssertNotNil(edit.created)
            let changed = try XCTUnwrap(db.assistance(id))
            XCTAssertEqual(changed.questions.map(\.time), [nil, 10, nil])
            XCTAssertEqual(changed.questions.map(\.quote), original.questions.map(\.quote))
            try db.setCoachQuestion(id, question: original.questions[1].id, status: .asked)
            XCTAssertNotNil(try db.restoreEdit(id))
            let restored = try XCTUnwrap(db.assistance(id))
            XCTAssertEqual(restored.questions.map(\.time), original.questions.map(\.time))
            XCTAssertEqual(restored.questions[1].status, .asked)
            XCTAssertEqual(restored.questions.map(\.quote), original.questions.map(\.quote))
        }
    }

    func testMergeOffsetsOwnEvidenceAndLeavesOtherMeetingAssistanceIntact() throws {
        try withDatabase { db in
            let first = try meeting(db, times: [20])
            let other = try meeting(db, times: [3])
            let otherState = try XCTUnwrap(db.assistance(other))
            let plan = EditPlan(pieces: [.init(meetingId: other, start: 0, end: 10),
                                         .init(meetingId: first, start: 0, end: 50)])
            XCTAssertNotNil(try db.applyEdit(first, plan: plan, cut: nil, splitTitle: "", audioExtension: nil))
            XCTAssertEqual(try XCTUnwrap(db.assistance(first)).questions.first?.time, 30)
            XCTAssertEqual(try db.assistance(other), otherState)
            XCTAssertNotNil(try XCTUnwrap(db.meeting(other)).deletedAt)
            XCTAssertNotNil(try db.restoreEdit(first))
            XCTAssertEqual(try XCTUnwrap(db.assistance(first)).questions.first?.time, 20)
            XCTAssertEqual(try db.assistance(other), otherState)
            XCTAssertNil(try XCTUnwrap(db.meeting(other)).deletedAt)
        }
    }
}
