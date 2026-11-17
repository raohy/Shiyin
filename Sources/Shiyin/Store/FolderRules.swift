import Foundation
import GRDB

/// 文件夹的自动加入条件（R98、design §72）：任一个条件符合就放进去
struct FolderRule: SnakeCaseRecord, Hashable {
    static let databaseTableName = "folder_rules"
    var folder: String
    var keywords: [String] = []
    /// 人物 id：选的人都有参加才算
    var people: [Int64] = []
    var templateId: String?
    var createdAt: String = Clock.now()

    var isEmpty: Bool { keywords.isEmpty && people.isEmpty && templateId == nil }

    func matches(title: String, attended: Set<Int64>, templateId: String) -> Bool {
        if keywords.contains(where: { !$0.isEmpty && title.range(of: $0, options: .caseInsensitive) != nil }) { return true }
        if !people.isEmpty && Set(people).isSubset(of: attended) { return true }
        if let id = self.templateId, id == templateId { return true }
        return false
    }
}

/// 会议像不像（文件夹的建议用，R98.3、design §72）：同一群人、内核人物、标题的共同词
enum MeetingSimilarity {
    /// 同一群人：共同的人物至少 2 位、Jaccard ≥ 0.5
    static func samePeople(_ a: Set<Int64>, _ b: Set<Int64>) -> Bool {
        let common = a.intersection(b).count
        return common >= 2 && Double(common) / Double(a.union(b).count) >= 0.5
    }

    /// 过半数场次都有的人
    static func core(_ people: [Set<Int64>]) -> Set<Int64> {
        var counts: [Int64: Int] = [:]
        for set in people { for id in set { counts[id, default: 0] += 1 } }
        return Set(counts.filter { $0.value * 2 > people.count }.keys)
    }

    /// 共同的词：标题先拿掉数字和跟着的日期单位（11/3、11月3日、2026-11-16），最长的共同子字符串去掉头尾的空白、标点后
    /// 至少 2 个字（只有拉丁字母时至少 3 个字母）
    static func commonWord(_ titles: [String]) -> String? {
        let list = titles.map { Array(withoutNumbers($0)) }.filter { !$0.isEmpty }
        guard list.count >= 2, let shortest = list.min(by: { $0.count < $1.count }) else { return nil }
        let lowered = list.map { String($0).lowercased() }
        for length in stride(from: shortest.count, through: 2, by: -1) {
            for start in 0...(shortest.count - length) {
                let piece = String(shortest[start..<(start + length)])
                guard lowered.allSatisfy({ $0.contains(piece.lowercased()) }) else { continue }
                let cleaned = clean(piece)
                if isSignificant(cleaned), lowered.allSatisfy({ isWholeWord(cleaned.lowercased(), in: $0) }) { return cleaned }
            }
        }
        return nil
    }

    /// 英文要是完整的单字：头尾是英文字母或数字时，前后不能接着英文字母或数字（「Control」「Conceptual」不会取出「Con」；
    /// 2026-11-16 用 AMI 真人录音验收时发现）。中文没有空格，头尾是中文时不检查
    static func isWholeWord(_ word: String, in text: String) -> Bool {
        let w = Array(word), t = Array(text)
        guard let first = w.first, let last = w.last, w.count <= t.count else { return false }
        func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        for i in 0...(t.count - w.count) where Array(t[i..<(i + w.count)]) == w {
            let before = !latin(first) || i == 0 || !latin(t[i - 1])
            let after = !latin(last) || i + w.count == t.count || !latin(t[i + w.count])
            if before && after { return true }
        }
        return false
    }

    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)

    /// 前面接英文字母的数字（Q3、v2）留着
    private static let numberPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z])[0-9０-９]+[年月日号号/.\\-]?")  // l10n-skip
    private static let spaces = try! NSRegularExpression(pattern: "\\s+")

    static func withoutNumbers(_ title: String) -> String {
        let stripped = numberPattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: " ")
        return spaces.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: " ")
    }

    static func clean(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let first = scalars.first, edgeCharacters.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, edgeCharacters.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func isSignificant(_ word: String) -> Bool {
        let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }
        let latinOnly = letters.allSatisfy { $0.isASCII }
        return !latinOnly || letters.count >= 3
    }
}

/// 不在文件夹的会议很像某个文件夹里的会议（R98.3、design §72）
struct FolderSuggestion: Hashable {
    enum Reason: Hashable {
        /// 都有这几位参加（人物 id）
        case people([Int64])
        /// 标题都有这个词
        case title(String)
    }
    var folder: String
    var reason: Reason
    var count: Int
}

enum FolderSuggester {
    struct Input: Hashable {
        var id: Int64
        var folder: String
        var title: String
        var people: Set<Int64>
    }

    /// 通用的词不算共同的词
    static let genericWords: Set<String> = ["会议", "会议", "会议记录", "meeting", "meetings", "讨论", "讨论", "会议", "회의"]  // l10n-skip

    static func best(for meeting: Input, among others: [Input]) -> FolderSuggestion? {
        var best: FolderSuggestion?
        let byFolder = Dictionary(grouping: others.filter { !$0.folder.isEmpty && $0.id != meeting.id }, by: \.folder)
        for folder in byFolder.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let members = byFolder[folder]!
            guard members.count >= 2 else { continue }
            var options: [FolderSuggestion] = []
            let samePeople = members.filter { MeetingSimilarity.samePeople(meeting.people, $0.people) }
            if samePeople.count >= 2 {
                let core = MeetingSimilarity.core(samePeople.map(\.people)).intersection(meeting.people)
                options.append(FolderSuggestion(folder: folder, reason: .people(core.sorted()), count: samePeople.count))
            }
            var words: [String: Int] = [:]
            for member in members {
                if let word = MeetingSimilarity.commonWord([meeting.title, member.title]), !genericWords.contains(word.lowercased()) {
                    words[word, default: 0] += 1
                }
            }
            // 场数最多的词；一样多时照字符串排序取第一个
            if let (word, count) = words.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }).first, count >= 2 {
                options.append(FolderSuggestion(folder: folder, reason: .title(word), count: count))
            }
            // 同一个文件夹：人的比较准，场数一样时用人
            for option in options where best == nil || option.count > best!.count {
                best = option
            }
        }
        return best
    }
}

// MARK: - 数据库

extension AppDatabase {
    func folderRules() throws -> [FolderRule] {
        try pool.read { db in try FolderRule.order(Column("folder")).fetchAll(db) }
    }

    /// 条件都空时当成移除
    func saveFolderRule(_ rule: FolderRule) throws {
        try pool.write { db in
            if rule.isEmpty {
                try db.execute(sql: "DELETE FROM folder_rules WHERE folder = ?", arguments: [rule.folder])
            } else {
                var rule = rule
                try rule.save(db)
            }
        }
    }

    func setFolderDecided(_ id: Int64) throws {
        try pool.write { db in try db.execute(sql: "UPDATE meetings SET folder_decided = 1 WHERE id = ?", arguments: [id]) }
    }

    /// 自动放进文件夹（design §72）：不在文件夹、还没决定过、不在垃圾桶；符合好几个时放名称排第一的。回传文件夹名称
    func autoFile(_ meetingId: Int64) throws -> String? {
        guard let meeting = try meeting(meetingId), meeting.folder.isEmpty, !meeting.folderDecided, meeting.deletedAt == nil else { return nil }
        let attended = try meetingPeople()[meetingId] ?? []
        let rules = try folderRules().sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
        guard let rule = rules.first(where: {
            $0.matches(title: meeting.displayTitle, attended: attended, templateId: meeting.templateId)
        }) else { return nil }
        try pool.write { db in
            try db.execute(sql: "UPDATE meetings SET folder = ?, folder_decided = 1, updated_at = ? WHERE id = ?",
                           arguments: [rule.folder, Clock.now(), meetingId])
        }
        return rule.folder
    }

    /// 「现在不在文件夹里的会议也套用」：符合条件的会议（不在文件夹、不在垃圾桶）
    func meetingsMatching(_ rule: FolderRule) throws -> [Int64] {
        let people = try meetingPeople()
        return try pool.read { db in
            try Meeting.filter(Column("deleted_at") == nil && Column("folder") == "").fetchAll(db)
        }
        .filter { meeting in
            rule.matches(title: meeting.displayTitle, attended: people[meeting.id ?? 0] ?? [], templateId: meeting.templateId)
        }
        .compactMap(\.id)
    }
}
