import SwiftUI

/// 会议列表的「显示方式」：排序、分组、筛选（R97、design §71）。列表上方的按钮和菜单列的「显示方式」共用；
/// 菜单列放成三个子菜单，列表上方的按钮放成三段
struct MeetingListMenu: View {
    let model: AppModel
    var submenus = false

    var body: some View {
        if submenus {
            // 菜单列：Picker 的菜单样式就是有打勾的子菜单（inline 会在子菜单头尾多出分隔线）
            sortPicker.pickerStyle(.menu)
            groupingPicker.pickerStyle(.menu)
                .disabled(model.showTrash)
            Menu("筛选") { filters }
                .disabled(model.showTrash)
        } else {
            // inline 的 Picker 自己会带段落标题和分隔线；再包一层 Section 会多出连续好几条分隔线（2026-11-16 自己验收时发现）
            sortPicker.pickerStyle(.inline)
            if !model.showTrash {
                groupingPicker.pickerStyle(.inline)
                Section("筛选") { filters }
            }
        }
    }

    private var sortPicker: some View {
        @Bindable var model = model
        return Picker("排序方式", selection: $model.meetingSort) {
            ForEach(MeetingSort.allCases) { Text($0.label).tag($0) }
        }
    }

    /// 看某个文件夹时不能依文件夹分组，打勾的是实际用的
    private var groupingPicker: some View {
        Picker("分组方式", selection: Binding(get: { model.effectiveGrouping }, set: { model.meetingGrouping = $0 })) {
            ForEach(model.availableGroupings) { Text($0.label).tag($0) }
        }
    }

    @ViewBuilder
    private var filters: some View {
        @Bindable var model = model
        Toggle("有待确认的", isOn: $model.meetingFilter.needsReview)
        // 没有设置「我」时不出现（R97.3）
        if model.myName != nil {
            Toggle("有我的待办的", isOn: $model.meetingFilter.myActionItems)
        }
        if !model.peopleOverview.isEmpty {
            Picker("有谁参加", selection: $model.meetingFilter.personId) {
                Text("不限").tag(Int64?.none)
                Divider()
                ForEach(model.peopleOverview) { person in
                    Text(person.isMe ? String(localized: "\(person.name)（我）") : person.name).tag(Optional(person.id))
                }
            }
            .pickerStyle(.menu)
        }
        Picker("模板", selection: $model.meetingFilter.templateId) {
            Text("不限").tag(String?.none)
            Divider()
            ForEach(model.templates) { template in
                Text(template.displayName).tag(Optional(template.id))
            }
        }
        .pickerStyle(.menu)
        if model.meetingFilter.isActive {
            Divider()
            Button("清除筛选") { model.meetingFilter = MeetingFilter() }
        }
    }
}

/// 会议那一段的标题：「所有会议」或文件夹名称、分组方式，右边「显示方式」按钮；筛选中按钮变实心（design §71）
struct MeetingListHeader: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            // 名称是收合的按钮（R101、design §75）；右边的「显示方式」不动。会议拖到这里＝移进现在看的地方，
            // 「其他会议」是移出文件夹（R103.1）
            SidebarSectionHeader(title: title, key: "meetings", besideMenu: true)
                .foregroundStyle(dropTargeted ? Color.celadon : Color.secondary)
            Spacer(minLength: 4)
            Menu {
                MeetingListMenu(model: model)
            } label: {
                // 细线的滑杆图标，跟「文件夹」的「+」同一种样子；筛选中是青瓷绿
                SidebarHeaderIcon(systemName: "slider.horizontal.3", active: model.meetingFilter.isActive)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, SidebarHeaderIcon.trailing)
            .help("排序、分组、筛选会议")
            .accessibilityLabel(Text("显示方式"))
        }
        .contentShape(Rectangle())
        .meetingDrop(enabled: model.listHeaderAcceptsMeetings, targeted: $dropTargeted) { model.dropOnListHeader($0) }
    }

    private var title: String {
        // 下面只放文件夹以外的会议时叫「其他会议」（R101.6）
        let scope = model.folderFilter
            ?? (model.listShowsOthersOnly ? String(localized: "其他会议") : String(localized: "所有会议"))
        let grouping = model.effectiveGrouping
        return grouping == .none ? scope : scope + "・" + grouping.label
    }
}

/// 筛选中的那一列（列表最上面）：「筛选：有待确认、王小明 有参加」，✕ 清掉（R97.3）
struct MeetingFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Color.celadon)
            Text("筛选：\(model.filterSummary)")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.meetingFilter = MeetingFilter() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("清除筛选")
            .accessibilityLabel(Text("清除筛选"))
        }
        .font(.callout)
        .selectionDisabled()
    }
}

/// 筛选后没有会议（R97.3）：说明、清除筛选
struct MeetingFilterEmpty: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("没有符合筛选的会议").foregroundStyle(.secondary)
            Button("清除筛选") { model.meetingFilter = MeetingFilter() }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.celadon)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .selectionDisabled()
    }
}
