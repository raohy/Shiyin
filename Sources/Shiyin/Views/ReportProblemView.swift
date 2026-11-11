import AppKit
import SwiftUI

/// 反馈问题（design §21.9、R19.7）：先让用户看会附上的信息，按「在 GitHub 反馈」才打开浏览器
struct ReportProblemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("反馈问题").font(.songti(20))
            Text("按「在 GitHub 反馈」会用浏览器打开新的 issue，并带入下面的内容，你可以在浏览器里修改后再送出。内容只有版本、环境和错误的种类，不包含会议内容、文件名或 API key。没有 GitHub 账号的话，可以按「复制」用其他方式寄给维护的人。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if copied { Label("已复制", systemImage: "checkmark").foregroundStyle(.secondary) }
                Spacer()
                Button("关闭") { dismissWindow(id: "report") }
                    .keyboardShortcut(.cancelAction)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                Button("在 GitHub 反馈") {
                    if let url = ProblemReport.url(body: text) { NSWorkspace.shared.open(url) }
                    dismissWindow(id: "report")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear {
            text = ProblemReport.text(db: model.db)
            copied = false
        }
    }
}
