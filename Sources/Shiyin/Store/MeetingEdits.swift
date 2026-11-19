import Foundation
import GRDB

/// 编辑会议的快照（migration v16、design §81.3）：只留第一次编辑前的样子，最后一次编辑后 30 天删掉（D179）
struct MeetingEditRecord: SnakeCaseRecord {
    static let databaseTableName = "meeting_edits"
    var meetingId: Int64
    var snapshot: String
    /// 编辑前的录音，audio/ 底下的相对路径（edits/<id>.<扩展名>）；没有录音的会议是空字符串
    var audioFile: String
    var splitInto: String = "[]"
    var mergedFrom: String = "[]"
    var createdAt: String = Clock.now()
    var editedAt: String = Clock.now()

    static let keepDays = 30

    var splitIds: [Int64] { (try? JSONDecoder().decode([Int64].self, from: Data(splitInto.utf8))) ?? [] }
    var mergedIds: [Int64] { (try? JSONDecoder().decode([Int64].self, from: Data(mergedFrom.utf8))) ?? [] }

    /// 还剩几天自动删掉（至少 1，当天到期也说 1 天）
    func daysLeft(now: Date = Date()) -> Int {
        guard let edited = ISO8601DateFormatter().date(from: editedAt) else { return Self.keepDays }
        let left = Double(Self.keepDays) - now.timeIntervalSince(edited) / 86_400
        return max(1, Int(left.rounded(.up)))
    }

    static func encodeIds(_ ids: [Int64]) -> String {
        String(decoding: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), as: UTF8.self)
    }
}

/// 编辑前这场会议的样子（§81.3）：字段、所有句子（含精简版、校正建议）、标记重点、说话者、参考文件的 id
struct EditSnapshot: Codable {
    struct CoachEvidence: Codable {
        var id: String
        var time: Double?
    }
    struct Line: Codable {
        var segment: Segment
        var clean: String?
        var corrections: [Correction]
    }
    var audioFile: String
    var durationSeconds: Int?
    var userNotes: String
    var notes: String?
    var notesBy: String?
    var notesDraft: Int
    var createdAt: String
    var meetingDate: String
    var participants: String
    var lines: [Line]
    var bookmarks: [Bookmark]
    var speakers: [SpeakerName]
    var documentIds: [Int64]
    /// 可选以兼容没有助手依据的旧格式快照。
    var coachEvidence: [CoachEvidence]? = nil
}

extension AppDatabase {
    struct EditOutcome {
        var meeting: Meeting
        /// 分成两场时分出去的那场
        var created: Meeting?
        /// 第一次编辑：原本的录音要搬到 audio/edits/（之后的编辑，旧的录音直接删）
        var firstEdit: Bool
        /// 合并时复制过来的参考文件：documents/ 底下的来源 → 目的
        var documentCopies: [(from: String, to: String)]
    }

    struct RestoreOutcome {
        /// 现在的录音（要删），audio/ 底下的文件名
        var currentAudio: String
        /// 快照的录音（audio/edits/…）要搬回 audio/<这个名字>；没有录音是空字符串
        var editsAudio: String
        var restoredAudio: String
        var trashed: [Int64]
        var untrashed: [Int64]
        var removedDocuments: [String]
    }

    func editRecord(_ meetingId: Int64) throws -> MeetingEditRecord? {
        try pool.read { db in try MeetingEditRecord.fetchOne(db, key: meetingId) }
    }

    func expiredEdits(olderThan days: Int) throws -> [MeetingEditRecord] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).ISO8601Format()
        return try pool.read { db in try MeetingEditRecord.filter(Column("edited_at") < cutoff).fetchAll(db) }
    }

    func deleteEditRecord(_ meetingId: Int64) throws {
        try pool.write { db in _ = try MeetingEditRecord.deleteOne(db, key: meetingId) }
    }

    #if DEBUG
    /// DEBUG 的 editage：把最后编辑的时间改早，测 30 天的清除
    func ageEdit(_ meetingId: Int64, days: Double) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meeting_edits SET edited_at = ? WHERE meeting_id = ?",
                           arguments: [Date().addingTimeInterval(-days * 86_400).ISO8601Format(), meetingId])
        }
    }
    #endif

    /// 还在用的编辑前录音（audio/ 底下的相对路径），清 audio/edits/ 时留着
    func editAudioFiles() throws -> Set<String> {
        try pool.read { db in Set(try String.fetchAll(db, sql: "SELECT audio_file FROM meeting_edits WHERE audio_file <> ''")) }
    }

    /// 套用编辑（R107.7、design §81.1）：一个交易改这场的句子、标记重点、说话者、笔记、会议记录的时间；
    /// 合并时另一场的资料复制过来、那场移到垃圾桶；cut 有值时接着分成两场（新时间轴上的时间）。
    /// audioExtension 是新录音的扩展名（没有录音是 nil）；录音档由调用的人搬
    func applyEdit(_ id: Int64, plan: EditPlan, cut: Double?, splitTitle: String, audioExtension: String?) throws -> EditOutcome? {
        try pool.write { db -> EditOutcome? in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return nil }
            let now = Clock.now()
            let others = plan.pieces.map(\.meetingId).reduce(into: [Int64]()) { if $1 != id && !$0.contains($1) { $0.append($1) } }

            // 快照：第一次编辑才存（§81.3）
            var record = try MeetingEditRecord.fetchOne(db, key: id)
            let firstEdit = record == nil
            if record == nil {
                let ext = (meeting.audioFile as NSString).pathExtension
                record = MeetingEditRecord(meetingId: id, snapshot: try Self.snapshot(db, meeting),
                                           audioFile: meeting.audioFile.isEmpty ? "" : "edits/\(id).\(ext)", createdAt: now, editedAt: now)
            }
            record!.editedAt = now
            record!.mergedFrom = MeetingEditRecord.encodeIds(record!.mergedIds + others.filter { !record!.mergedIds.contains($0) })

            // 说话者时间的比例（§81.1）：每个说话者正式逐字稿留下的长度 ÷ 原本的长度
            var spoken: [Int64: [Int: (before: Double, after: Double)]] = [:]
            func count(_ meetingId: Int64, _ segment: Segment, kept: (start: Double, end: Double)?) {
                guard segment.kind == "final", let idx = segment.speaker else { return }
                var entry = spoken[meetingId, default: [:]][idx, default: (0, 0)]
                entry.before += max(0, segment.end - segment.start)
                if let kept { entry.after += max(0, kept.end - kept.start) }
                spoken[meetingId, default: [:]][idx] = entry
            }

            // 这场的句子：留下的改时间，其余删掉（精简版、校正建议跟着 ON DELETE CASCADE）
            try Self.unindexSegments(db, meetingId: id)
            for segment in try Segment.filter(Column("meeting_id") == id).fetchAll(db) {
                let kept = plan.mapSentence(id, start: segment.start, end: segment.end)
                count(id, segment, kept: kept)
                if let kept {
                    try db.execute(sql: "UPDATE segments SET start = ?, end = ? WHERE id = ?", arguments: [kept.start, kept.end, segment.id])
                } else {
                    _ = try Segment.deleteOne(db, key: segment.id!)
                }
            }
            for bookmark in try Bookmark.filter(Column("meeting_id") == id).fetchAll(db) {
                if let t = plan.map(id, bookmark.time) {
                    try db.execute(sql: "UPDATE bookmarks SET time = ? WHERE id = ?", arguments: [t, bookmark.id])
                } else {
                    _ = try Bookmark.deleteOne(db, key: bookmark.id!)
                }
            }

            // 合并：另一场的说话者对起来，句子、标记、参考文件复制过来（§81.4）
            var documentCopies: [(from: String, to: String)] = []
            var notesParts: [(order: Int, text: String)] = []
            let order = { (meetingId: Int64) in plan.pieces.firstIndex { $0.meetingId == meetingId } ?? 0 }
            notesParts.append((order(id), plan.remapUserNotes(meeting.userNotes, meetingId: id)))
            var participants = meeting.participantList
            var addedSeconds: [Int: Double] = [:]
            for other in others {
                guard let source = try Meeting.fetchOne(db, key: other) else { continue }
                let speakerMap = try Self.mergeSpeakers(db, into: id, from: other, language: meeting.meetingLanguage)
                for segment in try Segment.filter(Column("meeting_id") == other).order(Column("seq")).fetchAll(db) {
                    let kept = plan.mapSentence(other, start: segment.start, end: segment.end)
                    count(other, segment, kept: kept)
                    guard let kept else { continue }
                    var copy = segment
                    copy.id = nil
                    copy.meetingId = id
                    copy.start = kept.start
                    copy.end = kept.end
                    copy.speaker = segment.speaker.flatMap { speakerMap[$0] }
                    try copy.insert(db)
                    if let clean = try String.fetchOne(db, sql: "SELECT text FROM clean_lines WHERE segment_id = ?", arguments: [segment.id]) {
                        try db.execute(sql: "INSERT INTO clean_lines (segment_id, text) VALUES (?, ?)", arguments: [copy.id, clean])
                    }
                    for var correction in try Correction.filter(Column("segment_id") == segment.id).fetchAll(db) {
                        correction.id = nil
                        correction.meetingId = id
                        correction.segmentId = copy.id!
                        try correction.insert(db)
                    }
                }
                for bookmark in try Bookmark.filter(Column("meeting_id") == other).fetchAll(db) {
                    guard let t = plan.map(other, bookmark.time) else { continue }
                    var copy = Bookmark(meetingId: id, time: t, label: bookmark.label)
                    try copy.insert(db)
                }
                for document in try MeetingDocument.filter(Column("meeting_id") == other).order(Column("id")).fetchAll(db) {
                    var copy = document
                    copy.id = nil
                    copy.meetingId = id
                    copy.createdAt = now
                    try copy.insert(db)
                    copy.file = "\(copy.id!)/\(document.name)"
                    try copy.update(db)
                    documentCopies.append((document.file, copy.file))
                }
                notesParts.append((order(other), plan.remapUserNotes(source.userNotes, meetingId: other)))
                for name in source.participantList where !participants.contains(name) { participants.append(name) }
                for (from, to) in speakerMap {
                    let ratio = spoken[other]?[from].map { $0.before > 0 ? $0.after / $0.before : 1 } ?? 1
                    let seconds = try Double.fetchOne(db, sql: "SELECT speech_seconds FROM speakers WHERE meeting_id = ? AND idx = ?",
                                                      arguments: [other, from]) ?? 0
                    addedSeconds[to, default: 0] += seconds * ratio
                }
                try db.execute(sql: "UPDATE meetings SET deleted_at = ? WHERE id = ?", arguments: [now, other])
            }

            // 句子照新的时间重新编号（正式、实时各自）
            for kind in ["final", "live"] {
                let ids = try Int64.fetchAll(db, sql: "SELECT id FROM segments WHERE meeting_id = ? AND kind = ? ORDER BY start, seq, id",
                                             arguments: [id, kind])
                for (seq, segmentId) in ids.enumerated() {
                    try db.execute(sql: "UPDATE segments SET seq = ? WHERE id = ?", arguments: [seq, segmentId])
                }
            }

            // 说话者：没有句子的拿掉（声纹、人物留着，还原时才放得回去）；说话时间照留下的比例
            for speaker in try SpeakerName.filter(Column("meeting_id") == id).fetchAll(db) {
                let speaks = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM segments WHERE meeting_id = ? AND speaker = ?)",
                                               arguments: [id, speaker.idx]) ?? false
                if !speaks {
                    try db.execute(sql: "DELETE FROM speakers WHERE meeting_id = ? AND idx = ?", arguments: [id, speaker.idx])
                    continue
                }
                let ratio = spoken[id]?[speaker.idx].map { $0.before > 0 ? $0.after / $0.before : 1 } ?? 1
                let seconds = (speaker.speechSeconds * ratio) + (addedSeconds[speaker.idx] ?? 0)
                try db.execute(sql: "UPDATE speakers SET speech_seconds = ? WHERE meeting_id = ? AND idx = ?",
                               arguments: [seconds, id, speaker.idx])
            }

            // 会议记录：旧的存成版本，时间点先移到切口（刷新之前议题时间轴大致对得上）
            if !plan.keepsWhole(id), let notes = meeting.decodedNotes, let old = meeting.notes {
                var version = NotesVersion(meetingId: id, notes: old, reason: String(localized: "编辑会议前"))
                try version.insert(db)
                let mapped = notes.mappingTimes { plan.snap(id, $0) }
                meeting.notes = mapped.jsonString()
            }
            meeting.userNotes = notesParts.sorted { $0.order < $1.order }.map(\.text)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
            if participants != meeting.participantList {
                meeting.participants = participants.joined(separator: meeting.participants.contains("、") ? "、" : ", ")  // l10n-skip
            }
            // 开始时间：第一个片段那场的开始加上裁掉的秒数；日期跟着那场
            if let first = plan.pieces.first, let owner = try Meeting.fetchOne(db, key: first.meetingId),
               let started = ISO8601DateFormatter().date(from: owner.createdAt) {
                meeting.createdAt = started.addingTimeInterval(first.start).ISO8601Format()
                meeting.meetingDate = owner.meetingDate
            }
            meeting.durationSeconds = Int(plan.duration.rounded())
            if let audioExtension { meeting.audioFile = "\(id).\(audioExtension)" }
            meeting.updatedAt = now
            try meeting.update(db)
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [id])
            try Self.reindexMeeting(db, meeting)

            var created: Meeting?
            if let cut, let split = try Self.splitMeeting(db, id, at: cut, title: splitTitle, audioExtension: audioExtension) {
                created = split
                record!.splitInto = MeetingEditRecord.encodeIds(record!.splitIds + [split.id!])
                meeting = try Meeting.fetchOne(db, key: id) ?? meeting
            }
            // 助手的依据时间必须跟着编辑后的录音；被删掉或分到另一场的依据不再链接到本场。
            if var assistance = try Self.assistance(db, id) {
                for i in assistance.questions.indices {
                    guard let time = assistance.questions[i].time else { continue }
                    let mapped = plan.map(id, time)
                    assistance.questions[i].time = mapped.flatMap { t in
                        if created != nil, let cut, t >= cut { return nil }
                        return t
                    }
                }
                try Self.saveAssistance(db, id, assistance)
            }
            try record!.save(db)
            return EditOutcome(meeting: meeting, created: created, firstEdit: firstEdit, documentCopies: documentCopies)
        }
    }

    /// 还原成编辑前的样子（R107.8）：照快照放回字段、句子、标记、说话者，删掉编辑后加进来的参考文件；
    /// 分出去的移到垃圾桶、合并进来的从垃圾桶拿出来。录音档由调用的人搬
    func restoreEdit(_ id: Int64) throws -> RestoreOutcome? {
        try pool.write { db -> RestoreOutcome? in
            guard let record = try MeetingEditRecord.fetchOne(db, key: id), var meeting = try Meeting.fetchOne(db, key: id),
                  let snapshot = try? JSONDecoder().decode(EditSnapshot.self, from: Data(record.snapshot.utf8)) else { return nil }
            let now = Clock.now()
            let currentAudio = meeting.audioFile

            try Self.unindexSegments(db, meetingId: id)
            try db.execute(sql: "DELETE FROM segments WHERE meeting_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM bookmarks WHERE meeting_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM speakers WHERE meeting_id = ?", arguments: [id])
            // 句子用新的 id 放回（分出去的那场可能还用着原本的 id）
            for line in snapshot.lines {
                var segment = line.segment
                segment.id = nil
                segment.meetingId = id
                try segment.insert(db)
                if let clean = line.clean {
                    try db.execute(sql: "INSERT INTO clean_lines (segment_id, text) VALUES (?, ?)", arguments: [segment.id, clean])
                }
                for var correction in line.corrections {
                    correction.id = nil
                    correction.meetingId = id
                    correction.segmentId = segment.id!
                    try correction.insert(db)
                }
            }
            for var bookmark in snapshot.bookmarks {
                bookmark.id = nil
                bookmark.meetingId = id
                try bookmark.insert(db)
            }
            for var speaker in snapshot.speakers {
                speaker.meetingId = id
                if let person = speaker.personId,
                   !(try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM people WHERE id = ?)", arguments: [person]) ?? false) {
                    speaker.personId = nil
                }
                try speaker.insert(db)
            }
            var removedDocuments: [String] = []
            for document in try MeetingDocument.filter(Column("meeting_id") == id).fetchAll(db) where !snapshot.documentIds.contains(document.id!) {
                _ = try MeetingDocument.deleteOne(db, key: document.id!)
                removedDocuments.append(document.file)
            }

            if let notes = meeting.notes, notes != snapshot.notes {
                var version = NotesVersion(meetingId: id, notes: notes, reason: String(localized: "还原编辑前"))
                try version.insert(db)
            }
            meeting.notes = snapshot.notes
            meeting.notesBy = snapshot.notesBy
            meeting.notesDraft = snapshot.notesDraft
            meeting.userNotes = snapshot.userNotes
            meeting.durationSeconds = snapshot.durationSeconds
            meeting.createdAt = snapshot.createdAt
            meeting.meetingDate = snapshot.meetingDate
            meeting.participants = snapshot.participants
            meeting.audioFile = record.audioFile.isEmpty ? "" : snapshot.audioFile
            meeting.updatedAt = now
            try meeting.update(db)
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [id])
            try Self.reindexMeeting(db, meeting)

            var trashed: [Int64] = [], untrashed: [Int64] = []
            for other in record.splitIds {
                guard let split = try Meeting.fetchOne(db, key: other), split.deletedAt == nil else { continue }
                try db.execute(sql: "UPDATE meetings SET deleted_at = ? WHERE id = ?", arguments: [now, other])
                trashed.append(other)
            }
            for other in record.mergedIds {
                guard let merged = try Meeting.fetchOne(db, key: other), merged.deletedAt != nil else { continue }
                try db.execute(sql: "UPDATE meetings SET deleted_at = NULL WHERE id = ?", arguments: [other])
                untrashed.append(other)
            }
            // 只恢复原依据时间，保留用户在编辑后对问题状态的调整。
            if let evidence = snapshot.coachEvidence, var assistance = try Self.assistance(db, id) {
                for i in assistance.questions.indices {
                    if let original = evidence.first(where: { $0.id == assistance.questions[i].id }) {
                        assistance.questions[i].time = original.time
                    }
                }
                try Self.saveAssistance(db, id, assistance)
            }
            _ = try MeetingEditRecord.deleteOne(db, key: id)
            return RestoreOutcome(currentAudio: currentAudio, editsAudio: record.audioFile, restoredAudio: meeting.audioFile,
                                  trashed: trashed, untrashed: untrashed, removedDocuments: removedDocuments)
        }
    }

    private static func snapshot(_ db: Database, _ meeting: Meeting) throws -> String {
        let id = meeting.id!
        let lines = try Segment.filter(Column("meeting_id") == id).order(Column("kind"), Column("seq")).fetchAll(db).map { segment in
            EditSnapshot.Line(segment: segment,
                              clean: try String.fetchOne(db, sql: "SELECT text FROM clean_lines WHERE segment_id = ?", arguments: [segment.id]),
                              corrections: try Correction.filter(Column("segment_id") == segment.id).order(Column("id")).fetchAll(db))
        }
        let snapshot = EditSnapshot(
            audioFile: meeting.audioFile, durationSeconds: meeting.durationSeconds, userNotes: meeting.userNotes, notes: meeting.notes,
            notesBy: meeting.notesBy, notesDraft: meeting.notesDraft, createdAt: meeting.createdAt, meetingDate: meeting.meetingDate,
            participants: meeting.participants, lines: lines,
            bookmarks: try Bookmark.filter(Column("meeting_id") == id).order(Column("time")).fetchAll(db),
            speakers: try SpeakerName.filter(Column("meeting_id") == id).order(Column("idx")).fetchAll(db),
            documentIds: try Int64.fetchAll(db, sql: "SELECT id FROM documents WHERE meeting_id = ? ORDER BY id", arguments: [id]),
            coachEvidence: try Self.assistance(db, id)?.questions.map { EditSnapshot.CoachEvidence(id: $0.id, time: $0.time) })
        return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    }

    /// 合并时另一场的说话者对到这场（§81.4）：同一个人物 → 同样的名字（不是默认的）→ 声纹（门槛同声纹比对）；
    /// 都对不上的接在后面。回传另一场的编号 → 这场的编号
    private static func mergeSpeakers(_ db: Database, into id: Int64, from other: Int64, language: MeetingLanguage) throws -> [Int: Int] {
        var mine = try SpeakerName.filter(Column("meeting_id") == id).order(Column("idx")).fetchAll(db)
        let theirs = try SpeakerName.filter(Column("meeting_id") == other).order(Column("idx")).fetchAll(db)
        var map: [Int: Int] = [:]
        var taken = Set<Int>()
        func claim(_ from: Int, _ to: Int) { map[from] = to; taken.insert(to) }
        for s in theirs {
            if let person = s.personId, let match = mine.first(where: { $0.personId == person && !taken.contains($0.idx) }) {
                claim(s.idx, match.idx)
            }
        }
        for s in theirs where map[s.idx] == nil && s.nameSource != "default" {
            let name = s.name.lowercased()
            if let match = mine.first(where: { $0.nameSource != "default" && $0.name.lowercased() == name && !taken.contains($0.idx) }) {
                claim(s.idx, match.idx)
            }
        }
        for s in theirs where map[s.idx] == nil {
            guard let data = s.embedding else { continue }
            let vector = Voiceprint.vector(data)
            let best = mine.filter { !taken.contains($0.idx) }.compactMap { m -> (Int, Double)? in
                m.embedding.map { (m.idx, Voiceprint.similarity(vector, Voiceprint.vector($0))) }
            }.max { $0.1 < $1.1 }
            if let best, best.1 >= voiceprintThreshold { claim(s.idx, best.0) }
        }
        var next = (mine.map(\.idx).max() ?? 0) + 1
        for s in theirs where map[s.idx] == nil {
            var copy = s
            copy.meetingId = id
            copy.idx = next
            if s.nameSource == "default" { copy.name = language.defaultSpeaker(next) }
            copy.speechSeconds = 0   // 套用时照留下的比例加上去
            try copy.insert(db)
            mine.append(copy)
            claim(s.idx, next)
            next += 1
        }
        return map
    }

    /// 这场会议的搜索索引全部重建（句子、标题、笔记、会议记录）
    static func reindexMeeting(_ db: Database, _ meeting: Meeting) throws {
        let id = meeting.id!
        try unindexSegments(db, meetingId: id)
        try unindexMeeting(db, meetingId: id)
        try db.execute(sql: "INSERT INTO search (rowid, meeting_id, kind, ref, text) SELECT id, meeting_id, 'segment', id, text FROM segments WHERE meeting_id = ?",
                       arguments: [id])
        try index(db, meetingId: id, kind: .title, ref: 0, text: meeting.displayTitle)
        try index(db, meetingId: id, kind: .userNotes, ref: 0, text: meeting.userNotes)
        if let notes = meeting.decodedNotes { try index(db, meetingId: id, kind: .notes, ref: 0, text: notes.plainText) }
    }
}
