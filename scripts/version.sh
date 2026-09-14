#!/usr/bin/env bash
#
# What a build calls itself, worked out from git rather than typed by a person.
#
#   scripts/version.sh              # MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=75
#   scripts/version.sh --marketing  # 0.1.0
#   scripts/version.sh --build      # 75
#
# The tag names the release and the history counts the attempts: `v0.1.0` on HEAD is release
# 0.1.0, and the number of commits behind HEAD is the build number, which only ever goes up.
# With no tag anywhere the answer is 0.0.0 -- there has not been a release, and saying 0.1.0
# would be inventing one.
#
# App Store Connect can already hold a build number this one would repeat: the same commit
# released twice counts the same commits twice. Stepping past that means asking the store,
# which needs its key, so it belongs to the release lane rather than here -- see #32. For the
# same reason a shallow clone lies to this script: a release checkout wants fetch-depth 0.

set -euo pipefail

cd "$(dirname "$0")/.."

NO_RELEASE_YET="0.0.0"

marketing() {
    local tag

    if tag="$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null)"; then
        echo "${tag#v}"
    elif tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)"; then
        echo >&2 "version.sh: no tag on HEAD -- settling for the nearest one, $tag"
        echo "${tag#v}"
    else
        echo >&2 "version.sh: no tag anywhere -- settling for $NO_RELEASE_YET"
        echo "$NO_RELEASE_YET"
    fi
}

build() {
    git rev-list --count HEAD
}

case "${1:---both}" in
    --marketing) marketing ;;
    --build)     build ;;
    --both)      echo "MARKETING_VERSION=$(marketing) CURRENT_PROJECT_VERSION=$(build)" ;;
    *)           echo >&2 "usage: ${0##*/} [--marketing|--build|--both]"; exit 2 ;;
esac
