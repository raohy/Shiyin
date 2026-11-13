import Foundation
import GRDB

/// 资料表对应（design §3）。字段名称在数据库是 snake_case。
protocol SnakeCaseRecord: Codable, FetchableRecord, MutablePersistableRecord {}

extension SnakeCaseRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

enum Clock {
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}

struct Meeting: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "meetings"
    var id: Int64?
    var title: String = ""
    var titleLocked: Bool = false
    var meetingDate: String
    var participants: String = ""
    var sourceFilename: String
    var audioFile: String = ""
    var durationSeconds: Int?
    var notes: String?
    var notesBy: String?
    var createdAt: String = Clock.now()
    var updatedAt: String = Clock.now()
    // v2（design §4）
    var templateId: String = "general"
    var userNotes: String = ""
    var source: String = "import"        // recording / import / package / transcript
    var channels: String = "mic"         // mic / system / both
    var deletedAt: String?
    var folder: String = ""
    // v3（design §16.3）
    var language: String = "zh"
    // v7（design §21.1）：1 是用实时逐字稿整理的草稿，2 是用户改过的草稿；转录引擎（breeze / japanese / system）
    var notesDraft: Int = 0
    var transcribedWith: String = ""
    // v8（design §23.2）：说话者识别至少分出几个人，nil 是自动判断
    var minSpeakers: Int?
    // v9（design §24.1）：说话者识别的自我检查分数（越大越可能把不同的人并在一起），nil 是没算过；用户按了「不用了」
    var speakerCheck: Double?
    var speakerHintDismissed: Bool = false

    var meetingLanguage: MeetingLanguage { MeetingLanguage(rawValue: language) ?? .zh }

    /// 说话者识别的自我检查觉得可能把不同的人并在一起（design §24.5）
    var mayHaveMergedSpeakers: Bool { (speakerCheck ?? 0) >= Diarizer.Quality.hintThreshold }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return (sourceFilename as NSString).deletingPathExtension
    }

    var decodedNotes: MeetingNotes? {
        guard let notes, let data = notes.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingNotes.self, from: data)
    }

    var audioURL: URL { Paths.audioDir.appendingPathComponent(audioFile) }
    var hasAudio: Bool { !audioFile.isEmpty && FileManager.default.fileExists(atPath: audioURL.path) }

    var participantList: [String] {
        participants.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })  // l10n-skip
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct Segment: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "segments"
    var id: Int64?
    var meetingId: Int64
    var seq: Int
    var start: Double
    var end: Double
    var text: String
    var lowConfidence: Bool
    var speaker: Int?
    var kind: String = "final"           // live（实时快稿）/ reviewed（音频复核稿）/ final
    var channel: Int? = nil              // 分声道转录时：0 麦克风、1 电脑声音（design §17.3）
    var speakerManual: Bool = false      // v9：用户改过这句的说话者（design §24.2）

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Segment {
    /// 手写的读取：GRDB 用 Codable 逐笔解码时每一笔都要重建字段对照，2,000 段以上的会议光读逐字稿就要上百毫秒（design §21.12）
    init(row: Row) throws {
        id = row["id"]
        meetingId = row["meeting_id"]
        seq = row["seq"]
        start = row["start"]
        end = row["end"]
        text = row["text"]
        lowConfidence = row["low_confidence"]
        speaker = row["speaker"]
        kind = row["kind"]
        channel = row["channel"]
        speakerManual = row["speaker_manual"]
    }
}

/// 说话者名字（R5.2），没改过名字时显示「说话者 n」
struct SpeakerName: SnakeCaseRecord, Hashable {
    static let databaseTableName = "speakers"
    var meetingId: Int64
    var idx: Int
    var name: String
    // v7（design §21.1）
    var nameSource: String = "default"     // default / manual / voiceprint / suggestion
    var personId: Int64?
    var embedding: Data?                   // 声纹，Float32×256
    var speechSeconds: Double = 0
    var audioSource: String = "mix"        // mic / system / mix
    var suggestedName: String?
    var suggestionReason: String?
    var suggestionTime: String?
}

/// 录音中按 ⌘B 标的重点（R2.4）
struct Bookmark: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "bookmarks"
    var id: Int64?
    var meetingId: Int64
    var time: Double
    var label: String = ""

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 逐字稿校正建议（design §17.4、R14.4）：pending 待确认、accepted 已接受（段落文字已改）、rejected 已拒绝
struct Correction: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "corrections"
    var id: Int64?
    var meetingId: Int64
    var segmentId: Int64
    var original: String
    var suggestion: String
    var reason: String
    var status: String = "pending"
    var createdAt: String = Clock.now()

    var suggestionValue: CorrectionSuggestion {
        CorrectionSuggestion(segment: 0, original: original, suggestion: suggestion, reason: reason)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 词汇表建议（design §17.5）：用户确认才加进词汇表
struct GlossarySuggestion: Hashable, Identifiable {
    enum Source { case participant, speaker, correction, title }
    var term: String
    var source: Source
    var id: String { term.lowercased() }

    var sourceLabel: String {
        switch source {
        case .participant: String(localized: "参加者")
        case .speaker: String(localized: "说话者名字")
        case .correction: String(localized: "校正过的字")
        case .title: String(localized: "会议标题")
        }
    }
}

/// 会议记录模板（R6.2、design §8.2）
struct TemplateRecord: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "templates"
    var id: String
    var name: String
    var builtin: Bool
    var definition: String
    var updatedAt: String = Clock.now()
}

struct NotesVersion: SnakeCaseRecord, Identifiable {
    static let databaseTableName = "notes_versions"
    var id: Int64?
    var meetingId: Int64
    var notes: String
    var reason: String
    var createdAt: String = Clock.now()

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum JobKind: String, Codable, CaseIterable {
    case transcribe, summarize, revise, compress
    case correct   // 逐字稿校正（design §17.4）
    case nameSpeakers   // 猜说话者（design §21.5）
    case rediarize   // 只重新识别说话者（design §23）

    /// 转录线、整理线、辅助线（design §21.2）：校正、猜说话者在辅助线，跟整理同时跑
    var lane: JobLane {
        switch self {
        case .transcribe, .compress, .rediarize: return .transcribe
        case .summarize, .revise: return .llm
        case .correct, .nameSpeakers: return .assist
        }
    }

    /// 要用整理工具的工作（design §34）
    var usesSummarizer: Bool { self == .summarize || self == .revise || self == .correct || self == .nameSpeakers }

    /// 背景的辅助工作：不发通知、不改会议的状态
    var isAuxiliary: Bool { self == .compress || self == .correct || self == .nameSpeakers || self == .rediarize }
}

enum JobLane: String, CaseIterable { case transcribe, llm, assist }

enum JobStatus: String, Codable {
    case queued, running, done, failed, cancelled
}

struct Job: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "jobs"
    var id: Int64?
    var meetingId: Int64
    var kind: JobKind
    var status: JobStatus = .queued
    var payload: String?
    var error: String?
    var createdAt: String = Clock.now()
    var startedAt: String?
    var finishedAt: String?
    /// 执行时拾音意外结束的次数（design §20.5）
    var crashes = 0
    /// 失败的种类（Error.logSummary，design §21.9）
    var errorKind: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct GlossaryTerm: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "glossary"
    var id: Int64?
    var term: String
    var createdAt: String = Clock.now()

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 会议的参考文档的种类（design §39.2）：PDF、幻灯片有页码
enum DocumentKind: String, Codable, CaseIterable {
    case pdf, docx, pptx, text, image

    var isPaged: Bool { self == .pdf || self == .pptx }
}

/// 会议的参考文档（design §39.1、R61）：源文件在 documents/<file>，读出来的文字每页一项
struct MeetingDocument: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "documents"
    var id: Int64?
    var meetingId: Int64
    var name: String
    var file: String = ""
    var kind: String
    var pages: String                    // JSON 字符串数组
    var ocr: Bool = false
    var createdAt: String = Clock.now()

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var documentKind: DocumentKind { DocumentKind(rawValue: kind) ?? .text }
    var pageTexts: [String] { (try? JSONDecoder().decode([String].self, from: Data(pages.utf8))) ?? [] }
    var fileURL: URL { Paths.documentsDir.appendingPathComponent(file) }

    /// 页的文字存成 JSON（同会议记录的写法，Windows 用 SwiftJson 写出一样的字符串）
    static func encodePages(_ pages: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: (try? encoder.encode(pages)) ?? Data(), encoding: .utf8) ?? "[]"
    }
}
