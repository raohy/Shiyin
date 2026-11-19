import Foundation

/// 只负责录音界面的显示；数据库仍分别保留快稿和复核稿。
struct LiveTranscriptDisplay {
    struct Line: Identifiable, Hashable {
        let id = UUID()
        var start: Double
        var end: Double
        var text: String
        var reviewed: Bool
    }

    private struct Coverage {
        var start: Double
        var end: Double
    }

    private(set) var lines: [Line] = []
    private(set) var previewText = ""
    private var previewStart = 0.0
    private var previewEnd = 0.0
    private var coverage: [Coverage] = []
    private static let timeTolerance = 0.001

    var visiblePreview: String {
        isCovered(start: previewStart, end: previewEnd) ? "" : previewText
    }

    mutating func setPreview(start: Double, end: Double, text: String) {
        previewStart = start
        previewEnd = end
        previewText = text
    }

    @discardableResult
    mutating func addDraft(start: Double, end: Double, text: String) -> Bool {
        guard !text.isEmpty, !isCovered(start: start, end: end) else { return false }
        insert(Line(start: start, end: end, text: text, reviewed: false))
        return true
    }

    @discardableResult
    mutating func addReview(start: Double, end: Double, text: String) -> Bool {
        guard start.isFinite, end.isFinite, end > start,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        coverage.append(Coverage(start: start, end: end))
        coverage.sort { $0.start < $1.start }
        var merged: [Coverage] = []
        for range in coverage {
            if let last = merged.indices.last, range.start <= merged[last].end + Self.timeTolerance {
                merged[last].end = max(merged[last].end, range.end)
            } else {
                merged.append(range)
            }
        }
        coverage = merged
        // 时间戳不逐字对齐：跨界快稿保留到整个时间范围被复核覆盖，不能按比例截字。
        let ranges = coverage
        lines.removeAll { !$0.reviewed && Self.isCovered(start: $0.start, end: $0.end, by: ranges) }
        insert(Line(start: start, end: end, text: text, reviewed: true))
        return true
    }

    private func isCovered(start: Double, end: Double) -> Bool {
        Self.isCovered(start: start, end: end, by: coverage)
    }

    private static func isCovered(start: Double, end: Double, by coverage: [Coverage]) -> Bool {
        guard start.isFinite, end.isFinite, end > start else { return false }
        return coverage.contains { $0.start <= start + Self.timeTolerance && $0.end >= end - Self.timeTolerance }
    }

    private mutating func insert(_ line: Line) {
        if lines.last.map({ $0.start <= line.start }) ?? true {
            lines.append(line)
            return
        }
        let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
        lines.insert(line, at: index)
    }
}
