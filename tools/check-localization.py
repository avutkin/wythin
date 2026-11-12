#!/usr/bin/env python3
"""Fail the build when the Russian app catalog is incomplete or malformed."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "ios/Wythin/Localizable.xcstrings"
PROJECT = ROOT / "ios/Wythin.xcodeproj/project.pbxproj"
INFO = ROOT / "ios/Wythin/InfoPlist.xcstrings"
TOKEN = re.compile(r"%(?:\d+\$)?([-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|d|f|g|@|%))")
SWIFT_LITERAL = re.compile(r'LocalizedCopy\.(?:text|format)\(\s*"((?:\\.|[^"\\])*)"')


def tokens(value: str) -> list[str]:
    # Xcode may add positional indices to an extracted interpolation.  Only
    # argument types matter for translation safety; ordinary prose containing
    # a percent sign must not be mistaken for a printf argument.
    return sorted(match.group(1) for match in TOKEN.finditer(value))


def swift_literal(value: str) -> str:
    value = re.sub(r"\\u\{([0-9a-fA-F]+)\}",
                   lambda match: chr(int(match.group(1), 16)), value)
    return value.replace(r"\n", "\n").replace(r"\t", "\t").replace(r'\"', '"')


def main() -> int:
    errors: list[str] = []
    if not CATALOG.is_file():
        errors.append(f"missing {CATALOG.relative_to(ROOT)}")
    if not INFO.is_file():
        errors.append(f"missing {INFO.relative_to(ROOT)}")
    else:
        info = json.loads(INFO.read_text())
        for key in ("CFBundleDisplayName", "CFBundleName",
                    "NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"):
            value = info.get("strings", {}).get(key, {}).get("localizations", {}).get("ru", {}).get("stringUnit", {}).get("value")
            if not value:
                errors.append(f"missing Russian Info.plist value: {key}")
    project = PROJECT.read_text()
    if not re.search(r"knownRegions\s*=\s*\([^)]*\bru\s*,", project, re.S):
        errors.append("Xcode project does not advertise ru")

    if CATALOG.is_file():
        data = json.loads(CATALOG.read_text())
        if data.get("sourceLanguage") != "en":
            errors.append("catalog source language must be en")
        strings = data.get("strings", {})
        for key in ("LIVE", "Settings", "No data for this day"):
            if key not in strings:
                errors.append(f"missing key: {key}")
        for key, entry in strings.items():
            if not key:
                continue
            if entry.get("shouldTranslate") is False:
                continue
            russian = entry.get("localizations", {}).get("ru", {}).get("stringUnit", {})
            value = russian.get("value")
            if not value:
                errors.append(f"missing Russian: {key}")
            elif tokens(key) != tokens(value):
                errors.append(f"format placeholders differ: {key}")
        for source in (ROOT / "ios/Wythin").rglob("*.swift"):
            swift = source.read_text()
            for match in SWIFT_LITERAL.finditer(swift):
                key = swift_literal(match.group(1))
                if key not in strings:
                    line = swift.count("\n", 0, match.start()) + 1
                    errors.append(f"missing runtime key: {source.relative_to(ROOT)}:{line}: {key[:80]}")
        print(f"catalog: {len(strings)} keys, {len(errors)} errors")

    for error in errors[:50]:
        print(error, file=sys.stderr)
    if len(errors) > 50:
        print(f"...and {len(errors) - 50} more", file=sys.stderr)
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
