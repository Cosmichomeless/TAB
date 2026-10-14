#!/usr/bin/env python3
"""Checks App/Localizable.xcstrings without Xcode.

- every key is translated into every language the app ships;
- a translation uses the same format placeholders as its key (%@, %lld);
- every key appears as a string literal in the app sources, so a typo or a renamed
  string in Swift cannot silently fall back to English.

Usage: scripts/check_localizations.py   (exit code 1 on any problem)
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "Localizable.xcstrings"
LANGUAGES = ["es", "fr", "it", "pt", "de"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld)")


def placeholders(text):
    return sorted(re.sub(r"\d+\$", "", p) for p in PLACEHOLDER.findall(text))


def values(localization):
    if "stringUnit" in localization:
        yield localization["stringUnit"]["value"]
    for forms in localization.get("variations", {}).values():
        for form in forms.values():
            yield from values(form)


def source_text():
    parts = []
    for path in sorted((ROOT / "App").rglob("*.swift")):
        if "Sync" in path.relative_to(ROOT / "App").parts or path.name == "DemoData.swift":
            continue
        parts.append(path.read_text(encoding="utf-8"))
    return "\n".join(parts)


def key_pattern(key):
    literal = key.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    pieces = re.split(r"%@|%lld", literal)
    return re.compile(r"\\\(.*?\)".join(re.escape(p) for p in pieces), re.S)


def main():
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    sources = source_text()
    problems = []
    for key, entry in catalog["strings"].items():
        localizations = entry.get("localizations", {})
        for language in LANGUAGES:
            if language not in localizations:
                problems.append(f"{key!r}: missing {language}")
                continue
            for value in values(localizations[language]):
                if not value.strip():
                    problems.append(f"{key!r}: empty {language}")
                if placeholders(value) != placeholders(key):
                    problems.append(f"{key!r}: {language} placeholders differ: {value!r}")
        if not key_pattern(key).search(sources):
            problems.append(f"{key!r}: not found in the app sources")
    for problem in problems:
        print("ERROR", problem)
    print(f"{len(catalog['strings'])} keys, {len(LANGUAGES)} languages, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
