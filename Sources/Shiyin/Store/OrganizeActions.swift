import Foundation

/// 文件夹自动归类（R98、design §72）
extension AppModel {
    // MARK: 文件夹的条件

    func folderRule(_ folder: String) -> FolderRule? { folderRules.first { $0.folder == folder } }

    /// 保存条件（都空时移除）；applyNow：现在不在文件夹里的会议也套用
    func saveFolderRule(_ rule: FolderRule, applyNow: Bool) {
        perform {
            try db.saveFolderRule(rule)
            guard applyNow && !rule.isEmpty else { return }
            let ids = try db.meetingsMatching(rule)
            guard !ids.isEmpty else { return }
            try db.setFolder(ids, folder: rule.folder)
            noticeMessage = String(localized: "已把 \(ids.count) 场会议放进「\(rule.folder)」")
        }
    }

    /// 侧栏滑过去看的条件：「标题包含 周会、sync；陈家豪、王小明都参加；模板：一对一」
    func folderRuleSummary(_ rule: FolderRule) -> String {
        let separator = MeetingLanguage.ui(zh: "、", en: ", ")
        var parts: [String] = []
        if !rule.keywords.isEmpty { parts.append(String(localized: "标题包含 \(rule.keywords.joined(separator: separator))")) }
        let names = rule.people.compactMap { id in peopleOverview.first { $0.id == id }?.name }
        if !names.isEmpty { parts.append(String(localized: "\(names.joined(separator: separator)) 都参加")) }
        if let id = rule.templateId, let template = templates.first(where: { $0.id == id }) {
            parts.append(String(localized: "模板：\(template.displayName)"))
        }
        let joined = parts.joined(separator: MeetingLanguage.ui(zh: "；", en: "; "))
        return String(localized: "自动加入：\(joined)")
    }

    // MARK: 建议放进文件夹（R98.3）

    /// 会议不在文件夹、还没决定过、已经有会议记录、不在录音中、不在垃圾桶时，跟各个文件夹比
    func folderSuggestion(for meeting: Meeting) -> FolderSuggestion? {
        guard let id = meeting.id, meeting.folder.isEmpty, !meeting.folderDecided, meeting.deletedAt == nil,
              meeting.notes != nil, recorder.meetingId != id else { return nil }
        let input = FolderSuggester.Input(id: id, folder: "", title: meeting.displayTitle, people: meetingPeople[id] ?? [])
        let others = meetings.map { FolderSuggester.Input(id: $0.id, folder: $0.meeting.folder, title: $0.meeting.displayTitle,
                                                          people: meetingPeople[$0.id] ?? []) }
        return FolderSuggester.best(for: input, among: others)
    }

    func folderSuggestionText(_ suggestion: FolderSuggestion) -> String {
        switch suggestion.reason {
        case .people(let ids):
            let names = ids.compactMap { id in peopleOverview.first { $0.id == id }?.name }
            let shown = names.prefix(3).joined(separator: MeetingLanguage.ui(zh: "、", en: ", "))
            return String(localized: "这场很像「\(suggestion.folder)」里的会议：\(shown) 都参加（\(suggestion.count) 场）")
        case .title(let word):
            return String(localized: "这场很像「\(suggestion.folder)」里的会议：标题都有「\(word)」（\(suggestion.count) 场）")
        }
    }

    func acceptFolderSuggestion(_ meetingId: Int64, folder: String) {
        moveToFolder([meetingId], folder: folder)
    }

    /// 「不用」：之后不再建议这场
    func dismissFolderSuggestion(_ meetingId: Int64) {
        perform { try db.setFolderDecided(meetingId) }
    }

    // MARK: 自动（转录完、整理完）

    func organized(_ meetingId: Int64, folder: String?) {
        reload()
        let title = (try? db.meeting(meetingId))?.displayTitle ?? ""
        if let folder { noticeMessage = String(localized: "「\(title)」已放进「\(folder)」") }
    }
}
