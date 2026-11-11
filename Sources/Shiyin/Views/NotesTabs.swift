import SwiftUI

/// 阅读用的字段：靠左、宽度上限约 680 pt
struct ReadingColumn<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.textScale) private var scale
    @ViewBuilder var content: Content

    var body: some View {
        if snapshotMode {
            column
        } else {
            ScrollView { column }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 26) {
            content
        }
        .contentFont()   // 文字大小（design §38.5）：栏宽跟着放大，一行的字数不变
        .frame(maxWidth: 680 * scale, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NotesSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).contentTitleFont(18)
            content
        }
    }
}

/// 一条记录：内容加上时间点（R6.4：点时间点就跳到录音那里）。
/// `ref` 给每一条在会议记录里的位置（R41.1）：有对到待确认的题目时，时间点后面显示标记，点了在下面展开题目就地回答
struct ItemList: View {
    @Environment(AppModel.self) private var model
    let items: [MeetingNotes.Item]
    var detail: MeetingDetail? = nil
    var ref: (Int) -> NoteItemRef? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let ref = ref(index)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        (Text(item.text)).meetingText()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.time.isEmpty { TimeButton(time: item.time).font(.caption.monospacedDigit()) }
                        if let ref, let detail { ReviewMarker(ref: ref, count: detail.reviewCount(ref)) }
                    }
                    if let ref, let detail, model.reviewDraft?.expanded == ref {
                        InlineReviewCard(detail: detail, indexes: detail.reviewLinks[ref] ?? [])
                    }
                }
            }
        }
        .lineSpacing(3)
    }
}

/// 待确认的标记（R41.1，design §31.2）：这一条记录有几题整理时不确定的地方，琥珀色跟侧栏的「待确认 N 题」一样。
/// 点了在那一条下面展开题目（R41.2）；同时只展开一条，再点一次收合
struct ReviewMarker: View {
    @Environment(AppModel.self) private var model
    let ref: NoteItemRef
    let count: Int

    var body: some View {
        if count > 0 {
            Button {
                if let draft = model.reviewDraft {
                    draft.expanded = draft.expanded == ref ? nil : ref
                } else {
                    model.tab = .summary
                    model.reviewExpanded = true
                }
            } label: {
                Text(count > 1 ? "\(MeetingLanguage.ui(zh: "？", en: "?"))\(count)" : MeetingLanguage.ui(zh: "？", en: "?"))
                    .contentFont(.caption2, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(Color.signal)
                    .padding(.horizontal, count > 1 ? 5 : 0)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Color.signal.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(count > 1 ? String(localized: "整理时有 \(count) 题不确定的地方，点了就能回答") : String(localized: "整理时有一题不确定的地方，点了就能回答"))
            .accessibilityLabel(String(localized: "待确认 \(count) 题"))
        }
    }
}

/// 就地回答（R41.2，design §31.2）：展开在那一条记录下面，列出对应的题目；回答跟待确认标签页是同一份草稿，
/// 「送出」的规则也一样（送目前所有已回答和略过的题目）
struct InlineReviewCard: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let indexes: [Int]

    var body: some View {
        if let draft = model.reviewDraft, draft.meetingId == detail.meeting.id, let items = detail.notes?.reviewItems {
            let shown = Set(indexes.filter { items.indices.contains($0) })
            VStack(alignment: .leading, spacing: 12) {
                ForEach(shown.sorted(), id: \.self) { index in
                    ReviewQuestionRow(index: index, item: items[index], language: detail.meeting.meetingLanguage, draft: draft)
                }
                HStack(spacing: 12) {
                    Text("只送这一条的题目；有回答的交给整理工具依答案修正，略过的直接移除。")
                        .contentFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("收合") { draft.expanded = nil }
                    // 只送这一条对到的题目（R41.2），题数也只算这几题
                    Button(draft.submitTitle(only: shown)) { model.submitReviewDraft(only: shown) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.hasSomethingToSubmit(only: shown) || model.detailStatus?.isActive == true)
                }
            }
            .padding(14)
            .background(Color.signal.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 14)
        }
    }
}

/// 没有会议记录时的说明与动作
struct NotesPlaceholder: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let detail: MeetingDetail

    var body: some View {
        let status = model.detailStatus
        VStack(alignment: .leading, spacing: 12) {
            if status == .recording {
                Text("录音结束、转录完成后，会议记录会出现在这里。").foregroundStyle(.secondary)
            } else if status?.isActive == true {
                Text("转录和整理完成后，会议记录会出现在这里。").foregroundStyle(.secondary)
            } else if detail.segments.isEmpty && detail.meeting.userNotes.isEmpty {
                Text("还没有逐字稿。").foregroundStyle(.secondary)
            } else if AppSettings.needsProviderSetup {
                // 没选过整理工具、也没有 claude、codex（R35.2）：说还没设置，给打开设置的按钮（整理工具是第一个标签页）
                Text("还没设置整理工具。选好之后，就能把逐字稿整理成摘要、决议和待办；之后的会议转录完会自动整理。")
                    .foregroundStyle(.secondary)
                Button("设置整理工具") { openSettings() }
            } else if AppSettings.provider != .none, let problem = model.summarizerProblem {
                // 选了整理工具但还没准备好（没登录、没有 key…，R45.4）：说原因，给修的按钮
                // 不加 fixedSize：这里不在 ScrollView 里，量最小高度时整个窗口的内容会被往上推（CLAUDE.md）
                Text("整理工具还没设置好：\(problem.message)")
                    .foregroundStyle(.secondary)
                Button(problem.actionTitle) {
                    switch problem.action {
                    case .openSettings: openSettings()
                    case .login(let provider): CLILogin.openLogin(provider)
                    }
                }
            } else {
                Text(AppSettings.provider == .none
                     ? "整理工具目前设置为「不整理」。要产生会议记录，请到设置选择 Claude、Codex 或 API。"
                     : "这场会议还没整理成会议记录。")
                    .foregroundStyle(.secondary)
                Button("整理成会议记录") { model.resummarize() }
                    .disabled(AppSettings.provider == .none)
            }
        }
        .padding(32)
    }
}

/// 记录标签页（R44.1，design §33.1）：待确认的条、摘要、决议、待办、未决问题、议题、自订段落，一页卷到底（顺序同导出）。
/// 可以切换成编辑模式（R6.6），一份编辑器编全部；也可以切换成心智图（R67，design §42.4）
struct NotesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    @Environment(\.snapshotMode) private var snapshotMode
    @AppStorage(AppSettings.notesViewKey) private var notesView = "list"
    let detail: MeetingDetail
    @State private var editing: MeetingNotes?
    @State private var base: MeetingNotes?

    var body: some View {
        if let current = editing {
            NotesEditor(notes: Binding(draft: $editing, fallback: current)) { finish($0) }
                .onDisappear { finish(true, automatically: true) }   // 切到别的标签页、别场会议：自动存，不丢掉打的字
        } else if let notes = detail.notes, !notes.isEmpty, notesView == "mindMap" {
            mindMapPage(notes)
        } else if let notes = detail.notes, !notes.isEmpty {
            ReadingColumn {
                header(notes)
                if !notes.summary.isEmpty {
                    NotesSection(title: String(localized: "摘要")) { ItemList(items: notes.summary, detail: detail) { .summary($0) } }
                }
                if !notes.decisions.isEmpty {
                    NotesSection(title: String(localized: "决议")) { ItemList(items: notes.decisions, detail: detail) { .decisions($0) } }
                }
                if !notes.actionItems.isEmpty {
                    NotesSection(title: String(localized: "待办")) { ActionItemsTable(items: notes.actionItems, detail: detail) { .actionItems($0) } }
                }
                if !notes.openQuestions.isEmpty {
                    NotesSection(title: String(localized: "未决问题")) { ItemList(items: notes.openQuestions, detail: detail) { .openQuestions($0) } }
                }
                if !notes.topics.isEmpty {
                    NotesSection(title: String(localized: "议题")) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(Array(notes.topics.enumerated()), id: \.offset) { t, topic in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        TimeButton(time: topic.start)
                                        Text(topic.title).contentTitleFont(16)
                                    }
                                    ItemList(items: topic.points, detail: detail) { .topicPoint(t, $0) }
                                }
                            }
                        }
                    }
                }
                ForEach(Array(notes.custom.enumerated()), id: \.offset) { c, section in
                    if !section.items.isEmpty {
                        NotesSection(title: section.title) { ItemList(items: section.items, detail: detail) { .custom(c, $0) } }
                    }
                }
                if let by = detail.meeting.notesBy {
                    Text("由 \(LLMProvider(rawValue: by)?.shortLabel ?? by) 整理．\(templateName)")
                        .contentFont(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            NotesPlaceholder(detail: detail)
        }
    }

    /// 提示条和编辑列：条列、心智图共用
    @ViewBuilder private func header(_ notes: MeetingNotes) -> some View {
        // 加入、移除文档之后还没刷新（R61.8）：提示列不跟着文字大小（R59.2）
        if let id = detail.meeting.id, model.documentsChanged.contains(id) {
            DocumentsBanner().environment(\.textScale, 1)
        }
        if detail.reviewCount > 0 { ReviewBanner(detail: detail) }
        EditBar(viewMode: $notesView, disabled: model.detailStatus?.isActive == true,
                onUndo: detail.canUndoNotes ? { model.undoNotes() } : nil) {
            base = notes; editing = notes
        }
    }

    /// 心智图模式（design §42.4）：上面照旧是提示条、编辑列，下面是心智图；段落名称跟着界面语言（同条列）。
    /// 整页一起上下卷（同条列）：待确认展开时很高，放在滚动外面会把整个窗口的内容往上推（2026-11-05 用户看到整个窗口空白）
    private func mindMapPage(_ notes: MeetingNotes) -> some View {
        let layout = MindMap.layout(MindMap.tree(notes: notes, title: detail.meeting.displayTitle, labels: .init(.interface)))
        func page(width: Double) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 26) { header(notes) }
                    .contentFont()
                    .frame(maxWidth: 680 * scale, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MindMapView(layout: layout, language: detail.meeting.meetingLanguage, availableWidth: width,
                            onSeek: model.player.isLoaded ? { model.player.seek(to: $0) } : nil)
            }
        }
        return Group {
            if snapshotMode {
                page(width: 900)
            } else {
                GeometryReader { geo in
                    ScrollView(.vertical) { page(width: geo.size.width) }
                }
            }
        }
    }

    private func finish(_ save: Bool, automatically: Bool = false) {
        guard let draft = editing, let id = detail.meeting.id else { return }
        editing = nil
        if save { model.finishNotesEdit(draft, base: base, meetingId: id, automatically: automatically) }
    }

    private var templateName: String {
        String(localized: "模板：") + (model.templates.first { $0.id == detail.meeting.templateId }?.displayName ?? String(localized: "一般会议"))
    }
}

/// 记录顶部「还有 N 题待确认」（R44.2，design §33.1）：点了在原地展开待确认的内容（同一份 ReviewTab），回答跟就地回答共用草稿；
/// 展开状态只记这次选中期间（AppModel.reviewExpanded，换会议收起）
struct ReviewBanner: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.reviewExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.signal)
                    Text("还有 \(detail.reviewCount) 题待确认").contentFont(.callout, weight: .medium)
                    Spacer()
                    Text(model.reviewExpanded ? "收起" : "展开").contentFont(.callout).foregroundStyle(.secondary)
                    Image(systemName: model.reviewExpanded ? "chevron.up" : "chevron.down").contentFont(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "待确认 \(detail.reviewCount) 题"))
            if model.reviewExpanded {
                Divider()
                ReviewTab(detail: detail, embedded: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .background(Color.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 右上角的「编辑」按钮；有上一版时旁边多一颗「复原上一版」（R44.4，原本在「更多」）；左边是「条列｜心智图」（R67）
struct EditBar: View {
    /// list／mindMap；nil 不显示切换
    var viewMode: Binding<String>? = nil
    /// 转录或整理中不能编辑：工作完成时会整份写回，手动改的会被盖掉
    var disabled = false
    /// nil：没有上一版，不显示
    var onUndo: (() -> Void)? = nil
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let viewMode {
                Picker("显示方式", selection: viewMode) {
                    Text("条列").tag("list")
                    Text("心智图").tag("mindMap")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("把会议记录切换成条列或心智图")
            }
            Spacer()
            if let onUndo {
                Button("复原上一版", systemImage: "arrow.uturn.backward", action: onUndo)
                    .buttonStyle(.borderless)
                    .foregroundStyle(disabled ? Color.secondary : Color.celadon)
                    .disabled(disabled)
                    .help("换回上一版会议记录（再按一次换回更早的）")
            }
            Button("编辑", systemImage: "pencil", action: onEdit)
                .buttonStyle(.borderless)
                .foregroundStyle(disabled ? Color.secondary : Color.celadon)
                .disabled(disabled)
                .help(disabled ? "正在处理这场会议，完成后才能编辑" : "直接修改会议记录，存档时会留一个版本")
        }
        .font(.body)   // 按钮不跟着文字大小（R59.2）
        .padding(.bottom, -18)
    }
}

struct ActionItemsTable: View {
    @Environment(AppModel.self) private var model
    let items: [MeetingNotes.ActionItem]
    var detail: MeetingDetail? = nil
    var ref: (Int) -> NoteItemRef? = { _ in nil }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 9) {
            GridRow {
                Text("负责人")
                Text("事项")
                Text("期限")
            }
            .contentFont(.caption)
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let ref = ref(index)
                GridRow {
                    Text(item.owner.isEmpty ? String(localized: "未指定") : item.owner).meetingText()
                        .foregroundStyle(item.owner.isEmpty ? Color.signal : Color.primary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.task).meetingText()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.time.isEmpty { TimeButton(time: item.time).font(.caption.monospacedDigit()) }
                        if let ref, let detail { ReviewMarker(ref: ref, count: detail.reviewCount(ref)) }
                    }
                    .gridColumnAlignment(.leading)
                    Text(item.due.isEmpty ? "—" : item.due)
                        .monospacedDigit()
                        .foregroundStyle(item.due.isEmpty ? .secondary : .primary)
                }
                if let ref, let detail, model.reviewDraft?.expanded == ref {
                    GridRow {
                        InlineReviewCard(detail: detail, indexes: detail.reviewLinks[ref] ?? [])
                            .gridCellColumns(3)
                    }
                }
            }
        }
    }
}

extension Binding {
    /// 编辑中的草稿（可能是 nil）给编辑器用：草稿已经是 nil 时读到 fallback，写入不理会。
    /// 不能用 `Binding($editing)`：按「完成」「取消」把草稿设成 nil 时，同一次更新里编辑器的字段还会再读一次，
    /// 它会强制解开 nil 而闪退（3.2.0 的错误，3.2.1 修正）
    init(draft base: Binding<Value?>, fallback: Value) {
        self.init(get: { base.wrappedValue ?? fallback },
                  set: { if base.wrappedValue != nil { base.wrappedValue = $0 } })
    }
}

/// 手动编辑会议记录（R6.6）：每一条都是可以改的字段，可以添加、删除、上下移动；按「完成」才存成新版本
struct NotesEditor: View {
    @Environment(\.textScale) private var scale
    @Binding var notes: MeetingNotes
    let onFinish: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑会议记录").font(.headline)
                Spacer()
                Button("取消") { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("完成") { onFinish(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("标题", text: $notes.title).contentTitleFont(18)
                    EditorSection(title: String(localized: "摘要")) { ItemsEditor(items: $notes.summary) }
                    EditorSection(title: String(localized: "决议")) { ItemsEditor(items: $notes.decisions) }
                    EditorSection(title: String(localized: "待办")) { ActionItemsEditor(items: $notes.actionItems) }
                    EditorSection(title: String(localized: "未决问题")) { ItemsEditor(items: $notes.openQuestions) }
                    // 议题（原「详细」标签页的编辑器，R44.1 合并成一份）
                    EditorSection(title: String(localized: "议题")) {
                        ForEach(notes.topics.indices, id: \.self) { i in
                            let topic = $notes.topics.safe(i, fallback: .init(title: "", start: "", points: []))
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("时间", text: topic.start).frame(width: 70 * scale).monospacedDigit()
                                    TextField("议题", text: topic.title).contentTitleFont(16)
                                    Button { if notes.topics.indices.contains(i) { notes.topics.remove(at: i) } } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("删除这个议题")
                                }
                                ItemsEditor(items: topic.points)
                            }
                        }
                        Button("添加议题", systemImage: "plus") {
                            notes.topics.append(.init(title: "", start: "", points: []))
                        }
                        .buttonStyle(.borderless)
                        .contentFont(.callout)
                    }
                    ForEach(notes.custom.indices, id: \.self) { i in
                        let section = $notes.custom.safe(i, fallback: .init(title: "", items: []))
                        EditorSection(title: section.wrappedValue.title) { ItemsEditor(items: section.items) }
                    }
                    if !notes.reviewItems.isEmpty {
                        EditorSection(title: String(localized: "待确认")) {
                            ForEach(Array(notes.reviewItems.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.time).monospacedDigit().foregroundStyle(.secondary)
                                    Text(item.question).meetingText()
                                    Spacer()
                                    Button { if notes.reviewItems.indices.contains(index) { notes.reviewItems.remove(at: index) } } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("删除这一题")
                                }
                            }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .contentFont()   // 文字大小（design §38.5）
                .frame(maxWidth: 720 * scale, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).contentTitleFont(16)
            content
        }
    }
}

private struct ItemsEditor: View {
    @Environment(\.textScale) private var scale
    @Binding var items: [MeetingNotes.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let item = $items.safe(i, fallback: .init(text: ""))
                HStack(spacing: 6) {
                    TextField("内容", text: item.text, axis: .vertical).meetingText()
                    TextField("时间", text: item.time).frame(width: 64 * scale).monospacedDigit()
                    RowButtons(index: i, count: items.count, move: { $items.move(i, to: $0) }, delete: { $items.remove(i) })
                }
            }
            Button("添加一条", systemImage: "plus") { items.append(.init(text: "")) }
                .buttonStyle(.borderless)
                .contentFont(.callout)
        }
    }
}

private struct ActionItemsEditor: View {
    @Environment(\.textScale) private var scale
    @Binding var items: [MeetingNotes.ActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let item = $items.safe(i, fallback: .init(owner: "", task: "", due: ""))
                HStack(spacing: 6) {
                    TextField("负责人", text: item.owner).frame(width: 90 * scale)
                    TextField("事项", text: item.task, axis: .vertical).meetingText()
                    TextField("yyyy-MM-dd", text: item.due).frame(width: 100 * scale).monospacedDigit()
                    TextField("时间", text: item.time).frame(width: 64 * scale).monospacedDigit()
                    RowButtons(index: i, count: items.count, move: { $items.move(i, to: $0) }, delete: { $items.remove(i) })
                }
            }
            Button("添加待办", systemImage: "plus") { items.append(.init(owner: "", task: "", due: "")) }
                .buttonStyle(.borderless)
                .contentFont(.callout)
        }
    }
}

private struct RowButtons: View {
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { move(index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("往上移")
            Button { move(index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index >= count - 1).help("往下移")
            Button(action: delete) { Image(systemName: "trash") }.help("删除")
        }
        .buttonStyle(.borderless)
    }
}

/// 编辑清单用的数组元素绑定：删掉一条之后 SwiftUI 可能还会用旧的位置读写一次，越界时读到空值、不写入，不会闪退
extension Binding where Value: MutableCollection & RangeReplaceableCollection, Value.Index == Int {
    func safe(_ index: Int, fallback: Value.Element) -> Binding<Value.Element> {
        Binding<Value.Element>(
            get: { wrappedValue.indices.contains(index) ? wrappedValue[index] : fallback },
            set: { if wrappedValue.indices.contains(index) { wrappedValue[index] = $0 } })
    }

    func remove(_ index: Int) {
        if wrappedValue.indices.contains(index) { wrappedValue.remove(at: index) }
    }

    func move(_ index: Int, to target: Int) {
        if wrappedValue.indices.contains(index) && wrappedValue.indices.contains(target) { wrappedValue.swapAt(index, target) }
    }
}
