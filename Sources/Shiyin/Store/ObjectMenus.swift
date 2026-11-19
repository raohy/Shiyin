import AppKit

/// 「⋯」和右键菜单的内容（R105、design §79）：每一种东西一份，自己画的菜单（FloatingMenu）用。
/// 工具列的「更多」照旧是系统菜单（ObjectActions 的 SwiftUI 版本）
extension AppModel {
    /// 侧栏的会议（一场或多选的好几场）
    func meetingMenu(_ ids: [Int64]) -> [MenuEntry] {
        if showTrash {
            return [.action(String(localized: "还原"), icon: "arrow.uturn.backward") { self.restore(ids) },
                    .action(String(localized: "永久删除…"), icon: "trash", destructive: true) { self.confirmPurge = ids }]
        }
        guard !ids.isEmpty else { return [] }
        var entries: [MenuEntry] = []
        if ids.count == 1, let id = ids.first {
            entries.append(.action(String(localized: "重命名…"), icon: "pencil", shortcut: "↩") { self.requestRenameMeeting(id) })
            // 编辑会议（R107.1）；编辑过的会议多一项还原，写还剩几天（R107.8）
            entries.append(.action(String(localized: "编辑会议…"), icon: "scissors") { self.requestEditMeeting(id) })
            if let record = try? db.editRecord(id) {
                entries.append(.action(String(localized: "还原成编辑前的样子…"), icon: "arrow.uturn.backward",
                                       shortcut: String(localized: "还有 \(record.daysLeft()) 天")) { self.requestRestoreEdit(id) })
            }
            entries.append(.divider)
        }
        entries.append(.submenu(String(localized: "移到文件夹"), icon: "folder", folderMoveEntries(ids)))
        entries.append(.divider)
        if ids.count == 1 {
            entries.append(.action(String(localized: "移到垃圾桶"), icon: "trash", shortcut: "⌘⌫", destructive: true) { self.moveToTrash(ids) })
        } else {
            entries.append(.action(String(localized: "把 \(ids.count) 场会议移到垃圾桶…"), icon: "trash", destructive: true) {
                self.deleteTargets = ids
                self.confirmDelete = true
            })
        }
        return entries
    }

    /// 「移到文件夹 ›」：别的文件夹、新文件夹、移出
    private func folderMoveEntries(_ ids: [Int64]) -> [MenuEntry] {
        let current = commonFolder(ids)
        let targets = folders.filter { current == nil || $0.name != current }
        var entries: [MenuEntry] = targets.map { f in .action(f.name, icon: "folder") { self.moveToFolder(ids, folder: f.name) } }
        if !entries.isEmpty { entries.append(.divider) }
        entries.append(.action(String(localized: "新文件夹…"), icon: "folder.badge.plus") { self.renameTarget = .newFolder(ids) })
        if current == nil {
            entries.append(.action(String(localized: "移出文件夹"), icon: "minus.circle") { self.moveToFolder(ids, folder: "") })
        } else if let current, !current.isEmpty {
            entries.append(.action(String(localized: "移出「\(current)」"), icon: "minus.circle") { self.moveToFolder(ids, folder: "") })
        }
        return entries
    }

    func folderMenu(_ folder: String) -> [MenuEntry] {
        [.action(String(localized: "重命名…"), icon: "pencil") { self.renameTarget = .folder(folder) },
         .action(folderRule(folder) == nil ? String(localized: "自动加入的条件…") : String(localized: "编辑自动加入的条件…"), icon: "gearshape") {
             self.editingFolderRule = folder
         },
         .divider,
         .action(String(localized: "删除文件夹…"), icon: "trash", destructive: true) { self.confirmDeleteFolder = folder }]
    }

    func personMenu(_ person: PersonOverview) -> [MenuEntry] {
        let others = peopleOverview.filter { $0.id != person.id }
        var entries: [MenuEntry] = [.action(String(localized: "重命名…"), icon: "pencil", shortcut: "↩") {
            self.selectedPerson = person.id
            self.renameTarget = .person(person.id)
        }]
        if !others.isEmpty {
            entries.append(.submenu(String(localized: "合并到"), icon: "person.2", others.map { other in
                .action(other.name) {
                    self.renamePerson(person.id, to: other.name)
                    self.selectedPerson = other.id
                }
            }))
        }
        entries += [.divider,
                    .action(String(localized: "移除这个人…"), icon: "person.crop.circle.badge.minus", destructive: true) { self.confirmRemovePerson = person.id }]
        return entries
    }

    /// 人物页里的一场会议：打开
    func meetingLinkMenu(_ meeting: Meeting) -> [MenuEntry] {
        guard let id = meeting.id else { return [] }
        return [.action(String(localized: "打开这场会议"), icon: "arrow.up.forward.app") { self.openFromPersonPage(id) }]
    }

    /// 会议记录的一条：拷贝、从这里播放、编辑、删除
    func noteItemMenu(_ ref: NoteItemRef, text: String, time: String) -> [MenuEntry] {
        var entries: [MenuEntry] = [.action(String(localized: "拷贝"), icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }]
        if let seconds = TimeFormat.seconds(time), player.isLoaded {
            entries.append(.action(String(localized: "从这里播放"), icon: "play") { self.player.seek(to: seconds) })
        }
        entries += [.divider,
                    .action(String(localized: "编辑这一条"), icon: "pencil", enabled: canEditNotes) { self.editingNoteItem = ref },
                    .action(String(localized: "删除这一条"), icon: "trash", destructive: true, enabled: canEditNotes) { self.deleteNoteItem(ref) }]
        return entries
    }
}
