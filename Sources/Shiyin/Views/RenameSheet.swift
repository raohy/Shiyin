import SwiftUI

/// 重命名的弹窗（R102、design §76）：标题、一行说明、带目前名字的输入框、取消／保存。
/// 会议、文件夹、新文件夹、人物、标记都用这一个
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: RenameTarget
    @State private var name = ""
    @State private var original = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「+」建空的文件夹时，同名的已经有就不能建（R104）
        let canSave = !trimmed.isEmpty && (isNewFolder || trimmed != original) && !(isEmptyNewFolder && model.renameConflict(for: target, name: trimmed) != nil)
        // 共用的弹窗组件（design §80）
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: title, subtitle: hint(trimmed))
            SheetTextField(placeholder: placeholder, text: $name, focusOnAppear: true) { if canSave { save() } }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(isEmptyNewFolder ? String(localized: "建立") : isNewFolder ? String(localized: "建立并移入") : String(localized: "保存")) { save() }
                    .buttonStyle(SheetPillButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .sheetChrome()
        .onAppear {
            original = model.currentName(for: target)
            name = original
        }
    }

    private var isNewFolder: Bool { if case .newFolder = target { true } else { false } }
    private var isEmptyNewFolder: Bool { if case .newFolder(let ids) = target { ids.isEmpty } else { false } }

    private func save() {
        model.commitRename(target, to: name)
        dismiss()
    }

    private var title: String {
        switch target {
        case .meeting: String(localized: "重命名会议")
        case .folder: String(localized: "重命名文件夹")
        case .newFolder: String(localized: "新文件夹")
        case .person: String(localized: "重命名这个人")
        case .bookmark: String(localized: "重命名标记")
        }
    }

    private var placeholder: String {
        switch target {
        case .folder, .newFolder: String(localized: "文件夹名称")
        case .person: String(localized: "名字")
        default: String(localized: "名称")
        }
    }

    /// 说明；改成会合并的名字时换成提醒
    private func hint(_ name: String) -> String {
        if let other = model.renameConflict(for: target, name: name) {
            switch target {
            case .newFolder(let ids) where ids.isEmpty: return String(localized: "已经有「\(other)」。")
            case .newFolder: return String(localized: "已经有「\(other)」，会议会移进那个文件夹。")
            default: return String(localized: "已经有「\(other)」，保存后会合并成一个。")
            }
        }
        switch target {
        case .meeting: return String(localized: "保持简短、容易识别。日期和与会者在会议页的「编辑」改。")
        case .folder: return String(localized: "文件夹里的会议都会跟着改。")
        case .newFolder(let ids) where ids.isEmpty: return String(localized: "例如项目名称或客户名称。")
        case .newFolder(let ids):
            return ids.count > 1 ? String(localized: "例如项目名称或客户名称。这 \(ids.count) 场会议会移进新文件夹。")
                                 : String(localized: "例如项目名称或客户名称。这场会议会移进新文件夹。")
        case .person: return String(localized: "所有会议里的这个人都会跟着改。")
        case .bookmark(let id):
            let time = model.detail?.bookmarks.first { $0.id == id }?.time ?? 0
            return String(localized: "\(TimeFormat.string(time)) 的标记")
        }
    }
}
