import Foundation
import Observation

/// 会中分析独立运行，取消或失败都不影响录音（design §46.2）。
@MainActor
@Observable
final class MeetingCoach {
    let db: AppDatabase
    private(set) var meetingId: Int64?
    private(set) var busy = false
    private(set) var message = ""
    private(set) var lastUpdated: Date?
    @ObservationIgnored var canAnalyze: (Int64) -> Bool = { _ in false }
    @ObservationIgnored var onChange: (Int64) -> Void = { _ in }
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var process: Subprocess?
    @ObservationIgnored private var token: UUID?

    #if DEBUG
    var debugRecording = false
    #endif

    init(db: AppDatabase) { self.db = db }

    func begin(_ id: Int64) {
        stop()
        meetingId = id
        lastUpdated = nil
        message = String(localized: "等待新的复核文字")
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                var interval = 30.0
                #if DEBUG
                let configured = UserDefaults.standard.double(forKey: "debugCoachInterval")
                if configured > 0 { interval = configured }
                #endif
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.meetingId == id else { return }
                self.analyze(id, automatic: true)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        cancelRequest()
        meetingId = nil
        #if DEBUG
        debugRecording = false
        #endif
    }

    func cancelRequest() {
        token = nil
        request?.cancel()
        deadline?.cancel()
        process?.terminate()
        request = nil
        deadline = nil
        process = nil
        busy = false
    }

    func analyze(_ id: Int64, automatic: Bool = false) {
        var recording = canAnalyze(id)
        #if DEBUG
        recording = recording || debugRecording
        #endif
        guard meetingId == id, recording, !busy else { return }
        do {
            guard let state = try db.assistance(id), state.preparation.enabled else { return }
            guard AppSettings.summarizerReady else {
                message = AppSettings.summarizerProblem?.message ?? String(localized: "请先设置整理工具，再使用会中提问助手")
                return
            }
            let lines = try db.reviewedCoachLines(id, from: state.nextSeq)
            let batch = CoachBatch(lines: lines, state: state)
            guard !batch.lines.isEmpty else {
                if !automatic { message = String(localized: "还没有新的复核文字，请等待音频复核") }
                return
            }
            let prompt = try MeetingCoachPrompt.input(state: state, batch: batch)
            let provider = AppSettings.provider, model = AppSettings.model
            let current = UUID()
            token = current
            busy = true
            message = String(localized: "正在分析会议内容…")
            request = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.token == current {
                        self.deadline?.cancel()
                        self.deadline = nil
                        self.request = nil
                        self.process = nil
                        self.token = nil
                        self.busy = false
                    }
                }
                do {
                    try Task.checkCancellation()
                    let format = LLMClient.OutputFormat(schema: MeetingCoachPrompt.schema, toolName: "save_meeting_questions",
                                                        toolDescription: "Save cumulative meeting context and suggested follow-up questions")
                    let data = try await LLMClient.generateJSON(provider: provider, model: model, system: MeetingCoachPrompt.system,
                                                               prompt: prompt, format: format, onStart: { self.process = $0 })
                    try Task.checkCancellation()
                    guard self.token == current, self.meetingId == id else { return }
                    let output = try JSONDecoder().decode(CoachOutput.self, from: data)
                    try self.db.mergeCoachOutput(id, output: output, batch: batch)
                    self.lastUpdated = Date()
                    self.message = String(localized: "已更新提问建议")
                    self.onChange(id)
                } catch {
                    guard self.token == current, !Task.isCancelled else { return }
                    self.message = String(localized: "分析失败，已有问题已保留：\(error.localizedDescription)")
                }
            }
            deadline = Task { [weak self] in
                var timeout = 45.0
                #if DEBUG
                let configured = UserDefaults.standard.double(forKey: "debugCoachTimeout")
                if configured > 0 { timeout = configured }
                #endif
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let self, self.token == current else { return }
                self.cancelRequest()
                self.message = String(localized: "分析超时，已有问题已保留，可以重试")
            }
        } catch {
            message = String(localized: "无法准备会中分析：\(error.localizedDescription)")
        }
    }
}
