import Foundation

/// 会议列表的排序（R97.2、design §71）：记住
enum MeetingSort: String, CaseIterable, Identifiable {
    case dateDesc, dateAsc, title, duration
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateDesc: return String(localized: "日期（新到旧）")
        case .dateAsc: return String(localized: "日期（旧到新）")
        case .title: return String(localized: "标题")
        case .duration: return String(localized: "长度（长的在前）")
        }
    }
}

/// 会议列表的分组（R97.2）：记住（以前存的 series 读成不分组）
enum MeetingGrouping: String, CaseIterable, Identifiable {
    case none, month, folder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return String(localized: "不分组")
        case .month: return String(localized: "依月份")
        case .folder: return String(localized: "依文件夹")
        }
    }
}

/// 会议列表的筛选（R97.3）：不记住，都要符合
struct MeetingFilter: Equatable {
    var needsReview = false
    var myActionItems = false
    var personId: Int64?
    var templateId: String?

    var isActive: Bool { needsReview || myActionItems || personId != nil || templateId != nil }
}

/// 分组后的一段：标题空的是不分组
struct MeetingGroup: Identifiable {
    var id: String
    var title: String
    var rows: [MeetingRow]
}

extension AppModel {
    /// 「我」的名字（R80）：「有我的待办的」用；没有设置「我」是 nil
    var myName: String? { peopleOverview.first(where: \.isMe)?.name }

    /// 实际用的分组：看某个文件夹时不依文件夹分组（design §71）
    var effectiveGrouping: MeetingGrouping {
        switch meetingGrouping {
        case .folder where folderFilter != nil: return .none
        default: return meetingGrouping
        }
    }

    /// 菜单里可以选的分组
    var availableGroupings: [MeetingGrouping] {
        MeetingGrouping.allCases.filter { $0 != .folder || folderFilter == nil }
    }

    func matches(_ row: MeetingRow, _ filter: MeetingFilter) -> Bool {
        if filter.needsReview && row.reviewCount == 0 { return false }
        if let id = filter.templateId, row.meeting.templateId != id { return false }
        if let person = filter.personId, meetingPeople[row.id]?.contains(person) != true { return false }
        if filter.myActionItems {
            // 负责人跟名字一样或包含名字（不分大小写，同人物页 R85.3）
            guard let name = myName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  row.meeting.decodedNotes?.actionItems.contains(where: { $0.owner.range(of: name, options: .caseInsensitive) != nil }) == true
            else { return false }
        }
        return true
    }

    func sorted(_ rows: [MeetingRow]) -> [MeetingRow] {
        switch meetingSort {
        case .dateDesc: return rows   // 数据库照 meeting_date DESC, id DESC 读出来
        case .dateAsc: return rows.reversed()
        case .title:
            return rows.sorted { $0.meeting.displayTitle.localizedStandardCompare($1.meeting.displayTitle) == .orderedAscending }
        case .duration:
            return rows.sorted { ($0.meeting.durationSeconds ?? -1) > ($1.meeting.durationSeconds ?? -1) }
        }
    }

    /// 列表的分组（R97.2）：月份照日期新到旧（旧到新排序时反过来）；文件夹照名称，最后是「不在文件夹」；每一段里照排序
    var meetingGroups: [MeetingGroup] {
        let rows = filteredMeetings
        guard !showTrash else { return [MeetingGroup(id: "all", title: "", rows: rows)] }
        switch effectiveGrouping {
        case .none:
            return [MeetingGroup(id: "all", title: "", rows: rows)]
        case .month:
            let keys = Set(rows.map { String($0.meeting.meetingDate.prefix(7)) }).sorted(by: meetingSort == .dateAsc ? (<) : (>))
            return keys.map { key in
                MeetingGroup(id: "month-" + key, title: Self.monthTitle(key), rows: rows.filter { $0.meeting.meetingDate.hasPrefix(key) })
            }
        case .folder:
            let folders = Set(rows.map(\.meeting.folder)).sorted { a, b in
                a.isEmpty != b.isEmpty ? !a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending
            }
            return folders.map { folder in
                MeetingGroup(id: "folder-" + folder, title: folder.isEmpty ? String(localized: "不在文件夹") : folder,
                             rows: rows.filter { $0.meeting.folder == folder })
            }
        }
    }

    /// 「2026-11」→「2026 年 11 月」（界面语言）
    static func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: MeetingLanguage.interface == .en ? "en_US" : "zh_TW")
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        let text = formatter.string(from: date)
        return MeetingLanguage.simplifiedInterface ? ChineseScript.toSimplifiedUI(text) : text
    }

    /// 筛选的说明（列表上方那一列）
    var filterSummary: String {
        var parts: [String] = []
        if meetingFilter.needsReview { parts.append(String(localized: "有待确认")) }
        if meetingFilter.myActionItems { parts.append(String(localized: "有我的待办")) }
        if let id = meetingFilter.personId, let name = peopleOverview.first(where: { $0.id == id })?.name {
            parts.append(String(localized: "\(name) 有参加"))
        }
        if let id = meetingFilter.templateId, let template = templates.first(where: { $0.id == id }) {
            parts.append(String(localized: "模板：\(template.displayName)"))
        }
        return parts.joined(separator: MeetingLanguage.ui(zh: "、", en: ", "))
    }
}
