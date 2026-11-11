import Foundation
import os
import Security

/// API key 存在 macOS 钥匙串（design §8.4、N6），不写进文件或 log
enum Keychain {
    static let service = "com.weiwei.shiyin.apikey"

    /// 读不到、存不进去的原因（design §22.1、R21.2、R21.4）
    enum AccessError: LocalizedError {
        /// macOS 没有允许：用户按「拒绝」、关掉确认窗口
        case denied
        /// 钥匙串里有旧的 key，macOS 不让这一版取代
        case duplicate(String)
        case readFailed(OSStatus)
        case writeFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .denied:
                return String(localized: "macOS 没有让拾音读取钥匙串里的 API key。再试一次时，系统询问就输入这台 Mac 的登录密码（不是 API key），按「永远允许」；或到设置 → 整理工具重新粘贴 key。")
            case .duplicate(let account):
                return String(localized: "钥匙串里已经有旧的 key，macOS 没有让拾音取代它。请打开「钥匙串访问」，删除「拾音 API key（\(account)）」后再存一次。")
            case .readFailed(let status):
                return String(localized: "读取钥匙串里的 API key 失败（错误 \(Int(status))）")
            case .writeFailed(let status):
                return String(localized: "没办法把 API key 存进钥匙串（错误 \(Int(status))）")
            }
        }
    }

    /// 读到的 key 记在内存，拾音开着时同一个 key 只问钥匙串一次（design §22.1、D36）
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    #if DEBUG
    /// shiyinctl llmkey：测试用的 key 只放内存，不写进钥匙串（design §19.5）
    nonisolated(unsafe) static var debugKeys: [String: String] = [:]
    /// shiyinctl keychainsim：模拟钥匙串回「拒绝」或「已经有旧的」（design §22.1）
    nonisolated(unsafe) static var debugSimulated: [String: String] = [:]
    /// 实际查钥匙串的次数（验证缓存用）
    nonisolated(unsafe) static var debugReads = 0
    /// llmkey、keychainsim 改了之后，记在内存的 key 要清掉
    static func debugForget(_ account: String) { cache.withLock { $0[account] = nil } }
    /// DEBUG 版默认不读真的钥匙串：每次重建签名都不同，读用户存的 key 会跳出系统的访问确认（design §20.7）。
    /// 要测钥匙串时用启动参数 -debugRealKeychain YES
    static var usesRealKeychain: Bool { UserDefaults.standard.bool(forKey: "debugRealKeychain") }
    #endif

    /// 读出 key：没存回传 nil；macOS 没允许或其他错误丢出 AccessError
    static func read(_ account: String) throws -> String? {
        if let key = cache.withLock({ $0[account] }) { return key }
        #if DEBUG
        debugReads += 1
        if !usesRealKeychain || debugSimulated[account] != nil || debugKeys[account] != nil {
            if debugSimulated[account] == "denied" { throw AccessError.denied }
            guard let key = debugKeys[account] else { return nil }
            cache.withLock { $0[account] = key }
            return key
        }
        #endif
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
            cache.withLock { $0[account] = key }
            return key
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecNoAccessForItem:
            throw AccessError.denied
        default:
            throw AccessError.readFailed(status)
        }
    }

    /// 不需要分辨原因的地方用：读不到就是 nil
    /// 存或删 key 的次数（只在内存）：整理工具设置的指纹用，换了 key 就解除暂停（design §34.4）
    nonisolated(unsafe) static var generation = 0 {
        didSet { NotificationCenter.default.post(name: .summarizerStateChanged, object: nil) }
    }

    static func get(_ account: String) -> String? {
        try? read(account)
    }

    /// 有没有存这个 key：只读属性、不读内容。读内容要解密，换了签名会跳出系统的访问确认；只读属性不会（design §20.7、R18.7）
    static func exists(_ account: String) -> Bool {
        #if DEBUG
        if debugKeys[account] != nil || debugSimulated[account] != nil { return true }
        guard usesRealKeychain else { return false }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// 存 key（空字符串等于删除）；存不进去丢出 AccessError
    static func set(_ account: String, _ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { generation += 1 }   // 存好之后才通知（通知里会查 exists）
        #if DEBUG
        if debugSimulated[account] == "duplicate" { throw AccessError.duplicate(account) }
        // 没加 -debugRealKeychain 时只存在内存：不能写进、删掉用户真的钥匙串（design §20.7）
        if !usesRealKeychain {
            debugKeys[account] = trimmed.isEmpty ? nil : trimmed
            cache.withLock { $0[account] = trimmed.isEmpty ? nil : trimmed }
            return
        }
        #endif
        delete(account)
        guard !trimmed.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: String(localized: "拾音 API key（\(account)）"),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess: cache.withLock { $0[account] = trimmed }
        case errSecDuplicateItem: throw AccessError.duplicate(account)
        default: throw AccessError.writeFailed(status)
        }
    }

    static func delete(_ account: String) {
        defer { generation += 1 }
        cache.withLock { $0[account] = nil }
        #if DEBUG
        if !usesRealKeychain { debugKeys[account] = nil; return }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
