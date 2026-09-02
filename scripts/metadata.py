#!/usr/bin/env python3
"""What the store is told, checked before the store is told it.

    scripts/metadata.py                       # the tree, the lengths, the links
    scripts/metadata.py --version 0.1.0       # ... and that this version has release notes
    scripts/metadata.py --resolve             # ... and that the links answer

`deliver` reads a folder per language and uploads what it finds. What it does with a folder
whose name it does not recognise is nothing at all: no error, no warning, and a release that
went out in one language while somebody was sure it went out in two. `zh-TW` is the folder
this project will get wrong -- it is the code the documentation uses, it is not the code App
Store Connect uses, and it is the one deliver would skip in silence. So the languages are
named here, and anything else in the tree is a failure rather than a shrug.

The lengths are here for the same reason one step earlier: App Store Connect rejects a
description of 4001 characters after the archive has been built, signed and uploaded, which
is forty minutes to be told something a file could have said in a second.

Release notes are not in the language folders. They belong to a version rather than to an
app, and a file that is overwritten each release is a file that quietly ships the last
release's notes when somebody forgets. They live under `notes/<version>/` instead, so a tag
with nothing written for it has nowhere to read from and the release stops.
"""

from __future__ import annotations

import argparse
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METADATA = ROOT / "fastlane" / "metadata"
NOTES = METADATA / "notes"
SCREENSHOTS = ROOT / "fastlane" / "screenshots"

# The two the project ships, spelled the way App Store Connect spells them. Traditional
# Chinese is `zh-Hant` there and `zh-TW` in every filename in docs/; they are not the same
# string and only one of them uploads anything.
LOCALES = ("en-US", "zh-Hant")

# One record on App Store Connect, two platforms in it.
PLATFORMS = ("ios", "macos")

# What App Store Connect counts, and where it stops counting.
LIMITS = {
    "name": 30,
    "subtitle": 30,
    "keywords": 100,
    "description": 4000,
    "promotional_text": 170,
    "release_notes": 4000,
}

REQUIRED = ("name", "subtitle", "description", "keywords", "support_url", "privacy_url")
OPTIONAL = ("promotional_text", "marketing_url")

# Name, subtitle and privacy link belong to the app rather than to one of its platforms:
# App Store Connect keeps one of each per language, whichever platform uploaded it. Both
# trees carry them anyway, because deliver reads a whole folder or none of it -- so the only
# way they can differ is by drifting, and the second upload of a run would silently win.
SHARED = ("name", "subtitle", "privacy_url")

URLS = ("support_url", "privacy_url", "marketing_url")

# The mistakes worth naming, rather than answering with a list of every language Apple has.
NEAR_MISSES = {
    "zh-TW": "zh-Hant",
    "zh-Hant-TW": "zh-Hant",
    "zh_Hant": "zh-Hant",
    "zh": "zh-Hant",
    "en": "en-US",
    "en_US": "en-US",
    "en-GB": "en-US",
}


class Report:
    """Everything wrong, rather than the first thing wrong.

    A run that stops at the first bad file is a run somebody has to repeat once per bad file,
    and these are files written in one sitting.
    """

    def __init__(self) -> None:
        self.problems: list[str] = []

    def fail(self, message: str) -> None:
        self.problems.append(message)

    def ok(self) -> bool:
        return not self.problems


def read(path: Path) -> str:
    """A metadata file's content as the store will see it -- deliver strips the ends too."""
    return path.read_text(encoding="utf-8").strip()


def check_locales(report: Report) -> None:
    """Which folders are there, against which folders mean anything."""
    for platform in PLATFORMS:
        root = METADATA / platform
        if not root.is_dir():
            report.fail(f"{platform}: no folder for this platform at all")
            continue

        found = {entry.name for entry in root.iterdir() if entry.is_dir()}

        for unknown in sorted(found - set(LOCALES)):
            hint = NEAR_MISSES.get(unknown)
            said = f" -- App Store Connect calls that one '{hint}'" if hint else ""
            report.fail(
                f"{platform}/{unknown}: not a language this project ships{said}. "
                f"deliver would skip it without saying so."
            )

        for missing in sorted(set(LOCALES) - found):
            report.fail(f"{platform}/{missing}: missing, and it is one of the two we ship")


def check_screenshots(report: Report) -> None:
    """The pictures, where somebody has taken any, in folders deliver recognises.

    The same trap as the text and the same silence: a language folder deliver does not know is
    a language that ships no pictures, and nothing says so. Absent altogether is fine — the
    lane uploads none rather than uploading zero, which App Store Connect would read as an
    answer — so this only has something to say once a folder exists.
    """
    if not SCREENSHOTS.is_dir():
        return

    for platform in PLATFORMS:
        root = SCREENSHOTS / platform
        if not root.is_dir():
            continue

        found = {entry.name for entry in root.iterdir() if entry.is_dir()}
        for unknown in sorted(found - set(LOCALES)):
            hint = NEAR_MISSES.get(unknown)
            said = f" -- App Store Connect calls that one '{hint}'" if hint else ""
            report.fail(f"screenshots/{platform}/{unknown}: not a language this project ships{said}")

        for locale in sorted(found & set(LOCALES)):
            pictures = sorted((root / locale).glob("*.png"))
            if not pictures:
                report.fail(f"screenshots/{platform}/{locale}: a folder with no pictures in it")

        # Both languages or neither. A release that went out with pictures in one language and
        # none in the other is the failure this whole file exists to prevent, wearing a
        # different hat.
        missing = sorted(set(LOCALES) - found)
        if found and missing:
            report.fail(f"screenshots/{platform}: pictures for {', '.join(sorted(found))} "
                        f"and none for {', '.join(missing)}")


def check_files(report: Report) -> None:
    """What is in each language folder, how long it is, and whether it is a link."""
    known = set(REQUIRED) | set(OPTIONAL)

    for platform in PLATFORMS:
        for locale in LOCALES:
            folder = METADATA / platform / locale
            if not folder.is_dir():
                continue

            for entry in sorted(folder.iterdir()):
                if entry.name == "release_notes.txt":
                    report.fail(
                        f"{platform}/{locale}/release_notes.txt: release notes belong to a "
                        f"version, not to a language -- put them in "
                        f"fastlane/metadata/notes/<version>/{locale}.txt"
                    )
                elif entry.stem not in known or entry.suffix != ".txt":
                    report.fail(f"{platform}/{locale}/{entry.name}: deliver has no field of that name")

            for field in REQUIRED:
                path = folder / f"{field}.txt"
                if not path.is_file():
                    report.fail(f"{platform}/{locale}/{field}.txt: missing")
                elif not read(path):
                    report.fail(f"{platform}/{locale}/{field}.txt: empty, which uploads nothing")

            for field in known:
                path = folder / f"{field}.txt"
                if not path.is_file():
                    continue
                text = read(path)
                check_length(report, f"{platform}/{locale}/{field}.txt", field, text)
                if field in URLS and text and not text.startswith("https://"):
                    report.fail(f"{platform}/{locale}/{field}.txt: not an https link")
                if field == "keywords" and text:
                    check_keywords(report, f"{platform}/{locale}/keywords.txt", text)


def check_length(report: Report, where: str, field: str, text: str) -> None:
    limit = LIMITS.get(field)
    if limit is not None and len(text) > limit:
        report.fail(f"{where}: {len(text)} characters, and App Store Connect takes {limit}")


def check_keywords(report: Report, where: str, text: str) -> None:
    """One hundred characters, and a space after a comma is one of them."""
    if ", " in text:
        report.fail(f"{where}: a space after a comma is charged against the 100 -- separate with commas alone")

    words = [word.strip() for word in text.split(",")]
    if "" in words:
        report.fail(f"{where}: an empty keyword, from a doubled or trailing comma")

    seen = {word for word in words if words.count(word) > 1 and word}
    for word in sorted(seen):
        report.fail(f"{where}: '{word}' is in there twice, and the second one is spent characters")


def check_shared(report: Report) -> None:
    """The fields App Store Connect keeps one of, kept the same in both trees."""
    for locale in LOCALES:
        for field in SHARED:
            values = {}
            for platform in PLATFORMS:
                path = METADATA / platform / locale / f"{field}.txt"
                if path.is_file():
                    values[platform] = read(path)

            if len(set(values.values())) > 1:
                said = ", ".join(f"{platform} says {value!r}" for platform, value in sorted(values.items()))
                report.fail(
                    f"{locale}/{field}.txt: App Store Connect keeps one of these per language, "
                    f"so whichever platform uploads last wins -- {said}"
                )


def check_notes(report: Report, version: str) -> None:
    """That this version has something to say, written before the tag that ships it."""
    folder = NOTES / version
    if not folder.is_dir():
        report.fail(
            f"notes/{version}/: nothing written for this version. Release notes are written "
            f"before the tag, not after -- see docs/release.md."
        )
        return

    for locale in LOCALES:
        path = folder / f"{locale}.txt"
        if not path.is_file():
            report.fail(f"notes/{version}/{locale}.txt: missing")
        elif not read(path):
            report.fail(f"notes/{version}/{locale}.txt: empty")
        else:
            check_length(report, f"notes/{version}/{locale}.txt", "release_notes", read(path))


def check_resolve(report: Report) -> None:
    """That the links answer. Apple checks them too, and later.

    The support link and the privacy link are the two the review asks about by name, and a
    link that has rotted is found either here or by a reviewer a fortnight from now.
    """
    links: dict[str, str] = {}
    for platform in PLATFORMS:
        for locale in LOCALES:
            for field in URLS:
                path = METADATA / platform / locale / f"{field}.txt"
                if path.is_file() and read(path):
                    links.setdefault(read(path), f"{platform}/{locale}/{field}.txt")

    for url, where in sorted(links.items()):
        status = fetch(url)
        if status is None or status >= 400:
            said = "no answer" if status is None else f"answered {status}"
            report.fail(f"{where}: {url} {said}")
        else:
            print(f"  {url}  {status}")


def fetch(url: str) -> int | None:
    """The status a link answers with, or nothing where it would not answer at all.

    HEAD first, because the body is not the question. Some hosts refuse the method rather
    than the address, and a 405 says the address is fine -- so that one is asked again.
    """
    for method in ("HEAD", "GET"):
        request = urllib.request.Request(url, method=method, headers={"User-Agent": "fediqo-metadata"})
        try:
            with urllib.request.urlopen(request, timeout=15) as answer:
                return answer.status
        except urllib.error.HTTPError as error:
            if error.code == 405 and method == "HEAD":
                continue
            return error.code
        except OSError:
            return None
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the store text before the store is handed it.")
    parser.add_argument("--version", help="also require release notes for this marketing version")
    parser.add_argument("--resolve", action="store_true", help="also ask whether the links answer")
    arguments = parser.parse_args()

    report = Report()

    if not METADATA.is_dir():
        print(f"metadata.py: no store text at {METADATA}", file=sys.stderr)
        return 1

    print(f"{METADATA.relative_to(ROOT)}: {' and '.join(PLATFORMS)}, in {' and '.join(LOCALES)}")

    check_locales(report)
    check_files(report)
    check_shared(report)
    check_screenshots(report)

    if arguments.version:
        check_notes(report, arguments.version)
        print(f"  release notes for {arguments.version}")

    if arguments.resolve:
        check_resolve(report)

    if report.ok():
        print("the store text is what it says it is")
        return 0

    # Flushed, because the two streams are one terminal and a reader reads them in order.
    sys.stdout.flush()
    print(file=sys.stderr)
    print("metadata.py: the store must not be told this:", file=sys.stderr)
    for problem in report.problems:
        print(f"  {problem}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
