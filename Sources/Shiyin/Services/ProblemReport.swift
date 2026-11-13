import AppKit
import Foundation
import GRDB

/// 反馈问题（design §21.9、R19.7、D33）：组出要附上的环境信息，打开浏览器的 GitHub 新 issue 页面让用户自己送出。
/// 不带会议内容、文件名、API key、模型名称、网址；错误只写种类（jobs.error_kind），不读 jobs.error（可能含逐字稿）
@MainActor
enum ProblemReport {
    static let defaultIssuesURL = "https://github.com/juinwei7/Shiyin/issues"

    /// Info.plist 的 ShiyinIssuesURL（fork 的人可以改），空的用默认
    static var issuesURL: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "ShiyinIssuesURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? defaultIssuesURL : value
    }

    static func text(db: AppDatabase) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let memory = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        let on = String(localized: "开"), off = String(localized: "关")
        var lines: [String] = []
        lines.append(String(localized: "## 问题描述"))
        lines.append(String(localized: "（请写发生了什么事、怎么重现。不要贴会议内容）"))
        lines.append("")
        lines.append(String(localized: "## 环境"))
        lines.append(String(localized: "- 拾音 \(version)（build \(build)）"))
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        lines.append(String(localized: "- macOS \(osVersion)（\(sysctl("kern.osversion") ?? "?")）"))
        lines.append(String(localized: "- \(sysctl("machdep.cpu.brand_string") ?? "Apple Silicon")，内存 \(memory)"))
        lines.append(String(localized: "- 界面语言：\(MeetingLanguage.interfaceCode)"))
        let engine = AppSettings.usesEnterpriseTranscription ? String(localized: "企业服务器")
            : ["system": String(localized: "macOS 内置识别"), "qwen": "Qwen3-ASR 1.7B"][AppSettings.transcriptionEngine] ?? "Breeze ASR 25"
        lines.append(String(localized: "- 转录：\(engine)；说话者识别：\(AppSettings.diarize ? on : off)；声纹：\(AppSettings.voiceprints ? on : off)"))
        lines.append(String(localized: "- 整理工具：\(AppSettings.provider.label)"))
        // 企业服务器（R52.3）：有没有连、服务器的版本；不写网址和账号
        let enterprise = EnterpriseServer.shared
        if let account = enterprise.account {
            let state = enterprise.isSignedIn ? String(localized: "已登录") : String(localized: "登录已失效")
            lines.append(String(localized: "- 企业服务器：\(state)（服务器 \(account.serverVersion ?? "?")）"))
        }
        lines.append("")
        lines.append(String(localized: "## 最近失败的工作"))
        let failures = (try? db.recentFailures(limit: 5)) ?? []
        if failures.isEmpty {
            lines.append(String(localized: "- 没有"))
        } else {
            for failure in failures {
                let errorKind = failure.errorKind ?? String(localized: "（没有记录种类）")
                lines.append(String(localized: "- \(failure.date) \(failure.kind)：\(errorKind)"))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func url(body: String) -> URL? {
        var components = URLComponents(string: issuesURL.hasSuffix("/") ? issuesURL + "new" : issuesURL + "/new")
        components?.queryItems = [URLQueryItem(name: "title", value: ""), URLQueryItem(name: "body", value: body)]
        return components?.url
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

extension AppDatabase {
    /// 反馈问题用：最近失败的工作的种类、错误种类、日期（不读 error，那里可能有逐字稿）
    func recentFailures(limit: Int) throws -> [(kind: String, errorKind: String?, date: String)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, error_kind, finished_at FROM jobs WHERE status = 'failed' ORDER BY finished_at DESC, id DESC LIMIT ?",
                             arguments: [limit])
                .map { ($0["kind"], $0["error_kind"], String(($0["finished_at"] as String?)?.prefix(10) ?? "")) }
        }
    }
}
