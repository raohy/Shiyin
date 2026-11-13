<img src="docs/images/icon.png" width="96" alt="拾音图标">

**简体中文** | [English](.github/README.md) | 官网：[shiyin.weibuilds.com](https://shiyin.weibuilds.com)

# 拾音 Shiyin

macOS 的会议记录 app。录下会议（现场或在线），录音中就能看到实时逐字稿；录完在本机转录、分出说话者，再交给 Claude、Codex 或 API 整理成会议记录。记录里每一条都附上录音时间点，点一下就能听到原话。

- 录音、转录、说话者识别都在本机完成，录音不会上传
- 不需要安装 Python、Homebrew 或 ffmpeg，下载 DMG 就能用
- Mac 界面有简体中文和英文（跟着 macOS 的语言），会议可以是中文、英文、日文、广东话或韩文（韩文是实验性的）
- 需要 Apple Silicon 和 macOS 26

![会议记录](docs/images/summary.png)

## 怎么用

1. **录音或导入**：按工具列的「录音」（⌘R）。在线会议请把录音来源选「麦克风＋电脑声音」，对方的声音也会录进来。已经有录音档的话，拖进窗口就好。
2. **边录边看、边记**：左边是实时逐字稿，右边「我的笔记」每换一行会自动记下录音时间；重要的地方按「标记重点」（⌘B，在其他 app 里按 ⌃⌥⌘B）。
3. **停止并转录**：停止后马上用实时逐字稿整理一份草稿，同时在本机正式转录并分出说话者。点「说话者 1」可以改成人名，拾音会记住声音，下次自动带入。
4. **看会议记录**：转录完自动整理成摘要、决议、待办、未决问题，每一条都能点时间点跳回录音。不确定的人名和专有名词会变成待确认的题目：有疑问的那一条旁边有「？」，点了就能当场回答，记录顶部的「还有 N 题待确认」可以一次看完；回答后 AI 会依答案修正（按「是」直接确认，不用等）。想知道谁说了什么，可以在「提问」标签页直接问。
5. **导出或分享**：会议记录存成 Markdown、PDF、Word，心智图存成图片，逐字稿存成字幕档，或把整场会议打包成 .shiyin 传给同事。

> 本轮简体中文适配针对 Mac 版；Windows 版的简体适配和跨平台标准答案将在后续跟进。

## 功能

- **会前准备与会中提问助手（Mac）**：先填写会议背景、目标、角色和已有问题，保存后再开始录音。实时快稿保留原样，Qwen3-ASR 在本机另行复核约 18～30 秒的完整音频；助手约每 30 秒将新增复核稿交给当前整理工具分析，给出带理由和依据时间点的追问建议。自动及「立即分析」都只使用复核稿，复核失败时会提示，不退回快稿。可标记已问或忽略，会后清单保留在这台 Mac。需要开启实时逐字稿、下载 Qwen 模型及音频编码器，并设置好整理工具；仅会前资料和复核文字交给该工具，音频复核不上传录音。音频窗口长度不含推理及 LLM 请求时间，实际延迟取决于电脑速度
- **录音**
  - 来源可以选「只录麦克风」「麦克风＋电脑声音（在线会议）」「只录电脑声音」。Zoom、Meet、Teams 对方的声音也录得到
  - 录音中显示实时逐字稿、各来源的音量；可以暂停、标记重点、做笔记
  - 收音提醒：麦克风没有收到声音、声音太小、背景太吵时，录音画面会提醒你；人在别的 app 时也会送通知、菜单列图标变成警示
  - 人多、吵杂时，录音中或导入时就可以选「大约几个人」，说话者分得比较准
  - 关掉主窗口后录音照常进行，菜单列可以暂停、停止；在其他 app 里按 ⌃⌥⌘R 也能开始或停止录音
  - 录音中接上或拔掉耳机、换了输出设备，会自动接上继续录
  - 检测到 Zoom、Teams、Google Meet 等在线会议开始用麦克风时，提醒你开始录音；会议好像结束时提醒停止。只提醒，不会自动录
  - 录音中在任何 app 按 ⌃⌥⌘B 标记重点，有音效和菜单列图标的反馈
  - 磁盘空间不够时会提醒；写不进磁盘时自动停止，已经录到的部分会保留、照常转录
  - app 当掉或电脑突然关机，下次打开会自动复原录音
- **导入**：音频和视频（m4a、mp3、wav、aac、flac、caf、aiff、mp4、mov）、逐字稿（srt、vtt、txt）、Markdown 笔记、整场会议封包（.shiyin）。可以拖进窗口、⌘O、拖到 Dock 图标，或在 Finder 用「打开方式」
- **本机转录**：whisper.cpp + Breeze ASR 25（联发科），词汇表会当成提示词；设置里可以改选 llama.cpp + Qwen3-ASR 1.7B（阿里巴巴开源，多人会议漏字少，Mac 输出统一为简体中文，全程本机）；日文、韩文会议用 Whisper large-v3-turbo（第一次转录时才下载）；广东话会议一律用 Qwen3-ASR，Mac 版照粤语口语转成简体（第一次转录时才下载）。也可以改用 macOS 内置识别（不用下载模型、速度快很多，但不参考词汇表）。模型还没下载好时，先用 macOS 内置识别转录，下载好之后可以一键重新转录。长录音分段转录，4 小时的会议也不会吃掉太多内存
- **会议语言**：每场会议可以选中文、英文、日文、广东话或韩文，转录、会议记录、导出的标题都跟着这个语言；日文、韩文会议的内容用各自的字形，PDF、Word 用各自的字体。广东话的逐字稿照粤语口语写（系、唔、咗），Mac 版会议记录写成简体中文的书面语。韩文是实验性的：会议记录、导出都是韩文，但提示词没有像中文、英文、日文那样逐字调过。默认语言在设置里改。每种语言的做法写在一份语言档（`Resources/languages.json`），Mac、Windows 共用
- **自动检测语言**：开始录音后听约 10 秒，判断是中文、英文、日文还是韩文；跟会议语言不同而且有把握时，自动切换实时逐字稿和会议语言，录音画面可以改回来。广东话会判成中文，两者之间不会自动切换，广东话会议要自己选
- **逐字稿校正**：转录完，整理工具依词汇表和上下文找出可能听错的字（同音字、专有名词），标在逐字稿里，你按「接受」才改，可以还原
- **可选的 Qwen 实时转录（Mac）**：设置 → 录音与转录 → 实时转录引擎，可选「macOS 系统识别（低延迟）」或「Qwen3-ASR（上下文优先）」。Qwen 全程在本机运行，参考个人与公司词汇表，与正式转录共用约 2.5 GB 模型；当前句子会持续修订，停顿后定稿，连续发言最长约 24 秒换一段，并携带上一段完整音频与原始文字续写。相比系统识别占用更多内存和 GPU，出字可能更慢；切换在下次录音生效，现有用户仍默认使用系统识别。
- **词汇表建议**：从参加者、说话者名字、校正过的字、会议标题建议要加进词汇表的词
- **说话者识别**：逐字稿每段标上说话者，每个人一个颜色；可以改名、只看某一位说话者
  - 声纹：替说话者取名后，拾音记住这个人的声音，之后的会议自动带入名字（标「自动」，认错可以改正）。声纹只存在这台 Mac，设置里可以查看、删除、关闭
  - AI 从对话内容猜说话者的名字（例如「谢谢小陈的报告」），列成建议，按「套用」才改；改名时会议记录里的名字一起换
  - 人多、吵杂或手机远距收音，分出来的人太少时：「更多 → 重新识别说话者…」选大约几个人，只重新分辨谁在说话，逐字稿的文字不变
  - 分错了很好改：同一个人被分成两位，在说话者名字上点一下选「合并到…」；某几句分错人，在逐字稿按右键选「这句是谁说的」或「这段连续的话是谁说的」。改过的可以从「更多 → 复原说话者的调整」复原，重新识别说话者时也会保留
  - 拾音觉得可能把不同的人当成同一位时（人多、吵杂），逐字稿上方会提醒你重新识别说话者
- **会议记录**
  - 模板：一般会议、一对一、访谈、课堂／演讲、脑力激荡，也可以自订
  - 整理工具：Claude Code、Codex CLI、Anthropic API、OpenAI API、Gemini API、OpenAI 兼容 API（Groq、OpenRouter、本机的 Ollama、LM Studio），或「不整理」只要逐字稿
  - 只装了 Codex 桌面版（Mac 上新版叫 ChatGPT）也可以：拾音会用它附的 codex。只有 Claude 桌面版时，引导和设置会说明怎么另外装 Claude Code，附上可以复制的安装命令
  - 停止录音后先用实时逐字稿整理一份草稿（标「草稿」），正式转录完成后自动换成正式版
  - 可以直接编辑；每次修改都留版本，可以复原
  - 心智图：「记录」标签页上方切换「条列｜心智图」，会议标题在中间，议题、决议、待办、未决问题往两边展开，点时间点就从那里播放；直接从记录画出来，不再调用整理工具
  - 议题时间轴：播放条上方每个议题一段色块（颜色跟心智图一样），看得出每个议题从哪里讲到哪里，点一下就从那个议题开始听
  - 参考文件：会议中一起讨论的文件（PDF、Word、PowerPoint、纯文字、照片）可以加进会议，整理、提问时一起参考，数字和名称照文件写对；用到文件的地方注明出处，会议说的跟文件不一样时列成待确认。扫描的 PDF 和照片用 macOS 的文字识别读出文字，一场会议的文件合计最多 4 万字
- **导出与分享**

  | 项目 | 格式 |
  |---|---|
  | 会议记录 | Markdown、PDF、Word；也可以复制成保留格式的文字（贴到 Word、Notion、邮件）、Markdown、纯文字 |
  | 心智图 | PNG、PDF、SVG；也可以直接复制成图片 |
  | 逐字稿 | txt、Markdown、srt、vtt、Word（可选要不要时间点和说话者） |
  | 录音 | m4a、wav |
  | 整场会议 | .shiyin 封包（录音、逐字稿、说话者、记录、笔记、重点、参考文件），对方双击就能导入 |

  导出时也可以直接用 AirDrop、Mail、消息分享。
- **对会议提问**：在会议的「提问」标签页用自然语言问（例如「预算最后决定多少？」），提交后立即显示原问题、处理阶段和已用时间，完成后显示完整回答及录音时间点；取消或失败时保留问题，可以重试。工具列的「提问」可以问所有会议、目前的文件夹或最近 30 天，同样显示进展，回答附上是哪一场会议
- **让 AI 工具读取会议（MCP）**：设置 → 高级打开「让 AI 工具读取会议」，一键加到 Claude Code、Codex 或 Claude Desktop（其他支持 MCP 的工具可以复制设置）。AI 工具可以列出、搜索会议，读会议记录、逐字稿和跨会议的待办，回答附上会议和时间点的链接，点了打开拾音跳过去；可以跟其他工具一起用（把待办开成工单、写周报）。只能读、不能改，拾音不用开着；公司的企业服务器可以关掉这个功能
- **管理**：文件夹（依项目或客户分类）、全文搜索所有会议、垃圾桶（30 天内可还原）
- **其他**：倍速播放（0.75×～2×）、用词修正（逐字稿和记录一起改）、转录完自动把录音压缩成 m4a、完成或失败时发通知、app 内更新、「辅助说明 → 回报问题…」（附上版本和环境，不含会议内容）

![心智图](docs/images/mindmap.png)

![逐字稿与说话者](docs/images/transcript.png)

<sub>逐字稿截屏的示范录音取自 [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/)（ES2004a，CC BY 4.0）。</sub>

![录音中](docs/images/recording.png)

## 系统需求

| 项目 | 需求 |
|---|---|
| 芯片 | Apple Silicon（M1 以上） |
| 系统 | macOS 26 以上 |
| 内存 | 8 GB 以上。转录加说话者识别的峰值约 2.9 GB，长录音分段转录，会议长短影响不大（4 小时的会议 2.9 GB，M3 Pro 实测） |
| 磁盘空间 | 模型约 1.7 GB（第一次使用时下载；改用 macOS 内置识别就不用），日文、韩文会议另外 574 MB、自动检测语言 60 MB、改选 Qwen3-ASR 或开广东话会议另外约 2.5 GB，加上录音：m4a 约每小时 10～30 MB |
| 整理工具 | 择一：已登录的 [Claude Code](https://claude.com/claude-code)（`claude`）、Codex CLI（`codex`，只装了 Codex 桌面版也可以）、Anthropic API key、OpenAI API key、Gemini API key，或 OpenAI 兼容 API（Groq、OpenRouter 填 key；本机的 Ollama、LM Studio 不用 key）。也可以选「不整理」 |
| 网络 | 第一次下载模型、整理会议记录时需要；录音、转录、说话者识别都不需要 |

## 安装

### 用 DMG 安装

1. 取得 `Shiyin-<版本>.dmg`（[官网](https://shiyin.weibuilds.com)、这个 repo 的 Releases，或向维护的人拿），打开后把「拾音」拖到旁边的 Applications（应用程序）。
2. 拾音没有经过 Apple 公证，第一次打开会被挡下：到「系统设置 → 隐私与安全性」按「仍要打开」（只要做一次）。DMG 里的「安装说明.pdf」有完整步骤（英文版是「Install Guide.pdf」）。
3. 第一次打开会出现引导：允许麦克风、下载转录模型（约 1.7 GB）、选整理工具。每一步都可以略过，之后在设置里补做。
4. 3.1.1 起，拾音会自动检查这个 repo 的 Releases 有没有新版，询问你之后自动更新。

### 从源代码建置

需要 Xcode 26（Swift 6.2 以上）。第一次建置会用 Swift Package Manager 下载 GRDB、FluidAudio 和 whisper.cpp 的 XCFramework。

```bash
git clone https://github.com/juinwei7/Shiyin.git
cd Shiyin
scripts/make-signing-cert.sh --trust   # 只要做一次：建立并信任自签证书（要输入登录密码），之后更新 app 时权限不用重新允许
scripts/build-app.sh --install         # 建置 release 版并安装到 ~/Applications
```

没有执行 `make-signing-cert.sh --trust` 也能建置，会改用 ad-hoc 签名，只是每次重新建置后系统可能会再问一次权限。

## Windows 版

Windows 版在 [`windows/`](windows/)（C#、.NET 10、WinUI 3），功能跟 Mac 4.2 相同。到[官网](https://shiyin.weibuilds.com/windows/)或这个 repo 的 Releases 下载（tag 是 `win-vX.Y.Z`）。

| 项目 | 需求 |
|---|---|
| 系统 | Windows 11（x64 或 ARM64）。N 版要先装「媒体功能套件」（Media Feature Pack） |
| 内存 | 8 GB 以上 |
| 磁盘空间 | 第一次使用时下载：快速识别约 240 MB、说话者识别约 45 MB、转录模型约 1.7 GB；日文、韩文会议另外 574 MB；改选 Qwen3-ASR 或开广东话会议另外约 2.5 GB（含 llama.cpp 的可执行文件） |
| 显卡 | 不是必要的。x64 的电脑有 NVIDIA 显卡时，拾音会自动下载显卡加速（约 685 MB），正式转录改用显卡（40 分钟的会议用 RTX 3060 约 8 分钟，只用 CPU 约 30 分钟）；有 AMD 显卡（含 Radeon 内显）时自动下载 Vulkan 版的加速（约 20 MB），一样用显卡转录。只有 Intel 显卡时也下载这一份，第一次正式转录时先用一段录音比对显卡和 CPU，结果一样、显卡又比较快才改用显卡。ARM 的电脑只用 CPU |
| 性能 | NVIDIA 显卡最快：显示内存建议 4 GB 以上、驱动要 527 版以后。只用 CPU 时比较慢，笔记本电脑可能比会议本身还久；转录最多用 8 个线程。等不及的话，「设置 → 录音与转录 → 正式转录」改成「快速识别」（快很多但比较不准）。录音中的实时逐字稿约用一个 CPU 内核的三分之一 |
| 整理工具 | 同 Mac |

跟 Mac 版不一样的地方：

- **安装**：执行 `Shiyin-<版本>-win-x64-Setup.exe`（ARM 的电脑用 `win-arm64` 那个），不用系统管理员权限，装在 `%LOCALAPPDATA%\ShiyinApp`。安装档没有代码签名：出现「Windows 已保护您的电脑」时按「其他信息」→「仍要执行」；开着「智能型应用程序控制」时会被直接挡下，要先到「Windows 安全性 → 应用程序与浏览器控制」关掉它。之后有新版时，拾音会在 app 里问你要不要更新。
- **电脑声音**：录的是 Windows 默认输出设备播放的所有声音（Teams 会议的声音也录得到），换默认输出设备、拔耳机时接著录新的设备。录音中在拾音里播放录音，声音也会录进去（Mac 会排除拾音自己的声音）。
- **系统匣**取代菜单列：关掉主窗口时拾音留在系统匣，录音和转录不会中断；Windows 11 默认把新图标收在任务栏的「^」里。
- **快捷键**：⌘ 换成 Ctrl；在其他 app 里用 Ctrl+Alt+Shift+R 开始或停止录音、Ctrl+Alt+Shift+B 标记重点。
- **识别**：实时逐字稿和「快速识别」（取代 macOS 内置识别，转录模型还没下载好时先用）是 SenseVoice；说话者识别是 sherpa-onnx，声纹跟 Mac 版不通用。参考文件的 PDF 用 PdfPig 读文字，扫描的 PDF 和照片用 Windows 的文字识别（要有会议语言的识别：设置 → 时间与语言 → 语言与地区）。.shiyin 封包两边可以互相导入。
- **资料与隐私**：资料在 `%LOCALAPPDATA%\Shiyin`（只有这个 Windows 用户读得到），设置是里面的 `settings.json`；API key 存在 Windows 的「认证管理员」，不写进文件或 log。卸载不会删掉录音和数据库。其他同下面的〈资料与隐私〉。
- **授权**：另外用了 sherpa-onnx、ONNX Runtime、SenseVoice、pyannote、3D-Speaker、NAudio、PdfPig、Velopack、WinUIEx、Windows App SDK 等，完整的清单和条文在「关于拾音」和安装文件夹的 `Third-Party Licenses.txt`（`scripts/windows/make-third-party-licenses.py` 产生，更新套件后要重跑）。

从源代码建置要在 Windows 上，需要 .NET 10 SDK、Visual Studio Build Tools（C++，含 ARM64 的工具）、CMake、Git；ARM64 另外要 LLVM（clang）和 Ninja，AMD 用的 Vulkan 版（`-Vulkan`）要先装 Vulkan SDK：

```powershell
pwsh scripts/windows/build-whisper.ps1 -Arch x64 -Out build\whisper-x64
pwsh scripts/windows/pack.ps1 -Version 4.0.0 -Arch x64 -Whisper build\whisper-x64   # 安装档在 dist\win-x64
```

不碰画面的程序（数据库、提示词、整理工具、转录流程）在 Mac 上也能测：`cd windows && dotnet test --project tests/Shiyin.Tests`。

## 企业服务器

公司可以在自己的机房架拾音的企业服务器（另外的项目，不在这个 repo；app 和服务器之间的 API 写在 [`docs/design.md`](docs/design.md) §36）。员工登录之后：

- **转录**：正式转录送到公司的服务器（有 NVIDIA 显卡的机器），笔记本电脑不用自己跑模型。排队时会写第几位；连不上时会等，也可以在会议页改在这台电脑转录
- **整理**：整理工具选「公司」，用公司在后台设置的模型，每个人不用自己准备 Claude、Codex 或 API key
- **公司的词汇表**：产品名、客户名由公司统一维护，跟自己的词汇表一起用在转录和整理（设置 → 说话者与词汇）
- **登录**：设置 → 高级 → 企业服务器，填网址按「登录」，用公司的账号登录；或点公司给的加入链接。退出登录后拾音跟原本完全一样

Mac 和 Windows 都可以用。说话者的声纹只存在自己的电脑；公司的后台只看得到用量（几分钟、几次），看不到会议内容。

## 发布新版

开发、合并、版本和撤回规则见 [AGENTS.md](AGENTS.md)。独立功能在独立分支开发，通过 PR 和 `macOS checks` 后合并；正式发布另开版本 PR，更新版本号、构建号和 `docs/releases/X.Y.Z.md`。已有 Git 历史和发布标签保留，出问题通过新的撤回提交或修复版本处理。

本地自动检查：`bash scripts/ci/check-macos.sh`。它运行 Swift 测试、会中助手纯逻辑回归、本地化检查和发布配置编译，不启动应用或使用真实会议。GUI 集成和真实模型验证按相关设计另外执行并注明结果。

### 用 GitHub Actions（推荐）

1. 改 `Resources/Info.plist` 的 `CFBundleShortVersionString`，commit 并推上去。
2. 打一个带说明的 tag 并推上去，说明文字就是这版的更新内容（GitHub Release 和官网的版本说明都用它）：

   ```bash
   git tag -a vX.Y.Z -F 说明.txt
   git push origin vX.Y.Z
   ```

   `说明.txt` 是中文一段、空一行、英文一段，标题的版本号跟 tag 一致，每一条用「- 」开头（格式不对时官网建置会失败）：

   ```
   拾音 X.Y.Z：副标
   - 用户看得到的改变，一行一条

   Shiyin X.Y.Z: Subtitle
   - One item per line
   ```

3. [`.github/workflows/release.yml`](.github/workflows/release.yml) 会在 `macos-26` runner 上建置 DMG，建立 GitHub Release 并上传 DMG 和 `shiyin-update.json`。tag 跟版本号不一致时会直接失败。

也可以在 Actions 页面手动执行「打包」，只建置、不发布，DMG 放在那次执行的 artifact。

Windows 版推 `win-vX.Y.Z` 的 tag（标题写「拾音 Windows X.Y.Z」「Shiyin for Windows X.Y.Z」）：[`.github/workflows/release-windows.yml`](.github/workflows/release-windows.yml) 在 x64、ARM64 的 Windows 上建置、打包，建立不设成 latest 的 Release（Mac 的 app 内更新读 latest）。

设置（Settings → Secrets and variables → Actions，都是选填）：

| 名称 | 种类 | 用途 |
|---|---|---|
| `SHIYIN_SIGNING_P12`、`SHIYIN_SIGNING_P12_PASSWORD` | Secret | 自签证书。用 `scripts/export-signing-cert.sh --to-github <owner/repo>` 从自己的电脑设置，CI 签出来的 app 才会跟你电脑上建的一致；没有设置就用 ad-hoc 签名 |
| `SHIYIN_UPDATE_URL` | Variable | 写进 app 的更新网址 |
| `SHIYIN_USAGE_URL` | Variable | 写进 app 的匿名使用统计网址（选填；没设就不送统计） |
| `SHIYIN_RELEASES_REPO`、`SHIYIN_RELEASES_TOKEN` | Variable、Secret | 另外发布到一个公开的 repo（代码维持私人、又想让 app 自动更新时用） |

### 在自己的电脑上发布

1. 改 `Resources/Info.plist` 的 `CFBundleShortVersionString`。
2. 产生 DMG，带入更新网址和这版的更新内容：

   ```bash
   SHIYIN_UPDATE_URL=https://example.com/shiyin/shiyin-update.json \
   SHIYIN_RELEASE_NOTES="这版改了什么" scripts/make-dmg.sh
   ```

   `dist/` 里会有 `Shiyin-<版本>.dmg` 和 `shiyin-update.json`（版本、DMG 文件名、SHA-256、更新内容）。
3. 把这两个文件放到更新网址的位置（一定要 https）。已经安装的拾音会在 24 小时内检查到新版，询问用户后自动下载、验证并重新打开。

用 GitHub Releases 发布的话，更新网址可以用 `https://github.com/juinwei7/Shiyin/releases/latest/download/shiyin-update.json`，每次发布时把两个文件都上传：

```bash
gh release create v3.1.1 dist/Shiyin-3.1.1.dmg dist/shiyin-update.json --notes "这版改了什么"
```

注意：私人 repo 的 Releases 文件要登录才能下载，app 内更新会失败；这种情况请把两个文件放在公开的 https 位置（公司内部网站、NAS 等）。

app 会检查新版的签名是否跟目前的 app 相符。执行过 `make-signing-cert.sh --trust` 之后，只有同一张证书签的版本才能通过更新安装。

## 资料与隐私

| 项目 | 位置与去向 |
|---|---|
| 录音、逐字稿、数据库、模型 | `~/Library/Application Support/Shiyin`（权限 700，不会被 iCloud 同步） |
| 录音、转录、说话者识别 | 完全在本机，不连网 |
| 整理、校稿、提问、猜说话者 | 逐字稿文字、你的笔记、加入的参考文件读出来的文字（源文件不送）、词汇表、会议基本资料会送到你选的服务（Anthropic、OpenAI、Google，或 OpenAI 兼容 API 填的网址）。问所有会议时只送找到的相关片段。录音档不会送出 |
| 让 AI 工具读取会议（打开了才有） | 你在 Claude Code、Codex、Claude Desktop 等 AI 工具里问到的会议内容（会议记录、逐字稿、笔记）会交给那个工具处理，跟整理一样会离开这台电脑。只能读、不能改；垃圾桶里、正在录的会议读不到；关掉开关就读不到 |
| 声纹 | 说话者的声音特征（一组数字，不是录音）只存在本机数据库，不上传、不放进导出的 .shiyin 封包；设置 → 说话者与词汇可以删除或关闭 |
| 企业服务器（登录了才有） | 录音送到公司自己的服务器转录，不经过其他云端服务，转完就删；整理工具选「公司」时，逐字稿送到公司的服务器，由公司选的模型整理。Mac 在本机识别说话者，Windows 交给服务器识别、声纹传回来只存在本机。登录的 token 存在钥匙串（Windows 是认证管理员）。公司的后台只看得到用量，看不到会议内容 |
| 回报问题 | 只在你按「在 GitHub 回报」时用浏览器打开 GitHub，内容你看过、自己送出：版本、环境、错误的种类（登录企业服务器时加上服务器的版本），不含会议内容、文件名、API key、服务器网址或账号 |
| 匿名使用统计 | 每天送一份给拾音的开发者：版本、系统、录音和转录的分钟数、用了哪些功能（包括有没有用企业服务器转录、整理）、失败的次数和种类（例如没登录、key 错误，不含错误消息），加上一个随机的匿名 ID。不含会议标题、逐字稿、会议记录、人名、声纹、服务器网址、公司名称或任何文件。设置 → 高级可以关掉 |
| API key | 存在 macOS 钥匙串，不写进文件或 log |
| 整理工具选「不整理」，并关掉匿名使用统计 | 完全离线 |
| OpenAI 兼容 API 填本机网址（Ollama、LM Studio） | 整理也在这台 Mac 上完成，内容不会离开电脑 |

## 设置（⌘,）

| 标签页 | 内容 |
|---|---|
| 整理工具 | Claude、Codex、Anthropic API、OpenAI API、Gemini API、OpenAI 兼容 API 或不整理；登录状态、测试整理工具；API key；OpenAI 兼容 API 的网址（有常用服务可选）；模型；转录完是否自动整理、是否检查可能听错的字；模板（内置和自订、默认模板） |
| 录音与转录 | 录音来源、麦克风、权限设置；默认会议语言、自动检测会议语言；正式转录引擎（Breeze、Qwen3-ASR 或 macOS 内置）、说话者识别、实时逐字稿、下载／暂停／删除模型；检测在线会议和不提醒的 app、全域快捷键（开始停止录音、标记重点） |
| 说话者与词汇 | 记住说话者的声音（声纹）、认识的人：改名、删除、全部删除；词汇表：人名、系统名、专有名词的正确写法，转录和整理都会参考；建议加入的词 |
| 高级 | 企业服务器（登录、退出登录）、更新网址与检查更新、环境检查、压缩录音、空间用量、重新显示首次使用引导、重建搜索索引、匿名使用统计、删除第二版留下的旧文件 |

## 开发

本项目采用 SDD（规格驱动开发）：先写需求、设计、任务，再写程序，每项任务都要实际跑过才算完成。

| 文件 | 内容 |
|---|---|
| [`docs/requirements.md`](docs/requirements.md) | 需求 |
| [`docs/design.md`](docs/design.md) | 架构、资料模型、提示词、界面、决策记录 |
| [`docs/design-windows.md`](docs/design-windows.md) | Windows 版跟 Mac 不同的地方、标准答案、验证环境 |
| [`docs/website.md`](docs/website.md) | 官网的需求和设计 |
| [`docs/tasks.md`](docs/tasks.md) | 还没完成的任务 |
| [`CLAUDE.md`](CLAUDE.md) | 开发与验证时要注意的事 |

### 项目结构

```
Sources/Shiyin/
├── App/          app 进入点、菜单、AppDelegate
├── Capture/      录音（麦克风、系统声音）、写档、实时逐字稿
├── Transcribe/   解码、whisper.cpp、macOS 内置识别、说话者识别
├── Notes/        整理工具（CLI、API）、提示词、模板
├── Model/        资料表与会议记录的资料结构
├── Store/        数据库（GRDB）、AppModel
├── IO/           导出、.shiyin 封包、导入逐字稿
├── Services/     工作队列、模型下载、更新、钥匙串、全域快捷键、通知
├── Views/        SwiftUI 画面
└── Debug/        DEBUG 版的控制通道（shiyinctl）
Sources/QwenShim/ llama.cpp 的 C 薄层（Qwen3-ASR）
Resources/        Info.plist、翻译表（Localizable.xcstrings）、图标、OpenCC 字表
windows/          Windows 版（C#、.NET 10、WinUI 3）
shared/golden/    Mac 产生的标准答案，Windows 版的测试跟它比对
site/             官网（shiyin.weibuilds.com）
workers/usage/    匿名使用统计的后台（Cloudflare Workers）
scripts/          建置、DMG、自签证书、图标、开发工具；scripts/windows/ 是 Windows 版的建置和打包
docs/             规格
```

### 常用命令

```bash
scripts/build-app.sh               # release 建置，产出 build/Shiyin.app（实际位置在 ~/Library/Caches/ShiyinBuild）
scripts/build-app.sh --debug       # DEBUG 建置，含验证用的控制通道
scripts/make-dmg.sh                # release 建置并产生 DMG 和 shiyin-update.json
swift scripts/make-icon.swift Resources/AppIcon.icns   # 重新产生图标

# DEBUG 版的控制通道：不用操作画面就能触发功能、读取状态、截屏
swiftc scripts/dev/shiyinctl.swift -o ~/Library/Caches/ShiyinBuild/shiyinctl
~/Library/Caches/ShiyinBuild/shiyinctl state /tmp/state.json
~/Library/Caches/ShiyinBuild/shiyinctl snapshot /tmp/summary.png dark detail

scripts/dev/l10n.py check         # 改过界面文字后：抽出字符串、列出缺英文翻译和没查表的中文
~/Library/Caches/ShiyinBuild/app/Shiyin.app/Contents/MacOS/Shiyin -AppleLanguages "(en)"   # 用英文界面打开

/usr/bin/log stream --predicate 'subsystem == "com.weiwei.shiyin"'      # 看 log
sqlite3 ~/Library/Application\ Support/Shiyin/shiyin.sqlite             # 看资料
```

## 已知限制

- 没有 Apple 开发者账号，app 没有公证，第一次打开要手动放行。
- 实时逐字稿默认使用系统内置识别，不参考词汇表，英文专有名词常常不准（例如 Redis 变成 readis）。Mac 可在设置切换到参考词汇表的 Qwen3-ASR 实时模式；Qwen 模式优先等待上下文与停顿，定稿更慢。两种模式都保留会后的正式转录与逐字稿校正。
- 转录的准确度：在公开的真人中文会议（远距收音、6 人）上，字错误率 Breeze 约 29%、macOS 内置约 25%、可选的 Qwen3-ASR 约 18%，以漏掉抢话和语助词为主；整理出来的会议记录仍然正确。台湾国语的朗读句子（中英夹杂）两个模型都约 2%。笔记本电脑或耳机收音的会议应该会好很多。
- 说话者识别：很短、而且大部分时间只有一个人在讲的录音，话少的人可能被并进别人。逐字稿的一段里如果换人说话，整段只会标一个说话者；Qwen3-ASR 的段落（最长 15 秒）比 Breeze 的粗，抢话多的会议标错的比例高一些。
- Claude 整理通常要 30～70 秒，偶尔会到几分钟。
- 英文会议的转录：在公开的英文会议片段（AMI，4 人）上，字错误率 Breeze 约 36%、Qwen3-ASR 约 34%、macOS 内置约 37%（去掉语助词后约 33%、31%、34%），大多是同时说话的漏字。
- 日文会议的转录：在日本国会公开的专家听证（6 人）上，字错误率 Whisper large-v3-turbo 约 8～9%。正确答案用的国会会议录删掉了语助词，实际的错误率会比这个低。
- 广东话、韩文会议的转录（用 macOS 语音合成的开发周会和 FLEURS 朗读句子，2026-11-04）：广东话用 Qwen3-ASR，字错误率约 2～4%，照粤语口语写；韩文用 Whisper large-v3-turbo，约 6%。还没有用真人会议量过。
- 还没有：其他会议语言（加在语言档里，见 design §41）、日文和韩文界面、行事历集成、iPhone 版。

## 使用的开源项目与模型

| 名称 | 用途 | 授权 |
|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 正式转录（Breeze、日文、韩文）、语言检测 | MIT |
| [Breeze ASR 25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25)（[GGML 转档](https://huggingface.co/shdennlin/breeze-asr-25-ggml)） | 转录模型（繁体中文、中英夹杂） | Apache-2.0 |
| [Whisper](https://github.com/openai/whisper) large-v3-turbo、base（[GGML 转档](https://huggingface.co/ggerganov/whisper.cpp)） | 日文、韩文转录、自动检测语言 | MIT |
| [Qwen3-ASR 1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)（[GGUF 转档](https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF)） | 可选的转录模型（中文、英文）、广东话的转录（输出用 [OpenCC](https://github.com/BYVoid/OpenCC) 的字表在 Mac 版统一转成简体中文） | Apache-2.0 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | 跑 Qwen3-ASR | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 说话者识别 | Apache-2.0 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite 数据库、全文搜索 | MIT |

转录模型和说话者识别模型不放在这个 repo 里，第一次使用时才下载。app 和 DMG 都附有上面这些套件的完整授权条款：「关于拾音」窗口、DMG 里的 `Third-Party Licenses.txt`（`scripts/dev/make-third-party-licenses.sh` 产生，更新套件后要重跑）。

## 赞助

拾音是个人的开源项目，免费使用。觉得好用的话，可以在 Ko-fi 请我喝杯咖啡。

[![在 Ko-fi 请我喝杯咖啡](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/weiwei_chang)

## 授权

[MIT](LICENSE)。使用的开源项目和模型各自依上表的授权条款。
