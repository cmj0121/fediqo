#!/usr/bin/env bash
#
# Fails if the tested part of the package is covered less than it should be.
#
#   scripts/coverage.sh [threshold]      # threshold defaults to 85 (per cent of lines)
#
# What is measured is Sources/FediqoCore, and only that. FediqoUI is SwiftUI view bodies:
# nothing in this package can execute them, so counting them would not measure how well the
# app is tested -- it would measure how much of the app is a view. When there is a UI test
# target it gets a gate of its own rather than being folded into this one.

set -euo pipefail

THRESHOLD="${1:-85}"
MEASURED="${COVERAGE_PATH:-Sources/FediqoCore}"

cd "$(dirname "$0")/.."

# Pin to Package.resolved when there is one, so a run never quietly
# resolves a newer dependency. A dummy with no packages has no file.
#
# One test at a time. A runner builds every test target into one process, and with a few
# thousand tests started together -- most of them bound to the one main actor -- each step of
# a test waits behind every other test's. The tests that guard against a hang by the clock
# (fifty seconds, a minute) then ran out of it without anything being wrong: forty-five
# failed that way on a run where nothing else did. Taken one at a time they have the machine
# to themselves, and the run is a minute longer. `make test` on a desk stays as it was.
#
# What the run says is kept in a file and what matters of it is said afterwards. Left to
# write straight to a runner's log, the run's output stopped a few seconds in and the step
# ended with a bare exit code: a failure nobody could read. Every test that starts and
# passes is tens of thousands of lines; what is said here is everything else, and each
# test that did not pass, in full.
RUN_LOG="$(mktemp -t fediqo-tests)"
RESOLVED=()
[ -f Package.resolved ] && RESOLVED=(--only-use-versions-from-resolved-file)
set +e
swift test --no-parallel --enable-code-coverage ${RESOLVED[@]+"${RESOLVED[@]}"} > "$RUN_LOG" 2>&1
TEST_CODE=$?
set -e
grep -vE '^◇ |^✔ (Test|Suite)|^↳ ' "$RUN_LOG" | tail -300 || true
grep -E 'Test run with' "$RUN_LOG" || true
if [ "$TEST_CODE" -ne 0 ]; then
    echo
    echo "the tests failed (swift test exited $TEST_CODE); each issue, as it was recorded:"
    grep -E -A12 'recorded an issue' "$RUN_LOG" | grep -vE '^◇ |^✔ ' | head -400 || true
    exit "$TEST_CODE"
fi

BIN_PATH="$(swift build --show-bin-path)"
PROFILE="$BIN_PATH/codecov/default.profdata"

# Which bundles a build leaves behind is a fact about the toolchain, not about this package.
# Up to Xcode 26 SwiftPM wrote one combined `FediqoPackageTests.xctest`; Xcode 27's build system
# writes one bundle per test target instead, and the gate died with "no test binary" the morning
# the machine updated itself. Both layouts are accepted, and a layout nobody has seen yet fails
# loudly rather than reporting the coverage of whatever it did find.
# llvm-cov takes the first binary as a positional and every further one behind `-object`,
# so they are collected in that shape rather than as a plain list.
BINARIES=()
for bundle in "$BIN_PATH"/*.xctest; do
    [ -d "$bundle" ] || continue
    name="$(basename "$bundle" .xctest)"
    exe="$bundle/Contents/MacOS/$name"
    [ -x "$exe" ] || continue
    if [ "${#BINARIES[@]}" -eq 0 ]; then BINARIES+=("$exe"); else BINARIES+=(-object "$exe"); fi
done

[ "${#BINARIES[@]}" -gt 0 ] || { echo "no test bundle under $BIN_PATH"; exit 1; }
[ -f "$PROFILE" ] || { echo "no coverage profile at $PROFILE"; exit 1; }

SUMMARY="$(mktemp -t fediqo-coverage)"
trap 'rm -f "$SUMMARY"' EXIT
# View bodies and the test runner are in the same binary. They are not
# what this gate is for: ignore them, and count only Core.
xcrun llvm-cov export -summary-only \
    -ignore-filename-regex='Sources/FediqoUI/|Tests/|\.build/' \
    -instr-profile "$PROFILE" "${BINARIES[@]}" "$MEASURED" > "$SUMMARY"

python3 scripts/coverage_gate.py "$SUMMARY" "$THRESHOLD" "$MEASURED"
