"""Prints an llvm-cov summary of Sources/FediqoUI, whole and file by file.

Its own printer rather than `coverage_gate.py`'s, because this one is not a gate: there is no
threshold to be below, and the per-file list is the point -- what a run of the app driving
tests reached and what it never went near is the whole of what anybody reads this for.
"""

import json
import sys

MEASURED = "Sources/FediqoUI/"

with open(sys.argv[1]) as handle:
    data = json.load(handle)["data"][0]

totals = data["totals"]
print("coverage of Sources/FediqoUI, from the app driven")
for name in ("lines", "regions", "functions"):
    part = totals[name]
    print(f"    {name:<10} {part['percent']:6.2f}%   {part['covered']}/{part['count']}")

print()
files = sorted(data["files"], key=lambda file: -file["summary"]["lines"]["percent"])
for file in files:
    lines = file["summary"]["lines"]
    print(f"    {file['filename'].split(MEASURED)[-1]:<42}{lines['percent']:6.2f}%   "
          f"{lines['covered']}/{lines['count']}")
