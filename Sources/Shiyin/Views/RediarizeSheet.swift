import SwiftUI

/// 重新识别说话者（design §23.4、R22）：选大约几个人，只重新分辨谁在说话，逐字稿的文字不变
struct RediarizeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// 0 是自动判断
    @State private var count = 0

    var body: some View {
        // 同其他弹窗的样子（R106、design §80）
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: String(localized: "重新识别说话者"),
                        subtitle: String(localized: "只重新分辨谁在说话，逐字稿的文字不会变。人多、吵杂或手机远距收音时，告诉拾音大约几个人会分得比较准。"))
            VStack(alignment: .leading, spacing: 6) {
                SheetFieldLabel(String(localized: "大约几个人"))
                SheetMenuField(options: [(0, String(localized: "自动判断"))] + (2...12).map { ($0, String(localized: "\($0) 人")) },
                               selection: $count)
                    .frame(width: 220)
            }
            Text("原本取过的名字会尽量保留，其他说话者会用声纹比对、再用整理工具猜名字。会议记录不会自动更新。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("开始") {
                    if let id = model.rediarizeMeetingId { model.rediarize(meetingId: id, minSpeakers: count == 0 ? nil : count) }
                    dismiss()
                }
                .buttonStyle(SheetPillButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheetChrome()
        .onAppear {
            // 默认是这场记住的人数
            if let id = model.rediarizeMeetingId, let n = (try? model.db.meeting(id))??.minSpeakers { count = n }
        }
    }
}
