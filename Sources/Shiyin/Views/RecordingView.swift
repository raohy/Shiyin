import SwiftUI

/// 录音中的画面（design §5.4、R2）：实时逐字稿＋我的笔记＋重点
struct RecordingPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textScale) private var scale
    let detail: MeetingDetail
    @State private var followLatest = true

    var body: some View {
        #if DEBUG
        let _ = DebugMetrics.bump("recordingPanelBody")
        #endif
        let recorder = model.recorder
        VStack(spacing: 0) {
            // 计时、音量每 0.05 秒变一次，只让这一块重算（design §21.12）
            Isolated { controls(recorder) }
            if let change = recorder.languageSwitch {
                // 自动检测换了语言（design §18.8）：可以改回来
                HStack(spacing: 12) {
                    Label("听起来是\(change.to.uiName)，实时逐字稿和会议语言已经改成\(change.to.uiName)", systemImage: "globe")
                    Spacer()
                    Button("改回\(change.from.uiName)") { recorder.switchLanguage(to: change.from) }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.signal.opacity(0.12))
            }
            if recorder.idlePrompt {
                // 忘了停止录音（design §35.2、R48.1）
                HStack(spacing: 12) {
                    Label("好像没人在说话了，要停止录音吗？再 15 分钟没人说话会自动停止。", systemImage: "moon.zzz")
                    Spacer()
                    Button("继续录") { recorder.continueAfterIdle() }
                    Button("停止录音") { recorder.stop() }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.signal.opacity(0.12))
            }
            if let hint = recorder.micHint {
                // 用蓝牙耳机的麦克风录现场会议（design §38.4、R58.3）
                HStack(spacing: 12) {
                    Label(hint.text, systemImage: "headphones")
                    Spacer()
                    if let builtIn = hint.builtIn {
                        Button("改用 \(builtIn.name)") { model.switchMicrophone(builtIn.uid) }
                            .buttonStyle(.borderedProminent)
                            .help("录音不会中断，接着用这支麦克风录；之后的录音也用这支")
                    }
                    Button("知道了") { recorder.dismissMicHint() }
                        .help("这场录音不再提示这件事")
                }
                .font(.callout)
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.signal.opacity(0.12))
            }
            if let hint = recorder.levelHint {
                // 收音提醒（design §26.1）
                HStack(spacing: 12) {
                    Label(recorder.text(for: hint), systemImage: hint == .noisy ? "waveform.badge.exclamationmark" : "mic.badge.xmark")
                    Spacer()
                    Button("知道了") { recorder.dismissLevelHint() }
                        .help("这场录音不再提示这件事")
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.signal.opacity(0.12))
            }
            Divider()
            // 不用 HSplitView：它在 NavigationSplitView 里会把内容撑到窗口的默认宽度，窗口窄的时候左右被切掉
            HStack(spacing: 0) {
                Isolated { liveTranscript(recorder) }
                    .frame(minWidth: 300, maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView { MeetingAssistancePanel(meeting: detail.meeting, recording: true).padding(.bottom, 8) }
                    Divider()
                    Text("我的笔记").font(.songti(16))
                    Text("每换一行会自动加上当下的录音时间；整理时会优先纳入这些内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    UserNotesEditor(meetingId: detail.meeting.id!, initial: detail.meeting.userNotes) { recorder.elapsed }
                        .frame(height: 140)
                }
                .padding(16)
                .frame(width: 340)
            }
        }
    }

    private func controls(_ recorder: Recorder) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(recorder.isPaused ? Color.secondary : .red).frame(width: 10, height: 10)
                Text(recorder.isPaused ? "已暂停" : "录音中")
                RecorderClock(recorder: recorder).foregroundStyle(.secondary)
            }
            .font(.title3)
            if recorder.hasMic {
                Label { RecorderMeter(recorder: recorder, system: false) } icon: { Image(systemName: "mic") }
                    .help("麦克风音量")
                // 正在用哪一支麦克风，点一下可以换（design §38.3、R58.2）；窗口窄的时候先缩这个
                MicrophoneMenu(recorder: recorder)
                    .frame(maxWidth: 180, alignment: .leading)
                    .layoutPriority(-1)
            }
            if recorder.hasSystem {
                Label { RecorderMeter(recorder: recorder, system: true) } icon: { Image(systemName: "speaker.wave.2") }
                    .help("电脑播放的声音（在线会议的对方）")
            }
            Spacer(minLength: 0)
            // 窗口窄的时候（侧边栏打开、窗口宽 960）按钮只留图标，说明放在鼠标提示。
            // 英文的字比较长，中间多一层：暂停、标记只留图标，「停止并转录」保留文字
            ViewThatFits(in: .horizontal) {
                actionButtons(recorder).labelStyle(.titleAndIcon)
                HStack(spacing: 14) {
                    HStack(spacing: 14) { pauseButton(recorder); bookmarkButton(recorder) }.labelStyle(.iconOnly)
                    stopButton(recorder).labelStyle(.titleAndIcon)
                }
                .fixedSize()
                actionButtons(recorder).labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottomLeading) {
            if let warning = warning(recorder) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.signal)
                    .padding(.leading, 20)
                    .offset(y: 14)
            }
        }
    }

    private func actionButtons(_ recorder: Recorder) -> some View {
        HStack(spacing: 14) {
            pauseButton(recorder)
            bookmarkButton(recorder)
            stopButton(recorder)
        }
        .fixedSize()
    }

    private func pauseButton(_ recorder: Recorder) -> some View {
        Button(recorder.isPaused ? "继续" : "暂停", systemImage: recorder.isPaused ? "play.fill" : "pause.fill") {
            recorder.isPaused ? recorder.resume() : recorder.pause()
        }
        .help(recorder.isPaused ? "继续录音（⇧⌘P）" : "暂停录音（⇧⌘P）")
    }

    private func bookmarkButton(_ recorder: Recorder) -> some View {
        Button("标记重点", systemImage: "star") {
            model.addBookmark(at: recorder.elapsed, meetingId: detail.meeting.id)
            model.noticeMessage = String(localized: "已标记 \(TimeFormat.string(recorder.elapsed)) 为重点")
        }
        .help("标记这个时间点（⌘B），整理时会被当成重点")
    }

    private func stopButton(_ recorder: Recorder) -> some View {
        Button("停止并转录", systemImage: "stop.fill") { recorder.stop() }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("停止录音，开始正式转录")
    }

    private func warning(_ recorder: Recorder) -> String? {
        if let warning = recorder.deviceWarning { return warning }
        if recorder.hasSystem && recorder.systemSilent {
            return String(localized: "超过 15 秒没有收到系统声音：请确认在线会议有声音，并在「系统设置 → 隐私与安全性 → 录制屏幕与系统录音」允许拾音")
        }
        return recorder.liveStatus.isEmpty ? nil : recorder.liveStatus
    }

    private func liveTranscript(_ recorder: Recorder) -> some View {
        #if DEBUG
        DebugMetrics.bump("liveTranscriptBuild")
        #endif
        // 每个重点只标在一段上：开始时间不晚于它的最后一段
        let starred = Set(detail.bookmarks.compactMap { mark in recorder.liveLines.last(where: { $0.start <= mark.time })?.id })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if recorder.liveLines.isEmpty && recorder.volatileText.isEmpty {
                        Text(AppSettings.liveTranscription ? "开始说话后，逐字稿会实时出现在这里。" : "实时逐字稿已在设置中关闭，录音结束后会正式转录。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recorder.liveLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(TimeFormat.string(line.start)).contentFont(.callout, monospacedDigit: true).foregroundStyle(Color.celadon)
                                .frame(width: 52 * scale, alignment: .trailing)
                            Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).meetingText()
                            if starred.contains(line.id) {
                                Image(systemName: "star.fill").foregroundStyle(Color.signal).contentFont(.caption)
                            }
                        }
                        .id(line.id)
                    }
                    // 还没定稿的文字一直在变，只让这一行重算，不拖着整份实时逐字稿（design §21.12）
                    Isolated {
                        if !recorder.volatileText.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("…").frame(width: 52 * scale, alignment: .trailing).foregroundStyle(.tertiary)
                                Text(recorder.volatileText).foregroundStyle(.secondary).meetingText()
                            }
                            .id("volatile")
                            .onChange(of: recorder.volatileText.count) { _, _ in
                                guard followLatest else { return }
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .contentFont()   // 文字大小（design §38.5）
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 用户往回看时不要自动滚动（R2.2）：看滚动的位置。往上卷（内容没有变短）就不跟了，回到底部再跟。
            // 不用「底部的标记出现／消失」改状态：那是在排版途中改，可能让排版一直重来（design §25）
            .onScrollGeometryChange(for: LivePosition.self) { geometry in
                LivePosition(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                             bottom: geometry.visibleRect.maxY)
            } action: { old, new in
                if new.bottom >= new.content - 40 {
                    if !followLatest { followLatest = true }
                } else if new.offset < old.offset - 1 && new.content >= old.content {
                    if followLatest { followLatest = false }
                }
            }
            .onChange(of: recorder.liveLines.count) { _, _ in
                guard followLatest else { return }
                if reduceMotion { proxy.scrollTo("bottom", anchor: .bottom) }
                else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLatest {
                    Button("回到最新", systemImage: "arrow.down") {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        followLatest = true
                    }
                    .padding(12)
                }
            }
        }
    }
}

/// 用户笔记（R2.3）：换行时自动加上时间点，停下来 0.8 秒后存档
struct UserNotesEditor: View {
    @Environment(AppModel.self) private var model
    let meetingId: Int64
    let initial: String
    let now: () -> Double?
    @State private var text = ""
    @State private var savedText = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $text).meetingText()
            .contentFont()   // 文字大小（design §38.5）
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .onAppear {
                text = initial
                savedText = initial
            }
            .onChange(of: text) { old, new in
                if let stamp = now().map({ "[\(TimeFormat.string($0))] " }) {
                    if old.isEmpty && !new.isEmpty && !new.hasPrefix("[") {
                        text = stamp + new
                        return
                    }
                    if new.count == old.count + 1 && new.hasSuffix("\n") {
                        text = new + stamp
                        return
                    }
                }
                guard new != savedText else { return }
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    save()
                }
            }
            .onDisappear {
                saveTask?.cancel()
                // 只有用户改过才存，避免用旧内容盖掉别处写进去的笔记
                if text != savedText { save() }
            }
            // 别处改了笔记（例如导入 Markdown 笔记）：换成新的内容，不然下一次存档会盖回旧的
            .onChange(of: initial) { _, new in
                guard new != savedText else { return }
                saveTask?.cancel()
                text = new
                savedText = new
            }
    }

    private func save() {
        savedText = text
        model.saveUserNotes(meetingId, text)
    }
}

/// 逐字稿顶部的「我的笔记」（R44.3，design §33.1）：默认收起，标签写有几行；展开是录音中同一个编辑器，播放时换行会加上播放时间。
/// 展开状态只记这次选中期间（AppModel.userNotesExpanded，换会议收起）
struct UserNotesDisclosure: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    /// 有字的行数
    private var lineCount: Int {
        detail.meeting.userNotes.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { model.userNotesExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                        Text(lineCount > 0 ? String(localized: "我的笔记（\(lineCount) 行）") : String(localized: "写笔记")).font(.callout)
                        Image(systemName: model.userNotesExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !detail.bookmarks.isEmpty {
                    Menu("重点标记 \(detail.bookmarks.count)") {
                        ForEach(detail.bookmarks) { bookmark in
                            Button("\(TimeFormat.string(bookmark.time)) \(bookmark.label)") { model.player.seek(to: bookmark.time) }
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if model.userNotesExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // 不能加 fixedSize：量最小高度时会用很窄的宽度，算出很高的高度，整个窗口的内容被往上推（2026-11-05 用户看到）
                    Text("播放录音时换行，会自动加上当下的播放时间。整理时 AI 会参考这些笔记；改完之后可以从「更多 → 重新处理」选「刷新会议记录」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    UserNotesEditor(meetingId: detail.meeting.id!, initial: detail.meeting.userNotes) {
                        model.player.isPlaying ? model.player.currentTime : nil
                    }
                    .frame(height: 180)
                    .id(detail.meeting.id)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }
}

/// 实时逐字稿滚动的位置：卷了多少、内容多高、看得到的底部在哪
struct LivePosition: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var bottom: CGFloat
}

/// 录音的经过时间：在自己的 body 里读，整秒变了只重算这一个 Text（design §25）
struct RecorderClock: View {
    let recorder: Recorder
    var body: some View { Text(TimeFormat.string(Double(recorder.elapsedSeconds))).monospacedDigit() }
}

/// 录音的音量条（design §25）：AppKit 的 view 自己定时读音量，不经过 SwiftUI 的更新。
/// DEBUG 截屏（ImageRenderer 画不出 AppKit 的 view）时用 SwiftUI 的 VUMeter
struct RecorderMeter: View {
    @Environment(\.snapshotMode) private var snapshotMode
    let recorder: Recorder
    let system: Bool
    var segments = 14

    var body: some View {
        if snapshotMode {
            VUMeter(level: system ? recorder.systemLevel : recorder.micLevel, segments: segments)
        } else {
            LevelMeter(segments: segments) { [recorder, system] in system ? recorder.systemLevel : recorder.micLevel }
        }
    }
}

/// 让内容在自己的 body 里算：里面读到、一直在变的资料（计时、音量、播放位置、还没定稿的文字）
/// 只会让这一块重算，不会拖着外面整个画面一起重算（design §21.12）
struct Isolated<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// 录音画面的麦克风名称（design §38.3、R58.2）：写出实际在收音的那一支，点一下从清单换，录音不中断
struct MicrophoneMenu: View {
    @Environment(AppModel.self) private var model
    let recorder: Recorder

    var body: some View {
        let monitor = MicrophoneMonitor.shared
        let current = recorder.micDevice
        Menu {
            Button {
                model.switchMicrophone("")
            } label: {
                Text(monitor.defaultInput.map { String(localized: "系统默认（\($0.name)）") } ?? String(localized: "系统默认"))
            }
            Divider()
            ForEach(monitor.inputs) { device in
                Button {
                    model.switchMicrophone(device.uid)
                } label: {
                    if device.uid == current?.uid { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        } label: {
            Text(current?.name ?? String(localized: "麦克风")).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .help(current.map { String(localized: "正在用「\($0.name)」收音，点一下可以换") } ?? String(localized: "点一下可以换麦克风"))
        .accessibilityLabel(String(localized: "麦克风：\(current?.name ?? "")"))
    }
}
