#!/bin/bash
# 本地与 GitHub Actions 共用；不启动应用、不访问真实会议或模型服务。
set -euo pipefail
cd "$(dirname "$0")/../.."

TASK_SCRATCH="${SHIYIN_CI_SCRATCH:-$HOME/Library/Caches/ShiyinBuild}"
CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/shiyin-ci.XXXXXX")"
trap 'rm -rf "$CHECK_TMP"' EXIT

swift test --arch arm64 --disable-keychain --scratch-path "$TASK_SCRATCH"

# 纯逻辑回归，独立于 AppModel 和用户资料。
swiftc Sources/Shiyin/Transcribe/ChineseScript.swift \
  Sources/Shiyin/Model/MeetingAssistance.swift \
  Sources/Shiyin/Notes/MeetingCoachPrompt.swift \
  scripts/dev/coach-check.swift -o "$CHECK_TMP/coach-check"
"$CHECK_TMP/coach-check"

python3 scripts/dev/l10n.py check
git diff --exit-code -- Resources/Localizable.xcstrings \
  Resources/zh-Hans.lproj/InfoPlist.strings \
  windows/src/Shiyin.App/Strings/Windows.xcstrings

swift build -c release --arch arm64 --disable-keychain --scratch-path "$TASK_SCRATCH"
