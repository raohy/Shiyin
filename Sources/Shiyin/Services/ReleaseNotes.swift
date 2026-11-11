import Foundation

/// 更新说明的摘要（R10.6，design §12）：tag 的说明文字是「中文一段、空一行、英文一段」，每段第一行是标题、其余是「- 」开头的条目。
/// 询问更新的窗口只列界面语言那一段的前几项，其余写「还有 N 项」；完整说明在官网。Windows 的 ReleaseNotes.cs 同一套规则（标准答案 util/release-notes.json）
enum ReleaseNotes {
    /// 窗口里最多列几项
    static let maxItems = 4

    /// 回传要列出的条目和没列的项数；条目不含「- 」。没有条目的说明（只有一两行字）就拿标题以外的行
    static func brief(_ notes: String, english: Bool) -> (items: [String], more: Int) {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        guard !paragraphs.isEmpty else { return ([], 0) }
        let picked = english
            ? paragraphs.first { $0[0].lowercased().hasPrefix("shiyin") } ?? paragraphs[paragraphs.count - 1]
            : paragraphs.first { $0[0].hasPrefix("拾音") } ?? paragraphs[0]   // l10n-skip
        var items = picked.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if items.isEmpty { items = picked.count > 1 ? Array(picked.dropFirst()) : picked }
        let shown = Array(items.prefix(maxItems))
        return (shown, items.count - shown.count)
    }

    /// 对话框里的文字：每项前面加「• 」，没列完的加一行说还有几项
    static func text(_ notes: String?, english: Bool) -> String {
        guard let notes else { return "" }
        let (items, more) = brief(notes, english: english)
        var out = items.map { "• " + $0 }
        if more > 0 { out.append(String(localized: "……还有 \(more) 项，完整说明在官网。")) }
        let text = out.joined(separator: "\n")
        return english ? text : ChineseScript.toSimplified(text)
    }
}
