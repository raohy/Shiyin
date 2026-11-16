import AppKit

/// 分享画面时藏起拾音的窗口（design §53、R77、D163）：设置打开时每个窗口的 sharingType 都是 .none，
/// 分享整个屏幕、截屏、录像都拍不到，自己的屏幕照常看得到。
/// 菜单列的小窗口、检测会议的浮动提醒不会变成 key，出现时会收到 occlusion 的通知，所以也听它
@MainActor
enum WindowSharing {
    private static var observers: [NSObjectProtocol] = []
    private static var applied: Bool?

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { if let window = note.object as? NSWindow { apply(to: window) } }
            })
        }
        // 设置页改了开关：马上套用到开着的窗口（R77.3）。任何设置改了都会通知，只比对这一个值
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if applied != AppSettings.hideFromScreenSharing { applyAll() } }
        })
        applyAll()
    }

    static func applyAll() {
        applied = AppSettings.hideFromScreenSharing
        NSApp.windows.forEach(apply(to:))
    }

    static func apply(to window: NSWindow) {
        // 录音岛一律拍不到（R81.7），自己设
        if window is IslandPanel { return }
        let type: NSWindow.SharingType = AppSettings.hideFromScreenSharing ? .none : .readOnly
        if window.sharingType != type { window.sharingType = type }
    }
}
