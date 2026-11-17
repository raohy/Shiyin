import Foundation

// MARK: - 侧栏的收合（R101、design §75）

extension AppModel {
    nonisolated static func folderKey(_ name: String) -> String { "folder:" + name }
    nonisolated static func groupKey(_ group: MeetingGroup) -> String { "group:" + group.id }

    /// 段落（folders、meetings、people、group:…）展开了没；默认展开
    func isSectionExpanded(_ key: String) -> Bool { !sidebarCollapsed.contains(key) }

    func setSection(_ key: String, expanded: Bool) {
        // 值真的变了才设：观察的属性一设就重排整个侧栏（§21.12）
        if expanded, sidebarCollapsed.contains(key) { sidebarCollapsed.remove(key) }
        if !expanded, !sidebarCollapsed.contains(key) { sidebarCollapsed.insert(key) }
    }

    /// 文件夹在原地展开了没；默认收起
    func isRowExpanded(_ key: String) -> Bool { sidebarExpanded.contains(key) }

    func setRow(_ key: String, expanded: Bool) {
        if expanded, !sidebarExpanded.contains(key) { sidebarExpanded.insert(key) }
        if !expanded, sidebarExpanded.contains(key) { sidebarExpanded.remove(key) }
    }

    /// 点文件夹：在原地展开或收起（R101.2）
    func toggleRow(_ key: String) { setRow(key, expanded: !isRowExpanded(key)) }

    /// 下面的列表只看这个文件夹（展开后的「显示全部 N 场」）
    func showFolder(_ name: String) {
        sidebarMode = .meetings
        folderFilter = name
    }

    /// 文件夹里的会议（不含垃圾桶），日期新到旧（数据库读出来的顺序）
    func peekRows(folder: String) -> [MeetingRow] { meetings.filter { $0.meeting.folder == folder } }

    /// 点了展开的那一场：人物模式换回会议、选那场；下面的列表不换
    func openFromSidebar(_ id: Int64) {
        sidebarMode = .meetings
        selection = id
    }

    /// 下面的列表只放文件夹以外的会议（R101.6）。
    /// 没有看某个文件夹、没有筛选、不是依文件夹分组时才这样：筛选、依文件夹分组是要跨文件夹找东西。
    /// 还没有文件夹时就是所有会议
    var listShowsOthersOnly: Bool {
        !showTrash && folderFilter == nil && !meetingFilter.isActive
            && meetingGrouping != .folder && (meetings.contains { !$0.meeting.folder.isEmpty })
    }

    /// 程序带你去某场会议时（reveal），看得到它在哪里：在下面的列表就展开列表和那一组；
    /// 在文件夹里（下面的列表没有）就展开那个文件夹
    func expandToShow(_ id: Int64) {
        if let group = meetingGroups.first(where: { group in group.rows.contains { $0.id == id } }) {
            setSection("meetings", expanded: true)
            setSection(Self.groupKey(group), expanded: true)
        } else if let meeting = meetings.first(where: { $0.id == id })?.meeting {
            setSection("folders", expanded: true)
            if !meeting.folder.isEmpty {
                setRow(Self.folderKey(meeting.folder), expanded: true)
            }
        }
    }
}
