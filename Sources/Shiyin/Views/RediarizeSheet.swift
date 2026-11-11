import SwiftUI

/// 重新识别说话者（design §23.4、R22）：选大约几个人，只重新分辨谁在说话，逐字稿的文字不变
struct RediarizeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// 0 是自动判断
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重新识别说话者").font(.title3.weight(.semibold))
            Text("只重新分辨谁在说话，逐字稿的文字不会变。人多、吵杂或手机远距收音时，告诉拾音大约几个人会分得比较准。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("大约几个人", selection: $count) {
                Text("自动判断").tag(0)
                ForEach(2...12, id: \.self) { n in Text("\(n) 人").tag(n) }
            }
            .frame(width: 260)
            Text("原本取过的名字会尽量保留，其他说话者会用声纹比对、再用整理工具猜名字。会议记录不会自动更新。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始") {
                    if let id = model.rediarizeMeetingId { model.rediarize(meetingId: id, minSpeakers: count == 0 ? nil : count) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .tint(.celadon)
        .onAppear {
            // 默认是这场记住的人数
            if let id = model.rediarizeMeetingId, let n = (try? model.db.meeting(id))??.minSpeakers { count = n }
        }
    }
}
