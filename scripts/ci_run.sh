#!/usr/bin/env bash
# usage: scripts/ci_run.sh <DAILY|FULL> <true|false:dry_run>      (single-job path: DAILY, or FULL on a self-hosted runner)
set -uo pipefail
MODE="${1:?mode}"; DRY="${2:-true}"
export START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)" PIPELINE_MODE="$MODE"
scripts/ci_steps.sh prepare "$MODE" "$DRY" || exit 1
scripts/ci_steps.sh model "$MODE"
scripts/ci_steps.sh publish "$DRY"
