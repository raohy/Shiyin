import SwiftUI

/// 菜单列图标：闲置、录音中、工作中三种状态（R13.1）
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .onAppear {
                // 菜单列图标一直存在，用它提供「重新打开主窗口」的方法
                let open = openWindow
                if model.openMainWindow == nil {
                    model.openMainWindow = {
                        open(id: "main")
                        NSApp.activate()
                    }
                }
            }
    }
}

/// 菜单内容（R13.2）
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recording
            Divider()
            jobs
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button("打开拾音") { model.openMainWindow?() }
                Button("使用说明") {
                    openWindow(id: "guide")
                    NSApp.activate()
                }
                Button("结束拾音") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .tint(.celadon)
    }

    @ViewBuilder
    private var recording: some View {
        let recorder = model.recorder
        if recorder.isRecording {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(recorder.isPaused ? Color.secondary : .red).frame(width: 8, height: 8)
                    Text(recorder.isPaused ? "已暂停" : "录音中")
                    RecorderClock(recorder: recorder).foregroundStyle(.secondary)
                    Spacer()
                    Button(recorder.isPaused ? "继续" : "暂停") { recorder.isPaused ? recorder.resume() : recorder.pause() }
                    Button("停止") { recorder.stop() }
                }
                if recorder.hasMic {
                    RecorderMeter(recorder: recorder, system: false, segments: 24)
                    // 正在用哪一支麦克风（design §38.3）
                    if let device = recorder.micDevice {
                        Text("麦克风：\(device.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if recorder.hasSystem { RecorderMeter(recorder: recorder, system: true, segments: 24) }
                if recorder.idlePrompt {
                    // 忘了停止录音（R48.1）：同录音画面
                    VStack(alignment: .leading, spacing: 6) {
                        Label("好像没人在说话了，要停止录音吗？", systemImage: "moon.zzz")
                            .font(.caption)
                            .foregroundStyle(Color.signal)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("继续录") { recorder.continueAfterIdle() }
                            Button("停止录音") { recorder.stop() }
                        }
                        .font(.caption)
                    }
                }
                if let hint = recorder.micHint {
                    // 用蓝牙耳机的麦克风录现场会议（design §38.4）：同录音画面
                    VStack(alignment: .leading, spacing: 6) {
                        Label(hint.text, systemImage: "headphones")
                            .font(.caption)
                            .foregroundStyle(Color.signal)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let builtIn = hint.builtIn {
                                Button("改用 \(builtIn.name)") { model.switchMicrophone(builtIn.uid) }
                            }
                            Button("知道了") { recorder.dismissMicHint() }
                        }
                        .font(.caption)
                    }
                }
                if let hint = recorder.levelHint {
                    // 收音提醒（R42.2）：跟录音画面同一句，「知道了」这场不再提示
                    VStack(alignment: .leading, spacing: 6) {
                        Label(recorder.text(for: hint), systemImage: hint == .noisy ? "waveform.badge.exclamationmark" : "mic.badge.xmark")
                            .font(.caption)
                            .foregroundStyle(Color.signal)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("知道了") { recorder.dismissLevelHint() }
                            .font(.caption)
                    }
                }
                if !recorder.volatileText.isEmpty || !recorder.liveLines.isEmpty {
                    Text(recorder.volatileText.isEmpty ? recorder.liveLines.last?.text ?? "" : recorder.volatileText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else {
            Button { model.startRecording() } label: {
                Label("开始录音", systemImage: "record.circle")
            }
        }
    }

    @ViewBuilder
    private var jobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = model.runner.running[.transcribe] {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "\(t.job.kind == .compress ? String(localized: "压缩录音") : t.stage.isEmpty ? String(localized: "转录") : t.stage)中：\(title(t.job.meetingId))")).lineLimit(1)
                    if let p = t.progress {
                        ProgressView(value: p).tint(.signal)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            // 整理线、辅助线（逐字稿校正）同时跑（design §21.2）
            ForEach([JobLane.llm, .assist], id: \.self) { lane in
                if let l = model.runner.running[lane] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(llmStatus(l.job.kind, title(l.job.meetingId))).lineLimit(1)
                    }
                }
            }
            if model.queuedCount > 0 {
                Text("排队中 \(model.queuedCount) 项").foregroundStyle(.secondary)
            }
            if !model.runner.isBusy && model.queuedCount == 0 {
                Text("目前没有进行中的工作").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// 整理那条线正在做什么：整理、依回答修正、检查可能听错的字
    private func llmStatus(_ kind: JobKind, _ title: String) -> String {
        switch kind {
        case .revise: return String(localized: "依回答修正中：\(title)")
        case .correct: return String(localized: "检查可能听错的字：\(title)")
        case .nameSpeakers: return String(localized: "猜说话者：\(title)")
        default: return String(localized: "整理中：\(title)")
        }
    }

    private func title(_ meetingId: Int64) -> String {
        model.meetings.first { $0.id == meetingId }?.meeting.displayTitle ?? String(localized: "会议")
    }
}
