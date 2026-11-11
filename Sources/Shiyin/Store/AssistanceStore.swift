import Foundation
import GRDB

extension AppDatabase {
    func assistance(_ meetingId: Int64) throws -> MeetingAssistance? {
        try pool.read { try Self.assistance($0, meetingId) }
    }

    private static func assistance(_ db: Database, _ id: Int64) throws -> MeetingAssistance? {
        guard let text = try String.fetchOne(db, sql: "SELECT state FROM meeting_assistance WHERE meeting_id = ?", arguments: [id]) else { return nil }
        return try JSONDecoder().decode(MeetingAssistance.self, from: Data(text.utf8))
    }

    private static func saveAssistance(_ db: Database, _ id: Int64, _ state: MeetingAssistance) throws {
        let data = try JSONEncoder().encode(state)
        try db.execute(sql: "INSERT INTO meeting_assistance(meeting_id, state) VALUES (?, ?) ON CONFLICT(meeting_id) DO UPDATE SET state = excluded.state",
                       arguments: [id, String(decoding: data, as: UTF8.self)])
    }

    func savePreparation(_ id: Int64, _ preparation: MeetingPreparation) throws {
        try pool.write { db in
            var state = try Self.assistance(db, id) ?? MeetingAssistance()
            state.preparation = preparation.bounded
            if try String.fetchOne(db, sql: "SELECT source FROM meetings WHERE id = ?", arguments: [id]) == "prepared" {
                state.questions = []
            }
            state.seedQuestions()
            try Self.saveAssistance(db, id, state)
        }
    }

    func setCoachEnabled(_ id: Int64, _ enabled: Bool) throws {
        try pool.write { db in
            var state = try Self.assistance(db, id) ?? MeetingAssistance()
            state.preparation.enabled = enabled
            try Self.saveAssistance(db, id, state)
        }
    }

    func resetCoachProgress(_ id: Int64) throws {
        try pool.write { db in
            guard let old = try Self.assistance(db, id) else { return }
            var state = MeetingAssistance(preparation: old.preparation)
            state.seedQuestions()
            try Self.saveAssistance(db, id, state)
        }
    }

    func setCoachQuestion(_ id: Int64, question: String, status: CoachQuestion.Status) throws {
        try pool.write { db in
            guard var state = try Self.assistance(db, id), let index = state.questions.firstIndex(where: { $0.id == question }) else { return }
            state.questions[index].status = status
            try Self.saveAssistance(db, id, state)
        }
    }

    func mergeCoachOutput(_ id: Int64, output: CoachOutput, batch: CoachBatch) throws {
        try pool.write { db in
            guard var state = try Self.assistance(db, id), state.preparation.enabled,
                  try String.fetchOne(db, sql: "SELECT source FROM meetings WHERE id = ? AND deleted_at IS NULL", arguments: [id]) == "recording" else { return }
            state.merge(output, batch: batch)
            try Self.saveAssistance(db, id, state)
        }
    }
}
