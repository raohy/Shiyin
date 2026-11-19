import Foundation

/// 编辑会议（R107、design §81）：打开编辑画面、套用、还原、30 天后清掉编辑前的录音
extension AppModel {
    /// 不能编辑的原因（R107.1）；nil 是可以
    func editProblem(_ id: Int64) -> String? {
        guard let meeting = meetings.first(where: { $0.id == id })?.meeting ?? (try? db.meeting(id)) else { return "" }
        if recorder.meetingId == id && recorder.isRecording { return String(localized: "这场会议还在录音，请先停止录音再编辑") }
        if meeting.deletedAt != nil { return String(localized: "垃圾桶里的会议要先还原才能操作") }
        if applyingEdit != nil || (try? db.hasActiveJobs(id)) == true { return String(localized: "正在处理这场会议，完成后才能编辑") }
        return nil
    }

    /// 「编辑会议…」（右键、「⋯」、更多）：选到那场、打开编辑画面
    func requestEditMeeting(_ id: Int64) {
        if let problem = editProblem(id) {
            if !problem.isEmpty { noticeMessage = problem }
            return
        }
        if selection != id { selection = id }
        editingMeeting = id
    }

    /// 合并时可以选的会议（§81.5）：不在垃圾桶、不是这场、不在录音或处理中；同一天、前后三天的在前面
    func mergeCandidates(for id: Int64) -> (near: [MeetingRow], older: [MeetingRow]) {
        guard let base = meetings.first(where: { $0.id == id })?.meeting,
              let day = DateText.date(base.meetingDate) else { return ([], []) }
        let rows = meetings.filter { row in
            row.id != id && !(recorder.meetingId == row.id && recorder.isRecording) && (try? db.hasActiveJobs(row.id)) != true
        }
        func distance(_ row: MeetingRow) -> Double {
            DateText.date(row.meeting.meetingDate).map { abs($0.timeIntervalSince(day)) / 86_400 } ?? .infinity
        }
        let near = rows.filter { distance($0) <= 3 }.sorted { distance($0) < distance($1) }
        let older = rows.filter { distance($0) > 3 }
        return (near, older)
    }

    /// 套用（R107.7）：背景接好录音（分成两场时前后各一个档），一个交易改数据库，再换文件、复制参考文件、排刷新
    func applyMeetingEdit(_ id: Int64, plan: EditPlan, cut: Double?) {
        if let problem = editProblem(id) {
            if !problem.isEmpty { noticeMessage = problem }
            return
        }
        guard let meeting = try? db.meeting(id) else { return }
        var sources: [Int64: URL] = [:]
        var titles: [Int64: String] = [:]
        for meetingId in Set(plan.pieces.map(\.meetingId)) {
            guard let m = meetingId == id ? meeting : try? db.meeting(meetingId) else { continue }
            if m.hasAudio { sources[meetingId] = m.audioURL }
            titles[meetingId] = m.displayTitle
        }
        let splitTitle = String(localized: "\(meeting.displayTitle)（2）")
        let parts = cut.flatMap { plan.split(at: $0) }
        applyingEdit = id
        Task {
            defer { applyingEdit = nil }
            var temps: [URL] = []
            defer { temps.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
            do {
                let head = try await Task.detached(priority: .userInitiated) {
                    try await AudioEdit.compose(parts?.head ?? plan, sources: sources)
                }.value
                let tail = try await Task.detached(priority: .userInitiated) { () async throws -> URL? in
                    guard let parts else { return nil }
                    return try await AudioEdit.compose(parts.tail, sources: sources)
                }.value
                temps = [head, tail].compactMap { $0 }
                guard let outcome = try db.applyEdit(id, plan: plan, cut: parts == nil ? nil : cut, splitTitle: splitTitle,
                                                     audioExtension: head?.pathExtension) else { return }
                if selection == id { player.unload() }
                try replaceAudio(meeting, with: head, firstEdit: outcome.firstEdit)
                if let tail, let created = outcome.created { try FileManager.default.moveItem(at: tail, to: created.audioURL) }
                for copy in outcome.documentCopies {
                    let from = Paths.documentsDir.appendingPathComponent(copy.from), to = Paths.documentsDir.appendingPathComponent(copy.to)
                    try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: from, to: to)
                }
                let others = titles.filter { $0.key != id }.map(\.value)
                var message: String
                if let created = outcome.created {
                    message = String(localized: "已分成两场：「\(created.displayTitle)」")
                } else if let other = others.first {
                    message = String(localized: "已合并「\(other)」，那场移到垃圾桶")
                } else {
                    message = String(localized: "已编辑「\(meeting.displayTitle)」")
                }
                if AppSettings.summarizerReady {
                    try db.enqueue(id, kind: .summarize)
                    if let created = outcome.created { try db.enqueue(created.id!, kind: .summarize) }
                    runner.wake()
                    message += String(localized: "。会议记录正在刷新")
                } else {
                    message += String(localized: "。会议记录要刷新，设置好整理工具后按「刷新」")
                }
                reload()
                if selection == id { reloadDetail(forceAudio: true) }
                noticeMessage = message
            } catch {
                errorMessage = String(localized: "编辑会议失败：\(error.localizedDescription)")
                reload()
            }
        }
    }

    /// 换上新的录音：第一次编辑时原本的录音搬到 audio/edits/（还原用），之后的编辑旧的直接删
    private func replaceAudio(_ meeting: Meeting, with new: URL?, firstEdit: Bool) throws {
        let fm = FileManager.default
        if meeting.hasAudio {
            if firstEdit {
                let ext = meeting.audioURL.pathExtension
                let kept = Paths.editsAudioDir.appendingPathComponent("\(meeting.id!).\(ext)")
                try fm.createDirectory(at: Paths.editsAudioDir, withIntermediateDirectories: true)
                try? fm.removeItem(at: kept)
                try fm.moveItem(at: meeting.audioURL, to: kept)
            } else {
                try fm.removeItem(at: meeting.audioURL)
            }
        }
        if let new {
            let destination = Paths.audioDir.appendingPathComponent("\(meeting.id!).\(new.pathExtension)")
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: new, to: destination)
        }
    }

    /// 「还原成编辑前的样子…」要确认（R107.8）
    func requestRestoreEdit(_ id: Int64) {
        guard (try? db.editRecord(id)) ?? nil != nil else {
            noticeMessage = String(localized: "这场会议没有编辑过。编辑会议后 30 天内可以从这里还原。")
            return
        }
        if let problem = editProblem(id) {
            if !problem.isEmpty { noticeMessage = problem }
            return
        }
        confirmRestoreEdit = id
    }

    /// 还原确认弹窗的说明：原本多长、编辑后的修改会不见、分出去的会议移到垃圾桶、合并进来的从垃圾桶拿出来
    func restoreEditMessage(_ id: Int64) -> String {
        guard let record = try? db.editRecord(id),
              let snapshot = try? JSONDecoder().decode(EditSnapshot.self, from: Data(record.snapshot.utf8)) else { return "" }
        var lines = [String(localized: "会议会回到编辑前的样子（原本 \(TimeFormat.string(Double(snapshot.durationSeconds ?? 0)))），录音、逐字稿、标记重点、会议记录都换回来。"),
                     String(localized: "编辑之后对逐字稿、说话者、笔记的修改会不见。")]
        for other in record.splitIds {
            if let m = try? db.meeting(other), m.deletedAt == nil { lines.append(String(localized: "分出去的「\(m.displayTitle)」会移到垃圾桶。")) }
        }
        for other in record.mergedIds {
            if let m = try? db.meeting(other), m.deletedAt != nil { lines.append(String(localized: "合并进来的「\(m.displayTitle)」会从垃圾桶还原。")) }
        }
        return lines.map { "・" + $0 }.joined(separator: "\n")  // l10n-skip
    }

    func restoreMeetingEdit(_ id: Int64) {
        if let problem = editProblem(id) {
            if !problem.isEmpty { noticeMessage = problem }
            return
        }
        applyingEdit = id
        defer { applyingEdit = nil }
        do {
            if selection == id { player.unload() }
            guard let outcome = try db.restoreEdit(id) else { return }
            let fm = FileManager.default
            if !outcome.currentAudio.isEmpty { try? fm.removeItem(at: Paths.audioDir.appendingPathComponent(outcome.currentAudio)) }
            if !outcome.editsAudio.isEmpty {
                let destination = Paths.audioDir.appendingPathComponent(outcome.restoredAudio)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: Paths.audioDir.appendingPathComponent(outcome.editsAudio), to: destination)
            }
            outcome.removedDocuments.forEach(db.removeDocumentFile)
            var message = String(localized: "已还原成编辑前的样子")
            if !outcome.trashed.isEmpty { message += String(localized: "，分出去的会议移到垃圾桶") }
            if !outcome.untrashed.isEmpty { message += String(localized: "，合并进来的会议已从垃圾桶拿出来") }
            reload()
            if selection == id { reloadDetail(forceAudio: true) }
            noticeMessage = message
        } catch {
            errorMessage = String(localized: "还原失败：\(error.localizedDescription)")
            reload()
        }
    }

    /// 最后一次编辑超过 30 天：删掉编辑前的录音和快照（R107.8）；audio/edits/ 里没人用的档（会议永久删除了）一起删
    func purgeExpiredEdits() {
        let fm = FileManager.default
        for record in (try? db.expiredEdits(olderThan: MeetingEditRecord.keepDays)) ?? [] {
            if !record.audioFile.isEmpty { try? fm.removeItem(at: Paths.audioDir.appendingPathComponent(record.audioFile)) }
            try? db.deleteEditRecord(record.meetingId)
        }
        guard let keep = try? db.editAudioFiles(),
              let files = try? fm.contentsOfDirectory(atPath: Paths.editsAudioDir.path) else { return }
        for name in files where !keep.contains("edits/" + name) {
            try? fm.removeItem(at: Paths.editsAudioDir.appendingPathComponent(name))
        }
    }
}
