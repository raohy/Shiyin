import SwiftUI

// MARK: - 侧栏的收合（R101、design §75）

/// 侧栏的列鼠标移上去时，整列一块淡淡的圆角底（R101）：跟系统选中的那一块一样大，
/// 选到的列被系统的选中盖过去
struct SidebarHoverModifier: ViewModifier {
    /// 选到的列（侧栏自己画选中的列：文件夹、展开的会议）一直有一块比较深的灰底
    var selected = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SidebarHoverModifier.radius, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.11 : hovering ? 0.06 : 0))
                    .padding(.horizontal, -SidebarHoverModifier.inset.width)
                    .padding(.vertical, -SidebarHoverModifier.inset.height)
            }
            .onHover { hovering = $0 }
    }

    static let radius: CGFloat = 8

    /// 内容到系统选中那一块的边的距离
    static let inset = CGSize(width: 6, height: 3)
}

extension View {
    func sidebarHover(selected: Bool = false) -> some View { modifier(SidebarHoverModifier(selected: selected)) }

    /// 侧栏 List 里有选中的列（下面的会议、人物）：不画系统的选中（青瓷绿的一整块），选到的列改成灰底；
    /// 选中、多选、键盘照旧。选到时字照常的颜色（不然系统把字换成白的，浅色模式在灰底上看不见）
    func sidebarSelectableRow(selected: Bool) -> some View {
        environment(\.backgroundProminence, .standard)
            .sidebarHover(selected: selected)
            .background(NoNativeSelection())
    }
}

/// 段落标题右边的小按钮（「+」、显示方式）：细线、跟字差不多高、灰色，滑过一块淡淡的圆角底，跟列的「⋯」对齐
struct SidebarHeaderIcon: View {
    let systemName: String
    var active = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .light))
            .foregroundStyle(active ? Color.celadon : hovering ? Color.primary : Color.secondary)
            .frame(width: 26, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    /// 跟列右边的「⋯」对齐：段落标题比列宽一点
    static let trailing: CGFloat = 6
}

/// 侧栏的图标、名字：自己排，不用系统侧栏的排法（系统会用强调色画图标）；图标跟字同色
struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .font(.system(size: 15))
                .frame(width: 22, alignment: .center)
            configuration.title
        }
    }
}

/// 找到侧栏 List 背后的 NSTableView，关掉系统画的选中（选中的状态照旧，由列自己画灰底）
private struct NoNativeSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view, !(current is NSTableView) { view = current.superview }
                if let table = view as? NSTableView, table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            }
        }
    }
}

/// 可以收合的段落标题：标题后面一个小箭头（滑过标题或收起来时才出现），标题和箭头是同一颗按钮
struct SidebarSectionHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let key: String
    /// 旁边还有菜单（会议列表的「显示方式」）：段落标题在辅助功能里会跟菜单并成一个组件，按下去要照旧打开菜单，
    /// 所以这时不用按钮，收合改成有名字的动作（2026-11-16 用 AX 按的时候发现菜单打不开）
    var besideMenu = false
    @State private var hovering = false

    var body: some View {
        let expanded = model.isSectionExpanded(key)
        let toggle = {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.setSection(key, expanded: !expanded) }
        }
        let label = HStack(spacing: 4) {
            // 跟列一样大的灰字、不加粗，不用 macOS 侧栏默认的小粗体
            Text(title).lineLimit(1).font(.body).fontWeight(.regular).foregroundStyle(.secondary)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .opacity(hovering || !expanded ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        let help = expanded ? String(localized: "收起这一段") : String(localized: "展开这一段")
        if besideMenu {
            label
                .sidebarClick(toggle)
                .help(help)
                .accessibilityAction(named: Text(help), toggle)
        } else {
            // 不用 Button：List 里的 SwiftUI 按钮会让整个表格的点击卡住（见 sidebarClick）
            label
                .sidebarClick(toggle)
                .help(help)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits([.isHeader, .isButton])
                .accessibilityAction(.default, toggle)
                .accessibilityValue(Text(expanded ? "已展开" : "已收起"))
        }
    }
}

/// 侧栏的文件夹图标（R101）：关着、打开两种表示有没有展开；系统图标没有打开的文件夹，
/// 自己画（`OpenFolderShape`），大小、粗细照系统的 `folder`。标记在右上角：齿轮是有自动加入条件
struct FolderGlyph: View {
    var open: Bool
    var badge: String? = nil

    var body: some View {
        // 看不见的系统文件夹图标决定大小、基线，画的东西放在它上面
        Image(systemName: "folder").hidden()
            .overlay {
                GeometryReader { g in
                    let badgeSize = g.size.height * 0.62
                    let center = CGPoint(x: g.size.width * 0.88, y: g.size.height * 0.2)
                    ZStack {
                        Group {
                            if open {
                                OpenFolderShape()
                                    .stroke(style: StrokeStyle(lineWidth: g.size.height * 0.085, lineCap: .round, lineJoin: .round))
                            } else {
                                Image(systemName: "folder").resizable()
                            }
                        }
                        // 标记的位置挖空，线才不会穿过标记。遮罩一定要给明确的颜色：侧栏的默认前景色是半透明的，
                        // 拿来当遮罩整个图标会不见（2026-11-16 在侧栏上才看到）
                        .mask {
                            BadgeHole(center: center, radius: badge == nil ? 0 : badgeSize * 0.62)
                                .fill(Color.black, style: FillStyle(eoFill: true))
                        }
                        if let badge {
                            Image(systemName: badge)
                                .resizable().scaledToFit()
                                .fontWeight(.bold)
                                .frame(width: badgeSize, height: badgeSize)
                                .position(center)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// 整个框，挖掉标记的圆（even-odd）
private struct BadgeHole: Shape {
    var center: CGPoint
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if radius > 0 { path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)) }
        return path
    }
}

/// 打开的文件夹：后面一片带标签的背板，前面一片斜的盖子（座标是系统 `folder` 图标的框里的比例）
struct OpenFolderShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.10, 0.80))
        path.addLine(to: p(0.10, 0.22))
        path.addQuadCurve(to: p(0.17, 0.14), control: p(0.10, 0.14))
        path.addLine(to: p(0.36, 0.14))
        path.addQuadCurve(to: p(0.42, 0.17), control: p(0.40, 0.14))
        path.addLine(to: p(0.47, 0.24))
        path.addLine(to: p(0.76, 0.24))
        path.addQuadCurve(to: p(0.83, 0.31), control: p(0.83, 0.24))
        path.addLine(to: p(0.83, 0.42))
        path.move(to: p(0.10, 0.80))
        path.addQuadCurve(to: p(0.17, 0.86), control: p(0.11, 0.86))
        path.addLine(to: p(0.76, 0.86))
        path.addQuadCurve(to: p(0.83, 0.81), control: p(0.81, 0.86))
        path.addLine(to: p(0.95, 0.50))
        path.addQuadCurve(to: p(0.90, 0.42), control: p(0.97, 0.42))
        path.addLine(to: p(0.30, 0.42))
        path.addQuadCurve(to: p(0.24, 0.47), control: p(0.26, 0.42))
        path.addLine(to: p(0.10, 0.80))
        return path
    }
}

/// 文件夹在原地展开的最近 5 场；超过时最后一列「显示全部 N 场」（下面的列表只看这个文件夹）；
/// 没有会议时一列「没有会议」
struct SidebarPeek: View {
    let rows: [MeetingRow]
    let showAll: () -> Void

    var body: some View {
        if rows.isEmpty {
            SidebarPeekLine { Text("没有会议").foregroundStyle(.secondary) }
                .selectionDisabled()
        }
        // id 用字符串：ForEach 会把 id 当成列的 tag，用会议 id 的话 List 会把这几列当成选中（跟下面的列表一起亮成一整条）
        ForEach(rows.prefix(5).map { (key: "peek:\($0.id)", row: $0) }, id: \.key) { item in
            SidebarPeekRow(row: item.row)
        }
        if rows.count > 5 {
            SidebarPeekLine {
                Text("显示全部 \(rows.count) 场").foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, showAll)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .sidebarClick(showAll)
            .sidebarHover()
            .selectionDisabled()
        }
    }
}

/// 展开的一场：点了打开（下面的列表不换）；选到时青瓷绿、粗体，同文件夹列（不用 List 的选中，下面的列表也有这场）
private struct SidebarPeekRow: View {
    @Environment(AppModel.self) private var model
    let row: MeetingRow

    var body: some View {
        let selected = model.sidebarMode == .meetings && !model.showTrash && model.selection == row.id
        let open = { model.openFromSidebar(row.id) }
        SidebarPeekLine {
            Text(row.meeting.displayTitle).lineLimit(1)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 拖到别的文件夹、其他会议的标题、垃圾桶（R103.1）：不在 List 的选中里，盖拖动把手；没拖就是点一下
        .sidebarDragHandle(type: .shiyinMeetingIDs, label: row.meeting.displayTitle,
                           data: { Data(model.dragIDs(for: row.id).map(String.init).joined(separator: ",").utf8) }, onClick: open)
        .floatingRowMenu(selected: selected) { model.meetingMenu([row.id]) }
        // 选到时一块灰底，不用 List 的选中（下面的列表也有这场，两边都亮会像多选）
        .sidebarHover(selected: selected)
        .help("\(row.meeting.meetingDate)・\(row.meeting.displayTitle)")
        .selectionDisabled()
    }
}

/// 缩进到跟文件夹名称对齐：看不见的文件夹图标
private struct SidebarPeekLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Label { content } icon: { Image(systemName: "folder").hidden() }
            .labelStyle(SidebarLabelStyle())
    }
}
