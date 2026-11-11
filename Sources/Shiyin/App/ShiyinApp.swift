import SwiftUI

/// 进入点在 main.swift（`--mcp` 要在 SwiftUI 启动前分流，design §44.1）
struct ShiyinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("拾音", id: "main") {
            RootView()
                .environment(AppModel.shared)
                .frame(minWidth: 960, minHeight: 620)
                .chineseGlyphs()
        }
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.presented)
        .commands { AppCommands(model: AppModel.shared) }

        Window("欢迎使用拾音", id: "onboarding") {
            OnboardingView()
                .environment(AppModel.shared)
                .chineseGlyphs()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("拾音使用说明", id: "guide") {
            GuideView()
                .tint(.celadon)
                .frame(minWidth: 520, minHeight: 480)
                .chineseGlyphs()
        }
        .defaultSize(width: 680, height: 780)
        .defaultLaunchBehavior(.suppressed)

        // 反馈问题（design §21.9）
        Window("反馈问题", id: "report") {
            ReportProblemView()
                .environment(AppModel.shared)
                .chineseGlyphs()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // 问所有会议（design §21.8）
        Window("问所有会议", id: "ask") {
            AskAllView()
                .environment(AppModel.shared)
                .chineseGlyphs()
        }
        .defaultSize(width: 680, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(AppModel.shared)
                .chineseGlyphs()
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(AppModel.shared)
                .chineseGlyphs()
        } label: {
            MenuBarLabel()
                .environment(AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.textSizeKey) private var textSize = 0

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { Task { await model.checkForUpdatesFromMenu() } }
        }
        CommandGroup(replacing: .newItem) {
            Button("准备会议…") { model.openMainWindow?(); model.openPreparation() }
            // 主窗口关着时先打开，不然对话框要等到下次打开主窗口才会跳出来
            Button("导入…") { model.openMainWindow?(); model.showFileImporter = true }
                .keyboardShortcut("o")
            Button(model.recorder.isRecording ? "停止录音" : "开始录音") { model.toggleRecording() }
                .keyboardShortcut("r")
            Button(model.recorder.isPaused ? "继续录音" : "暂停录音") {
                model.recorder.isPaused ? model.recorder.resume() : model.recorder.pause()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!model.recorder.isRecording)
            Button("标记重点") {
                model.addBookmark(at: model.recorder.elapsed, meetingId: model.recorder.meetingId)
                model.noticeMessage = String(localized: "已标记 \(TimeFormat.string(model.recorder.elapsed)) 为重点")
            }
            .keyboardShortcut("b")
            .disabled(!model.recorder.isRecording)
            Divider()
            Button("导出…") { model.openMainWindow?(); model.openExportSheet() }
                .keyboardShortcut("e")
                .disabled(model.detail == nil)
        }
        // 会议内容的文字大小（design §38.5、R59）：「显示」菜单；⌘= 不用按 Shift 也算放大（AppDelegate 拦下来）
        CommandGroup(after: .toolbar) {
            Divider()
            Button("放大文字") { TextSize.change(1) }
                .keyboardShortcut("+")
                .disabled(textSize >= TextSize.levels.upperBound)
            Button("缩小文字") { TextSize.change(-1) }
                .keyboardShortcut("-")
                .disabled(textSize <= TextSize.levels.lowerBound)
            Button("实际大小") { TextSize.change(nil) }
                .keyboardShortcut("0")
                .disabled(textSize == 0)
        }
        CommandGroup(replacing: .help) {
            Button("拾音使用说明") { openWindow(id: "guide") }
                .keyboardShortcut("?", modifiers: .command)
            Button("反馈问题…") { openWindow(id: "report") }
        }
        CommandMenu("会议") {
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.label) { model.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(model.detail == nil)
            }
            Divider()
            Button("播放／暂停") { model.player.toggle() }
                .disabled(!model.player.isLoaded)
            Divider()
            // 条件跟「更多」菜单一样；按下时 AppModel 会再检查一次
            Button("刷新会议记录") { model.resummarize() }
                .disabled(model.detail.map { ($0.segments.isEmpty && $0.meeting.userNotes.isEmpty) || $0.meeting.deletedAt != nil } ?? true
                          || model.detailStatus?.isActive == true)
            Button("复原上一版会议记录") { model.undoNotes() }
                .disabled((model.detail?.versionCount ?? 0) == 0 || model.detail?.meeting.deletedAt != nil
                          || model.detailStatus?.isActive == true)
            Divider()
            Button("复制会议记录（保留格式）") { model.copyNotes(.rich) }
                .disabled(model.detail == nil)
            Button("复制会议记录（Markdown）") { model.copyNotes(.markdown) }
                .disabled(model.detail == nil)
            Divider()
            Button("移到垃圾桶…") {
                // ⌘⌫ 在输入框里是「删到行首」，但菜单的快捷键会比输入框先收到，要交回给输入框
                if NSApp.currentEvent?.type == .keyDown, let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                    text.deleteToBeginningOfLine(nil)
                    return
                }
                model.openMainWindow?()
                model.requestDelete()
            }
                .keyboardShortcut(.delete)
                .disabled(model.detail == nil || model.showTrash)
        }
    }
}

extension View {
    /// 会议内容里的中文一律用简体中文的字形（design §16.2、§45）：英文界面时系统可能改用别的字形，
    /// 全角逗号、问号的位置不同。只影响中文字的字形，英文不受影响
    func chineseGlyphs() -> some View {
        typesettingLanguage(Locale.Language(identifier: "zh-Hans"))
    }

    /// 单独一段会议内容（会议列表的标题、搜索结果）的字形跟着会议语言（design §18.6）
    func contentGlyphs(_ language: MeetingLanguage) -> some View {
        environment(\.meetingLanguage, language).meetingText()
    }
}
