import Foundation

/// 目前有几个 whisper context 还没释放（转录、语言检测）。结束 app 时要等它归零：
/// whisper.cpp 还在 GPU 上算的时候 exit，静态解构会在 ggml_metal_device_free 里 abort（design §20.12）
enum WhisperContexts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func opened() { lock.withLock { count += 1 } }
    static func closed() { lock.withLock { count -= 1 } }
    static var active: Int { lock.withLock { count } }
}
