import AVFoundation
import AppKit
import Observation

/// 录音（design §5、R1、R2）：统筹音源、写档、实时逐字稿、暂停、音量
@MainActor
@Observable
final class Recorder {
    struct Result {
        var meetingId: Int64
        var file: URL?
        var duration: Double
        var error: String?
        /// 没人说话太久而自动停止（R48.2）：最后有人说话的秒数
        var idleSince: Double? = nil
    }

    struct LiveLine: Identifiable, Hashable {
        let id = UUID()
        var start: Double
        var end: Double
        var text: String
    }

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var meetingId: Int64?
    private(set) var startedAt: Date?
    /// 精确的录音秒数（笔记的时间点、标记重点用）。每 0.05 秒变一次，画面不要读这个，读 elapsedSeconds（design §25）
    @ObservationIgnored private(set) var elapsed: Double = 0
    /// 画面显示的录音秒数：整秒变了才更新
    private(set) var elapsedSeconds = 0
    /// 音量（0～1）。不让 SwiftUI 观察：音量条（LevelMeter）自己定时来读，
    /// 不然说话时每秒变十几次，每次整个窗口都要重新排版（design §25）
    @ObservationIgnored private(set) var micLevel: Float = 0
    @ObservationIgnored private(set) var systemLevel: Float = 0
    private(set) var source = "mic"            // mic / system / both
    private(set) var liveLines: [LiveLine] = []
    private(set) var volatileText = ""
    private(set) var liveStatus = ""
    /// 系统声音一直是静音：可能没有允许「录制系统音频」或没有东西在播
    private(set) var systemSilent = false
    var permissionDenied = false
    var failureMessage: String?
    /// 自动检测换了会议语言（design §18.8）：录音画面显示「改回」
    private(set) var languageSwitch: (from: MeetingLanguage, to: MeetingLanguage)?
    /// 有音源超过 3 秒没送资料、正在重新连接（design §20.2）：录音画面的提示列显示
    private(set) var deviceWarning: String?

    /// 收音提醒（design §26.1、R24.1、R24.3）
    enum LevelHint: String {
        case silent   // 麦克风的声音完全是 0
        case suppressed   // 几乎没声音：被别的 app 的语音处理占住（design §45、R57）
        case quiet    // 有人在说话，但声音很小
        case noisy    // 背景一直很大声

        /// 录音画面、菜单列、通知都用同一句（R42）
        var text: String {
            switch self {
            case .silent: return String(localized: "麦克风没有收到声音：可能被静音、被其他 app 占用，或选错了麦克风。可以在设置的「录音与转录」换一个。")
            case .suppressed: return Self.suppressedText(nil)
            case .quiet: return String(localized: "声音有点小：手机或笔记本电脑放近说话的人一点。")
            case .noisy: return String(localized: "背景有点吵，说话者可能分不准。录完可以用「重新识别说话者」告诉拾音大约几个人。")
            }
        }

        /// 被占住的提示要写出是哪个 app（design §45.3、R57.1、R57.2）：浏览器、找不到是谁时建议改用 Chrome，其他 app 只建议换麦克风
        static func suppressedText(_ user: MeetingDetector.MicrophoneUser?) -> String {
            guard let user, !user.isBrowser else {
                let name = user?.name ?? String(localized: "其他 app")
                return String(localized: "麦克风几乎收不到声音：\(name) 可能正在用这支麦克风做回音消除（例如用 Safari 开的 Google Meet），拾音收不到你的声音。请改用 Chrome 开会，或让会议和拾音用不同的麦克风。")
            }
            return String(localized: "麦克风几乎收不到声音：\(user.name) 可能正在用这支麦克风做回音消除，拾音收不到你的声音。请让 \(user.name) 和拾音用不同的麦克风。")
        }
    }
    private(set) var levelHint: LevelHint?
    /// 提示的文字（录音画面、菜单列、通知共用，R42）
    func text(for hint: LevelHint) -> String {
        hint == .suppressed ? LevelHint.suppressedText(suppressedBy) : hint.text
    }
    /// 被占住的提示出现时，正在用麦克风的 app（design §45.2）；AppModel 接到 MeetingDetector
    @ObservationIgnored var microphoneUser: (() -> MeetingDetector.MicrophoneUser?)?
    @ObservationIgnored private var suppressedBy: MeetingDetector.MicrophoneUser?
    /// 这场录音稍早的背景音量（最低值）；晚 10 秒才算数，还没算数的放 pendingFloor（design §45.1）
    @ObservationIgnored private var micFloor: Float?
    @ObservationIgnored private var pendingFloor: [Float] = []
    /// 几乎没声音之后 30 秒内的背景不算：30 秒的音量里还有那时候的
    @ObservationIgnored private var floorHold = 0

    /// 正在收音的麦克风（design §38.3、R58.2）：开始、重新开始、换麦克风后更新
    private(set) var micDevice: AudioDevices.Device?
    /// 用蓝牙耳机的麦克风录现场会议（design §38.4、R58.3）
    struct MicHint: Equatable {
        var name: String
        /// 这台电脑的内置麦克风，提示列的「改用」按钮用；没有就不放按钮
        var builtIn: AudioDevices.Device?

        /// 录音画面、菜单列、通知都用同一句
        var text: String {
            String(localized: "正在用「\(name)」收音：这是蓝牙耳机的麦克风，人不在旁边时录不到现场的声音。")
        }
    }
    private(set) var micHint: MicHint?
    @ObservationIgnored private var micHintDismissed = false
    @ObservationIgnored private var micHintNotified = false
    /// 蓝牙的提示第一次出现：AppModel 决定要不要送通知（同收音提醒，design §31.5）
    @ObservationIgnored var onMicHint: ((MicHint) -> Void)?
    @ObservationIgnored private var dismissedLevelHints: Set<LevelHint> = []
    /// 这场录音已经通知过的提示（R42.1：每种每场最多一次）
    @ObservationIgnored private var notifiedLevelHints: Set<LevelHint> = []
    /// 提示第一次出现（design §31.5）：AppModel 决定要不要送通知
    @ObservationIgnored var onLevelHint: ((LevelHint) -> Void)?
    @ObservationIgnored private var noisySeconds = 0
    @ObservationIgnored private var quietSeconds = 0

    /// 忘了停止录音（design §35、R48）：最后有人说话的录音秒数；实时逐字稿有没有接上音频
    @ObservationIgnored private var lastSpeechAt: Double = 0
    @ObservationIgnored private var liveActive = false
    /// 好像没人在说话了，要停止录音吗？（录音画面、菜单列显示）
    private(set) var idlePrompt = false
    /// 提醒出现（AppModel 送通知）
    @ObservationIgnored var onIdlePrompt: (() -> Void)?
    /// 15 分钟提醒、30 分钟自动停止；DEBUG 可以用启动参数缩短（design §35.2）
    static var idleRemindSeconds: Double { debugSeconds("idleRemindSeconds") ?? 900 }
    static var idleStopSeconds: Double { debugSeconds("idleStopSeconds") ?? 1800 }
    private static func debugSeconds(_ key: String) -> Double? {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : nil
        #else
        return nil
        #endif
    }
    #if DEBUG
    @ObservationIgnored private(set) var levelCheck: [String: Any] = [:]
    /// 忘了停止录音的状态（design §35.2）：shiyinctl state 的 recorder.idle
    var idleInfo: [String: Any] {
        ["idleSeconds": isRecording ? elapsed - lastSpeechAt : 0, "lastSpeechAt": lastSpeechAt, "prompt": idlePrompt,
         "liveActive": liveActive, "remindAfter": Self.idleRemindSeconds, "stopAfter": Self.idleStopSeconds]
    }
    #endif

    @ObservationIgnored var onFinished: ((Result) -> Void)?
    /// 录音开始了（全域快捷键标记重点这时才注册，design §21.10）
    @ObservationIgnored var onStarted: (() -> Void)?
    /// 停止后实时识别收尾完（最后还没定稿的文字已经存进去），给草稿记录用（design §21.3）：会议 id、录到的秒数
    @ObservationIgnored var onLiveFinished: ((Int64, Double) -> Void)?
    @ObservationIgnored var onLiveFinal: ((Int64, Double, Double, String) -> Void)?
    @ObservationIgnored var onReviewed: ((Int64, Double, Double, String) throws -> Void)?
    /// 录音中换了会议语言（自动检测或改回），要更新数据库
    @ObservationIgnored var onLanguageChange: ((Int64, MeetingLanguage) -> Void)?
    @ObservationIgnored private let tap = MixTap()
    @ObservationIgnored private var writer: RecordingWriter?
    @ObservationIgnored private var sources: [Int: AudioSource] = [:]   // 声道 → 音源
    /// 看门狗：没送资料的声道 → 上次试着重新连接的时间；重新连接失败的原因
    @ObservationIgnored private var reconnecting: [Int: Date] = [:]
    @ObservationIgnored private var reconnectErrors: [Int: String] = [:]
    @ObservationIgnored private var pendingRestarts: [Int: DispatchWorkItem] = [:]
    /// 重新连接的节奏（design §50.1）：每个声道 60 秒内重新连接的时间、上次重新连接完的时间
    @ObservationIgnored private var restarts: [Int: [Date]] = [:]
    @ObservationIgnored private var restartedAt: [Int: Date] = [:]
    /// 重新连接在背景队列做（design §50.2）：正在做的声道、做完要再做一次的声道（中途换了麦克风）
    @ObservationIgnored private var restarting: Set<Int> = []
    @ObservationIgnored private var restartAgain: Set<Int> = []
    @ObservationIgnored private let deviceQueue = DispatchQueue(label: "com.weiwei.shiyin.devices", qos: .userInitiated)
    /// 磁盘空间（design §20.3）：上次检查的时间；录音中不到 300 MB 只提醒一次
    @ObservationIgnored private var lastDiskCheck = Date.distantPast
    @ObservationIgnored private var warnedLowDisk = false
    #if DEBUG
    /// 模拟录音的文件送完了，之后没有资料是正常的
    @ObservationIgnored private var simulationEnded = false
    #endif
    @ObservationIgnored private var live: (any LiveTranscribing)?
    @ObservationIgnored private var reviewer: QwenLiveTranscriber?
    private(set) var reviewStatus = ""
    private(set) var reviewedThrough: Double = 0
    private(set) var finishingLiveCount = 0
    var isUsingQwenLive: Bool { isRecording && (live is QwenLiveTranscriber || reviewer != nil) }
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// 这场录音的会议语言，决定实时逐字稿的识别语言（design §16.4）
    private(set) var language: MeetingLanguage = .zh

    var hasMic: Bool { source != "system" }
    var hasSystem: Bool { source != "mic" }

    func start(meetingId: Int64, source: String = AppSettings.recordSource, language: MeetingLanguage) {
        guard !isRecording else { return }
        self.source = source
        self.language = language
        if source == "system" {
            begin(meetingId: meetingId, makeSources: makeDeviceSources)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(meetingId: meetingId, makeSources: makeDeviceSources)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.begin(meetingId: meetingId, makeSources: self.makeDeviceSources) }
                    else { self.abort(meetingId, permission: true) }
                }
            }
        default:
            abort(meetingId, permission: true)
        }
    }

    #if DEBUG
    /// 只在 DEBUG：用音频档当麦克风，验证录音流程（speed 是倍速）
    func startSimulated(meetingId: Int64, file: URL, speed: Double, both: Bool, language: MeetingLanguage) {
        guard !isRecording else { return }
        source = both ? "both" : "mic"
        self.language = language
        simulationEnded = false
        begin(meetingId: meetingId) {
            let source = FileSource(url: file, speed: speed)
            source.deviceUID = AppSettings.inputDeviceUID
            source.onEnded = { [weak self] in Task { @MainActor in self?.simulationEnded = true } }
            var list: [(Int, AudioSource)] = [(0, source)]
            if both {
                let mirror = MirroredSource()
                source.mirror = mirror
                list.append((1, mirror))
            }
            return list
        }
    }

    /// 只在 DEBUG：recordstall，某个声道停止送资料几秒，nil 是马上恢复（design §20.2）
    func simulateStall(channel: Int, seconds: Double?) {
        (sources[0] as? FileSource)?.stall(channel: channel, seconds: seconds)
    }

    /// 只在 DEBUG：recordinterrupt，等于音源发现设备变了。连续送几次，验证只会重新开始一次
    func simulateInterruption(channel: Int, times: Int = 3) {
        for _ in 0..<times { sources[channel]?.onInterruption?() }
    }

    /// 只在 DEBUG：recordflap，麦克风一直说设备变了、重新开始很慢（design §50.4）
    func simulateFlapping(times: Int, seconds: Double) {
        (sources[0] as? FileSource)?.flap(times: times, seconds: seconds)
    }

    /// state 的 recorder.restarts：每个声道 60 秒内重新连接的时间（录音开始后的秒数）、正在重新连接的声道
    var restartInfo: [String: Any] {
        let start = startedAt ?? Date()
        return ["times": Dictionary(uniqueKeysWithValues: restarts.map { ("\($0.key)", $0.value.map { (($0.timeIntervalSince(start)) * 10).rounded() / 10 }) }),
                "restarting": restarting.sorted()]
    }
    #endif

    func pause() {
        guard isRecording, !isPaused else { return }
        writer?.setPaused(true)
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        writer?.resetRecentLevels()
        resetMicFloor()
        (noisySeconds, quietSeconds) = (0, 0)
        markSpeech()   // 按了继续表示人还在，重新计时（design §35.1）
        writer?.setPaused(false)
        isPaused = false
    }

    /// 「继续录」：人还在，重新计时（R48.1）
    func continueAfterIdle() {
        guard isRecording else { return }
        markSpeech()
    }

    /// 有人在说话：重新计时，提醒收掉
    private func markSpeech() {
        lastSpeechAt = elapsed
        if idlePrompt { idlePrompt = false }
    }

    /// 每秒检查没人说话多久（design §35）：15 分钟提醒、30 分钟自动停止
    private func checkIdle(_ writer: RecordingWriter) {
        guard AppSettings.idleStop, !isPaused else { return }
        // 实时逐字稿没在跑时才看声音（打字、关门也会算，只当备用，D115）
        if !liveActive && soundsLikeSpeech(writer) { markSpeech() }
        let idle = elapsed - lastSpeechAt
        if idle >= Self.idleStopSeconds {
            log.info("recording auto-stopped after \(Int(idle))s without speech")
            stop(idleSince: lastSpeechAt)
            return
        }
        let prompt = idle >= Self.idleRemindSeconds
        if prompt != idlePrompt {
            idlePrompt = prompt
            if prompt { onIdlePrompt?() }
        }
    }

    /// 最近 1 秒有 30% 以上的音框像说话（design §35.1）：比背景（最近 30 秒的第 10 百分位）大 12 dB 而且高于 -50 dBFS，
    /// 或本身就高于 -40 dBFS（一开始就一直有人说话时，背景也是说话的音量）
    private func soundsLikeSpeech(_ writer: RecordingWriter) -> Bool {
        for channel in 0..<(source == "both" ? 2 : 1) {
            let levels = writer.recentLevels(channel)
            guard levels.count >= 20 else { continue }
            let background = levels.sorted()[Int(Double(levels.count - 1) * 0.1)]
            let threshold = min(max(background + 12, -50), -40)
            let last = levels.suffix(10)
            if Double(last.filter { $0 > threshold }.count) >= Double(last.count) * 0.3 { return true }
        }
        return false
    }

    /// 换麦克风（design §38.3、R58.2）：存成设置，录音中就接着用新的这支录（同一个文件，录音不停）
    func switchMicrophone(uid: String) {
        UserDefaults.standard.set(uid, forKey: AppSettings.inputDeviceKey)
        guard isRecording, let mic = sources[0] as? MicrophoneInput else { return }
        mic.deviceUID = uid
        log.info("switching microphone")
        restartSource(0, counted: false)
    }

    /// 蓝牙提示的「知道了」：这场录音不再出现
    func dismissMicHint() {
        micHintDismissed = true
        updateMicHint()
    }

    private func updateMicDevice() {
        let device = (sources[0] as? MicrophoneInput)?.current
        if device != micDevice {
            micDevice = device
            resetMicFloor()   // 换了一支麦克风，底噪不一样
        }
        updateMicHint()
    }

    /// 只录麦克风（现场会议）、实际收音的是蓝牙、不是用户自己指定的那支时提示（R58.3、R58.4、D130）
    private func updateMicHint() {
        var hint: MicHint?
        if isRecording, source == "mic", !micHintDismissed, let device = micDevice, device.isBluetooth,
           device.uid != AppSettings.inputDeviceUID {
            hint = MicHint(name: device.name, builtIn: MicrophoneMonitor.shared.inputs.first(where: \.isBuiltIn))
        }
        guard hint != micHint else { return }
        micHint = hint
        if let hint, !micHintNotified {
            micHintNotified = true
            onMicHint?(hint)
        }
    }

    private func resetMicFloor() {
        micFloor = nil
        pendingFloor = []
        floorHold = 0
    }

    /// 「知道了」：这一种提示这场录音不再出现
    func dismissLevelHint() {
        guard let levelHint else { return }
        dismissedLevelHints.insert(levelHint)
        self.levelHint = nil
    }

    func stop(idleSince: Double? = nil) {
        guard isRecording, let meetingId else { return }
        // 在重新连接的队列上停：等正在进行的重新连接做完，不会同时动 AVAudioEngine（design §50.2）
        let stopping = Array(sources.values)
        deviceQueue.sync { stopping.forEach { $0.stop() } }
        sources = [:]
        let duration = writer?.finish() ?? 0
        let file = writer?.url
        if writer?.writeFailed == true {
            // 写不进去时关档可能也没更新 WAV 标头的大小，照实际的文件大小补上（复原流程也是这样修）
            if let file { try? WAVRepair.repair(file) }
            failureMessage = String(localized: "录音写不进磁盘（可能是空间不足），已经停止录音。停止前录到的部分有保留，会照常转录。")
        }
        let live = live
        let reviewer = reviewer
        let finishing = live != nil || reviewer != nil
        if finishing { finishingLiveCount += 1 }
        Task {
            await live?.finish()
            await reviewer?.finish()
            if finishing { self.finishingLiveCount -= 1 }
            self.onLiveFinished?(meetingId, duration)
        }
        cleanup()
        log.info("recording stopped, \(Int(duration))s")
        onFinished?(Result(meetingId: meetingId, file: file, duration: duration, error: nil, idleSince: idleSince))
    }

    static func openPrivacySettings(_ pane: String = "Privacy_Microphone") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 内部

    private func makeDeviceSources() -> [(Int, AudioSource)] {
        switch source {
        case "system": return [(0, SystemAudioSource())]
        case "both": return [(0, MicrophoneSource(deviceUID: AppSettings.inputDeviceUID)), (1, SystemAudioSource())]
        default: return [(0, MicrophoneSource(deviceUID: AppSettings.inputDeviceUID))]
        }
    }

    private func begin(meetingId: Int64, makeSources: () -> [(Int, AudioSource)]) {
        do {
            try Paths.ensureDirectories()
            // 文件名带会议 id：当掉后可以接回原本的会议（AppModel.recoverRecordings）
            let url = Paths.recordingDir.appendingPathComponent("\(meetingId)-\(UUID().uuidString).wav")
            let channels = source == "both" ? 2 : 1
            let writer = try RecordingWriter(url: url, channels: channels)
            var started: [Int: AudioSource] = [:]
            var warnings: [String] = []
            for (channel, audioSource) in makeSources() {
                audioSource.onSamples = { [weak writer] samples in writer?.append(channel: channel, samples) }
                audioSource.onInterruption = { [weak self] in
                    Task { @MainActor in self?.scheduleRestart(channel) }
                }
                do {
                    try audioSource.start()
                    started[channel] = audioSource
                } catch {
                    warnings.append(error.localizedDescription)
                }
            }
            guard !started.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                throw CaptureError.coreAudio(warnings.first ?? String(localized: "开始录音"), -1)
            }
            if !warnings.isEmpty { failureMessage = String(localized: "有一个音源没办法启动，只录到另一个：\(warnings.joined(separator: String(localized: "；")))") }
            writer.onMix = tap.handler
            writer.start()
            self.writer = writer
            self.sources = started
            warnedLowDisk = false
            checkDiskSpace(writer, starting: true)
            self.meetingId = meetingId
            startedAt = Date()
            elapsed = 0
            elapsedSeconds = 0
            levelHint = nil
            dismissedLevelHints = []
            notifiedLevelHints = []
            micHint = nil
            micHintDismissed = false
            micHintNotified = false
            (noisySeconds, quietSeconds) = (0, 0)
            suppressedBy = nil
            resetMicFloor()
            lastSpeechAt = 0
            liveActive = false
            idlePrompt = false
            liveLines = []
            volatileText = ""
            systemSilent = false
            isPaused = false
            isRecording = true
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: String(localized: "拾音正在录音"))
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
            updateMicDevice()
            if AppSettings.liveTranscription { startLive(writer: writer, meetingId: meetingId) }
            startLanguageDetection(meetingId: meetingId)
            log.info("recording started (\(self.source, privacy: .public))")
            onStarted?()
        } catch {
            abort(meetingId, message: String(localized: "没办法开始录音：\(error.localizedDescription)"))
        }
    }

    private func startLive(writer: RecordingWriter, meetingId: Int64) {
        let language = language
        let live: any LiveTranscribing
        if AppSettings.liveTranscriptionEngine == "qwen" {
            let glossary = CompanyGlossary.merged((try? AppModel.shared.db.glossary().map(\.term)) ?? [])
            live = QwenLiveTranscriber(language: language, glossary: glossary)
        } else {
            live = LiveTranscriber(language: language)
        }
        self.live = live
        reviewedThrough = 0
        reviewStatus = String(localized: "等待音频复核…")
        liveStatus = String(localized: "正在准备实时逐字稿…")
        liveActive = false
        live.onVolatile = { [weak self, weak live] text in
            #if DEBUG
            DebugMetrics.bump("volatileUpdate")
            #endif
            guard let self, let live, self.live === live else { return }
            // 有新的字就是有人在说话（design §35.1）
            // 中文会议用简体时转成简体（design §47.2）
            let text = AppSettings.script(text, for: language)
            if !text.isEmpty && text != self.volatileText { self.markSpeech() }
            self.volatileText = text
        }
        // 中途重新开始时，新的识别从 0 秒算，要加上接上音频时已经录了多久
        let offset = LiveOffset()
        live.onFinal = { [weak self, weak live] start, end, text in
            guard let self else { return }
            let (start, end) = (start + offset.seconds, end + offset.seconds)
            let text = AppSettings.script(text, for: language)
            if let live, self.live === live {
                self.liveLines.append(LiveLine(start: start, end: end, text: text))
                if !text.isEmpty { self.markSpeech() }
            }
            self.onLiveFinal?(meetingId, start, end, text)
        }
        var failed = false
        live.onFailure = { [weak self, weak live] error in
            guard let self, let live, self.live === live else { return }
            failed = true
            // Qwen 的快稿失败时，独立复核仍可继续接收音频。
            if !(live is QwenLiveTranscriber) { self.tap.setLive(nil) }
            self.liveActive = false
            self.volatileText = ""
            self.liveStatus = String(localized: "实时逐字稿已停止（\(error.localizedDescription)），录音照常进行，录完会正式转录")
        }
        // Qwen 冷启动期间先缓存音频，避免模型加载时漏掉开场；系统识别准备好后再接。
        if live.buffersBeforeStart {
            offset.seconds = writer.recordedSeconds
            tap.setLive(live.feedHandler)
        }
        if let qwen = live as? QwenLiveTranscriber {
            configureReview(qwen, meetingId: meetingId, offset: offset)
        } else {
            let glossary = CompanyGlossary.merged((try? AppModel.shared.db.glossary().map(\.term)) ?? [])
            let reviewer = QwenLiveTranscriber(language: language, glossary: glossary, reviewOnly: true)
            self.reviewer = reviewer
            let reviewOffset = LiveOffset()
            reviewOffset.seconds = writer.recordedSeconds
            configureReview(reviewer, meetingId: meetingId, offset: reviewOffset)
            tap.setReview(reviewer.feedHandler)
            Task {
                do { try await reviewer.start() }
                catch { reviewer.onReviewFailure?(error) }
            }
        }
        Task {
            do {
                try await live.start()
                guard self.live === live else { return }   // 准备期间又换了语言
                guard !failed else { return }
                if !live.buffersBeforeStart {
                    offset.seconds = writer.recordedSeconds
                    tap.setLive(live.feedHandler)
                }
                liveStatus = ""
                liveActive = true
            } catch {
                guard self.live === live else { return }
                tap.setLive(nil)
                liveStatus = String(localized: "实时逐字稿没办法启动（\(error.localizedDescription)），录音照常进行，录完会正式转录")
                (live as? QwenLiveTranscriber)?.onReviewFailure?(error)
            }
        }
    }

    private func configureReview(_ qwen: QwenLiveTranscriber, meetingId: Int64, offset: LiveOffset) {
        let language = language
        qwen.onReviewed = { [weak self, weak qwen] start, end, text in
            guard let self else { return }
            let (start, end) = (start + offset.seconds, end + offset.seconds)
            let current = qwen != nil && (self.live === qwen || self.reviewer === qwen)
            do {
                try self.onReviewed?(meetingId, start, end, AppSettings.script(text, for: language))
                if current {
                    self.reviewedThrough = end
                    self.reviewStatus = ""
                }
            } catch {
                if current { self.reviewStatus = String(localized: "无法保存复核文字：\(error.localizedDescription)") }
            }
        }
        qwen.onReviewFailure = { [weak self, weak qwen] error in
            guard let self, let qwen, self.live === qwen || self.reviewer === qwen else { return }
            if self.reviewer === qwen { self.tap.setReview(nil) }
            self.reviewStatus = String(localized: "音频复核已停止（\(error.localizedDescription)），会中助手只分析已复核文字")
        }
    }

    // MARK: 自动检测主要语言（design §18.8、R16、D21）

    /// 开始录音后收集约 10 秒有声音的片段，判断是中文、英文还是日文；跟目前不同而且有把握才切换，只判断一次
    private func startLanguageDetection(meetingId: Int64) {
        languageSwitch = nil
        guard AppSettings.autoDetectLanguage else { return }
        let path = ModelStore.path(.languageDetection).path
        guard FileManager.default.fileExists(atPath: path) else {
            AppModel.shared.models.autoStart(.languageDetection)   // 这次来不及，下次录音就能用
            return
        }
        tap.setDetector(LanguageDetector.Collector { [weak self] samples in
            let recorder = self
            Task.detached(priority: .utility) {
                let result = Swift.Result { try LanguageDetector.detect(samples, modelPath: path) }
                await recorder?.applyDetection(result, meetingId: meetingId)
            }
        })
    }

    private func applyDetection(_ result: Swift.Result<[MeetingLanguage: Double], Error>, meetingId: Int64) {
        tap.setDetector(nil)
        guard isRecording, self.meetingId == meetingId else { return }
        switch result {
        case .success(let probabilities):
            let summary = probabilities.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
            log.info("language detection: \(summary, privacy: .public)")
            guard let (best, p) = probabilities.max(by: { $0.value < $1.value }).map({ ($0.key, $0.value) }),
                  best.profile.family != language.profile.family, p >= LanguageDetector.threshold else { return }   // 同一个语系不切（design §41.4）
            let from = language
            switchLanguage(to: best)
            languageSwitch = (from, best)
        case .failure(let error):
            log.error("language detection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 录音中换会议语言：实时逐字稿用新的语言重新开始（之前的逐字稿保留，录完会正式转录）
    func switchLanguage(to newLanguage: MeetingLanguage) {
        guard isRecording, let meetingId, let writer, newLanguage != language else { return }
        language = newLanguage
        languageSwitch = nil
        tap.setDetector(nil)
        onLanguageChange?(meetingId, newLanguage)
        guard AppSettings.liveTranscription else { return }
        tap.setLive(nil)
        // 旧的识别收尾送来的是用错的语言听的，不加进逐字稿
        let old = live
        old?.onFinal = nil
        old?.onVolatile = nil
        old?.onFailure = nil
        (old as? QwenLiveTranscriber)?.onReviewed = nil
        (old as? QwenLiveTranscriber)?.onReviewFailure = nil
        old?.cancel()
        let oldReviewer = reviewer
        oldReviewer?.onReviewed = nil
        oldReviewer?.onReviewFailure = nil
        oldReviewer?.cancel()
        reviewer = nil
        tap.setReview(nil)
        volatileText = ""
        Task {
            await old?.finish()
            await oldReviewer?.finish()
        }
        startLive(writer: writer, meetingId: meetingId)
    }

    private func tick() {
        guard let writer else { return }
        if writer.writeFailed {
            stop()
            return
        }
        // 观察的属性只在值真的变了才设（@Observable 设成同样的值也会让画面重算，design §25）
        elapsed = writer.recordedSeconds
        let seconds = Int(elapsed)
        if seconds != elapsedSeconds {
            elapsedSeconds = seconds
            checkLevels(writer)
            checkIdle(writer)
            guard isRecording else { return }   // 没人说话太久，刚自动停止
            updateDeviceWarning()   // 「一直在重新连接」1 分钟没再重新连接就收起（design §50.1）
        }
        var silent = systemSilent
        if source == "both" {
            micLevel = writer.level(0)
            systemLevel = writer.level(1)
            silent = writer.silence(1) > 15
        } else if source == "system" {
            systemLevel = writer.level(0)
            silent = writer.silence(0) > 15
        } else {
            micLevel = writer.level(0)
        }
        if silent != systemSilent { systemSilent = silent }
        watchdog(writer)
        if Date().timeIntervalSince(lastDiskCheck) >= 30 { checkDiskSpace(writer, starting: false) }
    }

    /// 收音提醒（design §26.1）：每秒看麦克风最近 30 秒的音量。第 90 百分位是说话的音量、第 10 百分位是背景
    private func checkLevels(_ writer: RecordingWriter) {
        guard hasMic, !isPaused else { return }
        let silent = writer.silence(0) > 10
        let recent = writer.recentLevels(0)
        let levels = recent.sorted()
        var speech: Float = 0, background: Float = 0
        if levels.count >= 300 {
            speech = levels[Int(Double(levels.count - 1) * 0.9)]
            background = levels[Int(Double(levels.count - 1) * 0.1)]
            noisySeconds = background > -36 ? noisySeconds + 1 : 0
            // 说话比背景大 4 dB 以上才算有人在说话（完全安静时声音很平），不是安静的停顿
            quietSeconds = speech < -50 && speech - background >= 4 ? quietSeconds + 1 : 0
        }
        // 被别的 app 的语音处理占住（design §45.1、R57）：最近 8 秒几乎没声音（完全是 0 的不算），
        // 而且是内置麦克风、或这场录音稍早的背景比现在高 12 dB 以上
        var nearSilent = false, suppressed = false
        if recent.count >= 80 {
            let tail = recent.suffix(80).sorted()
            nearSilent = tail.count(where: { $0 > -119 && $0 < -70 }) >= 72
            if nearSilent {
                quietSeconds = 0   // 不是「声音有点小」（R57.3）
                pendingFloor = []
                floorHold = 30
                suppressed = micIsBuiltIn || micFloor.map { $0 - tail[71] >= 12 } ?? false
            } else if floorHold > 0 {
                floorHold -= 1
            } else if levels.count >= 300 {
                pendingFloor.append(background)
                if pendingFloor.count > 10 {
                    let value = pendingFloor.removeFirst()
                    if value > -119 { micFloor = min(micFloor ?? value, value) }
                }
            }
        }
        let hint: LevelHint? = silent ? .silent : suppressed ? .suppressed : quietSeconds >= 60 ? .quiet : noisySeconds >= 45 ? .noisy : nil
        let shown = hint.flatMap { dismissedLevelHints.contains($0) ? nil : $0 }
        if shown != levelHint {
            // 是哪个 app 在提示出现时决定，之后不跟着变（design §45.2）
            if shown == .suppressed { suppressedBy = microphoneUser?() }
            levelHint = shown
            // 第一次出现才通知（R42.1）；提示消失又出现不再通知
            if let shown, notifiedLevelHints.insert(shown).inserted { onLevelHint?(shown) }
        }
        #if DEBUG
        levelCheck = ["speech": speech, "background": background, "frames": levels.count, "silentSeconds": writer.silence(0),
                      "noisySeconds": noisySeconds, "quietSeconds": quietSeconds, "hint": levelHint?.rawValue ?? "",
                      "nearSilent": nearSilent, "floor": micFloor ?? 0, "suppressedApp": suppressedBy?.name ?? "",
                      "text": levelHint.map { text(for: $0) } ?? ""]
        #endif
    }

    /// 正在收音的是这台 Mac 的内置麦克风；模拟录音没有真的设备，DEBUG 用 -debugMicBuiltIn YES 当成内置（design §45.4）
    private var micIsBuiltIn: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugMicBuiltIn") { return true }
        #endif
        return micDevice?.isBuiltIn == true
    }

    /// 开始录音时剩不到 1 GB、录音中剩不到 300 MB 就提醒（录音照常进行；写不进去时 tick 会停止录音）
    private func checkDiskSpace(_ writer: RecordingWriter, starting: Bool) {
        lastDiskCheck = Date()
        // ForImportantUsage 含可以清掉的空间，但磁盘映像、外接磁盘会回传 0，所以跟一般的剩余空间取大的
        guard let values = try? Paths.recordingDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return }
        let available = max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))
        guard available < (starting ? 1_000_000_000 : 300_000_000), starting || !warnedLowDisk else { return }
        if !starting { warnedLowDisk = true }
        // 16 kHz、16 比特：单声道每小时约 115 MB，双声道约 230 MB
        let bytesPerMinute = CaptureFormat.sampleRate * 2 * Double(writer.channels) * 60
        let minutes = Int(Double(available) / bytesPerMinute)
        let size = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        log.info("low disk space: \(available / 1_000_000) MB")
        let message = String(localized: "磁盘只剩 \(size)，大约只能录 \(minutes) 分钟。空间用完时会自动停止录音，已经录到的部分会保留。")
        failureMessage = failureMessage.map { $0 + "\n\n" + message } ?? message
    }

    // MARK: 换设备、看门狗（design §20.2、R18.2、D25；节奏 §50.1）

    /// 60 秒内已经重新连接 n 次，下一次等多久：前两次 0.3 秒，之后 2、4、8、16 秒，最多 30 秒（design §50.1、R74.2）
    nonisolated static func restartDelay(_ n: Int) -> Double {
        n < 3 ? 0.3 : min(30, pow(2, Double(n - 2)))
    }

    /// 这个声道 60 秒内重新连接了几次（顺便丢掉更早的）
    private func recentRestarts(_ channel: Int, now: Date = Date()) -> Int {
        restarts[channel] = restarts[channel]?.filter { now.timeIntervalSince($0) < 60 }
        return restarts[channel]?.count ?? 0
    }

    /// 设备切换时通知会连续来好几次，等一下没有新的通知再重新开始；一直重新连接时等久一点
    private func scheduleRestart(_ channel: Int) {
        guard isRecording else { return }
        pendingRestarts[channel]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingRestarts[channel] = nil
                self?.restartSource(channel)
            }
        }
        pendingRestarts[channel] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay(recentRestarts(channel)), execute: item)
    }

    /// 在背景队列重新开始（design §50.2）：蓝牙设备开始收音要好几秒，不能卡住画面。
    /// counted：算进重新连接的次数（用户换麦克风不算）
    private func restartSource(_ channel: Int, counted: Bool = true) {
        guard isRecording, let audioSource = sources[channel] else { return }
        if counted { restarts[channel, default: []].append(Date()) }
        guard !restarting.contains(channel) else {
            restartAgain.insert(channel)
            return
        }
        restarting.insert(channel)
        let box = SourceBox(source: audioSource)
        deviceQueue.async { [weak self] in
            let failure: Error?
            do { try box.source.restart(); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishRestart(channel, box.source, failure) }
            }
        }
    }

    private func finishRestart(_ channel: Int, _ audioSource: AudioSource, _ failure: Error?) {
        restarting.remove(channel)
        // 录音已经停了（音源在 stop() 停掉了）：结果丢掉
        guard isRecording, sources[channel] === audioSource else {
            restartAgain.remove(channel)
            return
        }
        restartedAt[channel] = Date()
        if let failure {
            // 录音不停：另一个音源照常录，双声道时这段会补静音；看门狗再试
            reconnectErrors[channel] = failure.localizedDescription
            log.error("audio source \(channel) restart failed: \(failure.localizedDescription, privacy: .public)")
        } else {
            reconnectErrors[channel] = nil
            log.info("audio source \(channel) restarted")
        }
        if channel == 0 { updateMicDevice() }
        updateDeviceWarning()
        if restartAgain.remove(channel) != nil { restartSource(channel, counted: false) }
    }

    /// 音源超过 3 秒没送资料：提示并重新连接；重新连接完 5 秒内、正在重新连接时不再重开（R74.1），
    /// 重试的间隔 max(5, 重新连接的节奏)；收到资料后提示消失
    private func watchdog(_ writer: RecordingWriter) {
        #if DEBUG
        if simulationEnded { return }
        #endif
        let now = Date()
        for channel in sources.keys.sorted() {
            if writer.secondsSinceSamples(channel) > 3 {
                if reconnecting[channel] == nil {
                    log.info("audio source \(channel) stalled")
                    reconnecting[channel] = .distantPast
                    updateDeviceWarning()
                }
                guard !restarting.contains(channel), pendingRestarts[channel] == nil else { continue }
                if let done = restartedAt[channel], now.timeIntervalSince(done) < 5 { continue }
                let interval = max(5, Self.restartDelay(recentRestarts(channel, now: now)))
                if let last = reconnecting[channel], now.timeIntervalSince(last) < interval { continue }
                reconnecting[channel] = now
                restartSource(channel)
            } else if reconnecting[channel] != nil {
                reconnecting[channel] = nil
                reconnectErrors[channel] = nil
                log.info("audio source \(channel) recovered")
                updateDeviceWarning()
            }
        }
    }

    /// 提示列（design §50.1）：重新连接失败的原因 ＞ 一直在重新连接（60 秒内 3 次以上）＞ 正在重新连接…
    private func updateDeviceWarning() {
        let isMic = { (channel: Int) in self.source != "system" && channel == 0 }
        let stalled = reconnecting.keys.sorted().first
        let flapping = sources.keys.sorted().first { recentRestarts($0) >= 3 }
        var warning: String?
        if let channel = stalled, let reason = reconnectErrors[channel] {
            warning = isMic(channel) ? String(localized: "麦克风没有送出声音，重新连接失败：\(reason)。会继续重试，录音没有停")
                : String(localized: "电脑声音的截取中断了，重新连接失败：\(reason)。会继续重试，录音没有停")
        } else if let channel = flapping {
            warning = isMic(channel) ? String(localized: "麦克风一直在重新连接，录音可能断断续续。蓝牙耳机的麦克风常这样，可以点上面的麦克风名称换成内置麦克风。")
                : String(localized: "电脑声音的截取一直在重新连接，录音可能断断续续。")
        } else if let channel = stalled {
            warning = isMic(channel) ? String(localized: "麦克风没有送出声音，正在重新连接…") : String(localized: "电脑声音的截取中断了，正在重新连接…")
        }
        if warning != deviceWarning { deviceWarning = warning }
    }

    private func abort(_ meetingId: Int64, permission: Bool = false, message: String? = nil) {
        if permission { permissionDenied = true }
        if let message { failureMessage = message }
        onFinished?(Result(meetingId: meetingId, file: nil, duration: 0, error: nil))
    }

    private func cleanup() {
        meterTimer?.invalidate()
        meterTimer = nil
        pendingRestarts.values.forEach { $0.cancel() }
        pendingRestarts = [:]
        restarts = [:]
        restartedAt = [:]
        restarting = []
        restartAgain = []
        reconnecting = [:]
        reconnectErrors = [:]
        deviceWarning = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        writer = nil
        live = nil
        reviewer = nil
        tap.setLive(nil)
        tap.setReview(nil)
        tap.setDetector(nil)
        languageSwitch = nil
        levelHint = nil
        micHint = nil
        micDevice = nil
        idlePrompt = false
        liveActive = false
        meetingId = nil
        startedAt = nil
        isRecording = false
        isPaused = false
        micLevel = 0
        systemLevel = 0
        volatileText = ""
        liveStatus = ""
        reviewStatus = ""
        reviewedThrough = 0
    }
}

/// 交给背景队列重新开始的音源（design §50.2）：同一个音源的重新开始、停止都在 Recorder 的 deviceQueue 上，不会同时
private struct SourceBox: @unchecked Sendable {
    let source: AudioSource
}

/// 录音的单声道混音要同时送给实时逐字稿和语言检测；写档的线程调用 handler，主线程换掉接收端
final class MixTap: @unchecked Sendable {
    private let lock = NSLock()
    private var live: (([Float]) -> Void)?
    private var review: (([Float]) -> Void)?
    private var detector: LanguageDetector.Collector?

    func setLive(_ handler: (([Float]) -> Void)?) { lock.withLock { live = handler } }
    func setReview(_ handler: (([Float]) -> Void)?) { lock.withLock { review = handler } }
    func setDetector(_ collector: LanguageDetector.Collector?) { lock.withLock { detector = collector } }

    var handler: ([Float]) -> Void {
        { [weak self] samples in
            guard let self else { return }
            let (live, review, detector) = self.lock.withLock { (self.live, self.review, self.detector) }
            live?(samples)
            review?(samples)
            detector?.feed(samples)
        }
    }
}

/// 一个实时识别的时间偏移（design §18.8）
@MainActor
private final class LiveOffset {
    var seconds: Double = 0
}
