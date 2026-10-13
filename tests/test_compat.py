"""Real data: ingest into a copy of seed/raw_data.xlsx, then let R read it like the pipeline does (readxl + pipeline functions)."""
import os, shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "tests"))
import test_ingest as T  # noqa: E402


def test_ingested_real_file_is_readable_by_the_r_pipeline(tmp_path):
    x = tmp_path / "ingested.xlsx"; shutil.copy2(T.SEED, x)
    st = T.read_state(x); last, by = st["last_date"], st["by_date"]
    reg = T.make_registry(by, last, [T.D1, T.D2]); idx = T.FakeIdx(T.idx_days(last, by, [T.D1, T.D2]), drop=["BBCA"])      # BBCA absent from IDX -> must become text "NA"
    r = T.run_ingest(str(x), T.CFG, {}, lambda: idx, {"http": None, "phei_store": None}, reg, T.at(2026, 10, 13))
    assert r.status == T.SUCCESS
    p = subprocess.run(["Rscript", str(ROOT / "tests/R/test_compat_real_data.R")], capture_output=True, text=True, cwd=ROOT,
                       env={**os.environ, "REPO_ROOT": str(ROOT), "INGESTED_XLSX": str(x), "EXPECT_NA_EXTRA": "BBCA IJ EQUITY"})
    assert p.returncode == 0 and "FAIL" not in p.stdout and p.stdout.count("PASS") == 8, p.stdout + p.stderr
