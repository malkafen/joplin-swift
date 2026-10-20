#!/bin/bash
# Runs the test suite with code coverage and prints a per-file report.
#   scripts/coverage.sh                 -> table on stdout
#   scripts/coverage.sh --lcov out.info -> also write an lcov file (for CI upload)
#   MIN_COVERAGE=90 scripts/coverage.sh -> fail when total line coverage is lower
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/test.sh --enable-code-coverage

BIN=$(swift build --show-bin-path)
PROFILE="$BIN/codecov/default.profdata"
# SwiftPM builds one bundle per test target (older versions: a single *PackageTests bundle).
OBJECTS=()
for bundle in "$BIN"/*.xctest; do
  [ ${#OBJECTS[@]} -eq 0 ] && OBJECTS+=("$bundle/Contents/MacOS/$(basename "$bundle" .xctest)") \
    || OBJECTS+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
# The stress harness only runs against a real window (scripts/stress).
IGNORE='(\.build|Tests)/|StressProbe\.swift'

xcrun llvm-cov report "${OBJECTS[@]}" -instr-profile "$PROFILE" -ignore-filename-regex "$IGNORE"

if [ "${1:-}" = "--lcov" ]; then
  xcrun llvm-cov export "${OBJECTS[@]}" -instr-profile "$PROFILE" -ignore-filename-regex "$IGNORE" -format=lcov > "$2"
fi

TOTAL=$(xcrun llvm-cov export "${OBJECTS[@]}" -instr-profile "$PROFILE" -ignore-filename-regex "$IGNORE" -summary-only \
  | python3 -c 'import json,sys; print("%.2f" % json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"])')
echo "Total line coverage: $TOTAL%"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Code coverage: $TOTAL%"
    echo '```'
    xcrun llvm-cov report "${OBJECTS[@]}" -instr-profile "$PROFILE" -ignore-filename-regex "$IGNORE"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "${MIN_COVERAGE:-}" ]; then
  python3 -c "import sys; sys.exit(0 if $TOTAL >= $MIN_COVERAGE else 1)" \
    || { echo "Coverage $TOTAL% is below the required $MIN_COVERAGE%"; exit 1; }
fi
