import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// 读出会议参考文档的文字（design §39.2、R61.2）：PDF 用 PDFKit，扫描的页面和图片用 Vision 的文字识别，
/// docx、pptx 自己读 XML（规则跟 Windows 一样，标准答案比对），纯文字照 UTF-8／UTF-16 读
enum DocumentReader {
    struct Result: Equatable {
        var kind: DocumentKind
        var pages: [String]
        var ocr: Bool
    }

    enum DocumentError: LocalizedError, Equatable {
        case unsupported(ext: String)
        case tooLarge(String), locked(String), unreadable(String), empty(String), encoding(String), duplicate(String)

        /// 标准答案比的是原因，不是消息（消息跟着界面语言）
        var code: String {
            switch self {
            case .unsupported(let ext): return "unsupported:\(ext)"
            case .tooLarge: return "tooLarge"
            case .locked: return "locked"
            case .unreadable: return "unreadable"
            case .empty: return "empty"
            case .encoding: return "encoding"
            case .duplicate: return "duplicate"
            }
        }

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                switch ext {
                case "key": return String(localized: "拾音读不了 Keynote 档。请先在 Keynote 导出成 PDF 再加入。")
                case "pages": return String(localized: "拾音读不了 Pages 档。请先在 Pages 导出成 PDF 再加入。")
                case "numbers": return String(localized: "拾音读不了 Numbers 档。请先在 Numbers 导出成 PDF 再加入。")
                case "doc": return String(localized: "拾音读不了旧版的 Word 档（.doc）。请另存成 docx 或 PDF 再加入。")
                case "": return String(localized: "拾音读不了没有扩展名的文件。请先导出成 PDF 再加入。")
                default: return String(localized: "拾音读不了 .\(ext) 档。请先导出成 PDF 再加入。")
                }
            case .tooLarge(let name): return String(localized: "「\(name)」超过 200 MB，拾音不读这么大的文档。")
            case .locked(let name): return String(localized: "「\(name)」有密码保护，拾音读不了。请先移除密码再加入。")
            case .unreadable(let name): return String(localized: "「\(name)」读不出来，文件可能坏了。")
            case .empty(let name): return String(localized: "「\(name)」里读不到文字。")
            case .encoding(let name): return String(localized: "「\(name)」不是 UTF-8 的文字档。请另存成 UTF-8 再加入。")
            case .duplicate(let name): return String(localized: "「\(name)」已经加过了")
            }
        }
    }

    static let maxBytes = 200 * 1024 * 1024
    /// 扫描的页面最多识别几页（R61.7）
    static let maxOCRPages = 50
    /// 一页的文字（不算空白）少于这个数就当成扫描的页面
    static let scannedPageChars = 20

    static func kind(of url: URL) -> DocumentKind? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "pptx": return .pptx
        case "txt", "md", "markdown": return .text
        case "png", "jpg", "jpeg", "heic": return .image
        default: return nil
        }
    }

    /// 拖进主窗口时当成文档的（R61.3）：读得了的，加上看得出是文档、要说明怎么办的。txt、md 照旧是逐字稿、笔记
    static func isDroppedDocument(_ url: URL) -> Bool {
        ["pdf", "docx", "pptx", "png", "jpg", "jpeg", "heic",
         "key", "pages", "numbers", "doc", "rtf", "ppt", "xls", "xlsx"].contains(url.pathExtension.lowercased())
    }

    /// 「加入文档…」的选档类型
    static var openPanelTypes: [UTType] {
        [.pdf, .plainText, .png, .jpeg, .heic]
            + ["docx", "pptx", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    /// 在背景执行：文字识别一页约 0.5～1 秒
    static func read(_ url: URL, language: MeetingLanguage) throws -> Result {
        let name = url.lastPathComponent
        guard let kind = kind(of: url) else { throw DocumentError.unsupported(ext: url.pathExtension.lowercased()) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else { throw DocumentError.tooLarge(name) }
        var ocr = false
        let raw: [String]
        switch kind {
        case .pdf: (raw, ocr) = try readPDF(url, name: name, language: language)
        case .docx: raw = [try OfficeText.docx(url, name: name)]
        case .pptx: raw = try OfficeText.pptx(url, name: name)
        case .text: raw = [try readText(url, name: name)]
        case .image:
            let (image, orientation) = try loadImage(url, name: name)
            raw = [try recognize(image, orientation: orientation, language: language)]
            ocr = true
        }
        let pages = raw.map(normalize)
        guard pages.contains(where: { !$0.isEmpty }) else { throw DocumentError.empty(name) }
        return Result(kind: kind, pages: pages, ocr: ocr)
    }

    // MARK: 整理文字（Windows 照同样的规则）

    private static let blank: Set<Character> = [" ", "\t", "\u{00A0}", "\u{3000}"]

    /// 换行统一成 \n、每行去掉行尾的空白、连续的空行只留一行、整页去掉头尾的空白和换行
    static func normalize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [Substring] = []
        var blankLines = 0
        for var line in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            while let last = line.last, blank.contains(last) { line.removeLast() }
            if line.isEmpty {
                blankLines += 1
                if blankLines > 1 { continue }
            } else {
                blankLines = 0
            }
            lines.append(line)
        }
        var joined = Substring(lines.joined(separator: "\n"))
        while let first = joined.first, blank.contains(first) || first == "\n" { joined.removeFirst() }
        while let last = joined.last, blank.contains(last) || last == "\n" { joined.removeLast() }
        return String(joined)
    }

    // MARK: PDF

    private static func readPDF(_ url: URL, name: String, language: MeetingLanguage) throws -> ([String], Bool) {
        guard let pdf = PDFDocument(url: url) else { throw DocumentError.unreadable(name) }
        guard !pdf.isLocked else { throw DocumentError.locked(name) }
        var pages: [String] = []
        var recognizedPages = 0
        var ocr = false
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { pages.append(""); continue }
            var text = normalize(page.string ?? "")
            if text.filter({ !$0.isWhitespace }).count < scannedPageChars, recognizedPages < maxOCRPages, let image = render(page) {
                recognizedPages += 1
                let recognized = normalize(try recognize(image, orientation: .up, language: language))
                if recognized.count > text.count {
                    text = recognized
                    ocr = true
                }
            }
            pages.append(text)
        }
        return (pages, ocr)
    }

    /// 长边 2000 px、白底，自己画（不用 NSImage 的缩略图，背景线程也安全）
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return nil }
        let scale = 2000 / longest
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: 图片、文字识别

    private static func loadImage(_ url: URL, name: String) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DocumentError.unreadable(name) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation, language: MeetingLanguage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = language.profile.ocr.mac   // 语言档（design §41.5）
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: 纯文字

    private static func readText(_ url: URL, name: String) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable(name) }
        let decoded: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            decoded = String(data: data, encoding: .utf8)
        }
        guard let decoded else { throw DocumentError.encoding(name) }
        return decoded
    }
}

/// docx、pptx 的文字（design §39.2、D136）：`unzip -p` 只取要读的 XML（不解出图片），同一套规则读 Word 的段落、表格和幻灯片
enum OfficeText {
    /// 一个 XML 档解压后最多多大：防止压缩炸弹
    static let maxEntryBytes = 64 * 1024 * 1024

    static func docx(_ url: URL, name: String) throws -> String {
        guard let xml = entry(url, "word/document.xml") else { throw DocumentReader.DocumentError.unreadable(name) }
        return try text(xml, name: name)
    }

    static func pptx(_ url: URL, name: String) throws -> [String] {
        guard let presentation = entry(url, "ppt/presentation.xml"),
              let rels = entry(url, "ppt/_rels/presentation.xml.rels") else { throw DocumentReader.DocumentError.unreadable(name) }
        let ids = SlideList.ids(presentation)
        let targets = Relationships.targets(rels)
        var pages: [String] = []
        for id in ids {
            guard let target = targets[id], let path = resolve(target), let xml = entry(url, path) else { continue }
            pages.append(try text(xml, name: name))
        }
        guard !pages.isEmpty else { throw DocumentReader.DocumentError.unreadable(name) }
        return pages
    }

    /// 幻灯片的 Target 相对于 ppt/；「/」开头是从根算。有 .. 或奇怪字符的不读（unzip 的参数是通配符的样式）
    static func resolve(_ target: String) -> String? {
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-")
        guard !target.isEmpty, !path.hasSuffix("/"), path.unicodeScalars.allSatisfy(allowed.contains),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return path
    }

    /// 解出 zip 里的一个档；找不到、坏掉、太大都是 nil
    static func entry(_ url: URL, _ path: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", "-qq", url.path, path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxEntryBytes {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    static func text(_ xml: Data, name: String) throws -> String {
        let reader = TextCollector()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw DocumentReader.DocumentError.unreadable(name) }
        return reader.output
    }

    /// 段落、表格的规则（design §39.2）：只看元素的本地名称，Word（w:）和幻灯片（a:）共用
    private final class TextCollector: NSObject, XMLParserDelegate {
        private(set) var output = ""
        private var stack: [String] = []
        private var collecting = false
        private var fallback = 0
        private var tableDepth = 0
        private var cell = ""
        private var row: [String] = []

        private func emit(_ text: String) {
            if tableDepth > 0 { cell += text } else { output += text }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let parent = stack.last
            stack.append(elementName)
            if elementName == "Fallback" { fallback += 1 }
            guard fallback == 0 else { return }
            switch elementName {
            case "t": collecting = parent == "r" || parent == "fld"
            case "tab": if parent == "r" { emit("\t") }
            case "br": if parent == "r" || parent == "p" { emit("\n") }
            case "cr": if parent == "r" { emit("\n") }
            case "tbl":
                tableDepth += 1
                if tableDepth == 1 { row = []; cell = "" }
            case "tr": if tableDepth == 1 { row = [] }
            case "tc": if tableDepth == 1 { cell = "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting && fallback == 0 { emit(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if !stack.isEmpty { stack.removeLast() }
            if elementName == "Fallback" {
                fallback = max(0, fallback - 1)
                return
            }
            guard fallback == 0 else { return }
            switch elementName {
            case "t": collecting = false
            case "p": emit(tableDepth > 0 ? " " : "\n")
            case "tc":
                if tableDepth == 1 {
                    row.append(DocumentReader.normalize(cell.replacingOccurrences(of: "\n", with: " ")))
                    cell = ""
                }
            case "tr":
                if tableDepth == 1 {
                    output += row.joined(separator: " | ") + "\n"
                    row = []
                }
            case "tbl": tableDepth = max(0, tableDepth - 1)
            default: break
            }
        }
    }

    /// presentation.xml 的 sldIdLst：每个 sldId 的 r:id，照顺序
    private final class SlideList: NSObject, XMLParserDelegate {
        private var ids: [String] = []

        static func ids(_ xml: Data) -> [String] {
            let list = SlideList()
            let parser = XMLParser(data: xml)
            parser.shouldProcessNamespaces = true
            parser.delegate = list
            parser.parse()
            return list.ids
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard elementName == "sldId",
                  let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value else { return }
            ids.append(id)
        }
    }

    /// presentation.xml.rels：Id → Target（外部链接不算）
    private final class Relationships: NSObject, XMLParserDelegate {
        private var targets: [String: String] = [:]

        static func targets(_ xml: Data) -> [String: String] {
            let rels = Relationships()
            let parser = XMLParser(data: xml)
            parser.shouldProcessNamespaces = true
            parser.delegate = rels
            parser.parse()
            return rels.targets
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard elementName == "Relationship", let id = attributes["Id"], let target = attributes["Target"],
                  attributes["TargetMode"] != "External" else { return }
            targets[id] = target
        }
    }
}
