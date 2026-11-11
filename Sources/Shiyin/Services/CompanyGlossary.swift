import Foundation
import os

extension Notification.Name {
    /// 公司词汇表换了（R53）：画面、建议的新词要重算
    static let companyGlossaryChanged = Notification.Name("companyGlossaryChanged")
}

/// 公司词汇表（R53、design §36.3）：企业服务器后台维护的词，存在 SHIYIN_HOME/enterprise-glossary.json，跟自己的词一起用。
/// 转录、整理在背景线程读，所以不绑 MainActor，用锁保护
enum CompanyGlossary {
    private struct Stored: Codable {
        var terms: [String]
        var updatedAt: String?
    }

    private static let cache = OSAllocatedUnfairLock<[String]?>(initialState: nil)
    static var file: URL { Paths.home.appendingPathComponent("enterprise-glossary.json") }

    /// 上次从服务器拿到的（连不上时照样用）
    static var terms: [String] {
        cache.withLock { cached in
            if let cached { return cached }
            let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }?.terms ?? []
            cached = loaded
            return loaded
        }
    }

    /// 服务器给的词的上限（design §36.2，同 Windows）：最多 500 个、每个最多 100 字（UTF-16 单位），太长的略过
    static let maxTerms = 500
    static let maxTermLength = 100

    static func save(_ terms: [String], updatedAt: String?) {
        let cleaned = limited(terms)
        guard cleaned != self.terms else { return }
        if let data = try? JSONEncoder().encode(Stored(terms: cleaned, updatedAt: updatedAt)) {
            try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        cache.withLock { $0 = cleaned }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .companyGlossaryChanged, object: nil) }
    }

    /// 退出登录时删掉（R53.4）
    static func clear() {
        try? FileManager.default.removeItem(at: file)
        cache.withLock { $0 = [] }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .companyGlossaryChanged, object: nil) }
    }

    /// 自己的词在前、公司的接在后面，不分大小写去掉重复（转录的提示词有长度上限，R53.2）。
    /// 没有公司的词时照原本的词汇表、一个字都不动：没登录的人跟 4.1.2 一样（R52.5；自己存了「API」和「api」两个都留着）
    static func merge(_ own: [String], _ company: [String]) -> [String] {
        company.isEmpty ? own : clean(own + company)
    }

    /// 去掉空白、重复之后，略过太长的、只留前 maxTerms 个
    static func limited(_ terms: [String]) -> [String] {
        Array(clean(terms).filter { $0.utf16.count <= maxTermLength }.prefix(maxTerms))
    }

    private static func clean(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func merged(_ own: [String]) -> [String] { merge(own, terms) }

    static func contains(_ term: String) -> Bool {
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return terms.contains { $0.lowercased() == key }
    }
}
