import Foundation
import GRDB

extension AppModel {
    func openPreparation(_ id: Int64? = nil) {
        preparationMeetingId = id
        showPreparationSheet = true
    }

    @discardableResult
    func saveMeetingPreparation(id: Int64?, title: String, preparation: MeetingPreparation) -> Int64? {
        guard !recorder.isRecording else {
            errorMessage = String(localized: "请先停止录音，再修改会前准备")
            return nil
        }
        guard preparation.hasContext else {
            errorMessage = String(localized: "请填写会议主要内容或本场目标")
            return nil
        }
        var created: Int64?
        do {
            let mid: Int64
            let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            if let id, var meeting = try db.meeting(id), meeting.deletedAt == nil {
                meeting.title = title
                meeting.titleLocked = !title.isEmpty
                try db.updateMeeting(meeting)
                mid = id
            } else if id == nil {
                let meeting = try db.insertMeeting(Meeting(title: title, titleLocked: !title.isEmpty,
                    meetingDate: DateText.string(Date()), sourceFilename: String(localized: "准备会议"),
                    templateId: AppSettings.defaultTemplate, source: "prepared", folder: currentFolder,
                    language: AppSettings.defaultMeetingLanguage.rawValue), audioExtension: nil)
                mid = meeting.id!
                created = mid
            } else { return nil }
            try db.savePreparation(mid, preparation)
            reload()
            showTrash = false
            selection = mid
            reloadAssistance(mid)
            return mid
        } catch {
            if let created { try? db.deleteMeeting(created) }
            errorMessage = String(localized: "无法保存会前准备：\(error.localizedDescription)")
            return nil
        }
    }

    func selectedPreparedMeeting() throws -> Meeting? {
        guard let id = selection, let meeting = try db.meeting(id), meeting.source == "prepared", meeting.deletedAt == nil else { return nil }
        return meeting
    }

    func preservePreparationOrDelete(_ id: Int64) throws {
        if try db.assistance(id) != nil, var meeting = try db.meeting(id) {
            meeting.source = "prepared"
            meeting.audioFile = ""
            meeting.durationSeconds = nil
            try db.updateMeeting(meeting)
            try db.resetCoachProgress(id)
            try db.pool.write { db in
                try db.execute(sql: "DELETE FROM segments WHERE meeting_id = ? AND kind = 'live'", arguments: [id])
            }
        } else { try db.deleteMeeting(id) }
    }

    func reloadAssistance(_ id: Int64) {
        guard selection == id else { return }
        let value = try? db.assistance(id)
        if meetingAssistance != value { meetingAssistance = value }
    }

    func setCoachEnabled(_ id: Int64, enabled: Bool) {
        do {
            try db.setCoachEnabled(id, enabled)
            if !enabled && coach.meetingId == id { coach.cancelRequest() }
            reloadAssistance(id)
            if enabled { coach.analyze(id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func markCoachQuestion(_ id: Int64, question: String, status: CoachQuestion.Status) {
        do {
            try db.setCoachQuestion(id, question: question, status: status)
            reloadAssistance(id)
        } catch { errorMessage = error.localizedDescription }
    }
}
