import json, os, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]


def test_shard_meta_and_report_handle_one_failed_stock(tmp_path):
    r = subprocess.run(["Rscript", "-e", f'''
setwd("{ROOT}"); Sys.setenv(REPO_ROOT = getwd()); source("tests/R/helpers_synth.R")
H <- extract_functions("pipeline/15092026.R", c("pipeline_shard_stocks","pipeline_save_rds_atomic","pipeline_save_shard"), new.env(parent=globalenv()))
st <- sprintf("S%02d", 1:10); d <- "{tmp_path}"
for (i in 1:3) {{ ar <- setNames(vector("list",10), st); for (s in H$pipeline_shard_stocks(st,i,3)) ar[s] <- list(if (s=="S04") NULL else list(x=1)); H$pipeline_save_shard(d,i,3,st,ar,"m",600*i) }}
system2("Rscript", c("scripts/shard_meta.R", d))'''], capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, r.stderr
    out = subprocess.run([sys.executable, str(ROOT / "scripts/shard_report.py"), str(tmp_path)], capture_output=True, text=True).stdout
    assert "| 1/3 | 4 | 3 | 10.0 | S04 |" in out and "slowest shard: **30.0 min**" in out and "total shard compute: **1.0 h**" in out
