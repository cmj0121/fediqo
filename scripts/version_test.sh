#!/usr/bin/env bash
#
# What `version.sh` answers, for every shape of `VERSION` and tag there is.
#
#   scripts/version_test.sh
#
# **In a throwaway repository, never this one.** The cases below need tags on commits that are not
# HEAD, and a test that made them here would leave `v0.1.3` lying in somebody's checkout naming a
# release that never happened -- which is exactly the kind of false record the script exists to
# stop. Each case gets its own `git init` under `mktemp -d`.
#
# The first case is the one that mattered: with no tag anywhere, `grep` in `highest_released`
# matched nothing, exited 1, and `pipefail` plus `set -e` ended the script -- so the very first
# build of a series printed an empty version and the release lane stamped a build with nothing.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/version.sh"

failures=0

# Builds a repository with three commits, tags whatever is asked for on the *first* one, writes
# `VERSION`, and reports what the script makes of it.
#
# Tagging the first commit and not HEAD is deliberate: a tag on HEAD is a rebuild of that release
# and takes a different branch of the script, so tagging HEAD everywhere would have left the
# "next patch in the series" path untested -- which is how this file's own first draft passed
# while the script was broken.
answer() {
    local version="$1"; shift
    local repo; repo="$(mktemp -d)"

    # **Copied in, not called where it lives.** `version.sh` opens with `cd "$(dirname "$0")/.."`,
    # which is right in production -- it answers for its own checkout wherever it is invoked from
    # -- and means a copy running from the real `scripts/` would read the real `VERSION` and the
    # real tags. The test's first run did exactly that and reported 0.1.0 for every case,
    # including the one with no `VERSION` at all.
    mkdir -p "$repo/scripts"
    cp "$SCRIPT" "$repo/scripts/version.sh"

    (
        cd "$repo"
        git init -q .
        git config user.email t@example.com
        git config user.name t
        git commit -q --allow-empty -m one
        for tag in "$@"; do git tag "$tag"; done
        git commit -q --allow-empty -m two
        git commit -q --allow-empty -m three
        [ "$version" = "--none" ] || printf '%s\n' "$version" > VERSION
        ./scripts/version.sh --marketing 2>/dev/null
    )
    rm -rf "$repo"
}

check() {
    local want="$1" note="$2"; shift 2
    local got; got="$(answer "$@" || echo "<the script failed>")"

    if [ "$got" = "$want" ]; then
        printf '  ok    %-9s %s\n' "$got" "$note"
    else
        printf '  FAIL  wanted %-9s got %-20s %s\n' "$want" "$got" "$note"
        failures=$((failures + 1))
    fi
}

echo "version.sh:"

check 0.1.0 "a series nobody has released -- no tag is needed to build it" 0.1
check 0.1.1 "the tag is the last word, and the next commit is past it"     0.1 v0.1.0
check 0.1.4 "gaps in the series do not repeat a number"                    0.1 v0.1.0 v0.1.3
check 0.1.11 "sorted as numbers: the eleventh is not the tenth"            0.1 v0.1.9 v0.1.10
check 0.2.0 "a new series starts at .0 whatever the old one reached"       0.2 v0.1.0 v0.1.9
check 0.1.7 "three components pin the version outright"                    0.1.7 v0.1.0
check 0.1.0 "a tag from another series does not answer for this one"       0.1 v0.2.5
check 0.0.0 "no VERSION at all: there has not been a release"              --none

echo
if [ "$failures" -eq 0 ]; then
    echo "version.sh: every case answered"
else
    echo "version.sh: $failures case(s) wrong"
    exit 1
fi
