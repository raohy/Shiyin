import SwiftUI

/// 待确认（R6）：每题可以回答或略过，送出后由 LLM 依回答修正。
/// 最上面是说话者的题目（声纹没把握的、AI 猜的，R33、design §27）：送出时直接改名字，不经过整理工具。
/// 回答存在 `ReviewDraft`（design §31.2），跟记录旁的就地回答（R41.2）共用同一份。
/// 4.1 起嵌在记录顶部的「还有 N 题待确认」里（`embedded`，R44.2）：不自己滚动、不另外留边
struct ReviewTab: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    var embedded = false

    private var items: [MeetingNotes.ReviewItem] { detail.notes?.reviewItems ?? [] }
    private var speakerItems: [(idx: Int, suggestion: SpeakerNaming.Suggestion)] {
        detail.speakerSuggestions.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        if detail.notes == nil && speakerItems.isEmpty {
            NotesPlaceholder(detail: detail)
        } else if items.isEmpty && speakerItems.isEmpty {
            ReadingColumn {
                Label("没有待确认的项目", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.celadon)
                Text("会议记录里推测出来的人名、专有名词、负责人和期限，都已经确认过了。")
                    .foregroundStyle(.secondary)
            }
        } else if let draft = model.reviewDraft, draft.meetingId == detail.meeting.id {
            content(draft)
        }
    }

    private func content(_ draft: ReviewDraft) -> some View {
        VStack(spacing: 0) {
            if embedded {
                VStack(alignment: .leading, spacing: 18) { rows(draft) }
            } else {
                ReadingColumn { rows(draft) }
            }
            Divider().padding(.vertical, embedded ? 8 : 0)
            HStack(spacing: 12) {
                Text(footnote)
                    .contentFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(draft.submitTitle) { model.submitReviewDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasSomethingToSubmit || model.detailStatus?.isActive == true)
            }
            .padding(.horizontal, embedded ? 0 : 32)
            .padding(.vertical, embedded ? 0 : 12)
        }
    }

    /// 说明、全部略过、说话者的题目、记录的题目
    @ViewBuilder private func rows(_ draft: ReviewDraft) -> some View {
        let speakerIdxs = speakerItems.map(\.idx)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(items.contains(where: \.yesNo) || !speakerItems.isEmpty
                 ? "以下是整理时不确定的地方。按「是」「不是」或直接回答就好；看不懂或不重要的可以略过。"
                 : "以下是整理时不确定的地方。直接回答就好；看不懂或不重要的可以略过。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // 全部略过（R41.5）：还没回答的都标成略过，已经有回答的不动
            Button("全部略过") { draft.skipAllUnanswered(questionCount: items.count, speakers: speakerIdxs) }
                .disabled(!draft.hasUnanswered(questionCount: items.count, speakers: speakerIdxs))
                .help("还没回答的题目都标成略过，送出后直接移除")
        }
        ForEach(speakerItems, id: \.idx) { item in
            speakerRow(item.idx, item.suggestion, draft: draft)
        }
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            ReviewQuestionRow(index: index, item: item, language: language, draft: draft)
        }
    }

    /// 说话者的题目（R33.2）：「『说话者 3』是 weiwei 吗？」，下面是原因；选「不是」可以挑最像的人或打名字，也可以不填
    private func speakerRow(_ idx: Int, _ suggestion: SpeakerNaming.Suggestion, draft: ReviewDraft) -> some View {
        let skipped = draft.speakerSkipped.contains(idx)
        let current = detail.speakers[idx] ?? ""
        let question = language.format(zh: "「%@」是%@吗？", en: "Is “%@” %@?", ja: "「%@」は%@ですか？",
                                       current, suggestion.name)  // l10n-skip：会议语言的题目
        let choice = YesNoAnswer(draft.speakerAnswers[idx] ?? "", language: language) ?? YesNoAnswer(isYes: nil)
        let others = (detail.speakerCandidates[idx] ?? []).filter { $0.caseInsensitiveCompare(suggestion.name) != .orderedSame }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.speaker(idx))
                    .frame(width: 12)
                Text(question).meetingText()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(skipped ? .secondary : .primary)
                    .strikethrough(skipped)
                // 略过的题目收成一行（R41.5）：只留题目和「取消略过」
                if skipped {
                    Spacer(minLength: 0)
                    SkipButton(skipped: true) { draft.speakerSkipped.remove(idx) }
                }
            }
            if !skipped {
                if !suggestion.reason.isEmpty || !suggestion.time.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !suggestion.time.isEmpty { TimeButton(time: suggestion.time) }
                        Text(suggestion.reason).meetingText()
                            .contentFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 22)
                }
                HStack(spacing: 12) {
                    YesNoPicker(choice: choice, language: language, disabled: false) { draft.speakerAnswers[idx] = $0 }
                    Spacer()
                    SkipButton(skipped: false) { draft.speakerSkipped.insert(idx) }
                }
                .padding(.leading, 22)
                if choice.isYes == false {
                    HStack(spacing: 10) {
                        if !others.isEmpty {
                            Menu("是…") {
                                ForEach(others, id: \.self) { name in
                                    Button(name) { draft.speakerAnswers[idx] = YesNoAnswer(isYes: false, correction: name).text(language) }
                                }
                            }
                            .fixedSize()
                        }
                        TextField("是谁？（可以不填）", text: Binding(get: { choice.correction }, set: { text in
                            draft.speakerAnswers[idx] = YesNoAnswer(isYes: false, correction: text).text(language)
                        }))
                        .textFieldStyle(.roundedBorder)
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    private var language: MeetingLanguage { detail.meeting.meetingLanguage }

    private var footnote: String {
        let provider = AppSettings.provider == .none ? "LLM" : AppSettings.provider.label
        let speakers = String(localized: "说话者的题目不会送给整理工具，送出后直接换名字。")
        guard !items.isEmpty else { return speakers }
        let notes = String(localized: "有回答的题目会交给 \(provider) 依答案修正会议记录；略过的题目直接移除。改错了可以按「编辑」旁的「复原上一版」。")
        return speakerItems.isEmpty ? notes : notes + " " + speakers
    }
}

/// 一题待确认（design §31.2）：待确认标签页和记录旁的就地回答共用。
/// 是非题（R32）给「是」「不是」，选了「不是」才要填正确的答案；旧的草稿认不出来时照旧用输入框
struct ReviewQuestionRow: View {
    let index: Int
    let item: MeetingNotes.ReviewItem
    let language: MeetingLanguage
    let draft: ReviewDraft

    var body: some View {
        let isDismissed = draft.dismissed.contains(index)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(index + 1)")
                    .contentFont(.callout, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(Color.signal)
                TimeButton(time: item.time)
                Text(item.question).meetingText()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isDismissed ? .secondary : .primary)
                    .strikethrough(isDismissed)
                // 略过的题目收成一行（R41.5）：只留题号、时间点、题目和「取消略过」
                if isDismissed {
                    Spacer(minLength: 0)
                    SkipButton(skipped: true) { draft.dismissed.remove(index) }
                }
            }
            if isDismissed {
                EmptyView()
            } else if item.yesNo, let choice = YesNoAnswer(draft.answers[index] ?? "", language: language) {
                HStack(spacing: 12) {
                    YesNoPicker(choice: choice, language: language, disabled: false) { draft.answers[index] = $0 }
                    Spacer()
                    SkipButton(skipped: false) { draft.dismissed.insert(index) }
                }
                .padding(.leading, 22)
                if choice.isYes == false {
                    TextField("正确的是…（可以不填）", text: Binding(get: { choice.correction }, set: { text in
                        draft.answers[index] = YesNoAnswer(isYes: false, correction: text).text(language)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 22)
                }
            } else {
                HStack(spacing: 12) {
                    TextField("你的回答", text: Binding(get: { draft.answers[index] ?? "" }, set: { draft.answers[index] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    SkipButton(skipped: false) { draft.dismissed.insert(index) }
                }
                .padding(.leading, 22)
            }
        }
    }
}

/// 「略过」「取消略过」（R41.5）：不用勾选框，按了那题收成一行
struct SkipButton: View {
    let skipped: Bool
    let action: () -> Void

    var body: some View {
        Button(skipped ? "取消略过" : "略过", action: action)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// 是非题的「是」「不是」（design §27）：选了「是」就清掉填过的答案
struct YesNoPicker: View {
    let choice: YesNoAnswer
    let language: MeetingLanguage
    let disabled: Bool
    let set: (String) -> Void

    var body: some View {
        Picker("回答", selection: Binding(get: { choice.isYes }, set: { yes in
            set(YesNoAnswer(isYes: yes, correction: yes == false ? choice.correction : "").text(language))
        })) {
            Text("是").tag(Bool?.some(true))
            Text("不是").tag(Bool?.some(false))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(disabled)
    }
}

/// 是非题的回答（design §27）：存成会议语言的文字，就是草稿和送给校稿的回答。
/// 「是」→ 是／Yes／はい；「不是」→ 不是／No／いいえ；不是而且填了答案 →「不是，答案」「No, 答案」「いいえ、答案」
struct YesNoAnswer: Equatable {
    /// nil：还没选
    var isYes: Bool?
    var correction = ""

    init(isYes: Bool?, correction: String = "") {
        self.isYes = isYes
        self.correction = correction
    }

    /// 从存起来的文字认回来；空字符串是还没选，认不出来的（例如旧的草稿）回传 nil
    init?(_ text: String, language: MeetingLanguage) {
        let yes = Self.yes(language), no = Self.no(language), separator = Self.separator(language)
        if text.isEmpty {
            self.init(isYes: nil)
        } else if text == yes {
            self.init(isYes: true)
        } else if text == no {
            self.init(isYes: false)
        } else if text.hasPrefix(no + separator) {
            self.init(isYes: false, correction: String(text.dropFirst(no.count + separator.count)))
        } else {
            return nil
        }
    }

    func text(_ language: MeetingLanguage) -> String {
        switch isYes {
        case nil: return ""
        case true?: return Self.yes(language)
        case false?: return correction.isEmpty ? Self.no(language) : Self.no(language) + Self.separator(language) + correction
        }
    }

    private static func yes(_ l: MeetingLanguage) -> String { l.text(zh: "是", en: "Yes", ja: "はい") }
    private static func no(_ l: MeetingLanguage) -> String { l.text(zh: "不是", en: "No", ja: "いいえ") }
    private static func separator(_ l: MeetingLanguage) -> String { l.text(zh: "，", en: ", ", ja: "、") }
}
