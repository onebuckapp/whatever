#!/usr/bin/env python3
"""check-tr: every translation literal in Swift sources must exist in English.

Scans `macos/Sources/**/*.swift` for `tr("msgid")` and `LocaleItem("msgid")`
first-argument literals and fails when any is missing from `locale/en.po`.
xgettext does not parse Swift, so this is the extractor's honest half:
translators never silently lose a string.

Usage: locale/check-tr.py (from the repo root; exit 1 on missing msgids).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources"
ENGLISH = ROOT / "locale" / "en.po"

CALL = re.compile(r'(?:tr|LocaleItem)\(\s*"((?:[^"\\]|\\.)*)"')
MSGID = re.compile(r'^msgid "(.*)"$')
CONT = re.compile(r'^"(.*)"$')


def unescape(literal: str) -> str:
    # Swift escapes that occur in msgids: \" and \\ everywhere, \u{...}
    # where the source spells a non-ASCII character as an escape (the
    # runtime string is identical either way, so the template holds the
    # literal character). Anything fancier belongs in a comment, not a
    # lookup key.
    literal = re.sub(
        r"\\u\{([0-9A-Fa-f]+)\}",
        lambda match: chr(int(match.group(1), 16)),
        literal,
    )
    return (
        literal.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n").replace("\\t", "\t")
    )


def source_msgids() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            # Doc comments may quote tr() usage as an example; only code counts.
            if line.strip().startswith("//"):
                continue
            for match in CALL.finditer(line):
                msgid = unescape(match.group(1))
                found.setdefault(msgid, []).append(f"{path.relative_to(ROOT)}:{lineno}")
    return found


def template_msgids() -> set[str]:
    msgids: set[str] = set()
    current: list[str] | None = None
    for line in ENGLISH.read_text(encoding="utf-8").splitlines():
        msg = MSGID.match(line)
        if msg:
            current = [msg.group(1)]
            continue
        if current is not None:
            cont = CONT.match(line)
            if cont:
                current.append(cont.group(1))
                continue
            text = "".join(current)
            if text:
                msgids.add(unescape(text))
            current = None
    if current:
        text = "".join(current)
        if text:
            msgids.add(unescape(text))
    return msgids


def main() -> int:
    if not ENGLISH.exists():
        print(f"check-tr: no English source at {ENGLISH}", file=sys.stderr)
        return 1
    template = template_msgids()
    missing = {
        msgid: locations
        for msgid, locations in source_msgids().items()
        if msgid not in template
    }
    if not missing:
        print("check-tr: all translation literals are in en.po")
        return 0
    for msgid, locations in sorted(missing.items()):
        print(f'missing msgid "{msgid}" at:')
        for location in locations:
            print(f"  {location}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
