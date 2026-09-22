#!/usr/bin/env bash
#
# What a build calls itself, worked out from `VERSION` and the tags rather than typed by a person.
#
#   scripts/version.sh              # MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=75
#   scripts/version.sh --marketing  # 0.1.0
#   scripts/version.sh --build      # 75
#   scripts/version.sh --source     # FEDIQO_SOURCE_REVISION=532ab49… FEDIQO_SOURCE_DIRTY=NO
#
# `VERSION` names the series this checkout is working towards -- `0.1` -- and the tags say which
# of that series have already been released. The patch number is the one after the highest tag in
# the series, or `.0` where the series has never been released. So the first TestFlight build of
# `0.1.0` needs no tag at all, which is what `docs/release.md` has always claimed and what this
# script did not do.
#
# **The circle this breaks.** `release.md` says to tag what was released, afterwards -- the tag
# names the release rather than causing it. But the marketing version was read *from* the tag, so
# nothing could be built to be released until it had been tagged as released. With no tag anywhere
# the answer was `0.0.0`, which has no release notes and never will, and `make publish` stopped on
# that before it built anything.
#
# **The tag is the last word, and the next commit is past it.** Tag `v0.1.0` and this says `0.1.1`
# from the next build on: the series moves on by itself, and nobody edits a number to make it.
# `VERSION` is only edited to open a new series -- `0.2` -- which is the one decision a person
# should be making.
#
# **`VERSION` may pin a whole version instead.** Three components (`0.1.7`) are used exactly as
# written, for the case where a particular number has to be built whatever the tags say. Two
# components is the ordinary way.
#
# App Store Connect can already hold a build number this one would repeat: the same commit
# released twice counts the same commits twice. Stepping past that means asking the store, which
# needs its key, so it belongs to the release lane rather than here -- see #32. For the same
# reason a shallow clone lies to this script: a release checkout wants fetch-depth 0.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION_FILE="VERSION"
NO_RELEASE_YET="0.0.0"

# The series, as written down. Blank lines and `#` comments are allowed so the file can say what
# it is for; anything else has to be a version, because a typo here names the release.
series() {
    [ -f "$VERSION_FILE" ] || return 1

    local said
    said="$(grep -vE '^[[:space:]]*(#|$)' "$VERSION_FILE" | head -1 | tr -d '[:space:]')"
    [ -n "$said" ] || return 1

    if ! [[ "$said" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo >&2 "version.sh: $VERSION_FILE says '$said', which is not a version"
        exit 2
    fi
    echo "$said"
}

# The highest patch already tagged in this series, or nothing where none has been.
#
# Sorted numerically on the patch alone rather than with `sort -V`, which is not on every machine
# this runs on -- and a lexical sort would put `v0.1.10` before `v0.1.9`, so the eleventh release
# of a series would be named the tenth.
# `|| true` because no match is the ordinary answer, not a failure: a series that has never been
# released has no tag, and that is the whole case this script was rewritten for. Without it
# `grep` exits 1, `pipefail` carries that out of the function, and `set -e` ends the script --
# so the very first build of 0.1.0 printed nothing at all and the lane read an empty version.
highest_released() {
    git tag -l "v$1.*" 2>/dev/null |
        sed "s|^v$1\.||" |
        { grep -E '^[0-9]+$' || true; } |
        sort -n |
        tail -1
}

marketing() {
    local said tag patch

    if ! said="$(series)"; then
        # No `VERSION` at all: the old answer, which says there has not been a release rather
        # than inventing one.
        echo >&2 "version.sh: no $VERSION_FILE -- settling for $NO_RELEASE_YET"
        echo "$NO_RELEASE_YET"
        return
    fi

    # Pinned outright.
    if [[ "$said" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$said"
        return
    fi

    # Sitting exactly on a tag of this series is a rebuild of that release, not the next one.
    # Checked against the series so that a tag left on HEAD from an older one cannot quietly
    # answer for a series `VERSION` has already moved past.
    if tag="$(git describe --tags --exact-match --match "v$said.[0-9]*" 2>/dev/null)"; then
        echo "${tag#v}"
        return
    fi

    patch="$(highest_released "$said")"
    if [ -n "$patch" ]; then
        echo "$said.$((patch + 1))"
    else
        echo "$said.0"
    fi
}

build() {
    git rev-list --count HEAD
}

# Which source a build is made from (#143): the commit, whole, and whether the checkout differed
# from it when the build was asked for. Neither number above can say it -- a build number counts
# commits, and two branches the same length count the same -- so a report that names only those
# cannot tell the build that fixed something from the one beside it.
#
# **Dirty is anything `git status` would show**, untracked files included, because an untracked
# file under `Sources/` is compiled exactly as a tracked one is. What is ignored is not counted:
# `.build/`, the generated project, `.env`. It is asked when the build is asked for, after
# XcodeGen has rewritten the plists it owns, so a build is dirty only if what it compiles is.
#
# **Outside a checkout it prints nothing**, and the build is simply not stamped. The app then
# says it does not know which source it came from, which is true, rather than naming one.
#
# Not part of `--both`: that line is what `make version` prints for a person, and it answers
# what the build calls itself, which this does not change.
source_stamp() {
    local revision dirty=NO

    revision="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || return 0
    [ -z "$(git status --porcelain 2>/dev/null)" ] || dirty=YES
    echo "FEDIQO_SOURCE_REVISION=$revision FEDIQO_SOURCE_DIRTY=$dirty"
}

case "${1:---both}" in
    --marketing) marketing ;;
    --build)     build ;;
    --source)    source_stamp ;;
    --both)      echo "MARKETING_VERSION=$(marketing) CURRENT_PROJECT_VERSION=$(build)" ;;
    *)           echo >&2 "usage: ${0##*/} [--marketing|--build|--source|--both]"; exit 2 ;;
esac
