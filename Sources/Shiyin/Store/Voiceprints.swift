import Foundation
import GRDB

/// 认识的人（design §21.4）：用户替说话者取过名字的人
struct Person: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "people"
    var id: Int64?
    var name: String
    var createdAt: String = Clock.now()

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 设置页的认识的人：几份声纹、最近出现在哪场会议
struct PersonSummary: Identifiable, Hashable {
    var id: Int64
    var name: String
    var voiceprintCount: Int
    var lastMeetingTitle: String?
    var lastMeetingDate: String?
}

/// 声纹的比对与学习（design §21.4、R19.3、D29）。都在本机的数据库里做，不上传
extension AppDatabase {
    /// 说话少于这个秒数不比对、不学：太短的声纹不准
    static let voiceprintMinimumSeconds = 8.0
    /// 相似度门槛（cosine）：AMI 评估（design §21.4.1）同一个人最低 0.81、不同的人最高 0.42，
    /// 取中间偏高，宁可少带入、不要带错。到这里算候选，没到直接带入的门槛就在待确认问（R33）
    static let voiceprintThreshold = 0.65
    /// 直接带入：很像（用户的资料里不同的人可以像到 0.77、0.85），而且比第二像的人高出一截（design §21.4.1、D91）
    static let voiceprintAutoThreshold = 0.88
    static let voiceprintAutoMargin = 0.15
    /// 同一个人的声纹最多留几份，超过删最旧的
    static let voiceprintsPerPerson = 30

    /// 转录完：还是默认名称的说话者跟认识的人比对。很有把握的自动带入名字（name_source = voiceprint），
    /// 够像但没把握的存成说话者的建议，在待确认问（R33、D91）。
    /// 一个人在一场会议只对到一位说话者，依相似度由高到低分配。回传带入了几位
    @discardableResult
    func matchVoiceprints(_ meetingId: Int64) throws -> Int {
        try pool.write { db in
            let speakers = try SpeakerName.filter(Column("meeting_id") == meetingId).fetchAll(db)
                .filter { $0.nameSource == "default" && $0.embedding != nil && $0.speechSeconds >= Self.voiceprintMinimumSeconds }
            guard !speakers.isEmpty else { return 0 }
            let library = try Self.library(db)
            guard !library.isEmpty else { return 0 }
            var candidates: [(score: Double, idx: Int, person: Int64)] = []
            var scores: [Int: [Int64: Double]] = [:]
            for speaker in speakers {
                let vector = Voiceprint.vector(speaker.embedding!)
                for (person, prints) in library {
                    let score = prints.map { Voiceprint.similarity(vector, $0) }.max() ?? 0
                    scores[speaker.idx, default: [:]][person] = score
                    if score >= Self.voiceprintThreshold { candidates.append((score, speaker.idx, person)) }
                }
            }
            let language = try Meeting.fetchOne(db, key: meetingId)?.meetingLanguage ?? .zh
            var usedSpeakers = Set<Int>(), usedPeople = Set<Int64>()
            // 已经手动取名、对到某人的说话者，那个人就不再带给别人
            for row in try SpeakerName.filter(Column("meeting_id") == meetingId && Column("person_id") != nil).fetchAll(db) {
                if let person = row.personId { usedPeople.insert(person) }
            }
            var matched = 0
            for candidate in candidates.sorted(by: { $0.score > $1.score }) {
                guard !usedSpeakers.contains(candidate.idx), !usedPeople.contains(candidate.person),
                      let name = try String.fetchOne(db, sql: "SELECT name FROM people WHERE id = ?", arguments: [candidate.person]) else { continue }
                usedSpeakers.insert(candidate.idx)
                usedPeople.insert(candidate.person)
                let second = scores[candidate.idx]?.filter { $0.key != candidate.person }.values.max() ?? 0
                if candidate.score >= Self.voiceprintAutoThreshold && candidate.score - second >= Self.voiceprintAutoMargin {
                    try db.execute(sql: "UPDATE speakers SET name = ?, name_source = 'voiceprint', person_id = ? WHERE meeting_id = ? AND idx = ?",
                                   arguments: [name, candidate.person, meetingId, candidate.idx])
                    matched += 1
                } else {
                    // 没把握：不带入，存成建议，在待确认问「说话者 N 是 X 吗？」（design §27）
                    let reason = language.format(zh: "声音跟之前的%@很像", en: "Sounds like %@ from earlier meetings",
                                                 ja: "以前の%@の声に似ています", name)  // l10n-skip：会议语言的原因
                    try db.execute(sql: """
                        UPDATE speakers SET suggested_name = ?, suggestion_reason = ?, suggestion_time = NULL
                        WHERE meeting_id = ? AND idx = ? AND name_source = 'default'
                        """, arguments: [name, reason, meetingId, candidate.idx])
                }
            }
            return matched
        }
    }

    /// 每位说话者最像的几位认识的人（不含目前的名字），由高到低：「是别人」的菜单、待确认的「不是」用（R33）
    func voiceprintCandidates(_ meetingId: Int64, limit: Int = 3) throws -> [Int: [String]] {
        try pool.read { db in
            let speakers = try SpeakerName.filter(Column("meeting_id") == meetingId).fetchAll(db)
                .filter { $0.embedding != nil && $0.speechSeconds >= Self.voiceprintMinimumSeconds }
            guard !speakers.isEmpty else { return [:] }
            let library = try Self.library(db)
            guard !library.isEmpty else { return [:] }
            let names = Dictionary(try Person.fetchAll(db).compactMap { p in p.id.map { ($0, p.name) } }, uniquingKeysWith: { a, _ in a })
            var result: [Int: [String]] = [:]
            for speaker in speakers {
                let vector = Voiceprint.vector(speaker.embedding!)
                let ranked = library.compactMap { person, prints -> (name: String, score: Double)? in
                    guard let name = names[person], name.caseInsensitiveCompare(speaker.name) != .orderedSame else { return nil }
                    return (name, prints.map { Voiceprint.similarity(vector, $0) }.max() ?? 0)
                }
                result[speaker.idx] = ranked.sorted { $0.score > $1.score }.prefix(limit).map(\.name)
            }
            return result
        }
    }

    /// 所有认识的人的声纹
    private static func library(_ db: Database) throws -> [Int64: [[Float]]] {
        var result: [Int64: [[Float]]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT person_id, embedding FROM voiceprints") {
            let data: Data = row["embedding"]
            result[row["person_id"], default: []].append(Voiceprint.vector(data))
        }
        return result
    }

    /// 说话者被取名（手动、套用建议）之后：连到同名的人（没有就创建），把这场会议的声纹存起来（design §21.4）。
    /// 名字是默认的「说话者 N」时，取消链接、删掉这场会议这位说话者存过的声纹
    func learnVoiceprint(_ meetingId: Int64, idx: Int, name: String, source: String = "manual") throws {
        try pool.write { db in
            // 这位说话者之前存过的声纹（例如改正自动带入的名字）先删掉
            try db.execute(sql: "DELETE FROM voiceprints WHERE meeting_id = ? AND speaker_idx = ?", arguments: [meetingId, idx])
            guard !Self.isDefaultSpeakerName(name) else {
                try db.execute(sql: "UPDATE speakers SET person_id = NULL WHERE meeting_id = ? AND idx = ?", arguments: [meetingId, idx])
                try Self.deleteOrphanPeople(db)
                return
            }
            var person = try Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db)
            if person == nil {
                var created = Person(name: name)
                try created.insert(db)
                person = created
            }
            guard let personId = person?.id else { return }
            try db.execute(sql: "UPDATE speakers SET person_id = ?, name_source = ? WHERE meeting_id = ? AND idx = ?",
                           arguments: [personId, source, meetingId, idx])
            guard let speaker = try SpeakerName.filter(Column("meeting_id") == meetingId && Column("idx") == idx).fetchOne(db),
                  let embedding = speaker.embedding, speaker.speechSeconds >= Self.voiceprintMinimumSeconds else { return }
            let vector = Voiceprint.vector(embedding)
            let existing = try Row.fetchAll(db, sql: "SELECT embedding FROM voiceprints WHERE person_id = ?", arguments: [personId])
                .map { Voiceprint.vector($0["embedding"] as Data) }
            // 跟已有的某份几乎一样就不重复存
            guard !existing.contains(where: { Voiceprint.similarity(vector, $0) > 0.95 }) else { return }
            try db.execute(sql: """
                INSERT INTO voiceprints (person_id, embedding, audio_source, meeting_id, speaker_idx, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [personId, embedding, speaker.audioSource, meetingId, idx, Clock.now()])
            try db.execute(sql: """
                DELETE FROM voiceprints WHERE person_id = ? AND id NOT IN
                  (SELECT id FROM voiceprints WHERE person_id = ? ORDER BY id DESC LIMIT ?)
                """, arguments: [personId, personId, Self.voiceprintsPerPerson])
        }
    }

    /// 这场会议说话者识别至少分出几个人（design §23.2），nil 自动判断
    func setMinSpeakers(_ meetingId: Int64, _ minSpeakers: Int?) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET min_speakers = ? WHERE id = ?", arguments: [minSpeakers, meetingId])
        }
    }

    /// 重新识别说话者（design §23.3）：段落换成新的说话者；删掉这场存过的声纹（旧的分群可能混了两个人）；
    /// 重建这场的说话者，inherited 的沿用名字，其他用默认名称，声纹、说话秒数照新的结果
    func reassignSpeakers(_ meetingId: Int64, segmentSpeakers: [(id: Int64, speaker: Int?)], voices: [Int: SpeakerVoice],
                          inherited: [Int: (name: String, source: String, personId: Int64?)]) throws {
        try pool.write { db in
            for item in segmentSpeakers {
                try db.execute(sql: "UPDATE segments SET speaker = ? WHERE id = ?", arguments: [item.speaker, item.id])
            }
            try db.execute(sql: "DELETE FROM voiceprints WHERE meeting_id = ?", arguments: [meetingId])
            let language = try Meeting.fetchOne(db, key: meetingId)?.meetingLanguage ?? .zh
            try SpeakerName.filter(Column("meeting_id") == meetingId).deleteAll(db)
            let count = segmentSpeakers.compactMap(\.speaker).max() ?? 0
            for idx in stride(from: 1, through: count, by: 1) {
                var speaker = SpeakerName(meetingId: meetingId, idx: idx,
                                          name: language.defaultSpeaker(idx))
                if let old = inherited[idx] {
                    speaker.name = old.name
                    speaker.nameSource = old.source
                    speaker.personId = old.personId
                }
                if let voice = voices[idx] {
                    speaker.embedding = Voiceprint.data(voice.embedding)
                    speaker.speechSeconds = voice.seconds
                    speaker.audioSource = voice.source
                }
                try speaker.insert(db)
            }
            try Self.deleteOrphanPeople(db)
            // 旧的复原资料对不上新的说话者了（design §24.2）
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId])
            try db.execute(sql: "UPDATE meetings SET updated_at = ? WHERE id = ?", arguments: [Clock.now(), meetingId])
        }
    }

    /// 「不是他」：自动带入的名字不对，回到默认名称；之后重新比对也不再带入这位（name_source = manual）
    func rejectVoiceprintMatch(_ meetingId: Int64, idx: Int, defaultName: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE speakers SET name = ?, name_source = 'manual', person_id = NULL WHERE meeting_id = ? AND idx = ?",
                           arguments: [defaultName, meetingId, idx])
            try db.execute(sql: "DELETE FROM voiceprints WHERE meeting_id = ? AND speaker_idx = ?", arguments: [meetingId, idx])
            try Self.deleteOrphanPeople(db)
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId])
        }
    }

    /// 没有声纹、也没有连到任何说话者的人（例如取名后又改回去），不留在认识的人里
    static func deleteOrphanPeople(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM people WHERE id NOT IN (SELECT person_id FROM voiceprints)
              AND id NOT IN (SELECT person_id FROM speakers WHERE person_id IS NOT NULL)
            """)
    }

    // MARK: 猜说话者（design §21.5）

    /// 存 AI 猜的名字：只写还是默认名称、还没有建议的说话者（声纹的建议优先：有声音当根据，design §27）
    func saveSpeakerSuggestions(_ meetingId: Int64, _ suggestions: [SpeakerNaming.Suggestion]) throws {
        try pool.write { db in
            for s in suggestions {
                try db.execute(sql: """
                    UPDATE speakers SET suggested_name = ?, suggestion_reason = ?, suggestion_time = ?
                    WHERE meeting_id = ? AND idx = ? AND name_source = 'default' AND suggested_name IS NULL
                    """, arguments: [s.name, s.reason, s.time, meetingId, s.speaker])
            }
        }
    }

    func clearSpeakerSuggestion(_ meetingId: Int64, idx: Int) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE speakers SET suggested_name = NULL, suggestion_reason = NULL, suggestion_time = NULL WHERE meeting_id = ? AND idx = ?",
                           arguments: [meetingId, idx])
        }
    }

    /// 说话者改名后，会议记录里的旧名字换成新名字（design §21.6）；有改到就存一版，回传是否有改
    @discardableResult
    func replaceSpeakerNameInNotes(_ meetingId: Int64, from old: String, to new: String) throws -> Bool {
        guard old != new, let meeting = try self.meeting(meetingId), let notes = meeting.decodedNotes else { return false }
        let updated = notes.replacingSpeakerName(old, with: new, isDefaultName: Self.isDefaultSpeakerName(old))
        guard updated != notes else { return false }
        try saveNotes(meetingId, notes: updated, by: nil, reason: String(localized: "说话者改名"))
        return true
    }

    // MARK: 设置页：认识的人

    func peopleSummaries() throws -> [PersonSummary] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name,
                  (SELECT count(*) FROM voiceprints v WHERE v.person_id = p.id) AS prints,
                  (SELECT m.id FROM speakers s JOIN meetings m ON m.id = s.meeting_id
                     WHERE s.person_id = p.id AND m.deleted_at IS NULL ORDER BY m.meeting_date DESC LIMIT 1) AS last_id
                FROM people p ORDER BY p.name COLLATE NOCASE
                """).map { row in
                    // 没有标题的会议跟会议列表一样显示文件名
                    let last = try (row["last_id"] as Int64?).flatMap { try Meeting.fetchOne(db, key: $0) }
                    return PersonSummary(id: row["id"], name: row["name"], voiceprintCount: row["prints"],
                                         lastMeetingTitle: last?.displayTitle, lastMeetingDate: last?.meetingDate)
                }
        }
    }

    /// 改名：认识的人和所有连到他的说话者一起改；新名字已经有人用了就合并过去
    func renamePerson(_ id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try pool.write { db in
            if let other = try Person.filter(sql: "name = ? COLLATE NOCASE AND id <> ?", arguments: [trimmed, id]).fetchOne(db), let otherId = other.id {
                try db.execute(sql: "UPDATE voiceprints SET person_id = ? WHERE person_id = ?", arguments: [otherId, id])
                try db.execute(sql: "UPDATE speakers SET person_id = ?, name = ? WHERE person_id = ?", arguments: [otherId, other.name, id])
                try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
            } else {
                try db.execute(sql: "UPDATE people SET name = ? WHERE id = ?", arguments: [trimmed, id])
                try db.execute(sql: "UPDATE speakers SET name = ? WHERE person_id = ?", arguments: [trimmed, id])
            }
        }
    }

    /// 删除认识的人：声纹删掉（外键），已经带入的名字留着
    func deletePerson(_ id: Int64) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id]) }
    }

    func deleteAllPeople() throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM people") }
    }

    /// 认识的人的名字，给猜说话者参考写法
    func peopleNames() throws -> [String] {
        try pool.read { db in try String.fetchAll(db, sql: "SELECT name FROM people ORDER BY name COLLATE NOCASE") }
    }
}
