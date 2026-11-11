import Foundation
import UserNotifications

/// 系统通知（design §10、R12）。没有授权就不发，其他功能不受影响。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((Int64) -> Void)?
    /// 检测到会议的通知按钮（design §21.7）：动作（start、mute、stop、continue）、哪个 app
    var onMeetingAction: ((String, String) -> Void)?
    /// 忘了停止录音的通知按钮（design §35.2）：stop、continue
    var onIdleAction: ((String) -> Void)?
    #if DEBUG
    /// 验证用：最近要发的通知内容（没有通知权限时也记录）
    private(set) var recent: [[String: Any]] = []
    #endif

    func activate() {
        UNUserNotificationCenter.current().delegate = self
        let start = UNNotificationCategory(identifier: "MEETING_START", actions: [
            UNNotificationAction(identifier: "start", title: String(localized: "开始录音"), options: []),
            UNNotificationAction(identifier: "mute", title: String(localized: "不要再提醒这个 app"), options: []),
        ], intentIdentifiers: [])
        let stop = UNNotificationCategory(identifier: "MEETING_STOP", actions: [
            UNNotificationAction(identifier: "stop", title: String(localized: "停止并转录"), options: []),
            UNNotificationAction(identifier: "continue", title: String(localized: "继续录"), options: []),
        ], intentIdentifiers: [])
        let idle = UNNotificationCategory(identifier: "IDLE_PROMPT", actions: [
            UNNotificationAction(identifier: "stop", title: String(localized: "停止录音"), options: []),
            UNNotificationAction(identifier: "continue", title: String(localized: "继续录"), options: []),
        ], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([start, stop, idle])
    }

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// 检测到会议（design §21.7）
    func meetingPrompt(_ prompt: MeetingDetector.Prompt) {
        let content = UNMutableNotificationContent()
        switch prompt {
        case .start(let app):
            content.title = String(localized: "\(app.name) 正在开会")
            content.body = String(localized: "要开始录音吗？")
            content.categoryIdentifier = "MEETING_START"
            content.userInfo = ["bundle": app.bundleID]
        case .stop(let app):
            content.title = String(localized: "会议好像结束了")
            content.body = String(localized: "要停止录音并转录吗？")
            content.categoryIdentifier = "MEETING_STOP"
            content.userInfo = ["bundle": app.bundleID]
        }
        content.sound = .default
        post(content)
    }

    /// 收音提醒（R42.1、design §31.5）：内容跟录音画面同一句，点了打开录音中的会议
    /// `kind` 是提示的种类（silent、quiet、noisy、bluetooth），只给 DEBUG 的记录
    func levelHint(_ text: String, kind: String, meetingId: Int64) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "收音提醒")
        content.body = text
        content.categoryIdentifier = "LEVEL_HINT"
        content.sound = .default
        content.userInfo = ["meetingId": NSNumber(value: meetingId)]
        #if DEBUG
        recent = Array(([["title": content.title, "body": content.body, "meetingId": meetingId, "hint": kind]] + recent).prefix(10))
        #endif
        post(content)
    }

    /// 录音中很久没人说话（R48.1）：按钮「停止录音」「继续录」，点通知本身打开录音中的会议
    func idlePrompt(meetingId: Int64) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "好像没人在说话了")
        content.body = String(localized: "要停止录音吗？再 15 分钟没人说话会自动停止。")
        content.categoryIdentifier = "IDLE_PROMPT"
        content.sound = .default
        content.userInfo = ["meetingId": NSNumber(value: meetingId), "idle": true]
        #if DEBUG
        recent = Array(([["title": content.title, "body": content.body, "meetingId": meetingId, "idle": "prompt"]] + recent).prefix(10))
        #endif
        post(content)
    }

    /// 没人说话太久，自动停止了（R48.2）：点了打开那场会议
    func idleStopped(meetingId: Int64, title: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "已自动停止录音")
        content.body = String(localized: "\(title)：30 分钟没有人说话")
        content.sound = .default
        content.userInfo = ["meetingId": NSNumber(value: meetingId)]
        #if DEBUG
        recent = Array(([["title": content.title, "body": content.body, "meetingId": meetingId, "idle": "stopped"]] + recent).prefix(10))
        #endif
        post(content)
    }

    func jobFinished(_ job: Job, meeting: Meeting, error: Error?) {
        let content = UNMutableNotificationContent()
        let title = meeting.displayTitle
        if let error {
            content.title = job.kind == .transcribe ? String(localized: "转录失败") : String(localized: "整理失败")
            // 只取第一行（design §40.2）：额度用完的第二行是 CLI 的原文，放不下就不要挤进来
            let firstLine = error.localizedDescription.split(whereSeparator: \.isNewline).first.map(String.init) ?? error.localizedDescription
            content.body = String(localized: "\(title)：\(String(firstLine.prefix(60)))")
        } else if job.kind == .transcribe {
            content.title = String(localized: "转录完成")
            content.body = title
        } else if job.kind == .summarize, let payload = job.payload,
                  (try? JSONDecoder().decode(SummarizePayload.self, from: Data(payload.utf8)))?.draft == true {
            content.title = String(localized: "会议记录草稿好了")
            content.body = String(localized: "\(title)（正式转录完成后会自动更新）")
        } else {
            let count = meeting.decodedNotes?.reviewItems.count ?? 0
            content.title = String(localized: "会议记录整理好了")
            content.body = count > 0 ? String(localized: "\(title)，有 \(count) 题待确认") : title
        }
        content.sound = .default
        content.userInfo = ["meetingId": NSNumber(value: meeting.id ?? 0)]
        #if DEBUG
        recent = Array(([["title": content.title, "body": content.body, "meetingId": meeting.id ?? 0]] + recent).prefix(10))
        #endif
        post(content)
    }

    private func post(_ content: UNNotificationContent) {
        let center = UNUserNotificationCenter.current()
        Task {
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do { try await center.add(request) } catch { log.error("notification failed: \(error.localizedDescription)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["meetingId"] as? NSNumber)?.int64Value
        let bundle = response.notification.request.content.userInfo["bundle"] as? String
        let idle = response.notification.request.content.userInfo["idle"] as? Bool ?? false
        let action = response.actionIdentifier
        Task { @MainActor in
            let button = action != UNNotificationDefaultActionIdentifier && action != UNNotificationDismissActionIdentifier
            if let bundle, button {
                self.onMeetingAction?(action, bundle)
            } else if idle, button {
                self.onIdleAction?(action)
            } else if let id, id > 0 { self.onOpen?(id) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
