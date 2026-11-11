import Foundation
import UniformTypeIdentifiers

/// 导入的选填资料（R1.2）
struct ImportOptions {
    var title: String = ""
    var date: String? = nil
    var participants: String = ""
    /// 显示用的来源名称；没给就用文件名
    var sourceName: String? = nil
    var templateId: String? = nil
    /// 放进哪个文件夹（R9.2）；空字符串是不放
    var folder: String = ""
    /// 会议语言（design §16.3）
    var language: MeetingLanguage = AppSettings.defaultMeetingLanguage
    /// 大约几个人（design §26.2）：nil 是自动判断
    var minSpeakers: Int? = nil
}

enum ImportError: LocalizedError {
    case copyFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let name, let reason): return String(localized: "无法导入「\(name)」：\(reason)")
        }
    }
}

/// 统一处理四种导入入口（design §7）
enum Importer {
    static let contentTypes: [UTType] = [.audio, .movie, .audiovisualContent]
    /// 逐字稿、Markdown 笔记、.shiyin 封包（R3.3～R3.5）
    static let otherTypes: [UTType] = [UTType(filenameExtension: "shiyin"), UTType(filenameExtension: "srt"),
                                       UTType(filenameExtension: "vtt"), .plainText,
                                       UTType(filenameExtension: "md")].compactMap { $0 }

    /// 会议日期默认值（R1.4）：文件名有日期就用文件名，年份取不晚于今天的最近一年；否则用文件修改日期
    static func inferDate(filename: String, modified: Date?, today: Date = Date()) -> String {
        let name = (filename as NSString).deletingPathExtension
        let calendar = Calendar(identifier: .gregorian)
        let todayParts = calendar.dateComponents([.year, .month, .day], from: today)

        func valid(_ y: Int, _ m: Int, _ d: Int) -> String? {
            guard (1...12).contains(m), (1...31).contains(d),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
                  calendar.component(.day, from: date) == d else { return nil }
            return DateText.string(date)
        }
        func withNearestYear(_ m: Int, _ d: Int) -> String? {
            let year = todayParts.year!
            let isFuture = (m, d) > (todayParts.month!, todayParts.day!)
            return valid(isFuture ? year - 1 : year, m, d)
        }
        func match(_ pattern: String) -> [Int]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: name).flatMap { Int(name[$0]) } }
        }

        // 2026-08-27、2026_08_27、20260827
        if let p = match(#"(?<!\d)(20\d{2})[-_./]?(\d{1,2})[-_./]?(\d{1,2})(?!\d)"#), p.count == 3,
           let date = valid(p[0], p[1], p[2]) { return date }
        // 8_27、08-27、8.27
        if let p = match(#"(?<!\d)(\d{1,2})[-_./](\d{1,2})(?!\d)"#), p.count == 2,
           let date = withNearestYear(p[0], p[1]) { return date }
        // 0827
        if let p = match(#"(?<!\d)(\d{2})(\d{2})(?!\d)"#), p.count == 2,
           let date = withNearestYear(p[0], p[1]) { return date }
        return DateText.string(modified ?? today)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 只保留英数字的扩展名，避免路径穿越（N1）
    static func safeExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ext.isEmpty ? "bin" : String(ext.prefix(8))
    }

    /// 创建会议、复制录音、排转录工作。复制失败会删掉刚创建的会议。
    @discardableResult
    static func importFile(_ url: URL, options: ImportOptions, db: AppDatabase,
                           move: Bool = false) throws -> Meeting {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = Meeting(
            title: title, titleLocked: !title.isEmpty,
            meetingDate: options.date ?? inferDate(filename: url.lastPathComponent, modified: modificationDate(url)),
            participants: options.participants.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceFilename: options.sourceName ?? url.lastPathComponent,
            templateId: options.templateId ?? AppSettings.defaultTemplate, source: "import", folder: options.folder,
            language: options.language.rawValue)
        draft.minSpeakers = options.minSpeakers
        let meeting = try db.insertMeeting(draft, audioExtension: safeExtension(url))
        var moved = false
        do {
            try Paths.ensureDirectories()
            // 同一个 APFS 磁盘区时，copyItem 会自动用 clone，不占额外空间
            if move {
                try FileManager.default.moveItem(at: url, to: meeting.audioURL)
                moved = true
            } else {
                try FileManager.default.copyItem(at: url, to: meeting.audioURL)
            }
            try db.enqueue(meeting.id!, kind: .transcribe)
            // 匿名使用统计（design §30.1）：复原当掉的录音（move）不算导入
            if !move { UsageStats.shared.imported() }
        } catch {
            try? db.deleteMeeting(meeting.id!)
            if moved {
                // 复原的录音是唯一的一份：搬回原处，下次打开再试（design §20.6、R18.6）
                try? FileManager.default.moveItem(at: meeting.audioURL, to: url)
            } else {
                try? FileManager.default.removeItem(at: meeting.audioURL)
            }
            throw ImportError.copyFailed(url.lastPathComponent, error.localizedDescription)
        }
        return meeting
    }
}
