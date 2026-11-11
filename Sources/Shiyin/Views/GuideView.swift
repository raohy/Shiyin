import SwiftUI

/// 使用说明（R10.4、v2 R14）。提到的按钮、标签页、菜单名称都要和界面上的文字一致。
struct GuideView: View {
    @Environment(\.snapshotMode) private var snapshotMode

    private struct Step {
        let symbol: String
        let title: String
        let body: String
    }

    private let steps: [Step] = [
        Step(symbol: "list.bullet.rectangle", title: String(localized: "准备会议与会中提问"),
             body: String(localized: "按「准备会议」填写主要内容、本场目标、角色和已有问题，保存后点「开始这场会议的录音」。开启会中提问助手后，会前资料和实时定稿文字会交给当前整理工具处理，约每 30 秒更新建议；可以点「立即分析」，把问题标成「已问」或「忽略」。录音结束后，在「提问」标签页查看全部问题；会后整理也会参考这些目标和问题。")),
        Step(symbol: "record.circle", title: String(localized: "录音或导入"),
             body: String(localized: "按工具列的「录音」（⌘R）开始录；点按钮旁的箭头可以选录音来源和麦克风，在线会议请选「麦克风＋电脑声音（在线会议）」，对方的声音也会录进来。录音画面的音量条旁写着正在用哪一支麦克风，点一下可以换；蓝牙耳机连着时，系统可能自动改用耳机的麦克风，现场会议记得换成这台 Mac 的麦克风。已经有录音档的话，拖进窗口、按「导入」（⌘O），或拖到 Dock 上的拾音图标都可以。")),
        Step(symbol: "text.bubble", title: String(localized: "边录边看、边记"),
             body: String(localized: "录音中画面左边是实时逐字稿，讲完几秒内就会出现；右边「我的笔记」每换一行会自动记下当时的录音时间（录完在逐字稿标签页顶部的「我的笔记」还能改）。重要的地方按「标记重点」（⌘B），在其他 app 里也可以按 ⌃⌥⌘B。需要中断时按「暂停」（⇧⌘P），暂停的时间不会录进去。")),
        Step(symbol: "waveform", title: String(localized: "正式转录、分辨说话者"),
             body: String(localized: "按「停止并转录」后，拾音会在这台 Mac 上重新转录（中文、英文用 Breeze ASR 25，\(MeetingLanguage.uiNames(model: "turbo"))用 Whisper large-v3-turbo，\(MeetingLanguage.uiNames(model: "qwen"))用 Qwen3-ASR），并分辨不同的说话者。等待的时候，会议记录会先用实时逐字稿整理一份草稿，正式版好了会自动换掉。逐字稿上点「说话者 1」可以改成人名，整场都会跟着改；拾音会记住这个人的声音，之后的会议自动带入名字（标「自动」，认错了点一下就能改）。")),
        Step(symbol: "doc.text", title: String(localized: "看会议记录"),
             body: String(localized: "转录完会自动整理。「记录」标签页由上而下是摘要、决议、待办、未决问题和依议题分段的讨论；每一条后面的时间点点一下，就从录音那里开始播放。上方的「条列｜心智图」可以把记录画成心智图，一眼看出有哪些议题。右上角的模板菜单可以换成一对一、访谈、课堂／演讲、脑力激荡等格式，换完从「更多 → 重新处理」选「刷新会议记录」。想找某件事，可以在「提问」标签页直接问，例如「预算最后决定多少？」，回答会附上时间点；工具列的「提问」可以一次问所有会议。")),
        Step(symbol: "questionmark.bubble", title: String(localized: "回答待确认、修改"),
             body: String(localized: "整理时没把握的人名、专有名词、负责人和期限会列成待确认的题目。记录里有疑问的那一条旁边会有「？」，点了就能当场回答；记录顶部的「还有 N 题待确认」点开可以一次看完。能用是或否回答的直接按「是」「不是」（按「是」不用等整理工具），其他的在「你的回答」字段回答，按「送出」，会议记录就会依你的答案修正；看不懂或不重要的按「略过」，或一次「全部略过」。也可以按「编辑」直接改。改错了按「编辑」旁的「复原上一版」。")),
        Step(symbol: "square.and.arrow.up", title: String(localized: "导出、分享"),
             body: String(localized: "按右上角的「导出」（⌘E）：会议记录可以存成 Markdown、PDF、Word，心智图可以存成 PNG、PDF、SVG；逐字稿可以存成 txt、srt、vtt、Word；录音可以存成 m4a、wav；「整场会议（.shiyin）」可以传给同事，对方双击就能导入。「导出」旁边的箭头可以直接复制会议记录或心智图的图片，贴到 Notion、Slack 或邮件。")),
    ]

    var body: some View {
        if snapshotMode {
            content
        } else {
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                Text("拾音使用说明").font(.songti(30))
                Text("拾音把会议变成逐字稿和会议记录。录音、转录、说话者识别都在这台 Mac 上完成。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            // 浅色模式白字、深色模式深色字，在青瓷绿上都看得清楚
                            .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            .frame(width: 24, height: 24)
                            .background(Color.celadon, in: Circle())
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        VStack(alignment: .leading, spacing: 6) {
                            Label(step.title, systemImage: step.symbol)
                                .font(.songti(18))
                                .labelStyle(GuideTitleLabelStyle())
                            Text(step.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(3)
                        }
                    }
                }
            }

            GuideSection(title: String(localized: "找会议、播放")) {
                GuideBullet(String(localized: "侧栏上方的「搜索所有会议」会同时搜标题、逐字稿、会议记录和你的笔记，点结果就跳到那一段。"))
                GuideBullet(String(localized: "点任何时间点或窗口底部的时间轴就从那里播放，空白键播放或暂停；播放列右边可以选 0.75×～2× 的速度。"))
                GuideBullet(String(localized: "逐字稿里琥珀色的段落识别信心比较低，值得回头听；时间轴上的三角形是待确认题目、圆点是你标的重点；时间轴上面的色块是议题，点了从那个议题开始听。"))
                GuideBullet(String(localized: "会议可以分文件夹：在会议上按右键（或「更多」）选「移到文件夹」→「新文件夹…」。侧栏上方的「文件夹」可以切换只看某个文件夹；正在看某个文件夹时，新录的和导入的会议都会放进去。文件夹按右键可以重命名或删除（会议会保留）。"))
                GuideBullet(String(localized: "删除的会议会先放进侧栏最下面的「垃圾桶」，30 天内都可以还原。"))
                GuideBullet(String(localized: "说话者分得太少（人多、吵杂、手机放在桌上远距收音）时，从「更多 → 重新处理」选「重新识别说话者…」，告诉拾音大约几个人。只会重新分辨谁在说话，逐字稿的文字不会变。录音中（会议标题右边的「人数」）或导入时也可以先选。"))
                GuideBullet(String(localized: "说话者分错了：同一个人被分成两位，点说话者的名字选「合并到…」；某几句分错人，在逐字稿按右键选「这句是谁说的」。改错了，点说话者的名字或按右键选「复原」。"))
                GuideBullet(String(localized: "开 Zoom、Teams、Google Meet 等在线会议时，拾音会提醒你开始录音；会议好像结束时提醒停止。不想被某个 app 提醒，在提醒上按「不要再提醒」。"))
                GuideBullet(String(localized: "遇到问题，可以从「辅助说明」菜单选「反馈问题…」，会附上版本和环境（不含会议内容）。"))
            }

            // 会议的参考文档（design §39.6、R61.10）
            GuideSection(title: String(localized: "会议的参考文档")) {
                GuideBullet(String(localized: "会议中一起讨论的文档（演示文稿、规格书、报价单、白板照片）可以加进会议：会议标题下回纹针图标的菜单（还没有文档时写「加入文档」）选「加入文档…」，或把 PDF、Word、PowerPoint、图片拖进窗口。纯文字、Markdown 要从「加入文档…」选（拖进来的 txt 会当成逐字稿、md 会当成笔记）。"))
                GuideBullet(String(localized: "整理会议记录、提问时，文档读出来的文字会一起送给整理工具，帮忙看懂讨论、写对数字和名称。记录还是以会议中讲的为准，用到文档的地方会注明出处，会议说的跟文档不一样时会列成待确认。已经整理好的会议加了文档，按记录上方的「刷新会议记录」。"))
                GuideBullet(String(localized: "扫描的 PDF、图片用 macOS 的文字识别读出文字。一场会议的文档合计最多 4 万字，太长的只送前面的部分。Keynote、Pages 请先导出成 PDF。"))
            }

            // 让 AI 工具读取会议（本地 MCP，design §44.4、R69）
            GuideSection(title: String(localized: "让 AI 工具读取会议")) {
                GuideBullet(String(localized: "Claude Code、Claude Desktop、Codex 等支持 MCP 的 AI 工具可以直接读拾音的会议：到「设置 → 高级 → AI 工具（MCP）」打开「让 AI 工具读取会议」，再按「加到 Claude Code」「加到 Codex」或「加到 Claude Desktop」。其他工具用「复制」自己粘贴设置。拾音不用开着。"))
                GuideBullet(String(localized: "加好之后在 AI 工具里直接问，例如「列出我这周的会议」「上周所有会议的待办有哪些」「找出提到预算的会议，整理成一段给主管」，也可以跟其他工具一起用（把待办开成工单、写周报）。回答里的会议链接点了会打开拾音、跳到那个时间点。"))
                GuideBullet(String(localized: "只能读、不能改；垃圾桶里的会议、正在录的会议读不到。读到的会议内容会交给那个 AI 工具处理，跟整理会议记录一样会离开这台 Mac；关掉开关就读不到了。"))
            }

            GuideSection(title: String(localized: "设置（⌘,）")) {
                GuideBullet(String(localized: "「整理工具」：选 Claude、Codex（需要先安装并登录对应的 CLI），或填 Anthropic、OpenAI 的 API key。觉得整理太慢，可以在「模型」填比较快的模型，例如 sonnet。最下面的「模板」内置五种；也可以复制一份来改，或自己添加段落与指示。"))
                GuideBullet(String(localized: "「录音与转录」：录音来源和麦克风、会议语言、正式转录的引擎和模型、要不要实时逐字稿和说话者识别、在线会议的提醒和快捷键。「正式转录」可以选 Breeze ASR 25（建议，联发科的台湾模型，会参考词汇表）、Qwen3-ASR（阿里巴巴开源，多人会议漏字少，全程本机）或 macOS 内置（不用下载模型、速度快，但英文专有名词比较容易错）。"))
                GuideBullet(String(localized: "「说话者与词汇」：拾音认识的人和他们的声纹，可以改名、删除，或关掉记住声音的功能；词汇表加入系统名、产品名、人名的正确写法，这对专有名词的正确率影响很大。"))
                GuideBullet(String(localized: "「高级」：检查更新（有新版时拾音会询问，同意后自动下载、验证并重新打开；也可以从「拾音」菜单选「检查更新…」）、环境检查、录音和模型占用的空间。"))
                if EnterpriseServer.shared.hasAccount {
                    GuideBullet(String(localized: "「高级 → 企业服务器」：公司的服务器、你的账号，可以选要不要用它转录、整理，或退出登录。整理工具选「公司」就用公司设置的模型。"))
                }
            }

            GuideSection(title: String(localized: "资料与隐私")) {
                GuideBullet(String(localized: "录音、逐字稿和会议记录都只存在这台 Mac 上（~/Library/Application Support/Shiyin），不会被 iCloud 同步。"))
                GuideBullet(String(localized: "实时逐字稿、正式转录、说话者识别都在本机进行，不需要网络。"))
                GuideBullet(String(localized: "整理、回答待确认、提问、猜说话者时，会把逐字稿文字、你的笔记、加入的文档读出来的文字和词汇表送到你选的整理工具，录音档和文档的源文件不会送出。选「不整理」就完全离线。"))
                GuideBullet(String(localized: "声纹（说话者的声音特征，一组数字，不是录音）只存在这台 Mac，不会放进导出的 .shiyin 封包。"))
                GuideBullet(String(localized: "API key 存在 macOS 钥匙串，不会写进任何文件。"))
                // 企业服务器（R52.1）：登录了才写，没登录的人照原本的说明
                if EnterpriseServer.shared.hasAccount {
                    GuideBullet(String(localized: "登录公司的企业服务器时：录音会上传到公司自己的服务器转录，不经过其他云端服务，转完就删；选「公司」整理时，逐字稿送到公司的服务器，由公司选的模型整理（公司机房里的模型，或公司接的 AI 服务）。说话者在这台 Mac 识别，声纹不会上传。公司的后台只看得到用量的数字（几分钟、几次），看不到会议内容。"))
                }
                // 匿名使用统计（design §30.5）：有统计网址的版本才写
                if UsageStats.isOffered {
                    GuideBullet(String(localized: "每天送一份匿名的使用统计（版本、系统、录音和转录的分钟数、用了哪些功能、失败的次数和种类），不含任何会议内容。在设置 → 高级可以关掉。"))
                }
            }

            GuideSection(title: String(localized: "系统需求")) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 9) {
                    requirement(String(localized: "芯片"), String(localized: "Apple Silicon（M1 以上）"))
                    requirement(String(localized: "系统"), String(localized: "macOS 26 以上"))
                    requirement(String(localized: "内存"), String(localized: "8 GB 以上。转录加说话者识别时最高约 2.9 GB，长录音分段转录，会议长短影响不大（4 小时的会议 2.9 GB，M3 Pro 实测）"))
                    requirement(String(localized: "磁盘空间"), String(localized: "约 1.7 GB 给模型（转录 1.66 GB、说话者识别 21 MB；开\(MeetingLanguage.uiNames(model: "turbo"))会议另外 574 MB、自动检测语言 60 MB），另外加上录音：转录完会压缩成 m4a，每小时约 10～30 MB"))
                    requirement(String(localized: "先安装"), String(localized: "不需要另外安装任何工具。要整理会议记录的话，安装并登录 claude 或 codex，或准备 Anthropic、OpenAI 的 API key"))
                    requirement(String(localized: "网络"), String(localized: "第一次使用下载模型时需要（约 1.7 GB）；整理会议记录时需要。录音、转录不需要"))
                }
            }

            GuideSection(title: String(localized: "快捷键")) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
                    shortcut("⌘R", String(localized: "开始或停止录音"))
                    shortcut("⌃⌥⌘R", String(localized: "在其他 app 里也能开始或停止录音（可以在设置 → 录音与转录关掉）"))
                    shortcut("⇧⌘P", String(localized: "暂停或继续录音"))
                    shortcut("⌘B", String(localized: "录音中标记重点"))
                    shortcut("⌃⌥⌘B", String(localized: "录音中在其他 app 里也能标记重点"))
                    shortcut("⌘O", String(localized: "导入"))
                    shortcut("⌘E", String(localized: "导出"))
                    shortcut(String(localized: "空白键"), String(localized: "播放或暂停"))
                    shortcut(String(localized: "⌘1～⌘3"), String(localized: "切换记录、逐字稿、提问"))
                    shortcut("⌘+ / ⌘−", String(localized: "放大、缩小会议内容的文字（⌘0 回到标准大小）"))
                    shortcut("⌘F", String(localized: "搜索逐字稿（在「逐字稿」）"))
                    shortcut("⌘,", String(localized: "设置"))
                    shortcut("⌘?", String(localized: "打开这份说明"))
                }
            }

            Text("之后随时可以从「辅助说明」菜单（⌘?）或菜单列的拾音图标，再打开这份说明。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func requirement(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).monospaced().foregroundStyle(Color.celadon)
            Text(action)
        }
    }
}

private struct GuideTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Color.celadon).font(.body)
            configuration.title
        }
    }
}

private struct GuideSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.songti(18))
            content
        }
    }
}

private struct GuideBullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }
}
