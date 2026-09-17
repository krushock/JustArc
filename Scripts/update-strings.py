#!/usr/bin/env python3
"""Regenerates the Localizable.strings files from the L("...") calls in the sources.

Existing translations are preserved; new keys are reported so they can be filled in.
Run it after adding or changing any user-facing string.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources/JustArc/Resources"
LANGUAGES = ["en", "ru"]

CALL = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
CONCATENATED = re.compile(r'\bL\(\s*"(?:[^"\\]|\\.)*"\s*\n?\s*\+')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def lint(paths):
    """A key assembled with + cannot be extracted, so it would never be translated."""
    problems = []
    for path in paths:
        text = path.read_text()
        for match in CONCATENATED.finditer(text):
            line = text[: match.start()].count("\n") + 1
            problems.append(f"{path.relative_to(ROOT)}:{line}")
    return problems


def collect_keys():
    sources = [p for p in (ROOT / "Sources").rglob("*.swift") if p.name != "Localized.swift"]
    problems = lint(sources)
    if problems:
        print("error: these L() calls build their key by concatenation, so it cannot be", file=sys.stderr)
        print("       extracted. Put the whole message in one string literal.", file=sys.stderr)
        for problem in problems:
            print(f"       {problem}", file=sys.stderr)
        sys.exit(1)

    keys = set()
    for path in sources:
        keys.update(match.group(1) for match in CALL.finditer(path.read_text()))

    # Menu titles reach L() as a parameter, so take them from the call sites.
    menu = (ROOT / "Sources/JustArc/App/MainMenuBuilder.swift").read_text()
    keys.update(re.findall(r'\bsubmenu\(\s*"((?:[^"\\]|\\.)*)"', menu))
    keys.update(re.findall(r'\badd\(\s*menu\s*,\s*"((?:[^"\\]|\\.)*)"', menu))
    return sorted(keys)


def read_existing(language):
    path = RESOURCES / f"{language}.lproj/Localizable.strings"
    if not path.exists():
        return {}
    translations = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = ENTRY.match(line.strip())
        if match:
            translations[match.group(1)] = match.group(2)
    return translations


def write(language, keys, translations):
    path = RESOURCES / f"{language}.lproj/Localizable.strings"
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"/* JustArc — {language}.\n"
        "   The English text is the key, so anything untranslated still reads correctly.\n"
        "   Regenerate with Scripts/update-strings.py after changing any message. */\n\n"
    ]
    for key in keys:
        lines.append('"%s" = "%s";\n' % (key, translations.get(key, key)))
    path.write_text("".join(lines), encoding="utf-8")


def main():
    keys = collect_keys()
    for language in LANGUAGES:
        existing = read_existing(language)
        # An English string is its own key, so nothing is ever missing there.
        missing = [] if language == "en" else [k for k in keys if k not in existing]
        stale = [k for k in existing if k not in keys]
        write(language, keys, existing)
        print(f"{language}: {len(keys)} keys, {len(missing)} untranslated, {len(stale)} dropped")
        for key in missing:
            print(f"   needs {language}: {key!r}")


if __name__ == "__main__":
    main()
