#if DEBUG
import FluidAudio
import AVFoundation
import CoreAudio
import AppKit
import SwiftUI
import UserNotifications

/// 只在 DEBUG 建置存在的控制通道：让验证脚本在不操作画面（例如屏幕锁定）时也能触发功能。
/// 用 scripts/dev/shiyinctl 送命令；结果写到命令指定的文件。正式版（release）不会编进这段程序。
@MainActor
enum DebugControl {
    static let notificationName = Notification.Name(ProcessInfo.processInfo.environment["SHIYIN_DEBUG_CHANNEL"] ?? "com.weiwei.shiyin.debug")
    static let separator: Character = "\u{1F}"
    /// quit 命令：结束时不跳确认对话框，直接当成按了「结束」
    static var confirmQuit = false

    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { handle(command.split(separator: separator, omittingEmptySubsequences: false).map(String.init)) }
        }
        DebugMetrics.startMainThreadWatch()
        log.info("debug control installed")
    }

    private static func handle(_ args: [String]) {
        let model = AppModel.shared
        guard let name = args.first else { return }
        let id = args.count > 1 ? Int64(args[1]) : nil
        switch name {
        case "coach": coachCommand(Array(args.dropFirst()))
        case "select": model.showTrash = false; model.selection = id
        // notesview list|mindmap|people：记录标签页切换成条列、心智图或人物（design §42.5；写进共用设置，测完 defaults delete com.weiwei.shiyin notesView）
        case "notesview":
            let view = args.count > 1 ? args[1].lowercased() : "list"
            UserDefaults.standard.set(view == "mindmap" ? "mindMap" : view == "people" ? "people" : "list", forKey: AppSettings.notesViewKey)
        case "tab":   // tab <summary|transcript|ask>；旧名称 topics、review、notes 当别名（review 顺便展开待确认、notes 展开我的笔记，design §33.1）
            if let r = DetailTab.resolve(args[1]) {
                model.tab = r.tab
                if r.expandReview { model.reviewExpanded = true }
                if r.expandNotes { model.userNotesExpanded = true }
            }
        case "cancel": model.selection = id; model.cancelJobs()
        case "retry": model.selection = id; model.retry()
        case "retranscribe": model.selection = id; model.retranscribe()
        case "resummarize": model.selection = id; model.resummarize()
        case "peoplenotes": model.selection = id; model.generatePeopleNotes()   // 「人物」的「产生每个人的重点」（design §66）
        case "cleantranscript": model.selection = id; model.generateCleanTranscript()   // 逐字稿「精简」的「产生精简版」（design §70）
        case "transcriptview": UserDefaults.standard.set(args[1] == "clean" ? "clean" : "original", forKey: AppSettings.transcriptViewKey)
        case "reload": model.reloadPeopleOverview(); model.reload()   // 直接改数据库之后重读
        // 文件夹自动归类（design §72）
        case "folderrule":   // folderrule <文件夹> <JSON|-> [apply]：JSON 是 {"keywords":[…],"people":[id…],"templateId":…}
            var rule = FolderRule(folder: args[1])
            if args[2] != "-", let data = args[2].data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                rule.keywords = object["keywords"] as? [String] ?? []
                rule.people = (object["people"] as? [NSNumber] ?? []).map(\.int64Value)
                rule.templateId = object["templateId"] as? String
            }
            model.saveFolderRule(rule, applyNow: args.count > 3 && args[3] == "apply")
        case "editfolderrule": model.editingFolderRule = args[1]   // 打开条件的编辑
        case "autofile":
            if let id, let folder = try? model.db.autoFile(id) { model.organized(id, folder: folder) }
        case "foldersuggest":   // foldersuggest <会议 id> <输出.json>
            if let id, let meeting = try? model.db.meeting(id) {
                let s = model.folderSuggestion(for: meeting)
                var reason: [String: Any] = [:]
                switch s?.reason {
                case .people(let ids)?: reason = ["people": ids]
                case .title(let word)?: reason = ["title": word]
                case nil: break
                }
                write(["folder": s?.folder ?? "", "count": s?.count ?? 0, "reason": reason,
                       "text": s.map { model.folderSuggestionText($0) } ?? ""], to: args[2])
            }
        case "foldersuggestion":   // foldersuggestion accept|dismiss <会议 id>
            if let mid = Int64(args[2]), let meeting = try? model.db.meeting(mid) {
                if args[1] == "accept", let s = model.folderSuggestion(for: meeting) {
                    model.acceptFolderSuggestion(mid, folder: s.folder)
                } else if args[1] == "dismiss" {
                    model.dismissFolderSuggestion(mid)
                }
            }
        // 每一种东西都能直接改、删（R100、design §74）
        case "renamemeetingui": if let id { model.requestRenameMeeting(id) }   // 等于侧栏右键「重命名…」、Return
        case "folderdeleteui": model.confirmDeleteFolder = args[1]              // 等于文件夹的「删除文件夹…」、Delete，打开确认
        // 侧栏的收合（R101、design §75）
        case "sidebarsection": if args.count > 2 { model.setSection(args[1], expanded: args[2] == "on") }   // sidebarsection <folders|meetings|people|group:…> on|off
        case "sidebarexpand": if args.count > 2 { model.setRow(args[1], expanded: args[2] == "on") }     // sidebarexpand <folder:名称> on|off
        case "sidebarkey":   // sidebarkey return|delete：等于在侧栏按 Return、Delete（照现在选到的）
            if args[1] == "return" { _ = model.sidebarReturn() } else { model.sidebarDelete() }
        case "noteitem":   // noteitem <editui|edit|delete> <summary|decisions|actionItems|openQuestions|topic|custom|person> <位置> [第二个位置] [文字]
            let a = Int(args.count > 3 ? args[3] : "") ?? 0
            let twoLevel = ["topic", "custom", "person"].contains(args[2])
            let b = twoLevel ? Int(args.count > 4 ? args[4] : "") ?? 0 : 0
            let ref: NoteItemRef? = switch args[2] {
            case "summary": .summary(a)
            case "decisions": .decisions(a)
            case "actionItems": .actionItems(a)
            case "openQuestions": .openQuestions(a)
            case "topic": .topicPoint(a, b)
            case "custom": .custom(a, b)
            case "person": .person(a, b)
            default: nil
            }
            let textIndex = twoLevel ? 5 : 4
            if let ref {
                switch args[1] {
                case "editui": model.editingNoteItem = ref
                case "edit": model.editNoteItem(ref, text: args.count > textIndex ? args[textIndex] : "")
                case "delete": model.deleteNoteItem(ref)
                default: model.editingNoteItem = nil
                }
            }
        case "bookmarkrename": if let id { model.renameBookmark(id, label: args[2]) }
        case "bookmarkrenameui": if let id { model.renameTarget = .bookmark(id) }
        case "menupick": if args.count > 1 { pickNextMenu(args.dropFirst().joined(separator: " ")) }   // menupick <项目>：接下来打开的菜单选这一项
        // 自己画的菜单（R105）：floatpick <项目>（子菜单「移到文件夹 ▸ 客户」）选开着的那一项；floatclose 关掉
        case "floatpick": if args.count > 1 { FloatingMenuController.shared.debugPick(args.dropFirst().joined(separator: " ")) }
        case "floatclose": FloatingMenuController.shared.close()
        case "floatothers": FloatingMenuController.shared.ignoreOtherApps = args.count > 1 && args[1] == "off"   // floatothers off：点别的 app 不关菜单
        case "foldernew": if args.count > 1 { model.createFolder(args[1]) }   // 等于按「文件夹」标题的「+」建立（R104）
        case "importinto": if args.count > 2 { model.importDropped([URL(fileURLWithPath: args[2])], into: args[1]) }   // 等于从 Finder 把文件拖到文件夹（R103.3）
        // 重命名的弹窗（R102、design §76）：renameui <meeting|folder|person|bookmark|newfolder> <id、名称或会议 id,…>
        case "renameui":
            guard args.count > 2 else { break }
            switch args[1] {
            case "meeting": if let i = Int64(args[2]) { model.renameTarget = .meeting(i) }
            case "folder": model.renameTarget = .folder(args[2])
            case "person": if let i = Int64(args[2]) { model.renameTarget = .person(i) }
            case "bookmark": if let i = Int64(args[2]) { model.renameTarget = .bookmark(i) }
            case "newfolder": model.renameTarget = .newFolder(args[2].split(separator: ",").compactMap { Int64($0) })
            default: break
            }
        case "termrename": if let id { model.renameTerm(id, to: args[2]) }
        // 会议列表的排序、分组、筛选（design §71）
        case "listsort": if let sort = MeetingSort(rawValue: args[1]) { model.meetingSort = sort }
        case "listgroup": if let grouping = MeetingGrouping(rawValue: args[1]) { model.meetingGrouping = grouping }
        case "listfilter":
            switch args[1] {
            case "review": model.meetingFilter.needsReview.toggle()
            case "mine": model.meetingFilter.myActionItems.toggle()
            case "person": model.meetingFilter.personId = args.count > 2 ? Int64(args[2]) : nil
            case "template": model.meetingFilter.templateId = args.count > 2 ? args[2] : nil
            default: model.meetingFilter = MeetingFilter()
            }
        case "undo": model.selection = id; model.undoNotes()
        case "trash": if let id { model.moveToTrash(id) }
        case "restore": if let id { model.restore(id) }
        case "purge": if let id { model.deletePermanently(id) }
        case "confirmpurge": model.confirmPurge = id.map { [$0] }   // 等于在垃圾桶按右键「永久删除…」
        // 多选（R88、design §62）：selectmany <id,id,…>（等于 ⌘ 点击）；trashmany、restoremany、purgemany <id,id,…>；
        // showtrash 0|1；confirmemptytrash（跳出确认）；emptytrash（不经过确认）
        case "selectmany": model.listSelection = Set(args[1].split(separator: ",").compactMap { Int64($0) })
        case "trashmany": model.moveToTrash(args[1].split(separator: ",").compactMap { Int64($0) })
        case "restoremany": model.restore(args[1].split(separator: ",").compactMap { Int64($0) })
        case "purgemany": model.deletePermanently(args[1].split(separator: ",").compactMap { Int64($0) })
        case "showtrash": model.showTrash = args.count > 1 && args[1] == "1"
        case "confirmemptytrash": model.confirmEmptyTrash = true
        case "emptytrash": model.emptyTrash()
        // 删除一句（R89、design §63）：deletesegment <会议 id> <段落 id>；分割会议（R90、§64）：splitmeeting <会议 id> <段落 id>（不经过确认），
        // splitconfirm <会议 id> <段落 id>（跳出确认对话框，等于右键「从这里分成两场…」）
        case "deletesegment": model.selection = id; model.deleteSegment(Int64(args[2]) ?? 0)
        case "splitmeeting": model.selection = id; model.splitMeeting(at: Int64(args[2]) ?? 0)
        case "splitconfirm": model.selection = id; model.tab = .transcript; model.splitMeetingRequest = Int64(args[2])
        // 编辑会议（R107、design §81.6）：editmeeting <会议 id> keep=<开始>-<结束>[,…] [split=<秒>] [merge=<会议 id>[:<开始>-<结束>,…]]
        // （不经过画面和确认；merge 没给范围是整场，照会议开始的先后接）；restoreedit <会议 id>（不经过确认）、confirmrestoreedit <会议 id>；
        // editage <会议 id> <天数>（把最后编辑的时间改早，接着清一次过期的）；openedit <会议 id>（打开编辑画面）
        case "editmeeting":
            guard let id, let meeting = try? model.db.meeting(id) else { break }
            func ranges(_ text: Substring) -> [(Double, Double)] {
                text.split(separator: ",").compactMap { r in
                    let p = r.split(separator: "-").compactMap { Double($0) }
                    return p.count == 2 ? (p[0], p[1]) : nil
                }
            }
            func whole(_ m: Meeting) -> [(Double, Double)] {
                [(0, max(Double(m.durationSeconds ?? 0), ((try? model.db.segments(m.id!)) ?? []).map(\.end).max() ?? 0))]
            }
            var mine = whole(meeting)
            var cut: Double?
            var merged: (meeting: Meeting, ranges: [(Double, Double)])?
            for arg in args.dropFirst(2) {
                let value = arg.split(separator: "=", maxSplits: 1).last ?? ""
                if arg.hasPrefix("keep=") { mine = ranges(value) }
                else if arg.hasPrefix("split=") { cut = Double(value) }
                else if arg.hasPrefix("merge="), let other = Int64(value.split(separator: ":")[0]), let m = try? model.db.meeting(other) {
                    let parts = value.split(separator: ":", maxSplits: 1)
                    merged = (m, parts.count > 1 ? ranges(parts[1]) : whole(m))
                }
            }
            var pieces = mine.map { EditPlan.Piece(meetingId: id, start: $0.0, end: $0.1) }
            if let merged {
                let theirs = merged.ranges.map { EditPlan.Piece(meetingId: merged.meeting.id!, start: $0.0, end: $0.1) }
                pieces = merged.meeting.createdAt < meeting.createdAt ? theirs + pieces : pieces + theirs
            }
            model.applyMeetingEdit(id, plan: EditPlan(pieces: pieces), cut: cut)
        case "restoreedit": if let id { model.restoreMeetingEdit(id) }
        case "confirmrestoreedit": if let id { model.requestRestoreEdit(id) }
        case "editage": if let id { try? model.db.ageEdit(id, days: Double(args[2]) ?? 31); model.purgeExpiredEdits() }
        case "openedit": if let id { model.requestEditMeeting(id) }
        // editorstate start=<秒> end=<秒> del=<a-b,…> sel=<a-b|none> cut=<秒|none> playhead=<秒> zoom=<倍> merge=<会议 id|none> play lines=<id,…>：
        // 直接改打开的编辑画面（背景的窗口收不到点击，截屏、验画面用）
        case "editorstate":
            guard let editor = MeetingEditor.debugCurrent else { break }
            func range(_ text: Substring) -> ClosedRange<Double>? {
                let p = text.split(separator: "-").compactMap { Double($0) }
                return p.count == 2 ? min(p[0], p[1])...max(p[0], p[1]) : nil
            }
            for arg in args.dropFirst() {
                let parts = arg.split(separator: "=", maxSplits: 1)
                let key = parts[0], value = parts.count > 1 ? parts[1] : ""
                switch key {
                case "start": editor.debugSet(start: Double(value), end: nil, deleted: nil, selection: nil, cut: nil)
                case "end": editor.debugSet(start: nil, end: Double(value), deleted: nil, selection: nil, cut: nil)
                case "del": editor.debugSet(start: nil, end: nil, deleted: value.split(separator: ",").compactMap(range), selection: nil, cut: nil)
                case "sel": editor.debugSet(start: nil, end: nil, deleted: nil, selection: .some(range(value)), cut: nil)
                case "cut": editor.debugSet(start: nil, end: nil, deleted: nil, selection: nil, cut: .some(Double(value)))
                case "playhead": editor.playhead = Double(value) ?? 0
                case "zoom": editor.zoom = Double(value) ?? 1
                case "lines": editor.selectedLines = Set(value.split(separator: ",").compactMap { Int64($0) })
                case "merge":
                    if let other = Int64(value), let m = try? model.db.meeting(other) { editor.merge(with: m, db: model.db) }
                    else { editor.unmerge(db: model.db) }
                case "play": editor.togglePlay()
                default: break
                }
            }
        case "reviewexpand":
            // reviewexpand <会议 id> <summary|decisions|actionItems|openQuestions|topic|custom|person> <位置> [第二个位置]：
            // 等于点那一条记录旁的待确认标记（R41.2）；位置给 - 就收合。窗口不在目前的桌面时 press 按不到标记，用这个
            model.selection = id
            let a = Int(args.count > 3 ? args[3] : "") ?? 0, b = Int(args.count > 4 ? args[4] : "") ?? 0
            let ref: NoteItemRef? = switch args[2] {
            case "summary": .summary(a)
            case "decisions": .decisions(a)
            case "actionItems": .actionItems(a)
            case "openQuestions": .openQuestions(a)
            case "topic": .topicPoint(a, b)
            case "custom": .custom(a, b)
            case "person": .person(a, b)
            default: nil
            }
            model.reviewDraft?.expanded = ref
        case "reviewsubmit":   // reviewsubmit <会议 id> [段落 位置 [第二个位置]]：等于按待确认标签页的「送出」；给了段落就是按那一条卡片的「送出」（只送那几题）
            model.selection = id
            if args.count > 3 {
                let a = Int(args[3]) ?? 0, b = Int(args.count > 4 ? args[4] : "") ?? 0
                let ref: NoteItemRef? = switch args[2] {
                case "summary": .summary(a)
                case "decisions": .decisions(a)
                case "actionItems": .actionItems(a)
                case "openQuestions": .openQuestions(a)
                case "topic": .topicPoint(a, b)
                case "custom": .custom(a, b)
                case "person": .person(a, b)
                default: nil
                }
                model.submitReviewDraft(only: Set(ref.flatMap { model.detail?.reviewLinks[$0] } ?? []))
            } else {
                model.submitReviewDraft()
            }
        case "reviewskipall":   // reviewskipall <会议 id>：等于按待确认标签页的「全部略过」（R41.5）
            model.selection = id
            model.reviewDraft?.skipAllUnanswered(questionCount: model.detail?.notes?.reviewItems.count ?? 0,
                                                 speakers: model.detail.map { Array($0.speakerSuggestions.keys) } ?? [])
        case "review":
            // review <id> <答案 JSON：{"0":"答案"}> <略过的题号，逗号分隔>
            model.selection = id
            let answers = (try? JSONDecoder().decode([String: String].self, from: Data(args[2].utf8))) ?? [:]
            let dismissed = Set(args[3].split(separator: ",").compactMap { Int($0) })
            model.submitReview(answers: Dictionary(uniqueKeysWithValues: answers.compactMap { k, v in Int(k).map { ($0, v) } }),
                               dismissed: dismissed)
        case "replace":
            model.selection = id
            let result = model.replace(find: args[2], with: args[3], addToGlossary: args[4] == "1")
            write(["segmentsChanged": result?.segmentsChanged ?? -1, "notesChanged": result?.notesChanged ?? false], to: args[5])
        case "segment": model.updateSegment(id ?? 0, text: args[2])
        case "speaker": model.selection = id; model.renameSpeaker(Int(args[2]) ?? 1, to: args[3])
        // 声纹（design §21.4）：notthis <会议 id> <说话者>（不是他）；people <输出.json>；personrename <id> <名字>；
        // persondelete <id>；peopledeleteall
        case "notthis": model.selection = id; model.rejectVoiceprintMatch(Int(args[2]) ?? 1)
        // speakerreview <会议 id> <回答 JSON：{"说话者编号":"是"|"不是，名字"}> <略过的说话者，逐号分隔>：等于在待确认送出说话者的题目（R33.2）
        case "speakerreview":
            model.selection = id
            let answers = (try? JSONDecoder().decode([String: String].self, from: Data(args[2].utf8))) ?? [:]
            model.answerSpeakerQuestions(Dictionary(uniqueKeysWithValues: answers.compactMap { k, v in Int(k).map { ($0, v) } }),
                                         skipped: Set(args[3].split(separator: ",").compactMap { Int($0) }))
        // 猜说话者（design §21.5）：namespeakers <会议 id>（排工作）；applysuggestion、dismisssuggestion <会议 id> <说话者>；
        // applyallsuggestions <会议 id>
        // 对会议提问（design §21.8）：ask <会议 id> <问题>；askall <all|folder|recent> <问题>；
        // questions <会议 id|all> <输出.json>；cancelask
        case "ask": model.selection = id; model.loadMeetingQuestions(id ?? 0); model.askMeeting(args[2])
        case "askall": model.loadAllQuestions(); model.askAll(args[2], scope: AskScope(rawValue: args[1]) ?? .all)
        case "questions":
            let list = args[1] == "all" ? ((try? model.db.questions(meetingId: nil)) ?? []) : ((try? model.db.questions(meetingId: Int64(args[1]))) ?? [])
            let target: AskTarget = args[1] == "all" ? .all : .meeting(Int64(args[1]) ?? 0)
            let request = model.askRequest.flatMap { $0.target == target ? $0 : nil }
            write(["asking": model.asking != nil,
                   "pendingQuestion": request?.question ?? "", "progress": request?.phase.label ?? "",
                   "phase": request.map { String(describing: $0.phase) } ?? "",
                   "visibleQuestions": (args[1] == "all" ? model.allQuestions : model.meetingQuestions).map(\.question),
                   "questions": list.map { ["question": $0.question, "scope": $0.scope, "provider": $0.provider,
                                                                            "answer": (try? JSONSerialization.jsonObject(with: Data($0.answer.utf8))) ?? [:]] }],
                  to: args[2])
        case "cancelask": model.cancelAsk()
        case "retryask": model.retryAsk()
        // 检测会议（design §21.7）：meetingapp <bundleID> start|stop；meetingprompts <输出.json>；meetingaction <按钮>
        case "meetingapp": model.meetingDetector.simulated[args[1]] = args[2] == "start"
        case "meetingprompts":
            let current = RecordingIsland.isEnabled ? RecordingIsland.shared.state.prompt?.prompt : MeetingPromptPanel.shared.current
            let text: String
            switch current {
            case .start(let app): text = "start:\(app.bundleID)"
            case .stop(let app): text = "stop:\(app.bundleID)"
            case nil: text = ""
            }
            let actions = RecordingIsland.isEnabled ? (RecordingIsland.shared.state.prompt?.actions.map(\.id) ?? []).sorted()
                : MeetingPromptPanel.shared.actions.keys.sorted()
            write(["prompt": text, "actions": actions, "muted": MeetingDetector.muted,
                   "countdown": model.meetingEndDeadline.map { max(0, $0.timeIntervalSinceNow) } ?? -1,
                   "recording": model.recorder.isRecording], to: args[1])
        case "meetingaction": RecordingIsland.isEnabled ? RecordingIsland.shared.perform(args[1]) : MeetingPromptPanel.shared.perform(args[1])
        case "island":   // island hover on|off：等于鼠标移到录音岛上、移开（design §57.3）
            if args.count > 2, args[1] == "hover" { RecordingIsland.shared.state.hover = args[2] == "on"; RecordingIsland.shared.update() }
        // reportinfo <输出.json>：回报问题会附上的内容和网址（不打开浏览器、不动剪贴板，design §21.9）
        case "reportinfo":
            let text = ProblemReport.text(db: model.db)
            write(["text": text, "url": ProblemReport.url(body: text)?.absoluteString ?? "", "issuesURL": ProblemReport.issuesURL], to: args[1])
        // rediarize <会议 id> <人数|auto>：等于在选人数的窗口按「开始」；rediarizerequest <会议 id>：等于按「更多 → 重新识别说话者…」
        case "rediarize": if let id { model.rediarize(meetingId: id, minSpeakers: args[2] == "auto" ? nil : Int(args[2])) }
        case "rediarizerequest": model.selection = id; model.requestRediarize()
        // 说话者的修正（design §24.6）：mergespeaker <会议 id> <来源> <目标>；reassign <会议 id> <说话者|new> <段落 id…>；undospeaker <会议 id>；
        // speakerhint <会议 id> dismiss：等于按「不用了」
        case "mergespeaker": model.selection = id; model.mergeSpeaker(Int(args[2]) ?? 0, into: Int(args[3]) ?? 0)
        case "reassign":
            model.selection = id
            model.reassignSegments(args.dropFirst(3).compactMap { Int64($0) }, to: args[2] == "new" ? nil : Int(args[2]))
        case "undospeaker": model.selection = id; model.undoSpeakerEdit()
        case "splitmode":   // splitmode <会议 id> <段落 id>：逐字稿进入拆成两句的模式（等于右键「拆成两句…」）
            model.selection = id
            model.tab = .transcript
            model.splitRequest = Int64(args[2])
        case "splitcaret":   // splitcaret <UTF-16 位置>：拆开模式的文字框把光标放到这里（背景的窗口点不到文字框，design §46.2）
            func find(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView, text.accessibilityLabel() == String(localized: "要拆开的句子") { return text }
                return view.subviews.lazy.compactMap(find).first
            }
            if let content = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.contentView, let text = find(content) {
                text.setSelectedRange(NSRange(location: Int(args[1]) ?? 0, length: 0))
            }
        case "splitsegment":   // splitsegment <会议 id> <段落 id> <UTF-16 位置> <说话者|new>：拆成两句（design §46.2）
            model.selection = id
            model.splitSegment(Int64(args[2]) ?? 0, at: Int(args[3]) ?? 0, to: args[4] == "new" ? nil : Int(args[4]))
        case "speakerhint": model.selection = id; if args.count > 2, args[2] == "dismiss" { model.dismissSpeakerHint() }
        case "minspeakers": model.selection = id; model.setMinSpeakers(args[2] == "auto" ? nil : Int(args[2]))   // 录音中的「人数」菜单（design §26.2）
        case "levelhint": if args.count > 1, args[1] == "dismiss" { model.recorder.dismissLevelHint() }   // 收音提醒按「知道了」
        // 麦克风（design §38.7）：fakemic <名称> <bluetooth 0|1> [内置麦克风的名称]｜off：加假的麦克风（只在内存），
        // 第一支当成系统默认；micswitch <uid|default>：等于在录音画面选一支；michint dismiss：蓝牙提示按「知道了」
        case "fakemic":
            let monitor = MicrophoneMonitor.shared
            if args.count < 3 || args[1] == "off" {
                monitor.fakeDefault = nil
                monitor.fakes = []
            } else {
                var fakes = [AudioDevices.Device(uid: "fake-mic-1", name: args[1],
                                                 transport: args[2] == "1" ? kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeUSB)]
                if args.count > 3 { fakes.append(AudioDevices.Device(uid: "fake-mic-builtin", name: args[3], transport: kAudioDeviceTransportTypeBuiltIn)) }
                monitor.fakes = fakes
                monitor.fakeDefault = "fake-mic-1"
            }
        case "micswitch": model.switchMicrophone(args[1] == "default" ? "" : args[1])
        case "michint": if args.count > 1, args[1] == "dismiss" { model.recorder.dismissMicHint() }
        // textsize <−1～5|bigger|smaller|actual>：会议内容的文字大小（design §38.7；写共用设置，测完 defaults delete contentTextSize）
        case "textsize":
            switch args[1] {
            case "bigger": TextSize.change(1)
            case "smaller": TextSize.change(-1)
            case "actual": TextSize.change(nil)
            default: UserDefaults.standard.set(Int(args[1]) ?? 0, forKey: AppSettings.textSizeKey)
            }
        case "namespeakers": if let id { try? model.db.enqueue(id, kind: .nameSpeakers); model.runner.wake() }
        case "applysuggestion": model.selection = id; model.applySpeakerSuggestion(Int(args[2]) ?? 1)
        case "dismisssuggestion": model.selection = id; model.dismissSpeakerSuggestion(Int(args[2]) ?? 1)
        case "applyallsuggestions": model.selection = id; model.applyAllSpeakerSuggestions()
        case "people":
            model.reloadPeople()
            write(["people": model.people.map { ["id": $0.id, "name": $0.name, "voiceprints": $0.voiceprintCount,
                                                 "lastTitle": $0.lastMeetingTitle ?? "", "lastDate": $0.lastMeetingDate ?? ""] }], to: args[1])
        case "personrename": if let id { model.renamePerson(id, to: args[2]) }
        case "persondelete": if let id { model.deletePerson(id) }
        case "personremove": model.confirmRemovePerson = id   // 等于选了「移除这个人…」（R85.7），打开确认
        case "personrenameui":   // 等于选了「改名…」（更多、侧栏右键，R85.7）：选那个人、打开铅笔下面的输入框
            model.sidebarMode = .people
            model.selectedPerson = id
            if let id { model.renameTarget = .person(id) }
        case "peopledeleteall": model.deleteAllPeople()
        case "template": model.selection = id; model.setTemplate(args[2])
        case "language": model.selection = id; model.setMeetingLanguage(MeetingLanguage(rawValue: args[2]) ?? .zh)
        case "transcribe-eval": transcribeEval(audio: args[1], options: args[2], output: args[3])   // design §17.1
        case "dump-golden": GoldenDump.run(fixtures: args[1], output: args[2])   // design-windows §4.1
        case "seedfixtures": GoldenDump.seed(fixtures: args[1], keys: Array(args.dropFirst(2)), into: model)   // 本地 MCP 的示范会议（design §44.6）
        case "mcpsetup":   // mcpsetup claudecode|codex|desktop <输出.json>：等于按设置页的「加到…」（design §44.6）
            let output = args.count > 2 ? args[2] : nil
            Task {
                let r: MCPSetup.Outcome
                switch args.count > 1 ? args[1] : "" {
                case "claudecode": r = await MCPSetup.addToClaudeCode()
                case "codex": r = await MCPSetup.addToCodex()
                default: r = MCPSetup.addToClaudeDesktop()
                }
                if let output { write(["ok": r.ok, "message": r.message], to: output) }
            }
        case "mcpcopy":   // mcpcopy command|json：等于按设置页「复制」菜单的「复制 Claude Code 命令」「复制设置（JSON）」（design §44.6）
            MCPSetup.copy(args.count > 1 && args[1] == "json" ? .configJSON : .claudeCodeCommand)
        case "unquarantine":   // unquarantine <app 的路径> <输出.json>：对那个 bundle 跑拿掉隔离属性（D150）
            write(["removed": MCPSetup.removeQuarantine(in: URL(fileURLWithPath: args[1]))], to: args[2])
        case "openlink":   // openlink <shiyin://open?…>：等于点了 AI 工具给的会议链接（design §44.5），不拉到前面
            if let url = URL(string: args[1]), let target = MeetingLink.parse(url) {
                model.openMeetingLink(target.meetingId, seconds: target.seconds, activate: false)
            }
        case "segment-embed": segmentEmbed(audio: args[1], spans: args[2], output: args[3], batched: args.count > 4 ? Int(args[4]) : nil)   // design §6.3.2
        case "correct-eval": correctEval(input: args[1], options: args[2], output: args[3])          // design §17.4
        case "detect-eval": detectEval(audio: args[1], start: Double(args[2]) ?? 0, output: args[3])  // design §18.8
        case "checktranscript": model.selection = id; model.checkTranscript()
        case "correction":   // correction accept|reject|revert <校正 id>
            if let cid = Int64(args[2]) {
                switch args[1] {
                case "accept": model.acceptCorrection(cid)
                case "reject": model.rejectCorrection(cid)
                default: model.revertCorrection(cid)
                }
            }
        // correctiongroups <会议 id> <输出.json>：校正列「依词处理」看到的组；
        // correctiongroup <会议 id> accept|reject <第几组>：等于按那一组的「接受 N 处」「忽略」（design §21.11）
        case "correctiongroups":
            model.selection = id
            let groups = model.detail?.correctionGroups ?? []
            write(["groups": groups.map { ["original": $0[0].original, "suggestion": $0[0].suggestion, "count": $0.count,
                                           "segments": $0.map(\.segmentId)] }], to: args[2])
        case "correctiongroup":
            model.selection = id
            let groups = model.detail?.correctionGroups ?? []
            if let index = Int(args[3]), groups.indices.contains(index) {
                let ids = groups[index].compactMap(\.id)
                args[2] == "accept" ? model.acceptCorrections(ids) : model.rejectCorrections(ids)
            }
        case "corrections":  // corrections <会议 id> accept|reject：全部接受或全部忽略
            model.selection = id
            if args[2] == "accept" { model.acceptAllCorrections() } else { model.rejectAllCorrections() }
        case "editnotes":
            // editnotes <id> <会议记录 JSON>
            model.selection = id
            if let notes = try? JSONDecoder().decode(MeetingNotes.self, from: Data(args[2].utf8)) { model.saveEditedNotes(notes, meetingId: id ?? 0) }
        case "usernotes": model.selection = id; model.updateUserNotes(args[2])
        // notestype <文字>：在画面上的笔记输入框（TextEditor 背后的 NSTextView）结尾打字，跟键盘打字走同一条路，
        // 屏幕上锁、窗口在别的桌面时也能用；notesvalue <输出.json>：输入框目前显示的内容（design §20.4）
        case "notestype":
            guard let textView = notesTextView() else { break }
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText(args[1], replacementRange: textView.selectedRange())
        case "notesvalue": write(["found": notesTextView() != nil, "text": notesTextView()?.string ?? ""], to: args[1])
        // press <标签> [第几个，从 0 开始] [结果.json]：在 app 内走辅助功能的组件树，按下标签相符的按钮。
        // 跟从外面用 AX 按的是同一条路，屏幕上锁、窗口在别的桌面时也能用
        case "metrics":   // metrics <输出.json> [reset]：性能计数（design §21.12）；加 reset 读完归零
            write(DebugMetrics.snapshot, to: args[1])
            if args.count > 2 && args[2] == "reset" { DebugMetrics.reset() }
        // 输入框（design §21.15 验证用，屏幕上锁、窗口在别的桌面时也能用）：用提示文字找 SwiftUI TextField 背后的 NSTextField
        // typefield <提示文字> <文字> [第几个]：在结尾打字；fieldvalue <提示文字> <输出.json> [第几个]；submitfield <提示文字> [第几个]：按 Return
        case "typefield":
            guard let field = textField(placeholder: args[1], index: args.count > 3 ? Int(args[3]) ?? 0 : 0) else { break }
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                editor.insertText(args[2], replacementRange: editor.selectedRange())
            }
        case "fieldvalue":
            let field = textField(placeholder: args[1], index: args.count > 3 ? Int(args[3]) ?? 0 : 0)
            write(["found": field != nil, "text": field?.stringValue ?? ""], to: args[2])
        case "submitfield":
            guard let field = textField(placeholder: args[1], index: args.count > 2 ? Int(args[2]) ?? 0 : 0) else { break }
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.insertNewline(nil)
        case "editsegment": model.debugEditSegment = id   // editsegment <段落 id>：等于点那一段开始编辑
        case "settingsaction": model.debugSettingsAction = Array(args.dropFirst())   // settingsaction pickmodel | savekey <key>（设置页要开着）
        // voiceprint-eval <设置.json> <输出.json>：设置是 [{"file": 音档, "name": 名称}]；每个文件跑说话者识别，
        // 输出每位说话者的声纹、说话秒数、说话的时段，用来跟 AMI 标注比对、决定门槛（design §21.4.1）
        // 设置的每一项可以加 threshold、minSpeakers、numSpeakers（字符串）换分群设置，比较分出几个人；dump（路径）倒出每个片段的声纹
        // model：standard、nemotron（R87，design §61.2；没写时用标准的）
        case "voiceprint-eval":
            let config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1])))) as? [[String: String]] ?? []
            let output = args[2]
            Task {
                var results: [[String: Any]] = []
                for item in config {
                    guard let file = item["file"] else { continue }
                    let started = Date()
                    do {
                        let samples = try await AudioDecoder.decode(URL(fileURLWithPath: file))
                        var clustering: OfflineDiarizerConfig.Clustering?
                        if item["threshold"] != nil || item["minSpeakers"] != nil || item["numSpeakers"] != nil {
                            var c = OfflineDiarizerConfig.Clustering.community
                            if let t = item["threshold"].flatMap(Double.init) { c.threshold = t }
                            c.minSpeakers = item["minSpeakers"].flatMap(Int.init)
                            c.numSpeakers = item["numSpeakers"].flatMap(Int.init)
                            clustering = c
                        }
                        // 短句的实验：zeroVote（重新嵌入没人认领的片段，最短秒数）、minSegment（算声纹的最短秒数）、step（窗口步距比例）
                        var config: OfflineDiarizerConfig?
                        if item["zeroVote"] != nil || item["minSegment"] != nil || item["step"] != nil || item["legacy"] != nil {
                            // legacy：改之前的设置（FluidAudio 的默认），跟现在比
                            var c = item["legacy"] != nil ? OfflineDiarizerConfig(clustering: clustering ?? .community, exposeChunkEmbeddings: true)
                                : Diarizer.config(clustering: clustering ?? .community)
                            if let v = item["zeroVote"].flatMap(Double.init) { c.zeroVoteReembed = .init(enabled: true, minDurationSeconds: v) }
                            if let v = item["minSegment"].flatMap(Double.init) { c.embedding.minSegmentDurationSeconds = v }
                            if let v = item["step"].flatMap(Double.init) { c.segmentation.stepRatio = v }
                            config = c
                        }
                        let diarization = try await Diarizer.diarize(samples: samples, minSpeakers: item["minSpeakers"].flatMap(Int.init),
                                                                     clustering: clustering, config: config,
                                                                     model: Diarizer.Model(rawValue: item["model"] ?? "") ?? .standard) { _ in }
                        // dump：<路径>.f32 是每个片段的声纹（256 个 Float32 一笔），<路径>.json 是对应的群、片段、片段里的说话者
                        if let dump = item["dump"] {
                            var floats: [Float] = []
                            for chunk in diarization.chunks { floats += chunk.embedding256 }
                            try floats.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: dump + ".f32"))
                            write(["cluster": diarization.chunks.map(\.speakerId), "chunk": diarization.chunks.map(\.chunkIndex),
                                   "local": diarization.chunks.map(\.speakerIndex), "start": diarization.chunks.map(\.startTimeSeconds),
                                   "end": diarization.chunks.map(\.endTimeSeconds)], to: dump + ".json")
                        }
                        // Nemotron-3 的说话者不一定有声纹（§61.2）：说过话的都列
                        let numbers = Set(diarization.turns.map(\.speaker)).union(diarization.voiceprints.keys).sorted()
                        let speakers: [[String: Any]] = numbers.map { number in
                            ["number": number, "seconds": diarization.speechSeconds[number] ?? 0,
                             "embedding": diarization.voiceprints[number] ?? [],
                             "turns": diarization.turns.filter { $0.speaker == number }.map { [$0.start, $0.end] }]
                        }
                        results.append(["name": item["name"] ?? file, "seconds": Double(samples.count) / AudioDecoder.sampleRate,
                                        "model": diarization.model.rawValue,
                                        "elapsed": Date().timeIntervalSince(started), "speakers": speakers,
                                        "collisionRate": diarization.quality?.collisionRate ?? -1,
                                        "multiSpeakerChunks": diarization.quality?.multiSpeakerChunks ?? -1,
                                        "cohesion": diarization.quality?.cohesion ?? -1,
                                        "mergeRisk": diarization.quality?.mergeRisk ?? -1])
                    } catch {
                        results.append(["name": item["name"] ?? file, "error": error.localizedDescription])
                    }
                    write(["done": results.count, "total": config.count, "results": results], to: output)
                }
            }
        case "windowsize":   // windowsize <宽> <高>：把主窗口的内容区设成这个大小（点）。官网截屏用（website.md §16）：窗口在别的桌面时 AX 改不了大小，screencapture -l 照样截得到
            if let w = Double(args[1]), let h = Double(args[2]),
               let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                window.setContentSize(NSSize(width: w, height: h))
            }
        case "summon":   // summon：把拾音的窗口移到目前的桌面、放到最前面（真的画面上用辅助功能测试时，窗口在别的桌面会按不到）
            for window in NSApp.windows where window.isVisible && window.frame.width > 400 {
                // preview 的窗口本来就在每个桌面：再加 moveToActiveSpace 会被 AppKit 丢例外、整个 app 当掉（2026-10-29）
                if window.collectionBehavior.contains(.canJoinAllSpaces) {
                    window.makeKeyAndOrderFront(nil)
                    continue
                }
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                window.collectionBehavior.remove(.moveToActiveSpace)
            }
            NSApp.activate()
        case "livescroll":   // livescroll <0～1>：把录音画面的实时逐字稿卷到这个位置（0 是最上面），等于拖滚动条（design §25）
            let fraction = CGFloat(Double(args[1]) ?? 0)
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            for window in NSApp.windows where window.isVisible {
                for scroll in scrollViews(window.contentView ?? NSView())
                where !(scroll.documentView is NSTextView) && !(scroll.documentView is NSTableView) {
                    guard let document = scroll.documentView else { continue }
                    let range = max(0, document.frame.height - scroll.contentView.bounds.height)
                    let y = document.isFlipped ? range * fraction : range * (1 - fraction)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        case "axdump":   // axdump <输出.txt>：倒出辅助功能的组件树（角色、标签），找 press 要用的标签
            var lines: [String] = []
            func dump(_ element: NSAccessibilityProtocol, depth: Int) {
                guard depth < 80 else { return }
                lines.append(String(repeating: "  ", count: depth) + "\(element.accessibilityRole()?.rawValue ?? "?") label=\(element.accessibilityLabel() ?? "") title=\(element.accessibilityTitle() ?? "")")
                for child in element.accessibilityChildren() ?? [] {
                    if let child = child as? NSAccessibilityProtocol { dump(child, depth: depth + 1) }
                }
            }
            for window in NSApp.windows where window.isVisible { dump(window, depth: 0) }
            try? lines.joined(separator: "\n").write(toFile: args[1], atomically: true, encoding: .utf8)
        case "press":
            let matches = accessibilityButtons(label: args[1])
            let index = args.count > 2 ? Int(args[2]) ?? 0 : 0
            let pressed = matches.indices.contains(index) && matches[index].accessibilityPerformPress()
            if args.count > 3 { write(["found": matches.count, "pressed": pressed], to: args[3]) }
        // clickat <x> <y> [窗口 id]：在窗口里点一下（点，左上原点，含标题列；默认主窗口）。直接交给 NSWindow.sendEvent，
        // 走 AppKit、SwiftUI 正常的点击判断，窗口在别的桌面（例如用户在全屏幕的 app）也点得到，不碰用户的鼠标
        case "clickat":
            // 窗口 id 或窗口编号（确认对话框的 sheet 没有 id，用 screencapture 看到的编号）
            let target = args.count > 3 ? args[3] : "main"
            guard let x = Double(args[1]), let y = Double(args[2]),
                  let window = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue == target || "\($0.windowNumber)" == target) })
            else { break }
            let point = NSPoint(x: x, y: window.frame.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        // mouseat <left|right|double|move> <x> <y> <窗口 id 或编号> [菜单输出.json]：同 clickat，直接交给 NSWindow.sendEvent，
        // 不碰用户的鼠标、不用切到那个桌面（R100 自己验收）。给了输出档时，接下来打开的菜单（右键、「⋯」）把项目写出来再关掉
        case "mouseat":
            guard args.count > 4, let x = Double(args[2]), let y = Double(args[3]),
                  let window = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue == args[4] || "\($0.windowNumber)" == args[4]) })
            else { break }
            // 最后一个参数 app：走 NSApp.sendEvent（经过 app 的事件监看、NSApp.currentEvent 是这一下；自己画的菜单的右键靠它）
            let viaApp = args.last == "app"
            if args.count > 5, args[5] != "app" { captureNextMenu(to: args[5], keep: args.count > 6 ? Double(args[6]) ?? 0 : 0) }
            let point = NSPoint(x: x, y: window.frame.height - y)
            func deliver(_ event: NSEvent) { if viaApp { NSApp.sendEvent(event) } else { window.sendEvent(event) } }
            func send(_ type: NSEvent.EventType, clicks: Int) {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                    deliver(event)
                }
            }
            // 从 CGEvent 产生：带按键编号（右键是 1；NSEvent.mouseEvent 做的右键按键编号是 0，SwiftUI 会当成左键点击）。
            // NSEvent(cgEvent:) 没有窗口时 locationInWindow 是屏幕座标，所以把位置放成「数值等于窗口座标」，交给 sendEvent 时落在同一点
            func sendCG(_ type: CGEventType, _ button: CGMouseButton, clicks: Int64) {
                let height = NSScreen.screens.first?.frame.height ?? 0
                guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: height - point.y),
                                       mouseButton: button) else { return }
                cg.setIntegerValueField(.mouseEventClickState, value: clicks)
                if let event = NSEvent(cgEvent: cg) { deliver(event) }
            }
            switch args[1] {
            case "rightq":
                // 右键的按下、放开排进事件队列（经过 app 的事件监看，自己画的菜单的右键靠它）
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            case "clickq", "clickqcmd", "clickqshift":
                // 按下、放开都排进事件队列，同真的点一下：经过手势识别、NSApp.currentEvent 是这一下，
                // 表格按下后自己从队列拿放开（直接 sendEvent 的话这些都不一样，2026-11-17 验侧栏点击卡住时发现）
                let flags: NSEvent.ModifierFlags = args[1] == "clickqcmd" ? .command : args[1] == "clickqshift" ? .shift : []
                for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            case "dragq":
                // mouseat dragq <x> <y> <窗口> <x2> <y2>：按下、分 12 步拖到 (x2, y2)、放开，都排进事件队列（SwiftUI 的拖动手势；
                // 不是拖放：beginDraggingSession 读真的光标，拖放只能用真的鼠标）
                guard args.count > 6, let x2 = Double(args[5]), let y2 = Double(args[6]) else { break }
                let end = NSPoint(x: x2, y: window.frame.height - y2)
                let steps = 12
                var events: [(NSEvent.EventType, NSPoint, Float)] = [(.leftMouseDown, point, 1)]
                for i in 1...steps {
                    let f = CGFloat(i) / CGFloat(steps)
                    events.append((.leftMouseDragged, NSPoint(x: point.x + (end.x - point.x) * f, y: point.y + (end.y - point.y) * f), 1))
                }
                events.append((.leftMouseUp, end, 0))
                for (type, location, pressure) in events {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            case "right": send(.rightMouseDown, clicks: 1); send(.rightMouseUp, clicks: 1)
            case "cgright": sendCG(.rightMouseDown, .right, clicks: 1); sendCG(.rightMouseUp, .right, clicks: 1)
            case "cgleft": sendCG(.leftMouseDown, .left, clicks: 1); sendCG(.leftMouseUp, .left, clicks: 1)
            case "cgdouble":
                sendCG(.leftMouseDown, .left, clicks: 1); sendCG(.leftMouseUp, .left, clicks: 1)
                sendCG(.leftMouseDown, .left, clicks: 2); sendCG(.leftMouseUp, .left, clicks: 2)
            case "double": send(.leftMouseDown, clicks: 1); send(.leftMouseUp, clicks: 1); send(.leftMouseDown, clicks: 2); send(.leftMouseUp, clicks: 2)
            case "move": send(.mouseMoved, clicks: 0)
            default: send(.leftMouseDown, clicks: 1); send(.leftMouseUp, clicks: 1)
            }
        case "eventlog":   // eventlog <输出档|off>：把收到的鼠标、按键事件写下来（查外面送的事件有没有进来；三指拖移的事件、拖动开始了没）
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
            eventLogPath = nil
            if args[1] != "off" {
                let path = args[1]
                FileManager.default.createFile(atPath: path, contents: nil)
                eventLogPath = path
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .mouseMoved, .keyDown, .pressure]) { event in
                    let mouse = event.type != .keyDown
                    note("\(event.type.rawValue) win=\(event.windowNumber) loc=\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) clicks=\(mouse && event.type != .pressure ? event.clickCount : 0) key=\(mouse ? -1 : Int(event.keyCode)) subtype=\(mouse ? Int(event.subtype.rawValue) : -1) pressure=\(mouse ? event.pressure : 0) buttons=\(NSEvent.pressedMouseButtons)")
                    return event
                }
            }
        case "appearance":   // appearance light|dark|system：只改这个 app 的外观（巡检浅色、深色用，不动系统设置）
            NSApp.appearance = args[1] == "light" ? NSAppearance(named: .aqua) : args[1] == "dark" ? NSAppearance(named: .darkAqua) : nil
        case "capturemenu": captureNextMenu(to: args[1])   // capturemenu <输出.json>：接下来打开的菜单写出项目后关掉（配合外面送的真的鼠标事件）
        // keyat <return|delete|escape|f2> <窗口 id 或编号>：按键直接交给那个窗口（给第一回应者，同真的按键）
        case "keyat":
            guard args.count > 2, let window = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue == args[2] || "\($0.windowNumber)" == args[2]) })
            else { break }
            let (code, chars): (UInt16, String) = switch args[1] {
            case "delete": (51, "\u{7f}")
            case "space": (49, " ")
            case "escape": (53, "\u{1b}")
            case "f2": (120, String(UnicodeScalar(NSF2FunctionKey)!))
            case "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
            case "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
            case "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
            case "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
            default: (36, "\r")
            }
            // 第四个参数 app：走 NSApp.sendEvent（会经过 app 的事件监看，自己画的菜单的键盘靠它）
            let throughApp = args.count > 3 && args[3] == "app"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: code) {
                    if throughApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
                }
            }
        // pressbutton <按钮的字> [窗口编号]：按 AppKit 的按钮（确认对话框的 NSAlert 在桌面层时 AX 看不到、clickat 点不到）
        case "pressbutton":
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == args[1], button.isEnabled { return button }
                return view.subviews.lazy.compactMap(find).first
            }
            let windows = NSApp.windows.filter { $0.isVisible && (args.count < 3 || "\($0.windowNumber)" == args[2]) }
            windows.lazy.compactMap { $0.contentView.flatMap(find) }.first?.performClick(nil)
        case "bookmark": model.addBookmark(at: Double(args[2]) ?? 0, meetingId: id)
        case "addterm": model.addTerms(args[1].replacingOccurrences(of: "\\n", with: "\n"))   // 一次好几个（R94.1）：「\n」当换行
        case "dismissterm": model.dismissGlossarySuggestion(args[1])
        case "record":
            switch args[1] {
            case "start": model.startRecording()
            case "pause": model.recorder.pause()
            case "resume": model.recorder.resume()
            default: model.recorder.stop()
            }
        case "importsheet": model.requestImport(args.dropFirst().map { URL(fileURLWithPath: $0) })   // 只打开导入对话框
        case "recordstall":   // recordstall <秒数|off> [声道]：模拟录音的音源停止送资料（design §20.2）
            model.recorder.simulateStall(channel: args.count > 2 ? Int(args[2]) ?? 0 : 0, seconds: args[1] == "off" ? nil : Double(args[1]) ?? 5)
        case "recordinterrupt":   // recordinterrupt [声道]：等于音源发现设备变了，Recorder 会重新开始这个音源
            model.recorder.simulateInterruption(channel: args.count > 1 ? Int(args[1]) ?? 0 : 0)
        case "recordflap":   // recordflap <次数> [秒数]：麦克风接下来几次开始收音后都说设备变了，每次重新开始花几秒（design §50.4）
            model.recorder.simulateFlapping(times: Int(args[1]) ?? 0, seconds: args.count > 2 ? Double(args[2]) ?? 0 : 0)
        case "recordlang":   // recordlang <语言代码>：录音中换会议语言（等于按「改回」；zh、en、ja、yue、ko…）
            if let language = MeetingLanguage(rawValue: args[1]) { model.recorder.switchLanguage(to: language) }
        case "record-sim":
            // record-sim <音档> <倍速> <both: 1/0/2>：2 是双声道、电脑声音那一声道全是 0（design §51.1）
            let channels = args.count > 3 ? args[3] : "0"
            model.startSimulatedRecording(file: URL(fileURLWithPath: args[1]), speed: Double(args[2]) ?? 1,
                                          both: channels == "1" || channels == "2", systemSilent: channels == "2")
        case "recordtext" where args.count >= 6:
            // recordtext <会议 id> <draft|review|preview> <开始> <结束> <文字>；只对模拟录音生效。
            if let id, let start = Double(args[3]), let end = Double(args[4]) {
                model.recorder.simulateTranscriptResult(meetingId: id, kind: args[2], start: start, end: end, text: args[5])
            }
        case "recordtextshow" where args.count >= 2:
            if let state = model.recorder.simulatedTranscriptState { write(state, to: args[1]) }
        case "reminders": model.selection = id; model.addActionItemsToReminders()   // reminders <会议 id>：等于按「加到提醒事项」（design §52.2）
        case "reminderdone":   // reminderdone <会议 id> <第几项，0 开始>：假的提醒事项里把那场会议的第几项设成完成
            let matching = FakeReminders.shared.entries.indices.filter { Reminders.meetingAndKey(FakeReminders.shared.entries[$0].item.url)?.meetingId == id }
            if let n = Int(args[2]), n < matching.count { FakeReminders.shared.entries[matching[n]].completed = true }
            model.refreshReminderStatus()
        case "enrollvoice":   // enrollvoice <音档> <名字>：用音档代替麦克风录「我的声音」（design §56.3）
            Task {
                do {
                    let samples = try await AudioDecoder.decode(URL(fileURLWithPath: args[1]))
                    try await model.enrollVoice(name: args[2], samples: samples)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
        case "enrolldelete": model.deleteEnrollment()
        case "sidebar":   // sidebar people|meetings：侧栏的「会议｜人物」（design §60.2）
            model.sidebarMode = args.count > 1 && args[1] == "people" ? .people : .meetings
            model.reloadPeopleOverview()
        case "person":   // person <人的 id>：侧栏切到人物、选这个人
            model.sidebarMode = .people
            model.reloadPeopleOverview()
            model.selectedPerson = id
        case "hidesharing":   // hidesharing on|off：改默认值（只在内存，不写进共用设置；共用设置里有值时以它为准），套用到所有窗口（design §53）
            UserDefaults.standard.register(defaults: [AppSettings.hideFromScreenSharingKey: args[1] == "on"])
            WindowSharing.applyAll()
        case "systempermission":   // systempermission <denied|granted|notDetermined|real>：盖掉查到的「录制系统音频」权限（design §51.1）
            SystemAudioPermission.debugOverride = SystemAudioPermission(rawValue: args[1])
        case "seek": model.player.seek(to: Double(args[1]) ?? 0, play: args.count > 2 && args[2] == "play")
        case "rate": model.player.setRate(Float(args[1]) ?? 1)
        case "playvolume": model.player.setVolume(Float(args[1]) ?? 1)   // playvolume <0～1>（design §49.3）
        case "toggle": model.player.toggle()
        case "export":
            // export <项目> <格式> <路径> [times 1/0] [speakers 1/0] [会议 id，默认目前选中的]
            let item = ExportItem(rawValue: args[1]) ?? .notes
            let url = URL(fileURLWithPath: args[3])
            let meetingId = args.count > 6 ? Int64(args[6]) : model.selection
            Task {
                do {
                    guard let meetingId else { throw AppModel.ExportError.meetingGone }
                    try await model.export(item, format: args[2], times: args.count <= 4 || args[4] == "1",
                                           speakers: args.count <= 5 || args[5] == "1", meetingId: meetingId, to: url)
                }
                catch { try? "ERROR \(error.localizedDescription)".write(to: url.appendingPathExtension("error"), atomically: true, encoding: .utf8) }
            }
        case "import":   // import [lang=ja] [minSpeakers=6] <文件>…（minSpeakers：导入对话框的「大约几个人」，design §26.2）
            var files = Array(args.dropFirst()), options = ImportOptions()
            while let first = files.first, first.hasPrefix("lang=") || first.hasPrefix("minSpeakers=") {
                if first.hasPrefix("lang=") { options.language = MeetingLanguage(rawValue: String(first.dropFirst(5))) ?? .zh }
                else { options.minSpeakers = Int(first.dropFirst(12)) }
                files.removeFirst()
            }
            model.requestImport(files.map { URL(fileURLWithPath: $0) })
            if model.showImportSheet { model.confirmImport(options) }
        // 会议的参考文档（design §39.7）：adddoc <会议 id> <文件>…（加到这场，同「加入文档…」选了这些档）；
        // drop <文件>…（等于拖进主窗口：文档加到选中中的会议，其他照旧导入）；removedoc <文档 id>；
        // docread <文件> <zh|en|ja> <输出.json>（只读出文字，不写数据库）；docbanner <会议 id> dismiss|resummarize（文档有变动的提示条）
        case "adddoc": if let id { model.addDocuments(args.dropFirst(2).map { URL(fileURLWithPath: $0) }, to: id) }
        case "drop": model.requestImport(args.dropFirst().map { URL(fileURLWithPath: $0) })
        case "removedoc":
            if let docId = Int64(args[1]), let document = try? model.db.document(docId) { model.removeDocument(document) }
        case "docread":
            let url = URL(fileURLWithPath: args[1]), language = MeetingLanguage(rawValue: args[2]) ?? .zh, output = args[3]
            Task {
                let started = Date()
                let result = await Task.detached { Result { try DocumentReader.read(url, language: language) } }.value
                switch result {
                case .success(let r):
                    write(["kind": r.kind.rawValue, "pages": r.pages, "ocr": r.ocr, "seconds": Date().timeIntervalSince(started)], to: output)
                case .failure(let error):
                    write(["error": error.localizedDescription], to: output)
                }
            }
        case "docbanner":
            model.selection = id
            if args.count > 2, args[2] == "dismiss" { model.dismissDocumentsChanged() } else { model.resummarize() }
        case "copy":   // copy [plain|md|mindmap]
            if args.count > 1 && args[1] == "mindmap" { model.copyMindMap() }
            else { model.copyNotes(args.count > 1 && args[1] == "plain" ? .plain : args.count > 1 && args[1] == "md" ? .markdown : .rich) }
        case "search": model.searchQuery = args.count > 1 ? args[1] : ""
        case "openhit": if let index = Int(args[1]), model.searchResults.indices.contains(index) { model.openSearchHit(model.searchResults[index]) }
        case "model" where args.count > 2 && args[2] == "nemotron":   // model start|delete nemotron（R87，FluidAudio 下载）
            args[1] == "start" ? model.models.prepareNemotron() : args[1] == "delete" ? model.models.deleteNemotron() : ()
        case "model":   // model start|pause|delete [breeze|japanese|languageDetection|qwen]（qwen 是两个档一起）
            let which = ModelStore.Model(rawValue: args.count > 2 ? args[2] : "") ?? .breeze
            args[1] == "start" ? model.models.startAll(which) : args[1] == "pause" ? model.models.pauseAll(which) : model.models.deleteAll(which)
        case "qwenchunks":   // qwenchunks <录音> <输出.json> [最长秒数] [any] [mixed]：先识别说话者再照 §32.4 分段，倒出片段、切点、能量中位数（验证分段规则）
            qwenChunks(audio: args[1], output: args[2], maxSeconds: args.count > 3 ? Double(args[3]) ?? QwenEngine.maxChunkSeconds : QwenEngine.maxChunkSeconds,
                       anyChange: args.contains("any"), splitMixed: args.contains("mixed"))
        case "s2tw":    // s2tw <输入.txt> <输出.txt>：简体转台湾繁体（design §32.5），验证跟原型工具的结果相同
            if let text = try? String(contentsOfFile: args[1], encoding: .utf8) {
                try? ChineseScript.toTaiwan(text).write(toFile: args[2], atomically: true, encoding: .utf8)
            }
        case "t2s":    // t2s <输入.txt> <输出.txt>：繁体转大陆简体（design §45），验证跟 scripts/dev/t2s.py 的结果相同
            if let text = try? String(contentsOfFile: args[1], encoding: .utf8) {
                try? ChineseScript.toSimplified(text).write(toFile: args[2], atomically: true, encoding: .utf8)
            }
        case "diarizer": model.models.prepareDiarizer()
        case "modelurl":   // modelurl <模型> <网址>：改从别的网址下载；网址给 - 就改回原本的
            if let which = ModelStore.Model(rawValue: args[1]) { model.models.debugURLs[which] = args[2] == "-" ? nil : URL(string: args[2]) }
        case "llmurl":     // llmurl <anthropic|openai|gemini|openaiCompatible> <网址>：API 改送到本机的假服务器；网址给 - 就改回原本的
            if let provider = LLMProvider(rawValue: args[1]) { LLMClient.debugBaseURLs[provider] = args[2] == "-" ? nil : args[2] }
        case "enterprise":
            // 企业服务器（design §36.7）：login <网址> <邮箱> <输出.json>（服务器开发用的登录，不经过浏览器）、logout、expire（access token 立刻过期）、
            // local <会议 id>（等于按「改在这台电脑转录」）。登录会写进共用的设置（网址、账号），测完用 defaults delete 清掉
            switch args[1] {
            case "login":
                let output = args[4]
                Task {
                    do {
                        try await EnterpriseServer.shared.debugDevSignIn(args[2], email: args[3])
                        write(["ok": true, "state": EnterpriseServer.shared.debugState], to: output)
                    } catch {
                        write(["ok": false, "error": error.localizedDescription], to: output)
                    }
                    model.refreshEnvironment()
                }
            case "logout": Task { await EnterpriseServer.shared.signOut(); model.refreshEnvironment() }
            case "expire": EnterpriseServer.shared.debugExpireAccess()
            case "glossary": Task { await EnterpriseServer.shared.refreshGlossary() }   // 重新拿公司词汇表（R53）
            case "join":   // join <shiyin://join?server=…>：等于点了加入链接（会跳出确认，出现在用户画面上）
                if let url = URL(string: args[2]) { Task { await EnterpriseJoin.handle(url) } }
            case "local": model.runner.transcribeLocally(meetingId: Int64(args[2]) ?? -1)
            case "info":   // info <网址> <输出.json>：只读服务器的 /api/v1/info、写出解析结果，不改账号和设置（本地 MCP 的 mcp 字段，design §44.6）
                let output = args[3]
                Task {
                    guard let url = EnterpriseServer.normalized(args[2]) else { write(["ok": false, "error": "bad url"], to: output); return }
                    do {
                        let info = try await EnterpriseServer.shared.fetchInfo(url)
                        write(["ok": true, "name": info.name, "llm": info.llm, "mcp": info.mcp.map { $0 as Any } ?? NSNull()], to: output)
                    } catch {
                        write(["ok": false, "error": error.localizedDescription], to: output)
                    }
                }
            default: break
            }
        case "llmkey":   // llmkey <account> <key>：只放内存
            Keychain.debugKeys[args[1]] = args[2] == "-" ? nil : args[2]
            Keychain.debugForget(args[1])
            Keychain.generation += 1   // 等于存了新的 key：解除暂停（design §34.4）
            model.refreshSummarizerProblem()
        case "keychainsim":   // keychainsim <account> denied|duplicate|-：模拟钥匙串回「拒绝」「已经有旧的」（design §22.1）
            Keychain.debugSimulated[args[1]] = args[2] == "-" ? nil : args[2]
            Keychain.debugForget(args[1])
        case "keychainreads": write(["reads": Keychain.debugReads], to: args[1])   // keychainreads <输出.json>：查钥匙串的次数
        case "llmprovider":   // llmprovider <整理工具> [模型] [思考强度]：只放内存，不改共用的设置；给 - 改回设置
            if args[1] == "-" {
                AppSettings.debugProvider = nil
                AppSettings.debugModel = nil
                AppSettings.debugThinkingEffort = nil
            } else {
                AppSettings.debugProvider = LLMProvider(rawValue: args[1])
                AppSettings.debugModel = args.count > 2 ? (args[2] == "-" ? nil : args[2]) : nil
                AppSettings.debugThinkingEffort = args.count > 3 ? ThinkingEffort(rawValue: args[3]) : nil
            }
            model.refreshSummarizerProblem()
        case "summarizer":   // summarizer <输出.json>：整理工具准备好了没、登录缓存、暂停（design §34.6）
            let problem = AppSettings.summarizerProblem
            write(["provider": AppSettings.provider.rawValue,
                   "model": AppSettings.model,
                   "thinkingEffort": AppSettings.thinkingEffort.rawValue,
                   "ready": problem == nil,
                   "problem": problem.map { String(describing: $0) } ?? "",
                   "message": problem?.message ?? "",
                   "action": problem?.actionTitle ?? "",
                   "shown": model.summarizerProblem.map { String(describing: $0) } ?? "",
                   "loggedIn": ["claude": CLILoginCache.loggedIn(.claude).map { $0 ? "yes" : "no" } ?? "unknown",
                                "codex": CLILoginCache.loggedIn(.codex).map { $0 ? "yes" : "no" } ?? "unknown",
                                "agy": CLILoginCache.loggedIn(.agy).map { $0 ? "yes" : "no" } ?? "unknown"]], to: args[1])
        case "loginrefresh":   // loginrefresh：重新查 claude、codex、agy 的登录状态
            Task {
                await CLILogin.refresh(.claude)
                await CLILogin.refresh(.codex)
                await CLILogin.refresh(.agy)
            }
        case "listmodels":  // listmodels <整理工具> <结果.json>：设置页「选择」用的模型清单
            if let provider = LLMProvider(rawValue: args[1]) {
                Task { write(["models": await LLMClient.listModels(provider)], to: args[2]) }
            }
        case "refreshmodels": model.refreshEnvironment()
        case "verifymodel":
            // verifymodel <文件> <结果.json>：用下载完成时同一个函数验证 SHA-256
            let ok = (try? ModelStore.verify(URL(fileURLWithPath: args[1]))) ?? false
            write(["valid": ok], to: args[2])
        case "state": write(state(), to: args[1])
        case "snapshot": snapshot(to: args[1], scheme: args.count > 2 ? args[2] : "light", target: args.count > 3 ? args[3] : "detail")
        case "filter": model.filter = args.count > 1 ? args[1] : ""
        // 文件夹（R9.2）：名称用「-」表示空的
        case "folder": if let id { model.moveToFolder(id, folder: args[2] == "-" ? "" : args[2]) }
        case "folderfilter": model.folderFilter = args.count > 1 && args[1] != "-" ? args[1] : nil
        case "renamefolder": model.renameFolder(args[1], to: args[2])
        case "deletefolder": model.deleteFolder(args[1])
        // 更新（R10.6）
        case "setupdateurl": UserDefaults.standard.set(args.count > 1 && args[1] != "-" ? args[1] : nil, forKey: Updater.urlKey)
        case "checkupdate": Task { await model.updater.check(userInitiated: true) }
        case "quitprompt":   // quitprompt <输出.json>：现在结束拾音的话会问什么（不真的结束；design §12 的下载中提醒）
            let prompt = AppDelegate.terminationPrompt()
            write(["prompt": prompt != nil, "title": prompt?.title ?? "", "info": prompt?.info ?? ""], to: args[1])
        case "installupdate":   // 等于在设置页按「下载并更新到」：install 自己会收起主窗口的询问（开着时 app 结束不了，替换会被取消）
            if case .available(let manifest) = model.updater.state {
                Task { await model.updater.install(manifest, model: model) }
            }
        case "dismissupdate": model.updater.prompt = nil
        // 匿名使用统计（design §30.7）：DEBUG 版只在这里设了网址才累计、送出
        case "usageurl":   // usageurl <网址|off>：只在内存设统计网址
            UsageStats.debugURL = args.count > 1 && args[1] != "off" ? args[1] : nil
            UsageStats.shared.touch()
        case "usage": write(UsageStats.shared.debugSnapshot(), to: args[1])   // usage <输出.json>：目前的文件和下一份要送的
        case "usageage": UsageStats.shared.debugAge(days: Int(args[1]) ?? 1)   // usageage <天数>：把今天的汇总改成几天前
        case "usagesend": Task { await UsageStats.shared.sendPending() }
        // 全域快捷键（R11.3）：不能送按键，用这个模拟按下
        case "hotkey":   // hotkey [bookmark]：模拟按下 ⌃⌥⌘R（或 ⌃⌥⌘B）
            if args.count > 1 && args[1] == "bookmark" { GlobalHotKey.shared.fireBookmark() } else { GlobalHotKey.shared.fire() }
        case "hotkeyenable": GlobalHotKey.shared.setEnabled(args[1] == "1")
        // 点通知后的动作（系统的点击没办法模拟，直接调用同一个处理函数）
        case "opennotification": if let id { model.notifier.onOpen?(id) }
        case "exportsheet": if args.count < 2 || args[1] == "1" { model.openExportSheet() } else { model.showExportSheet = false }
        // quit：照正常流程结束拾音（录音中、有工作时等于在确认对话框按「结束」）
        case "quit":
            confirmQuit = true
            NSApp.terminate(nil)
        // benchsave <会议 id> <段数> <输出.json>：存一份假的逐字稿，量 saveTranscript 花多久（design §20.11）
        case "benchsave":
            guard let meetingId = id, let count = Int(args[2]) else { return }
            let segments = (0..<count).map { i in
                Segment(meetingId: meetingId, seq: i, start: Double(i), end: Double(i + 1), text: "测试段落 \(i) Kubernetes 部署",
                        lowConfidence: false, speaker: nil, kind: "final")
            }
            let start = Date()
            do {
                try model.db.saveTranscript(meetingId, segments: segments, duration: count, speakerCount: 0)
                write(["seconds": Date().timeIntervalSince(start)], to: args[3])
            } catch {
                write(["error": "\(error)"], to: args[3])
            }
        // epipe <输出.json>：子程序没读完输入就结束（design §20.1）。拾音不能被 SIGPIPE 结束
        case "epipe":
            let path = args[1]
            var current = sigaction()
            sigaction(SIGPIPE, nil, &current)
            let ignored = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == 1   // SIG_IGN
            Task {
                do {
                    let result = try await Subprocess(URL(fileURLWithPath: "/usr/bin/true"), []).run(input: Data(count: 1 << 20))
                    write(["status": Int(result.status), "survived": true, "sigpipeIgnored": ignored], to: path)
                } catch {
                    write(["error": error.localizedDescription, "survived": true, "sigpipeIgnored": ignored], to: path)
                }
            }
        // 麦克风权限被拒时的提醒（R1.8）：真的拒绝要用户操作，这里只看画面
        case "permdenied": model.recorder.permissionDenied = args.count < 2 || args[1] == "1"
        case "info": model.selection = id; model.updateInfo(title: args[2], date: args[3], participants: args[4])
        case "closewindow":
            let prefix = args.count > 1 ? args[1] : "main"
            NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(prefix) == true }.forEach { $0.close() }
        case "openwindow": model.openWindowById?(args[1])
        case "windowlevel":   // windowlevel <窗口 id 开头> desktop|normal：放到桌面层（被所有窗口盖住，screencapture -l 照样截得到），不出现在用户的画面上
            let level = args.count > 2 && args[2] == "desktop" ? NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))) : .normal
            NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(args[1]) == true }.forEach { $0.level = level }
        // windowshot <窗口 id 或编号> <输出.png>：app 自己把窗口的内容画成图（屏幕上锁、窗口在桌面层或别的桌面也画得出来，
        // 输入框这些 AppKit 组件照样画；snapshot 的 ImageRenderer 画不出来）
        case "windowshot":
            guard args.count > 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == args[1] || "\($0.windowNumber)" == args[1] }),
                  let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            // 画出来的内容没有窗口的底色（材质、背景是窗口服务器画的），先铺上窗口的底色再叠上去
            let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            output.size = view.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
            }
            rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            try? output.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        case "exportui": model.openExportSheet()   // 等于按工具列的「导出」
        case "togglesidebar":   // togglesidebar [show|hide]：等于按工具列的侧栏按钮（不用座标点，工具列的按钮位置会跟着画面变）
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { break }
            func split(_ view: NSView) -> NSSplitView? { (view as? NSSplitView) ?? view.subviews.lazy.compactMap(split).first }
            guard let controller = window.contentView.flatMap(split)?.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else { break }
            let want = args.count > 1 ? args[1] == "show" : sidebar.isCollapsed
            if want == sidebar.isCollapsed { controller.toggleSidebar(nil) }
        case "mousehold": model.debugMouseHeld = args.count > 1 && args[1] == "on"   // mousehold on|off：当成左键按着（选中会议时先不换会议页，design §77）
        case "setkey": try? Keychain.set(args[1], args[2])          // setkey anthropic|openai <key>
        case "delkey": Keychain.delete(args[1])
        case "settings": model.openWindowById?(SettingsPage.windowID)
        case "preview":   // preview <settings|onboarding [步骤]|import|rename> [front] [height=<点>]（import：导入对话框；rename：说话者的改名小窗口，design §26.2、§24.2）
            // 设置窗口要 app 在前景才打得开；这里把画面放进桌面层的无边框窗口（被所有窗口盖住；
            // 屏幕外的窗口截不到），不抢前景，再用 screencapture -l 截（closewindow <settings|onboarding>-preview 关掉）。
            // preview detail：目前选中的会议页（量长会议的性能用，design §21.12：不在画面上的窗口 SwiftUI 不更新）
            let onboarding = args.count > 1 && args[1] == "onboarding"
            let detailPage = args.count > 1 && args[1] == "detail"
            // preview settings <页面代号或 0～10>：预览窗口一开始停在那一页（provider、templates、recording、transcription、models、
            // speakers、glossary、general、ai、enterprise、status，R108）
            let settingsPreview = args.count > 1 && args[1] == "settings"
            let pageArg = args.count > 2 && !args[2].hasPrefix("height=") && args[2] != "front" ? args[2] : ""
            SettingsView.previewPage = settingsPreview
                ? SettingsPage(rawValue: pageArg) ?? Int(pageArg).flatMap { SettingsPage.allCases.indices.contains($0) ? SettingsPage.allCases[$0] : nil } ?? .provider
                : nil
            // height=<点>：设置页要看下面的段落时拉高（桌面层的窗口卷不了）
            let height = args.first { $0.hasPrefix("height=") }.flatMap { Double($0.dropFirst(7)) }
            SettingsView.previewHeight = height.map { CGFloat($0) }
            let size = detailPage ? NSSize(width: 1100, height: 760)
                : settingsPreview ? NSSize(width: 820, height: height ?? 620) : NSSize(width: 640, height: height ?? 560)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            // 加 front：放在一般窗口层（会出现在用户画面上），辅助功能才看得到、按得到里面的按钮
            let front = args.contains("front")
            window.level = front ? .normal : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = front ? [.canJoinAllSpaces] : [.canJoinAllSpaces, .stationary]
            window.identifier = NSUserInterfaceItemIdentifier(onboarding ? "onboarding-preview" : detailPage ? "detail-preview" : "settings-preview")
            window.title = window.identifier!.rawValue
            window.isReleasedWhenClosed = false
            // editinfo、replace：会议页里自己打开的弹窗（编辑会议信息、用词修正，design §80），用目前选中的会议
            if args.count > 1, ["import", "rename", "editinfo", "replace", "rediarize", "noteseditor"].contains(args[1]) {
                window.identifier = NSUserInterfaceItemIdentifier("\(args[1])-preview")
                window.title = window.identifier!.rawValue
                let view: AnyView = switch args[1] {
                case "import": AnyView(ImportSheet(urls: [URL(fileURLWithPath: "/tmp/周会 0827.m4a")]).environment(model))   // l10n-skip
                case "editinfo":
                    if let meeting = model.detail?.meeting { AnyView(EditInfoForm(meeting: meeting) {}.environment(model)) } else { AnyView(EmptyView()) }
                case "replace": AnyView(ReplaceSheet(initialFind: "Lumeo").environment(model))
                case "noteseditor":   // 编辑会议记录（记录标签页的「编辑」，R6.6）
                    if let notes = model.detail?.notes {
                        AnyView(NotesEditor(notes: .constant(notes)) { _ in }.frame(width: 900, height: 560).environment(model))
                    } else { AnyView(EmptyView()) }
                case "rediarize":   // 重新识别说话者（示范会议没有录音，requestRediarize 打不开）
                    { model.rediarizeMeetingId = model.selection; return AnyView(RediarizeSheet().environment(model)) }()
                default: AnyView(RenameSpeakerForm(name: .constant("说话者 2"), automatic: true, onReject: {},   // l10n-skip
                                                   mergeTargets: [(1, "小明"), (3, "说话者 3")], onMerge: { _ in }, onSave: {}))   // l10n-skip
                }
                window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                window.setContentSize(window.contentView!.fittingSize)
            } else if detailPage {
                window.contentView = NSHostingView(rootView: AnyView(DetailPreview().environment(model)))
            } else {
                window.contentView = onboarding
                    ? NSHostingView(rootView: AnyView(OnboardingView(startStep: args.count > 2 ? Int(args[2]) ?? 0 : 0).environment(model)))
                    : NSHostingView(rootView: AnyView(SettingsView().environment(model)))
            }
            window.orderFrontRegardless()
        case "notifystatus":
            Task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                write(["authorization": settings.authorizationStatus.rawValue], to: args[1])
            }
        default: log.error("unknown debug command \(name)")
        }
    }

    /// coach prepare <title> <preparation.json> <result.json> | start <id> | append|review <id> <seconds> <text>
    /// coach analyze|stop|open|show <id> [output.json] | mark <id> <question UUID> <pending|asked|ignored>
    private static func coachCommand(_ args: [String]) {
        let model = AppModel.shared
        guard let command = args.first else { return }
        let id = args.count > 1 ? Int64(args[1]) : nil
        do {
            switch command {
            case "prepare" where args.count >= 4:
                let value = try JSONDecoder().decode(MeetingPreparation.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                let mid = model.saveMeetingPreparation(id: nil, title: args[1], preparation: value)
                write(["id": mid ?? -1, "error": model.errorMessage ?? ""], to: args[3])
            case "start":
                guard let id, var meeting = try model.db.meeting(id) else { return }
                meeting.source = "recording"
                try model.db.updateMeeting(meeting)
                model.coach.begin(id)
                model.coach.debugRecording = true
            case "pause": model.coach.debugRecording = false
            case "resume": model.coach.debugRecording = true
            case "append" where args.count >= 4:
                guard let id else { return }
                let start = Double(args[2]) ?? 0
                try model.db.appendLiveSegment(id, start: start, end: start + 5, text: args[3])
            case "review" where args.count >= 4:
                guard let id else { return }
                let start = Double(args[2]) ?? 0
                try model.db.appendReviewedSegment(id, start: start, end: start + 5, text: args[3])
            case "analyze": if let id { model.coach.analyze(id) }
            case "stop": model.coach.stop()
            case "finish":
                model.coach.stop()
                if let id, var meeting = try model.db.meeting(id) {
                    meeting.source = "transcript"
                    try model.db.updateMeeting(meeting)
                    try model.db.pool.write { db in
                        try db.execute(sql: "UPDATE segments SET kind = 'final' WHERE meeting_id = ? AND kind = 'reviewed'", arguments: [id])
                    }
                    model.reload()
                }
            case "mark" where args.count >= 4:
                if let id, let status = CoachQuestion.Status(rawValue: args[3]) { model.markCoachQuestion(id, question: args[2], status: status) }
            case "enabled" where args.count >= 3:
                if let id { model.setCoachEnabled(id, enabled: args[2] == "1") }
            case "show" where args.count >= 3:
                guard let id else { return }
                let state = try model.db.assistance(id)
                let data = try JSONEncoder().encode(state)
                write(["state": try JSONSerialization.jsonObject(with: data), "busy": model.coach.busy,
                       "message": model.coach.message, "active": model.coach.meetingId ?? -1,
                       "reference": state?.notesReference ?? ""], to: args[2])
            case "open":
                if let id { model.selection = id; model.tab = .ask }
                else { model.openPreparation() }
            case "failrecording": if let id { try model.preservePreparationOrDelete(id); model.reload() }
            default: break
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private static func state() -> [String: Any] {
        let model = AppModel.shared
        var out: [String: Any] = [
            "selection": model.selection ?? -1,
            // 多选、清空垃圾桶、分割会议（design §62、§64）
            "multiSelected": model.multiSelected, "showTrash": model.showTrash, "trashCount": model.trash.count,
            "confirmDelete": model.confirmDelete, "deleteTargets": model.deleteTargets, "confirmPurge": model.confirmPurge ?? [],
            "confirmEmptyTrash": model.confirmEmptyTrash, "splitMeetingRequest": model.splitMeetingRequest ?? -1,
            "splittingMeeting": model.applyingEdit ?? -1,
            "tab": model.tab.rawValue, "reviewExpanded": model.reviewExpanded, "userNotesExpanded": model.userNotesExpanded,
            "notesView": UserDefaults.standard.string(forKey: AppSettings.notesViewKey) ?? "list",
            "folderRules": model.folderRules.map { ["folder": $0.folder, "keywords": $0.keywords, "people": $0.people,
                                                    "templateId": $0.templateId ?? ""] as [String: Any] },
            "confirmRemovePerson": model.confirmRemovePerson ?? -1,
            "confirmDeleteFolder": model.confirmDeleteFolder ?? "",
            "renameTarget": model.renameTarget?.id ?? "",
            "editingNoteItem": model.editingNoteItem.map { "\($0)" } ?? "",
            "sidebarCollapsed": model.sidebarCollapsed.sorted(), "sidebarExpanded": model.sidebarExpanded.sorted(),
            "sidebarOrder": model.sidebarFolderItems.map(\.key), "showImportSheet": model.showImportSheet,
            "floatingMenu": FloatingMenuController.shared.debugTitles, "floatingMenuState": FloatingMenuController.shared.debugState,
            "floatingMenuWindow": FloatingMenuController.shared.debugWindowNumber,
            "list": ["sort": model.meetingSort.rawValue, "group": model.effectiveGrouping.rawValue,
                     "filter": ["review": model.meetingFilter.needsReview, "mine": model.meetingFilter.myActionItems,
                                "person": model.meetingFilter.personId ?? -1, "template": model.meetingFilter.templateId ?? ""] as [String: Any],
                     "filterSummary": model.filterSummary, "myName": model.myName ?? "",
                     "ids": model.filteredMeetings.map(\.id),
                     "groups": model.meetingGroups.map { ["title": $0.title, "count": $0.rows.count] as [String: Any] }] as [String: Any],
            // 本地 MCP（design §44.6）：开关、启动档
            "mcp": ["enabled": AppSettings.mcpEnabled, "launcher": MCPSetup.launcherURL.path,
                    "launcherExists": FileManager.default.fileExists(atPath: MCPSetup.launcherURL.path)] as [String: Any],
            // 播放条上的议题带（design §43.3）：选中中的会议，长度同播放条
            "topicRanges": model.detail.flatMap { d in
                d.notes.map { MindMap.topicRanges(notes: $0, duration: max(model.player.duration, Double(d.meeting.durationSeconds ?? 0)),
                                                  untitled: MindMap.topicLabel(.interface)) }
            }.map { $0.map { ["branch": $0.branch, "title": $0.title, "start": $0.start, "end": $0.end] } } ?? [],
            // 会议的参考文档（design §39.7）：选中中的会议
            "documents": (model.detail?.documents ?? []).map { d -> [String: Any] in
                let use = model.detail?.documentUse[d.id ?? 0]
                return ["id": d.id ?? 0, "name": d.name, "kind": d.kind, "file": d.file, "pages": d.pageTexts.count, "ocr": d.ocr,
                        "chars": d.pageTexts.reduce(0) { $0 + $1.count },
                        "includedPages": use?.includedPages ?? 0, "truncated": use?.truncated ?? false]
            },
            "readingDocuments": Dictionary(uniqueKeysWithValues: model.readingDocuments.map { (String($0.key), $0.value) }),
            "documentsChanged": model.documentsChanged.sorted(),
            // 选中的会议：说话者的名字、来源、建议、最像的几位认识的人（R33，「自动」名字的菜单）
            "speakers": (model.detail?.speakers ?? [:]).keys.sorted().map { idx -> [String: Any] in
                ["idx": idx, "name": model.detail?.speakers[idx] ?? "", "source": model.detail?.speakerSources[idx] ?? "",
                 "suggestion": model.detail?.speakerSuggestions[idx]?.name ?? "", "candidates": model.detail?.speakerCandidates[idx] ?? []]
            },
            "glossary": model.glossary.map(\.term),
            "glossarySuggestions": model.glossarySuggestions.map { ["term": $0.term, "source": $0.sourceLabel] },
            "environment": model.environment.items.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail, "fix": $0.fix] },
            "meetings": model.meetings.map { ["id": $0.id, "title": $0.meeting.displayTitle, "date": $0.meeting.meetingDate,
                                               "status": model.status($0).label, "audio": $0.meeting.audioFile,
                                               "template": $0.meeting.templateId, "folder": $0.meeting.folder] },
            "queuedCount": model.queuedCount,
            "filteredCount": model.filteredMeetings.count,
            "menuBarSymbol": model.menuBarSymbol,
            "micStatus": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "openMainWindowReady": model.openMainWindow != nil,
            "detailMeeting": model.detail?.meeting.id ?? -1,
            "applyingEdit": model.applyingEdit ?? -1,
            "editingMeeting": model.editingMeeting ?? -1,
            "editor": MeetingEditor.debugCurrent.map { e -> [String: Any] in
                ["start": e.start, "end": e.end, "deleted": e.deleted.map { [$0.lowerBound, $0.upperBound] }, "cut": e.cut ?? -1,
                 "playhead": e.playhead, "zoom": e.zoom, "total": e.total, "isPlaying": e.isPlaying, "hasChanges": e.hasChanges,
                 "planDuration": e.plan.duration, "preview": e.debugPreview, "pieces": e.plan.pieces.map { [$0.meetingId, $0.start, $0.end] as [Any] }]
            } ?? [:],
            "meetingEdit": model.detail.flatMap { try? model.db.editRecord($0.meeting.id!) }.map { r -> [String: Any] in
                ["audioFile": r.audioFile, "daysLeft": r.daysLeft(), "splitInto": r.splitIds, "mergedFrom": r.mergedIds, "editedAt": r.editedAt]
            } ?? [:],
            // 侧栏的表格（拖动，design §77）：直直往上下拖会不会开始拖动
            "sidebarTables": NSApp.windows.filter { $0.identifier?.rawValue == "main" }.flatMap { window -> [[String: Any]] in
                func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
                return window.contentView.map(tables)?.map {
                    ["class": String(describing: type(of: $0)), "verticalMotionCanBeginDrag": $0.verticalMotionCanBeginDrag,
                     "allowsMultipleSelection": $0.allowsMultipleSelection, "rows": $0.numberOfRows]
                } ?? []
            },
            "running": model.runner.running.map { lane, r in
                ["lane": lane.rawValue, "job": r.job.id ?? 0, "kind": r.job.kind.rawValue, "stage": r.stage, "progress": r.progress ?? -1,
                 "remaining": r.remaining ?? -1, "server": r.server.map { ["text": $0.text, "waiting": $0.waiting] } as Any] },
            "enterprise": EnterpriseServer.shared.debugState,
            // 找到的 claude、codex、agy：用户自己装的，或桌面版附的（design §37.4）
            "tools": ["claude": Paths.locateTool("claude").map { ["path": $0.url.path, "desktopApp": $0.desktopApp ?? ""] } as Any,
                      "codex": Paths.locateTool("codex").map { ["path": $0.url.path, "desktopApp": $0.desktopApp ?? "",
                                                                "extraPath": $0.extraPath] } as Any,
                      "agy": Paths.locateTool("agy").map { ["path": $0.url.path, "desktopApp": $0.desktopApp ?? ""] } as Any,
                      "claudeDesktop": DesktopApps.hasClaude],
            "transcriptionEngine": AppSettings.transcriptionEngine,
            "textSize": TextSize.level,   // 会议内容的文字大小（design §38.5）
            // 提醒事项（design §52.2）：假的列表里的每一项、目前这场会议的状态
            "reminders": FakeReminders.shared.entries.map { entry -> [String: Any] in
                ["title": entry.item.title, "notes": entry.item.notes, "url": entry.item.url.absoluteString, "completed": entry.completed,
                 "due": entry.item.due.map { "\($0.year ?? 0)-\($0.month ?? 0)-\($0.day ?? 0)" } ?? ""]
            },
            "reminderStatus": model.reminderStatus,
            "island": RecordingIsland.shared.debugInfo,   // 录音岛（design §57.3）
            // 人物页（design §60.2）
            "sidebarMode": model.sidebarMode.rawValue, "selectedPerson": model.selectedPerson ?? -1,
            "peopleOverview": model.peopleOverview.map { ["id": $0.id, "name": $0.name, "meetings": $0.meetingCount,
                                                          "last": $0.lastMeetingDate ?? "", "me": $0.isMe] },
            // 我的声音（design §56.3）
            "selfPerson": ((try? model.db.enrollment()) ?? nil).map { ["id": $0.personId, "name": $0.name, "createdAt": $0.createdAt] } as Any,
            "remindersAccess": Reminders.store.access.rawValue,
            "player": ["loaded": model.player.isLoaded, "playing": model.player.isPlaying,
                       "time": model.player.currentTime, "duration": model.player.duration, "rate": model.player.rate,
                       "mixing": model.player.isMixing,
                       "mix": ChannelMix.stats.withLock { ["frames": $0.frames, "sourcePeaks": $0.sourcePeaks, "mixedPeak": $0.mixedPeak] }],
            "recorder": ["recording": model.recorder.isRecording, "paused": model.recorder.isPaused,
                         "meetingId": model.recorder.meetingId ?? -1, "elapsed": model.recorder.elapsed,
                         "micLevel": model.recorder.micLevel, "systemLevel": model.recorder.systemLevel,
                         "liveLines": model.recorder.liveLines.count, "volatile": model.recorder.volatileText,
                         "liveStatus": model.recorder.liveStatus, "permissionDenied": model.recorder.permissionDenied,
                         "levelCheck": model.recorder.levelCheck,   // 收音提醒（design §26.1）
                         "permissionRestarts": model.recorder.permissionRestarts,   // 允许了权限而重新接上电脑声音（design §51.1）
                         "systemSilent": model.recorder.systemSilent,
                         "idle": model.recorder.idleInfo,   // 忘了停止录音（design §35）
                         "failure": model.recorder.failureMessage ?? "", "language": model.recorder.language.rawValue,
                         "languageSwitch": model.recorder.languageSwitch.map { "\($0.from.rawValue)→\($0.to.rawValue)" } ?? "",
                         "deviceWarning": model.recorder.deviceWarning ?? "",
                         "restarts": model.recorder.restartInfo,   // 重新连接的节奏（design §50.4）
                         // 麦克风（design §38.7）
                         "micDevice": model.recorder.micDevice.map { ["name": $0.name, "uid": $0.uid, "bluetooth": $0.isBluetooth] } as Any,
                         "micHint": model.recorder.micHint.map { ["text": $0.text, "builtIn": $0.builtIn?.name ?? ""] } as Any],
            "microphones": ["inputs": MicrophoneMonitor.shared.inputs.map { ["name": $0.name, "uid": $0.uid, "bluetooth": $0.isBluetooth,
                                                                            "builtIn": $0.isBuiltIn] },
                            "default": MicrophoneMonitor.shared.defaultInput?.uid ?? "", "setting": AppSettings.inputDeviceUID],
            "languages": ["defaultMeeting": AppSettings.defaultMeetingLanguage.rawValue, "interface": MeetingLanguage.interface.rawValue,
                          "interfaceScript": MeetingLanguage.interfaceCode, "chineseScript": "simplified",
                          "preferred": Locale.preferredLanguages.first ?? ""],
            "models": ["breeze": "\(model.models.state)", "japanese": "\(model.models.state(.japanese))",
                       "qwen": "\(model.models.combinedState(.qwen))",
                       "languageDetection": "\(model.models.state(.languageDetection))", "diarizer": "\(model.models.diarizerState)",
                       "nemotron": "\(model.models.nemotronState)", "diarizationModel": AppSettings.diarizationModel.rawValue],
            "exportMeeting": model.exportMeetingId as Any,
            "search": ["query": model.searchQuery, "results": model.searchResults.map { ["meeting": $0.meetingId, "kind": $0.kind.rawValue, "ref": $0.ref, "snippet": $0.snippet] }],
            "trash": model.trash.map { $0.id },
            "templates": model.templates.map { $0.id },
            "folders": model.folders.map { ["name": $0.name, "count": $0.count] },
            "folderFilter": model.folderFilter ?? "",
            "update": ["state": model.updater.state.label, "prompt": model.updater.prompt?.version ?? "",
                       "received": model.updater.progress?.received ?? -1, "total": model.updater.progress?.total ?? -1,
                       "progressText": model.updater.progress?.text ?? "",
                       "version": Updater.currentVersion, "feed": Updater.feedURLString],
            "hotkey": ["registered": GlobalHotKey.shared.isRegistered, "status": Int(GlobalHotKey.shared.status),
                       "bookmarkRegistered": GlobalHotKey.shared.isBookmarkRegistered],
            "notifications": model.notifier.recent,
            "filteredIds": model.filteredMeetings.map(\.id),
            "highlightSegment": model.highlightSegment ?? -1,
            "errorMessage": model.errorMessage ?? "",
            "noticeMessage": model.noticeMessage ?? "",
            // 窗口的最小尺寸（SwiftUI 依内容算的）：录音中卡住的调查用；sharing 是分享画面时藏不藏（0 none、1 readOnly，design §53）
            "windows": NSApp.windows.map { ["id": $0.identifier?.rawValue ?? "", "title": $0.title, "visible": $0.isVisible,
                                            "minWidth": $0.contentMinSize.width, "minHeight": $0.contentMinSize.height,
                                            "minSizeW": $0.minSize.width, "minSizeH": $0.minSize.height,
                                            "width": $0.frame.width, "height": $0.frame.height,
                                            "number": $0.windowNumber, "sharing": $0.sharingType.rawValue,
                                            // 最大尺寸可能是无限大（录音岛），JSON 写不进去会当掉：写 -1
                                            "resizable": $0.styleMask.contains(.resizable), "maxW": finite($0.maxSize.width), "maxH": finite($0.maxSize.height),
                                            "contentMaxW": finite($0.contentMaxSize.width), "contentMaxH": finite($0.contentMaxSize.height)] },
        ]
        if let status = model.detailStatus { out["detailStatus"] = status.label }
        if let detail = model.detail {
            out["transcribedWith"] = detail.meeting.transcribedWith
            out["canUpgradeTranscript"] = model.canUpgradeTranscript(detail.meeting)   // design §21.17
            out["minSpeakers"] = detail.meeting.minSpeakers ?? 0   // design §23
            out["showRediarizeSheet"] = model.showRediarizeSheet
            out["speakerCheck"] = detail.meeting.speakerCheck ?? -1   // design §24.6
            out["showsSpeakerHint"] = detail.showsSpeakerHint
            out["speakerUndo"] = (try? model.db.speakerUndoLabel(detail.meeting.id!)) ?? ""
            out["manualSegments"] = detail.segments.filter(\.speakerManual).count
        }
        return out
    }

    /// 提示文字是 placeholder 的输入框（依画面上的顺序）
    private static func textField(placeholder: String, index: Int) -> NSTextField? {
        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable,
               field.placeholderString == placeholder || field.placeholderAttributedString?.string == placeholder {
                found.append(field)
            }
            view.subviews.forEach(walk)
        }
        for window in NSApp.windows where window.isVisible { window.contentView.map(walk) }
        return found.indices.contains(index) ? found[index] : nil
    }

    /// 所有看得到的窗口里，标签或标题等于 label 的按钮（依组件树的顺序）
    private static func accessibilityButtons(label: String) -> [NSAccessibilityProtocol] {
        var found: [NSAccessibilityProtocol] = []
        func walk(_ element: NSAccessibilityProtocol, depth: Int) {
            guard depth < 80 else { return }
            if element.accessibilityRole() == .button,
               element.accessibilityLabel() == label || element.accessibilityTitle() == label {
                found.append(element)
            }
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? NSAccessibilityProtocol { walk(child, depth: depth + 1) }
            }
        }
        for window in NSApp.windows where window.isVisible { walk(window, depth: 0) }
        return found
    }

    /// 主窗口里可以编辑的 NSTextView（笔记标签页、录音画面的笔记输入框）
    private static func notesTextView() -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, textView.isEditable, !textView.isFieldEditor { return textView }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.contentView.flatMap(find) }.first
    }

    /// 下一个开始追踪的菜单（右键菜单、「⋯」）：项目写到 path（子菜单展开成「父 ▸ 子」），然后关掉，不留在用户画面上
    private static var menuObserver: NSObjectProtocol?
    private static var eventMonitor: Any?
    private static var eventLogPath: String?
    private static let eventLogStart = ProcessInfo.processInfo.systemUptime

    /// eventlog 开着时写一行（拖动开始了没这类，事件以外的东西也写进同一份）
    static func note(_ text: String) {
        guard let path = eventLogPath else { return }
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - eventLogStart) + text + "\n"
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
    }
    /// keep：菜单留着几秒再关（给外面截屏）
    /// 接下来打开的菜单（右键、「⋯」）直接选标题是 title 的那一项（子菜单用「移到文件夹 ▸ 客户」），等于用户点了它
    private static func pickNextMenu(_ title: String) {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, menu.supermenu == nil, menu != NSApp.mainMenu else { return }
            if let observer = menuObserver { NotificationCenter.default.removeObserver(observer); menuObserver = nil }
            nonisolated(unsafe) let tracked = menu
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    tracked.update()
                    var current: NSMenu? = tracked
                    let path = title.components(separatedBy: " ▸ ")
                    for (i, part) in path.enumerated() {
                        guard let m = current, let index = m.items.firstIndex(where: { $0.title == part }) else { break }
                        if i == path.count - 1 {
                            tracked.cancelTracking()
                            m.performActionForItem(at: index)
                        } else {
                            m.items[index].submenu?.update()
                            current = m.items[index].submenu
                        }
                    }
                    tracked.cancelTracking()
                }
            }
        }
    }

    private static func captureNextMenu(to path: String, keep: Double = 0) {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, menu.supermenu == nil, menu != NSApp.mainMenu else { return }
            if let observer = menuObserver { NotificationCenter.default.removeObserver(observer); menuObserver = nil }
            func titles(_ m: NSMenu, _ prefix: String) -> [String] {
                m.items.flatMap { item -> [String] in
                    let hidden = item.isHidden ? "（隐藏）" : ""
                    if item.isSeparatorItem { return [prefix + "——" + hidden] }
                    let header = item.isSectionHeader ? "【段落】" : ""
                    let line = prefix + header + item.title + (item.isEnabled ? "" : "（禁用）") + (item.state == .on ? "（✓）" : "") + hidden
                    return [line] + (item.submenu.map { titles($0, prefix + item.title + " ▸ ") } ?? [])
                }
            }
            // SwiftUI 的菜单内容在开始追踪时才补齐，等一下再读（菜单追踪时主线程在 event tracking 模式，要排在 common）
            nonisolated(unsafe) let tracked = menu
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    tracked.update()
                    write(["items": titles(tracked, "")], to: path)
                    if keep > 0 {
                        let timer = Timer(timeInterval: keep, repeats: false) { _ in MainActor.assumeIsolated { tracked.cancelTracking() } }
                        RunLoop.main.add(timer, forMode: .common)
                    } else {
                        tracked.cancelTracking()
                    }
                }
            }
        }
    }

    /// 无限大、NaN 写成 -1（JSONSerialization 遇到会丢 Objective-C 例外，整个 app 当掉）
    private static func finite(_ x: CGFloat) -> CGFloat { x.isFinite ? x : -1 }

    private static func write(_ object: [String: Any], to path: String) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// correct-eval <transcribe-eval 的输出.json> <设置.json> <输出.json>：用目前的整理工具跑逐字稿校正，
    /// 输出「全部接受」之后的逐字稿和所有建议（design §17.4），格式跟 transcribe-eval 一样，可以直接评分。
    /// 设置：{"language": "zh", "glossary": [...], "title": "…", "participants": [...]}
    private static func correctEval(input: String, options: String, output: String) {
        Task { @MainActor in
            let started = Date()
            var result: [String: Any] = ["input": input]
            do {
                guard let source = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [String: Any],
                      var segments = source["segments"] as? [[String: Any]],
                      let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: options))) as? [String: Any]
                else { throw LLMError.badOutput("bad input") }
                let language = MeetingLanguage(rawValue: settings["language"] as? String ?? "zh") ?? .zh
                let speakerName = { (s: [String: Any]) -> String? in
                    (s["speaker"] as? Int).map { language.defaultSpeaker($0) }
                }
                let context = TranscriptCorrection.Context(
                    language: language,
                    title: settings["title"] as? String ?? "", participants: settings["participants"] as? [String] ?? [],
                    speakerNames: [], glossary: settings["glossary"] as? [String] ?? [],
                    segments: segments.map { ($0["text"] as? String ?? "", speakerName($0)) })
                let suggestions = try await TranscriptCorrection.suggest(context, provider: AppSettings.provider, model: AppSettings.model,
                                                                         onStart: { _ in }, onProgress: { _ in })
                for s in suggestions {
                    if let text = segments[s.segment]["text"] as? String, let fixed = TranscriptCorrection.apply(s, to: text) {
                        segments[s.segment]["text"] = fixed
                    }
                }
                result["segments"] = segments
                result["duration"] = source["duration"]
                result["options"] = source["options"]
                result["suggestions"] = suggestions.map { ["segment": $0.segment, "original": $0.original,
                                                           "suggestion": $0.suggestion, "reason": $0.reason] }
            } catch {
                result["error"] = error.localizedDescription
            }
            result["elapsed"] = Date().timeIntervalSince(started)
            write(result, to: output + ".tmp")
            try? FileManager.default.removeItem(atPath: output)
            try? FileManager.default.moveItem(atPath: output + ".tmp", toPath: output)
        }
    }

    /// segment-embed <录音> <时段.json：[[开始, 结束], …]> <输出.json>：每一段带着前后文（10 秒的窗、遮罩只标这一段）
    /// 用 FluidAudio 的 wespeaker_v2 算声纹，给短句的实验离线比对（design §6.3.2）。模型放在缓存文件夹，不放进拾音的模型文件夹
    private static func segmentEmbed(audio: String, spans: String, output: String, batched: Int? = nil) {
        Task { @MainActor in
            let started = Date()
            var result: [String: Any] = ["audio": audio]
            do {
                let samples = try await AudioDecoder.decode(URL(fileURLWithPath: audio))
                let list = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: spans))) as? [[Double]]) ?? []
                // batched：用 app 的做法（SpeakerRecheck，一次三句），跟 FluidAudio 的 extractor 比
                if let batched {
                    let model = try await SpeakerRecheck.prepare()
                    result["embeddings"] = try SpeakerRecheck.embed(list.map { ($0[0], $0[1]) }, samples: samples, model: model, perCall: batched)
                    result["elapsed"] = Date().timeIntervalSince(started)
                    write(result, to: output + ".tmp")
                    try? FileManager.default.removeItem(atPath: output)
                    try? FileManager.default.moveItem(atPath: output + ".tmp", toPath: output)
                    return
                }
                let dir = URL.cachesDirectory.appending(path: "ShiyinEval/wespeaker", directoryHint: .isDirectory)
                let models = try await DiarizerModels.downloadIfNeeded(to: dir)
                let extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
                let shape = models.segmentationModel.modelDescription.outputDescriptionsByName["segments"]?.multiArrayConstraint?.shape
                let frames = shape.map { $0[1].intValue } ?? 589
                let window = 160_000, rate = AudioDecoder.sampleRate
                var embeddings: [Any] = []
                for span in list where span.count == 2 {
                    let center = (span[0] + span[1]) / 2
                    let start = max(0, min(Int((center - 5) * rate), samples.count - window))
                    var clip = Array(samples[start..<min(samples.count, start + window)])
                    if clip.count < window { clip += [Float](repeating: 0, count: window - clip.count) }
                    let from = Double(start) / rate
                    let mask = (0..<frames).map { i -> Float in
                        let t = from + (Double(i) + 0.5) * 10 / Double(frames)
                        return t >= span[0] && t <= span[1] ? 1 : 0
                    }
                    guard mask.reduce(0, +) >= 1 else { embeddings.append(NSNull()); continue }
                    embeddings.append(try extractor.getEmbeddings(audio: clip, masks: [mask], minActivityThreshold: 0).first ?? [])
                }
                result["embeddings"] = embeddings
            } catch {
                result["error"] = "\(error)"
            }
            result["elapsed"] = Date().timeIntervalSince(started)
            write(result, to: output + ".tmp")
            try? FileManager.default.removeItem(atPath: output)
            try? FileManager.default.moveItem(atPath: output + ".tmp", toPath: output)
        }
    }

    /// transcribe-eval <录音> <设置.json> <输出.json>：用跟 app 一样的转录流程跑一次，不创建会议、不写数据库（design §17.1）。
    /// 输出写完才出现（先写暂存档再改名），评估脚本等这个文件出现就能读
    private static func transcribeEval(audio: String, options: String, output: String) {
        Task { @MainActor in
            let started = Date()
            var result: [String: Any] = ["audio": audio]
            let meter = MemoryMeter()
            do {
                let options = try JSONDecoder().decode(TranscriptionOptions.self, from: Data(contentsOf: URL(fileURLWithPath: options)))
                result["options"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options))
                result["whisperDefaults"] = WhisperEngine.defaultParameters()   // whisper.cpp 的默认值（实验时对照用，design §17.1）
                var pipeline = TranscriptionPipeline(options: options)
                pipeline.stage = { meter.set(stage: $0) }
                if let run = try await pipeline.run(URL(fileURLWithPath: audio)) {
                    result["duration"] = run.duration
                    result["seams"] = run.seams
                    result["segments"] = run.segments.enumerated().map { i, segment -> [String: Any] in
                        ["start": segment.start, "end": segment.end, "text": segment.text,
                         "speaker": run.speakers[i] ?? NSNull(), "channel": run.channels[i] ?? NSNull(),
                         "lowConfidence": segment.lowConfidence]
                    }
                }
            } catch {
                result["error"] = error.localizedDescription
            }
            result["elapsed"] = Date().timeIntervalSince(started)
            result["memory"] = meter.stop()
            write(result, to: output + ".tmp")
            try? FileManager.default.removeItem(atPath: output)
            try? FileManager.default.moveItem(atPath: output + ".tmp", toPath: output)
        }
    }

    private static func qwenChunks(audio: String, output: String, maxSeconds: Double, anyChange: Bool, splitMixed: Bool) {
        Task { @MainActor in
            var result: [String: Any] = ["audio": audio, "maxSeconds": maxSeconds]
            do {
                let samples = try await AudioDecoder.decode(URL(fileURLWithPath: audio))
                let diarization = try await Diarizer.diarize(samples: samples, minSpeakers: nil) { _ in }
                let chunks = QwenEngine.chunks(samples, turns: diarization.turns, maxSeconds: maxSeconds, anyChange: anyChange, splitMixed: splitMixed)
                let rate = AudioDecoder.sampleRate
                result["turns"] = diarization.turns.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end] }
                result["chunks"] = chunks.map { ["start": Double($0.range.lowerBound) / rate, "end": Double($0.range.upperBound) / rate] }
                result["median"] = samples.withUnsafeBufferPointer { QwenEngine.medianFrameEnergy($0) }
            } catch {
                result["error"] = error.localizedDescription
            }
            write(result, to: output)
        }
    }

    /// detect-eval <音档> <开始秒数> <输出.json>：从开始秒数起，跟录音时一样收集 10 秒有声音的片段做语言检测（design §18.8）
    private static func detectEval(audio: String, start: Double, output: String) {
        Task { @MainActor in
            var result: [String: Any] = ["audio": audio, "start": start]
            do {
                let samples = try await AudioDecoder.decode(URL(fileURLWithPath: audio))
                let from = min(samples.count, Int(start * AudioDecoder.sampleRate))
                let box = DetectBox()
                let collector = LanguageDetector.Collector { box.samples = $0 }
                var position = from
                while box.samples == nil && position < samples.count {
                    let end = min(samples.count, position + 1600)
                    collector.feed(Array(samples[position..<end]))
                    position = end
                }
                guard let voiced = box.samples else { throw WhisperError.empty }
                result["used"] = Double(position - from) / AudioDecoder.sampleRate
                let path = ModelStore.path(.languageDetection).path
                let probabilities = try await Task.detached { try LanguageDetector.detect(voiced, modelPath: path) }.value
                result["probabilities"] = Dictionary(uniqueKeysWithValues: probabilities.map { ($0.key.rawValue, $0.value) })
                result["detected"] = probabilities.max { $0.value < $1.value }?.key.rawValue ?? ""
            } catch {
                result["error"] = error.localizedDescription
            }
            write(result, to: output)
        }
    }

    private final class DetectBox: @unchecked Sendable { var samples: [Float]? }

    /// 屏幕锁定时没办法截窗口，改用 ImageRenderer 把画面画成图片（AppKit 组件会变成黄色占位框）
    private static func snapshot(to path: String, scheme: String, target: String) {
        let model = AppModel.shared
        let content: AnyView
        switch target {
        case "guide":
            content = AnyView(GuideView().frame(width: 680))
        case "menubar":
            content = AnyView(MenuBarContent().frame(width: 290))
        case "setup":
            content = AnyView(OnboardingView())
        case "import":
            content = AnyView(ImportSheet(urls: [URL(fileURLWithPath: "/tmp/周会 0827.m4a")]))
        case "onboarding":
            content = AnyView(OnboardingView())
        case "export":
            content = AnyView(ExportSheet())
        case "glossary":
            content = AnyView(GlossarySettings().frame(width: 560, height: 420))
        case "recording":
            guard let detail = model.detail else { return }
            content = AnyView(RecordingPanel(detail: detail).frame(width: 900, height: 520))
        case "recording-lines":
            guard model.recorder.simulatedTranscriptState != nil else { return }
            content = AnyView(VStack(alignment: .leading, spacing: 8) {
                ForEach(model.recorder.liveLines) { line in LiveTranscriptLineView(line: line, starred: false) }
            }.contentFont().padding(20).frame(width: 600, alignment: .leading))
        case "coach":
            guard let detail = model.detail else { return }
            content = AnyView(MeetingAssistancePanel(meeting: detail.meeting, recording: false).padding(20).frame(width: 620))
        case "prepared":
            guard let detail = model.detail else { return }
            content = AnyView(PreparedMeetingView(meeting: detail.meeting).frame(width: 900))
        case "replace":
            content = AnyView(ReplaceSheet(initialFind: "Lumeo"))
        case "folders":
            // 侧栏的文件夹区块（List 画不出来，用同样的列重组）
            content = AnyView(VStack(alignment: .leading, spacing: 8) {
                Text("文件夹").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FolderRow(name: "所有会议", count: model.meetings.count, symbol: "tray.full", selected: model.folderFilter == nil) {}
                ForEach(model.folders, id: \.name) { folder in
                    FolderRow(name: folder.name, count: folder.count, symbol: "folder", selected: model.folderFilter == folder.name) {}
                }
                Text(model.folderFilter ?? "所有会议").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(model.filteredMeetings) { row in MeetingRowView(row: row, status: model.status(row)) }
            }
            .padding(14).frame(width: 280))
        case "sidebar":
            content = AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(model.filteredMeetings) { row in
                    MeetingRowView(row: row, status: model.status(row)).padding(.horizontal, 12)
                    Divider()
                }
            }.frame(width: 260))
        case let t where t.hasPrefix("speaker-"):
            // speaker-2：逐字稿只看说话者 2
            guard let detail = model.detail else { return }
            content = AnyView(SnapshotView(detail: detail, tab: .transcript, speakerFilter: Int(t.dropFirst(8))).frame(width: 900))
        default:
            guard let detail = model.detail else { return }
            content = AnyView(SnapshotView(detail: detail, tab: model.tab).frame(width: 900))
        }
        let view = content
            .environment(model)
            .environment(\.snapshotMode, true)
            .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: scheme == "dark" ? NSColor(white: 0.13, alpha: 1) : .white))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// preview detail：跟主窗口一样的会议页，跟着 selection 换
private struct DetailPreview: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let detail = model.detail { MeetingDetailView(detail: detail) } else { Text("没有选中会议") }  // l10n-skip
    }
}

/// 截屏用：标题、状态栏、标签页内容、播放列（不含 NavigationSplitView 与工具列）
private struct SnapshotView: View {
    let detail: MeetingDetail
    let tab: DetailTab
    var speakerFilter: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            MeetingTop(detail: detail)
            Divider()
            Group {
                switch tab {
                case .summary: NotesPage(detail: detail)
                case .transcript: TranscriptTab(detail: detail, speakerFilter: speakerFilter)
                case .ask: AskTab(detail: detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            PlayerBar(detail: detail)
        }
        .tint(.celadon)
    }
}
#endif
