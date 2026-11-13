import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    private var isRecordingThis: Bool { model.recorder.meetingId == detail.meeting.id }
    private var isTrashed: Bool { detail.meeting.deletedAt != nil }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            MeetingTop(detail: detail, isRecording: isRecordingThis)
                .environment(\.textScale, 1)   // 标题列不跟着文字大小（R59.2）

            Divider()

            if isRecordingThis {
                RecordingPanel(detail: detail)
            } else if detail.meeting.source == "prepared" && !isTrashed {
                PreparedMeetingView(meeting: detail.meeting)
            } else {
                Group {
                    switch model.tab {
                    case .summary: NotesPage(detail: detail)
                    // 换会议时重新创建：编辑中的状态、草稿是每场会议自己的（design §21.15）
                    case .transcript: TranscriptTab(detail: detail).id(detail.meeting.id)
                    case .ask: AskTab(detail: detail).id(detail.meeting.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if detail.meeting.hasAudio { PlayerBar(detail: detail) }
            }
        }
        .environment(\.meetingLanguage, detail.meeting.meetingLanguage)   // 内容的字形、标题字体（design §18.6）
        .contentTextScale()   // 会议内容的文字大小（design §38.5）
        .navigationTitle(detail.meeting.displayTitle)
        .toolbar {
            if !isRecordingThis {
                if detail.meeting.source != "prepared" {
                    ToolbarItem(placement: .principal) {
                        Picker("标签页", selection: $model.tab) {
                            ForEach(DetailTab.allCases) { tab in Text(tab.label).tag(tab) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                    }
                }
                // 垃圾桶里的会议不能操作
                if !isTrashed {
                    // 导出放在「更多」左边，看得到（R60、design §38.6）
                    if detail.meeting.source != "prepared" {
                        ToolbarItem(placement: .primaryAction) {
                            ExportMenu()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        MoreMenu(detail: detail)
                    }
                }
            }
        }
    }
}

struct MeetingHeader: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var editing = false

    var body: some View {
        let meeting = detail.meeting
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(meeting.displayTitle)
                    .contentTitleFont(26)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button("编辑") { editing = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.celadon)
                    .font(.callout)
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        EditInfoForm(meeting: meeting) { editing = false }
                    }
                Spacer(minLength: 0)
            }
            // 模板和语言菜单放在信息列右边，标题才能用整行的宽度（英文标题比较长，design §16.3）；
            // 信息列放不下时（说话者多、英文字比较长），菜单改到下一行，说话者名字才不会被截断
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    infoRow(meeting)
                    Spacer(minLength: 0)
                    menus(meeting)
                }
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(meeting)
                    HStack(spacing: 12) { menus(meeting) }
                }
            }
        }
    }

    private func infoRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 16) {
            if !meeting.folder.isEmpty {
                Label(meeting.folder, systemImage: "folder").help("这场会议所在的文件夹")
            }
            Text("\(meeting.meetingDate) \(DateText.weekday(meeting.meetingDate))")
            if meeting.durationSeconds != nil { Text(TimeFormat.duration(meeting.durationSeconds)) }
            if let minutes = detail.untranscribedMinutes {
                // 自动停止的录音（design §35.3、R48.3）：后面没人说话的部分没有转录
                Label("最后 \(minutes) 分钟没有人说话，没有转录", systemImage: "moon.zzz")
                    .help("录音中很久没人说话，拾音自动停止了录音。要转录全部的话，用「更多 → 重新处理 → 重新转录」。")
            }
            if !detail.speakers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(detail.speakers.keys.sorted(), id: \.self) { idx in
                        if detail.speakerSources[idx] == "voiceprint" {
                            AutoSpeakerName(idx: idx, name: detail.speakers[idx] ?? "", others: detail.speakerCandidates[idx] ?? [])
                        } else {
                            Text(detail.speakers[idx] ?? "").foregroundStyle(Color.speaker(idx))
                        }
                    }
                }
            } else if !meeting.participantList.isEmpty {
                Text(meeting.participantList.joined(separator: String(localized: "、")))
            }
        }
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menus(_ meeting: Meeting) -> some View {
        Menu {
            ForEach(model.templates) { template in
                Button {
                    model.setTemplate(template.id)
                } label: {
                    if template.id == meeting.templateId { Label(template.displayName, systemImage: "checkmark") }
                    else { Text(template.displayName) }
                }
            }
        } label: {
            Label(model.templates.first { $0.id == meeting.templateId }?.displayName ?? String(localized: "一般会议"), systemImage: "doc.text")
        }
        .fixedSize()
        .help("会议记录的模板。换了模板之后，从「更多 → 重新处理」选「刷新会议记录」就会照新模板整理")
        // 会议语言（design §16.3）
        Menu {
            ForEach(MeetingLanguage.allCases) { language in
                Button {
                    model.setMeetingLanguage(language)
                } label: {
                    if language == meeting.meetingLanguage { Label(language.name, systemImage: "checkmark") }
                    else { Text(language.name) }
                }
            }
        } label: {
            Label(meeting.meetingLanguage.name, systemImage: "globe")
        }
        .fixedSize()
        .help("会议语言：决定转录和会议记录用的语言。改了之后，从「更多 → 重新处理」重新转录或刷新会议记录")
        // 会议的参考文档（design §39.4）：垃圾桶里的会议不放
        if meeting.deletedAt == nil { DocumentsMenu(detail: detail) }
        // 录音中先填人数（design §26.2）：录完转录时用
        if model.recorder.isRecording && model.recorder.meetingId == meeting.id {
            Menu {
                Button {
                    model.setMinSpeakers(nil)
                } label: {
                    if meeting.minSpeakers == nil { Label("自动判断", systemImage: "checkmark") } else { Text("自动判断") }
                }
                ForEach(2...12, id: \.self) { n in
                    Button {
                        model.setMinSpeakers(n)
                    } label: {
                        if meeting.minSpeakers == n { Label("\(n) 人", systemImage: "checkmark") } else { Text("\(n) 人") }
                    }
                }
            } label: {
                Label(meeting.minSpeakers.map { String(localized: "大约 \($0) 人") } ?? String(localized: "人数：自动判断"),
                      systemImage: "person.2")
            }
            .fixedSize()
            .help("大约几个人：人多、吵杂或手机放在桌上录音时，先告诉拾音大约几个人，说话者会分得比较准")
        }
    }
}

/// 修改标题、日期、与会者
struct EditInfoForm: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let onDone: () -> Void
    @State private var title = ""
    @State private var date = Date()
    @State private var participants = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("标题", text: $title)
                DatePicker("会议日期", selection: $date, displayedComponents: .date)
                TextField("与会者", text: $participants, prompt: Text("用逗号分隔"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    // 标题栏预先填的是显示用的标题（还没命名时是文件名）；没动过就照原样存，不然会被当成自订标题锁住，整理时不会再取名
                    let edited = title.trimmingCharacters(in: .whitespaces)
                    model.updateInfo(title: edited == meeting.displayTitle ? meeting.title : edited,
                                     date: DateText.string(date), participants: participants)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            title = meeting.displayTitle
            date = DateText.date(meeting.meetingDate) ?? Date()
            participants = meeting.participants
        }
    }
}

struct TrashBanner: View {
    @Environment(AppModel.self) private var model
    let meetingId: Int64
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 12) {
            Label("这场会议在垃圾桶里，30 天后会永久删除", systemImage: "trash")
            Spacer()
            Button("还原") { model.restore(meetingId) }
            Button("永久删除", role: .destructive) { confirm = true }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("永久删除这场会议？", isPresented: $confirm) {
            Button("永久删除", role: .destructive) { model.deletePermanently(meetingId) }
        } message: {
            Text("会议记录、逐字稿和录音档都会删除，没办法复原。")
        }
    }
}

/// 工作进度、失败原因
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let detail: MeetingDetail

    var body: some View {
        if let status = model.detailStatus, status != .recording, let content = content(status) {
            HStack(spacing: 12) {
                content
                Spacer(minLength: 12)
                actions(status)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background(status), in: RoundedRectangle(cornerRadius: 8))
        } else if let helper = model.runner.running.values.first(where: {
            $0.job.meetingId == detail.meeting.id && ($0.job.kind == .correct || $0.job.kind == .nameSpeakers || $0.job.kind == .rediarize)
        }) {
            // 背景的辅助工作（design §21.2）：不算会议的状态，但让用户知道还在跑
            let provider = helper.provider?.shortLabel ?? ""
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                switch helper.job.kind {
                case .correct: Text("正在用 \(provider) 检查可能听错的字…")
                case .rediarize: Text("正在重新识别说话者…")
                default: Text("正在用 \(provider) 猜说话者的名字…")
                }
                Spacer(minLength: 12)
                Button("取消") { model.cancelJobs() }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func content(_ status: MeetingStatus) -> AnyView? {
        let running = model.runner.runningJob(for: detail.meeting.id!)
        switch status {
        case .queued:
            let kind = detail.latestJob?.kind
            return AnyView(Label(kind == .transcribe ? "排队等待转录" : "排队等待整理", systemImage: "clock"))
        case .transcribing(_, _) where running?.server?.waiting == true:
            // 在等企业服务器（连不上、登录失效，R50.5）：不显示百分比
            return AnyView(Label(running?.server?.text ?? "", systemImage: "clock").lineLimit(2))
        case .transcribing(let progress, let stage):
            let note = running?.server?.text ?? ""
            return AnyView(HStack(spacing: 10) {
                Text(transcribingText(progress, stage: stage, remaining: running?.remaining) + (note.isEmpty ? "" : String(localized: "，\(note)")))
                    .monospacedDigit()
                if let progress {
                    ProgressView(value: progress).frame(width: 160).tint(.signal)
                } else {
                    ProgressView().controlSize(.small)
                }
            })
        case .summarizing:
            let provider = running?.provider?.shortLabel ?? ""
            return AnyView(HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                switch running?.job.kind {
                case .revise: Text("正在用 \(provider) 依你的回答修正会议记录…")
                default: Text("正在用 \(provider) 整理会议记录…")
                }
            })
        case .failed(let kind, let stored):
            let message = MeetingLanguage.uiStored(stored)
            return AnyView(Label {
                Text(kind == .transcribe ? String(localized: "转录失败：\(message)") : String(localized: "整理失败：\(message)")).lineLimit(3).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            })
        case .cancelled:
            return AnyView(Label("已取消转录", systemImage: "xmark.circle"))
        default:
            return nil
        }
    }

    @ViewBuilder
    private func actions(_ status: MeetingStatus) -> some View {
        switch status {
        case .transcribing where model.runner.runningJob(for: detail.meeting.id!)?.server != nil:
            // 企业服务器在排队、连不上时，可以改在这台 Mac 转录（R50.5）
            Button("改在这台电脑转录") { model.runner.transcribeLocally(meetingId: detail.meeting.id!) }
            Button("取消") { model.cancelJobs() }
        case .queued, .transcribing, .summarizing: Button("取消") { model.cancelJobs() }
        case .failed(let kind, let message):
            // 设置问题（没登录、key 错误…）而且还没修好（R46.2、design §34.4）：给修的按钮，不放「重试」（重试也一样会失败）
            if kind != .transcribe, LLMError.isSetupProblem(errorKind: detail.latestJob?.errorKind),
               let problem = model.summarizerProblem {
                Button(problem.actionTitle) {
                    switch problem.action {
                    case .openSettings: openSettings()
                    case .login(let provider): CLILogin.openLogin(provider)
                    }
                }
            } else {
                // 登录问题（3.1.2）：先引导重新登录，登录完再按重试
                if kind != .transcribe, LLMError.isLoginMessage(message),
                   AppSettings.provider == .claude || AppSettings.provider == .codex {
                    // 桌面版附的 codex：打开那个 app 登录（R55.3）
                    let title = CLILogin.desktopApp(AppSettings.provider).map { String(localized: "打开 \($0) 登录") }
                        ?? String(localized: "重新登录 \(AppSettings.provider.shortLabel)")
                    Button(title) { CLILogin.openLogin(AppSettings.provider) }
                }
                Button("重试") { model.retry() }
            }
        case .cancelled: Button("重新转录") { model.retry() }
        default: EmptyView()
        }
    }

    private func background(_ status: MeetingStatus) -> Color {
        if case .failed = status { return Color.red.opacity(0.1) }
        return Color.signal.opacity(0.12)
    }

    private func transcribingText(_ progress: Double?, stage: String, remaining: TimeInterval?) -> String {
        guard let progress else { return stage.isEmpty ? String(localized: "准备转录…") : "\(stage)…" }
        var text = String(localized: "\(stage.isEmpty ? String(localized: "转录") : stage)中 \(Int(progress * 100))%")
        if let remaining, remaining > 0 {
            text += remaining < 60 ? String(localized: "，快好了") : String(localized: "，约剩 \(Int((remaining / 60).rounded(.up))) 分钟")
        }
        return text
    }
}

/// 右上角的「导出」（R60、design §38.6）：按下打开导出对话框，箭头直接复制会议记录。
/// 工具列的菜单创建一次就不更新，动作在按下时才看目前选中的会议（同「更多」）
struct ExportMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("复制会议记录：保留格式（贴到 Word、Notion、邮件）") { model.copyNotes(.rich) }
            Button("复制会议记录：Markdown") { model.copyNotes(.markdown) }
            Button("复制会议记录：纯文字（贴到 Slack、消息）") { model.copyNotes(.plain) }
            Divider()
            Button("复制心智图（图片）") { model.copyMindMap() }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        } primaryAction: {
            model.openExportSheet()
        }
        .labelStyle(.titleAndIcon)
        .help("导出会议记录、逐字稿或录音（⌘E）；箭头可以直接复制会议记录")
    }
}

struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    // 工具列右上角的菜单创建一次就不会更新（换会议、工作开始或结束都一样，加 .id 也没用），
    // 所以这里不预先禁用：按下时由 AppModel 检查目前的会议，不能做就说明原因
    var body: some View {
        // 三项（R44.4、R60，design §33.2、§38.6）：重新处理的四个动作收成子菜单；两个「复原」回到记录的编辑列和说话者的改名处；
        // 导出、复制会议记录在左边的「导出」
        Menu {
            Menu("重新处理", systemImage: "arrow.clockwise") {
                Button("刷新会议记录", systemImage: "arrow.clockwise") { model.resummarize() }
                Button("检查可能听错的字", systemImage: "text.magnifyingglass") { model.checkTranscript() }
                Button("重新转录（含说话者识别）", systemImage: "waveform") { model.retranscribe() }
                Button("重新识别说话者…", systemImage: "person.2.wave.2") { model.requestRediarize() }
            }
            Divider()
            // 工具列的菜单创建一次就不会更新（禁用状态、按钮记住的会议），动作一律在按下时才看目前选中的会议
            FolderMenu()
            Button("移到垃圾桶", systemImage: "trash", role: .destructive) {
                if let id = model.selection { model.moveToTrash(id) }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .help("更多动作")
    }
}

/// 会议页上方：标题、状态或垃圾桶提示、草稿提示。截屏（DEBUG 的 snapshot）也用这一份
struct MeetingTop: View {
    let detail: MeetingDetail
    var isRecording = false

    var body: some View {
        let trashed = detail.meeting.deletedAt != nil
        VStack(alignment: .leading, spacing: 14) {
            MeetingHeader(detail: detail)
            if trashed { TrashBanner(meetingId: detail.meeting.id!) } else { StatusBanner(detail: detail) }
            if detail.meeting.notesDraft != 0 && detail.notes != nil && !isRecording && !trashed {
                DraftNotesBanner()
            }
            if !detail.speakerSuggestions.isEmpty && !isRecording && !trashed {
                SpeakerSuggestionsBanner(detail: detail)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 会议记录是用实时逐字稿整理的草稿（design §21.3、R19.1）
struct DraftNotesBanner: View {
    var body: some View {
        Label("草稿：用录音中的实时逐字稿整理的，正式转录完成后会自动更新", systemImage: "doc.badge.clock")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 声纹自动带入的说话者名字（design §21.4、R19.3）：名字后面标「自动」。
/// 点一下直接选是别人（最像的几位认识的人，一次改名、记住声音、改会议记录，R33.4），或说不是他
private struct AutoSpeakerName: View {
    @Environment(AppModel.self) private var model
    let idx: Int
    let name: String
    let others: [String]

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                if !others.isEmpty {
                    Section("是别人：") {
                        ForEach(others, id: \.self) { other in
                            Button(other) { model.renameSpeaker(idx, to: other) }
                        }
                    }
                }
                Button("其他人…（到逐字稿改名）") { model.tab = .transcript }
                Divider()
                Button("不是\(name)（不知道是谁）") { model.rejectVoiceprintMatch(idx) }
            } label: {
                Text(name).foregroundStyle(Color.speaker(idx))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // 菜单按钮在画面上只画标题的文字（标签里的背景会被拿掉），「自动」标记要放在菜单外面
            Text("自动")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .help("拾音认出这个人的声音，自动带入名字。不对的话点名字")
    }
}

/// AI 猜到的说话者名字（design §21.5、R19.2）：按「套用」才改名
private struct SpeakerSuggestionsBanner: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var showing = false

    var body: some View {
        let suggestions = detail.speakerSuggestions.sorted { $0.key < $1.key }
        HStack(spacing: 10) {
            Label("猜到 \(suggestions.count) 位说话者的名字", systemImage: "person.crop.circle.badge.questionmark")
            Spacer()
            Button("查看") { showing = true }
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("猜到的说话者名字").font(.headline)
                        ForEach(suggestions, id: \.key) { idx, suggestion in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(detail.speakers[idx] ?? "").foregroundStyle(Color.speaker(idx))
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(suggestion.name).fontWeight(.semibold)
                                    Spacer()
                                    Button("忽略") { model.dismissSpeakerSuggestion(idx) }.buttonStyle(.link)
                                    Button("套用") { model.applySpeakerSuggestion(idx) }.buttonStyle(.link)
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    if !suggestion.time.isEmpty { TimeButton(time: suggestion.time) }
                                    Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Text("套用后，逐字稿和会议记录都会换成名字。").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("全部套用") { model.applyAllSpeakerSuggestions(); showing = false }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                    .frame(width: 420)
                }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.celadon.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
