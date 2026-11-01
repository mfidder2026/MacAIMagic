#!/usr/bin/env python3
"""Localization helper for the app.

  i18n.py wrap <files...>   wrap the Dutch interface texts in L("...") (review the diff afterwards)
  i18n.py keys              list every key used with L("...") in App/Sources (Dutch, %@ for values)
  i18n.py build             write App/Sources/MacAIMagic/Support/Translations.swift from tools/i18n/*.json
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "App/Sources/MacAIMagic")

def literals(line):
    """(start, end, inner) of each single-line string literal, with nested strings inside \\( ) skipped."""
    out, i = [], 0
    while i < len(line):
        if line.startswith('"""', i):
            return out
        if line[i] == '"':
            j, depth = i + 1, 0
            while j < len(line):
                c = line[j]
                if c == "\\" and depth == 0 and j + 1 < len(line) and line[j + 1] == "(":
                    depth, j = 1, j + 2
                    continue
                if depth > 0:
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    elif c == '"':   # a nested literal inside the interpolation
                        k = j + 1
                        while k < len(line) and line[k] != '"':
                            k += 2 if line[k] == "\\" else 1
                        j = k
                    j += 1
                    continue
                if c == "\\":
                    j += 2
                    continue
                if c == '"':
                    break
                j += 1
            out.append((i, j + 1, line[i + 1:j]))
            i = j + 1
        else:
            i += 1
    return out

def template(inner):
    """The key: literal text with %@ for every interpolation, % doubled."""
    key, i = "", 0
    while i < len(inner):
        if inner.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(inner) and depth:
                if inner[j] == "(":
                    depth += 1
                elif inner[j] == ")":
                    depth -= 1
                elif inner[j] == '"':
                    j += 1
                    while j < len(inner) and inner[j] != '"':
                        j += 2 if inner[j] == "\\" else 1
                j += 1
            key += "%@"
            i = j
        elif inner.startswith("\\n", i):
            key += "\n"; i += 2
        elif inner.startswith('\\"', i):
            key += '"'; i += 2
        elif inner.startswith("\\\\", i):
            key += "\\"; i += 2
        elif inner[i] == "%":
            key += "%%"; i += 1
        else:
            key += inner[i]; i += 1
    return key

UI = re.compile(r'(Text\(|Label\(|Button\(|Toggle\(|Picker\(|Section\(|TextField\(|SecureField\(|\.help\(|navigationTitle\(|'
                r'title: |text: |label: |append\(|\.starting\(|\.failed\(|\? |: |= \[|\+ |return |\(\[|, )\s*$')
SKIP = re.compile(r'(systemImage: |systemName: |tag\(|forKey: |named: |hasPrefix\(|hasSuffix\(|contains\(|URL\(string: |== |!= |'
                  r'identifier: |format: |Key\]|\["|setValue\(|forHTTPHeaderField|separator: |replacingOccurrences)\s*$')
WORD = re.compile(r'[A-Za-zÀ-ÿ]{3,}')

def is_text(inner):
    t = template(inner).replace("%@", "")
    return bool(WORD.search(t)) and (" " in t or re.search(r"[a-zà-ÿ]", t)) and not re.fullmatch(r"[a-z0-9_.\-/]+", t.strip())

def wrap(path):
    lines = open(path).read().split("\n")
    changed = 0
    for n, line in enumerate(lines):
        s = line.lstrip()
        if s.startswith("//") or s.startswith("///") or "L(\"" in line and False:
            continue
        out, last = "", 0
        for (a, b, inner) in literals(line):
            before = line[:a]
            if before.rstrip().endswith("L(") or not is_text(inner) or SKIP.search(before) or not UI.search(before):
                continue
            out += line[last:a] + "L(" + line[a:b] + ")"
            last = b
            changed += 1
        if last:
            lines[n] = out + line[last:]
    open(path, "w").write("\n".join(lines))
    return changed

def keys():
    found = {}
    for d, _, files in os.walk(SRC):
        for f in files:
            if not f.endswith(".swift") or f == "Translations.swift":
                continue
            for line in open(os.path.join(d, f)):
                for (a, b, inner) in literals(line):
                    if line[:a].rstrip().endswith("L("):
                        found.setdefault(template(inner), f)
    # texts that only exist at run time: the model summaries in models.json
    for m in json.load(open(os.path.join(ROOT, "tools/models.json")))["models"]:
        found.setdefault(m["summary"].replace("%", "%%"), "models.json")
    return found

def swift_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "wrap":
        for p in sys.argv[2:]:
            print(wrap(p), p)
    elif cmd == "keys":
        json.dump(sorted(keys()), sys.stdout, ensure_ascii=False, indent=1)
    elif cmd == "build":
        used = keys()
        out = ["/// Generated from tools/i18n/*.json by tools/i18n.py build: the Dutch texts in the code are the keys.",
               "enum Translations {", "    static let table: [String: [String: String]] = ["]
        for lang in ["en", "de", "fr"]:
            table = json.load(open(os.path.join(ROOT, "tools/i18n", lang + ".json")))
            missing = [k for k in used if k not in table]
            if missing:
                print(f"{lang}: {len(missing)} missing", file=sys.stderr)
                for k in missing[:20]:
                    print("   ", repr(k), file=sys.stderr)
            out.append(f'        "{lang}": [')
            for k in sorted(table):
                if k in used:
                    out.append(f"            {swift_string(k)}: {swift_string(table[k])},")
            out.append("        ],")
        out += ["    ]", "}", ""]
        open(os.path.join(SRC, "Support/Translations.swift"), "w").write("\n".join(out))
