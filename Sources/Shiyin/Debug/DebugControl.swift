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
        // notesview list|mindmap：记录标签页切换成条列或心智图（design §42.5；写进共用设置，测完 defaults delete com.weiwei.shiyin notesView）
        case "notesview":
            UserDefaults.standard.set(args.count > 1 && args[1].lowercased() == "mindmap" ? "mindMap" : "list", forKey: AppSettings.notesViewKey)
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
        case "undo": model.selection = id; model.undoNotes()
        case "trash": if let id { model.moveToTrash(id) }
        case "restore": if let id { model.restore(id) }
        case "purge": if let id { model.deletePermanently(id) }
        case "confirmpurge": model.confirmPurge = id   // 等于在垃圾桶按右键「永久删除…」
        case "reviewexpand":
            // reviewexpand <会议 id> <summary|decisions|actionItems|openQuestions|topic|custom> <位置> [第二个位置]：
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
            write(["asking": model.asking != nil, "questions": list.map { ["question": $0.question, "scope": $0.scope, "provider": $0.provider,
                                                                            "answer": (try? JSONSerialization.jsonObject(with: Data($0.answer.utf8))) ?? [:]] }],
                  to: args[2])
        case "cancelask": model.cancelAsk()
        // 检测会议（design §21.7）：meetingapp <bundleID> start|stop；meetingprompts <输出.json>；meetingaction <按钮>
        case "meetingapp": model.meetingDetector.simulated[args[1]] = args[2] == "start"
        case "meetingprompts":
            let current = MeetingPromptPanel.shared.current
            let text: String
            switch current {
            case .start(let app): text = "start:\(app.bundleID)"
            case .stop(let app): text = "stop:\(app.bundleID)"
            case nil: text = ""
            }
            write(["prompt": text, "actions": MeetingPromptPanel.shared.actions.keys.sorted(), "muted": MeetingDetector.muted,
                   "recording": model.recorder.isRecording], to: args[1])
        case "meetingaction": MeetingPromptPanel.shared.perform(args[1])
        // reportinfo <输出.json>：反馈问题会附上的内容和网址（不打开浏览器、不动剪贴板，design §21.9）
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
                        let diarization = try await Diarizer.diarize(samples: samples, clustering: clustering, config: config) { _ in }
                        // dump：<路径>.f32 是每个片段的声纹（256 个 Float32 一笔），<路径>.json 是对应的群、片段、片段里的说话者
                        if let dump = item["dump"] {
                            var floats: [Float] = []
                            for chunk in diarization.chunks { floats += chunk.embedding256 }
                            try floats.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: dump + ".f32"))
                            write(["cluster": diarization.chunks.map(\.speakerId), "chunk": diarization.chunks.map(\.chunkIndex),
                                   "local": diarization.chunks.map(\.speakerIndex), "start": diarization.chunks.map(\.startTimeSeconds),
                                   "end": diarization.chunks.map(\.endTimeSeconds)], to: dump + ".json")
                        }
                        let speakers: [[String: Any]] = diarization.voiceprints.keys.sorted().map { number in
                            ["number": number, "seconds": diarization.speechSeconds[number] ?? 0,
                             "embedding": diarization.voiceprints[number] ?? [],
                             "turns": diarization.turns.filter { $0.speaker == number }.map { [$0.start, $0.end] }]
                        }
                        results.append(["name": item["name"] ?? file, "seconds": Double(samples.count) / AudioDecoder.sampleRate,
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
            let target = args.count > 3 ? args[3] : "main"
            guard let x = Double(args[1]), let y = Double(args[2]),
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == target }) else { break }
            let point = NSPoint(x: x, y: window.frame.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        case "bookmark": model.addBookmark(at: Double(args[2]) ?? 0, meetingId: id)
        case "addterm": model.addTerm(args[1])
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
            // record-sim <音档> <倍速> <both: 1/0>
            model.startSimulatedRecording(file: URL(fileURLWithPath: args[1]), speed: Double(args[2]) ?? 1, both: args.count > 3 && args[3] == "1")
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
        case "llmprovider":   // llmprovider <整理工具> [模型]：只放内存，不改共用的设置；给 - 改回设置
            AppSettings.debugProvider = args[1] == "-" ? nil : LLMProvider(rawValue: args[1])
            AppSettings.debugModel = args.count > 2 ? args[2] : nil
            model.refreshSummarizerProblem()
        case "summarizer":   // summarizer <输出.json>：整理工具准备好了没、登录缓存、暂停（design §34.6）
            let problem = AppSettings.summarizerProblem
            write(["provider": AppSettings.provider.rawValue,
                   "ready": problem == nil,
                   "problem": problem.map { String(describing: $0) } ?? "",
                   "message": problem?.message ?? "",
                   "action": problem?.actionTitle ?? "",
                   "shown": model.summarizerProblem.map { String(describing: $0) } ?? "",
                   "loggedIn": ["claude": CLILoginCache.loggedIn(.claude).map { $0 ? "yes" : "no" } ?? "unknown",
                                "codex": CLILoginCache.loggedIn(.codex).map { $0 ? "yes" : "no" } ?? "unknown"]], to: args[1])
        case "loginrefresh":   // loginrefresh：重新查 claude、codex 的登录状态
            Task {
                await CLILogin.refresh(.claude)
                await CLILogin.refresh(.codex)
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
        case "setkey": try? Keychain.set(args[1], args[2])          // setkey anthropic|openai <key>
        case "delkey": Keychain.delete(args[1])
        case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "preview":   // preview <settings|onboarding [步骤]|import|rename> [front]（import：导入对话框；rename：说话者的改名小窗口，design §26.2、§24.2）
            // 设置窗口要 app 在前景才打得开；这里把画面放进桌面层的无边框窗口（被所有窗口盖住；
            // 屏幕外的窗口截不到），不抢前景，再用 screencapture -l 截（closewindow <settings|onboarding>-preview 关掉）。
            // preview detail：目前选中的会议页（量长会议的性能用，design §21.12：不在画面上的窗口 SwiftUI 不更新）
            let onboarding = args.count > 1 && args[1] == "onboarding"
            let detailPage = args.count > 1 && args[1] == "detail"
            // preview settings <标签页编号>：预览窗口一开始停在那个标签页（0 整理工具 … 4 录音、5 模型与保存空间）
            SettingsView.previewTab = args.count > 2 && args[1] == "settings" ? Int(args[2]) ?? 0 : 0
            let size = detailPage ? NSSize(width: 1100, height: 760) : NSSize(width: 640, height: 560)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            // 加 front：放在一般窗口层（会出现在用户画面上），辅助功能才看得到、按得到里面的按钮
            let front = args.contains("front")
            window.level = front ? .normal : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = front ? [.canJoinAllSpaces] : [.canJoinAllSpaces, .stationary]
            window.identifier = NSUserInterfaceItemIdentifier(onboarding ? "onboarding-preview" : detailPage ? "detail-preview" : "settings-preview")
            window.title = window.identifier!.rawValue
            window.isReleasedWhenClosed = false
            if args.count > 1 && (args[1] == "import" || args[1] == "rename") {
                window.identifier = NSUserInterfaceItemIdentifier("\(args[1])-preview")
                window.title = window.identifier!.rawValue
                let view = args[1] == "import"
                    ? AnyView(ImportSheet(urls: [URL(fileURLWithPath: "/tmp/周会 0827.m4a")]).environment(model))   // l10n-skip
                    : AnyView(RenameSpeakerForm(name: .constant("说话者 2"), mergeTargets: [(1, "小明"), (3, "说话者 3")],   // l10n-skip
                                                onMerge: { _ in }, onSave: {}))
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

    /// coach prepare <title> <preparation.json> <result.json> | start <id> | append <id> <seconds> <text>
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
            case "analyze": if let id { model.coach.analyze(id) }
            case "stop": model.coach.stop()
            case "finish":
                model.coach.stop()
                if let id, var meeting = try model.db.meeting(id) {
                    meeting.source = "transcript"
                    try model.db.updateMeeting(meeting)
                    try model.db.pool.write { db in
                        try db.execute(sql: "UPDATE segments SET kind = 'final' WHERE meeting_id = ? AND kind = 'live'", arguments: [id])
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
            "tab": model.tab.rawValue, "reviewExpanded": model.reviewExpanded, "userNotesExpanded": model.userNotesExpanded,
            "notesView": UserDefaults.standard.string(forKey: AppSettings.notesViewKey) ?? "list",
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
            "running": model.runner.running.map { lane, r in
                ["lane": lane.rawValue, "job": r.job.id ?? 0, "kind": r.job.kind.rawValue, "stage": r.stage, "progress": r.progress ?? -1,
                 "remaining": r.remaining ?? -1, "server": r.server.map { ["text": $0.text, "waiting": $0.waiting] } as Any] },
            "enterprise": EnterpriseServer.shared.debugState,
            // 找到的 claude、codex：用户自己装的，或桌面版附的（design §37.4）
            "tools": ["claude": Paths.locateTool("claude").map { ["path": $0.url.path, "desktopApp": $0.desktopApp ?? ""] } as Any,
                      "codex": Paths.locateTool("codex").map { ["path": $0.url.path, "desktopApp": $0.desktopApp ?? "",
                                                                "extraPath": $0.extraPath] } as Any,
                      "claudeDesktop": DesktopApps.hasClaude],
            "transcriptionEngine": AppSettings.transcriptionEngine,
            "textSize": TextSize.level,   // 会议内容的文字大小（design §38.5）
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
                       "languageDetection": "\(model.models.state(.languageDetection))", "diarizer": "\(model.models.diarizerState)"],
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
            // 窗口的最小尺寸（SwiftUI 依内容算的）：录音中卡住的调查用
            "windows": NSApp.windows.map { ["id": $0.identifier?.rawValue ?? "", "title": $0.title, "visible": $0.isVisible,
                                            "minWidth": $0.contentMinSize.width, "minHeight": $0.contentMinSize.height,
                                            "minSizeW": $0.minSize.width, "minSizeH": $0.minSize.height,
                                            "width": $0.frame.width, "height": $0.frame.height] },
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

    private static func write(_ object: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
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
