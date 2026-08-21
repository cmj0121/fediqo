"""Reads an llvm-cov summary and fails when line coverage is below the threshold."""

import json
import sys

summary_path, threshold, measured = sys.argv[1], float(sys.argv[2]), sys.argv[3]

with open(summary_path) as handle:
    totals = json.load(handle)["data"][0]["totals"]

print(f"coverage of {measured}")
for name in ("lines", "regions", "functions"):
    part = totals[name]
    print(f"    {name:<10} {part['percent']:6.2f}%   {part['covered']}/{part['count']}")

lines = totals["lines"]["percent"]
if lines + 1e-9 < threshold:
    print(f"\nFAIL: line coverage {lines:.2f}% is below the {threshold:.0f}% this project keeps")
    raise SystemExit(1)

print(f"\nOK: line coverage {lines:.2f}% is at or above {threshold:.0f}%")
