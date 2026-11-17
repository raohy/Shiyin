import AppKit
import UniformTypeIdentifiers

// MARK: - 拖动（R103、design §77）

extension UTType {
    /// 拖的会议（id 用逗号分开），只在拾音里面（Info.plist 声明）
    static let shiyinMeetingIDs = UTType(exportedAs: "com.weiwei.shiyin.meeting-ids")
    /// 拖的文件夹（键：folder:名称）
    static let shiyinSidebarItem = UTType(exportedAs: "com.weiwei.shiyin.sidebar-item")
}

/// 侧栏「文件夹」那一段的一列
struct SidebarFolderItem: Identifiable {
    var name: String
    var count: Int

    var key: String { AppModel.folderKey(name) }
    var id: String { key }
}

extension AppModel {
    /// 「文件夹」那一段的顺序：拖动排过的照 sidebarOrder，没排过的（新的）在后面，照名称
    var sidebarFolderItems: [SidebarFolderItem] {
        let defaults = folders.map { SidebarFolderItem(name: $0.name, count: $0.count) }
        let rank = Dictionary(sidebarOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return defaults.enumerated().sorted { a, b in
            switch (rank[a.element.key], rank[b.element.key]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// 把一个文件夹拖到另一个的前面或后面
    func moveSidebarItem(_ key: String, to target: String, before: Bool) {
        var keys = sidebarFolderItems.map(\.key)
        guard key != target, let from = keys.firstIndex(of: key) else { return }
        keys.remove(at: from)
        guard let to = keys.firstIndex(of: target) else { return }
        keys.insert(key, at: before ? to : to + 1)
        sidebarOrder = keys
    }

    /// 往上、往下移一格（VoiceOver 的动作）
    func moveSidebarItem(_ key: String, by offset: Int) {
        let keys = sidebarFolderItems.map(\.key)
        guard let i = keys.firstIndex(of: key), keys.indices.contains(i + offset) else { return }
        moveSidebarItem(key, to: keys[i + offset], before: offset < 0)
    }

    /// 拖一场会议时带的会议：在多选里就是整个多选（列表的顺序）
    func dragIDs(for id: Int64) -> [Int64] {
        let multi = multiSelected
        return multi.count > 1 && multi.contains(id) ? multi : [id]
    }

    /// 点下面列表的会议（design §77）：一般是只选这场；⌘ 加入或拿掉；⇧ 从上一次点的那场选到这场（照列表看到的顺序）
    func clickMeetingRow(_ id: Int64, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            var ids = listSelection
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            listSelection = ids
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? selection {
            let order = meetingGroups.flatMap(\.rows).map(\.id)
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                listSelection = Set(order[min(a, b)...max(a, b)])
            } else {
                listSelection = [id]
            }
        } else {
            listSelection = [id]
            selectionAnchor = id
        }
    }

    /// 会议拖到下面列表的标题：移进现在看的文件夹；「其他会议」是移出文件夹
    func dropOnListHeader(_ ids: [Int64]) {
        if let folder = folderFilter {
            moveToFolder(ids, folder: folder)
        } else if listShowsOthersOnly {
            let inFolder = ids.filter { id in !(meetings.first { $0.id == id }?.meeting.folder.isEmpty ?? true) }
            if inFolder.isEmpty {
                noticeMessage = ids.count == 1 ? String(localized: "这场会议没有在任何文件夹里") : String(localized: "这些会议都没有在文件夹里")
            } else {
                moveToFolder(inFolder, folder: "")
            }
        }
    }

    /// 下面列表的标题能不能收会议（看所有会议、有筛选时不行）
    var listHeaderAcceptsMeetings: Bool {
        !showTrash && (folderFilter != nil || listShowsOthersOnly)
    }

    /// 从 Finder 拖到文件夹上的文件：导入到那个文件夹（R103.3）；参考文件（PDF 这类）要拖到会议页
    func importDropped(_ urls: [URL], into folder: String) {
        let files = urls.filter { !DocumentReader.isDroppedDocument($0) }
        if files.isEmpty {
            errorMessage = String(localized: "参考文件请拖到会议页，会加进那场会议")
            return
        }
        importFolderOverride = folder
        requestImport(files)
        importFolderOverride = nil
        if showImportSheet { pendingImportFolder = folder }
    }
}
