import Carbon.HIToolbox
import Foundation

/// 全域快捷键（R11.3、R19.5、design §12、§21.10）：在其他 app 里也能用。
/// ⌃⌥⌘R 开始或停止录音；⌃⌥⌘B 录音中标记重点（只在录音中注册，不录音时不占用这组按键）。
/// 用 Carbon 的 RegisterEventHotKey，不需要辅助功能权限。
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let display = "⌃⌥⌘R"
    static let bookmarkDisplay = "⌃⌥⌘B"

    private static let recordID: UInt32 = 1
    private static let bookmarkID: UInt32 = 2

    var onPress: (() -> Void)?
    var onBookmark: (() -> Void)?
    /// 最近一次注册录音快捷键的结果；被其他 app 占用时不是 noErr
    private(set) var status: OSStatus = noErr
    var isRegistered: Bool { hotKeys[Self.recordID] != nil }
    var isBookmarkRegistered: Bool { hotKeys[Self.bookmarkID] != nil }

    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            status = register(Self.recordID, key: kVK_ANSI_R)
        } else {
            unregister(Self.recordID)
            status = noErr
        }
    }

    /// 录音开始时打开、停止时关掉（design §21.10）
    func setBookmarkEnabled(_ enabled: Bool) {
        if enabled { _ = register(Self.bookmarkID, key: kVK_ANSI_B) } else { unregister(Self.bookmarkID) }
    }

    /// 按下快捷键；DEBUG 命令也用这个模拟
    func fire() { onPress?() }
    func fireBookmark() { onBookmark?() }

    private func register(_ id: UInt32, key: Int) -> OSStatus {
        guard hotKeys[id] == nil else { return noErr }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let id = hotKeyID.id
                Task { @MainActor in
                    if id == GlobalHotKey.bookmarkID { GlobalHotKey.shared.fireBookmark() } else { GlobalHotKey.shared.fire() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_5949), id: id)   // 'SHYI'
        var ref: EventHotKeyRef?
        // 独占注册：别的 app 已经独占这组按键时会失败（设置里会显示），也避免两个 app 同时被触发
        let result = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey | controlKey), hotKeyID,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if result == noErr, let ref { hotKeys[id] = ref }
        else { log.error("global hot key \(id) registration failed: \(result)") }
        return result
    }

    private func unregister(_ id: UInt32) {
        if let ref = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
}
