#!/usr/bin/env python3
"""Build the release copy of Living Front.

    python3 tools/build.py            -> dist/LivingFront   (install this folder)

The source tree (LivingFront/) is written to be read: long comments, aligned tables, indents.
None of that is needed by the game, so the release copy drops it:

  * Lua: comments removed, indentation and trailing spaces removed. Every line stays on its
    own line number, so an error in console.txt ("LF_Medic.lua:212") still points at line 212
    of the source file.
  * XML (AnimSets): comments and the whitespace between tags removed.
  * Everything else is copied unchanged.

The script only reads LivingFront/ and only writes dist/.
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "LivingFront")
OUT = os.path.join(ROOT, "dist", "LivingFront")


def long_bracket(s, i):
    """If s[i:] opens a long bracket ([[ or [==[), return its closing string, else None."""
    m = re.match(r"\[(=*)\[", s[i:])
    return ("]" + m.group(1) + "]") if m else None


def strip_lua(src):
    """Remove comments without touching strings; keep every newline."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":                                   # quoted string
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1]); i = j + 1
        elif c == "[" and long_bracket(src, i):           # long string
            close = long_bracket(src, i)
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(src[i:j]); i = j
        elif src.startswith("--", i):                    # comment
            close = long_bracket(src, i + 2)
            if close:                                    # block comment: keep its newlines
                j = src.find(close, i)
                j = n if j < 0 else j + len(close)
                out.append("\n" * src.count("\n", i, j)); i = j
            else:                                        # line comment
                j = src.find("\n", i)
                i = n if j < 0 else j
        else:
            out.append(c); i += 1
    lines = [l.strip() for l in "".join(out).split("\n")]
    return "\n".join(lines).rstrip("\n") + "\n"


def strip_xml(src):
    src = re.sub(r"<!--.*?-->", "", src, flags=re.S)
    src = re.sub(r">\s+<", "><", src)
    return src.strip() + "\n"


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    before = after = 0
    for d, _, files in os.walk(SRC):
        for f in files:
            sp = os.path.join(d, f)
            dp = os.path.join(OUT, os.path.relpath(sp, SRC))
            os.makedirs(os.path.dirname(dp), exist_ok=True)
            before += os.path.getsize(sp)
            if f.endswith(".lua"):
                with open(sp, encoding="utf-8") as h:
                    text = strip_lua(h.read())
                with open(dp, "w", encoding="utf-8", newline="\n") as h:
                    h.write(text)
            elif f.endswith(".xml"):
                with open(sp, encoding="utf-8") as h:
                    text = strip_xml(h.read())
                with open(dp, "w", encoding="utf-8", newline="\n") as h:
                    h.write(text)
            else:
                shutil.copy2(sp, dp)
            after += os.path.getsize(dp)
    print("built %s: %d KB -> %d KB" % (os.path.relpath(OUT, ROOT), before // 1024, after // 1024))


if __name__ == "__main__":
    sys.exit(main())
