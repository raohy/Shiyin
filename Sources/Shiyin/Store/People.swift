import Foundation
import GRDB

/// 侧栏「人物」的一列（design §60.1、R85.1）
struct PersonOverview: Identifiable, Hashable {
    var id: Int64
    var name: String
    var meetingCount: Int
    var lastMeetingDate: String?
    /// 录过「我的声音」的人（R80）
    var isMe: Bool
}

/// 人物页的一场会议：他说了多久（秒）
struct PersonMeeting: Identifiable, Hashable {
    var meeting: Meeting
    var seconds: Double
    var id: Int64 { meeting.id ?? 0 }
}

/// 人物页的一条待办：负责人是他（R85.3）
struct PersonActionItem: Identifiable, Hashable {
    var meeting: Meeting
    var index: Int
    var item: MeetingNotes.ActionItem
    var id: String { "\(meeting.id ?? 0)-\(index)" }
}

extension AppDatabase {
    /// 认识的人：一起开过几场（不在垃圾桶的）、最近一场的日期；我排第一，其他照最近一场由新到旧
    func peopleOverview() throws -> [PersonOverview] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name,
                  (SELECT count(DISTINCT s.meeting_id) FROM speakers s JOIN meetings m ON m.id = s.meeting_id
                     WHERE s.person_id = p.id AND m.deleted_at IS NULL) AS meetings,
                  (SELECT max(m.meeting_date) FROM speakers s JOIN meetings m ON m.id = s.meeting_id
                     WHERE s.person_id = p.id AND m.deleted_at IS NULL) AS last_date,
                  EXISTS (SELECT 1 FROM voiceprints v WHERE v.person_id = p.id AND v.audio_source = 'enroll') AS me
                FROM people p
                """).map { row in
                    PersonOverview(id: row["id"], name: row["name"], meetingCount: row["meetings"],
                                   lastMeetingDate: row["last_date"], isMe: row["me"])
                }
        }
        .sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            if a.lastMeetingDate != b.lastMeetingDate { return (a.lastMeetingDate ?? "") > (b.lastMeetingDate ?? "") }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 他出现过的会议（不在垃圾桶），说了多久是那场他的说话者的正式逐字稿加总；照日期由新到旧
    func personMeetings(_ personId: Int64) throws -> [PersonMeeting] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.meeting_id,
                  (SELECT COALESCE(SUM(g."end" - g.start), 0) FROM segments g
                     WHERE g.meeting_id = s.meeting_id AND g.kind = 'final' AND g.speaker = s.idx) AS seconds
                FROM speakers s JOIN meetings m ON m.id = s.meeting_id
                WHERE s.person_id = ? AND m.deleted_at IS NULL
                """, arguments: [personId])
            var seconds: [Int64: Double] = [:]
            for row in rows { seconds[row["meeting_id"], default: 0] += row["seconds"] }
            return try seconds.compactMap { id, total in
                try Meeting.fetchOne(db, key: id).map { PersonMeeting(meeting: $0, seconds: total) }
            }
            .sorted { ($0.meeting.meetingDate, $0.id) > ($1.meeting.meetingDate, $1.id) }
        }
    }

    /// 负责人跟名字一样或包含名字（不分大小写，同本地 MCP 的 list_action_items）的待办；照会议日期由新到旧、会议里的顺序
    func personActionItems(_ name: String) throws -> [PersonActionItem] {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }
        let meetings = try pool.read { db in
            try Meeting.filter(Column("deleted_at") == nil && Column("notes") != nil && Column("notes") != "")
                .order(sql: "meeting_date DESC, id DESC").fetchAll(db)
        }
        return meetings.flatMap { meeting -> [PersonActionItem] in
            guard let notes = meeting.decodedNotes else { return [] }
            return notes.actionItems.enumerated().compactMap { index, item in
                item.owner.range(of: target, options: .caseInsensitive) != nil
                    ? PersonActionItem(meeting: meeting, index: index, item: item) : nil
            }
        }
    }
}

/// 侧栏是会议还是人物（design §60.2）
enum SidebarMode: String {
    case meetings, people
}

/// 人物页（design §60、R85）
extension AppModel {
    func reloadPeopleOverview() {
        peopleOverview = (try? db.peopleOverview()) ?? []
        if let selected = selectedPerson, !peopleOverview.contains(where: { $0.id == selected }) { selectedPerson = nil }
    }

    /// 从人物页打开一场会议（切回「会议」）；有时间点时从那里播放
    func openFromPersonPage(_ meetingId: Int64, seconds: Double? = nil) {
        sidebarMode = .meetings
        if let seconds {
            openMeetingLink(meetingId, seconds: seconds, activate: false)
        } else {
            reveal(meetingId)
        }
    }

    /// 他负责的待办一次加到提醒事项（R85.2、§52）：照各自的会议加，加过的不重复
    func addPersonItemsToReminders(_ items: [PersonActionItem]) {
        guard !items.isEmpty, !addingReminders else { return }
        addingReminders = true
        Task {
            defer { addingReminders = false }
            let store = Reminders.store
            if store.access == .notDetermined { _ = await store.requestAccess() }
            guard store.access == .granted else {
                errorMessage = String(localized: "拾音没有使用提醒事项的权限：请到「系统设置 → 隐私与安全性 → 提醒事项」允许拾音。")
                return
            }
            do {
                let list = try store.list()
                var added = 0
                for (meetingId, group) in Dictionary(grouping: items, by: { $0.meeting.id ?? 0 }) {
                    guard let meeting = group.first?.meeting, let notes = meeting.decodedNotes else { continue }
                    let keys = Set(group.map { Reminders.key($0.item.task) })
                    let existing = try await store.existing(meetingId: meetingId)
                    let fresh = Reminders.items(meeting: meeting, notes: notes).filter { keys.contains($0.key) && existing[$0.key] == nil }
                    try store.add(fresh, to: list)
                    added += fresh.count
                }
                noticeMessage = added == 0 ? String(localized: "这些待办都已经在提醒事项了")
                    : String(localized: "已加到提醒事项的「\(Reminders.listTitle)」列表：\(added) 项")
            } catch {
                errorMessage = String(localized: "没办法加到提醒事项：\(error.localizedDescription)")
            }
        }
    }
}
