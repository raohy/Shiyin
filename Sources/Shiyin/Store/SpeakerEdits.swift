import Foundation
import GRDB

/// 说话者的修正（design §24.2～§24.4、R23）：合并、改句子的说话者、复原最近一次；说话者识别的自我检查（§24.5）
extension AppDatabase {
    private struct SpeakerSnapshot: Codable {
        struct SegmentState: Codable { var id: Int64; var speaker: Int?; var manual: Bool }
        struct SpeakerState: Codable {
            var idx: Int, name: String, nameSource: String, personId: Int64?
            var embedding: Data?, speechSeconds: Double, audioSource: String
        }
        var segments: [SegmentState]
        var speakers: [SpeakerState]
        /// 合并时换了会议记录里的名字：换之前、换之后的会议记录（JSON）。复原时会议记录还是换之后的样子，就换回去
        var notesBefore: String?
        var notesAfter: String?
    }

    /// 改之前先存一份，只留最近一次
    private static func saveSpeakerUndo(_ db: Database, meetingId: Int64, label: String,
                                        notesBefore: String? = nil, notesAfter: String? = nil) throws {
        let segments = try Row.fetchAll(db, sql: "SELECT id, speaker, speaker_manual FROM segments WHERE meeting_id = ? AND kind = 'final'",
                                        arguments: [meetingId])
            .map { SpeakerSnapshot.SegmentState(id: $0["id"], speaker: $0["speaker"], manual: $0["speaker_manual"]) }
        let speakers = try SpeakerName.filter(Column("meeting_id") == meetingId).fetchAll(db).map {
            SpeakerSnapshot.SpeakerState(idx: $0.idx, name: $0.name, nameSource: $0.nameSource, personId: $0.personId,
                                         embedding: $0.embedding, speechSeconds: $0.speechSeconds, audioSource: $0.audioSource)
        }
        let snapshot = SpeakerSnapshot(segments: segments, speakers: speakers, notesBefore: notesBefore, notesAfter: notesAfter)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        try db.execute(sql: "INSERT OR REPLACE INTO speaker_undo (meeting_id, snapshot, label, created_at) VALUES (?, ?, ?, ?)",
                       arguments: [meetingId, json, label, Clock.now()])
    }

    /// 可以复原的调整（显示用的说明），没有就是 nil
    func speakerUndoLabel(_ meetingId: Int64) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT label FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId]) }
    }

    /// 复原最近一次说话者的调整。合并时换过名字的会议记录，之后没有再改的话一起换回去（拿掉合并时存的那一版）
    @discardableResult
    func undoSpeakerEdit(_ meetingId: Int64) throws -> Bool {
        try pool.write { db in
            guard let json = try String.fetchOne(db, sql: "SELECT snapshot FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId]),
                  let snapshot = try? JSONDecoder().decode(SpeakerSnapshot.self, from: Data(json.utf8)) else { return false }
            if let after = snapshot.notesAfter, let before = snapshot.notesBefore,
               try String.fetchOne(db, sql: "SELECT notes FROM meetings WHERE id = ?", arguments: [meetingId]) == after,
               try String.fetchOne(db, sql: "SELECT notes FROM notes_versions WHERE meeting_id = ? ORDER BY id DESC LIMIT 1",
                                   arguments: [meetingId]) == before {
                try Self.undoNotes(db, meetingId)
            }
            for s in snapshot.segments {
                try db.execute(sql: "UPDATE segments SET speaker = ?, speaker_manual = ? WHERE id = ?", arguments: [s.speaker, s.manual, s.id])
            }
            let people = Set(try Int64.fetchAll(db, sql: "SELECT id FROM people"))
            try SpeakerName.filter(Column("meeting_id") == meetingId).deleteAll(db)
            for s in snapshot.speakers {
                var row = SpeakerName(meetingId: meetingId, idx: s.idx, name: s.name)
                row.nameSource = s.nameSource
                row.personId = s.personId.flatMap { people.contains($0) ? $0 : nil }
                row.embedding = s.embedding
                row.speechSeconds = s.speechSeconds
                row.audioSource = s.audioSource
                try row.insert(db)
            }
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId])
            return true
        }
    }

    /// 合并说话者（R23.1）：from 的段落并到 into；声纹依说话秒数加权平均；from 存过的声纹删掉；
    /// 会议记录里 from 的名字换成 into 的名字（存一版）。回传两人原本的名字
    func mergeSpeakers(_ meetingId: Int64, from: Int, into: Int, label: String) throws -> (from: String, into: String)? {
        try pool.write { db in
            guard from != into,
                  let a = try SpeakerName.filter(Column("meeting_id") == meetingId && Column("idx") == into).fetchOne(db),
                  let b = try SpeakerName.filter(Column("meeting_id") == meetingId && Column("idx") == from).fetchOne(db),
                  let meeting = try Meeting.fetchOne(db, key: meetingId) else { return nil }
            var notesAfter: String?
            if let notes = meeting.decodedNotes, a.name != b.name {
                let updated = notes.replacingSpeakerName(b.name, with: a.name, isDefaultName: Self.isDefaultSpeakerName(b.name))
                if updated != notes {
                    try Self.saveNotes(db, meetingId, notes: updated, by: nil, reason: String(localized: "合并说话者"))
                    notesAfter = try String.fetchOne(db, sql: "SELECT notes FROM meetings WHERE id = ?", arguments: [meetingId])
                }
            }
            try Self.saveSpeakerUndo(db, meetingId: meetingId, label: label,
                                     notesBefore: notesAfter == nil ? nil : meeting.notes, notesAfter: notesAfter)
            try db.execute(sql: "UPDATE segments SET speaker = ? WHERE meeting_id = ? AND speaker = ?", arguments: [into, meetingId, from])
            var merged = a
            merged.speechSeconds = a.speechSeconds + b.speechSeconds
            switch (a.embedding, b.embedding) {
            case let (x?, y?):
                let (u, v) = (Voiceprint.vector(x), Voiceprint.vector(y))
                let (wa, wb) = (Float(max(a.speechSeconds, 1)), Float(max(b.speechSeconds, 1)))
                var sum = zip(u, v).map { $0 * wa + $1 * wb }
                let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
                if norm > 0 { sum = sum.map { $0 / norm } }
                merged.embedding = Voiceprint.data(sum)
            case (nil, let y?):
                merged.embedding = y
            default:
                break
            }
            try db.execute(sql: "UPDATE speakers SET speech_seconds = ?, embedding = ? WHERE meeting_id = ? AND idx = ?",
                           arguments: [merged.speechSeconds, merged.embedding, meetingId, into])
            try db.execute(sql: "DELETE FROM speakers WHERE meeting_id = ? AND idx = ?", arguments: [meetingId, from])
            try db.execute(sql: "DELETE FROM voiceprints WHERE meeting_id = ? AND speaker_idx = ?", arguments: [meetingId, from])
            try Self.deleteOrphanPeople(db)
            return (b.name, a.name)
        }
    }

    /// 改句子的说话者（R23.2）：to 是 nil 时添加一位说话者（默认名称）；改过的句子标成 speaker_manual；
    /// 没有段落的说话者拿掉。回传句子现在的说话者
    @discardableResult
    func reassignSegments(_ meetingId: Int64, ids: [Int64], to idx: Int?, label: String) throws -> Int {
        try pool.write { db in
            try Self.saveSpeakerUndo(db, meetingId: meetingId, label: label)
            var target = idx ?? 0
            if idx == nil {
                target = (try Int.fetchOne(db, sql: "SELECT MAX(idx) FROM speakers WHERE meeting_id = ?", arguments: [meetingId]) ?? 0) + 1
                let language = try Meeting.fetchOne(db, key: meetingId)?.meetingLanguage ?? .zh
                var speaker = SpeakerName(meetingId: meetingId, idx: target,
                                          name: language.defaultSpeaker(target))
                speaker.audioSource = try String.fetchOne(db, sql: "SELECT audio_source FROM speakers WHERE meeting_id = ? LIMIT 1",
                                                          arguments: [meetingId]) ?? "mix"
                try speaker.insert(db)
            }
            for id in ids {
                try db.execute(sql: "UPDATE segments SET speaker = ?, speaker_manual = 1 WHERE id = ? AND meeting_id = ?",
                               arguments: [target, id, meetingId])
            }
            let empty = try Int.fetchAll(db, sql: """
                SELECT idx FROM speakers s WHERE meeting_id = ?
                  AND NOT EXISTS (SELECT 1 FROM segments g WHERE g.meeting_id = s.meeting_id AND g.speaker = s.idx)
                """, arguments: [meetingId])
            for e in empty {
                try db.execute(sql: "DELETE FROM speakers WHERE meeting_id = ? AND idx = ?", arguments: [meetingId, e])
                try db.execute(sql: "DELETE FROM voiceprints WHERE meeting_id = ? AND speaker_idx = ?", arguments: [meetingId, e])
            }
            try Self.deleteOrphanPeople(db)
            return target
        }
    }

    /// 说话者识别完记下自我检查的分数（design §24.5），之前按过的「不用了」重置
    func setSpeakerCheck(_ meetingId: Int64, _ score: Double?) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET speaker_check = ?, speaker_hint_dismissed = 0 WHERE id = ?", arguments: [score, meetingId])
        }
    }

    func dismissSpeakerHint(_ meetingId: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET speaker_hint_dismissed = 1 WHERE id = ?", arguments: [meetingId])
        }
    }
}
