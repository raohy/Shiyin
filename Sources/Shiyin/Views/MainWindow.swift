import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var model = model
        MainView()
            .tint(.celadon)
            .onAppear {
                let open = openWindow
                model.openMainWindow = {
                    open(id: "main")
                    NSApp.activate()
                }
                model.openWindowById = { open(id: $0) }
                // 第一次使用：打开引导（R10.2）
                if !hasCompletedOnboarding { openWindow(id: "onboarding") }
            }
            .fileImporter(isPresented: $model.showFileImporter,
                          allowedContentTypes: Importer.contentTypes + Importer.otherTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.requestImport(urls) }
            }
            .sheet(isPresented: $model.showImportSheet) { ImportSheet(urls: model.pendingImport) }
            .sheet(isPresented: $model.showExportSheet) { ExportSheet() }
            .sheet(isPresented: $model.showRediarizeSheet) { RediarizeSheet() }
            .sheet(isPresented: $model.showPreparationSheet) { MeetingPreparationEditor(meetingId: model.preparationMeetingId) }
            .alert("出了一点问题", isPresented: Binding(get: { model.errorMessage != nil },
                                                   set: { if !$0 { model.errorMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("拾音没有麦克风权限", isPresented: Binding(get: { model.recorder.permissionDenied },
                                                       set: { model.recorder.permissionDenied = $0 })) {
                Button("打开系统设置") { Recorder.openPrivacySettings() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请到「系统设置 → 隐私与安全性 → 麦克风」打开「拾音」，再重新开始录音。")
            }
            .alert("录音的提醒", isPresented: Binding(get: { model.recorder.failureMessage != nil },
                                                 set: { if !$0 { model.recorder.failureMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(model.recorder.failureMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    UpdateProgressToast()
                    NoticeToast()
                }
                .padding(.bottom, 72)
            }
    }
}

/// 短暂的提示消息
struct NoticeToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.noticeMessage {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(3))
                    if model.noticeMessage == message { model.noticeMessage = nil }
                }
        }
    }
}

/// 更新下载中、准备安装时一直显示（design §12，4.7.1）：网络慢的时候看得出来还在下载
struct UpdateProgressToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.updater.state {
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text(model.updater.progress?.text ?? model.updater.state.label).monospacedDigit()
                    Text("下载好会自动重新打开").foregroundStyle(.secondary)
                }
                if let fraction = model.updater.progress?.fraction { ProgressView(value: fraction).tint(.signal) } else { ProgressView().progressViewStyle(.linear) }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.updater.state.label)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        default:
            EmptyView()
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasSeenGuide") private var hasSeenGuide = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            if model.sidebarMode == .people && !model.showTrash && model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                // 人物页（design §60.2）
                if let person = model.peopleOverview.first(where: { $0.id == model.selectedPerson }) {
                    PersonPage(person: person).id(person.id)
                } else {
                    PeopleEmptyView()
                }
            } else if model.multiSelected.count > 1 {
                MultiSelectionView(ids: model.multiSelected)
            } else if let detail = model.detail {
                MeetingDetailView(detail: detail)
                    .id(detail.meeting.id)
            } else {
                EmptyDetailView()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.requestImport(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.celadon, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            // 完成引导后才自动打开使用说明（只一次）
            if !hasSeenGuide && UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                hasSeenGuide = true
                openWindow(id: "guide")
            }
        }
        // 重命名、新文件夹的弹窗（R102、design §76）
        .sheet(item: Binding(get: { model.renameTarget }, set: { model.renameTarget = $0 })) { RenameSheet(target: $0) }
        // 文件夹的自动加入条件（design §72）
        .sheet(item: Binding(get: { model.editingFolderRule.map(EditingFolder.init) }, set: { model.editingFolderRule = $0?.name })) {
            FolderRuleSheet(folder: $0.name)
        }
        // 有新版时询问（R10.6）
        .alert(String(localized: "拾音 \(model.updater.prompt?.version ?? "") 可以更新了"), isPresented: Binding(
            get: { model.updater.prompt != nil }, set: { if !$0 { model.updater.prompt = nil } })) {
            Button("稍后", role: .cancel) { model.updater.prompt = nil }
            Button("下载并更新") {
                if let manifest = model.updater.prompt {
                    model.updater.prompt = nil
                    model.noticeMessage = String(localized: "正在下载更新，完成后拾音会自动重新打开")
                    Task { await model.updater.install(manifest, model: model) }
                }
            }
        } message: {
            // 更新内容只列前几项（R10.6、design §12）：tag 的说明中英各一段、每段好几条，整段放进对话框太长
            Text([ReleaseNotes.text(model.updater.prompt?.notes, english: MeetingLanguage.interface == .en),
                  String(localized: "目前是 \(Updater.currentVersion)。更新时拾音会结束并重新打开，会议资料都会保留。")]
                .filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        // 删除、移除、分成两场的确认（R106、design §80）：同一种弹窗，取代系统的确认对话框
        .sheet(item: Binding(get: { model.activeConfirmation }, set: { if $0 == nil { model.clearConfirmations() } })) { ConfirmSheet(request: $0) }
    }
}

/// 选了两场以上的会议（R88、design §62）：能一起做的事
struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let ids: [Int64]

    var body: some View {
        ContentUnavailableView {
            Label("已选中 \(ids.count) 场会议", systemImage: "square.stack")
        } description: {
            Text("按住 ⌘ 点击可以加入或取消，按住 ⇧ 点击一次选一段。")
        } actions: {
            HStack {
                if model.showTrash {
                    Button("还原") { model.restore(ids) }
                    Button("永久删除…", role: .destructive) { model.confirmPurge = ids }
                } else {
                    FolderMenu(meetingIds: ids, current: model.commonFolder(ids))
                        .fixedSize()
                    Button("移到垃圾桶…", role: .destructive) {
                        model.deleteTargets = ids
                        model.confirmDelete = true
                    }
                }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trashTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            let searching = !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
            if searching {
                SearchResultsList()
            } else if model.sidebarMode == .people && !model.showTrash {
                peopleList
            } else {
                meetingList
            }
            Divider()
            if model.importingCount > 0 {
                // 大文件在背景导入（design §21.13、R20.4）
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在导入 \(model.importingCount) 个文件…").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            HStack {
                Button {
                    model.showTrash.toggle()
                    model.selection = nil
                } label: {
                    Label(model.showTrash ? "回到所有会议" : "垃圾桶（\(model.trash.count)）",
                          systemImage: model.showTrash ? "chevron.backward" : "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(trashTargeted ? Color.celadon : .secondary)
                // 会议拖到这里＝移到垃圾桶（R103.1，可以还原）
                .meetingDrop(enabled: !model.showTrash, targeted: $trashTargeted) { model.moveToTrash($0) }
                Spacer()
                // 导入放这里：侧边栏的工具列放不下，会被收进「>>」（design §22.2、R21.5）；垃圾桶里换成清空（R88.3）
                if model.showTrash {
                    Button { model.confirmEmptyTrash = true } label: {
                        Label("清空垃圾桶…", systemImage: "trash.slash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(model.trash.isEmpty)
                } else {
                    Button { model.showFileImporter = true } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("导入录音、视频、逐字稿或 .shiyin 封包（⌘O）")
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "搜索所有会议")
        .onAppear { model.reloadPeopleOverview() }
        .toolbar {
            ToolbarItemGroup {
                RecordingControls()
                // 问所有会议（design §21.8）；录音中放不下，会被收进「>>」（design §22.2）
                if !model.recorder.isRecording {
                    Button { model.openPreparation() } label: {
                        Label("准备会议", systemImage: "square.and.pencil")
                    }
                    Button { model.openWindowById?("ask") } label: {
                        Label("提问", systemImage: "questionmark.bubble")
                    }
                    .help("问所有会议，回答附上是哪一场会议、哪个时间点")
                }
            }
        }
    }

    /// 侧栏最上面的两组（design §60.2、R85.1）：所有会议、人物，再来是文件夹。跟文件夹同一种列，
    /// 点了换下面那一段的内容（macOS 的侧栏是导览清单，不放分段控制）
    @ViewBuilder
    private var scopeSections: some View {
        let people = model.sidebarMode == .people
        Section {
            // 所有会议是回到默认的画面，不画选到的样子；人物模式时人物亮
            FolderRow(name: String(localized: "所有会议"), count: model.meetings.count, symbol: "tray.full", selected: false) {
                model.sidebarMode = .meetings
                model.folderFilter = nil
            }
            FolderRow(name: String(localized: "人物"), count: model.peopleOverview.count, symbol: "person.2", selected: people) {
                model.sidebarMode = .people
                model.reloadPeopleOverview()
            }
        }
        // 段落可以收起；每个文件夹可以在原地展开最近的会议（R101、design §75）。一直显示，标题右边「+」建空的文件夹（R104、design §78）
        Section {
            if model.isSectionExpanded("folders") {
                SidebarFolderRows()
                if model.folders.isEmpty {
                    Text("按 + 添加文件夹").font(.callout).foregroundStyle(.secondary).selectionDisabled()
                }
            }
        } header: {
            HStack(spacing: 6) {
                // 段落标题跟「+」在辅助功能里并成一个组件，按下去要是「+」，收合改成有名字的动作（同会议列表的标题）
                SidebarSectionHeader(title: String(localized: "文件夹"), key: "folders", besideMenu: true)
                Spacer(minLength: 4)
                // 不用 Button：List 里的 SwiftUI 按钮会让整个表格的点击卡住（见 sidebarClick）
                SidebarHeaderIcon(systemName: "plus")
                    .sidebarClick { model.renameTarget = .newFolder([]) }
                    .padding(.trailing, SidebarHeaderIcon.trailing)
                    .help("新文件夹")
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("新文件夹"))
                    .accessibilityAction { model.renameTarget = .newFolder([]) }
            }
        }
    }

    /// 一场会议的列：右边的「⋯」跟右键同一份（R100）；选到的是多选里的一场时，菜单对整个多选
    private func meetingRow(_ row: MeetingRow) -> some View {
        let selected = model.listSelection.contains(row.id)
        return MeetingRowView(row: row, status: model.status(row))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // 拖到文件夹、其他会议的标题、垃圾桶（R103.1）；在多选里时拖整个多选。点一下选中（⌘、⇧ 多选）也在这里，
            // 不经过 List 自己的点击、拖动（design §77）。垃圾桶里的不能拖。把手只盖内容，不盖右边的「⋯」
            .sidebarDragHandle(type: model.showTrash ? nil : .shiyinMeetingIDs, label: row.meeting.displayTitle,
                               data: { Data(model.dragIDs(for: row.id).map(String.init).joined(separator: ",").utf8) }) {
                model.clickMeetingRow(row.id, modifiers: $0)
            }
            // 「⋯」和右键：自己画的菜单（R105）；选到的是多选里的一场时，菜单对整个多选
            .floatingRowMenu(selected: selected) { model.meetingMenu(model.dragIDs(for: row.id)) }
            .sidebarSelectableRow(selected: selected)
            .tag(row.id)
    }

    /// 人物模式：上面同样是所有会议、人物、文件夹，下面是认识的人（design §60.2）
    private var peopleList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedPerson) {
            scopeSections
            Section {
                if model.isSectionExpanded("people") {
                    ForEach(model.peopleOverview) { person in
                        PersonRow(person: person)
                            .floatingRowMenu(selected: model.selectedPerson == person.id) { model.personMenu(person) }
                            .sidebarSelectableRow(selected: model.selectedPerson == person.id)
                            .tag(person.id)
                    }
                    if model.peopleOverview.isEmpty {
                        Text("在逐字稿点「说话者 1」改成名字，或到设置录一段你自己的声音，拾音就会记住这个人。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .selectionDisabled()
                    }
                }
            } header: {
                SidebarSectionHeader(title: String(localized: "人物"), key: "people")
            }
        }
        // 选到一个人时按 Return 重命名、Delete 移除（R85.7、R100）
        .onKeyPress(.return) { model.sidebarReturn() ? .handled : .ignored }
        .onDeleteCommand { model.sidebarDelete() }
    }

    private var meetingList: some View {
        @Bindable var model = model
        // 多选（R88、design §62）：⌘、⇧ 点击；右键在选中的列上是全部
        return List(selection: $model.listSelection) {
            if model.showTrash {
                Text("垃圾桶里的会议 30 天后会永久删除").font(.caption).foregroundStyle(.secondary)
            } else {
                scopeSections
            }
            if model.showTrash {
                Section {
                    ForEach(model.filteredMeetings) { row in meetingRow(row) }
                }
            } else {
                // 排序、分组、筛选（R97、design §71）：标题那一列有「显示方式」，分组时每组一段
                // 会议列表、分组的每一组都可以收起（R101、design §75）
                let groups = model.meetingGroups
                let grouped = model.effectiveGrouping != .none
                let expanded = model.isSectionExpanded("meetings")
                Section {
                    if expanded {
                        if model.meetingFilter.isActive { MeetingFilterBar() }
                        if model.meetingFilter.isActive && model.filteredMeetings.isEmpty { MeetingFilterEmpty() }
                        if model.listShowsOthersOnly && model.filteredMeetings.isEmpty {
                            Text("不在文件夹里的会议会列在这里").font(.callout).foregroundStyle(.secondary).selectionDisabled()
                        }
                        if !grouped, let rows = groups.first?.rows {
                            ForEach(rows) { row in meetingRow(row) }
                        }
                    }
                } header: {
                    MeetingListHeader()
                }
                if grouped && expanded {
                    ForEach(groups) { group in
                        let key = AppModel.groupKey(group)
                        Section {
                            if model.isSectionExpanded(key) {
                                ForEach(group.rows) { row in meetingRow(row) }
                            }
                        } header: {
                            SidebarSectionHeader(title: group.title, key: key)
                        }
                    }
                }
            }
        }
        // 键盘（R100）：Return 重命名、Delete 移到垃圾桶（垃圾桶里是永久删除），都照现在选到的
        .onKeyPress(.return) { model.sidebarReturn() ? .handled : .ignored }
        .onDeleteCommand { model.sidebarDelete() }
        .overlay {
            if model.filteredMeetings.isEmpty && model.showTrash {
                Text("垃圾桶是空的").foregroundStyle(.secondary)
            }
        }
    }
}

/// 侧栏的文件夹列（R9.2）：所有会议、人物点了换下面的列表；文件夹点了在原地展开（R101）。有菜单时（文件夹，R100）滑过或选到时
/// 数量的位置换成「⋯」。整列用点击手势，不用 Button：List 里的按钮会把右键当成点击，右键菜单出不来
/// （2026-11-16 自己验收时发现）
struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let count: Int
    let symbol: String
    let selected: Bool
    /// 文件夹（R101）：点了在原地展开、收起，图标换成打开或关着的文件夹（nil 是所有会议、人物这种一般的列）
    var folder: FolderState? = nil
    /// 拖动排序用的键（R103.2）；nil 不能拖
    var dragKey: String? = nil
    /// 收拖过来的会议、文件夹（排序）、文件（R103）
    var drop: SidebarRowDrop? = nil
    var menu: (() -> [MenuEntry])? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var dropState: SidebarDropState?
    @State private var height: CGFloat = 28

    /// 辅助功能的值：展开了没、几场（右边不显示场数）
    private var accessibilityState: String {
        let meetings = String(localized: "\(count) 场")
        guard let folder else { return meetings }
        return String(localized: "\(folder.expanded ? String(localized: "已展开") : String(localized: "已收起"))、\(meetings)")
    }

    struct FolderState {
        var expanded: Bool
        /// 右上角的标记：齿轮（有自动加入条件）
        var badge: String?
    }

    var body: some View {
        let showMenu = menu != nil && (hovering || selected)
        let state = dropState
        let into = state == .into
        HStack {
            HStack {
                Label {
                    Text(name)
                } icon: {
                    // 拖东西进来时也是打开的文件夹
                    if let folder { FolderGlyph(open: folder.expanded || into, badge: folder.badge) } else { Image(systemName: symbol) }
                }
                // 图标跟字同色（不用侧栏默认的主色）；选到时一块灰底，拖东西进来时青瓷绿
                .labelStyle(SidebarLabelStyle())
                .foregroundStyle(into ? Color.celadon : .primary)
                // 辅助功能照旧是一颗按钮（「⋯」另外一颗）；文件夹的值是展开了没，可以往上、往下移（R103.2）
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                // 右边不显示场数，辅助功能照样念得到
                .accessibilityValue(Text(accessibilityState))
                .accessibilityAction(.default, action)
                .accessibilityActions {
                    if let dragKey {
                        Button("往上移") { model.moveSidebarItem(dragKey, by: -1) }
                        Button("往下移") { model.moveSidebarItem(dragKey, by: 1) }
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            // 可以拖的列（文件夹）盖拖动把手：拖了排序，没拖就是点一下（R103.2、design §77）；其他列（所有会议、人物）
            // 盖只接点一下的 view，不用 onTapGesture（会让整个表格的点击卡住，见 sidebarClick）
            .modifier(FolderRowHandle(name: name, dragKey: dragKey, action: action))
            // 右边不放场数，滑过或选到时「⋯」
            if let menu {
                FloatingMenuButton(entries: menu)
                    .opacity(showMenu ? 1 : 0)
                    .allowsHitTesting(showMenu)
            }
        }
        .contentShape(Rectangle())
        .modifier(FolderRowContextMenu(menu: menu))
        .onHover { hovering = $0 }
        .sidebarHover(selected: selected)
        // 拖进来：整列一块青瓷绿的底；排序：上缘或下缘一条线（design §77）
        .background {
            RoundedRectangle(cornerRadius: SidebarHoverModifier.radius, style: .continuous)
                .fill(Color.celadon.opacity(into ? 0.18 : 0))
                .padding(.horizontal, -SidebarHoverModifier.inset.width)
                .padding(.vertical, -SidebarHoverModifier.inset.height)
        }
        .overlay(alignment: state == .after ? .bottom : .top) {
            if state == .before || state == .after {
                Capsule().fill(Color.celadon).frame(height: 2)
                    .padding(.horizontal, -SidebarHoverModifier.inset.width)
                    .offset(y: (state == .before ? -1 : 1) * (SidebarHoverModifier.inset.height + 1))
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .modifier(FolderRowDragModifier(drop: drop, height: height, state: $dropState))
    }
}

/// 有菜单的列：右键打开自己画的菜单（R105）
private struct FolderRowContextMenu: ViewModifier {
    let menu: (() -> [MenuEntry])?

    func body(content: Content) -> some View {
        if let menu { content.floatingContextMenu(menu) } else { content }
    }
}

/// 有键的列盖拖动把手
private struct FolderRowHandle: ViewModifier {
    let name: String
    let dragKey: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let dragKey {
            content.sidebarDragHandle(type: .shiyinSidebarItem, label: name, data: { Data(dragKey.utf8) }, onClick: action)
        } else {
            content.sidebarClick(action)
        }
    }
}

/// 有 drop 的列收拖过来的会议、文件夹（排序）、文件
private struct FolderRowDragModifier: ViewModifier {
    let drop: SidebarRowDrop?
    let height: CGFloat
    @Binding var state: SidebarDropState?

    func body(content: Content) -> some View {
        if let drop {
            let types = [drop.meetings != nil ? UTType.shiyinMeetingIDs : nil, drop.item != nil ? .shiyinSidebarItem : nil,
                         drop.files != nil ? .fileURL : nil].compactMap { $0 }
            content.onDrop(of: types, delegate: SidebarRowDropDelegate(drop: drop, height: height, state: $state))
        } else {
            content
        }
    }
}

/// 「移到文件夹」菜单：既有的文件夹、新文件夹、移出文件夹（R9.2）
struct FolderMenu: View {
    @Environment(AppModel.self) private var model
    /// nil：目前选中的会议。工具列的菜单可能沿用之前建立的，按下时才决定是哪一场，不然会移到上一场会议
    var meetingIds: [Int64]? = nil
    /// 这几场现在在的文件夹（空字符串是不在文件夹里）；多选而且在不同文件夹时是 nil
    var current: String? = nil

    private var targets: [Int64] { meetingIds ?? [model.selection].compactMap { $0 } }

    var body: some View {
        Menu("移到文件夹", systemImage: "folder") {
            if meetingIds == nil || current == nil {
                // 工具列的菜单内容不会更新，列出全部文件夹和固定的「移出文件夹」，选到原本的文件夹时 AppModel 会说明；
                // 多选而且在不同文件夹时也是这样
                ForEach(model.folders, id: \.name) { item in
                    Button(item.name) { model.moveToFolder(targets, folder: item.name) }
                }
                if !model.folders.isEmpty { Divider() }
                Button("新文件夹…", systemImage: "folder.badge.plus") { if !targets.isEmpty { model.renameTarget = .newFolder(targets) } }
                Button("移出文件夹", systemImage: "minus.circle") { model.moveToFolder(targets, folder: "") }
            } else if let folder = current {
                ForEach(model.folders.filter { $0.name != folder }, id: \.name) { item in
                    Button(item.name) { model.moveToFolder(targets, folder: item.name) }
                }
                if !model.folders.filter({ $0.name != folder }).isEmpty { Divider() }
                Button("新文件夹…", systemImage: "folder.badge.plus") { if !targets.isEmpty { model.renameTarget = .newFolder(targets) } }
                if !folder.isEmpty {
                    Button("移出「\(folder)」", systemImage: "minus.circle") { model.moveToFolder(targets, folder: "") }
                }
            }
        }
    }
}

/// 全文搜索结果（R9.1）：依会议分组，显示摘录
struct SearchResultsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.searchResults, by: \.meetingId)
        let order = model.searchResults.map(\.meetingId).reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }
        List {
            if model.searchResults.isEmpty {
                Text("找不到「\(model.searchQuery)」").foregroundStyle(.secondary)
            }
            ForEach(order, id: \.self) { meetingId in
                Section(model.meetings.first { $0.id == meetingId }?.meeting.displayTitle ?? String(localized: "会议")) {
                    ForEach(groups[meetingId] ?? []) { hit in
                        Button { model.openSearchHit(hit) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kindLabel(hit.kind)).font(.caption2).foregroundStyle(.secondary)
                                Text(hit.snippet).font(.callout).lineLimit(3)
                                    .contentGlyphs(model.meetings.first { $0.id == meetingId }?.meeting.meetingLanguage ?? .zh)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func kindLabel(_ kind: SearchHit.Kind) -> String {
        switch kind {
        case .title: return String(localized: "标题")
        case .segment: return String(localized: "逐字稿")
        case .notes: return String(localized: "会议记录")
        case .userNotes: return String(localized: "我的笔记")
        }
    }
}

struct MeetingRowView: View {
    let row: MeetingRow
    let status: MeetingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.meeting.displayTitle).lineLimit(1).contentGlyphs(row.meeting.meetingLanguage)
            HStack(spacing: 8) {
                Text(shortDate).monospacedDigit().foregroundStyle(.secondary)
                Text(status.label).foregroundStyle(color)
            }
            .font(.caption)
            if case .transcribing(let p?, _) = status {
                ProgressView(value: p).controlSize(.mini).tint(.signal)
            }
        }
        .padding(.vertical, 3)
    }

    private var shortDate: String {
        let parts = row.meeting.meetingDate.split(separator: "-")
        guard parts.count == 3 else { return row.meeting.meetingDate }
        let thisYear = String(Calendar.current.component(.year, from: Date()))
        return parts[0] == thisYear ? "\(parts[1])/\(parts[2])" : "\(parts[0])/\(parts[1])/\(parts[2])"
    }

    private var color: Color {
        switch status {
        case .recording, .failed: return .red
        case .queued, .transcribing, .summarizing, .review: return .signal
        default: return .secondary
        }
    }
}

/// 工具列的录音按钮（R1）：可以选录音来源
struct RecordingControls: View {
    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "both": return String(localized: "麦克风＋电脑声音（在线会议）")
        case "system": return String(localized: "只录电脑声音")
        default: return String(localized: "只录麦克风")
        }
    }

    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.recordSourceKey) private var source = "mic"
    @AppStorage(AppSettings.defaultMeetingLanguageKey) private var language: MeetingLanguage = .systemDefault
    @AppStorage(AppSettings.inputDeviceKey) private var device = ""

    var body: some View {
        if model.recorder.isRecording {
            // 侧边栏上方的空间很窄，只放「● 经过时间」和停止，避免整组被收进工具列的「>>」
            HStack(spacing: 4) {
                Button {
                    if let id = model.recorder.meetingId { model.reveal(id) }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.recorder.isPaused ? Color.secondary : .red).frame(width: 8, height: 8)
                        RecorderClock(recorder: model.recorder)
                    }
                }
                .help(model.recorder.isPaused ? "已暂停，点一下打开录音中的会议" : "录音中，点一下打开这场会议")
                .accessibilityLabel(model.recorder.isPaused ? "已暂停" : "录音中")
                Button { model.recorder.stop() } label: { Label("停止", systemImage: "stop.fill") }
                    .help("停止录音并开始转录（⌘R）")
            }
        } else {
            // 这两个选项是之后录音的设置，选完画面不会变，跳一个提示让人知道选到了。
            // 按钮和箭头分成两个控制项（A11Y1）：分割菜单（Menu 的 primaryAction）箭头那一半在辅助功能里没有名字，VoiceOver 读不出来
            ControlGroup {
                Button { model.startRecording() } label: {
                    Label(MeetingLanguage.ui(zh: "录音", en: "Record"), systemImage: "record.circle")
                }
                .help("开始录音（⌘R），用\(language.uiName)识别；点右边的箭头可以改录音来源和语言")
                Menu {
                    Picker("录音来源", selection: Binding(get: { source }, set: { value in
                        source = value
                        model.noticeMessage = String(localized: "之后的录音：\(Self.sourceLabel(value))")
                    })) {
                        ForEach(["mic", "both", "system"], id: \.self) { Text(Self.sourceLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    // 麦克风（R58.1、design §38.2）：跟设置页同一个设置
                    if source != "system" {
                        Picker("麦克风", selection: Binding(get: { device }, set: { model.switchMicrophone($0) })) {
                            MicrophoneOptions(saved: device)
                        }
                        .pickerStyle(.inline)
                    }
                    Picker("会议语言", selection: Binding(get: { language }, set: { value in
                        language = value
                        model.noticeMessage = String(localized: "之后的录音都用\(value.uiName)")
                    })) {
                        ForEach(MeetingLanguage.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("录音选项", systemImage: "chevron.down")
                }
                .menuIndicator(.hidden)
                .help("录音来源、麦克风、会议语言")
                .accessibilityLabel(Text("录音选项"))
            }
            .controlGroupStyle(.navigation)
            // 工具列的菜单建立一次就不会更新勾选，选项变了（含接上、拔掉麦克风）就换一个新的菜单
            .id("\(source)-\(language.rawValue)-\(device)-\(MicrophoneMonitor.shared.signature)")
        }
    }
}

/// 麦克风的选项（R58、design §38.2）：系统默认（写出现在是哪一支）、每一支麦克风；存的那支没接上时也列出来，勾选才看得到。
/// tag 是 UID，系统默认是空字符串
struct MicrophoneOptions: View {
    let saved: String

    var body: some View {
        let monitor = MicrophoneMonitor.shared
        if let name = monitor.defaultInput?.name {
            Text("系统默认（\(name)）").tag("")
        } else {
            Text("系统默认").tag("")
        }
        ForEach(monitor.inputs) { Text($0.name).tag($0.uid) }
        if !saved.isEmpty && !monitor.inputs.contains(where: { $0.uid == saved }) {
            Text("之前选的麦克风（没有接上，会用系统默认）").tag(saved)
        }
    }
}

struct EmptyDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.showTrash {
            ContentUnavailableView("垃圾桶", systemImage: "trash", description: Text("选一场会议来还原或永久删除。"))
        } else if model.meetings.isEmpty {
            ContentUnavailableView {
                Label("还没有会议", systemImage: "waveform")
            } description: {
                Text("按「录音」开始，或把录音档拖进来。")
            } actions: {
                HStack {
                    Button("开始录音") { model.startRecording() }
                        .buttonStyle(.borderedProminent)
                    Button("准备会议") { model.openPreparation() }
                    Button("导入录音…") { model.showFileImporter = true }
                    Button("看使用说明") { openWindow(id: "guide") }
                }
            }
        } else {
            ContentUnavailableView("从左边选一场会议", systemImage: "waveform",
                                   description: Text("也可以把新的录音档拖进来。"))
        }
    }
}

/// 从窗口导入时的对话框
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    @State private var title = ""
    @State private var date = Date()
    @State private var participants = ""
    @State private var templateId = AppSettings.defaultTemplate
    @State private var language = AppSettings.defaultMeetingLanguage
    @State private var speakerCount = 0

    var body: some View {
        // 同其他弹窗的样子（R106、design §80）
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: urls.count == 1 ? String(localized: "导入录音") : String(localized: "导入 \(urls.count) 个录音档"),
                        onClose: { model.pendingImport = []; dismiss() })
            VStack(alignment: .leading, spacing: 4) {
                ForEach(urls, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "waveform").lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(.secondary)
            if urls.count == 1 {
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "标题"))
                    SheetTextField(placeholder: String(localized: "选填，没填就由整理时命名"), text: $title)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "会议日期"))
                    if urls.count == 1 {
                        SheetDateField(label: String(localized: "会议日期"), date: $date)
                    } else {
                        Text("依各文件的文件名或修改日期").font(.system(size: 15)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sheetFieldBox()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "大约几个人"))
                    // 先填人数（design §26.2）
                    SheetMenuField(options: [(0, String(localized: "自动判断"))] + (2...12).map { ($0, String(localized: "\($0) 人")) },
                                   selection: $speakerCount)
                        .help("人多、吵杂或手机放在桌上录音时，先告诉拾音大约几个人，说话者会分得比较准")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SheetFieldLabel(String(localized: "与会者"))
                SheetTextField(placeholder: String(localized: "选填，用逗号分隔"), text: $participants)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "模板"))
                    SheetMenuField(options: model.templates.map { ($0.id, $0.displayName) }, selection: $templateId)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "会议语言"))
                    SheetMenuField(options: MeetingLanguage.allCases.map { ($0, $0.name) }, selection: $language)
                        .help("决定转录和会议记录用的语言")
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    model.pendingImport = []
                    dismiss()
                }
                .buttonStyle(SheetPillButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                Button("导入并开始转录") {
                    model.confirmImport(ImportOptions(title: title, date: urls.count == 1 ? DateText.string(date) : nil,
                                                      participants: participants, templateId: templateId, language: language,
                                                      minSpeakers: speakerCount == 0 ? nil : speakerCount))
                }
                .buttonStyle(SheetPillButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheetChrome(width: 480)
        .onAppear {
            if let first = urls.first,
               let inferred = DateText.date(Importer.inferDate(filename: first.lastPathComponent, modified: Importer.modificationDate(first))) {
                date = inferred
            }
        }
    }
}

/// 正在编辑条件的文件夹（sheet(item:) 要 Identifiable）
struct EditingFolder: Identifiable {
    let name: String
    var id: String { name }
}
