#!/usr/bin/env python3
"""Find local functions called above the line that defines them.

In Lua a `local function f` is only in scope below its definition: a call to f higher up the file
calls the global f, which is nil - "Object tried to call nil" at run time, on every call. (0.50's
patch to LF_March called isThick before its definition and failed for every marching man.)

    python3 tools/forward_refs.py          -> prints file, name, line used, line defined
"""
import glob, os, re, sys
root = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "LivingFront")
bad = 0
for f in sorted(glob.glob(os.path.join(root, "**", "*.lua"), recursive=True)):
    lines = open(f, encoding="utf-8").read().split("\n")
    defs = {}
    for i, l in enumerate(lines):
        m = re.match(r"\s*local function (\w+)", l)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i
    for name, di in defs.items():
        for i in range(di):
            code = lines[i].split("--")[0]
            if re.search(r"(?<![\w.:])" + name + r"\s*\(", code) and not re.match(r"\s*local function", lines[i]):
                print(os.path.relpath(f, root), name, "used at", i + 1, "defined at", di + 1)
                bad += 1
                break
sys.exit(1 if bad else 0)
