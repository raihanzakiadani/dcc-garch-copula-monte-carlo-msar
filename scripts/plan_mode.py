#!/usr/bin/env python3
"""Decide mode, strategy and safety flags. Mode comes from the WIB weekday at RUN time (not from the cron string):
a delayed schedule still lands on the right Indonesian day (cron 11:00 UTC = 18:00 WIB; delays up to ~6h stay on the same WIB date).

strategy:
  daily     DAILY incremental, one hosted job
  sharded   FULL split into joint job + N shard jobs + merge job, all on GitHub-hosted runners (each job < 6 h)   [FULL_SHARDS >= 2]
  monolith  FULL in ONE job: on a self-hosted runner (FULL_RUNNER_LABEL, limit 5 days) or, if explicitly accepted, hosted (ALLOW_FULL_ON_HOSTED)
  skipped   Friday FULL not possible -> DAILY runs instead and the Summary says so
"""
import datetime as dt, json, os, sys
from zoneinfo import ZoneInfo

WIB = ZoneInfo("Asia/Jakarta")
MAX_SHARDS = 100          # GitHub matrix limit is 256 jobs; keep a wide safety margin


def plan(event, inputs, now, repo, expected_repo, ref, default_branch, full_weekday=5,
         full_runner="", allow_hosted_full=False, runner="ubuntu-24.04", full_shards=0):
    reasons, ok, full_skipped = [], True, False
    if not expected_repo:
        ok, _ = False, reasons.append("repository variable EXPECTED_REPOSITORY is not set (guard against wrong repo/fork)")
    elif repo != expected_repo:
        ok, _ = False, reasons.append(f"repo {repo} != EXPECTED_REPOSITORY {expected_repo}")
    wd = now.astimezone(WIB).isoweekday()
    if event == "schedule":
        mode, dry = ("FULL" if wd == full_weekday else "DAILY"), False
    else:
        mode = (inputs.get("mode") or "DAILY").upper()
        dry = str(inputs.get("dry_run", "true")).lower() != "false"
    if mode not in ("DAILY", "FULL"):
        ok, _ = False, reasons.append(f"invalid mode {mode}")
    if full_shards and not (2 <= full_shards <= MAX_SHARDS):
        ok, _ = False, reasons.append(f"FULL_SHARDS must be between 2 and {MAX_SHARDS} (got {full_shards})")
        full_shards = 0

    strategy, use_runner, timeout = "daily", runner, 350
    if mode == "FULL":
        if full_shards >= 2:
            strategy = "sharded"                                   # every job hosted => each limited to 6 h by GitHub
        elif full_runner:
            strategy, use_runner, timeout = "monolith", full_runner, 7000      # self-hosted: limit 5 days
        elif allow_hosted_full:
            strategy = "monolith"                                  # user accepted the 6 h risk
        elif event == "schedule":
            mode, strategy, full_skipped = "DAILY", "skipped", True
            reasons.append("FULL_SKIPPED: set FULL_SHARDS (>=2) to split FULL into short jobs, or FULL_RUNNER_LABEL for a self-hosted runner; ran DAILY instead.")
        else:
            ok, _ = False, reasons.append("FULL requested but none of FULL_SHARDS / FULL_RUNNER_LABEL / ALLOW_FULL_ON_HOSTED is set")
    if ref != default_branch and not dry:
        dry = True
        reasons.append(f"ref {ref} is not default branch {default_branch}: forced DRY RUN (nothing published)")
    # A DAILY job never silently starts a multi-hour FULL fallback (hosted jobs are cut at 6 h): it reports FULL REQUIRED instead.
    matrix = list(range(1, full_shards + 1)) if strategy == "sharded" else []
    return {"ok": ok, "mode": mode, "strategy": strategy, "dry_run": dry, "full_skipped": full_skipped, "runner": use_runner,
            "timeout": timeout, "shards": full_shards if strategy == "sharded" else 0, "matrix": matrix,
            "allow_daily_fallback": False, "wib_date": now.astimezone(WIB).date().isoformat(), "wib_weekday": wd, "notes": reasons}


def _flag(v):
    return str(v).lower() if isinstance(v, bool) else v


if __name__ == "__main__":
    e = os.environ
    inputs = json.loads(e.get("INPUTS_JSON", "{}") or "{}")
    try:
        shards = int(e.get("FULL_SHARDS", "").strip() or 0)
    except ValueError:
        shards = -1
    r = plan(e["GITHUB_EVENT_NAME"], inputs, dt.datetime.now(dt.timezone.utc), e["GITHUB_REPOSITORY"], e.get("EXPECTED_REPOSITORY", ""),
             e.get("GITHUB_REF_NAME", ""), e.get("DEFAULT_BRANCH", "main"),
             full_runner=e.get("FULL_RUNNER_LABEL", "").strip(), allow_hosted_full=e.get("ALLOW_FULL_ON_HOSTED", "").lower() == "true",
             runner=e.get("RUNNER_LABEL", "").strip() or "ubuntu-24.04", full_shards=shards)
    print(json.dumps(r))
    with open(e.get("GITHUB_OUTPUT", os.devnull), "a") as fh:
        for k in ("ok", "mode", "strategy", "dry_run", "full_skipped", "runner", "timeout", "shards", "allow_daily_fallback"):
            fh.write(f"{k}={_flag(r[k])}\n")
        fh.write("matrix=" + json.dumps(r["matrix"]) + "\n")
        fh.write("notes=" + " | ".join(r["notes"]) + "\n")
    sys.exit(0 if r["ok"] else 1)
