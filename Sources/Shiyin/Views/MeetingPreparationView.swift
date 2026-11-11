import SwiftUI

struct MeetingPreparationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meetingId: Int64?
    @State private var title = ""
    @State private var preparation = MeetingPreparation(enabled: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会前准备").font(.songti(24))
            Text("告诉助手会议讨论什么，以及你想确认什么。保存后可以稍后再开始录音。")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("会议标题（可选）", text: $title).textFieldStyle(.roundedBorder)
                    editor("会议主要内容", text: $preparation.background, limit: 4000)
                    editor("本场目标", text: $preparation.goals, limit: 2000)
                    editor("我的角色和关注点（可选）", text: $preparation.role, limit: 1000)
                    editor("已有问题（可选，每行一个）", text: $preparation.initialQuestions, limit: 4000)
                    Toggle("开启会中提问助手", isOn: $preparation.enabled)
                    Text("开启后，会前资料和录音中的实时定稿文字会交给当前选择的整理工具处理，约每 30 秒分析一次。可以在录音时随时关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(2)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存会前准备") {
                    if model.saveMeetingPreparation(id: meetingId, title: title, preparation: preparation) != nil { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!preparation.hasContext || model.recorder.isRecording)
            }
        }
        .padding(24)
        .frame(width: 640, height: 650)
        .task {
            guard let meetingId else { return }
            title = (try? model.db.meeting(meetingId))?.title ?? ""
            if let state = try? model.db.assistance(meetingId) { preparation = state.preparation }
        }
    }

    private func editor(_ title: LocalizedStringKey, text: Binding<String>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium))
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 68)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel(title)
                .onChange(of: text.wrappedValue) { _, value in
                    if value.count > limit { text.wrappedValue = String(value.prefix(limit)) }
                }
        }
    }
}

struct PreparedMeetingView: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        ReadingColumn {
            Text("会议已准备好").contentTitleFont(24)
            Text("准备内容已保存。开始录音后，左侧显示实时逐字稿，右侧按会议进展给出提问建议。")
                .foregroundStyle(.secondary)
            Button("开始这场会议的录音", systemImage: "record.circle") {
                model.selection = meeting.id
                model.startRecording()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.recorder.isRecording)
            MeetingAssistancePanel(meeting: meeting, recording: false)
        }
    }
}

/// 录音时显示最值得关注的待问问题，会后在提问页保留完整清单。
struct MeetingAssistancePanel: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let recording: Bool
    @State private var showAll = false

    private var id: Int64 { meeting.id! }
    private var trashed: Bool { meeting.deletedAt != nil }

    var body: some View {
        let state = model.meetingAssistance ?? MeetingAssistance()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("会中提问助手").font(.songti(18))
                Spacer(minLength: 4)
                if recording {
                    Toggle("开启会中提问助手", isOn: Binding(get: { state.preparation.enabled },
                        set: { model.setCoachEnabled(id, enabled: $0) }))
                        .toggleStyle(.switch).labelsHidden()
                } else if !trashed {
                    Button("编辑会前准备") { model.openPreparation(id) }.disabled(model.recorder.isRecording)
                }
            }
            if recording {
                Text("会前资料和实时定稿文字会交给当前整理工具处理。")
                    .font(.caption).foregroundStyle(.secondary)
                if state.preparation.enabled {
                    if !AppSettings.liveTranscription || !model.recorder.liveStatus.isEmpty {
                        Text("需要实时逐字稿的定稿文字才能分析。请确认实时逐字稿已开启并准备就绪。")
                            .font(.caption).foregroundStyle(Color.signal)
                    }
                    HStack(spacing: 8) {
                        if model.coach.busy { ProgressView().controlSize(.small) }
                        Button("立即分析") { model.coach.analyze(id) }
                            .disabled(model.coach.busy || model.recorder.isPaused)
                    }
                    Text(model.coach.message).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("会中分析已关闭，已有问题会继续保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.preparation.hasContext {
                DisclosureGroup("会前准备") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.preparation.background)
                        if !state.preparation.goals.isEmpty { Text("目标：\(state.preparation.goals)") }
                        if !state.preparation.role.isEmpty { Text("角色与关注点：\(state.preparation.role)") }
                    }
                    .font(.callout).textSelection(.enabled)
                }
            }
            if !state.summary.isEmpty {
                DisclosureGroup("当前讨论摘要") { Text(state.summary).font(.callout).textSelection(.enabled) }
            }
            let questions = recording && !showAll ? Array(state.pending.prefix(5)) : state.questions
            if questions.isEmpty {
                Text("有值得追问的内容时，建议会显示在这里。也可以在会前准备中加入已有问题。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(questions) { question in questionCard(question) }
            if recording && (state.questions.count > questions.count || showAll) {
                Button(showAll ? "只看优先待问" : "显示全部问题（\(state.questions.count)）") { showAll.toggle() }
                    .font(.caption)
            }
        }
        .onAppear { model.reloadAssistance(id) }
    }

    private func questionCard(_ question: CoachQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(question.text).font(.callout.weight(.medium)).textSelection(.enabled)
                Spacer(minLength: 2)
                if question.priority == 1 && question.status == .pending {
                    Text("优先").font(.caption).foregroundStyle(Color.signal)
                }
            }
            if !question.reason.isEmpty { Text(question.reason).font(.caption).foregroundStyle(.secondary) }
            if let time = question.time {
                HStack {
                    Text("依据").font(.caption).foregroundStyle(.secondary)
                    if recording { Text(TimeFormat.string(time)).font(.caption.monospacedDigit()) }
                    else { TimeButton(time: TimeFormat.string(time)).font(.caption) }
                }
                Text(question.quote).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 10) {
                if question.status == .pending {
                    Button("已问") { model.markCoachQuestion(id, question: question.id, status: .asked) }
                    Button("忽略") { model.markCoachQuestion(id, question: question.id, status: .ignored) }
                } else {
                    Text(question.status == .asked ? "已问" : "已忽略").foregroundStyle(.secondary)
                    Button("恢复待问") { model.markCoachQuestion(id, question: question.id, status: .pending) }
                }
            }
            .font(.caption).buttonStyle(.link).disabled(trashed)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
