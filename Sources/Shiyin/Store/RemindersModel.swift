import AppKit
import Foundation

/// 待办加进「提醒事项」（design §52、R76）
extension AppModel {
    /// 记录标签页「待办」旁的按钮：把这场会议的待办加进「拾音」列表，加过的不重复加（R76.3）
    func addActionItemsToReminders() {
        guard let detail, let notes = detail.notes, !notes.actionItems.isEmpty, !addingReminders else { return }
        let meeting = detail.meeting
        addingReminders = true
        Task {
            defer { addingReminders = false }
            let store = Reminders.store
            if store.access == .notDetermined { _ = await store.requestAccess() }
            guard store.access == .granted else {
                showRemindersDenied()
                return
            }
            do {
                let list = try store.list()
                let existing = try await store.existing(meetingId: meeting.id ?? 0)
                let items = Reminders.items(meeting: meeting, notes: notes).filter { existing[$0.key] == nil }
                if items.isEmpty {
                    noticeMessage = String(localized: "这场的待办都已经在提醒事项了")
                } else {
                    try store.add(items, to: list)
                    noticeMessage = String(localized: "已加到提醒事项的「\(Reminders.listTitle)」列表：\(items.count) 项")
                }
                if self.detail?.meeting.id == meeting.id { reminderStatus = try await store.existing(meetingId: meeting.id ?? 0) }
            } catch {
                errorMessage = String(localized: "没办法加到提醒事项：\(error.localizedDescription)")
            }
        }
    }

    /// 打开会议、回到前景时读一次（R76.4）。还没允许过就不读，不会因此跳出权限询问
    func refreshReminderStatus() {
        guard let id = detail?.meeting.id else {
            reminderStatus = [:]
            return
        }
        let store = Reminders.store
        guard store.access == .granted else {
            if !reminderStatus.isEmpty { reminderStatus = [:] }
            return
        }
        Task {
            let status = (try? await store.existing(meetingId: id)) ?? [:]
            if detail?.meeting.id == id, status != reminderStatus { reminderStatus = status }
        }
    }

    /// 拒绝或之前拒绝过（R76.5）
    private func showRemindersDenied() {
        let alert = NSAlert()
        alert.messageText = String(localized: "拾音没有使用提醒事项的权限")
        alert.informativeText = String(localized: "请到「系统设置 → 隐私与安全性 → 提醒事项」允许拾音，再按一次「加到提醒事项」。")
        alert.addButton(withTitle: String(localized: "打开系统设置"))
        alert.addButton(withTitle: String(localized: "取消"))
        if alert.runModal() == .alertFirstButtonReturn { Recorder.openPrivacySettings("Privacy_Reminders") }
    }
}
