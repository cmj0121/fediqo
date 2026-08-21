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

swift test --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
BINARY="$BIN_PATH/FediqoPackageTests.xctest/Contents/MacOS/FediqoPackageTests"
PROFILE="$BIN_PATH/codecov/default.profdata"

[ -x "$BINARY" ]  || { echo "no test binary at $BINARY"; exit 1; }
[ -f "$PROFILE" ] || { echo "no coverage profile at $PROFILE"; exit 1; }

SUMMARY="$(mktemp -t fediqo-coverage)"
trap 'rm -f "$SUMMARY"' EXIT
xcrun llvm-cov export -summary-only -instr-profile "$PROFILE" "$BINARY" "$MEASURED" > "$SUMMARY"

python3 scripts/coverage_gate.py "$SUMMARY" "$THRESHOLD" "$MEASURED"
