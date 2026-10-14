#!/bin/sh
# Regenerate the corpus with the upstream harness, run the BEAM runner over
# it, and diff against the Python referee (black-box oracle, as the harness
# itself uses it).
#
#   scripts/conformance.sh <path-to-git.pp-ng-clone>
set -eu
SPEC=${1:?usage: conformance.sh <git.pp-ng clone>}
cd "$(dirname "$0")/.."

python3 "$SPEC/conformance/harness.py" >/dev/null   # writes cases.json
mix run conformance/runner.exs -- "$SPEC/conformance/cases.json" results.ex.json
python3 conformance/differ.py "$SPEC" "$SPEC/conformance/cases.json" results.ex.json
