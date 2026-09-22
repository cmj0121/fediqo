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

# What `--source` says (#143), in a throwaway repository for the reason `answer` is. Each case is
# a shell fragment run in a repository with one commit, and the answer is compared with `$head`
# standing for that commit, since its hash is only known once it has been made.
source_answer() {
    local setup="$1"
    local repo; repo="$(mktemp -d)"
    mkdir -p "$repo/scripts"
    cp "$SCRIPT" "$repo/scripts/version.sh"
    (
        cd "$repo"
        git init -q .
        git config user.email t@example.com
        git config user.name t
        printf 'scripts/\n' > .gitignore
        printf 'one\n' > tracked
        git add .gitignore tracked
        git commit -q -m one
        eval "$setup"
        local head; head="$(git rev-parse HEAD 2>/dev/null || echo no-commit)"
        ./scripts/version.sh --source 2>/dev/null | sed "s/$head/\$head/"
    )
    rm -rf "$repo"
}

source_check() {
    local want="$1" note="$2" setup="$3"
    local got; got="$(source_answer "$setup" || echo "<the script failed>")"

    if [ "$got" = "$want" ]; then
        printf '  ok    %s\n' "$note"
    else
        printf '  FAIL  wanted "%s" got "%s" -- %s\n' "$want" "$got" "$note"
        failures=$((failures + 1))
    fi
}

echo
echo "version.sh --source:"

source_check 'FEDIQO_SOURCE_REVISION=$head FEDIQO_SOURCE_DIRTY=NO'  "a clean checkout names its commit" ":"
source_check 'FEDIQO_SOURCE_REVISION=$head FEDIQO_SOURCE_DIRTY=YES' "a changed file is a change"     "printf 'two\n' > tracked"
source_check 'FEDIQO_SOURCE_REVISION=$head FEDIQO_SOURCE_DIRTY=YES' "so is a file nobody has added"   "touch new.swift"
source_check 'FEDIQO_SOURCE_REVISION=$head FEDIQO_SOURCE_DIRTY=NO'  "an ignored file is not"          "mkdir -p scripts/x; touch scripts/x/y"
source_check ''                                                     "no checkout at all: nothing"      "rm -rf .git"

echo
if [ "$failures" -eq 0 ]; then
    echo "version.sh: every case answered"
else
    echo "version.sh: $failures case(s) wrong"
    exit 1
fi
