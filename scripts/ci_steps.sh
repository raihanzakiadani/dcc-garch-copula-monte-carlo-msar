#!/usr/bin/env bash
# usage: scripts/ci_steps.sh prepare <MODE> <DRY> | model <MODE> | publish <DRY>
# Shared by the single-job path (scripts/ci_run.sh) and the sharded FULL path (prepare job / merge job).
# Fail-closed: production (= the published release) changes ONLY in `publish`, after a fully validated run.
set -uo pipefail
STEP="${1:?step}"; shift
REPO="${GITHUB_REPOSITORY:?}"; W=work; D=dist
mkdir -p "$W" audit
export TZ=Asia/Jakarta REPO_ROOT="$PWD"
status_of() { python -c "import json,sys;print(json.load(open('$W/run_result.json')).get('status','FAILED'))" 2>/dev/null || echo FAILED; }

case "$STEP" in
prepare)
  MODE="${1:?mode}"; DRY="${2:-true}"
  export START_UTC="${START_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" PIPELINE_MODE="$MODE"
  echo "::group::fetch last valid state"
  python scripts/release.py fetch --work "$W" --repo "$REPO" --seed seed/raw_data.xlsx || { echo "::error::cannot restore state"; exit 1; }
  echo "::endgroup::"
  echo "::group::PHEI capture (single-day source; captured first so it is never lost)"
  python -m ingest.capture_phei --store "$W/phei_history.csv" --out "$W/phei_capture.json" || echo "::warning::PHEI capture failed (see log)"
  if [ -f "$W/phei_history.csv" ] && [ "$DRY" != "true" ]; then python scripts/release.py phei-push --store "$W/phei_history.csv" --repo "$REPO" || echo "::warning::could not push PHEI history"; fi
  echo "::endgroup::"
  echo "::group::ingest"
  python -m ingest.run_ingest --xlsx "$W/raw_data.xlsx" --out "$W/ingest_result.json" --phei-store "$W/phei_history.csv"
  ING_RC=$?
  echo "::endgroup::"
  if [ "${STOP_ON_INGEST_FAILED:-false}" = "true" ] && [ "$ING_RC" -ne 0 ]; then
    echo "::error::ingest FAILED - stopping before any model work (production unchanged)"
    FINAL_STATUS=FAILED PUBLISHED=false DRY_RUN="$DRY" PIPELINE_MODE="$MODE" python scripts/audit_log.py "$W" "$D" audit/run.json
    exit 1
  fi
  exit 0 ;;
model)
  MODE="${1:?mode}"; export PIPELINE_MODE="$MODE"
  echo "::group::model ($MODE) stage=${PIPELINE_STAGE:-all}"
  Rscript R/run_pipeline.R --mode "$MODE" --work "$W" --ingest "$W/ingest_result.json" --out "$W/run_result.json"
  echo "::endgroup::"
  exit 0 ;;
publish)
  DRY="${1:-true}"; STATUS="$(status_of)"; PUBLISHED=false; PUBLISH_RC=0
  export PIPELINE_MODE="${PIPELINE_MODE:-}"
  if [ "$STATUS" = "SUCCESS" ] || [ "$STATUS" = "PARTIAL_SUCCESS" ]; then
    echo "::group::bundle + publish (dry_run=$DRY)"
    Rscript R/bundle.R --work "$W" --run "$W/run_result.json" --ingest "$W/ingest_result.json" --out "$D" --prev-manifest "$W/state_manifest.json" || STATUS=FAILED
    if [ "$STATUS" != "FAILED" ]; then
      if [ "$DRY" = "true" ]; then python scripts/release.py publish --dist "$D" --repo "$REPO" --dry-run
      else python scripts/release.py publish --dist "$D" --repo "$REPO" --keep 14 && PUBLISHED=true || { PUBLISH_RC=$?; STATUS=FAILED; }; fi
    fi
    echo "::endgroup::"
  fi
  export FINAL_STATUS="$STATUS" PUBLISHED DRY_RUN="$DRY" PUBLISH_RC
  python scripts/audit_log.py "$W" "$D" audit/run.json
  [ "${FULL_SKIPPED:-false}" = "true" ] && echo "::warning::Friday FULL was SKIPPED (see docs/RUNTIME.md)"
  [ "$STATUS" = "PARTIAL_SUCCESS" ] && echo "::warning::PARTIAL_SUCCESS - published, but see the summary for failed instruments / warnings"
  [ "$STATUS" = "FAILED" ] && { echo "::error::pipeline FAILED - production data left unchanged"; exit 1; }
  exit 0 ;;
*) echo "unknown step $STEP"; exit 2 ;;
esac
