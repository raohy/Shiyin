import Foundation

/// 重命名的弹窗要改的东西（R102、design §76）
enum RenameTarget: Identifiable, Equatable {
    case meeting(Int64)
    case folder(String)
    /// 新文件夹：建立后把这几场会议移进去
    case newFolder([Int64])
    case person(Int64)
    case bookmark(Int64)

    var id: String { "\(self)" }
}

extension AppModel {
    /// 弹窗打开时输入框里的字
    func currentName(for target: RenameTarget) -> String {
        switch target {
        case .meeting(let id):
            guard let meeting = (meetings + trash).first(where: { $0.id == id })?.meeting ?? (try? db.meeting(id)) else { return "" }
            return meeting.title.isEmpty ? meeting.displayTitle : meeting.title
        case .folder(let name): return name
        case .newFolder: return ""
        case .person(let id):
            // 人物总览只在打开过人物列表后才有；没有时从数据库读
            return peopleOverview.first { $0.id == id }?.name ?? ((try? db.peopleSummaries()) ?? people).first { $0.id == id }?.name ?? ""
        case .bookmark(let id): return detail?.bookmarks.first { $0.id == id }?.label ?? ""
        }
    }

    /// 改成这个名字会跟别的东西合并时，那个东西的名字（文件夹同名、人物同名大小写不分）
    func renameConflict(for target: RenameTarget, name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        switch target {
        case .folder(let old):
            return name != old && folders.contains { $0.name == name } ? name : nil
        case .newFolder:
            return folders.contains { $0.name == name } ? name : nil
        case .person(let id):
            let all = peopleOverview.isEmpty ? ((try? db.peopleSummaries()) ?? people).map { ($0.id, $0.name) } : peopleOverview.map { ($0.id, $0.name) }
            return all.first { $0.0 != id && $0.1.caseInsensitiveCompare(name) == .orderedSame }?.1
        default:
            return nil
        }
    }

    /// 弹窗按「保存」（或「建立并移入」）
    func commitRename(_ target: RenameTarget, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch target {
        case .meeting(let id):
            guard let meeting = try? db.meeting(id), name != currentName(for: target) else { return }
            perform { try db.updateInfo(id, title: name, date: meeting.meetingDate, participants: meeting.participants) }
        case .folder(let old): renameFolder(old, to: name)
        case .newFolder(let ids):
            // 「+」建的是空的文件夹（R104），从会议的菜单建的会把会议移进去
            if ids.isEmpty { createFolder(name) } else { moveToFolder(ids, folder: name) }
        case .person(let id):
            renamePerson(id, to: name)
            // 改成已经有的名字时合并过去，选那个人
            if sidebarMode == .people {
                selectedPerson = peopleOverview.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            }
        case .bookmark(let id): renameBookmark(id, label: name)
        }
    }
}
