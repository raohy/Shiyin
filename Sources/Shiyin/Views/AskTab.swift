import SwiftUI

/// 对这场会议提问（design §21.8、R19.6）：回答附上录音时间点，点了跳过去；问答记录留在会议里
struct AskTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.textScale) private var scale
    let detail: MeetingDetail
    @State private var question = ""

    private var asking: Bool { model.asking == .meeting(detail.meeting.id!) }
    private var request: AskRequest? {
        model.askRequest?.target == .meeting(detail.meeting.id!) ? model.askRequest : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if snapshotMode {
                // 截屏画不出 ScrollView 的内容（DEBUG 的 snapshot），直接排出来
                list
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { list }
                        .onChange(of: model.meetingQuestions.count) { _, _ in
                            if let last = model.meetingQuestions.last?.id { withAnimation { proxy.scrollTo(last, anchor: .top) } }
                        }
                        .onChange(of: request?.id) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                        }
                        .onAppear {
                            if let id = request?.id { proxy.scrollTo(id, anchor: .top) }
                        }
                }
            }
            Divider()
            AskInputBar(question: $question, placeholder: String(localized: "问这场会议，例如：谁负责寄信的部分？"),
                        busy: model.asking != nil, onClear: model.meetingQuestions.isEmpty ? nil : {
                            model.clearQuestions(meetingId: detail.meeting.id)
                        }) {
                model.askMeeting(question)
                if asking { question = "" }
            }
        }
        .onAppear { model.loadMeetingQuestions(detail.meeting.id!) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.meetingAssistance != nil {
                MeetingAssistancePanel(meeting: detail.meeting, recording: false)
                Divider()
            }
            if model.meetingQuestions.isEmpty && request == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("问这场会议").font(.songti(18))
                    Text("例如：「谁负责寄信的部分？」「最后决定的上线日期是哪一天？」回答只根据这场会议的会议记录和逐字稿，每一点都附上时间，点了就能听原话。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.meetingQuestions) { record in
                QuestionView(record: record) { time in
                    if let seconds = TimeFormat.seconds(time) { model.player.seek(to: seconds) }
                }
                .id(record.id)
            }
            if let request {
                AskRequestView(request: request).id(request.id)
            }
        }
        .contentFont()   // 文字大小（design §38.5）
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(maxWidth: 760 * scale, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 提问的输入列（单场和所有会议共用）
struct AskInputBar: View {
    @Environment(AppModel.self) private var model
    @Binding var question: String
    let placeholder: String
    let busy: Bool
    var onClear: (() -> Void)?
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = model.askUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.signal)
            }
            HStack(spacing: 10) {
                TextField(placeholder, text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(submit)
                Button("提问", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.askUnavailableReason != nil)
                if let onClear {
                    Menu {
                        Button("清除问答记录", role: .destructive, action: onClear)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多")
                    .disabled(busy)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    private func submit() {
        guard !busy, model.askUnavailableReason == nil, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit()
    }
}

/// 问题先显示在问答列表里，回答完成后由整组问答替换。
struct AskRequestView: View {
    @Environment(AppModel.self) private var model
    let request: AskRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.question).fontWeight(.semibold).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                if request.phase.isRunning { ProgressView().controlSize(.small) }
                Text(request.phase.label).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if request.phase.isRunning {
                TimelineView(.periodic(from: request.startedAt, by: 1)) { context in
                    Text("使用 \(request.providerLabel) · 已用时 \(TimeFormat.string(max(0, context.date.timeIntervalSince(request.startedAt))))")
                        .contentFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("完成后会在这里显示完整回答和出处。")
                        .contentFont(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("取消") { model.cancelAsk() }.buttonStyle(.link)
                }
            } else {
                HStack(spacing: 14) {
                    Button("重试") { model.retryAsk() }.buttonStyle(.link)
                    Button("关闭") { model.askRequest = nil }.buttonStyle(.link)
                }
                .disabled(model.asking != nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 一组问答：问题、回答、出处（时间点，跨会议时加上会议名称）
struct QuestionView: View {
    @Environment(AppModel.self) private var model
    let record: QuestionRecord
    var meetingTitle: ((Int64) -> String?)? = nil
    let onCitation: (String) -> Void
    var onMeetingCitation: ((Int64, String) -> Void)? = nil

    var body: some View {
        let answer = record.decoded
        VStack(alignment: .leading, spacing: 8) {
            Text(record.question).fontWeight(.semibold).textSelection(.enabled)
            if let answer {
                // 回答常用 **粗体**：解析行内的 Markdown，保留换行和「- 」列点
                Text((try? AttributedString(markdown: answer.answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(answer.answer))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(answer.found ? .primary : .secondary)
                if !answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(answer.citations.enumerated()), id: \.offset) { _, citation in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let id = citation.meetingId, let onMeetingCitation {
                                    Button {
                                        onMeetingCitation(id, citation.time)
                                    } label: {
                                        Text("\(meetingTitle?(id) ?? String(localized: "会议")) \(citation.time)")
                                            .contentFont(.callout, monospacedDigit: true)
                                            .foregroundStyle(Color.celadon)
                                    }
                                    .buttonStyle(.plain)
                                    .help("打开这场会议，从 \(citation.time) 开始")
                                } else if citation.time.isEmpty {
                                    // 参考文档的出处（design §39.3）：没有录音的时间点，quote 开头写了文档名称和页数
                                    Image(systemName: "paperclip")
                                        .contentFont(.callout)
                                        .foregroundStyle(.secondary)
                                        .help("出自这场会议的参考文档")
                                } else {
                                    Button(citation.time) { onCitation(citation.time) }
                                        .buttonStyle(.plain)
                                        .contentFont(.callout, monospacedDigit: true)
                                        .foregroundStyle(Color.celadon)
                                        .help("从 \(citation.time) 开始播放")
                                }
                                Text(citation.quote).contentFont(.callout).foregroundStyle(.secondary).lineLimit(2).meetingText()
                            }
                        }
                    }
                }
                if let ids = answer.meetingIds, record.meetingId == nil {
                    Text(ids.isEmpty ? String(localized: "没有找到相关的会议") : String(localized: "参考了 \(ids.count) 场会议"))
                        .contentFont(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 问所有会议（design §21.8）：独立的窗口，可以一边看会议一边问；出处点了打开那场会议
struct AskAllView: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var scope: AskScope = .all
    private var request: AskRequest? { model.askRequest?.target == .all ? model.askRequest : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("问所有会议").font(.songti(20))
                Spacer()
                Picker("范围", selection: $scope) {
                    ForEach(AskScope.allCases) { scope in
                        if scope != .folder || model.folderFilter != nil { Text(scope.label).tag(scope) }
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.allQuestions.isEmpty && request == nil {
                            Text("例如：「上个月跟客户谈过哪些价格？」「寄信的机制最后怎么决定的？」拾音会先找出相关的会议片段，再请整理工具回答，回答附上是哪一场会议、哪个时间点。")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.allQuestions) { record in
                            QuestionView(record: record, meetingTitle: { id in
                                model.meetings.first { $0.id == id }?.meeting.displayTitle
                            }, onCitation: { _ in }, onMeetingCitation: { id, time in model.openCitation(meetingId: id, time: time) })
                            .id(record.id)
                        }
                        if let request {
                            AskRequestView(request: request).id(request.id)
                        }
                    }
                    .contentFont()   // 文字大小（design §38.5）
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.allQuestions.count) { _, _ in
                    if let last = model.allQuestions.last?.id { withAnimation { proxy.scrollTo(last, anchor: .top) } }
                }
                .onChange(of: request?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                }
                .onAppear {
                    if let id = request?.id { proxy.scrollTo(id, anchor: .top) }
                }
            }
            Divider()
            AskInputBar(question: $question, placeholder: String(localized: "问所有会议，例如：寄信的机制最后怎么决定的？"),
                        busy: model.asking != nil, onClear: model.allQuestions.isEmpty ? nil : { model.clearQuestions(meetingId: nil) }) {
                model.askAll(question, scope: scope)
                if model.asking == .all { question = "" }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .contentTextScale()
        .onAppear { model.loadAllQuestions() }
    }
}
