import AppKit
import SwiftUI

/// 录音岛（design §57、R81、D165、D166）：录音中、检测到会议时，屏幕上方正中间（有浏海就接在浏海两侧）的小窗口。
/// 全屏幕的 app 上、每个桌面都看得到；分享画面、截屏拍不到；不抢焦点
@MainActor
final class RecordingIsland {
    static let shared = RecordingIsland()

    /// 设置「在屏幕上方显示录音岛」（R81.8），默认开
    static var isEnabled: Bool { AppSettings.recordingIsland }

    let state = IslandState()
    private var panel: IslandPanel?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var contentSize = CGSize(width: 200, height: 32)
    private weak var model: AppModel?

    func install(_ model: AppModel) {
        guard timer == nil else { return }
        self.model = model
        // 录音的状态、提醒都在 Recorder 上，每 0.5 秒看一次要不要出现、展开（便宜：只比对几个值）
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { RecordingIsland.shared.update() }
        }
        // 换 app、换桌面、屏幕设置变了：重新放到目前在用的屏幕
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecordingIsland.shared.place(animated: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecordingIsland.shared.place(animated: false) }
        })
    }

    // MARK: 检测会议的提醒（R81.3）

    /// deadline、countdown：会议结束的倒数（R95）：消息每秒换成剩下的秒数，倒数完才收起来（不是 30 秒）
    func showPrompt(_ prompt: MeetingDetector.Prompt, actions: [(id: String, title: String, action: () -> Void)], message: String,
                    deadline: Date? = nil, countdown: ((Int) -> String)? = nil) {
        state.prompt = IslandState.Prompt(prompt: prompt, message: message, actions: actions.map { item in
            IslandState.Action(id: item.id, title: item.title, run: { [weak self] in
                self?.closePrompt()
                item.action()
            })
        }, expires: deadline?.addingTimeInterval(2) ?? Date().addingTimeInterval(30), deadline: deadline, countdown: countdown)
        update()
    }

    func perform(_ id: String) { state.prompt?.actions.first { $0.id == id }?.run() }

    func closePrompt() {
        state.prompt = nil
        update()
    }

    // MARK: 出现、位置

    func update() {
        guard let model else { return }
        state.tick(model.recorder)
        let show = Self.isEnabled && (model.recorder.isRecording || state.prompt != nil)
        if show {
            let panel = ensurePanel(model)
            place(animated: false)
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if let panel, panel.isVisible {
            panel.orderOut(nil)
            state.hover = false
        }
    }

    /// SwiftUI 的内容量好大小时调用：窗口跟着内容（收起时只有一小块，不挡下面的窗口，R81.6）
    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        place(animated: true)
    }

    private func ensurePanel(_ model: AppModel) -> IslandPanel {
        if let panel { return panel }
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        // 一律拍不到（R81.7，不看「分享画面时藏起拾音的窗口」的设置）
        panel.sharingType = .none
        #if DEBUG
        // 验证：-debugIslandCapture YES 才拍得到；-debugIslandBehind YES 放在桌面层，不会出现在用户的画面上（design §57.3）
        if UserDefaults.standard.bool(forKey: "debugIslandCapture") { panel.sharingType = .readOnly }
        if UserDefaults.standard.bool(forKey: "debugIslandBehind") { panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1) }
        #endif
        let hosting = IslandHostingView(rootView: IslandRoot(state: state).environment(model))
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    func place(animated: Bool) {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let notch = IslandNotch(screen: screen)
        if state.notch != notch { state.notch = notch }
        let width = max(contentSize.width, 1), height = max(contentSize.height, 1)
        let midX = notch.midX ?? screen.frame.midX
        // 有浏海：上缘贴着屏幕的上缘；没有：菜单列下方 6 pt
        let top = notch.hasNotch ? screen.frame.maxY : screen.frame.maxY - notch.menuBarHeight - 6
        let frame = NSRect(x: (midX - width / 2).rounded(), y: top - height, width: width, height: height)
        guard panel.frame != frame else { return }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    #if DEBUG
    /// shiyinctl state 的 island（design §57.3）
    var debugInfo: [String: Any] {
        ["visible": panel?.isVisible ?? false, "mode": state.debugMode(model?.recorder),
         "frame": panel.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
         "notch": state.notch.hasNotch, "windowNumber": panel?.windowNumber ?? 0,
         "prompt": state.prompt?.message ?? "", "hintKey": state.hintKey ?? ""]
    }
    #endif
}

/// 录音岛的状态：滑过去、检测会议的提醒、提醒展开到什么时候（design §57.2）
@MainActor
@Observable
final class IslandState {
    struct Action {
        var id: String
        var title: String
        var run: () -> Void
    }

    struct Prompt {
        var prompt: MeetingDetector.Prompt
        var message: String
        var actions: [Action]
        var expires: Date
        /// 倒数到什么时候、消息怎么写（R95）；nil 是一般的提醒
        var deadline: Date? = nil
        var countdown: ((Int) -> String)? = nil
    }

    var hover = false
    var prompt: Prompt?
    /// 新的提醒出现后展开 10 秒（R81.2），之后收回成琥珀色的点
    private(set) var hintExpanded = false
    private(set) var hintKey: String?
    @ObservationIgnored private var expandedUntil = Date.distantPast
    var notch = IslandNotch.none

    /// 每 0.5 秒：提醒换了就展开 10 秒；检测会议的提醒 30 秒没按就收起来
    func tick(_ recorder: Recorder) {
        let now = Date()
        if let prompt, prompt.expires < now { self.prompt = nil }
        let key = Self.hintKey(recorder)
        if key != hintKey {
            hintKey = key
            if key != nil { expandedUntil = now.addingTimeInterval(10) }
        }
        let expanded = key != nil && now < expandedUntil
        if expanded != hintExpanded { hintExpanded = expanded }
    }

    /// 目前的提醒是哪一个（顺序同录音画面的提示列）：没人说话 → 蓝牙 → 收音 → 重新连接
    static func hintKey(_ recorder: Recorder) -> String? {
        guard recorder.isRecording else { return nil }
        if recorder.idlePrompt { return "idle" }
        if let mic = recorder.micHint { return "mic:\(mic.name)" }
        if let hint = recorder.levelHint { return "level:\(hint.rawValue)" }
        if let warning = recorder.deviceWarning { return "device:\(warning)" }
        return nil
    }

    #if DEBUG
    func debugMode(_ recorder: Recorder?) -> String {
        if prompt != nil { return "prompt" }
        guard recorder?.isRecording == true else { return "hidden" }
        if hover { return "hover" }
        if hintExpanded { return "hint" }
        return "collapsed"
    }
    #endif
}

/// 浏海的位置和大小；没有浏海时是菜单列的高度
struct IslandNotch: Equatable {
    var width: CGFloat
    var height: CGFloat
    var midX: CGFloat?
    var menuBarHeight: CGFloat

    var hasNotch: Bool { midX != nil }

    static let none = IslandNotch(width: 0, height: 26, midX: nil, menuBarHeight: 24)

    init(width: CGFloat, height: CGFloat, midX: CGFloat?, menuBarHeight: CGFloat) {
        self.width = width
        self.height = height
        self.midX = midX
        self.menuBarHeight = menuBarHeight
    }

    init(screen: NSScreen) {
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        var noNotch = false
        #if DEBUG
        noNotch = UserDefaults.standard.bool(forKey: "debugIslandNoNotch")
        #endif
        // 浏海＝屏幕的宽度扣掉左右两块菜单列
        if !noNotch, screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            self.init(width: width, height: screen.safeAreaInsets.top, midX: screen.frame.minX + left.width + width / 2, menuBarHeight: menuBar)
        } else {
            self.init(width: 0, height: 26, midX: nil, menuBarHeight: menuBar)
        }
    }
}

/// 不会变成 key、可以放在菜单列上的窗口
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 拾音不在前面时，第一下就按得到岛上的按钮
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
