import AppKit
import SwiftUI

/// 录音岛的画面（design §57.1、§57.2）：黑底白字，接在浏海两侧（没有浏海时是菜单列下方的胶囊）。
/// 收起：红点、时间；提醒：展开成那一句和按钮；检测会议：要开始录音吗；滑过去：音量、最新一句、控制
struct IslandRoot: View {
    @Environment(AppModel.self) private var model
    let state: IslandState
    @State private var bookmarked = false
    @State private var leaveTask: Task<Void, Never>?

    /// 浏海两侧各放多宽（红点、时间）
    private static let wing: CGFloat = 64

    var body: some View {
        content
            .background(HoverTracker { inside in hoverChanged(inside) })
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { RecordingIsland.shared.contentSizeChanged($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            .font(.system(size: 13))
    }

    @ViewBuilder
    private var content: some View {
        let recorder = model.recorder
        if let prompt = state.prompt {
            expanded(header: promptHeader) { promptBody(prompt) }
        } else if state.hover && recorder.isRecording {
            expanded(header: recordingHeader) { controls }
        } else if state.hintExpanded, let hint = currentHint {
            expanded(header: recordingHeader) { hintBody(hint) }
        } else {
            collapsed
        }
    }

    // MARK: 收起

    @ViewBuilder
    private var collapsed: some View {
        let notch = state.notch
        if notch.hasNotch {
            recordingHeader
                .background(IslandShape(radius: 10, flushTop: true).fill(.black))
        } else {
            HStack(spacing: 8) {
                statusDot
                elapsed
            }
            .padding(.horizontal, 12)
            .frame(height: notch.height)
            .background(Capsule().fill(.black.opacity(0.9)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
    }

    /// 浏海两侧：左边红点、右边时间；中间被浏海挡住的地方不放东西。没有浏海时放在一起
    @ViewBuilder
    private var recordingHeader: some View {
        let notch = state.notch
        if notch.hasNotch {
            HStack(spacing: 0) {
                statusDot.frame(width: Self.wing)
                Color.clear.frame(width: notch.width)
                elapsed.frame(width: Self.wing)
            }
            .frame(height: notch.height)
        } else {
            HStack(spacing: 8) {
                statusDot
                elapsed
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        }
    }

    @ViewBuilder
    private var promptHeader: some View {
        let notch = state.notch
        if notch.hasNotch {
            HStack(spacing: 0) {
                Image(systemName: "waveform").foregroundStyle(Color.celadon).frame(width: Self.wing)
                Color.clear.frame(width: notch.width)
                Color.clear.frame(width: Self.wing)
            }
            .frame(height: notch.height)
        } else {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Color.celadon)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        }
    }

    /// 红点；暂停时是暂停的图标；有提醒（收回之后）是琥珀色的点
    @ViewBuilder
    private var statusDot: some View {
        let recorder = model.recorder
        if recorder.isPaused {
            Image(systemName: "pause.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
        } else {
            Circle()
                .fill(state.hintKey != nil ? Color.signal : Color.red)
                .frame(width: 8, height: 8)
        }
    }

    private var elapsed: some View {
        Text(TimeFormat.string(Double(model.recorder.elapsedSeconds)))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
    }

    // MARK: 展开

    private func expanded<Header: View, Body: View>(header: Header, @ViewBuilder body: () -> Body) -> some View {
        let notch = state.notch
        let width = max(420, notch.width + 2 * Self.wing)
        return VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, notch.hasNotch ? 0 : 16)
            body()
                .padding(.horizontal, 18)
                .padding(.top, notch.hasNotch ? 10 : 2)
                .padding(.bottom, 16)
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.white)
        .background(IslandShape(radius: 20, flushTop: notch.hasNotch).fill(.black))
        .overlay {
            if !notch.hasNotch { IslandShape(radius: 20, flushTop: false).stroke(.white.opacity(0.1)) }
        }
    }

    /// 滑过去（R81.5）：音量、最新一句实时逐字稿、有提醒时那一句，按钮
    private var controls: some View {
        let recorder = model.recorder
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    LevelMeter(segments: 12) { [recorder] in recorder.micLevel }
                }
                if recorder.hasSystem {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                        LevelMeter(segments: 12) { [recorder] in recorder.systemLevel }
                    }
                }
                Spacer(minLength: 0)
            }
            if let line = latestLine {
                Text(line).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let hint = currentHint {
                Label(hint.text, systemImage: hint.symbol).foregroundStyle(Color.signal).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                // 提醒的按钮也放这里：展开的提醒一滑过去就换成这个画面，不放的话「知道了」「继续录」永远按不到
                hintButtons(hint)
            }
            HStack(spacing: 8) {
                IslandButton(title: recorder.isPaused ? String(localized: "继续") : String(localized: "暂停"),
                             symbol: recorder.isPaused ? "play.fill" : "pause.fill") {
                    recorder.isPaused ? recorder.resume() : recorder.pause()
                }
                IslandButton(title: bookmarked ? String(localized: "已标记") : String(localized: "标记重点"),
                             symbol: bookmarked ? "star.fill" : "star") {
                    model.addBookmark(at: recorder.elapsed, meetingId: recorder.meetingId)
                    bookmarked = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); bookmarked = false }
                }
                IslandButton(title: String(localized: "打开拾音"), symbol: "macwindow") {
                    if let id = recorder.meetingId { model.reveal(id) }
                    NSApp.activate()
                }
                Spacer(minLength: 0)
                IslandButton(title: String(localized: "停止并转录"), symbol: "stop.fill", role: .destructive) { recorder.stop() }
            }
        }
    }

    private func hintBody(_ hint: IslandHint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hint.text, systemImage: hint.symbol)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            hintButtons(hint)
        }
    }

    @ViewBuilder
    private func hintButtons(_ hint: IslandHint) -> some View {
        if !hint.buttons.isEmpty {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(hint.buttons.enumerated()), id: \.offset) { _, button in
                    IslandButton(title: button.title, role: button.primary ? .primary : .normal, action: button.action)
                }
            }
        }
    }

    private func promptBody(_ prompt: IslandState.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 会议结束的倒数（R95）：每秒换成剩下的秒数
            if let deadline = prompt.deadline, let countdown = prompt.countdown {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdown(max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))))
                        .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(prompt.message).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(prompt.actions.enumerated()), id: \.offset) { index, action in
                    IslandButton(title: action.title, role: index == prompt.actions.count - 1 ? .primary : .normal, action: action.run)
                }
            }
        }
    }

    // MARK: 资料

    /// 最新一句实时逐字稿（还没定稿的优先）
    private var latestLine: String? {
        let recorder = model.recorder
        let text = recorder.volatileText.isEmpty ? recorder.liveLines.last?.text ?? "" : recorder.volatileText
        return text.isEmpty ? nil : text
    }

    /// 目前的提醒和它的按钮，跟录音画面的提示列同一句、同样的按钮（R81.2）
    private var currentHint: IslandHint? {
        let recorder = model.recorder
        guard recorder.isRecording else { return nil }
        if recorder.idlePrompt {
            return IslandHint(text: String(localized: "好像没人在说话了，要停止录音吗？再 15 分钟没人说话会自动停止。"), symbol: "moon.zzz", buttons: [
                .init(title: String(localized: "继续录"), primary: false) { recorder.continueAfterIdle() },
                .init(title: String(localized: "停止录音"), primary: true) { recorder.stop() },
            ])
        }
        if let hint = recorder.micHint {
            var buttons: [IslandHint.Button] = []
            if let builtIn = hint.builtIn {
                buttons.append(.init(title: String(localized: "改用 \(builtIn.name)"), primary: true) { model.switchMicrophone(builtIn.uid) })
            }
            buttons.append(.init(title: String(localized: "知道了"), primary: false) { recorder.dismissMicHint() })
            return IslandHint(text: hint.text, symbol: "headphones", buttons: buttons)
        }
        if let hint = recorder.levelHint {
            var buttons: [IslandHint.Button] = []
            if hint == .systemDenied {
                buttons.append(.init(title: String(localized: "打开系统设置"), primary: true) { Recorder.openPrivacySettings("Privacy_AudioCapture") })
            }
            buttons.append(.init(title: String(localized: "知道了"), primary: false) { recorder.dismissLevelHint() })
            return IslandHint(text: recorder.text(for: hint), symbol: hint.symbol, buttons: buttons)
        }
        if let warning = recorder.deviceWarning {
            return IslandHint(text: warning, symbol: "arrow.triangle.2.circlepath", buttons: [])
        }
        return nil
    }

    /// 滑出去 0.3 秒后才收回（滑过边界不会闪）
    private func hoverChanged(_ inside: Bool) {
        leaveTask?.cancel()
        if inside {
            if !state.hover { state.hover = true }
        } else {
            leaveTask = Task {
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }
                state.hover = false
            }
        }
    }
}

struct IslandHint {
    struct Button {
        var title: String
        var primary: Bool
        var action: () -> Void
    }

    var text: String
    var symbol: String
    var buttons: [Button]
}

/// 岛上的按钮：白色半透明的胶囊；主要的是青瓷绿，停止是红色
private struct IslandButton: View {
    enum Role { case normal, primary, destructive }
    let title: String
    var symbol: String?
    var role: Role = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch role {
        case .normal: return .white.opacity(0.14)
        case .primary: return Color(nsColor: .dynamic(light: 0x2D6A5D, dark: 0x2D6A5D))
        case .destructive: return Color(red: 0.75, green: 0.2, blue: 0.2)
        }
    }
}

/// 上缘贴着屏幕（接在浏海下面）时上面两个角是直角；没有浏海时四个角都是圆角
struct IslandShape: Shape {
    var radius: CGFloat
    var flushTop: Bool

    func path(in rect: CGRect) -> Path {
        flushTop
            ? UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                     topTrailingRadius: 0, style: .continuous).path(in: rect)
            : RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

/// 鼠标进出：拾音不在前面时也要收得到（.activeAlways），SwiftUI 的 onHover 在不是 key 的窗口上不一定收得到
private struct HoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
