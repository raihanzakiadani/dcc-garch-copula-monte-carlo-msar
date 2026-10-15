import datetime as dt, sys
from pathlib import Path
import pytest
from openpyxl import Workbook
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from check_seed import check  # noqa: E402
from ingest.common import load_config  # noqa: E402

CFG = load_config()
COLS = list(CFG["instruments"]) + ["AAAA IJ EQUITY", "BBBB IJ EQUITY"]
TODAY = dt.date(2026, 10, 14)


def make(tmp_path, mutate=None, header=None, n=12):
    wb = Workbook(); ws = wb.active
    hdr = header or ["Dates"] + COLS
    ws.append(hdr)
    d = dt.date(2026, 9, 28); rows = []
    while len(rows) < n:
        if d.weekday() < 5: rows.append(d)
        d += dt.timedelta(days=1)
    data = [[dt.datetime(x.year, x.month, x.day)] + [100.0 + i + k for k in range(len(hdr) - 1)] for i, x in enumerate(rows)]
    if mutate: data = mutate(data)
    for r in data: ws.append(r)
    p = tmp_path / "raw.xlsx"; wb.save(p); return p


def errs(p): return check(p, CFG, TODAY)[0]


def test_clean_file_has_no_errors_and_reports_how_far_behind_it_is(tmp_path):
    e, w, info = check(make(tmp_path), CFG, TODAY)
    assert e == [] and info["rows"] == 12 and info["last_date"] == "2026-10-13"
    assert info["weekdays_behind_today"] == 1 and any("will be filled" in x for x in w)


def test_NA_text_is_fine_but_empty_cells_are_errors(tmp_path):
    def na(data): data[3][-1] = "NA"; return data
    assert errs(make(tmp_path, na)) == []
    def empty(data): data[3][-1] = None; return data
    assert any("empty cell" in x for x in errs(make(tmp_path, empty)))


def test_garbage_text_is_an_error(tmp_path):
    def bad(data): data[2][2] = "abc"; return data
    assert any("'abc'" in x for x in errs(make(tmp_path, bad)))


def test_date_problems(tmp_path):
    def dup(data): data[5][0] = data[4][0]; return data
    assert any("duplicate date" in x for x in errs(make(tmp_path, dup)))
    def back(data): data[5], data[6] = data[6], data[5]; return data
    assert any("backwards" in x for x in errs(make(tmp_path, back)))
    def hole(data): del data[4]; return data
    assert any("weekday(s) missing" in x for x in errs(make(tmp_path, hole)))
    def weekend(data): data[3][0] = dt.datetime(2026, 10, 3); return data
    assert any("weekend" in x for x in errs(make(tmp_path, weekend)))


def test_header_problems(tmp_path):
    assert any("required by config" in x for x in errs(make(tmp_path, header=["Dates"] + COLS[1:])))
    assert any("no source rule" in x for x in errs(make(tmp_path, header=["Dates"] + COLS + ["MYSTERY Index"])))
    assert any("duplicate column" in x for x in errs(make(tmp_path, header=["Dates"] + COLS + [COLS[0]])))
    assert any("first header" in x for x in errs(make(tmp_path, header=["Tanggal"] + COLS)))
    assert any("stray spaces" in x for x in errs(make(tmp_path, header=["Dates"] + [COLS[0] + " "] + COLS[1:])))


def test_warnings_for_jump_and_NA_in_required_last_row(tmp_path):
    def jump(data): data[6][3] = 100000.0; data[-1][1] = "NA"; return data
    e, w, _ = check(make(tmp_path, jump), CFG, TODAY)
    assert e == [] and any("daily jumps" in x for x in w) and any("NA on the last row" in x for x in w)


def test_real_seed_passes():
    e, w, info = check(ROOT / "seed" / "raw_data.xlsx", CFG, TODAY)
    assert e == [] and info["rows"] >= 3590 and info["NA_cells"] > 30000


def test_warns_when_phei_seed_lacks_the_last_data_date(tmp_path):
    p = make(tmp_path)                                                               # last date 2026-10-13, no phei_history.csv next to it
    e, w, _ = check(p, CFG, TODAY)
    assert e == [] and any("no PHEI value for the last data date 2026-10-13" in x for x in w)
    (tmp_path / "phei_history.csv").write_text("date,value,kind\n2026-10-13,114.3665,last\n")
    e, w, _ = check(p, CFG, TODAY)
    assert not any("no PHEI value" in x for x in w)


def test_repo_phei_seed_covers_the_live_observation():
    from ingest.phei_store import load
    h = load(ROOT / "seed" / "phei_history.csv")
    assert h[dt.date(2026, 10, 13)][0] == 114.3665 and h[dt.date(2026, 10, 12)][0] == 114.4903 and h[dt.date(2026, 10, 9)][0] == 114.5095
