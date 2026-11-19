import SwiftUI

// MARK: - 弹窗的共用样子（R106、design §80）

/// 弹窗的标题：大标题、一行灰字说明、右上角 ✕
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    /// 标题列右边的小字（「第 1 组，共 2 组」）
    var trailing: String? = nil
    /// ✕ 做什么；nil 是关掉弹窗
    var onClose: (() -> Void)? = nil
    /// 没有「取消」的弹窗：Esc 等于按 ✕（有「取消」的弹窗 Esc 是那个按钮，不能两个都设）
    var escCloses = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2).fontWeight(.bold)
                if let subtitle {
                    Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary).padding(.top, 4) }
            Button { if let onClose { onClose() } else { dismiss() } } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .help("关闭")
            .accessibilityLabel(Text("关闭"))
            .modifier(CancelShortcut(enabled: escCloses))
        }
    }
}

private struct CancelShortcut: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.cancelAction) } else { content }
    }
}

/// 输入框：细框圆角 10，有焦点时框变亮（不用青瓷绿的焦点框）
struct SheetTextField: View {
    let placeholder: String
    @Binding var text: String
    var focusOnAppear = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($focused)
            .focusEffectDisabled()
            .sheetFieldBox(focused: focused)
            .onSubmit(onSubmit)
            // 等外面的 onAppear 把字填好再给焦点，字才会全选
            .onAppear { if focusOnAppear { DispatchQueue.main.async { focused = true } } }
    }
}

/// 就地编辑、页面里的输入框（逐字稿改句子、待确认的回答、提问）用同一种框：`.textFieldStyle(.sheet)`；
/// compact 是放在清单里、小一号的
struct SheetFieldStyle: TextFieldStyle {
    var compact = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        FocusedFieldBox(compact: compact) { configuration }
    }
}

extension TextFieldStyle where Self == SheetFieldStyle {
    static var sheet: SheetFieldStyle { SheetFieldStyle() }
    static var sheetCompact: SheetFieldStyle { SheetFieldStyle(compact: true) }
}

private struct FocusedFieldBox<Content: View>: View {
    let compact: Bool
    @ViewBuilder let content: Content
    @FocusState private var focused: Bool

    var body: some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .sheetFieldBox(focused: focused, compact: compact)
    }
}

extension View {
    /// 输入框的外框（多行的、菜单式的字段也用）
    func sheetFieldBox(focused: Bool = false, compact: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        return padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 5 : 9)
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(focused ? 0.75 : 0.25), lineWidth: focused ? 1.5 : 1))
    }

    /// 弹窗的外距、宽度
    func sheetChrome(width: CGFloat = 440) -> some View {
        padding(24).frame(width: width)
    }
}

/// 菜单式的字段（模板这类选一个）：外框同输入框，右边上下箭头
struct SheetMenuField<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    /// 不能选的（例如没有录音时的「录音档」）
    var isDisabled: (Value) -> Bool = { _ in false }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
                    .disabled(isDisabled(option.value))
            }
        } label: {
            HStack {
                Text(options.first { $0.value == selection }?.title ?? "").font(.system(size: 15)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .sheetFieldBox()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// 日期字段：外框同输入框，里面是没有框的日期（可以打字、↑↓ 改；系统的日期字段自己有框，放进来会框中框），
/// 右边的日历打开月历选
struct SheetDateField: View {
    let label: String
    @Binding var date: Date
    @State private var showsCalendar = false

    var body: some View {
        HStack {
            // 日期字段自己有一点内距、比一行字高：拉回来跟其他输入框的字对齐、同高
            PlainDatePicker(label: label, date: $date)
                .padding(.leading, -3)
                .padding(.vertical, -2)
            Spacer(minLength: 8)
            Button { showsCalendar.toggle() } label: {
                Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("选日期")
            .accessibilityLabel(Text("选日期"))
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                DatePicker(label, selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(12)
            }
        }
        .sheetFieldBox()
    }
}

private struct PlainDatePicker: NSViewRepresentable {
    let label: String
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .yearMonthDay
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.font = .systemFont(ofSize: 15)
        picker.setAccessibilityLabel(label)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

/// 字段上面的灰色小标签
struct SheetFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

/// 弹窗的按钮：圆角 10、高 34。主要按钮用字的颜色当底（深色模式白底黑字），次要的淡底细框，删除类红底白字；
/// compact 是就地编辑用的小一号（高 26）
struct SheetPillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ kind: Kind, compact: Bool = false) { self.kind = kind; self.compact = compact }
    init(prominent: Bool) { kind = prominent ? .primary : .secondary }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        configuration.label
            .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
            .padding(.horizontal, compact ? 12 : 18)
            .frame(minWidth: compact ? 52 : 68, minHeight: compact ? 26 : 34)
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(kind == .secondary ? Color.primary.opacity(0.18) : Color.clear))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(nsColor: .windowBackgroundColor)
        case .secondary: .primary
        case .destructive: .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .primary
        case .secondary: Color.primary.opacity(0.06)
        case .destructive: Color(nsColor: .systemRed)
        }
    }
}

// MARK: - 确认

/// 要确认的事（删除、移除、分成两场…）：取代系统的确认对话框，样子同其他弹窗
struct ConfirmRequest: Identifiable {
    let id: String
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    let action: () -> Void
}

struct ConfirmSheet: View {
    let request: ConfirmRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 說明是「・」開頭的好幾行時畫成條列，換行對齊在點的後面（編輯會議的套用、還原，design §81.5）
        let bullets = request.message.components(separatedBy: "\n")
        let isList = bullets.count > 1 && bullets.allSatisfy { $0.hasPrefix("・") }  // l10n-skip
        VStack(alignment: .leading, spacing: 22) {
            if isList {
                VStack(alignment: .leading, spacing: 10) {
                    SheetHeader(title: request.title)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("・")  // l10n-skip
                                Text(line.dropFirst()).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                }
            } else {
                SheetHeader(title: request.title, subtitle: request.message)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) {
                    dismiss()
                    request.action()
                }
                .buttonStyle(SheetPillButtonStyle(request.destructive ? .destructive : .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheetChrome()
    }
}
