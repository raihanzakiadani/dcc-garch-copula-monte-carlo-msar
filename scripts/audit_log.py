#!/usr/bin/env python3
"""Merge ingest/run/manifest/state info into audit/run.json and a Markdown step summary."""
import datetime as dt, json, os, sys
from pathlib import Path
from zoneinfo import ZoneInfo

work, dist, out = map(Path, sys.argv[1:4])
rd = lambda p: json.loads(p.read_text()) if p.exists() else {}
ing, run, man, st = rd(work / "ingest_result.json"), rd(work / "run_result.json"), rd(dist / "manifest.json"), rd(work / "state_info.json")
now = dt.datetime.now(dt.timezone.utc); e = os.environ
a = {
    "final_status": e.get("FINAL_STATUS"), "published": e.get("PUBLISHED") == "true", "dry_run": e.get("DRY_RUN") == "true",
    "started_utc": e.get("START_UTC"), "finished_utc": now.isoformat(timespec="seconds"),
    "finished_wib": now.astimezone(ZoneInfo("Asia/Jakarta")).isoformat(timespec="seconds"),
    "run_id": e.get("GITHUB_RUN_ID"), "commit_sha": e.get("GITHUB_SHA"), "mode_requested": e.get("PIPELINE_MODE"),
    "mode_executed": run.get("mode_executed"), "fallback_full": run.get("fallback_full"), "fallback_reason": run.get("fallback_reason"),
    "raw_max_date": run.get("raw_max_date"), "new_observations": ing.get("n_new_obs"),
    "instruments_ok": ing.get("n_instruments_ok"), "instruments_failed": ing.get("n_instruments_failed"),
    "ingest_status": ing.get("status"), "ingest_reason": ing.get("reason"), "blocked_dates": ing.get("blocked_dates"),
    "revisions": ing.get("revisions"), "state_source": st, "stages": run.get("stages"), "validation": run.get("validation"),
    "warnings": (run.get("warnings") or []) + (ing.get("warnings") or []), "model_version": run.get("pipeline_version"),
    "version_id": man.get("version_id"), "artifact": man.get("bundle"), "run_reason": run.get("reason"), "full_skipped": e.get("FULL_SKIPPED") == "true",
    "failed_instruments": {k: v["detail"] for k, v in (ing.get("instruments") or {}).items() if str(v.get("status", "")).startswith("FAILED")},
    "definition_checks": {k: v["diag"] for k, v in (ing.get("instruments") or {}).items() if v.get("diag")},
}
out.parent.mkdir(parents=True, exist_ok=True); out.write_text(json.dumps(a, indent=2, default=str))
md = [f"## Pipeline {a['final_status']}  ({a['mode_requested']} -> {a['mode_executed']})",
      f"- published: **{a['published']}** (dry_run={a['dry_run']}) | version: `{a['version_id']}`",
      f"- raw data max date: **{a['raw_max_date']}** | new observations: {a['new_observations']} | ingest: {a['ingest_status']}",
      f"- instruments ok/failed: {a['instruments_ok']}/{a['instruments_failed']} | fallback FULL: {a['fallback_full']} {a['fallback_reason'] or ''}",
      f"- reason: {a['run_reason'] or a['ingest_reason'] or '-'}"]
if a["full_skipped"]:
    md += ["", "> **FULL was SKIPPED today** (no self-hosted FULL runner configured; GitHub-hosted jobs stop at 6 h). DAILY ran instead; the joint-distribution model was NOT re-estimated."]
if a["failed_instruments"]:
    md += ["", "### Failed instruments"] + [f"- `{k}`: {v}" for k, v in a["failed_instruments"].items()]
if a["definition_checks"]:
    md += ["", "### Definition checks vs stored history (return correlation)"] + [f"- `{k}`: {v}" for k, v in a["definition_checks"].items()]
if a["warnings"]:
    md += ["", "### Warnings"] + [f"- {w}" for w in a["warnings"]]
s = "\n".join(md)
print(s)
if e.get("GITHUB_STEP_SUMMARY"):
    open(e["GITHUB_STEP_SUMMARY"], "a").write(s + "\n")
