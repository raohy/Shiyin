import SwiftUI

/// 逐字稿标签页（R4）：时间点跳播、播放时高亮跟随、搜索、单段编辑、全文取代
struct TranscriptTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.textScale) private var scale
    let detail: MeetingDetail

    @State private var query = ""
    @State private var matchCursor = 0
    @State private var editingId: Int64?
    @State private var editText = ""
    @State private var draftTask: Task<Void, Never>?
    @State private var showReplace = false
    @State private var showCorrectionGroups = false
    /// 播放中的段落。由 PlaybackFollower 在换段时才更新，播放时间每次变动不会让整份列表重算（design §21.12）
    @State private var currentSegmentId: Int64?
    @State private var speakerFilter: Int?
    /// 正在改名的说话者和点的那一段：改名窗口挂在点的那一段（逐字稿是延迟创建的，第一段可能还不存在）
    @State private var renaming: (speaker: Int, segment: Int64)?
    @State private var renameText = ""
    /// 拆成两句（design §46.2）：正在拆的那一句、光标的位置（UTF-16）、后半句的说话者（nil 是新的说话者）
    @State private var splittingId: Int64?
    @State private var splitOffset: Int?
    @State private var splitTarget: Int?
    @FocusState private var searchFocused: Bool

    init(detail: MeetingDetail, speakerFilter: Int? = nil) {
        self.detail = detail
        _speakerFilter = State(initialValue: speakerFilter)
    }

    private var visibleSegments: [Segment] {
        guard let speakerFilter else { return detail.segments }
        return detail.segments.filter { $0.speaker == speakerFilter }
    }

    private var matches: [Int64] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return visibleSegments.filter { $0.text.localizedCaseInsensitiveContains(q) }.compactMap(\.id)
    }


    private var pendingCorrections: Int { detail.corrections.filter { $0.status == "pending" }.count }



    var body: some View {
        #if DEBUG
        let _ = DebugMetrics.bump("transcriptBody")
        #endif
        VStack(spacing: 0) {
            PlaybackFollower(detail: detail, current: $currentSegmentId)
            searchBar
            Divider()
            // 我的笔记收在逐字稿顶部（R44.3，design §33.1）
            UserNotesDisclosure(detail: detail)
            Divider()
            if model.canUpgradeTranscript(detail.meeting) && model.detailStatus?.isActive != true {
                upgradeBar
                Divider()
            }
            if detail.showsSpeakerHint && model.detailStatus?.isActive != true {
                speakerHintBar
                Divider()
            }
            if pendingCorrections > 0 && !snapshotMode {
                correctionBar
                Divider()
            }
            if detail.segments.isEmpty {
                Text(model.detailStatus?.isActive == true ? "转录完成后，逐字稿会出现在这里。" : "没有逐字稿。")
                    .foregroundStyle(.secondary)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else if snapshotMode {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleSegments.prefix(18)) { segment in row(segment) }
                }
                .contentFont()   // 文字大小（design §38.5）
                .frame(maxWidth: 760 * scale, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleSegments) { segment in
                                row(segment)
                                    .id(segment.id)
                            }
                        }
                        .contentFont()   // 文字大小（design §38.5）
                        .frame(maxWidth: 760 * scale, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: currentSegmentId) { _, id in
                        guard let id, model.player.isPlaying, editingId == nil else { return }
                        if reduceMotion { proxy.scrollTo(id, anchor: .center) }
                        else { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: matchCursor) { _, cursor in
                        if matches.indices.contains(cursor) { proxy.scrollTo(matches[cursor], anchor: .center) }
                    }
                    .onChange(of: query) { _, _ in
                        matchCursor = 0
                        if let first = matches.first { proxy.scrollTo(first, anchor: .center) }
                    }
                    // 单段编辑的草稿（design §21.15、R20.6）：换标签页、换会议、结束拾音都还在
                    .onAppear(perform: restoreEditDraft)
                    .onChange(of: editText) { _, _ in scheduleEditDraft() }
                    .onDisappear {
                        draftTask?.cancel()
                        saveEditDraft()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .flushDrafts)) { _ in
                        draftTask?.cancel()
                        saveEditDraft()
                    }
                    #if DEBUG
                    .onChange(of: model.debugEditSegment) { _, id in
                        if let segment = detail.segments.first(where: { $0.id == id }) { startEdit(segment) }
                        model.debugEditSegment = nil
                    }
                    #endif
                    .onChange(of: model.splitRequest, initial: true) { _, id in
                        guard let id else { return }
                        model.splitRequest = nil
                        startSplit(id)
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: model.highlightSegment, initial: true) { _, id in
                        guard let id else { return }
                        // 要跳到的段落被说话者筛选藏起来时，先取消筛选
                        if !visibleSegments.contains(where: { $0.id == id }) { speakerFilter = nil }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showReplace) {
            ReplaceSheet(initialFind: query)
        }
        // 合并、改说话者后筛选的那位不见了：回到所有说话者
        .onChange(of: detail.speakers.keys.sorted()) { _, keys in
            if let speakerFilter, !keys.contains(speakerFilter) { self.speakerFilter = nil }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索逐字稿", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if !matches.isEmpty { matchCursor = (matchCursor + 1) % matches.count } }
                if !query.isEmpty {
                    Text(matches.isEmpty ? "找不到" : "\(min(matchCursor + 1, matches.count))／\(matches.count) 段")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 360)
            // ⌘F 聚焦搜索框（design §9.4）
            Button("搜索") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
                .frame(width: 0)
            if !detail.speakers.isEmpty {
                Picker("说话者", selection: $speakerFilter) {
                    Text("所有说话者").tag(Int?.none)
                    ForEach(detail.speakers.keys.sorted(), id: \.self) { idx in
                        Text(detail.speakers[idx] ?? detail.meeting.meetingLanguage.defaultSpeaker(idx)).tag(Int?.some(idx))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("只看某一位说话者的内容")
            }
            Spacer()
            if detail.segments.contains(where: \.lowConfidence) {
                Label("琥珀色是识别信心低的段落", systemImage: "circle.fill")
                    .labelStyle(SmallDotLabelStyle())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("用词修正…") { showReplace = true }
                // 转录或整理中不能改：工作完成时会整份写回逐字稿或会议记录
                .disabled(detail.segments.isEmpty || model.detailStatus?.isActive == true)
                .help("把逐字稿和会议记录里的同一个词一起改掉")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// 重新转录会用的模型（design §41.3）
    private var upgradeText: String {
        switch ModelStore.transcription(for: detail.meeting.meetingLanguage) {
        case .japanese:
            return String(localized: "这场会议是在模型下载好之前，用 macOS 内置识别转录的。可以用\(MeetingLanguage.uiNames(model: "turbo"))转录模型重新转录，通常比较准。")
        case .qwen: return String(localized: "这场会议是在模型下载好之前，用 macOS 内置识别转录的。可以用 Qwen3-ASR 重新转录，通常比较准。")
        default: return String(localized: "这场会议是在模型下载好之前，用 macOS 内置识别转录的。可以用 Breeze 重新转录，通常比较准。")
        }
    }

    /// 模型下载好之前用 macOS 内置识别转录的会议（design §21.17）
    private var upgradeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(Color.signal)
            Text(upgradeText)
            // 不能加 fixedSize：在 HStack 里量最小高度时会用很窄的宽度，算出很高的高度，整个窗口的内容被往上推
            Spacer()
            Button("重新转录") { model.retranscribe() }
                .buttonStyle(.borderedProminent)
                .help("逐字稿里改过的文字会换成新的逐字稿，说话者的名字会留着")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .font(.callout)
        .controlSize(.small)
        .background(Color.signal.opacity(0.08))
    }

    /// 说话者可能分得不够（design §24.5）：说话者识别的自我检查觉得可能把不同的人并在一起
    private var speakerHintBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape").foregroundStyle(Color.signal)
            Text("说话者可能分得不够：有些不同的人可能被当成同一位。人多、吵杂或手机放在桌上录音时常发生，告诉拾音大约几个人会分得比较准。")
            // 不能加 fixedSize：理由同 upgradeBar
            Spacer()
            Button("不用了") { model.dismissSpeakerHint() }
                .help("这场会议不再提示")
            Button("重新识别说话者…") { model.requestRediarize() }
                .buttonStyle(.borderedProminent)
                .help("只重新分辨谁在说话，逐字稿的文字不会变")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .font(.callout)
        .controlSize(.small)
        .background(Color.signal.opacity(0.08))
    }

    /// 有待确认的校正建议时，显示在搜索列下方；可以展开依词处理（同一个词的每一处一起接受或忽略）
    private var correctionBar: some View {
        let groups = detail.correctionGroups
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(Color.signal)
                Text("\(pendingCorrections) 处可能听错的字，已标在逐字稿里")
                Button(showCorrectionGroups ? "收起" : "依词处理（\(groups.count) 组）") { showCorrectionGroups.toggle() }
                    .buttonStyle(.link)
                    .help("同一个词的每一处一起接受或忽略")
                Spacer()
                Button("全部忽略") { model.rejectAllCorrections() }
                Button("全部接受") { model.acceptAllCorrections() }
                    .buttonStyle(.borderedProminent)
                    .help("把所有建议套用到逐字稿，之后还能逐条还原")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if showCorrectionGroups {
                Divider()
                // 组数少时照内容的高度，超过 220 才滚动（ScrollView 的理想高度是内容的高度，最多 220）
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(groups, id: \.first!.id) { group in correctionGroupRow(group) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .background(Color.signal.opacity(0.08))
    }

    /// 一组「原文 → 建议」：点文字跳到第一处
    private func correctionGroupRow(_ group: [Correction]) -> some View {
        let first = group[0]
        let ids = group.compactMap(\.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.flashSegment(first.segmentId)
            } label: {
                Text("「\(first.original)」→「\(first.suggestion)」").fontWeight(.medium).meetingText()
            }
            .buttonStyle(.plain)
            .help("跳到第一处")
            Text("\(group.count) 处").foregroundStyle(.secondary).monospacedDigit()
            Text(first.reason).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button("忽略") { model.rejectCorrections(ids) }
                .buttonStyle(.link)
            Button(group.count > 1 ? "接受 \(group.count) 处" : "接受") { model.acceptCorrections(ids) }
                .buttonStyle(.link)
        }
        .font(.caption)
    }

    /// 一则校正建议：待确认的有接受、忽略；已接受的可以还原
    @ViewBuilder
    private func correctionLine(_ c: Correction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if c.status == "accepted" {
                Text("已改成「\(c.suggestion)」（原本是「\(c.original)」）")
                    .foregroundStyle(.secondary)
                Button("还原") { if let id = c.id { model.revertCorrection(id) } }
                    .buttonStyle(.link)
            } else {
                Text("「\(c.original)」→「\(c.suggestion)」").fontWeight(.medium).meetingText()
                Text(c.reason).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("忽略") { if let id = c.id { model.rejectCorrection(id) } }
                    .buttonStyle(.link)
                Button("接受") { if let id = c.id { model.acceptCorrection(id) } }
                    .buttonStyle(.link)
            }
        }
        .contentFont(.caption)
    }

    @ViewBuilder
    private func row(_ segment: Segment) -> some View {
        let isCurrent = segment.id == currentSegmentId
        let isHighlighted = segment.id == model.highlightSegment
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            TimeButton(time: TimeFormat.string(segment.start), seek: segment.start)
                .frame(width: 58 * scale, alignment: .trailing)
            if let idx = segment.speaker {
                Button(detail.speakerName(idx) ?? "") {
                    renameText = detail.speakerName(idx) ?? ""
                    if let id = segment.id { renaming = (idx, id) }
                }
                .buttonStyle(.plain)
                .contentFont(.callout, weight: .medium)
                .foregroundStyle(Color.speaker(idx))
                .frame(width: 72 * scale, alignment: .leading)
                .lineLimit(1)
                .help("点一下帮这位说话者改名")
                .popover(isPresented: Binding(get: { renaming?.segment == segment.id && segment.id != nil },
                                              set: { if !$0 { renaming = nil } })) {
                    RenameSpeakerForm(name: $renameText, automatic: detail.speakerSources[idx] == "voiceprint",
                                      onReject: { model.rejectVoiceprintMatch(idx); renaming = nil },
                                      mergeTargets: otherSpeakers(than: idx),
                                      onMerge: { into in
                                          renaming = nil
                                          model.mergeSpeaker(idx, into: into)
                                      },
                                      undoLabel: detail.speakerUndoLabel,
                                      onUndo: { renaming = nil; model.undoSpeakerEdit() }) {
                        model.renameSpeaker(idx, to: renameText)
                        renaming = nil
                    }
                }
            }
            if splittingId == segment.id {
                splitEditor(segment)
            } else if editingId == segment.id {
                VStack(alignment: .trailing, spacing: 6) {
                    TextField("段落内容", text: $editText, axis: .vertical).meetingText()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveEdit(segment) }
                    HStack {
                        Button("取消") { cancelEdit() }
                            .keyboardShortcut(.cancelAction)
                        Button("保存") { saveEdit(segment) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            } else {
                // 每一段的校正建议（design §17.4）：待确认的标在文字上并列出，已接受的可以还原，已拒绝的不显示
                let corrections = segment.id.flatMap { detail.correctionsBySegment[$0] } ?? []
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlighted(segment.text, corrections: corrections)).meetingText()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) { startEdit(segment) }
                    ForEach(corrections) { correctionLine($0) }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(isCurrent ? Color.celadon.opacity(0.13) : isHighlighted ? Color.signal.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if segment.lowConfidence {
                RoundedRectangle(cornerRadius: 1).fill(Color.signal).frame(width: 3).padding(.vertical, 6)
            }
        }
        .contextMenu {
            Button("从这里播放") { model.player.seek(to: segment.start) }
            Button("编辑这一段") { startEdit(segment) }
            Button("拷贝") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
            // 改这句的说话者（design §24.3、R23.2）
            if let id = segment.id, segment.kind == "final", !detail.speakers.isEmpty {
                Divider()
                Button("拆成两句…") { startSplit(id) }   // R70
                Menu("这句是谁说的") { speakerChoices(for: [id], current: segment.speaker) }
                let run = detail.speakerRun(around: id)
                if run.count > 1 {
                    Menu("这段连续的话是谁说的（\(run.count) 句）") { speakerChoices(for: run, current: segment.speaker) }
                }
                // 复原最近一次说话者的调整（R44.4，原本在「更多」）：有东西可复原才出现
                if let label = detail.speakerUndoLabel {
                    Button("复原：\(label)") { model.undoSpeakerEdit() }
                }
            }
        }
        .help(segment.lowConfidence ? "识别信心低，建议对照录音确认" : "")
    }

    // MARK: 拆成两句（R70、design §46.2）

    private func startSplit(_ id: Int64) {
        guard let index = detail.segments.firstIndex(where: { $0.id == id }) else { return }
        if model.detailStatus?.isActive == true {
            model.noticeMessage = String(localized: "正在处理这场会议，完成后才能改说话者")
            return
        }
        if editingId != nil { cancelEdit() }
        // 默认：下一句的说话者；下一句是同一位时用上一句的；都是同一位时新的说话者
        let current = detail.segments[index].speaker
        let next = detail.segments.dropFirst(index + 1).first?.speaker
        let previous = index > 0 ? detail.segments[index - 1].speaker : nil
        splitTarget = [next, previous].compactMap { $0 }.first { $0 != current }
        splitOffset = nil
        splittingId = id
    }

    /// 前半句、后半句（去掉头尾的空白）；任一边没有字是 nil（R70.2，同 `AppDatabase.splitSegment`）
    private func splitParts(_ text: String) -> (head: String, tail: String)? {
        guard let offset = splitOffset else { return nil }
        let ns = text as NSString
        guard offset > 0, offset < ns.length else { return nil }
        let blanks = CharacterSet(charactersIn: " \t\n\r\u{3000}")
        let head = ns.substring(to: offset).trimmingCharacters(in: blanks)
        let tail = ns.substring(from: offset).trimmingCharacters(in: blanks)
        return head.isEmpty || tail.isEmpty ? nil : (head, tail)
    }

    @ViewBuilder
    private func splitEditor(_ segment: Segment) -> some View {
        let parts = splitParts(segment.text)
        VStack(alignment: .leading, spacing: 6) {
            Text("在文字里点一下要拆开的地方").font(.caption).foregroundStyle(.secondary)
            SplitTextView(text: segment.text, scale: scale, offset: $splitOffset)
                .frame(minHeight: 40)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            if let parts {
                Text("前半句：…\(String(parts.head.suffix(8)))｜后半句：\(String(parts.tail.prefix(8)))…")
                    .font(.caption).foregroundStyle(.secondary).meetingText()
            }
            HStack {
                Picker("后半句是", selection: $splitTarget) {
                    ForEach(detail.speakers.keys.sorted(), id: \.self) { idx in
                        let name = detail.speakerName(idx) ?? ""
                        Text(idx == segment.speaker ? String(localized: "\(name)（同一位）") : name).tag(Optional(idx))
                    }
                    Divider()
                    Text("新的说话者").tag(Int?.none)
                }
                .fixedSize()
                Spacer()
                Button("取消") { splittingId = nil }
                    .keyboardShortcut(.cancelAction)
                Button("拆开") {
                    guard let id = segment.id, let offset = splitOffset else { return }
                    splittingId = nil
                    model.splitSegment(id, at: offset, to: splitTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(parts == nil)
            }
            .controlSize(.small)
        }
    }

    /// 除了 idx 以外的说话者（合并、改说话者的菜单）
    private func otherSpeakers(than idx: Int?) -> [(idx: Int, name: String)] {
        detail.speakers.keys.sorted().filter { $0 != idx }.map { ($0, detail.speakerName($0) ?? "") }
    }

    @ViewBuilder
    private func speakerChoices(for ids: [Int64], current: Int?) -> some View {
        ForEach(otherSpeakers(than: current), id: \.idx) { speaker in
            Button(speaker.name) { model.reassignSegments(ids, to: speaker.idx) }
        }
        Divider()
        Button("新的说话者") { model.reassignSegments(ids, to: nil) }
    }

    private func highlighted(_ text: String, corrections: [Correction] = []) -> AttributedString {
        var attributed = AttributedString(text)
        // 待确认的校正建议：原文加底线和底色
        for c in corrections where c.status == "pending" {
            if let range = attributed.range(of: c.original) {
                attributed[range].underlineStyle = .single
                attributed[range].backgroundColor = Color.signal.opacity(0.2)
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: q, options: .caseInsensitive) {
            attributed[range].backgroundColor = Color.signal.opacity(0.35)
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }

    private func startEdit(_ segment: Segment) {
        if model.detailStatus?.isActive == true {
            model.noticeMessage = String(localized: "正在处理这场会议，完成后才能编辑逐字稿")
            return
        }
        // 正在改别段的话，那一段的草稿不留（跟按取消一样）
        if editingId != nil && editingId != segment.id { cancelEdit() }
        editText = segment.text
        editingId = segment.id
    }

    private func saveEdit(_ segment: Segment) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = segment.id, !text.isEmpty, text != segment.text { model.updateSegment(id, text: text) }
        clearEditDraft()
        editingId = nil
    }

    private func cancelEdit() {
        clearEditDraft()
        editingId = nil
    }

    private func clearEditDraft() {
        draftTask?.cancel()
        model.deleteDrafts(detail.meeting.id!, prefix: "segment:")
    }

    /// 打字停 0.8 秒存一次
    private func scheduleEditDraft() {
        guard editingId != nil else { return }
        draftTask?.cancel()
        draftTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveEditDraft()
        }
    }

    /// 跟原本一样（刚开始编辑、改回原样）就不留草稿
    private func saveEditDraft() {
        guard let editingId else { return }
        let original = detail.segments.first { $0.id == editingId }?.text
        model.saveDraft(detail.meeting.id!, key: "segment:\(editingId)", text: editText == original ? "" : editText)
    }

    /// 上次没存的编辑：回到编辑状态，内容是草稿
    private func restoreEditDraft() {
        guard editingId == nil, let draft = model.latestDraft(detail.meeting.id!, prefix: "segment:"),
              let id = Int64(draft.key.dropFirst("segment:".count)),
              detail.segments.contains(where: { $0.id == id }) else { return }
        editText = draft.text
        editingId = id
        model.flashSegment(id)
    }
}

struct RenameSpeakerForm: View {
    @Binding var name: String
    /// 名字是声纹自动带入的：多一个「不是他」（design §21.4）
    var automatic = false
    var onReject: (() -> Void)? = nil
    /// 「合并到…」（design §24.2）：其他说话者
    var mergeTargets: [(idx: Int, name: String)] = []
    var onMerge: ((Int) -> Void)? = nil
    /// 可以复原的说话者调整（R44.4）：有才显示「复原」
    var undoLabel: String? = nil
    var onUndo: (() -> Void)? = nil
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("说话者名字").font(.headline)
            TextField("例如：小明", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)
            if automatic {
                Text("这个名字是拾音认出声音后自动带入的。不对的话直接改名，或按「不是他」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("整场逐字稿和之后的会议记录都会用这个名字；拾音也会记住这个人的声音，之后的会议自动带入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if automatic, let onReject { Button("不是他", action: onReject) }
                if !mergeTargets.isEmpty, let onMerge {
                    Menu("合并到…") {
                        ForEach(mergeTargets, id: \.idx) { target in
                            Button(target.name) { onMerge(target.idx) }
                        }
                    }
                    .fixedSize()
                    .help("同一个人被分成两位时，把这位说的话全部算到另一位")
                }
                Spacer()
                Button("保存", action: onSave).keyboardShortcut(.defaultAction)
            }
            if let undoLabel, let onUndo {
                Button("复原：\(undoLabel)", systemImage: "arrow.uturn.backward", action: onUndo)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("复原最近一次合并或改句子的说话者")
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

struct SmallDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(Color.signal).frame(width: 3, height: 12)
            configuration.title
        }
    }
}

/// 全文取代（R4.5、design §6.4）
struct ReplaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialFind: String
    @State private var find = ""
    @State private var replacement = ""
    @State private var addToGlossary = true
    @State private var result: ReplaceResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用词修正").font(.title3.weight(.semibold))
            Text("把逐字稿里的错字换成正确写法，会议记录里同样的字也会一起改。区分大小写。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("错误写法", text: $find)
                TextField("正确写法", text: $replacement)
                Toggle("把正确写法加进词汇表，之后转录比较容易一次转对", isOn: $addToGlossary)
            }
            .formStyle(.columns)
            if let result {
                Text(resultText(result))
                    .font(.callout)
                    .foregroundStyle(Color.celadon)
            }
            HStack {
                Spacer()
                Button(result == nil ? "取消" : "完成", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("全部取代") {
                    result = model.replace(find: find, with: replacement, addToGlossary: addToGlossary)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(find.isEmpty || find == replacement)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { find = initialFind }
    }

    private func resultText(_ r: ReplaceResult) -> String {
        if r.segmentsChanged == 0 && !r.notesChanged { return String(localized: "没有找到「\(find)」。") }
        var parts: [String] = []
        if r.segmentsChanged > 0 { parts.append(String(localized: "逐字稿改了 \(r.segmentsChanged) 段")) }
        if r.notesChanged { parts.append(String(localized: "会议记录也一起改了（按「编辑」旁的「复原上一版」可以还原）")) }
        return parts.joined(separator: String(localized: "，")) + String(localized: "。")
    }
}

/// 播放跟随（design §21.12）：只有这个 view 读播放时间（每 0.1 秒变一次），算出目前的段落，换段时才更新外面的状态
private struct PlaybackFollower: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @Binding var current: Int64?

    var body: some View {
        let time = model.player.currentTime
        let id = model.player.isPlaying || time > 0 ? detail.segmentId(at: time) : nil
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: id, initial: true) { _, new in
                if current != new { current = new }
            }
    }
}

/// 拆成两句时放光标的文字（design §46.2）：看得到光标、选得到位置，但不能改字。位置用 UTF-16（NSString 的单位）
private struct SplitTextView: NSViewRepresentable {
    let text: String
    let scale: CGFloat
    @Binding var offset: Int?

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 2)
        view.setAccessibilityLabel(String(localized: "要拆开的句子"))
        view.string = text
        view.font = .systemFont(ofSize: NSFont.systemFontSize * scale)
        view.textContainer?.widthTracksTextView = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.font = .systemFont(ofSize: NSFont.systemFontSize * scale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(width - 4, 10), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height) + 4)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SplitTextView
        init(parent: SplitTextView) { self.parent = parent }

        /// 不能改字（打字、粘贴、删除都挡掉），光标照样看得到
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { false }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let location = view.selectedRange().location
            parent.offset = location == NSNotFound ? nil : location
        }
    }
}
