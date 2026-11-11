#!/bin/bash
# 建置拾音：swift build → 组成 build/Shiyin.app → ad-hoc 签名。
# 用法：scripts/build-app.sh [--install | --debug]
#   --install  先结束执行中的拾音，再装到 ~/Applications
#   --debug    建置 DEBUG 版（含验证用控制通道，见 scripts/dev/shiyinctl.swift），不能和 --install 一起用
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUNDLE_ID="com.weiwei.shiyin"
# 建置暂存和 .app 都不放项目文件夹：桌面有 iCloud 同步，除了会上传几百 MB，
# iCloud 加在文件上的延伸属性也会让 codesign 失败。项目里的 build 是指过去的快捷方式。
SCRATCH="$HOME/Library/Caches/ShiyinBuild"
APP="$SCRATCH/app/Shiyin.app"
CONFIG="release"
[ "${1:-}" = "--debug" ] && CONFIG="debug"

# --disable-keychain：下载 whisper.cpp 的 XCFramework 时不要去钥匙串找 GitHub 帐密
swift build -c "$CONFIG" --arch arm64 --disable-keychain --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --disable-keychain --scratch-path "$SCRATCH" --show-bin-path)"

# 重建前先结束从这个路径启动的拾音：不然 LaunchServices 会把重建后的 bundle 当成另一个 app，
# 两个程序共用同一个数据库、同时跑工作。10 秒内没结束（例如卡在结束确认）就强制结束：
# 录音下次打开会自动复原，工作会重新排队。不影响 ~/Applications 里安装的那一份。
if pgrep -f "$APP/Contents/MacOS/Shiyin" >/dev/null; then
  pkill -TERM -f "$APP/Contents/MacOS/Shiyin" || true
  for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/Shiyin" >/dev/null || break; sleep 0.5; done
  pkill -KILL -f "$APP/Contents/MacOS/Shiyin" || true
fi
rm -rf "$APP"
mkdir -p "$SCRATCH/app"
[ -L "$ROOT/build" ] || { rm -rf "$ROOT/build"; ln -s "$SCRATCH/app" "$ROOT/build"; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/Shiyin" "$APP/Contents/MacOS/Shiyin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 更新网址（design §12、R10.6）：发布时用 SHIYIN_UPDATE_URL=https://…/shiyin-update.json 带入
if [ -n "${SHIYIN_UPDATE_URL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :ShiyinUpdateURL ${SHIYIN_UPDATE_URL}" "$APP/Contents/Info.plist"
fi
# 匿名使用统计的网址（design §30.6、R40）：SHIYIN_USAGE_URL=https://… 带入；没带就是不送统计的版本
if [ -n "${SHIYIN_USAGE_URL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :ShiyinUsageURL ${SHIYIN_USAGE_URL}" "$APP/Contents/Info.plist"
fi
# whisper.cpp 是动态 framework（design §6.2）；SwiftPM 的资源 bundle 放 Resources
ditto "$BIN_DIR/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
# llama.cpp（Qwen3-ASR，design §32.2）也是动态 framework
ditto "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/llama.framework"
# 简转繁的字表（design §32.5）
ditto Resources/opencc "$APP/Contents/Resources/opencc"
# 会议语言的语言档（design §41.1），Windows 内嵌同一份
cp Resources/languages.json "$APP/Contents/Resources/languages.json"
for bundle in "$BIN_DIR"/*.bundle; do ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"; done
chmod -R u+w "$APP"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# AccentColor（青瓷绿）要编译成 Assets.car，List 选中色等系统组件才会套用（design §9.3）
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --accent-color AccentColor \
  --output-partial-info-plist "$SCRATCH/assets-partial.plist" >/dev/null
# 界面翻译（design §16.1）：翻译表编成各语言的 Localizable.strings；
# app 名称、权限说明、文件类型名称的中文放在 Resources/zh-Hans.lproj/InfoPlist.strings（英文写在 Info.plist）
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
for lproj in Resources/*.lproj; do ditto "$lproj" "$APP/Contents/Resources/$(basename "$lproj")"; done
mkdir -p "$APP/Contents/Resources/en.lproj"
# 第三方授权（design §12.1、R13.1）：原文放一份；另外包成 Credits.html，系统的「关于拾音」窗口会显示。
# Credits.html 放在各语言的 lproj（最上面是赞助链接，R13.3），Resources 底下不能再有一份，不然系统会先拿那份
cp Resources/ThirdPartyLicenses.txt "$APP/Contents/Resources/ThirdPartyLicenses.txt"
/usr/bin/python3 -c 'import html, sys
text = html.escape(open(sys.argv[1], encoding="utf-8").read())
kofi = "https://ko-fi.com/weiwei_chang"
sponsor = {
    "zh-Hans": f"觉得拾音好用的话，可以<a href=\"{kofi}\">请我喝杯咖啡</a>。",
    "en": f"Enjoying Shiyin? <a href=\"{kofi}\">Buy me a coffee</a>.",
}
for lang, line in sponsor.items():
    with open(f"{sys.argv[2]}/{lang}.lproj/Credits.html", "w", encoding="utf-8") as f:
        f.write(f"<!doctype html><html lang=\"{lang}\"><meta charset=\"utf-8\">"
                f"<p style=\"font: 12px -apple-system; text-align: center\">{line}</p>"
                f"<pre style=\"font: 10px Menlo; white-space: pre-wrap\">{text}</pre>")' \
  Resources/ThirdPartyLicenses.txt "$APP/Contents/Resources"

xattr -cr "$APP"
# 签名（design §12、R10.7）：有已信任的自签证书就用它；没有就用 ad-hoc，
# 并把 designated requirement 指定成只看 bundle identifier，让更新后的 app 仍符合同一个要求
SIGN_DIR="$HOME/Library/Application Support/ShiyinSigning"
SIGN_KC="$SIGN_DIR/shiyin-signing.keychain-db"
IDENTITY=""
if [ -f "$SIGN_KC" ] && [ -f "$SIGN_DIR/password" ]; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_KC" 2>/dev/null || true
  IDENTITY="$(security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null | awk '/Shiyin Self-Signed/ {print $2; exit}')"
fi
# codesign 只在钥匙串搜索清单里找签名身分（加了 --keychain 也一样，不然会 no identity found），
# 签名期间暂时加进清单，签完或失败都还原
ORIG_KCS=()
if [ -n "$IDENTITY" ]; then
  while IFS= read -r kc; do ORIG_KCS+=("$kc"); done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
  restore_keychains() { security list-keychains -d user -s ${ORIG_KCS[@]+"${ORIG_KCS[@]}"}; }
  trap restore_keychains EXIT
  security list-keychains -d user -s "$SIGN_KC" ${ORIG_KCS[@]+"${ORIG_KCS[@]}"}
fi
sign() {
  if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --keychain "$SIGN_KC" --timestamp=none "$@"
  else
    codesign --force --sign - "$@"
  fi
}
sign "$APP/Contents/Frameworks/whisper.framework"
sign "$APP/Contents/Frameworks/llama.framework"
if [ -n "$IDENTITY" ]; then
  sign --identifier "$BUNDLE_ID" "$APP"
  restore_keychains
  trap - EXIT
  echo "签名：Shiyin Self-Signed"
else
  sign --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "签名：ad-hoc（还没有信任的自签证书；执行 scripts/make-signing-cert.sh --trust 后重建，权限才确定能在更新后保留）"
fi
codesign --verify --strict --deep "$APP"
echo "已建置（${CONFIG}）：${APP}（项目里的 build/Shiyin.app 指向这里）"

if [ "${1:-}" = "--install" ]; then
  if pgrep -xq Shiyin; then
    echo "结束执行中的拾音…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
    for _ in $(seq 1 60); do pgrep -xq Shiyin || break; sleep 0.5; done
    pgrep -xq Shiyin && { echo "拾音没有结束（可能在录音或工作中，请手动结束后再试）"; exit 1; }
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Shiyin.app"
  cp -R "$APP" "$HOME/Applications/Shiyin.app"
  echo "已安装：$HOME/Applications/Shiyin.app"
fi
