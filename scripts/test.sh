#!/bin/bash
# Runs the core tests. With Command Line Tools only, the Swift Testing macro plugin
# is not on the default plugin search path, so pass it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
