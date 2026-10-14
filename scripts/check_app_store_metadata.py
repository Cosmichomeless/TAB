#!/usr/bin/env python3
"""Checks docs/release/app-store/<locale>.md against App Store Connect's field limits.

Usage: scripts/check_app_store_metadata.py   (exit code 1 on any problem)
"""
import re
import sys
from pathlib import Path

DIRECTORY = Path(__file__).resolve().parent.parent / "docs" / "release" / "app-store"
LOCALES = ["en-US", "es-ES", "fr-FR", "it", "pt-PT", "de-DE"]
LIMITS = {"Name": 30, "Subtitle": 30, "Promotional text": 170, "Description": 4000, "Keywords": 100, "What's new": 4000}


def sections(text):
    parts = re.split(r"^## (.+)$", text, flags=re.M)
    return {parts[i].strip(): parts[i + 1].strip() for i in range(1, len(parts) - 1, 2)}


def main():
    problems = []
    for locale in LOCALES:
        path = DIRECTORY / f"{locale}.md"
        if not path.exists():
            problems.append(f"{locale}: file missing")
            continue
        found = sections(path.read_text(encoding="utf-8"))
        for field, limit in LIMITS.items():
            value = found.get(field, "")
            if not value:
                problems.append(f"{locale}: {field} is empty")
            elif len(value) > limit:
                problems.append(f"{locale}: {field} has {len(value)} characters, the limit is {limit}")
        keywords = found.get("Keywords", "")
        if ", " in keywords or " ," in keywords:
            problems.append(f"{locale}: Keywords should be comma-separated without spaces around the commas")
        captions = [line for line in found.get("Screenshot captions", "").splitlines() if line.strip()]
        if len(captions) < 5:
            problems.append(f"{locale}: expected at least 5 screenshot captions")
    for problem in problems:
        print("ERROR", problem)
    print(f"{len(LOCALES)} locales, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
