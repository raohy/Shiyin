import SwiftUI

/// 侧栏的一个人（design §60.2、R85.1）：头像、名字、一起开过几场和最近一场
struct PersonRow: View {
    let person: PersonOverview

    var body: some View {
        HStack(spacing: 10) {
            PersonAvatar(name: person.name, color: Color.person(person.name), size: 26, isMe: person.isMe, scales: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.isMe ? String(localized: "\(person.name)（我）") : person.name).lineLimit(1)
                Text(PersonPage.summaryLine(person)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 人物页（design §60.2、R85.2）：一起开过的会议、他负责的待办，在这里改名、合并、删除声音特征
struct PersonPage: View {
    @Environment(AppModel.self) private var model
    let person: PersonOverview
    @State private var meetings: [PersonMeeting] = []
    @State private var items: [PersonActionItem] = []
    @State private var renaming = false
    /// 名字旁的铅笔打开的改名（R85.6；同「更多 → 改名…」的输入框，接在铅笔下面）
    @State private var editingName = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    var body: some View {
        ReadingColumn {
            header
            NotesSection(title: String(localized: "负责的待办")) {
                if !items.isEmpty {
                    Button("加到提醒事项", systemImage: "checklist") { model.addPersonItemsToReminders(items) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(model.addingReminders)
                        .help("把这些待办加到「提醒事项」app 的「\(Reminders.listTitle)」列表，加过的不会重复加")
                }
            } content: {
                if items.isEmpty {
                    Text("会议记录里还没有这个人负责的待办。").foregroundStyle(.secondary)
                } else {
                    itemsGrid
                }
            }
            NotesSection(title: MeetingLanguage.ui(zh: "会议", en: "Meetings")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(meetings) { entry in
                        Button { model.openFromPersonPage(entry.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(entry.meeting.meetingDate).monospacedDigit().foregroundStyle(.secondary)
                                Text(entry.meeting.displayTitle).meetingText().lineLimit(1)
                                Spacer(minLength: 12)
                                Text(Self.spoke(entry.seconds)).font(.callout).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("打开这场会议")
                    }
                }
            }
        }
        .navigationTitle(person.name)
        // 改名、合并、删除放在工具列右上角的「更多」，跟会议页同一个位置
        .toolbar { ToolbarItem(placement: .primaryAction) { moreMenu } }
        .task(id: person) { load() }
    }

    /// 头像、名字、摘要；改名、合并、删除收在右边的「更多」（同会议页的「更多」，破坏性的动作不跟其他并排）
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            PersonAvatar(name: person.name, color: Color.person(person.name), size: 52, isMe: person.isMe, scales: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(person.name).contentTitleFont(26).textSelection(.enabled).lineLimit(1)
                    Button { renameText = person.name; editingName = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.celadon)
                        .help("改名")
                        .accessibilityLabel(Text("改名"))
                        .popover(isPresented: $editingName, arrowEdge: .bottom) { renameForm }
                    if person.isMe {
                        Text("我").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(Self.summaryLine(person, long: true)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
        .confirmationDialog("删除「\(person.name)」的声音特征？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                model.deletePerson(person.id)
                model.selectedPerson = nil
            }
        } message: {
            Text("已经带入的名字会留着，之后的会议不会再自动带入。")
        }
    }

    private var moreMenu: some View {
        let others = model.peopleOverview.filter { $0.id != person.id }
        return Menu {
            Button("改名…") { renameText = person.name; renaming = true }
            if !others.isEmpty {
                Menu("合并到") {
                    ForEach(others) { other in
                        Button(other.name) {
                            model.renamePerson(person.id, to: other.name)
                            model.selectedPerson = other.id
                        }
                    }
                }
            }
            Divider()
            Button("删除声音特征…", role: .destructive) { confirmDelete = true }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel(Text("更多"))
        .help("改名、跟另一个名字合并（同一个人被记成两个名字时）、删除声音特征")
        .popover(isPresented: $renaming, arrowEdge: .bottom) { renameForm }
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("名字", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit(saveRename)
            HStack {
                Spacer()
                Button("取消") { renaming = false; editingName = false }.keyboardShortcut(.cancelAction)
                Button("保存", action: saveRename).keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func saveRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.renamePerson(person.id, to: name)
        renaming = false
        editingName = false
        // 改成已经有的名字时合并过去，选那个人
        model.selectedPerson = model.peopleOverview.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// 他负责的待办：事项、期限、哪一场会议和时间点（点了打开那场、从那里播放）
    private var itemsGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 9) {
            GridRow {
                Text("事项")
                Text("期限")
                Text("会议")
            }
            .contentFont(.caption)
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(items) { entry in
                GridRow {
                    Text(entry.item.task).meetingText().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.item.due.isEmpty ? "—" : entry.item.due).monospacedDigit()
                        .foregroundStyle(entry.item.due.isEmpty ? .secondary : .primary)
                    Button {
                        model.openFromPersonPage(entry.meeting.id ?? 0, seconds: TimeFormat.seconds(entry.item.time))
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.meeting.displayTitle).lineLimit(1)
                            if !entry.item.time.isEmpty { Text(entry.item.time).monospacedDigit().foregroundStyle(Color.celadon) }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .help("打开这场会议，从这里开始播放")
                }
            }
        }
    }

    private func load() {
        meetings = (try? model.db.personMeetings(person.id)) ?? []
        items = (try? model.db.personActionItems(person.name)) ?? []
    }

    /// 「N 場會議・最近 <日期>」；人物頁上方用長的寫法
    static func summaryLine(_ person: PersonOverview, long: Bool = false) -> String {
        guard let date = person.lastMeetingDate else {
            return person.isMe ? String(localized: "录过你的声音，还没有一起开过会议") : String(localized: "还没有一起开过会议")
        }
        return long ? String(localized: "一起开过 \(person.meetingCount) 场会议，最近 \(date)")
            : String(localized: "\(person.meetingCount) 場會議・最近 \(date)")
    }

    static func spoke(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? String(localized: "说了不到 1 分钟") : String(localized: "说了 \(minutes) 分钟")
    }
}

/// 人物模式、还没选人时的右边（design §60.2）
struct PeopleEmptyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2").font(.largeTitle).foregroundStyle(.tertiary)
            Text(model.peopleOverview.isEmpty
                 ? String(localized: "还没有认识的人")
                 : String(localized: "选一个人，看一起开过的会议和负责的待办"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
