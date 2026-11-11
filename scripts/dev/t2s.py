#!/usr/bin/env python3
"""台湾繁体转大陆简体（design §45、D151）：跟 app 的 ChineseScript.toSimplified 用同一套字表、同一个做法。

用法：
  scripts/dev/t2s.py <文件>...          就地转换（只动中日韩的字）
  scripts/dev/t2s.py --stdin            读 stdin、写 stdout

做法：第一轮把台湾用词换成大陆用词（CNOverrides、TWPhrasesRev、TWVariantsRevPhrases、反查 TWVariants），
第二轮繁转简（TSPhrases、TSCharacters）；每一轮都是由左往右找最长的匹配。
"""
import sys
from pathlib import Path

OPENCC = Path(__file__).resolve().parents[2] / "Resources" / "opencc"


def rows(name):
    for line in (OPENCC / name).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2:
            yield parts[0], parts[1].split(" ")[0]


def table(*sources):
    out = {}
    for src in sources:
        for k, v in src:
            out.setdefault(k, v)
    return out


def tables():
    variants_rev = [(v, k) for k, v in rows("TWVariants.tsv") if len(k) == 1 and len(v) == 1]
    stage1 = table(rows("CNOverrides.tsv"), rows("TWPhrasesRev.tsv"), rows("TWVariantsRevPhrases.tsv"), variants_rev)
    stage2 = table(rows("TSPhrases.tsv"), rows("TSCharacters.tsv"))
    # 台湾用词也可能已经是简体字（Breeze 看到简体的提示词时会输出「软体」「资料库」）：用词表多一份简体的键
    longest2 = max(len(k) for k in stage2)
    for k, v in list(stage1.items()):
        stage1.setdefault(convert_once(k, stage2, longest2), v)
    return [stage1, stage2]


def is_cjk(c):
    o = ord(c)
    return 0x3400 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF


def convert_once(text, mapping, longest):
    out = []
    i, n = 0, len(text)
    while i < n:
        if is_cjk(text[i]):
            for length in range(min(longest, n - i), 0, -1):
                v = mapping.get(text[i:i + length])
                if v is not None:
                    out.append(v)
                    i += length
                    break
            else:
                out.append(text[i])
                i += 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


_TABLES = None


def convert(text):
    global _TABLES
    if _TABLES is None:
        _TABLES = [(t, max(len(k) for k in t)) for t in tables()]
    for mapping, longest in _TABLES:
        text = convert_once(text, mapping, longest)
    return text


def main():
    if sys.argv[1:] == ["--stdin"]:
        sys.stdout.write(convert(sys.stdin.read()))
        return
    for name in sys.argv[1:]:
        p = Path(name)
        old = p.read_text(encoding="utf-8")
        new = convert(old)
        if new != old:
            p.write_text(new, encoding="utf-8")
            print(f"converted {name}")


if __name__ == "__main__":
    main()
