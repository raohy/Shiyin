#!/usr/bin/env python3
"""Swift 原始码转简体（design §45）：只转中文，日文的字串、注释原样保留。

日文的判断：
- 含假名（平假名、片假名）的单行字串、注释那一行、多行字串的那一行
- 只有汉字、但在日文的位置：`ja:` 后面的字串，或 `("中文", "English", "日本語")` 第三个位置的字串

用法：scripts/dev/t2s-swift.py <文件>...（就地转换）
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from t2s import convert  # noqa: E402

KANA = re.compile(r"[぀-ヿㇰ-ㇿｦ-ﾟ]")
CJK = re.compile(r"[㐀-鿿豈-﫿]")


def convert_lines(text):
    """一行一行转，有假名的那一行不动"""
    return "".join(line if KANA.search(line) else convert(line) for line in text.splitlines(keepends=True))


def tokenize(src):
    """切成 (种类, 文字)：code、comment、string（单行字串，含引号）、mstring（多行字串）"""
    out = []
    i, n = 0, len(src)
    buf = []

    def flush():
        if buf:
            out.append(("code", "".join(buf)))
            buf.clear()

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            flush(); out.append(("comment", src[i:j])); i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            flush(); out.append(("comment", src[i:j])); i = j
        elif src.startswith('"""', i):
            j = i + 3
            while j < n and not (src.startswith('"""', j) and src[j - 1] != "\\"):
                j += 1
            j = min(n, j + 3)
            flush(); out.append(("mstring", src[i:j])); i = j
        elif c == '"':
            j = i + 1
            depth = 0
            while j < n:
                if src[j] == "\\" and j + 1 < n:
                    if src[j + 1] == "(" and depth == 0:
                        # 插值：找对应的右括号（里面的字串一起带过）
                        k, d, instr = j + 2, 1, False
                        while k < n and d > 0:
                            ch = src[k]
                            if instr:
                                if ch == "\\":
                                    k += 1
                                elif ch == '"':
                                    instr = False
                            elif ch == '"':
                                instr = True
                            elif ch == "(":
                                d += 1
                            elif ch == ")":
                                d -= 1
                            k += 1
                        j = k
                        continue
                    j += 2
                    continue
                if src[j] == '"' or src[j] == "\n":
                    break
                j += 1
            j = min(n, j + 1)
            flush(); out.append(("string", src[i:j])); i = j
        else:
            buf.append(c); i += 1
    flush()
    return out


def is_ascii_word(s):
    body = s[1:-1]
    return bool(re.search(r"[A-Za-z]", body)) and not CJK.search(body)


def convert_swift(src):
    toks = tokenize(src)
    result = []
    for idx, (kind, text) in enumerate(toks):
        if kind == "code":
            result.append(convert(text) if CJK.search(text) and not KANA.search(text) else text)
        elif kind == "comment" or kind == "mstring":
            result.append(convert_lines(text))
        else:
            japanese = bool(KANA.search(text))
            if not japanese and CJK.search(text):
                prev = toks[idx - 1][1] if idx > 0 else ""
                if re.search(r"\bja:\s*$", prev):
                    japanese = True
                elif re.fullmatch(r"\s*,\s*", prev) and idx >= 4:
                    # ("中文", "English", "日本語")：前一个是英文字串、再前一个是中文字串
                    p1k, p1 = toks[idx - 2]
                    p2k, p2 = toks[idx - 4]
                    if p1k == "string" and is_ascii_word(p1) and re.fullmatch(r"\s*,\s*", toks[idx - 3][1]) \
                            and p2k == "string" and CJK.search(p2):
                        japanese = True
            if not japanese and CJK.search(text) and neighbors_japanese(toks, idx):
                japanese = True
            result.append(text if japanese else convert(text))
    return "".join(result)


def neighbors_japanese(toks, idx):
    """日文的段落里只有汉字的字串（例如日文模板的「質疑応答」）：前后最近的中日文字串都有假名，
    而且自己不是 `zh:` 或 ("中文", "English", …) 第一个位置的字串"""
    prev = toks[idx - 1][1] if idx > 0 else ""
    if re.search(r"\bzh:\s*$", prev):
        return False
    if idx + 2 < len(toks) and re.fullmatch(r"\s*,\s*", toks[idx + 1][1]) and toks[idx + 2][0] == "string" \
            and is_ascii_word(toks[idx + 2][1]):
        return False

    def nearest(rng):
        lines = 0
        for k in rng:
            kind, t = toks[k]
            lines += t.count("\n")
            if lines > 3:
                return None
            if kind in ("string", "mstring") and CJK.search(t):
                return t
        return None

    before = nearest(range(idx - 1, -1, -1))
    after = nearest(range(idx + 1, len(toks)))
    return bool(before and after and KANA.search(before) and KANA.search(after))


def main():
    for name in sys.argv[1:]:
        p = Path(name)
        old = p.read_text(encoding="utf-8")
        new = convert_swift(old)
        if new != old:
            p.write_text(new, encoding="utf-8")


if __name__ == "__main__":
    main()
