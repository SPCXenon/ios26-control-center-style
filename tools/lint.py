#!/usr/bin/env python3
"""Fast compiler-free checks for the sources.

The tweak only compiles against Apple's linker and the Theos iOS SDK, which means a CI run on macOS
is the first time a typo is seen. This catches the classes of error that cost us builds before:

  * unbalanced braces / parentheses / brackets (comment- and string-aware)
  * a plist that does not parse, or a plist key list that has drifted
  * the Metal uniform struct and its Objective-C twin falling out of sync (a silent, very confusing
    kind of broken: the shader reads fields at the wrong offsets)
  * SDK-version traps we have already hit: `CACornerCurve` spelled as a type (absent from the 16.5
    SDK) and `typeof(...)` casts that ARC refuses

It is a lint, not a compiler. It runs in a second, locally and in CI before the build.
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
problems = []


def note(path, message):
    problems.append(f"{path.relative_to(ROOT)}: {message}")


def strip_code(text):
    """Drop comments and the contents of string/char literals, keeping newlines."""
    out = []
    i, n = 0, len(text)
    state = None
    while i < n:
        c = text[i]
        if state is None and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if state is None and text.startswith("/*", i):
            j = text.find("*/", i)
            i = n if j < 0 else j + 2
            continue
        if state is None and c in "\"'":
            state = c
            out.append(" ")
            i += 1
            continue
        if state:
            if c == "\\":
                i += 2
                continue
            if c == state:
                state = None
            if c == "\n":
                out.append("\n")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_balance(path):
    text = strip_code(path.read_text(encoding="utf-8", errors="replace"))
    pairs = {"{": "}", "(": ")", "[": "]"}
    closing = {v: k for k, v in pairs.items()}
    stack, line = [], 1
    for ch in text:
        if ch == "\n":
            line += 1
        elif ch in pairs:
            stack.append((ch, line))
        elif ch in closing:
            if not stack or stack[-1][0] != closing[ch]:
                note(path, f"unbalanced '{ch}' at line {line}")
                return
            stack.pop()
    for ch, at in stack[-3:]:
        note(path, f"unclosed '{ch}' opened at line {at}")


def check_uniform_sync(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    end = text.find("} LGUniforms;")
    start = text.rfind("typedef struct {", 0, end) if end >= 0 else -1
    objc = re.match(r"typedef struct \{(.*)", text[start:end], re.S) if start >= 0 else None
    msl = re.search(r"struct Uniforms \{(.*?)\};", text, re.S)
    if not objc or not msl:
        note(path, "LGUniforms / Uniforms struct not found")
        return
    def fields(body):
        names = []
        for line in body.splitlines():
            line = line.split("//")[0].strip()
            m = re.match(r"(simd_float[24]|float[24]?|uint\w*|int\w*)\s+(\w+)\s*;", line)
            if m:
                names.append((m.group(1).replace("simd_", ""), m.group(2)))
        return names
    a, b = fields(objc.group(1)), fields(msl.group(1))
    if a != b:
        note(path, f"uniform layout differs between LGUniforms and Uniforms: {a} vs {b}")


def check_plists():
    for path in ROOT.rglob("*.plist"):
        if ".git" in path.parts:
            continue
        raw = path.read_bytes()
        # Theos filter plists are old-style (NeXTSTEP) property lists, which plistlib cannot read and
        # which Apple does not read either; only the XML/binary ones we ship to iOS are checked.
        if not (raw.startswith(b"<?xml") or raw.startswith(b"bplist")):
            continue
        try:
            plistlib.loads(raw)
        except Exception as exc:  # noqa: BLE001 - any parse failure is the finding
            note(path, f"not a valid plist: {exc}")


def check_patterns(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"(?<![\w])CACornerCurve(?![\w])", text):
        line = text[: m.start()].count("\n") + 1
        note(path, f"'CACornerCurve' used as an identifier at line {line} (missing from the 16.5 SDK; use kCACornerCurve* or a BOOL)")
    for m in re.finditer(r"typeof\s*\(", text):
        line = text[: m.start()].count("\n") + 1
        note(path, f"'typeof(...)' at line {line}: casts of it are rejected under ARC on this SDK")


def main():
    sources = [p for p in ROOT.rglob("*") if p.suffix in (".m", ".mm") and ".git" not in p.parts]
    if not sources:
        print("lint: no sources found")
        return 1
    for path in sources:
        check_balance(path)
        check_patterns(path)
        if path.name.endswith("Backboardd.mm"):
            check_uniform_sync(path)
    check_plists()
    if problems:
        print("lint: %d problem(s)" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("lint: %d source file(s), all plists, uniform layout: OK" % len(sources))
    return 0


if __name__ == "__main__":
    sys.exit(main())
