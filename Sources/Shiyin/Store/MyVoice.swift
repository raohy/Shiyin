import Foundation

/// 录一段自己的声音（design §56、R80）
extension AppModel {
    /// 算声纹、存成「我」的一份 enroll 声纹
    func enrollVoice(name: String, samples: [Float]) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let embedding = try await VoiceEnrollment.voiceprint(samples)
        try db.enrollVoiceprint(name: trimmed, embedding: embedding)
        reloadPeople()
        noticeMessage = String(localized: "已记住你的声音：之后的会议听到像你的声音，会带入「\(trimmed)」或在待确认问你")
    }

    /// 只删那份声纹，这个人和会议里的名字照旧（R80.4）
    func deleteEnrollment() {
        perform { try db.deleteEnrollment() }
        reloadPeople()
    }

    /// 名字的默认值：已经录过的那个人，不然是这台电脑的用户名（R80.1）
    var enrollmentDefaultName: String {
        people.first(where: { $0.enrolledAt != nil })?.name ?? NSFullUserName()
    }
}
