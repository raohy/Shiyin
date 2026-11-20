# 个人 Fork 协作与开发规范

本仓库是 `juinwei7/Shiyin`（`upstream`）的个人自用 macOS 二开 fork。优先遵循用户在当前任务中的明确指令；已明确要求提交、合并或推送时，不再重复确认。

## 1. 仓库定位与分支策略

- **单主线滚动**：`main` 是唯一日常工作分支。同步上游、常规二开和小修复都直接在 `main` 上提交并推送，不再按日期创建 `sync-upstream-YYYYMMDD` 分支，也不走 PR 门禁、发布分支或 GitHub Release 流程。
- **临时分支例外**：只有较大或拿不准的实验性改动，才从最新 `main` 建短命功能分支；验证完成后合并回 `main` 并立即删除本地与远程分支。
- **稳定锚点 `last-good`**：`last-good` 标签指向用户最近一次实测稳妥的提交，作为随时回滚的安全网。不要覆盖或删除已有的历史标签（如 `v4.9.0`）；只有在用户确认当前版本日常使用稳定后，才移动 `last-good`（`git tag -f last-good main && git push -f origin last-good`）。
- **版本号策略**：不再单独维护一套 fork 正式版本号、`docs/releases/` 或 DMG 发布；同步上游时直接沿用上游的版本与构建号，减少无意义冲突。日常自用通过本地构建安装即可。
- **工作区纪律**：动手前先读 `CLAUDE.md` 及相关的 `docs/` 规格文档，检查 `git status` 与当前分支。保留用户尚未提交的改动，不混入无关文件或工具目录（如 `.loopx/`），不对 `main` 强制推送。

## 2. Fork 二开保护清单

同步上游或重构时，必须确保以下个人二开功能不被静默覆盖或回退；后续新增长期二开时同步补充到本清单：

1. **大陆简体中文适配与输出（RF70，`§F45` / `DF151`）**
   - Mac 界面、提示词、导出和转录结果一律使用大陆简体；新写源码中文直接写简体，日文提示词与模板不可被转换脚本误改。
   - 关键文件：`Sources/Shiyin/Transcribe/ChineseScript.swift`、`TranscriptionPipeline.swift`、`Resources/opencc/CNOverrides.tsv`、`TWPhrasesRev.tsv`、`Resources/Localizable.xcstrings`、`scripts/dev/l10n.py`、`scripts/dev/t2s*.py`、`scripts/dev/simplified-check.swift`。
2. **会前准备与会中提问助手（RF71，`§F46`）**
   - `source=prepared` 会前准备会议；录音中 `MeetingCoach` 每 30 秒仅消费 `segments.kind=reviewed` 生成追问建议（独立超时，停止后不写迟到响应）；会后保留并作为整理的非事实参考；保持与上游会议编辑/裁切/拆分/合并的时间点重映射兼容。
   - 关键文件：`Sources/Shiyin/Model/MeetingAssistance.swift`、`Services/MeetingCoach.swift`、`Notes/MeetingCoachPrompt.swift`、`Store/AssistanceStore.swift`、`Store/PreparingMeetings.swift`、`Store/AppDatabase.swift`（v11 及后续迁移兼容）、`Store/MeetingEditing.swift`、`Store/MeetingEdits.swift`、`Views/MeetingPreparationView.swift`、`Views/AskTab.swift`、`Tests/ShiyinTests/MeetingEditAssistanceTests.swift`、`scripts/dev/coach-check.swift`、`scripts/dev/coach-integration.py`。
3. **Qwen3-ASR 实时快稿、延迟音频复核与会中复核显示（R2.6，`§F51` / `§F52`）**
   - Mac 可选 Qwen3-ASR 实时快稿或系统 SpeechAnalyzer；本机延迟复核写入 `segments.kind=reviewed`；录音界面通过 `LiveTranscriptDisplay` 先显示快稿、复核成功后按时间范围替换并标记“已复核”，跨边界与空复核保留快稿，数据库仍分别保存。
   - 关键文件：`Sources/QwenShim/`、`Capture/QwenLiveBuffer.swift`、`Capture/QwenLiveTranscriber.swift`、`Capture/LiveTranscriber.swift`、`Capture/LiveTranscriptDisplay.swift`、`Capture/Recorder.swift`、`Transcribe/QwenEngine.swift`、`Views/RecordingView.swift`（`LiveTranscriptLineView`）、`Views/SettingsView.swift`、`Debug/DebugControl.swift`、`Tests/ShiyinTests/QwenLiveTests.swift`、`LiveReviewTests.swift`、`LiveTranscriptDisplayTests.swift`。
4. **提问进度反馈与取消重试**
   - 单场与跨会议提问提交后即时显示原问题、处理阶段与耗时；支持取消，取消或失败时保留原问题供重试。
   - 关键文件：`Sources/Shiyin/Store/Asking.swift`、`Views/AskTab.swift`、`Views/MainWindow.swift`、`scripts/dev/ask-integration.py`。
5. **文档编号隔离**
   - 本 fork 专属设计与需求编号统一加 `F` 前缀（如 `§F45`、`§F46`、`§F51`、`§F52`、`RF70`、`RF71`），避免与上游持续递增的编号冲突。
6. **Antigravity CLI（agy）与思考强度选择（RF72，`§F53`）**
   - `LLMProvider.agy` 作为整理工具之一接入设置、状态检查、环境检查、引导、会议整理与提问（`agy --output-format json --disable-slash-commands --json-schema ... --print=...`，`agy models` 按基础模型归并）；设置页在「模型」下方提供按工具保存的「思考强度」（`ThinkingEffort`）选择，透传至 `agy`、`claude`、`codex`、OpenAI API 与 Gemini API。
   - 关键文件：`Sources/Shiyin/Notes/LLMClient.swift`、`Notes/Backends/CLIBackends.swift`、`Notes/Backends/OpenAIAPI.swift`、`Notes/Backends/GeminiAPI.swift`、`Services/Paths.swift`、`Services/JobRunner.swift`、`Services/SummarizerReadiness.swift`、`Services/CLILogin.swift`、`Services/EnvironmentCheck.swift`、`Views/SettingsView.swift`、`Views/OnboardingView.swift`、`Debug/DebugControl.swift`、`Tests/ShiyinTests/AgyCLITests.swift`。

## 3. 同步上游标准流程

每次需要同步上游更新时，直接在 `main` 上执行：

1. `git fetch upstream`
2. 在 `main` 上执行 `git merge upstream/main`（保留普通 merge commit，不要 squash，以维持与上游的共同祖先、减少后续冲突）。
3. 解决冲突时逐项对照上方「Fork 二开保护清单」：优先吸收上游新功能与修复，同时完整保留本 fork 的二开逻辑、本地化与数据库迁移兼容；如出现新的繁体界面文案，按需转简体并补齐翻译表。
4. 执行下方「验证与自检」；全部通过后再提交并推送 `main`。
5. 完成后向用户输出简明同步摘要：
   - 本次吸收的上游核心变化；
   - 二开保护清单逐项受影响情况（未涉及 / 有冲突已适配 / 需留意）；
   - 实际运行的检查项、结果及未实测项（提醒下次开会顺便关注的交互点）。

## 4. 验证、自检与安全红线

- **基础底线检查**：任何 Mac 改动或上游同步完成后，必须运行 `bash scripts/ci/check-macos.sh`（覆盖单元测试、提问助手逻辑检查、本地化完整度检查与 Release 编译）。修改界面文字时补齐中英文，并提交 `Localizable.xcstrings` 的变更。
- **关键链路隔离集成检查**：
  - 涉及录音、实时快稿/复核、会中助手或数据库迁移时，组装独立 bundle id（非 `com.weiwei.shiyin`）的临时 DEBUG `.app`，用临时 `SHIYIN_HOME`、独立 `SHIYIN_DEBUG_CHANNEL` 和本地假服务运行 `scripts/dev/coach-integration.py`。
  - 涉及提问进度与取消重试时，按同样隔离方式运行 `scripts/dev/ask-integration.py`。
  - 严禁使用用户真实会议数据或真实 API key 代替测试数据。
- **不干扰用户正在使用的应用**：绝对不关闭用户正在录音或处理任务的拾音进程。日常验证构建使用 `swift build` 或独立临时目录组装测试 `.app`；只有在用户明确要求安装到本机时，才运行 `scripts/build-app.sh --install`。
- **数据库变更说明**：若上游或二开涉及 SQLite schema 变更，需确认向后迁移兼容与备份机制，并在交付摘要中说明；代码回滚到 `last-good` 不等同于数据库自动回退。
- **如实汇报**：明确列出实际跑过的命令、通过/跳过的用例，以及未覆盖的真机项（真实麦克风、真实 Qwen 模型、真实 LLM API、实际界面体验），不将自动检查通过等同于人工验收。
