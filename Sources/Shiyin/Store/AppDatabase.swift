import Foundation
import GRDB

/// 列表用：会议加上推算状态所需的资料
struct MeetingRow: Identifiable, Hashable {
    var meeting: Meeting
    var latestJob: Job?
    var reviewCount: Int
    var id: Int64 { meeting.id ?? 0 }
}

struct ReplaceResult {
    var segmentsChanged: Int
    var notesChanged: Bool
}

/// 全文搜索的一笔结果（R9.1）
struct SearchHit: Identifiable, Hashable {
    enum Kind: String { case title, segment, notes, userNotes = "user_notes" }
    var meetingId: Int64
    var kind: Kind
    var ref: Int64            // segment 的 id；其他种类是 0
    var snippet: String
    var id: String { "\(meetingId)-\(kind.rawValue)-\(ref)" }
}

final class AppDatabase: @unchecked Sendable {
    let pool: DatabasePool
    /// 参考文档源文件的文件夹（design §39.1）；nil 时删除会议、文档不碰文件（标准答案的暂存数据库）
    let documentsRoot: URL?

    /// 打开数据库；有待执行的 migration 时，先把旧档备份到 backups/（N3）
    init(path: String, documentsRoot: URL? = nil) throws {
        self.documentsRoot = documentsRoot
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: path, configuration: config)
        let migrator = Self.migrator
        let applied = try pool.read { try migrator.appliedIdentifiers($0) }
        let pending = migrator.migrations.filter { !applied.contains($0) }
        if !applied.isEmpty && !pending.isEmpty {
            _ = try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try FileManager.default.createDirectory(at: Paths.backupsDir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let backup = Paths.backupsDir.appendingPathComponent("shiyin-\(stamp)-before-\(pending[0]).sqlite")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: backup)
            log.info("database backed up before migration \(pending[0])")
        }
        try migrator.migrate(pool)
    }

    enum ReadOnlyError: Error {
        /// 还有没跑的 migration：更新后还没开过拾音
        case needsUpgrade
        /// 数据库比这版程序新
        case newerDatabase
    }

    /// 只读（本地 MCP，design §44.1）：不跑 migration、不备份；数据库的版本跟这版程序不同就丢出错误。
    /// 旁边没有 -wal、-shm（拾音上次正常关闭）时唯读连接打不开（SQLite 14），改用一般连接：一样只读，SQLite 自己建那两个档
    init(readOnlyPath path: String) throws {
        documentsRoot = nil
        var config = Configuration()
        config.readonly = true
        do {
            pool = try DatabasePool(path: path, configuration: config)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            config.readonly = false
            pool = try DatabasePool(path: path, configuration: config)
        }
        let migrator = Self.migrator
        let (superseded, completed) = try pool.read { db in
            (try migrator.hasBeenSuperseded(db), try migrator.hasCompletedMigrations(db))
        }
        if superseded { throw ReadOnlyError.newerDatabase }
        if !completed { throw ReadOnlyError.needsUpgrade }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE meetings (
              id               INTEGER PRIMARY KEY AUTOINCREMENT,
              title            TEXT NOT NULL DEFAULT '',
              title_locked     INTEGER NOT NULL DEFAULT 0,
              meeting_date     TEXT NOT NULL,
              participants     TEXT NOT NULL DEFAULT '',
              source_filename  TEXT NOT NULL,
              audio_file       TEXT NOT NULL,
              duration_seconds INTEGER,
              notes            TEXT,
              notes_by         TEXT,
              created_at       TEXT NOT NULL,
              updated_at       TEXT NOT NULL
            );
            CREATE TABLE segments (
              id             INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id     INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              seq            INTEGER NOT NULL,
              start          REAL NOT NULL,
              end            REAL NOT NULL,
              text           TEXT NOT NULL,
              low_confidence INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX segments_meeting ON segments(meeting_id, seq);
            CREATE TABLE notes_versions (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              notes      TEXT NOT NULL,
              reason     TEXT NOT NULL,
              created_at TEXT NOT NULL
            );
            CREATE TABLE jobs (
              id          INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id  INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              kind        TEXT NOT NULL,
              status      TEXT NOT NULL,
              payload     TEXT,
              error       TEXT,
              created_at  TEXT NOT NULL,
              started_at  TEXT,
              finished_at TEXT
            );
            CREATE INDEX jobs_status ON jobs(status, id);
            CREATE INDEX jobs_meeting ON jobs(meeting_id, id);
            CREATE TABLE glossary (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              term       TEXT NOT NULL UNIQUE,
              created_at TEXT NOT NULL
            );
            """)
        }
        // 第三版（design §4）
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
            ALTER TABLE meetings ADD COLUMN template_id TEXT NOT NULL DEFAULT 'general';
            ALTER TABLE meetings ADD COLUMN user_notes  TEXT NOT NULL DEFAULT '';
            ALTER TABLE meetings ADD COLUMN source      TEXT NOT NULL DEFAULT 'import';
            ALTER TABLE meetings ADD COLUMN channels    TEXT NOT NULL DEFAULT 'mic';
            ALTER TABLE meetings ADD COLUMN deleted_at  TEXT;
            ALTER TABLE meetings ADD COLUMN folder      TEXT NOT NULL DEFAULT '';
            ALTER TABLE segments ADD COLUMN speaker INTEGER;
            ALTER TABLE segments ADD COLUMN kind TEXT NOT NULL DEFAULT 'final';
            CREATE TABLE speakers (
              meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              idx        INTEGER NOT NULL,
              name       TEXT NOT NULL,
              PRIMARY KEY (meeting_id, idx)
            );
            CREATE TABLE bookmarks (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              time       REAL NOT NULL,
              label      TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE templates (
              id         TEXT PRIMARY KEY,
              name       TEXT NOT NULL,
              builtin    INTEGER NOT NULL,
              definition TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE search USING fts5(meeting_id UNINDEXED, kind UNINDEXED, ref UNINDEXED, text, tokenize = 'trigram');
            """)
            // 会议记录转成 v2 格式（字符串数组 → 带时间点的条目，时间点先留空）
            for row in try Row.fetchAll(db, sql: "SELECT id, notes FROM meetings WHERE notes IS NOT NULL") {
                let id: Int64 = row["id"]
                guard let json: String = row["notes"], let notes = try? JSONDecoder().decode(MeetingNotes.self, from: Data(json.utf8))
                else { continue }
                try db.execute(sql: "UPDATE meetings SET notes = ? WHERE id = ?", arguments: [notes.jsonString(), id])
            }
            try Self.rebuildSearch(db)
        }
        // v3（design §16.3）：会议语言，旧会议都是中文
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN language TEXT NOT NULL DEFAULT 'zh'")
        }
        // 3.2：分声道转录记录每段来自哪个声道（design §17.3）
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE segments ADD COLUMN channel INTEGER")
        }
        // 3.2：逐字稿校正建议（design §17.4），段落重新转录时一起删掉；词汇表建议被忽略的词（§17.5）
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                CREATE TABLE corrections (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  segment_id INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                  original   TEXT NOT NULL,
                  suggestion TEXT NOT NULL,
                  reason     TEXT NOT NULL DEFAULT '',
                  status     TEXT NOT NULL DEFAULT 'pending',
                  created_at TEXT NOT NULL
                );
                CREATE INDEX corrections_meeting ON corrections(meeting_id);
                CREATE TABLE glossary_dismissed (term TEXT PRIMARY KEY COLLATE NOCASE);
                """)
        }
        // 3.4.1：工作执行时拾音意外结束的次数（design §20.5）；搜索表的 rowid 改成可以推算，重建索引（§20.11）
        migrator.registerMigration("v6") { db in
            try db.execute(sql: "ALTER TABLE jobs ADD COLUMN crashes INTEGER NOT NULL DEFAULT 0")
            try Self.rebuildSearch(db)
        }
        // 3.5（design §21.1）：草稿记录、声纹、猜说话者、提问、编辑草稿、反馈问题用的错误种类
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN notes_draft INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE meetings ADD COLUMN transcribed_with TEXT NOT NULL DEFAULT '';
                ALTER TABLE jobs ADD COLUMN error_kind TEXT;
                CREATE TABLE people (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
                  created_at TEXT NOT NULL
                );
                ALTER TABLE speakers ADD COLUMN name_source TEXT NOT NULL DEFAULT 'default';
                ALTER TABLE speakers ADD COLUMN person_id INTEGER REFERENCES people(id) ON DELETE SET NULL;
                ALTER TABLE speakers ADD COLUMN embedding BLOB;
                ALTER TABLE speakers ADD COLUMN speech_seconds REAL NOT NULL DEFAULT 0;
                ALTER TABLE speakers ADD COLUMN audio_source TEXT NOT NULL DEFAULT 'mix';
                ALTER TABLE speakers ADD COLUMN suggested_name TEXT;
                ALTER TABLE speakers ADD COLUMN suggestion_reason TEXT;
                ALTER TABLE speakers ADD COLUMN suggestion_time TEXT;
                UPDATE speakers SET name_source = 'manual'
                  WHERE name NOT GLOB '說話者 [0-9]*' AND name NOT GLOB 'Speaker [0-9]*' AND name NOT GLOB '話者 [0-9]*';
                CREATE TABLE voiceprints (
                  id           INTEGER PRIMARY KEY AUTOINCREMENT,
                  person_id    INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                  embedding    BLOB NOT NULL,
                  audio_source TEXT NOT NULL,
                  meeting_id   INTEGER REFERENCES meetings(id) ON DELETE SET NULL,
                  speaker_idx  INTEGER,
                  created_at   TEXT NOT NULL
                );
                CREATE INDEX voiceprints_person ON voiceprints(person_id);
                CREATE TABLE questions (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
                  scope      TEXT NOT NULL DEFAULT '',
                  question   TEXT NOT NULL,
                  answer     TEXT NOT NULL,
                  provider   TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );
                CREATE INDEX questions_meeting ON questions(meeting_id, id);
                CREATE TABLE drafts (
                  meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  key        TEXT NOT NULL,
                  text       TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY (meeting_id, key)
                );
                """)
        }
        // 说话者识别至少分出几个人（design §23.2、R22.3）
        migrator.registerMigration("v8") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN min_speakers INTEGER")
        }
        // 说话者的修正、分不准的提示（design §24.1）
        migrator.registerMigration("v9") { db in
            try db.execute(sql: """
                ALTER TABLE segments ADD COLUMN speaker_manual INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE meetings ADD COLUMN speaker_check REAL;
                ALTER TABLE meetings ADD COLUMN speaker_hint_dismissed INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE speaker_undo (
                  meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
                  snapshot   TEXT NOT NULL,
                  label      TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );
                """)
        }
        // 会议的参考文档（design §39.1、R61）
        migrator.registerMigration("v10") { db in
            try db.execute(sql: """
                CREATE TABLE documents (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  name       TEXT NOT NULL,
                  file       TEXT NOT NULL,
                  kind       TEXT NOT NULL,
                  pages      TEXT NOT NULL,
                  ocr        INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL
                );
                CREATE INDEX documents_meeting ON documents(meeting_id, id);
                """)
        }
        // 会前准备与会中提问助手（Mac 第一版，design §46）。
        migrator.registerMigration("v11") { db in
            try db.execute(sql: """
                CREATE TABLE meeting_assistance (
                  meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
                  state TEXT NOT NULL
                );
                """)
        }
        return migrator
    }

    // MARK: 会议

    func meetingRows(trash: Bool = false) throws -> [MeetingRow] {
        try pool.read { db in
            let meetings = try Meeting
                .filter(trash ? Column("deleted_at") != nil : Column("deleted_at") == nil)
                .order(sql: "meeting_date DESC, id DESC").fetchAll(db)
            // 背景的辅助工作（压缩、逐字稿校正、猜说话者、重新识别说话者）不算会议的状态（design §21.2、§23.3）
            let auxiliary = JobKind.allCases.filter(\.isAuxiliary).map { "'\($0.rawValue)'" }.joined(separator: ", ")
            let latest = try Job.fetchAll(db, sql: "SELECT * FROM jobs WHERE id IN (SELECT MAX(id) FROM jobs WHERE kind NOT IN (\(auxiliary)) GROUP BY meeting_id)")
            let byMeeting = Dictionary(uniqueKeysWithValues: latest.map { ($0.meetingId, $0) })
            // 待确认的题数也算说话者的建议（R33.3）
            let speakerQuestions = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT meeting_id, COUNT(*) AS n FROM speakers WHERE name_source = 'default' AND suggested_name IS NOT NULL GROUP BY meeting_id
                """).map { (Int64($0["meeting_id"] as Int64), Int($0["n"] as Int64)) })
            return meetings.map { m in
                MeetingRow(meeting: m, latestJob: byMeeting[m.id ?? 0],
                           reviewCount: (m.decodedNotes?.reviewItems.count ?? 0) + (speakerQuestions[m.id ?? 0] ?? 0))
            }
        }
    }

    func meeting(_ id: Int64) throws -> Meeting? {
        try pool.read { db in try Meeting.fetchOne(db, key: id) }
    }

    func segments(_ meetingId: Int64, kind: String = "final") throws -> [Segment] {
        try pool.read { db in
            try Segment.filter(Column("meeting_id") == meetingId && Column("kind") == kind).order(Column("seq")).fetchAll(db)
        }
    }

    /// 只读这几段（改一段文字、接受校正之后，design §21.12）
    func segments(ids: [Int64]) throws -> [Segment] {
        try pool.read { db in try Segment.filter(ids.contains(Column("id"))).fetchAll(db) }
    }

    func versionCount(_ meetingId: Int64) throws -> Int {
        try pool.read { db in try NotesVersion.filter(Column("meeting_id") == meetingId).fetchCount(db) }
    }

    func latestJob(_ meetingId: Int64) throws -> Job? {
        try pool.read { db in
            try Job.filter(Column("meeting_id") == meetingId && !JobKind.allCases.filter(\.isAuxiliary).map(\.rawValue).contains(Column("kind")))
                .order(Column("id").desc).fetchOne(db)
        }
    }

    /// 最后一次完成的转录只做到第几秒（没人说话太久而自动停止，design §35.3）；转录了全部是 nil
    func transcribedUntil(_ meetingId: Int64) throws -> Double? {
        try pool.read { db in
            let payload = try String.fetchOne(db, sql: """
                SELECT payload FROM jobs WHERE meeting_id = ? AND kind = 'transcribe' AND status = 'done' ORDER BY id DESC LIMIT 1
                """, arguments: [meetingId])
            return payload.flatMap { try? JSONDecoder().decode(TranscribePayload.self, from: Data($0.utf8)) }?.until
        }
    }

    /// 创建会议并给定录音文件名（需要先拿到 id 才能命名，所以在同一个交易里做两步）
    func insertMeeting(_ meeting: Meeting, audioExtension: String?) throws -> Meeting {
        try pool.write { db in
            var m = meeting
            try m.insert(db)
            if let audioExtension { m.audioFile = "\(m.id!).\(audioExtension)" }
            try m.update(db)
            try Self.index(db, meetingId: m.id!, kind: .title, ref: 0, text: m.displayTitle)
            return m
        }
    }

    func updateMeeting(_ meeting: Meeting) throws {
        try pool.write { db in
            var m = meeting
            m.updatedAt = Clock.now()
            try m.update(db)
            try Self.index(db, meetingId: m.id!, kind: .title, ref: 0, text: m.displayTitle)
            try Self.index(db, meetingId: m.id!, kind: .userNotes, ref: 0, text: m.userNotes)
        }
    }

    /// 文件夹（R9.2）：文件夹就是 meetings.folder 的值，空字符串表示不在任何文件夹
    func setFolder(_ ids: [Int64], folder: String) throws {
        guard !ids.isEmpty else { return }
        try pool.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE meetings SET folder = ?, updated_at = ? WHERE id = ?", arguments: [folder, Clock.now(), id])
            }
        }
    }

    /// 改名或删除（newName 为空字符串）一个文件夹，垃圾桶里的会议也一起改
    func renameFolder(_ old: String, to newName: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET folder = ?, updated_at = ? WHERE folder = ?", arguments: [newName, Clock.now(), old])
        }
    }

    /// 录音中途当掉、连录音档都没有的会议（design §20.6）
    func emptyRecordingMeetings() throws -> [Int64] {
        try pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM meetings WHERE source = 'recording' AND audio_file = '' AND deleted_at IS NULL")
        }
    }

    /// 永久删除（垃圾桶清除或用户确认）；参考文档的源文件一起删（design §39.1）
    func deleteMeeting(_ id: Int64) throws {
        let files = try pool.write { db -> [String] in
            let files = try MeetingDocument.filter(Column("meeting_id") == id).fetchAll(db).map(\.file)
            // 段落会跟着会议删掉（ON DELETE CASCADE），所以先删索引
            try Self.unindexSegments(db, meetingId: id)
            try Self.unindexMeeting(db, meetingId: id)
            _ = try Meeting.deleteOne(db, key: id)
            return files
        }
        files.forEach(removeDocumentFile)
    }

    /// 移到垃圾桶或还原（R9.3）
    func setTrashed(_ id: Int64, _ trashed: Bool) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET deleted_at = ? WHERE id = ?", arguments: [trashed ? Clock.now() : nil, id])
        }
    }

    func expiredTrash(olderThan days: Int) throws -> [Meeting] {
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        return try pool.read { db in
            try Meeting.filter(Column("deleted_at") != nil && Column("deleted_at") < cutoff).fetchAll(db)
        }
    }

    /// 只改一个字段（模板、会议语言）。不要用 updateMeeting 整列写回：画面上的 Meeting 可能是旧的（例如笔记另外存过），会把别的字段盖回去
    func setTemplate(_ id: Int64, templateId: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET template_id = ?, updated_at = ? WHERE id = ?", arguments: [templateId, Clock.now(), id])
        }
    }

    func setLanguage(_ id: Int64, _ language: MeetingLanguage) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET language = ?, updated_at = ? WHERE id = ?", arguments: [language.rawValue, Clock.now(), id])
        }
    }

    func updateInfo(_ id: Int64, title: String, date: String, participants: String) throws {
        try pool.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { return }
            if m.title != title { m.titleLocked = true }
            m.title = title
            m.meetingDate = date
            m.participants = participants
            m.updatedAt = Clock.now()
            try m.update(db)
            try Self.index(db, meetingId: id, kind: .title, ref: 0, text: m.displayTitle)
        }
    }

    // MARK: 逐字稿

    /// 「说话者 1」「Speaker 1」「話者 1」及旧版繁体默认名称。
    static func isDefaultSpeakerName(_ name: String) -> Bool {
        (try? defaultSpeakerPattern.wholeMatch(in: name)) != nil
    }

    /// 语言档里每种语言的默认说话者名称（design §41.1）：「说话者 %lld」→「说话者 \d+」，接成一个样式
    private static let defaultSpeakerPattern: Regex<AnyRegexOutput> = {
        // 兼容旧繁体标签和当前简体默认名称，避免将默认标签当成真实人名。
        let formats = LanguageProfiles.all.map(\.speaker) + ["說話者 %lld"]  // l10n-skip
        let speakers = formats.flatMap { [$0, ChineseScript.toSimplified($0)] }
        let forms = Array(Set(speakers)).sorted().map { speaker -> String in
            let parts = speaker.components(separatedBy: "%lld")
            return parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\d+")
        }
        return try! Regex("^(?:" + forms.joined(separator: "|") + ")$")
    }()

    /// 写入正式逐字稿：取代旧的正式版，并删掉实时预览（design §5.3）
    /// voices：每位说话者的声纹、说话秒数、收音（design §21.4），写进 speakers
    /// transcribedWith：用哪个引擎转录的（breeze、japanese、system，design §21.17）；导入的逐字稿不写
    func saveTranscript(_ meetingId: Int64, segments: [Segment], duration: Int, speakerCount: Int,
                        voices: [Int: SpeakerVoice] = [:], transcribedWith: String? = nil) throws {
        try pool.write { db in
            try Self.unindexSegments(db, meetingId: meetingId)
            try Segment.filter(Column("meeting_id") == meetingId).deleteAll(db)
            // 逐字稿换掉了，说话者的复原资料对不上（design §24.2）
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId])
            for var s in segments {
                try s.insert(db)
                try Self.indexSegment(db, meetingId: meetingId, id: s.id!, text: s.text)
            }
            // 说话者：保留已改过的名字，新的编号补上默认名字（跟着会议语言）
            let language = try Meeting.fetchOne(db, key: meetingId)?.meetingLanguage ?? .zh
            let existing = try SpeakerName.filter(Column("meeting_id") == meetingId).fetchAll(db)
            // 默认名称（任何语言的「说话者 1」）不算改过，换了会议语言后要用新语言的默认名称
            let named = Dictionary(uniqueKeysWithValues: existing.filter { !Self.isDefaultSpeakerName($0.name) }.map { ($0.idx, $0) })
            try SpeakerName.filter(Column("meeting_id") == meetingId).deleteAll(db)
            for idx in stride(from: 1, through: speakerCount, by: 1) {
                var speaker = SpeakerName(meetingId: meetingId, idx: idx,
                                          name: language.defaultSpeaker(idx))
                if let old = named[idx] {
                    speaker.name = old.name
                    speaker.nameSource = old.nameSource == "default" ? "manual" : old.nameSource
                    speaker.personId = old.personId
                }
                if let voice = voices[idx] {
                    speaker.embedding = Voiceprint.data(voice.embedding)
                    speaker.speechSeconds = voice.seconds
                    speaker.audioSource = voice.source
                }
                try speaker.insert(db)
            }
            if var m = try Meeting.fetchOne(db, key: meetingId) {
                m.durationSeconds = duration
                if let transcribedWith { m.transcribedWith = transcribedWith }
                m.updatedAt = Clock.now()
                try m.update(db)
            }
        }
    }

    /// 录音中的实时预览段落（kind = live）
    func appendLiveSegment(_ meetingId: Int64, start: Double, end: Double, text: String) throws {
        try pool.write { db in
            let seq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), -1) + 1 FROM segments WHERE meeting_id = ?",
                                       arguments: [meetingId]) ?? 0
            var segment = Segment(meetingId: meetingId, seq: seq, start: start, end: end, text: text, lowConfidence: false,
                                  speaker: nil, kind: "live")
            try segment.insert(db)
        }
    }

    func updateSegmentText(_ id: Int64, text: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE segments SET text = ? WHERE id = ?", arguments: [text, id])
            try db.execute(sql: "UPDATE search SET text = ? WHERE rowid = ?", arguments: [text, id])
        }
    }

    // MARK: 编辑中的草稿（design §21.15、R20.6）

    /// key：review:<题目>、review-skip:<题目>、segment:<段落 id>
    func drafts(_ meetingId: Int64) throws -> [String: String] {
        try pool.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT key, text FROM drafts WHERE meeting_id = ?", arguments: [meetingId])
                .map { ($0["key"] as String, $0["text"] as String) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// 最近改过、key 以 prefix 开头的草稿
    func latestDraft(_ meetingId: Int64, prefix: String) throws -> (key: String, text: String)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT key, text FROM drafts WHERE meeting_id = ? AND substr(key, 1, ?) = ? ORDER BY updated_at DESC LIMIT 1",
                             arguments: [meetingId, prefix.count, prefix]).map { ($0["key"], $0["text"]) }
        }
    }

    /// 存草稿；text 是空的就删掉
    func setDraft(_ meetingId: Int64, key: String, text: String) throws {
        try pool.write { db in
            if text.isEmpty {
                try db.execute(sql: "DELETE FROM drafts WHERE meeting_id = ? AND key = ?", arguments: [meetingId, key])
            } else {
                try db.execute(sql: """
                    INSERT INTO drafts (meeting_id, key, text, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT (meeting_id, key) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
                    """, arguments: [meetingId, key, text, Clock.now()])
            }
        }
    }

    func deleteDrafts(_ meetingId: Int64, prefix: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM drafts WHERE meeting_id = ? AND substr(key, 1, ?) = ?", arguments: [meetingId, prefix.count, prefix])
        }
    }

    // MARK: 逐字稿校正（design §17.4）

    func corrections(_ meetingId: Int64) throws -> [Correction] {
        try pool.read { db in try Correction.filter(Column("meeting_id") == meetingId).order(Column("id")).fetchAll(db) }
    }

    /// 存一次校正的结果：之前还没处理的建议换成这次的，已接受、已拒绝的保留
    func saveCorrections(_ meetingId: Int64, _ items: [Correction]) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM corrections WHERE meeting_id = ? AND status = 'pending'", arguments: [meetingId])
            for var item in items { try item.insert(db) }
        }
    }

    /// 接受：改段落文字（含搜索索引）。段落之后被改过、找不到原文时回传 false
    @discardableResult
    func acceptCorrection(_ id: Int64) throws -> Bool {
        try pool.write { db in try Self.acceptCorrection(db, id) }
    }

    /// 一次接受多则（同一个词的每一处，或全部，design §21.11）：同一个交易；回传没套用的数量（段落之后改过）
    func acceptCorrections(_ ids: [Int64]) throws -> Int {
        try pool.write { db in try ids.filter { try !Self.acceptCorrection(db, $0) }.count }
    }

    private static func acceptCorrection(_ db: Database, _ id: Int64) throws -> Bool {
        guard var correction = try Correction.fetchOne(db, key: id), correction.status == "pending",
              let segment = try Segment.fetchOne(db, key: correction.segmentId),
              let text = TranscriptCorrection.apply(correction.suggestionValue, to: segment.text) else { return false }
        try db.execute(sql: "UPDATE segments SET text = ? WHERE id = ?", arguments: [text, segment.id])
        try db.execute(sql: "UPDATE search SET text = ? WHERE rowid = ?", arguments: [text, segment.id])
        correction.status = "accepted"
        try correction.update(db)
        return true
    }

    /// 还原已接受的建议：改回原文，回到待确认
    @discardableResult
    func revertCorrection(_ id: Int64) throws -> Bool {
        try pool.write { db in
            guard var correction = try Correction.fetchOne(db, key: id), correction.status == "accepted",
                  let segment = try Segment.fetchOne(db, key: correction.segmentId),
                  let text = TranscriptCorrection.revert(correction.suggestionValue, in: segment.text) else { return false }
            try db.execute(sql: "UPDATE segments SET text = ? WHERE id = ?", arguments: [text, segment.id])
            try db.execute(sql: "UPDATE search SET text = ? WHERE rowid = ?", arguments: [text, segment.id])
            correction.status = "pending"
            try correction.update(db)
            return true
        }
    }

    func rejectCorrection(_ id: Int64) throws {
        try rejectCorrections([id])
    }

    func rejectCorrections(_ ids: [Int64]) throws {
        try pool.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE corrections SET status = 'rejected' WHERE id = ? AND status = 'pending'", arguments: [id])
            }
        }
    }

    func speakers(_ meetingId: Int64) throws -> [SpeakerName] {
        try pool.read { db in try SpeakerName.filter(Column("meeting_id") == meetingId).order(Column("idx")).fetchAll(db) }
    }

    /// 只改名字和名字的来源，不动声纹等其他字段（design §21.1）
    func renameSpeaker(_ meetingId: Int64, idx: Int, name: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO speakers (meeting_id, idx, name, name_source) VALUES (?, ?, ?, ?)
                ON CONFLICT (meeting_id, idx) DO UPDATE SET name = excluded.name, name_source = excluded.name_source
                """, arguments: [meetingId, idx, name, Self.isDefaultSpeakerName(name) ? "default" : "manual"])
            // 改名之后不能再复原合并、改句子（复原会把名字一起换回去，跟会议记录对不上，design §24.4）
            try db.execute(sql: "DELETE FROM speaker_undo WHERE meeting_id = ?", arguments: [meetingId])
        }
    }

    // MARK: 重点与笔记

    // MARK: 参考文档（design §39.1、R61）

    func document(_ id: Int64) throws -> MeetingDocument? {
        try pool.read { db in try MeetingDocument.fetchOne(db, key: id) }
    }

    func documents(_ meetingId: Int64) throws -> [MeetingDocument] {
        try pool.read { db in try MeetingDocument.filter(Column("meeting_id") == meetingId).order(Column("id")).fetchAll(db) }
    }

    /// 先插入、再用 id 填 file（documents/<id>/<文件名>），同一个交易
    func addDocument(_ meetingId: Int64, name: String, kind: DocumentKind, pages: [String], ocr: Bool) throws -> MeetingDocument {
        try pool.write { db in
            var document = MeetingDocument(meetingId: meetingId, name: name, kind: kind.rawValue,
                                           pages: MeetingDocument.encodePages(pages), ocr: ocr)
            try document.insert(db)
            document.file = "\(document.id!)/\(name)"
            try document.update(db)
            return document
        }
    }

    /// 删掉一份文档，连同源文件；回传删掉的那笔
    @discardableResult
    func deleteDocument(_ id: Int64) throws -> MeetingDocument? {
        let document = try pool.write { db -> MeetingDocument? in
            guard let document = try MeetingDocument.fetchOne(db, key: id) else { return nil }
            _ = try MeetingDocument.deleteOne(db, key: id)
            return document
        }
        if let document { removeDocumentFile(document.file) }
        return document
    }

    /// 源文件放在 documents/<id>/ 底下，整个文件夹删掉。标准答案的暂存数据库不碰文件（documentsRoot 是 nil）
    private func removeDocumentFile(_ file: String) {
        guard let documentsRoot, let folder = file.split(separator: "/").first, Int64(folder) != nil else { return }
        try? FileManager.default.removeItem(at: documentsRoot.appendingPathComponent(String(folder), isDirectory: true))
    }

    func bookmarks(_ meetingId: Int64) throws -> [Bookmark] {
        try pool.read { db in try Bookmark.filter(Column("meeting_id") == meetingId).order(Column("time")).fetchAll(db) }
    }

    func addBookmark(_ meetingId: Int64, time: Double, label: String = "") throws {
        try pool.write { db in
            var bookmark = Bookmark(meetingId: meetingId, time: time, label: label)
            try bookmark.insert(db)
        }
    }

    func deleteBookmark(_ id: Int64) throws {
        _ = try pool.write { db in try Bookmark.deleteOne(db, key: id) }
    }

    func updateUserNotes(_ meetingId: Int64, _ text: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET user_notes = ?, updated_at = ? WHERE id = ?",
                           arguments: [text, Clock.now(), meetingId])
            try Self.index(db, meetingId: meetingId, kind: .userNotes, ref: 0, text: text)
        }
    }

    // MARK: 会议记录

    /// 写入新的会议记录，旧的那一版存进 notes_versions（R6.7）
    /// 会议记录怎么来的，决定草稿状态和要不要留版本（design §21.3）
    enum NotesSource {
        case edit        // 手动编辑、取代、略过待确认、导入：草稿被改过就标成 2（改过的草稿）
        case draft       // 用实时逐字稿整理的草稿：notes_draft = 1，不留版本
        case generated   // 正式整理：取代没改过的草稿不留版本；取代改过的草稿留一版（原因「草稿（改过）」）
        case revised     // 校稿：在草稿上校稿，结果仍然是草稿（2）
    }

    /// 回传是否取代了用户改过的草稿（画面要提示，design §21.3）
    @discardableResult
    func saveNotes(_ meetingId: Int64, notes: MeetingNotes, by provider: String?, reason: String, source: NotesSource = .edit) throws -> Bool {
        try pool.write { db in try Self.saveNotes(db, meetingId, notes: notes, by: provider, reason: reason, source: source) }
    }

    @discardableResult
    static func saveNotes(_ db: Database, _ meetingId: Int64, notes: MeetingNotes, by provider: String?, reason: String,
                                  source: NotesSource = .edit) throws -> Bool {
        guard var m = try Meeting.fetchOne(db, key: meetingId) else { return false }
        let wasDraft = m.notesDraft
        var keepVersion = true
        var versionReason = reason
        switch source {
        case .edit: if wasDraft != 0 { m.notesDraft = 2 }
        case .draft:
            keepVersion = false
            m.notesDraft = 1
        case .generated:
            if wasDraft == 1 { keepVersion = false }
            if wasDraft == 2 { versionReason = String(localized: "草稿（改过）") }
            m.notesDraft = 0
        case .revised: if wasDraft != 0 { m.notesDraft = 2 }
        }
        if keepVersion, let old = m.notes {
            var version = NotesVersion(meetingId: meetingId, notes: old, reason: versionReason)
            try version.insert(db)
        }
        m.notes = notes.jsonString()
        if let provider { m.notesBy = provider }
        if !m.titleLocked && !notes.title.trimmingCharacters(in: .whitespaces).isEmpty {
            m.title = notes.title.trimmingCharacters(in: .whitespaces)
        }
        m.updatedAt = Clock.now()
        try m.update(db)
        try index(db, meetingId: meetingId, kind: .notes, ref: 0, text: notes.plainText)
        try index(db, meetingId: meetingId, kind: .title, ref: 0, text: m.displayTitle)
        return source == .generated && wasDraft == 2
    }

    /// 复原上一版：成功回传 true
    func undoNotes(_ meetingId: Int64) throws -> Bool {
        try pool.write { db in try Self.undoNotes(db, meetingId) }
    }

    static func undoNotes(_ db: Database, _ meetingId: Int64) throws -> Bool {
        guard let version = try NotesVersion.filter(Column("meeting_id") == meetingId).order(Column("id").desc).fetchOne(db),
              var m = try Meeting.fetchOne(db, key: meetingId) else { return false }
        m.notes = version.notes
        m.notesDraft = 0   // 复原的是之前的某一版，不再当草稿自动更新
        if !m.titleLocked, let title = m.decodedNotes?.title, !title.isEmpty { m.title = title }
        m.updatedAt = Clock.now()
        try m.update(db)
        _ = try version.delete(db)
        try index(db, meetingId: meetingId, kind: .notes, ref: 0, text: m.decodedNotes?.plainText ?? "")
        try index(db, meetingId: meetingId, kind: .title, ref: 0, text: m.displayTitle)
        return true
    }

    /// 全文取代：逐字稿＋会议记录（沿用第二版）
    func replace(_ meetingId: Int64, find: String, with replacement: String) throws -> ReplaceResult {
        try pool.write { db in
            var changed = 0
            for var s in try Segment.filter(Column("meeting_id") == meetingId).fetchAll(db) where s.text.contains(find) {
                s.text = s.text.replacingOccurrences(of: find, with: replacement)
                try s.update(db)
                try db.execute(sql: "UPDATE search SET text = ? WHERE rowid = ?", arguments: [s.text, s.id])
                changed += 1
            }
            var notesChanged = false
            if let m = try Meeting.fetchOne(db, key: meetingId), let notes = m.decodedNotes {
                let updated = notes.replacing(find, with: replacement)
                if updated != notes {
                    try Self.saveNotes(db, meetingId, notes: updated, by: nil, reason: String(localized: "取代「\(find)」→「\(replacement)」"))
                    notesChanged = true
                }
            }
            return ReplaceResult(segmentsChanged: changed, notesChanged: notesChanged)
        }
    }

    /// 只略过、不需要 LLM 的待确认题目：直接从会议记录移除
    func dismissReviewItems(_ meetingId: Int64, indexes: Set<Int>) throws {
        try resolveReviewItems(meetingId, confirmed: [], dismissed: indexes)
    }

    /// 确认（是非题回答「是」）和略过的题目直接从记录移除（R41.4、design §31.3），留一个版本；两种都没有就不动
    func resolveReviewItems(_ meetingId: Int64, confirmed: Set<Int>, dismissed: Set<Int>) throws {
        let indexes = confirmed.union(dismissed)
        guard !indexes.isEmpty else { return }
        let reason = dismissed.isEmpty ? String(localized: "确认待确认")
            : confirmed.isEmpty ? String(localized: "略过待确认") : String(localized: "确认、略过待确认")
        try pool.write { db in
            guard let m = try Meeting.fetchOne(db, key: meetingId), var notes = m.decodedNotes else { return }
            notes.reviewItems = notes.reviewItems.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
            try Self.saveNotes(db, meetingId, notes: notes, by: nil, reason: reason)
        }
    }

    // MARK: 搜索（R9.1）

    /// 搜索表的 rowid（design §20.11、D27）：段落用段落的 id；标题、会议记录、笔记用 2^50 + 会议 id × 4 + 种类，
    /// 不会跟段落重叠。FTS5 只能用 MATCH 或 rowid 找列，用其他字段删改每次都要扫整张表，所以一律用 rowid。
    /// 添加时一定要指定 rowid：自动编号会接在最大的 rowid 后面，之后可能跟推算出来的值撞在一起
    private static let metaRowidBase: Int64 = 1 << 50

    private static func searchRowid(meetingId: Int64, kind: SearchHit.Kind) -> Int64 {
        let code: Int64 = switch kind {
        case .title: 1
        case .notes: 2
        case .userNotes: 3
        case .segment: preconditionFailure("段落的 rowid 就是段落的 id")   // l10n-skip
        }
        return metaRowidBase + meetingId * 4 + code
    }

    static func indexSegment(_ db: Database, meetingId: Int64, id: Int64, text: String) throws {
        try db.execute(sql: "INSERT INTO search (rowid, meeting_id, kind, ref, text) VALUES (?, ?, 'segment', ?, ?)",
                       arguments: [id, meetingId, id, text])
    }

    /// 删掉这场会议所有段落的索引（段落还在数据库里的时候调用）
    private static func unindexSegments(_ db: Database, meetingId: Int64) throws {
        try db.execute(sql: "DELETE FROM search WHERE rowid IN (SELECT id FROM segments WHERE meeting_id = ?)", arguments: [meetingId])
    }

    /// 删掉这场会议的标题、会议记录、笔记的索引
    private static func unindexMeeting(_ db: Database, meetingId: Int64) throws {
        let ids = [SearchHit.Kind.title, .notes, .userNotes].map { searchRowid(meetingId: meetingId, kind: $0) }
        try db.execute(sql: "DELETE FROM search WHERE rowid IN (?, ?, ?)", arguments: StatementArguments(ids))
    }

    /// 标题、会议记录、笔记（ref 是 0）
    private static func index(_ db: Database, meetingId: Int64, kind: SearchHit.Kind, ref: Int64, text: String) throws {
        let rowid = searchRowid(meetingId: meetingId, kind: kind)
        try db.execute(sql: "DELETE FROM search WHERE rowid = ?", arguments: [rowid])
        guard !text.isEmpty else { return }
        try db.execute(sql: "INSERT INTO search (rowid, meeting_id, kind, ref, text) VALUES (?, ?, ?, ?, ?)",
                       arguments: [rowid, meetingId, kind.rawValue, ref, text])
    }

    private static func rebuildSearch(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM search")
        try db.execute(sql: "INSERT INTO search (rowid, meeting_id, kind, ref, text) SELECT id, meeting_id, 'segment', id, text FROM segments")
        // 只读需要的字段，不要整笔解码成 Meeting：migration 里调用时，后面版本才加的字段还不存在（design §21.1）
        let rows = try Row.fetchAll(db, sql: "SELECT id, title, source_filename, user_notes, notes FROM meetings")
        for row in rows {
            let m = Meeting(id: row["id"], title: row["title"], meetingDate: "", sourceFilename: row["source_filename"],
                            notes: row["notes"], userNotes: row["user_notes"])
            try index(db, meetingId: m.id!, kind: .title, ref: 0, text: m.displayTitle)
            try index(db, meetingId: m.id!, kind: .userNotes, ref: 0, text: m.userNotes)
            if let notes = m.decodedNotes { try index(db, meetingId: m.id!, kind: .notes, ref: 0, text: notes.plainText) }
        }
    }

    func rebuildSearchIndex() throws {
        try pool.write { try Self.rebuildSearch($0) }
    }

    /// trigram 至少要 3 个字；1～2 个字改用 LIKE
    func search(_ query: String, limit: Int = 200) throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try pool.read { db in
            let rows: [Row]
            if q.count >= 3 {
                let phrase = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.meeting_id, s.kind, s.ref, s.text FROM search s
                    JOIN meetings m ON m.id = s.meeting_id AND m.deleted_at IS NULL
                    WHERE search MATCH ? ORDER BY m.meeting_date DESC, s.meeting_id DESC, s.ref LIMIT ?
                    """, arguments: [phrase, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.meeting_id, s.kind, s.ref, s.text FROM search s
                    JOIN meetings m ON m.id = s.meeting_id AND m.deleted_at IS NULL
                    WHERE s.text LIKE ? ESCAPE '\\' ORDER BY m.meeting_date DESC, s.meeting_id DESC, s.ref LIMIT ?
                    """, arguments: ["%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%", limit])
            }
            return rows.compactMap { row in
                guard let kind = SearchHit.Kind(rawValue: row["kind"]) else { return nil }
                let text: String = row["text"]
                return SearchHit(meetingId: row["meeting_id"], kind: kind, ref: row["ref"], snippet: Self.snippet(text, around: q))
            }
        }
    }

    private static func snippet(_ text: String, around query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(80)) }
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ")
            + (end < text.endIndex ? "…" : "")
    }

    // MARK: 模板

    /// 内置模板依固定顺序（一般会议在最前面），自订模板接在后面依名称排序
    func templates() throws -> [TemplateRecord] {
        let order = BuiltinTemplates.all.map(\.id)
        return try pool.read { db in try TemplateRecord.fetchAll(db) }.sorted { a, b in
            switch (order.firstIndex(of: a.id), order.firstIndex(of: b.id)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name < b.name
            }
        }
    }

    func saveTemplate(_ template: TemplateRecord) throws {
        try pool.write { db in
            var t = template
            t.updatedAt = Clock.now()
            try t.save(db)
        }
    }

    func deleteTemplate(_ id: String) throws {
        _ = try pool.write { db in try TemplateRecord.deleteOne(db, key: id) }
    }

    // MARK: 工作

    @discardableResult
    func enqueue(_ meetingId: Int64, kind: JobKind, payload: String? = nil) throws -> Job {
        #if DEBUG
        // 启动参数 -debugFailEnqueue YES：排工作失败，验证失败时不会删掉录音（design §20.6）
        if UserDefaults.standard.bool(forKey: "debugFailEnqueue") {
            throw DatabaseError(resultCode: .SQLITE_FULL, message: "debugFailEnqueue")
        }
        #endif
        return try pool.write { db in
            var job = Job(meetingId: meetingId, kind: kind, payload: payload)
            try job.insert(db)
            return job
        }
    }

    /// 取出下一个排队的工作，改成 running。模型还没下载好的语言也照样转录（先用 macOS 内置识别，design §21.17）
    func claimNext(lane: JobLane) throws -> Job? {
        let kinds = JobKind.allCases.filter { $0.lane == lane }.map(\.rawValue)
        return try pool.write { db in
            guard var job = try Job.filter(Column("status") == JobStatus.queued.rawValue && kinds.contains(Column("kind")))
                .order(Column("id")).fetchOne(db) else { return nil }
            job.status = .running
            job.startedAt = Clock.now()
            try job.update(db)
            return job
        }
    }

    /// errorKind：错误的种类（Error.logSummary），反馈问题时用，不含内容（design §21.9）
    func finish(_ jobId: Int64, status: JobStatus, error: String? = nil, errorKind: String? = nil) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE jobs SET status = ?, error = ?, error_kind = ?, finished_at = ? WHERE id = ?",
                           arguments: [status.rawValue, error, errorKind, Clock.now(), jobId])
        }
    }

    /// 工作的 payload 换掉（企业服务器的工作 id，design §36.3）
    func setJobPayload(_ jobId: Int64, _ payload: String?) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE jobs SET payload = ? WHERE id = ?", arguments: [payload, jobId])
        }
    }

    /// app 启动时：上次没跑完的工作改回排队
    /// 启动时：还是 running 的工作表示上次执行时拾音意外结束（design §20.5、D26）。
    /// 意外结束累计 2 次就标成失败，不再自动重跑；不到 2 次才改回排队
    func requeueRunning() throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE jobs SET crashes = crashes + 1 WHERE status = 'running'")
            try db.execute(sql: "UPDATE jobs SET status = 'failed', error = ?, finished_at = ? WHERE status = 'running' AND crashes >= 2",
                           arguments: [String(localized: "执行这个工作时拾音意外结束了 2 次，已经停止自动重试。可以按「重试」再试一次。"), Clock.now()])
            try db.execute(sql: "UPDATE jobs SET status = 'queued', started_at = NULL WHERE status = 'running'")
        }
    }

    /// 正常结束拾音时：执行中的工作改回排队，下次打开从头重跑，不算意外结束（design §20.5）
    func releaseRunning() throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE jobs SET status = 'queued', started_at = NULL WHERE status = 'running'")
        }
    }

    /// 取消这场会议所有排队中、执行中的工作，回传原本执行中的工作 id
    func cancelJobs(_ meetingId: Int64) throws -> [Int64] {
        try pool.write { db in
            let running = try Int64.fetchAll(db, sql: "SELECT id FROM jobs WHERE meeting_id = ? AND status = 'running'",
                                              arguments: [meetingId])
            try db.execute(sql: """
                UPDATE jobs SET status = 'cancelled', finished_at = ?
                WHERE meeting_id = ? AND status IN ('queued', 'running')
                """, arguments: [Clock.now(), meetingId])
            return running
        }
    }

    /// 这场会议有没有排队中或执行中的某种工作
    func hasActiveJob(_ meetingId: Int64, kind: JobKind) throws -> Bool {
        try pool.read { db in
            try Job.filter(Column("meeting_id") == meetingId && Column("kind") == kind.rawValue
                           && [JobStatus.queued.rawValue, JobStatus.running.rawValue].contains(Column("status"))).fetchCount(db) > 0
        }
    }

    /// 有没有某个语言的会议在排队等转录
    func hasQueuedTranscribe(language: MeetingLanguage) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM jobs j JOIN meetings m ON m.id = j.meeting_id
                               WHERE j.status = 'queued' AND j.kind = 'transcribe' AND m.language = ?)
                """, arguments: [language.rawValue]) ?? false
        }
    }

    func jobStatus(_ jobId: Int64) throws -> JobStatus? {
        try pool.read { db in try Job.fetchOne(db, key: jobId)?.status }
    }

    func activeJobs() throws -> [Job] {
        try pool.read { db in
            try Job.filter(["queued", "running"].contains(Column("status"))).order(Column("id")).fetchAll(db)
        }
    }

    // MARK: 词汇表

    func glossary() throws -> [GlossaryTerm] {
        try pool.read { db in try GlossaryTerm.order(Column("id")).fetchAll(db) }
    }

    func addTerm(_ term: String) throws {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO glossary (term, created_at) VALUES (?, ?)", arguments: [trimmed, Clock.now()])
        }
    }

    func deleteTerm(_ id: Int64) throws {
        _ = try pool.write { db in try GlossaryTerm.deleteOne(db, key: id) }
    }

    /// 词汇表建议（design §17.5、R14.5）：从参加者、改过名字的说话者、接受过的校正、中文会议标题里的英文词找。
    /// 已经在词汇表里、被忽略过的不建议；出现越多次排越前面
    func glossarySuggestions(limit: Int = 12) throws -> [GlossarySuggestion] {
        try pool.read { db in
            var found: [String: (term: String, source: GlossarySuggestion.Source, count: Int)] = [:]
            func add(_ raw: String, _ source: GlossarySuggestion.Source) {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...40).contains(term.count) else { return }
                let key = term.lowercased()
                if let existing = found[key] { found[key]?.count = existing.count + 1 } else { found[key] = (term, source, 1) }
            }
            let meetings = try Meeting.filter(Column("deleted_at") == nil).fetchAll(db)
            for meeting in meetings { meeting.participantList.forEach { add($0, .participant) } }
            let names = try String.fetchAll(db, sql: """
                SELECT s.name FROM speakers s JOIN meetings m ON m.id = s.meeting_id WHERE m.deleted_at IS NULL
                """)
            for name in names where !Self.isDefaultSpeakerName(name) { add(name, .speaker) }
            let accepted = try String.fetchAll(db, sql: "SELECT suggestion FROM corrections WHERE status = 'accepted'")
            for term in accepted where term.contains(where: { $0.isASCII && $0.isLetter }) { add(term, .correction) }
            // 中文、日文会议标题里的英文词通常是产品名、项目名；英文会议的标题就不拆了
            let word = #/[A-Za-z][A-Za-z0-9.+\-]{2,}/#
            for meeting in meetings where !meeting.meetingLanguage.profile.spaced {
                for match in meeting.title.matches(of: word) { add(String(match.output), .title) }
            }
            let existing = Set(try String.fetchAll(db, sql: "SELECT term FROM glossary").map { $0.lowercased() })
            let dismissed = Set(try String.fetchAll(db, sql: "SELECT term FROM glossary_dismissed").map { $0.lowercased() })
            return found.filter { !existing.contains($0.key) && !dismissed.contains($0.key) }
                .values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.term < $1.term }
                .prefix(limit).map { GlossarySuggestion(term: $0.term, source: $0.source) }
        }
    }

    func dismissGlossarySuggestion(_ term: String) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO glossary_dismissed (term) VALUES (?)", arguments: [term])
        }
    }

    // MARK: 保存空间

    func setAudioFile(_ meetingId: Int64, _ filename: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET audio_file = ? WHERE id = ?", arguments: [filename, meetingId])
        }
    }
}
