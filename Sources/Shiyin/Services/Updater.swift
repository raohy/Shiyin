import AppKit
import Foundation
import Observation
import Security

/// app 内更新（R10.6、design §12、D10）：
/// 读更新信息 JSON → 比版本 → 用户同意后下载 DMG → 验证 SHA-256 → 取出新 app → 检查签名符合目前 app 的
/// designated requirement → app 结束后由小脚本替换并重新打开
@MainActor
@Observable
final class Updater {
    struct Manifest: Codable, Equatable {
        var version: String
        var url: String
        var sha256: String
        var notes: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Manifest), downloading, installing, failed(String)

        var label: String {
            switch self {
            case .idle: return ""
            case .checking: return String(localized: "正在检查…")
            case .upToDate: return String(localized: "已是最新版本")
            case .available(let m): return String(localized: "有新版本 \(m.version)")
            case .downloading: return String(localized: "正在下载更新…")
            case .installing: return String(localized: "正在准备安装…")
            case .failed(let reason): return reason
            }
        }
    }

    enum UpdateError: LocalizedError {
        case noURL, insecureURL, http(Int), badManifest, checksum, noApp, signature(String), notNewer, busy

        var errorDescription: String? {
            switch self {
            case .noURL: return String(localized: "还没有设置更新网址")
            case .insecureURL: return String(localized: "更新网址必须是 https")
            case .http(let code): return String(localized: "更新网址回传 HTTP \(code)")
            case .badManifest: return String(localized: "更新信息的格式不对")
            case .checksum: return String(localized: "下载的文件验证失败（SHA-256 不符），已删除")
            case .noApp: return String(localized: "更新档里找不到拾音")
            case .signature(let reason): return String(localized: "新版的签名跟目前的拾音不符，拒绝安装（\(reason)）")
            case .notNewer: return String(localized: "更新档的版本没有比较新")
            case .busy: return String(localized: "录音或转录、整理进行中，完成后再更新")
            }
        }
    }

    static let urlKey = "updateURL"
    private static let lastCheckedKey = "updateLastChecked"

    var state: State = .idle
    /// 有新版时要问用户（主窗口会跳出对话框）
    var prompt: Manifest?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 设置里填的网址优先，没填就用建置时写进 Info.plist 的
    static var feedURLString: String {
        let custom = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !custom.isEmpty { return custom }
        return (Bundle.main.object(forInfoDictionaryKey: "ShiyinUpdateURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// 只接受 https；localhost、127.0.0.1 例外，给测试用
    static func validated(_ url: URL?) throws -> URL {
        guard let url, let scheme = url.scheme?.lowercased() else { throw UpdateError.noURL }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1"].contains(url.host?.lowercased() ?? "") { return url }
        throw UpdateError.insecureURL
    }

    /// 版本号依数字逐段比较，例如 3.0.10 比 3.0.9 新
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 检查

    /// 启动 30 秒后检查一次，之后每小时看看距离上次检查是否超过 24 小时
    func scheduleAutomaticChecks() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while let self {
                let last = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date ?? .distantPast
                if !Self.feedURLString.isEmpty, Date().timeIntervalSince(last) > 24 * 3600 {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        if case .installing = state { return }
        do {
            let url = try Self.validated(URL(string: Self.feedURLString))
            state = .checking
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.http(code) }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { throw UpdateError.badManifest }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckedKey)
            if Self.isNewer(manifest.version, than: Self.currentVersion) {
                state = .available(manifest)
                prompt = manifest
            } else {
                state = .upToDate
            }
        } catch UpdateError.noURL where !userInitiated {
            state = .idle
        } catch {
            // 自动检查失败不跳窗口打扰用户，只显示在设置里
            state = .failed(error.localizedDescription)
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 安装

    func install(_ manifest: Manifest, model: AppModel) async {
        var workDir: URL?
        do {
            guard !model.recorder.isRecording, !model.runner.isBusy else { throw UpdateError.busy }
            guard Self.isNewer(manifest.version, than: Self.currentVersion) else { throw UpdateError.notNewer }
            let feed = try Self.validated(URL(string: Self.feedURLString))
            let dmgURL = try Self.validated(URL(string: manifest.url, relativeTo: feed)?.absoluteURL)

            state = .downloading
            let work = try Paths.makeTempDirectory()
            workDir = work
            let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.http(code) }
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            let hash = try await Task.detached { try ModelStore.sha256(dmg) }.value
            guard hash == manifest.sha256.lowercased() else { throw UpdateError.checksum }

            state = .installing
            let staged = try await Self.extractApp(from: dmg, into: work)
            try Self.checkSignature(staged)
            let stagedVersion = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard Self.isNewer(stagedVersion, than: Self.currentVersion) else { throw UpdateError.notNewer }

            let target = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                // 一般用户账号不能改 /Applications：打开 DMG 让用户自己拖
                NSWorkspace.shared.open(dmg)
                state = .failed(String(localized: "没有权限替换「\(target.deletingLastPathComponent().path)」里的拾音，已经打开下载好的 DMG，请把拾音拖进「应用程序」取代旧版"))
                return
            }
            // 下载期间可能开始了录音或转录：结束 app 时会跳确认，取消的话更新就停在一半，所以先挡下来
            guard !model.recorder.isRecording, !model.runner.isBusy else { throw UpdateError.busy }
            let replacement = try Self.launchReplacement(staged: staged, target: target, work: work)
            NSApp.terminate(nil)
            // 走到这里表示结束被取消了：停掉替换脚本、清掉下载的文件，旧版不受影响，可以再按一次
            replacement.terminate()
            try? FileManager.default.removeItem(at: work)
            state = .failed(String(localized: "已取消更新，旧版没有改动"))
        } catch {
            // 失败时把下载和解出来的文件都删掉，旧版完全不受影响
            if let workDir { try? FileManager.default.removeItem(at: workDir) }
            state = .failed(error.localizedDescription)
            model.errorMessage = String(localized: "更新失败：\(error.localizedDescription)")
        }
    }

    /// 唯读挂载 DMG，把里面的拾音复制出来
    private static func extractApp(from dmg: URL, into work: URL) async throws -> URL {
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await Subprocess(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                          ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
            .run(timeout: 120)
        guard attach.succeeded else { throw UpdateError.noApp }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path, "-force"]
            try? detach.run()
            detach.waitUntilExit()
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier })
        else { throw UpdateError.noApp }
        let staged = work.appendingPathComponent("Shiyin.app", isDirectory: true)
        let copy = try await Subprocess(URL(fileURLWithPath: "/usr/bin/ditto"), [app.path, staged.path]).run(timeout: 300)
        guard copy.succeeded else { throw UpdateError.noApp }
        return staged
    }

    /// 新 app 的签名要有效，而且符合目前这个 app 的 designated requirement（自签证书时等于同一张证书）
    static func checkSignature(_ app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError.signature(String(localized: "读不到目前 app 的签名")) }
        var newStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newStatic) == errSecSuccess, let newStatic else {
            throw UpdateError.signature(String(localized: "读不到新版的签名"))
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidity(newStatic, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.signature(SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "错误代码 \(status)"))
        }
    }

    /// 写一个固定内容的小脚本，路径用参数传入：等这个 app 结束 → 旧版改名备份 → 放进新版 → 成功删备份、失败还原 → 重新打开
    @discardableResult
    private static func launchReplacement(staged: URL, target: URL, work: URL) throws -> Process {
        let script = work.appendingPathComponent("replace.sh")
        try """
        #!/bin/sh
        pid="$1"; new="$2"; target="$3"; work="$4"; backup="$3.updating"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 600 ] && exit 1
          sleep 0.1
        done
        rm -rf "$backup"
        if mv "$target" "$backup"; then
          if /usr/bin/ditto "$new" "$target"; then
            rm -rf "$backup"
          else
            rm -rf "$target"; mv "$backup" "$target"
          fi
        fi
        rm -rf "$work"
        /usr/bin/open "$target"
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
