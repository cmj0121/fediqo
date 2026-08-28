#!/usr/bin/env bash
#
# Reports what the tests that drive the app covered of Sources/FediqoUI.
#
#   scripts/ui_coverage.sh [derived data path]     # defaults to .build/xcode
#
# Reports, and does not gate. `scripts/coverage.sh` is the gate and it measures
# Sources/FediqoCore, for the reason its own header gives: nothing in the package can execute a
# SwiftUI view body, so counting them there would measure how much of the app is a view rather
# than how well it is tested. This is the other half of that sentence -- the app driven from
# outside itself, where the bodies do run. What the number ought to be is a question to answer
# from a few of these rather than from an opinion held in advance, which is why nothing here
# fails.
#
# Read the same way `coverage.sh` reads the package's: llvm-cov over the binary the run
# executed and the profile it left behind. `xccov` knows only about the project's own targets
# and FediqoUI is a package product linked into the app, so it reports the app's one source
# file and nothing else at all.

set -euo pipefail

# Resolved against wherever the caller stood, before this moves to the root of the checkout:
# `make -C Apps uitest` calls it from `Apps/` and hands over a path relative to that.
DERIVED_ARG="${1:-.build/xcode}"
DERIVED_ABSOLUTE="$(cd "$DERIVED_ARG" 2>/dev/null && pwd || true)"

cd "$(dirname "$0")/.."

DERIVED="${DERIVED_ABSOLUTE:-$DERIVED_ARG}"
PRODUCTS="$DERIVED/Build/Products/Debug/Fediqo.app/Contents/MacOS"
# The debug dylib where there is one -- a debug build puts the code there and leaves the
# executable a stub -- and the executable itself where there is not.
BINARY="$PRODUCTS/Fediqo.debug.dylib"
[ -f "$BINARY" ] || BINARY="$PRODUCTS/Fediqo"
PROFILE="$(find "$DERIVED/Build/ProfileData" -name '*.profdata' -print -quit 2>/dev/null || true)"

[ -f "$BINARY" ]  || { echo "no app binary at $BINARY -- run make -C Apps uitest first"; exit 1; }
[ -n "$PROFILE" ] || { echo "no coverage profile under $DERIVED/Build/ProfileData"; exit 1; }

SUMMARY="$(mktemp -t fediqo-ui-coverage)"
trap 'rm -f "$SUMMARY"' EXIT
xcrun llvm-cov export -summary-only -instr-profile "$PROFILE" "$BINARY" Sources/FediqoUI > "$SUMMARY"

python3 scripts/ui_coverage.py "$SUMMARY"
