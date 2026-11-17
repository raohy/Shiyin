import AppKit
import SwiftUI

// MARK: - 自己画的菜单（R105、design §79）

/// 「⋯」和右键菜单的一项（自己画的菜单：圆角深色面板、细线图标、右边灰色的快捷键、子菜单「›」）
struct MenuEntry: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([MenuEntry])
        case divider
    }

    let id = UUID()
    var title = ""
    var icon: String?
    /// 只是提示（例如 ↩、⌘⌫），不注册快捷键
    var shortcut: String?
    var destructive = false
    var enabled = true
    var kind: Kind

    static func action(_ title: String, icon: String? = nil, shortcut: String? = nil, destructive: Bool = false,
                       enabled: Bool = true, _ action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, icon: icon, shortcut: shortcut, destructive: destructive, enabled: enabled, kind: .action(action))
    }

    static func submenu(_ title: String, icon: String? = nil, _ items: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, icon: icon, enabled: !items.isEmpty, kind: .submenu(items))
    }

    static var divider: MenuEntry { MenuEntry(kind: .divider) }

    var isDivider: Bool { if case .divider = kind { true } else { false } }
}

/// 开着的菜单：一个透明的面板（不抢焦点，跟系统菜单一样主窗口照样是作用中的），子菜单画在右边、面板跟着变宽。
/// 点击单外面、按 Esc、选了一项、切到别的 app 就关
@MainActor
final class FloatingMenuController {
    static let shared = FloatingMenuController()

    private var panel: NSPanel?
    private var monitors: [Any] = []
    /// 菜单开着时让作用中的窗口送鼠标移动事件（滑过靠它，见 installMonitors），关掉时改回原本的
    private var movedWindow: (window: NSWindow, accepted: Bool)?
    private var state: FloatingMenuState?
    /// 菜单左上角（屏幕座标），面板变宽时固定这一点
    private var topLeft: NSPoint = .zero

    var isOpen: Bool { panel != nil }

    #if DEBUG
    /// DEBUG 验收时用户在用别的 app，点别的 app 不关菜单（floatothers off）
    var ignoreOtherApps = false

    /// DEBUG：开着的菜单的项目（子菜单写「移到文件夹 ▸ 客户」）、选某一项
    var debugTitles: [String] {
        func titles(_ entries: [MenuEntry], _ prefix: String) -> [String] {
            entries.flatMap { e -> [String] in
                if e.isDivider { return [prefix + "——"] }
                let line = prefix + e.title + (e.shortcut.map { "（\($0)）" } ?? "") + (e.destructive ? "（红）" : "") + (e.enabled ? "" : "（禁用）")   // l10n-skip
                if case .submenu(let items) = e.kind { return [line] + titles(items, prefix + e.title + " ▸ ") }
                return [line]
            }
        }
        return state.map { titles($0.entries, "") } ?? []
    }

    func debugPick(_ path: String) {
        guard let state else { return }
        var entries = state.entries
        let parts = path.components(separatedBy: " ▸ ")
        for (i, part) in parts.enumerated() {
            guard let entry = entries.first(where: { $0.title == part }) else { return }
            if i == parts.count - 1 { state.activate(entry) } else if case .submenu(let items) = entry.kind { entries = items }
        }
    }

    var debugFrame: NSRect? { panel?.frame }
    var debugWindowNumber: Int { panel?.windowNumber ?? -1 }

    var debugState: String {
        guard let state else { return "" }
        let mouse = state.lastPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"
        return "open=\(state.openSubmenu ?? -1) hl=\(state.highlighted ?? -1) sub=\(state.subHighlighted ?? -1) frame=\(state.submenuFrame) mouse=\(mouse)"
    }
    #endif

    /// 在屏幕上的一点打开（左上角对齐；超出屏幕时往上、往左挪）
    func show(_ entries: [MenuEntry], at point: NSPoint, from parent: NSWindow? = nil) {
        close()
        guard !entries.isEmpty else { return }
        let state = FloatingMenuState(entries: entries) { [weak self] in self?.close() }
        self.state = state
        let host = NSHostingView(rootView: FloatingMenuView(state: state) { [weak self] size in self?.resize(to: size) })
        host.sizingOptions = []
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // 主窗口在桌面层（DEBUG 验收时放在所有窗口后面）时菜单也跟着放低，不出现在用户的画面上
        if let parent, parent.level < .normal {
            panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        } else {
            panel.level = .popUpMenu
        }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // 阴影画在内容里（圆角）
        panel.hidesOnDeactivate = true
        panel.contentView = host

        // 内容外面留了 12 点画阴影，看得到的菜单左上角对齐这一点
        let inset = FloatingMenuView.shadowInset
        var origin = NSPoint(x: point.x - inset, y: point.y + inset - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame {
            if origin.y < screen.minY { origin.y = min(point.y + 4, screen.maxY - size.height) }
            if origin.x + size.width > screen.maxX { origin.x = screen.maxX - size.width }
        }
        topLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        self.panel = panel
        installMonitors()
    }

    /// 在一个 view 下面打开（「⋯」按钮）
    func show(_ entries: [MenuEntry], below view: NSView) {
        guard let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        show(entries, at: NSPoint(x: rect.minX, y: rect.minY - 4), from: window)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let movedWindow { movedWindow.window.acceptsMouseMovedEvents = movedWindow.accepted }
        movedWindow = nil
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }

    /// 子菜单打开、关上时面板跟着变宽变窄，左上角不动
    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
    }

    private func installMonitors() {
        // 点在菜单外面：关掉，这一下不往下传（同系统菜单）
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            self.close()
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                #if DEBUG
                if self?.ignoreOtherApps == true { return }
                #endif
                self?.close()
            }
        }) { monitors.append(m) }
        // 滑过：面板不是作用中的窗口，SwiftUI 的 onHover 有时慢半拍（快速斜着移到子菜单时经过的列来不及算），
        // app 收到鼠标移动就自己算光标在哪一列
        if let key = NSApp.keyWindow {
            movedWindow = (key, key.acceptsMouseMovedEvents)
            key.acceptsMouseMovedEvents = true
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            guard let self, let panel = self.panel, let content = panel.contentView else { return event }
            // 事件的位置换成面板里的位置（左上原点）
            let screen = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
            let point = panel.convertPoint(fromScreen: screen)
            self.state?.trackMouse(CGPoint(x: point.x, y: content.bounds.height - point.y))
            return event
        }) { monitors.append(m) }
        // 键盘：上下移、Return 选、→ 打开子菜单、← 回上一层、Esc 关
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let state = self.state else { return event }
            return state.handleKey(event) ? nil : event
        }) { monitors.append(m) }
    }
}

/// 菜单的状态：鼠标或键盘移到哪一项、哪个子菜单开着
@Observable
@MainActor
final class FloatingMenuState {
    let entries: [MenuEntry]
    let dismiss: () -> Void
    /// 第一层亮着的那一项、开着的子菜单（第一层的位置）、子菜单里亮着的那一项
    var highlighted: Int?
    var openSubmenu: Int?
    var subHighlighted: Int?

    init(entries: [MenuEntry], dismiss: @escaping () -> Void) {
        self.entries = entries
        self.dismiss = dismiss
    }

    var submenuEntries: [MenuEntry] {
        guard let i = openSubmenu, case .submenu(let items) = entries[i].kind else { return [] }
        return items
    }

    func activate(_ entry: MenuEntry) {
        guard entry.enabled, case .action(let action) = entry.kind else { return }
        dismiss()
        action()
    }

    /// 子菜单开着时滑到别的列，等一下才换（同系统菜单）：斜着往子菜单移的时候会经过别的列，
    /// 一经过就换掉的话子菜单点不到（2026-11-17 自己验收时发现）；这段时间滑进子菜单就不换
    @ObservationIgnored private var pendingSwitch: Task<Void, Never>?
    /// 子菜单在面板里的框、最后一次鼠标移动的位置（都是左上原点）：换子菜单之前看光标是不是已经在子菜单里
    @ObservationIgnored var submenuFrame: CGRect = .zero
    @ObservationIgnored var lastPoint: CGPoint?

    func hover(_ index: Int) {
        highlighted = index
        pendingSwitch?.cancel()
        let apply = { [weak self] in
            guard let self else { return }
            if case .submenu = self.entries[index].kind, self.entries[index].enabled {
                if self.openSubmenu != index { self.openSubmenu = index; self.subHighlighted = nil; self.subRowFrames = [:] }
            } else {
                self.openSubmenu = nil
                self.subRowFrames = [:]
            }
        }
        guard openSubmenu != nil, openSubmenu != index else { apply(); return }
        pendingSwitch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            if let point = self.lastPoint, self.submenuFrame.insetBy(dx: -4, dy: -4).contains(point) {
                self.highlighted = self.openSubmenu
                return
            }
            apply()
        }
    }

    /// 每一列在面板里的框（左上原点）：第一层、子菜单分开放
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    @ObservationIgnored var subRowFrames: [Int: CGRect] = [:]

    /// 光标移动：照现在的位置亮那一列（第一层换列会开、换子菜单；离开菜单时只留子菜单那一列亮着）

    func trackMouse(_ point: CGPoint) {
        lastPoint = point
        if openSubmenu != nil, let j = subRowFrames.first(where: { $0.value.contains(point) })?.key {
            if subHighlighted != j { hoverSubmenu(j) }
        } else if let i = rowFrames.first(where: { $0.value.contains(point) })?.key {
            if highlighted != i || (openSubmenu == nil && isSubmenu(i)) { hover(i) }
        } else if openSubmenu == nil || !submenuFrame.contains(point) {
            if highlighted != openSubmenu { highlighted = openSubmenu }
            if subHighlighted != nil { subHighlighted = nil }
        }
    }

    private func isSubmenu(_ i: Int) -> Bool { if case .submenu = entries[i].kind { true } else { false } }

    /// 滑进子菜单：取消还没换的，亮回子菜单那一列
    func hoverSubmenu(_ index: Int) {
        pendingSwitch?.cancel()
        subHighlighted = index
        highlighted = openSubmenu
    }

    /// 回传有没有处理
    func handleKey(_ event: NSEvent) -> Bool {
        let inSub = openSubmenu != nil && subHighlighted != nil
        let list = inSub ? submenuEntries : entries
        func step(_ from: Int?, _ delta: Int) -> Int? {
            let usable = list.indices.filter { !list[$0].isDivider && list[$0].enabled }
            guard !usable.isEmpty else { return nil }
            guard let from, let i = usable.firstIndex(of: from) else { return delta > 0 ? usable.first : usable.last }
            return usable[(i + delta + usable.count) % usable.count]
        }
        switch event.keyCode {
        case 53:   // Esc
            if inSub { subHighlighted = nil; openSubmenu = nil } else { dismiss() }
        case 125, 126:   // ↓ ↑
            let delta = event.keyCode == 125 ? 1 : -1
            if inSub { subHighlighted = step(subHighlighted, delta) } else { highlighted = step(highlighted, delta); openSubmenu = nil }
        case 124:   // →
            if !inSub, let i = highlighted, case .submenu = entries[i].kind, entries[i].enabled {
                openSubmenu = i
                subHighlighted = step(nil, 1)
            }
        case 123:   // ←
            if inSub { subHighlighted = nil; openSubmenu = nil }
        case 36, 76:   // Return、Enter
            if inSub, let j = subHighlighted { activate(submenuEntries[j]) }
            else if let i = highlighted {
                if case .submenu = entries[i].kind { openSubmenu = i; subHighlighted = step(nil, 1) } else { activate(entries[i]) }
            }
        default:
            return false
        }
        return true
    }
}

/// 菜单的样子：圆角 14 的面板（深色模式深灰、浅色白），每一项高 30：细线图标、字、右边灰色的快捷键或「›」
struct FloatingMenuView: View {
    let state: FloatingMenuState
    let onSize: (CGSize) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            panel(state.entries, sub: false)
            if state.openSubmenu != nil {
                // 用 padding 不用 offset：面板的大小要算到子菜单往下挪的部分，不然下面被切掉
                panel(state.submenuEntries, sub: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.submenuFrame = $0 }
                    .padding(.top, submenuOffset)
            }
        }
        .padding(FloatingMenuView.shadowInset)   // 阴影的空间
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    /// 子菜单跟它那一项同高
    private var submenuOffset: CGFloat {
        guard let i = state.openSubmenu else { return 0 }
        let before = state.entries.prefix(i)
        return CGFloat(before.filter { !$0.isDivider }.count) * FloatingMenuView.rowHeight
            + CGFloat(before.filter(\.isDivider).count) * FloatingMenuView.dividerHeight
    }

    static let rowHeight: CGFloat = 30
    static let shadowInset: CGFloat = 12
    static let dividerHeight: CGFloat = 9

    private func panel(_ entries: [MenuEntry], sub: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if entry.isDivider {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                } else {
                    row(entry, highlighted: sub ? state.subHighlighted == index : (state.highlighted == index || state.openSubmenu == index))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            if sub { state.subRowFrames[index] = frame } else { state.rowFrames[index] = frame }
                        }
                        .onTapGesture {
                            if case .submenu = entry.kind { if !sub { state.hover(index) } } else { state.activate(entry) }
                        }
                }
            }
        }
        .padding(5)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 1, alpha: 1)
                }))
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func row(_ entry: MenuEntry, highlighted: Bool) -> some View {
        let color: Color = entry.destructive ? .red : .primary
        return HStack(spacing: 10) {
            Group {
                if let icon = entry.icon { Image(systemName: icon) } else { Color.clear }
            }
            .font(.system(size: 14, weight: .light))
            .frame(width: 18)
            Text(entry.title).font(.system(size: 14)).lineLimit(1)
            Spacer(minLength: 16)
            // 快捷键、「›」一律灰色（删除那一项也是；.secondary 会跟着红色变淡红）
            if let shortcut = entry.shortcut {
                Text(shortcut).font(.system(size: 13)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } else if case .submenu = entry.kind {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: FloatingMenuView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(highlighted && entry.enabled ? 0.09 : 0)))
        .contentShape(Rectangle())
        .opacity(entry.enabled ? 1 : 0.35)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 「⋯」和右键

/// 抓一个 NSView 当菜单的位置（导出的「分享…」也用它放分享菜单）
final class MenuAnchorBox {
    weak var view: NSView?
}

struct MenuAnchor: NSViewRepresentable {
    let box: MenuAnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// 列右边的「⋯」：打开自己画的菜单，挂在按钮下面
struct FloatingMenuButton: View {
    let entries: () -> [MenuEntry]
    @State private var box = MenuAnchorBox()

    var body: some View {
        Button {
            if let view = box.view { FloatingMenuController.shared.show(entries(), below: view) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
                .background(MenuAnchor(box: box))
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .help("更多动作")
        .accessibilityLabel(Text("更多动作"))
    }
}

/// 右键（或 Control-点一下）：在光标的地方打开自己画的菜单。列上盖一个不接任何事件的透明 view 只是记下位置，
/// app 层级的事件监看收到右键时找光标下面最小的那一个（展开的会议在文件夹列里面这种情况取里面的）
private struct RightClickCatcher: NSViewRepresentable {
    let entries: () -> [MenuEntry]

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.entries = entries }

    final class CatcherView: NSView {
        var entries: (() -> [MenuEntry])?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { RightClickRegistry.shared.add(self) }
        }
    }
}

@MainActor
private final class RightClickRegistry {
    static let shared = RightClickRegistry()
    private let views = NSHashTable<RightClickCatcher.CatcherView>.weakObjects()
    private var monitor: Any?

    func add(_ view: RightClickCatcher.CatcherView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control), let self, let window = event.window else { return event }
            let hits = self.views.allObjects.filter { view in
                view.window === window && !view.isHiddenOrHasHiddenAncestor
                    && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
            guard let view = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
                  let entries = view.entries else { return event }
            FloatingMenuController.shared.show(entries(), at: window.convertPoint(toScreen: event.locationInWindow), from: window)
            return nil
        }
    }
}

extension View {
    /// 右键打开自己画的菜单（取代系统的 contextMenu）
    func floatingContextMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClickCatcher(entries: entries))
    }

    /// 列右边的「⋯」（滑过或选到时显示）＋右键，同一份菜单
    func floatingRowMenu(selected: Bool = false, _ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(FloatingRowMenuModifier(selected: selected, entries: entries))
    }
}

private struct FloatingRowMenuModifier: ViewModifier {
    var selected: Bool
    let entries: () -> [MenuEntry]
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 22)
            .floatingContextMenu(entries)
            // 「⋯」滑过或选到时才建：每一列都放一颗（含定位用的 NSView）时，长会议的记录一次几百颗，
            // 换会议时多花约 0.08 秒（2026-11-17 用用户资料的复本量到；用户觉得「卡卡的」）
            .overlay(alignment: .trailing) {
                if hovering || selected { FloatingMenuButton(entries: entries) }
            }
            .onHover { hovering = $0 }
            // VoiceOver 的「显示菜单」（VO-Shift-M）：同右键，在光标的位置打开
            .accessibilityAction(.showMenu) {
                guard let window = NSApp.keyWindow else { return }
                FloatingMenuController.shared.show(entries(), at: NSEvent.mouseLocation, from: window)
            }
    }
}
