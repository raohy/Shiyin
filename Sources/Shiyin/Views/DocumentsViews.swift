import SwiftUI

/// 会议的参考文档（design §39.4、R61.1、R61.4）：会议标题下信息列的菜单，放在会议语言之后
struct DocumentsMenu: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    var body: some View {
        let reading = model.readingDocuments[detail.meeting.id ?? 0] ?? []
        Menu {
            ForEach(detail.documents) { document in
                Menu(title(document)) {
                    Button("打开") { model.openDocument(document) }
                    Button("移除") { model.removeDocument(document) }
                }
            }
            ForEach(Array(reading.enumerated()), id: \.offset) { _, name in
                Button("正在读取「\(name)」…") {}.disabled(true)
            }
            if !detail.documents.isEmpty || !reading.isEmpty { Divider() }
            Button("加入文档…") { model.chooseDocuments() }
        } label: {
            Label(label(reading: !reading.isEmpty), systemImage: "paperclip")
        }
        .fixedSize()
        .help("会议中一起讨论的文档（演示文稿、规格书、报价单…）。整理会议记录、提问时会一起参考；也可以把文档拖进窗口")
    }

    private func label(reading: Bool) -> String {
        if reading { return String(localized: "正在读取文档…") }
        return detail.documents.isEmpty ? String(localized: "加入文档") : String(localized: "\(detail.documents.count) 份文档")
    }

    /// 「报价单.pdf（3 页）」；照长度分配后被截掉的接「，太长，只用前 N 页」（design §39.3）
    private func title(_ document: MeetingDocument) -> String {
        let use = detail.documentUse[document.id ?? 0]
        let pages = use?.document.pages.count ?? 0
        var text: String
        switch document.documentKind {
        case .pdf: text = String(localized: "\(document.name)（\(pages) 页）")
        case .pptx: text = String(localized: "\(document.name)（\(pages) 张幻灯片）")
        case .docx, .text, .image: text = document.name
        }
        if let use, use.truncated {
            switch use.cutByPages ? document.documentKind : .text {
            case .pdf: text += String(localized: "，太长，只用前 \(use.includedPages) 页")
            case .pptx: text += String(localized: "，太长，只用前 \(use.includedPages) 张")
            case .docx, .text, .image: text += String(localized: "，太长，只用前面的部分")
            }
        }
        return text
    }
}

/// 已经有会议记录、之后才加入或移除文档（R61.8）：记录标签页顶部提示刷新
struct DocumentsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Label("文档有变动，会议记录还没用上。", systemImage: "paperclip")
            Spacer()
            Button("不用") { model.dismissDocumentsChanged() }
            Button("刷新会议记录") { model.resummarize() }
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.celadon.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
