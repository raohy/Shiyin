import SwiftUI

/// 头像（design §58.2、R83）：圆形的釉色底，写名字的第一个字。
/// 会议里的说话者用 `Color.speaker(编号)`，人物页、侧栏用 `Color.person(名字)`
struct PersonAvatar: View {
    @Environment(\.textScale) private var textScale
    let name: String
    let color: Color
    var size: CGFloat = 18
    var isMe = false
    /// 会议内容里的头像跟着文字大小（R59）放大；侧栏、人物页的标题不跟
    var scales = true

    var body: some View {
        let diameter = size * (scales ? textScale : 1)
        Text(Self.initials(name))
            .font(.system(size: diameter * 0.46, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: diameter, height: diameter)
            .background(color.opacity(0.18), in: Circle())
            .overlay {
                // 「我」（R80）外圈一圈青瓷绿
                if isMe { Circle().strokeBorder(Color.celadon, lineWidth: min(2, max(1.5, diameter / 14))) }
            }
            .accessibilityHidden(true)
    }

    /// 写在头像上的字：默认名称写数字；中日韩文字取第一个字；其他取前两段的第一个字母
    static func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let scalar = first.unicodeScalars.first else { return "?" }
        if AppDatabase.isDefaultSpeakerName(trimmed) {
            let digits = trimmed.filter(\.isNumber)
            if !digits.isEmpty { return String(digits.prefix(2)) }
        }
        if isCJK(scalar) { return String(first) }
        let words = trimmed.split { $0.isWhitespace || $0 == "-" || $0 == "." || $0 == "_" }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? String(first) : letters.joined()
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

extension Color {
    /// 人物页、侧栏的头像颜色（design §58.1）：照名字算，同一个名字每次都一样
    static func person(_ name: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return speaker(Int(hash % 8) + 1)
    }
}
