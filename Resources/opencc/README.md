# 中文字形转换表（design §32.5、§45）

字表取自 OpenCC（https://github.com/BYVoid/OpenCC，Apache-2.0，LICENSE 在同一文件夹）的 `data/dictionary/`，只留每个键的第一个候选，去掉注释，存成 tab 分隔的 `.tsv`。键和值相同的词组必须保留：它们阻止逐字误转，例如「公里」「皇后」。

- `STCharacters`、`STPhrases`、`TWVariants`：`ChineseScript.toTaiwan` 使用的旧简转繁流程，仍供粤语修正的中间步骤和 Windows 版使用。
- `TSCharacters`、`TSPhrases`：繁体转简体。
- `TWPhrasesRev`、`TWVariantsRevPhrases`：台湾用词和字形的反向转换。
- `CNOverrides`：本项目的大陆用语覆盖表，优先于 OpenCC；例如「预设」转成「默认」，「资料」保留为「资料」。

Mac 的中文、粤语转录结果和新生成的会议记录最终由 `ChineseScript.toSimplified` 统一为简体；开发脚本 `scripts/dev/t2s.py` 读取相同字表。日文、英文、韩文不走转换流程。Windows 的简体适配另见 tasks ZH2。
