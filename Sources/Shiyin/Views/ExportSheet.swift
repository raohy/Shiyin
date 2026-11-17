import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 导出对话框（R7）：选项目、格式、选项，再存档或分享
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var item: ExportItem = .notes
    @State private var format = "md"
    @State private var times = true
    @State private var speakers = true
    @State private var working = false
    /// 「分享…」的位置：分享菜单（Mail、AirDrop、消息；R7.5）从按钮下面打开
    @State private var shareAnchor = MenuAnchorBox()
    /// 打开时那一场会议的资料（design §20.9）：对话框开着时选中的会议换了也不变
    @State private var bundle: ExportBundle?

    var body: some View {
        // 同其他弹窗的样子（R106、design §80）
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: bundle.map { String(localized: "导出「\($0.meeting.displayTitle)」") } ?? String(localized: "导出"))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "项目"))
                    SheetMenuField(options: ExportItem.allCases.map { ($0, $0.label) }, selection: $item) { item in
                        item == .audio && bundle?.meeting.hasAudio != true || item == .mindMap && !hasMindMap
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "格式"))
                    SheetMenuField(options: item.formats.map { ($0, formatLabel($0)) }, selection: $format)
                        .disabled(item.formats.count == 1)
                }
            }
            if item == .transcript {
                HStack(spacing: 18) {
                    Toggle("包含时间点", isOn: $times).disabled(format == "srt" || format == "vtt")
                    Toggle("包含说话者", isOn: $speakers)
                }
                .toggleStyle(.checkbox)
            }
            Text(hint)
                .font(.callout)
                .foregroundStyle(item == .notes && !hasNotes ? Color.signal : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("分享…") { Task { await share() } }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .background(MenuAnchor(box: shareAnchor))
                    .disabled(working)
                if working {
                    ProgressView().controlSize(.small)
                    Text("正在导出…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("存档…") { Task { await save() } }
                    .buttonStyle(SheetPillButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .sheetChrome(width: 480)
        .onChange(of: item) { _, newValue in format = newValue.formats[0] }
        // 还没有会议记录（整理中或整理失败）时，默认改导出逐字稿（用户反馈：导出的会议记录只有标题）
        .onAppear {
            bundle = model.exportMeetingId.flatMap { try? model.exportBundle(meetingId: $0) }
            if !hasNotes { item = .transcript }
        }
    }

    private var hasNotes: Bool { bundle?.notes != nil }
    /// 心智图要有内容（design §42.4）
    private var hasMindMap: Bool { bundle?.notes.map { !$0.isEmpty } ?? false }

    private var hint: String {
        switch item {
        case .notes:
            if !hasNotes {
                return String(localized: "这场会议还没有会议记录（还在整理或整理失败），导出的会议记录只会有标题和基本资料。要留下内容，请改导出逐字稿。")
            }
            return String(localized: "PDF 和 docx 的段落标题使用宋体；Markdown 适合贴到 Notion、GitHub。")
        case .mindMap: return String(localized: "依会议记录画成心智图。PNG 适合贴到聊天软件、演示文稿；SVG 可以再用其他软件编辑。")
        case .transcript: return String(localized: "srt、vtt 是字幕格式，可以搭配录音或视频在播放器里显示。")
        case .audio: return String(localized: "m4a 文件小、适合分享；wav 是 16 kHz 单声道，适合给其他转录工具使用。")
        case .package: return String(localized: "包含录音、逐字稿、说话者、会议记录、笔记和重点标记。传给同事后，对方双击就能导入拾音。")
        }
    }

    private func meetingId() throws -> Int64 {
        guard let id = model.exportMeetingId else { throw AppModel.ExportError.meetingGone }
        return id
    }

    private func formatLabel(_ format: String) -> String {
        ["md": "Markdown", "pdf": "PDF", "png": String(localized: "PNG 图片"), "svg": "SVG", "docx": String(localized: "Word（docx）"), "txt": String(localized: "纯文字（txt）"), "srt": String(localized: "字幕（srt）"),
         "vtt": String(localized: "字幕（vtt）"), "m4a": "m4a", "wav": "wav", "shiyin": String(localized: ".shiyin 封包")][format] ?? format
    }

    private func save() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.suggestedFilename(item, format: format, meeting: bundle?.meeting)
        if let type = UTType(filenameExtension: format) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        defer { working = false }
        do {
            try await model.export(item, format: format, times: times, speakers: speakers, meetingId: try meetingId(), to: url)
            model.noticeMessage = String(localized: "已导出 \(url.lastPathComponent)")
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func share() async {
        guard let url = await exportToTemp(), let view = shareAnchor.view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func exportToTemp() async -> URL? {
        guard let dir = try? Paths.makeTempDirectory() else { return nil }
        let url = dir.appendingPathComponent(model.suggestedFilename(item, format: format, meeting: bundle?.meeting))
        do {
            try await model.export(item, format: format, times: times, speakers: speakers, meetingId: try meetingId(), to: url)
            return url
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }
}
