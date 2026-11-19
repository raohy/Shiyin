# 会中实时复核显示 Implementation Plan

> **For agentic workers:** Execute the tasks in this isolated workspace, preserving the original checkout and running the named checks.

**Goal:** 录音界面先显示快稿，复核成功后自动显示对应复核文字。

**Architecture:** 新增纯内存显示时间线，合并成功复核覆盖范围，保守保留跨边界快稿。Recorder 将快稿、带时间的暂定文字和复核事件送入时间线，持久化路径不变。

**Tech Stack:** Swift、SwiftUI、XCTest、隔离 DEBUG 应用、本地假 LLM。

**Spec:** `docs/superpowers/specs/2026-11-19-live-reviewed-display-design.md`

## Global Constraints

- 基于最新 `main` 的独立功能分支；不得影响用户正在运行的应用、数据或设置。
- 中英文文案一起维护；不改变数据库 schema；真实模型与麦克风是否验证须如实报告。

## Review Focus

- 快稿跨复核边界：在完整覆盖前不丢失快稿，覆盖后消除重复。
- 复核先于快稿或暂定文字：已覆盖内容不重新显示，未覆盖尾部仍可见。
- 空结果、失败、复核之间的间隙：不隐藏未复核的快稿。
- 语言切换、停止后旧回调、新录音：显示与存储不能串会议。
- 长会议与滚动：增量更新列表，保留用户向上查看时的跟随行为。

### Task 1: 显示时间线

**Files:** Create `Sources/Shiyin/Capture/LiveTranscriptDisplay.swift`; test `Tests/ShiyinTests/LiveTranscriptDisplayTests.swift`.

**Interfaces:** `LiveTranscriptDisplay.addDraft(start:end:text:)`, `addReview(start:end:text:)`, `setPreview(start:end:text:)`, `lines`, `visiblePreview`.

- [x] 写测试，验证多句快稿被一段复核替换、跨边界保留与后续覆盖、迟到快稿、空结果和不连续复核。
- [x] 写测试，验证被复核覆盖的暂定文字隐藏且增长到未覆盖范围后可见。
- [x] 先运行测试确认缺少实现，再实现上述接口并运行测试直至通过。

### Task 2: 接入录音与界面

**Files:** Modify `Sources/Shiyin/Capture/{LiveTranscriber,QwenLiveTranscriber,Recorder}.swift`, `Sources/Shiyin/Views/RecordingView.swift`, `Tests/ShiyinTests/QwenLiveTests.swift`, and localized strings.

**Interfaces:** 实时引擎的暂定回调携带起止时间；Recorder 的可观察 `liveLines` 和 `volatileText` 从显示时间线更新。

- [x] 将真实回调接入时间线，旧会议回调仍只写原会议，开始新录音时重置显示状态。
- [x] 为复核片段显示中英文标记，更新设计、需求及 README。
- [x] 运行时间线、现有音频复核测试及本地化检查。

### Task 3: 隔离验证与交付

**Files:** 仅按需要增加隔离集成验证辅助；保留与功能直接相关的测试和文档。

- [x] 使用独立 scratch 运行 `bash scripts/ci/check-macos.sh`。
- [x] 使用独立 bundle id、临时 `SHIYIN_HOME`、独立 `SHIYIN_DEBUG_CHANNEL` 和本地假服务运行会中助手集成检查。
- [ ] 审查差异并完成一个功能提交，推送分支和创建 PR，等待 `macOS checks`；未经明确合并授权不合并。
