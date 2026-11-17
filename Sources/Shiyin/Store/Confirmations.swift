import Foundation

/// 要确认的事（R106、design §80）：原本各自的状态（confirmDeleteFolder 这些）照旧，主窗口依目前设了哪一个显示同一种确认弹窗
extension AppModel {
    var activeConfirmation: ConfirmRequest? {
        if let folder = confirmDeleteFolder {
            let count = meetings.filter { $0.meeting.folder == folder }.count
            return ConfirmRequest(id: "folder:" + folder, title: String(localized: "删除文件夹「\(folder)」？"),
                                  message: count > 0 ? String(localized: "里面的 \(count) 场会议会留着，移到「不在文件夹」。自动加入的条件也会删掉。")
                                                     : String(localized: "自动加入的条件也会删掉。"),
                                  confirmTitle: String(localized: "删除文件夹")) { self.deleteFolder(folder) }
        }
        if let id = confirmRemovePerson {
            let name = peopleOverview.first { $0.id == id }?.name ?? ""
            return ConfirmRequest(id: "person:\(id)", title: String(localized: "移除「\(name)」？"),
                                  message: String(localized: "会从「人物」拿掉，也会删掉他的声音特征。会议里已经带入的名字会留着，之后的会议不会再自动认出他。"),
                                  confirmTitle: String(localized: "移除")) {
                if self.selectedPerson == id { self.selectedPerson = nil }
                self.deletePerson(id)
            }
        }
        if let ids = confirmPurge {
            return ConfirmRequest(id: "purge:\(ids)", title: ids.count > 1 ? String(localized: "永久删除 \(ids.count) 场会议？")
                                                                         : String(localized: "永久删除这场会议？"),
                                  message: String(localized: "会议记录、逐字稿和录音都会删掉，没办法还原。"),
                                  confirmTitle: String(localized: "永久删除")) { self.deletePermanently(ids) }
        }
        if confirmEmptyTrash {
            return ConfirmRequest(id: "emptyTrash", title: String(localized: "永久删除垃圾桶里的 \(trash.count) 场会议？"),
                                  message: String(localized: "会议记录、逐字稿和录音都会删掉，没办法还原。"),
                                  confirmTitle: String(localized: "清空垃圾桶")) { self.emptyTrash() }
        }
        if let segment = splitMeetingRequest {
            let time = detail?.segments.first { $0.id == segment }.map { TimeFormat.string($0.start) } ?? ""
            return ConfirmRequest(id: "split:\(segment)", title: String(localized: "从 \(time) 这句开始分成另一场会议？"),
                                  message: String(localized: "这句和之后的逐字稿、录音、标记重点变成新的一场，前面的留在这场；我的笔记、参考文件、提问留在这场。两场都要刷新会议记录。分开后没办法合并回来。"),
                                  confirmTitle: String(localized: "分成两场"), destructive: false) { self.splitMeeting(at: segment) }
        }
        if confirmDelete {
            let ids = deleteTargets
            return ConfirmRequest(id: "trash:\(ids)", title: ids.count > 1 ? String(localized: "把 \(ids.count) 场会议移到垃圾桶？")
                                                                         : String(localized: "把这场会议移到垃圾桶？"),
                                  message: String(localized: "30 天内都可以从垃圾桶还原。"),
                                  confirmTitle: String(localized: "移到垃圾桶")) { self.moveToTrash(ids) }
        }
        return nil
    }

    /// 确认弹窗关掉（取消或做完）
    func clearConfirmations() {
        if confirmDeleteFolder != nil { confirmDeleteFolder = nil }
        if confirmRemovePerson != nil { confirmRemovePerson = nil }
        if confirmPurge != nil { confirmPurge = nil }
        if confirmEmptyTrash { confirmEmptyTrash = false }
        if splitMeetingRequest != nil { splitMeetingRequest = nil }
        if confirmDelete { confirmDelete = false }
    }
}
