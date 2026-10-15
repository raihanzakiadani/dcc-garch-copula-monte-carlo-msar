#!/usr/bin/env bash
# Wait until the FlareSolverr container really answers (it needs a while to start Chrome). Never fails the job:
# if it stays unreachable we print the container state/logs and let the ingest report the real error.
URL="${FLARESOLVERR_URL:-http://localhost:8191/v1}"
BASE="${URL%/v1}/"
MAX="${FLARE_WAIT_SECONDS:-240}"
STEP=3
waited=0
while [ "$waited" -lt "$MAX" ]; do
  if curl -fsS --max-time 5 "$BASE" >/dev/null 2>&1; then
    echo "FlareSolverr ready after ${waited}s: $(curl -fsS --max-time 5 "$BASE" 2>/dev/null | head -c 120)"
    exit 0
  fi
  sleep "$STEP"; waited=$((waited + STEP))
done
echo "::warning::FlareSolverr not reachable after ${MAX}s ($BASE)"
if command -v docker >/dev/null 2>&1; then
  echo "--- docker ps -a"; docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -10
  for c in $(docker ps -aq --filter ancestor=ghcr.io/flaresolverr/flaresolverr 2>/dev/null | head -2); do
    echo "--- logs of container $c (last 40 lines)"; docker logs --tail 40 "$c" 2>&1
  done
fi
exit 0
