import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    /// 子程序还没读完 stdin 就结束时，写入会收到 SIGPIPE，默认会结束整个拾音（design §20.1）。
    /// 忽略之后写入只会失败，照常读子程序的结束代码和错误消息
    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        installSpaceKey()
        #if DEBUG
        DebugControl.install()
        #endif
    }

    /// 回到前景时更新 claude、codex 的登录状态（用户可能刚在终端登录，design §34.1）
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await CLILogin.refreshIfStale() }
    }

    /// 拖到 Dock 图标、Finder 的「打开方式」（R1.3）；企业服务器的加入链接 shiyin://join（R49.7）；
    /// AI 工具给的会议链接 shiyin://open（design §44.5）
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.start()
        for link in urls where EnterpriseJoin.isJoin(link) { Task { await EnterpriseJoin.handle(link) } }
        for link in urls { if let target = MeetingLink.parse(link) { AppModel.shared.openMeetingLink(target.meetingId, seconds: target.seconds) } }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { AppModel.shared.importDirectly(files) }
    }

    /// 关掉主窗口 app 不结束，录音和工作照常进行（R13.3）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 结束前让还开着的编辑器存草稿（design §21.15、R20.6）
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .flushDrafts, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.openMainWindow?() }
        return true
    }

    /// 录音中或有工作在跑时先确认（R11.7、R13.4）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let recording = model.recorder.isRecording
        let busy = model.runner.isBusy
        guard recording || busy else { return .terminateNow }
        #if DEBUG
        // shiyinctl quit：等于在确认对话框按「结束」
        if DebugControl.confirmQuit { return finishTermination(recording: recording) }
        #endif

        let alert = NSAlert()
        alert.messageText = recording ? String(localized: "正在录音，要结束拾音吗？") : String(localized: "还有工作在进行，要结束拾音吗？")
        var info: [String] = []
        if recording { info.append(String(localized: "录音会先存好，下次打开拾音时开始转录。")) }
        if busy { info.append(String(localized: "进行中的转录或整理会中断，下次打开时从头重跑。")) }
        alert.informativeText = info.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "结束"))
        alert.addButton(withTitle: String(localized: "取消"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return finishTermination(recording: recording)
    }

    /// 送出取消后要等 whisper 的 context 都释放了再结束：还在 GPU 上算的时候 exit，
    /// 静态解构会在 ggml_metal_device_free 里 abort（design §20.12）。最多等 10 秒。
    /// 用 run loop 的 Timer 等，不用 MainActor 的 Task：从主队列里调用 terminate 时，主队列不会再执行别的工作
    private func finishTermination(recording: Bool) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if recording { model.recorder.stop() }
        model.runner.terminateAll()
        guard WhisperContexts.active > 0 else { return .terminateNow }
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            let waited = Date().timeIntervalSince(started)
            guard WhisperContexts.active == 0 || waited >= 10 else { return }
            timer.invalidate()
            log.info("terminate: whisper stopped after \(String(format: "%.1f", waited), privacy: .public)s")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// 空白键播放／暂停；光标在输入框时不拦截（design §9.4）。
    /// ⌘=（美式键盘上 + 的那个键，不按 Shift）也算「放大文字」：菜单的 ⌘+ 要按 Shift 才对得上（design §38.5）
    private func installSpaceKey() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               event.charactersIgnoringModifiers == "=" {
                TextSize.change(1)
                return nil
            }
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = NSApp.keyWindow, window.identifier?.rawValue.hasPrefix("main") == true,
                  !(window.firstResponder is NSText),
                  AppModel.shared.player.isLoaded else { return event }
            AppModel.shared.player.toggle()
            return nil
        }
    }
}
