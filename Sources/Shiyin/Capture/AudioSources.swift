import AVFoundation
import CoreAudio
import Foundation
import Observation

/// 所有音源输出的统一格式：16 kHz、单声道、Float32（design §5.1）
enum CaptureFormat {
    static let sampleRate: Double = 16_000
    static let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
}

/// 音源：把收到的音频转成 16 kHz 单声道后交给 `onSamples`。callback 在音频线程上，不能做重的事。
protocol AudioSource: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    /// 音源发现设备变了（design §20.2），任何线程都可能调用；Recorder 收到后会 `restart()`
    var onInterruption: (() -> Void)? { get set }
    func start() throws
    func stop()
    func restart() throws
}

extension AudioSource {
    func restart() throws {
        stop()
        try start()
    }
}

/// 麦克风那一声道的音源（design §38.3）：可以换设备，看得到实际在收音的是哪一支
protocol MicrophoneInput: AudioSource {
    /// 指定的输入设备 UID，空字符串是系统默认；改了之后 `restart()` 才生效
    var deviceUID: String { get set }
    /// 实际在收音的设备（指定的不在时是系统默认）；`start()` 成功后才有
    var current: AudioDevices.Device? { get }
}

/// 把任意格式的 buffer 持续转成 16 kHz 单声道（保留重采样的状态，适合串流）
final class StreamConverter {
    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: format, to: CaptureFormat.mono) else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = CaptureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: CaptureFormat.mono, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// 麦克风（AVAudioEngine）。可以指定输入设备的 UID，空字符串表示系统默认。
final class MicrophoneSource: MicrophoneInput {
    var onSamples: (([Float]) -> Void)?
    var onInterruption: (() -> Void)?
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var deviceUID: String
    private(set) var current: AudioDevices.Device?

    init(deviceUID: String) {
        self.deviceUID = deviceUID
    }

    /// 每次开始都用新的 engine：重新开始时重读输入格式；指定的设备不在了，新的 engine 就跟着系统默认（design §20.2）
    func start() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID) {
            try input.auAudioUnit.setDeviceID(id)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = StreamConverter(from: format) else {
            throw CaptureError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples) }
        }
        // 接上或拔掉耳机、蓝牙换协定、采样率改变时，engine 会自己停下来并送出这个通知
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onInterruption?()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        current = AudioDevices.device(id: input.auAudioUnit.deviceID)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// 电脑播放的声音（Core Audio process tap，macOS 14.4+，design §5.1）
final class SystemAudioSource: AudioSource {
    var onSamples: (([Float]) -> Void)?
    var onInterruption: (() -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.weiwei.shiyin.systemaudio", qos: .userInitiated)
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        // 排除自己（播放录音时不要录进去）
        let own = AudioDevices.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), String(localized: "创建系统声音截取"))

        guard let outputUID = AudioDevices.defaultOutputUID() else { throw CaptureError.noOutputDevice }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: String(localized: "拾音系统声音"),
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), String(localized: "创建聚合设备"))

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), String(localized: "读取系统声音格式"))
        guard let format = AVAudioFormat(streamDescription: &asbd), let converter = StreamConverter(from: format) else {
            throw CaptureError.unsupportedFormat
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples) }
        }, String(localized: "创建系统声音的 IO"))
        try check(AudioDeviceStart(aggregateID, procID), String(localized: "开始截取系统声音"))
        // 默认输出换了（接上耳机、换成蓝牙喇叭）：聚合设备还绑着旧的输出，要用新的重建（design §20.2）
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onInterruption?() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener) == noErr {
            outputListener = listener
        }
    }

    /// 一定要依序清干净，否则 HAL 可能卡住（design §5.1）
    func stop() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, outputListener)
        }
        outputListener = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr {
            stop()
            throw CaptureError.coreAudio(step, status)
        }
    }
}

#if DEBUG
/// 只在 DEBUG：用音频档模拟音源，speed 是播放倍速（验证录音流程用，见 design §13 of v2）
final class FileSource: MicrophoneInput {
    var onSamples: (([Float]) -> Void)?
    var onInterruption: (() -> Void)?
    /// 模拟录音的麦克风（design §38.7）：照 `MicrophoneMonitor` 的清单（含 `fakemic` 的假设备）决定是哪一支
    var deviceUID = ""
    private(set) var current: AudioDevices.Device?
    /// 模拟「麦克风＋电脑声音」时，同一段音频在同一个循环里也送给第二个声道。
    /// 两个声道各开一个 FileSource 的话，高倍速时两边的速度会不一样，造成真实设备不会有的「晚到」
    var mirror: MirroredSource?
    /// 文件送完了：之后没有资料是正常的，不是设备停了
    var onEnded: (() -> Void)?
    private let url: URL
    private let speed: Double
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var samples: [Float]?
    private var position = 0
    private var stalledUntil: [Int: Double] = [:]   // 声道 → 恢复送资料的时间（systemUptime）

    init(url: URL, speed: Double) {
        self.url = url
        self.speed = speed
    }

    /// 从上次停下的位置接着送，所以 restart()（stop 再 start）等于继续送
    func start() throws {
        let uid = deviceUID
        current = MainActor.assumeIsolated { MicrophoneMonitor.shared.resolve(uid) }
        let url = url, speed = speed
        task = Task.detached { [weak self] in
            guard let self else { return }
            var decoded = self.lock.withLock { self.samples }
            if decoded == nil { decoded = try? await AudioDecoder.decode(url) }
            guard let samples = decoded else { return }
            self.lock.withLock { self.samples = samples }
            let chunk = Int(CaptureFormat.sampleRate / 10)    // 0.1 秒一段
            while !Task.isCancelled {
                let (start, stalled) = self.lock.withLock { () -> (Int, Set<Int>) in
                    let now = ProcessInfo.processInfo.systemUptime
                    return (self.position, Set(self.stalledUntil.filter { $0.value > now }.keys))
                }
                guard start < samples.count else {
                    self.onEnded?()
                    return
                }
                let end = min(samples.count, start + chunk)
                let chunk = Array(samples[start..<end])
                // 先记下位置再送：restart() 时新的 task 不会重送同一段
                self.lock.withLock { self.position = end }
                // 停住的声道照样往前走（时间在过），只是没有送出资料，跟真的设备停了一样
                if !stalled.contains(0) { self.onSamples?(chunk) }
                if !stalled.contains(1) { self.mirror?.onSamples?(chunk) }
                try? await Task.sleep(for: .seconds(0.1 / speed))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// recordstall：这个声道停止送资料几秒（nil 是马上恢复）。restart() 不会提早恢复，模拟设备真的停了（design §20.2）
    func stall(channel: Int, seconds: Double?) {
        lock.withLock { stalledUntil[channel] = seconds.map { ProcessInfo.processInfo.systemUptime + $0 } }
    }
}

/// 只负责接收 FileSource 转送的音频，自己不产生资料
final class MirroredSource: AudioSource {
    var onSamples: (([Float]) -> Void)?
    var onInterruption: (() -> Void)?
    func start() throws {}
    func stop() {}
}
#endif

enum CaptureError: LocalizedError {
    case noInput
    case noOutputDevice
    case unsupportedFormat
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: return String(localized: "找不到可以用的麦克风")
        case .noOutputDevice: return String(localized: "找不到输出设备，没办法截取系统声音")
        case .unsupportedFormat: return String(localized: "不支持这个音频格式")
        case .coreAudio(let step, let status): return String(localized: "\(step)失败（错误代码 \(status)）。请确认已允许拾音「录制系统音频」")
        }
    }
}

/// Core Audio 设备查询
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        var id: String { uid }
        var uid: String
        var name: String
        /// 连接方式（`kAudioDevicePropertyTransportType`）：蓝牙、内置、USB…
        var transport: UInt32 = 0
        /// 输入的 data source（`kAudioDevicePropertyDataSource`）：内置的麦克风是 imic，耳机孔的「外接麦克风」是 emic
        var dataSource: UInt32 = 0

        var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
        /// 这台 Mac 本身的麦克风。耳机孔的输入连接方式也是内置，要用 data source 排除（2026-11-02：插着有线耳机时，
        /// 蓝牙提示的按钮变成「改用 外接麦克风」）
        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn && dataSource != AudioDevices.externalMicSource }
    }

    /// 四字码 emic（外接麦克风）
    static let externalMicSource: UInt32 = 0x656D_6963

    static func inputDevices() -> [Device] {
        allDevices().compactMap { id in hasInputStreams(id) ? device(id: id) : nil }
    }

    static func device(id: AudioDeviceID) -> Device? {
        guard id != kAudioObjectUnknown, let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        var source: UInt32 = 0
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source)
        return Device(uid: uid, name: name, transport: transport, dataSource: source)
    }

    /// 系统默认的输入设备
    static func defaultInput() -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return device(id: id)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// 这台电脑的麦克风清单和系统默认（design §38.1）：接上、拔掉设备或系统换了默认就更新。
/// 录音按钮的菜单、录音画面、设置页共用
@MainActor @Observable
final class MicrophoneMonitor {
    static let shared = MicrophoneMonitor()

    private(set) var inputs: [AudioDevices.Device] = []
    private(set) var defaultInput: AudioDevices.Device?
    #if DEBUG
    /// shiyinctl fakemic：假的麦克风（只在内存，模拟录音用，design §38.7）；`fakeDefault` 是假装的系统默认
    var fakes: [AudioDevices.Device] = [] { didSet { refresh() } }
    var fakeDefault: String? { didSet { refresh() } }
    #endif

    private init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// 值真的变了才设（design §25）
    func refresh() {
        var list = AudioDevices.inputDevices()
        var preset = AudioDevices.defaultInput()
        #if DEBUG
        list += fakes
        if let fakeDefault { preset = list.first { $0.uid == fakeDefault } }
        #endif
        if list != inputs { inputs = list }
        if preset != defaultInput { defaultInput = preset }
    }

    /// 这个设置实际会用哪一支：指定的在就用它，不在或没指定就是系统默认
    func resolve(_ uid: String) -> AudioDevices.Device? {
        (uid.isEmpty ? nil : inputs.first { $0.uid == uid }) ?? defaultInput
    }

    /// 菜单的 `.id`：清单或默认变了就换一个新的菜单（工具列的菜单创建一次就不更新）
    var signature: String { inputs.map(\.uid).joined(separator: ",") + "|" + (defaultInput?.uid ?? "") }
}
