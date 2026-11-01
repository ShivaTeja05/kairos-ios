#!/usr/bin/env bash
# Tests the iPhone agents' Gemini calls from this Mac with your real key, using the same Swift code as the app.
# The key is read from tempo-hub/agents/.env (save it there first: copy the key in AI Studio, then run
# tempo-hub/agents/set_gemini_key.sh). The key is never printed.
# Usage: tempo-ios/Tools/GeminiSmoke/run.sh [model]     (default gemini-3.5-flash-lite)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IOS="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$IOS/.." && pwd)"
CORE="$IOS/TempoApp/Agents/Core"
[ -d "$CORE" ] || CORE="$IOS/AgentsWIP/Core"
# The research team's grounded search (check 5): merged into the app, or still in its work folder.
GROUNDED="$IOS/TempoApp/Agents/Research/GroundedSearch.swift"
[ -f "$GROUNDED" ] || GROUNDED="$IOS/AgentsWIP6/Research/GroundedSearch.swift"
ENV_FILE="$ROOT/tempo-hub/agents/.env"
key=""
[ -f "$ENV_FILE" ] && key="$(grep -E '^GEMINI_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
if [ -z "$key" ]; then
  echo "No GEMINI_API_KEY in tempo-hub/agents/.env."
  echo "Copy the key in Google AI Studio, run tempo-hub/agents/set_gemini_key.sh, then run this again."
  exit 1
fi
OUT="${TMPDIR:-/tmp}/kairos-gemini-smoke"
mkdir -p "$OUT"
echo "Building the test from $CORE …"
rm -f "$OUT/smoke"
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
  "$CORE/JSONValue.swift" "$CORE/AgentKit.swift" "$CORE/ModelProvider.swift" "$IOS/TempoApp/KeyStore.swift" \
  "$GROUNDED" "$HERE/main.swift" -o "$OUT/smoke" 2> "$OUT/build.log"; then
  grep -E "error" "$OUT/build.log" | head -20
  echo "The test didn't build (see above)."
  exit 1
fi
GEMINI_API_KEY="$key" GEMINI_MODEL="${1:-gemini-3.5-flash-lite}" "$OUT/smoke"
