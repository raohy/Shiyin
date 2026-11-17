import SwiftUI

// 每一种东西都能直接改、删（R100、design §74）：画面上的「⋯」、右键、「更多」用同一份菜单内容

/// 菜单里会删掉、移除东西的项目：红色的字和图标（R101）。macOS 的菜单不会照 role 变色，
/// 要自己上色；title 已经查过字符串表（调用的地方用 `String(localized:)`）
struct DestructiveMenuButton: View {
    let title: String
    var systemImage = "trash"
    let action: () -> Void

    init(_ title: String, systemImage: String = "trash", action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            Label { Text(verbatim: title).foregroundStyle(.red) } icon: { Image(systemName: systemImage).foregroundStyle(.red) }
        }
        // 菜单的图标用主色画（字用前景色）
        .tint(.red)
    }
}

extension View {
    /// 菜单项目显示图标（macOS 的菜单默认只显示文字；R101）；图标跟字同色，不用 app 的主色
    func menuIcons() -> some View { labelStyle(.titleAndIcon).tint(.primary) }
}

// MARK: - 记录的条目（R100、design §74）

/// 一条记录的动作：双击就地改、右键、滑过时行尾的「⋯」。ref 是 nil（不是这场会议的记录）时什么都不加
private struct NoteItemActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let ref: NoteItemRef?
    let text: String
    let time: String

    func body(content: Content) -> some View {
        if let ref {
            content
                // 整行（含行尾空白）都可以右键、双击：先撑满整行再设可点的范围（反过来的话只有字的范围收得到；
                // 2026-11-16 自己验收时发现）。文字不当成可选中（selectableUnlessEditable），右键才是这一份
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if model.canEditNotes { model.editingNoteItem = ref } }
                .floatingRowMenu { model.noteItemMenu(ref, text: text, time: time) }
        } else {
            content
        }
    }
}

extension View {
    func noteItemActions(ref: NoteItemRef?, text: String, time: String) -> some View {
        modifier(NoteItemActions(ref: ref, text: text, time: time))
    }
}

/// 就地改一条记录：Return 保存、Esc 取消；待办只改事项
struct NoteItemEditor: View {
    @Environment(AppModel.self) private var model
    let ref: NoteItemRef
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.sheet)
                .focused($focused)
                .onSubmit { model.editNoteItem(ref, text: text) }
                .onExitCommand { model.editingNoteItem = nil }
            HStack(spacing: 8) {
                Text("Return 保存、Esc 取消").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.editingNoteItem = nil }
                    .buttonStyle(SheetPillButtonStyle(.secondary, compact: true))
                Button("保存") { model.editNoteItem(ref, text: text) }
                    .buttonStyle(SheetPillButtonStyle(.primary, compact: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            text = model.detail?.notes?.text(at: ref) ?? ""
            focused = true
        }
    }
}

extension View {
    /// 能直接改的记录（R100）不开文字选中：开了的话右键是系统的文字菜单、双击只选到一个词。
    /// 要拷贝用右键的「拷贝」，要改一部分双击进去改
    @ViewBuilder
    func selectableUnlessEditable(_ editable: Bool) -> some View {
        if editable { self } else { textSelection(.enabled) }
    }
}
