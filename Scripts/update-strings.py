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

# A literal that reads like a sentence and is not wrapped in L() is very likely a
# message someone will see. This caught a whole batch that an earlier pass missed,
# because that pass only understood assignments and not labelled arguments.
SENTENCE = re.compile(r'"([A-Z][^"\\]*\s[^"\\]*)"')

# Strings that look like prose but are not shown to anyone: keys in property lists,
# keys in 7-Zip's listing output, date patterns and paths.
NOT_USER_FACING = {
    "Format Description",
    "Physical Size",
    "Packed Size",
    "Host OS",
    "Library/Application Support",
    "GUID_partition_scheme",
    "My Drive",
    "yyyy-MM-dd HH:mm:ss",
    "ERROR: ",
    "Apple Development",
}

# Whole files that only ever build command lines or log lines.
LINT_SKIP_FILES = {"Localized.swift", "Diagnostics.swift", "ProcessRunner.swift",
                   "MainMenuBuilder.swift"}


def lint_concatenated(paths):
    """A key assembled with + cannot be extracted, so it would never be translated."""
    problems = []
    for path in paths:
        text = path.read_text()
        for match in CONCATENATED.finditer(text):
            line = text[: match.start()].count("\n") + 1
            problems.append(f"{path.relative_to(ROOT)}:{line}")
    return problems


def lint_unwrapped(paths):
    """Sentence-like literals that never reach the translation files."""
    problems = []
    for path in paths:
        if path.name in LINT_SKIP_FILES:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or "Diagnostics.log" in line:
                continue
            for match in SENTENCE.finditer(line):
                value = match.group(1)
                if value in NOT_USER_FACING:
                    continue
                if line[max(0, match.start() - 2):match.start()] == "L(":
                    continue
                problems.append(f"{path.relative_to(ROOT)}:{number}: {value!r}")
    return problems


def collect_keys():
    sources = [p for p in (ROOT / "Sources").rglob("*.swift") if p.name != "Localized.swift"]
    problems = lint_concatenated(sources)
    if problems:
        print("error: these L() calls build their key by concatenation, so it cannot be", file=sys.stderr)
        print("       extracted. Put the whole message in one string literal.", file=sys.stderr)
        for problem in problems:
            print(f"       {problem}", file=sys.stderr)
        sys.exit(1)

    unwrapped = lint_unwrapped(sources)
    if unwrapped:
        print("error: these literals look like messages but are not wrapped in L(), so", file=sys.stderr)
        print("       they would stay English. Wrap them, or add them to NOT_USER_FACING.", file=sys.stderr)
        for problem in unwrapped:
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


TODO_MARKER = "/* needs translation */"


def read_existing(language):
    """Returns (translations, untranslated keys).

    A translation can legitimately equal its English key, for instance "OK" or a
    format name, so sameness cannot be used to detect missing work. The marker
    comment written below is what carries that across runs.
    """
    path = RESOURCES / f"{language}.lproj/Localizable.strings"
    if not path.exists():
        return {}, set()
    translations = {}
    untranslated = set()
    pending_marker = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line == TODO_MARKER:
            pending_marker = True
            continue
        match = ENTRY.match(line)
        if match:
            translations[match.group(1)] = match.group(2)
            if pending_marker:
                untranslated.add(match.group(1))
        pending_marker = False
    return translations, untranslated


def write(language, keys, translations, untranslated):
    path = RESOURCES / f"{language}.lproj/Localizable.strings"
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"/* JustArc — {language}.\n"
        "   The English text is the key, so anything untranslated still reads correctly.\n"
        "   Regenerate with Scripts/update-strings.py after changing any message. */\n\n"
    ]
    for key in keys:
        if key in untranslated:
            lines.append(TODO_MARKER + "\n")
        lines.append('"%s" = "%s";\n' % (key, translations.get(key, key)))
    path.write_text("".join(lines), encoding="utf-8")


SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(l{0,2}[dDuUxXfFeEgGcCsS@])|%%")


def argument_types(text):
    """The type each argument must have, in argument order, or None if inconsistent.

    A translation may reorder its arguments, but only with positional specifiers
    such as %2$@. Reordering plain ones makes String(format:) read an integer as an
    object pointer, which crashes.
    """
    plain, positional = [], {}
    for match in SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        kind = match.group(2).lstrip("l").lower()
        if match.group(1):
            positional[int(match.group(1))] = kind
        else:
            plain.append(kind)
    if positional and plain:
        return None
    if positional:
        if sorted(positional) != list(range(1, len(positional) + 1)):
            return None
        return [positional[index] for index in sorted(positional)]
    return plain


def check_format_arguments(language, translations):
    problems = []
    for key, value in translations.items():
        if argument_types(value) != argument_types(key):
            problems.append(key)
    for key in problems:
        print(f"   {language}: format arguments do not match the English for {key!r}:\n"
              f"      {translations[key]!r}")
    return not problems


def main():
    keys = collect_keys()
    consistent = True
    for language in LANGUAGES:
        existing, previously_untranslated = read_existing(language)
        if language == "en":
            # An English string is its own key, so nothing is ever missing there.
            missing = set()
        else:
            missing = {k for k in keys if k not in existing} | (previously_untranslated & set(keys))
        stale = [k for k in existing if k not in keys]
        write(language, keys, existing, missing)
        consistent &= check_format_arguments(language, {k: existing[k] for k in keys if k in existing})
        print(f"{language}: {len(keys)} keys, {len(missing)} untranslated, {len(stale)} dropped")
        for key in sorted(missing):
            print(f"   needs {language}: {key!r}")
    if not consistent:
        sys.exit("A translation takes its arguments in a different order or type. "
                 "Use positional specifiers such as %1$d and %2$@.")


if __name__ == "__main__":
    main()
