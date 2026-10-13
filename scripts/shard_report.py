#!/usr/bin/env python3
"""Markdown table of per-shard timings (for calibrating FULL_SHARDS). usage: shard_report.py work/_shards"""
import glob, json, os, sys
rows = [json.load(open(f)) for f in sorted(glob.glob(os.path.join(sys.argv[1], "shard_meta_*.json")))]
for r in rows:                                   # jsonlite auto_unbox turns a 1-element vector into a bare string
    r["failed"] = [r["failed"]] if isinstance(r.get("failed"), str) else list(r.get("failed") or [])
if not rows:
    sys.exit(0)
tot = sum(r["seconds"] for r in rows) / 3600
out = ["### Shard timings (calibrate FULL_SHARDS: every shard must stay well below 6 h incl. ~30 min setup)",
       "", "| shard | stocks | ok | minutes | failed stocks |", "|---|---|---|---|---|"]
for r in rows:
    out.append(f"| {r['index']}/{r['count']} | {r['n_stocks']} | {r['n_ok']} | {r['seconds']/60:.1f} | {', '.join(r['failed']) or '-'} |")
mx = max(r["seconds"] for r in rows) / 60
out += ["", f"slowest shard: **{mx:.1f} min**; total shard compute: **{tot:.1f} h** (this is also the number of hosted runner-hours billed for shards)"]
s = "\n".join(out); print(s)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(s + "\n")
