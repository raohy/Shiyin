import Foundation

/// 每一种东西都能直接改、删（R100、design §74）
extension AppModel {
    /// 重命名一场会议：打开重命名的弹窗（R102；日期、与会者照旧在会议页的「编辑」改）
    func requestRenameMeeting(_ id: Int64) {
        renameTarget = .meeting(id)
    }

    /// 记录能不能就地改：有记录、不在垃圾桶、没在录这场、没在整理（同「编辑」按钮）
    var canEditNotes: Bool {
        guard let detail, detail.notes != nil, detail.meeting.deletedAt == nil else { return false }
        return detailStatus?.isActive != true && recorder.meetingId != detail.meeting.id
    }

    /// 就地改一条记录（双击、右键「编辑这一条」）：存成一个版本，同手动编辑
    func editNoteItem(_ ref: NoteItemRef, text: String) {
        editingNoteItem = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditNotes, let id = detail?.meeting.id, var notes = detail?.notes, !trimmed.isEmpty,
              notes.text(at: ref) != trimmed else { return }
        notes.setText(trimmed, at: ref)
        saveEditedNotes(notes, meetingId: id)
    }

    /// 删除一条记录：不确认，可以用「复原上一版会议记录」还原
    func deleteNoteItem(_ ref: NoteItemRef) {
        guard canEditNotes, let id = detail?.meeting.id, var notes = detail?.notes, notes.text(at: ref) != nil else { return }
        if editingNoteItem == ref { editingNoteItem = nil }
        notes.remove(at: ref)
        saveEditedNotes(notes, meetingId: id)
        noticeMessage = String(localized: "已删除一条记录，按「编辑」旁的「复原上一版」可以还原")
    }

    func renameBookmark(_ id: Int64, label: String) {
        perform(.detail([.bookmarks])) { try db.renameBookmark(id, label: label.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func renameTerm(_ id: Int64, to term: String) { perform { try db.renameTerm(id, to: term) } }

    // MARK: 侧栏的键盘：照现在选到、亮起来的是什么

    /// Return：重命名。回传有没有处理
    func sidebarReturn() -> Bool {
        guard !showTrash else { return false }
        if sidebarMode == .people {
            guard let id = selectedPerson else { return false }
            renameTarget = .person(id)
            return true
        }
        if selectedMeetings.count > 1 { return false }
        if let id = selection {
            requestRenameMeeting(id)
        } else if let folder = folderFilter {
            renameTarget = .folder(folder)
        } else {
            return false
        }
        return true
    }

    /// Delete：删除或移除（都先确认）
    func sidebarDelete() {
        if sidebarMode == .people && !showTrash {
            if let id = selectedPerson { confirmRemovePerson = id }
            return
        }
        let ids = multiSelected.isEmpty ? [selection].compactMap { $0 } : multiSelected
        if !ids.isEmpty {
            if showTrash {
                confirmPurge = ids
            } else {
                deleteTargets = ids
                confirmDelete = true
            }
        } else if !showTrash, let folder = folderFilter {
            confirmDeleteFolder = folder
        }
    }
}
