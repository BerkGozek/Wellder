#!/usr/bin/env bash
# Starts the local backend (in-memory, recording-only notifications) and runs the iOS unit + UI
# tests in the simulator. Usage: scripts/run-ui-tests.sh ["iPhone 17"]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-iPhone 17}"
PORT="${AB_UITEST_PORT:-8787}"
PROJECT=Wellder.xcodeproj
if ! xcrun simctl list runtimes | grep -q watchOS; then
  echo "watchOS runtime not installed — testing the iOS app without the embedded watch app."
  ./scripts/nowatch-project.sh
  PROJECT=WellderNoWatch.xcodeproj
fi
if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "Something is already serving on port $PORT (a leftover backend?). Stop it or set AB_UITEST_PORT." >&2
  exit 1
fi
# exec: $! must be the node process itself, or the EXIT trap kills only the subshell and the
# server outlives the run (a stale server once served old code to later test runs).
(cd backend && PORT=$PORT STORE=memory SWEEP_INTERVAL_SECONDS=5 exec node src/local/server.ts) > /tmp/wellder-uitest-backend.log 2>&1 &
BACKEND=$!
trap 'kill $BACKEND 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.2; done
# TEST_RUNNER_-prefixed variables are forwarded to the test process.
TEST_RUNNER_AB_UITEST_API="http://127.0.0.1:$PORT" xcodebuild test -project "$PROJECT" -scheme Wellder \
  -destination "platform=iOS Simulator,name=$DEVICE" CODE_SIGNING_ALLOWED=NO "${@:2}"
