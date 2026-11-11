import AppKit
import Foundation

/// 会议的参考文档（design §39.4、R61）：加入、移除、打开，文档有变动的提示
extension AppModel {
    /// 「加入文档…」：选档后加到选中中的会议
    func chooseDocuments() {
        guard let id = selection else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentReader.openPanelTypes
        panel.message = String(localized: "选择会议中一起讨论的文档（PDF、Word、PowerPoint、纯文字、图片）")
        panel.prompt = String(localized: "加入")
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self.addDocuments(urls, to: id) }
        }
    }

    /// 拖进主窗口的文档：加到选中中的会议（R61.1）
    func addDroppedDocuments(_ urls: [URL]) {
        guard let id = selection, let meeting = try? db.meeting(id), meeting.deletedAt == nil else {
            errorMessage = String(localized: "先选一场会议，再把文档拖进来")
            return
        }
        addDocuments(urls, to: id)
    }

    /// 一份一份依序读（加入的顺序固定），读取中记在 readingDocuments；读完复制源文件、写数据库
    func addDocuments(_ urls: [URL], to meetingId: Int64) {
        guard !urls.isEmpty, let meeting = try? db.meeting(meetingId) else { return }
        let language = meeting.meetingLanguage
        let db = db
        readingDocuments[meetingId, default: []] += urls.map(\.lastPathComponent)
        Task {
            var added: [MeetingDocument] = []
            var failures: [String] = []
            for url in urls {
                do {
                    added.append(try await Task.detached(priority: .userInitiated) {
                        try DocumentStore.add(url, meetingId: meetingId, language: language, db: db)
                    }.value)
                } catch {
                    failures.append(error.localizedDescription)
                }
                if var names = readingDocuments[meetingId], let index = names.firstIndex(of: url.lastPathComponent) {
                    names.remove(at: index)
                    readingDocuments[meetingId] = names.isEmpty ? nil : names
                }
                if selection == meetingId { reloadDetail(.documents) }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            guard !added.isEmpty else { return }
            if added.count == 1 {
                let name = added[0].name
                noticeMessage = added[0].ocr ? String(localized: "已加入「\(name)」，用文字识别读出文字") : String(localized: "已加入「\(name)」")
            } else {
                noticeMessage = String(localized: "已加入 \(added.count) 份文档")
            }
            markDocumentsChanged(meetingId)
        }
    }

    /// 移除：不另外确认（重新加入就回来了）
    func removeDocument(_ document: MeetingDocument) {
        guard let id = document.id else { return }
        perform(.detail([.documents])) { try db.deleteDocument(id) }
        noticeMessage = String(localized: "已移除「\(document.name)」")
        markDocumentsChanged(document.meetingId)
    }

    func openDocument(_ document: MeetingDocument) {
        guard FileManager.default.fileExists(atPath: document.fileURL.path) else {
            errorMessage = String(localized: "找不到「\(document.name)」的源文件")
            return
        }
        NSWorkspace.shared.open(document.fileURL)
    }

    /// 已经有会议记录（含草稿）时，记录标签页顶部提示刷新（R61.8）
    private func markDocumentsChanged(_ meetingId: Int64) {
        if (try? db.meeting(meetingId))?.notes != nil { documentsChanged.insert(meetingId) }
    }

    func dismissDocumentsChanged() {
        if let id = selection { documentsChanged.remove(id) }
    }
}

/// 存参考文档：读出文字、写数据库、复制源文件（design §39.1、§39.4）；封包导入也用
enum DocumentStore {
    static func add(_ url: URL, meetingId: Int64, language: MeetingLanguage, db: AppDatabase) throws -> MeetingDocument {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let result = try DocumentReader.read(url, language: language)
        // 同一份（文件名和读出来的文字都一样）加过了就不再加：送给整理工具会重复
        let name = safeName(url.lastPathComponent)
        if try db.documents(meetingId).contains(where: { $0.name == name && $0.pageTexts == result.pages }) {
            throw DocumentReader.DocumentError.duplicate(name)
        }
        return try save(url, name: url.lastPathComponent, kind: result.kind, pages: result.pages, ocr: result.ocr,
                        meetingId: meetingId, db: db)
    }

    /// 写数据库（拿到 id）再复制源文件到 documents/<id>/<文件名>；复制失败就把那一列删掉
    static func save(_ source: URL, name: String, kind: DocumentKind, pages: [String], ocr: Bool,
                     meetingId: Int64, db: AppDatabase) throws -> MeetingDocument {
        let document = try db.addDocument(meetingId, name: safeName(name), kind: kind, pages: pages, ocr: ocr)
        do {
            let destination = Paths.documentsDir.appendingPathComponent(document.file)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            _ = try? db.deleteDocument(document.id!)
            throw error
        }
        return document
    }

    /// 文件名只取最后一段、去掉开头的「.」；是空的就叫 document
    static func safeName(_ name: String) -> String {
        let last = String((name as NSString).lastPathComponent.drop { $0 == "." })
        return last.isEmpty ? "document" : last
    }
}
