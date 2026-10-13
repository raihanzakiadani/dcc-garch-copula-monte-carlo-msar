"""Ingestion tests (no network). Local simulation of OUR logic with fake sources + parser tests on the REAL pages
the user saved on 2026-10-09 (tests/fixtures)."""
import datetime as dt
import hashlib
import shutil
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ingest.common import FAILED, PARTIAL_SUCCESS, SUCCESS, UP_TO_DATE, WIB, ProviderError, load_config  # noqa: E402
from ingest.merge import read_state  # noqa: E402
from ingest.providers import web  # noqa: E402
from ingest import phei_store  # noqa: E402
from ingest.run_ingest import eligible_date, run_ingest  # noqa: E402

SEED = ROOT / "seed" / "raw_data.xlsx"
FIX = ROOT / "tests" / "fixtures"
CFG = load_config()
NONIDX = [c for c, s in CFG["instruments"].items() if s["provider"] not in ("idx_index",)]
md5 = lambda p: hashlib.md5(Path(p).read_bytes()).hexdigest()
D1, D2 = dt.date(2026, 10, 9), dt.date(2026, 10, 12)


def at(y, m, d, hh=18, mm=30):
    return dt.datetime(y, m, d, hh, mm, tzinfo=WIB)


class FakeIdx:
    def __init__(self, days, fail=False, drop=(), zero=()):
        self.days, self.fail, self.drop, self.zero = days, fail, set(drop), set(zero)

    def get_json(self, path, params):
        if self.fail:
            raise ProviderError("simulated 403")
        d = dt.datetime.strptime(params["date"], "%Y%m%d").date()
        day = self.days.get(d)
        if day is None:
            return {"data": []}
        if "IndexSummary" in path:
            return {"data": [{"IndexCode": "COMPOSITE", "Close": day["JCI Index"]}]}
        return {"data": [{"StockCode": c.split()[0], "Close": v, "Volume": 0 if c.split()[0] in self.zero else 1000} for c, v in day.items()
                         if c.endswith("IJ EQUITY") and c.split()[0] not in self.drop]}


@pytest.fixture(scope="module")
def base(tmp_path_factory):
    x = tmp_path_factory.mktemp("w") / "raw_data.xlsx"
    shutil.copy2(SEED, x)
    st = read_state(x)
    return x, st["last_date"], st["by_date"]


@pytest.fixture()
def world(base, tmp_path):
    x0, last, by = base
    x = tmp_path / "raw_data.xlsx"
    shutil.copy2(x0, x)
    return x, last, by


def idx_days(last, by, dates, bump=1.001):
    days, cur = {last: dict(by[last])}, {k: v for k, v in by[last].items() if v is not None}
    for d in dates:
        cur = {k: v * bump for k, v in cur.items()}
        days[d] = dict(cur)
    return days


def make_registry(by, last, dates, scale=1.037, bump=1.002, end=None, broken=(), end_providers=("stooq",)):
    """Source series for non-IDX instruments: SAME returns as stored history but a different level scale
    (like PHEI 114.5 vs 118.6) -> chain-linking must keep the stored level continuous."""
    reg = {}
    for c in NONIDX:
        hist = pd.Series({d: r[c] for d, r in by.items() if r.get(c) is not None and d >= last - dt.timedelta(days=80)}).sort_index()
        if CFG["instruments"][c]["provider"] == "phei":
            hist = hist.iloc[-2:]
        s = hist * scale
        cur = float(hist.iloc[-1])
        for d in dates:
            cur *= bump
            s.loc[d] = cur * scale
        if end is not None and CFG["instruments"][c]["provider"] in end_providers:
            s = s[[d <= end for d in s.index]]

        def fn(col, spec, ctx, s=s, c=c):
            if c in broken:
                raise ProviderError("simulated outage")
            return s
        reg[CFG["instruments"][c]["provider"] + "::" + c] = fn
    # registry is keyed by provider name; dispatch by column through a wrapper
    def dispatch(provider):
        def fn(col, spec, ctx):
            return reg[provider + "::" + col](col, spec, ctx)
        return fn
    return {p: dispatch(p) for p in {s["provider"] for s in CFG["instruments"].values()} - {"idx_index"}}


def run(world, dates, now, reg=None, idx=None, **kw):
    x, last, by = world
    reg = reg or make_registry(by, last, dates, **kw)
    idx = idx or FakeIdx(idx_days(last, by, dates))
    return run_ingest(str(x), CFG, {}, lambda: idx, {"http": None, "phei_store": None}, reg, now)


# --------------------------------------------------------------------------- timing
def test_eligible_date_rules():
    assert eligible_date(at(2026, 10, 9), 17.5) == D1                      # IDX settled same evening
    assert eligible_date(at(2026, 10, 9), 32) == dt.date(2026, 10, 8)      # US/London-settled: not before next morning
    assert eligible_date(at(2026, 10, 12), 32) == D1                       # Monday evening finalises Friday


# --------------------------------------------------------------------------- core flow
def test_chain_link_keeps_levels_continuous_and_history_untouched(world):
    x, last, by = world
    n0 = read_state(x)["n_rows"]
    r = run(world, [D1], at(2026, 10, 12))
    assert r.status == SUCCESS, (r.status, r.reason, {k: v.detail for k, v in r.instruments.items() if v.status.startswith("FAILED")})
    assert r.new_dates == ["2026-10-09"] and r.row_limit == "2026-10-09"
    st = read_state(x)
    assert st["n_rows"] == n0 + 1
    new = st["by_date"][D1]
    # different vendor scale (x1.037) must NOT leak into levels: level_t = level_{t-1} * (1.002)
    assert new["XAU Curncy"] == pytest.approx(by[last]["XAU Curncy"] * 1.002, rel=1e-9)
    assert new["IBPRCPI Index"] == pytest.approx(by[last]["IBPRCPI Index"] * 1.002, rel=1e-9)
    # yields chain on DIFFERENCES (pipeline uses first difference for GTIDR)
    assert new["GTIDR1Y Govt"] - by[last]["GTIDR1Y Govt"] == pytest.approx(
        (by[last]["GTIDR1Y Govt"]) * 1.037 * 0.002, rel=1e-6)
    assert r.instruments["XAU Curncy"].diag["return_corr"] > 0.99


def test_idempotent_rerun(world):
    run(world, [D1], at(2026, 10, 12))
    snap = md5(world[0])
    r = run(world, [D1], at(2026, 10, 12))
    assert r.status == UP_TO_DATE and md5(world[0]) == snap


def test_not_finalised_before_sources_settle(world):
    r = run(world, [D1], at(2026, 10, 9))          # Friday 18:30 -> US/London series not settled for Friday
    assert r.status == UP_TO_DATE and r.row_limit == "2026-10-08"


def test_weekdays_all_get_rows_even_if_idx_holiday_carry_forward(world):
    x, last, by = world
    idx = FakeIdx({last: dict(by[last])})                                    # IDX empty on 10-09 => holiday
    r = run(world, [D1], at(2026, 10, 12), idx=idx)
    assert r.status == SUCCESS and r.instruments["JCI Index"].n_carried == 1
    assert read_state(x)["by_date"][D1]["JCI Index"] == by[last]["JCI Index"]   # history convention (JCI flat on holidays)


def test_two_days_incl_weekend_gap(world):
    r = run(world, [D1, D2], at(2026, 10, 13))
    assert r.status == SUCCESS and r.new_dates == ["2026-10-09", "2026-10-12"]


# --------------------------------------------------------------------------- failures
@pytest.mark.parametrize("broken", ["IBPRCPI Index", "XAU Curncy", "GTIDR1Y Govt"])
def test_required_source_down_is_FAILED_and_file_untouched(world, broken):
    before = md5(world[0])
    r = run(world, [D1], at(2026, 10, 12), broken=[broken])
    assert r.status == FAILED and md5(world[0]) == before
    assert r.instruments[broken].status == "FAILED"


def test_idx_down_is_FAILED(world):
    x, last, by = world
    r = run(world, [D1], at(2026, 10, 12), idx=FakeIdx({}, fail=True))
    assert r.status == FAILED


def test_diagnostic_rejects_wrong_series(world):
    x, last, by = world
    rng = np.random.default_rng(1)
    reg = make_registry(by, last, [D1])
    good = reg["stooq"]

    def noisy(col, spec, ctx):
        s = good(col, spec, ctx)
        return pd.Series(rng.normal(1000, 20, len(s)), index=s.index)     # unrelated random series
    reg["stooq"] = noisy
    r = run(world, [D1], at(2026, 10, 12), reg=reg)
    assert r.status == FAILED and r.instruments["XAU Curncy"].status == "FAILED_DIAG"


def test_stale_feed_is_not_carried_forever(world):
    x, last, by = world
    r = run(world, [D1, D2, dt.date(2026, 10, 13), dt.date(2026, 10, 14)], at(2026, 10, 16), end=last)
    assert r.status in (FAILED, PARTIAL_SUCCESS)
    assert r.instruments["XAU Curncy"].status == "FAILED_STALE"
    assert len(r.new_dates) <= CFG["dataset"]["tail_carry_days"]


def test_phei_missing_day_on_trading_day_is_failure_not_carry(world):
    x, last, by = world
    reg = make_registry(by, last, [D1])
    ph = reg["phei"]

    def only_old(col, spec, ctx):
        s = ph(col, spec, ctx)
        return s[[d <= last for d in s.index]]       # capture missed 10-09
    reg["phei"] = only_old
    r = run(world, [D1], at(2026, 10, 12), reg=reg)
    assert r.instruments["IBPRCPI Index"].status == "FAILED_MISSING" and r.status == FAILED


def test_optional_equity_absent_stays_blank(world):
    x, last, by = world
    idx = FakeIdx(idx_days(last, by, [D1]), drop=["BBCA"])
    r = run(world, [D1], at(2026, 10, 12), idx=idx)
    assert r.status == SUCCESS and read_state(x)["by_date"][D1]["BBCA IJ EQUITY"] is None


def test_idx_anchor_mismatch(world):
    x, last, by = world
    days = idx_days(last, by, [D1]); days[last] = dict(days[last]); days[last]["JCI Index"] *= 1.01
    r = run(world, [D1], at(2026, 10, 12), idx=FakeIdx(days))
    assert r.instruments["JCI Index"].status == "FAILED_ANCHOR" and r.status == FAILED


def test_revision_reported_not_overwritten(world):
    x, last, by = world
    days = idx_days(last, by, [D1]); prev = last - dt.timedelta(days=1)
    days[prev] = dict(by[prev]); days[prev]["JCI Index"] += 5
    r = run(world, [D1], at(2026, 10, 12), idx=FakeIdx(days))
    assert any(v["instrument"] == "JCI Index" and v["date"] == prev.isoformat() for v in r.revisions)
    assert read_state(x)["by_date"][prev]["JCI Index"] == by[prev]["JCI Index"] and r.status == PARTIAL_SUCCESS


# --------------------------------------------------------------------------- REAL saved pages
def test_real_pages_parse():
    xau = web.parse_stooq((FIX / "stooq_xauusd.html").read_text(encoding="utf-8"))
    assert len(xau) == 40 and xau.index.max() == dt.date(2026, 10, 8) and xau.iloc[-1] == pytest.approx(4133.63)
    lq = web.parse_stooq((FIX / "stooq_lqf.html").read_text(encoding="utf-8"))
    assert lq.iloc[-1] == pytest.approx(151.7)
    ni = web.parse_westmetall((FIX / "westmetall_ni.html").read_text(encoding="utf-8"))
    assert len(ni) == 195 and ni.iloc[-1] == pytest.approx(15415.0)
    ph = web.parse_phei((FIX / "phei_indobex.html").read_text(encoding="utf-8"))
    assert ph == {"date": dt.date(2026, 10, 9), "previous": 114.4633, "last": 114.5095, "row": "INDOBeX Government Clean Price"}
    with pytest.raises(ProviderError):
        web.parse_phei((FIX / "phei_indobex.html").read_text(encoding="utf-8"), "INDOBeX Government Total Return X")


def test_real_pages_pass_definition_check_against_stored_history(base):
    """Measured on the user's real data: the thresholds in config must accept the real sources."""
    x, last, by = base
    for col, fx, parser in (("XAU Curncy", "stooq_xauusd.html", web.parse_stooq), ("XW1 Comdty", "stooq_lqf.html", web.parse_stooq),
                            ("LMNIDS03 LME Comdty", "westmetall_ni.html", web.parse_westmetall)):
        s = parser((FIX / fx).read_text(encoding="utf-8"))
        st = pd.Series({d: r[col] for d, r in by.items() if r.get(col) is not None})
        j = pd.concat([st, s], axis=1, keys=["st", "src"], join="inner").dropna()
        rr = np.log(j).diff().dropna()
        assert rr.corr().iloc[0, 1] >= CFG["instruments"][col]["min_overlap_corr"], col


def test_phei_store_idempotent_and_revision(tmp_path):
    p = tmp_path / "phei.csv"
    parsed = web.parse_phei((FIX / "phei_indobex.html").read_text(encoding="utf-8"))
    a = phei_store.record(p, parsed); b = phei_store.record(p, parsed)
    assert len(a["added"]) == 2 and b["added"] == [] and b["revisions"] == []
    assert phei_store.as_series(p).loc[dt.date(2026, 10, 8)] == pytest.approx(114.4633)
    parsed2 = dict(parsed, last=115.0)
    assert phei_store.record(p, parsed2)["revisions"][0]["date"] == "2026-10-09"


def test_mpoc_real_page_parses_and_misconfigured_fails_loudly():
    k = CFG["instruments"]["KO1 Comdty"]
    s = web.parse_mpoc((FIX / "mpoc_cpo.html").read_text(encoding="utf-8"), k["table_header_contains"], k["value_header"], k["date_format"])
    assert len(s) == 10 and s.index.min() == dt.date(2026, 9, 25) and s.index.max() == dt.date(2026, 10, 8)
    assert s.loc[dt.date(2026, 10, 8)] == 4661.0 and s.loc[dt.date(2026, 10, 1)] == 4554.0      # '1 Oct 26' (no zero padding) handled
    with pytest.raises(ProviderError):
        web.parse_mpoc((FIX / "mpoc_cpo.html").read_text(encoding="utf-8"), "", "")
    with pytest.raises(ProviderError):
        web.parse_mpoc((FIX / "mpoc_cpo.html").read_text(encoding="utf-8"), "Pricing Date", "Nonexistent Column")


# --------------------------------------------------------------------------- Google-Sheet feed (Yahoo via Apps Script)
from ingest.providers.sheet_csv import fetch_sheet_csv  # noqa: E402

WANT = ["USDIDR BGN Curncy", "CO1 Comdty"]
GET = lambda txt: (lambda url: txt)


def test_sheet_csv_iso_datetime_and_blank_rows():
    txt = "Dates,USDIDR BGN Curncy,CO1 Comdty,junk\n2026-10-08,16500.5,77.1,x\n2026-10-09 16:00:00,16520.0,,y\n,,,\n"
    df = fetch_sheet_csv("https://x.invalid/secret", WANT, GET(txt))
    assert list(df.index) == [dt.date(2026, 10, 8), dt.date(2026, 10, 9)] and "junk" not in df.columns
    assert df.loc[dt.date(2026, 10, 9), "USDIDR BGN Curncy"] == 16520.0 and pd.isna(df.loc[dt.date(2026, 10, 9), "CO1 Comdty"])


def test_sheet_csv_never_guesses_locale():
    amb = "Dates,USDIDR BGN Curncy\n10/9/2026,16500\n"
    with pytest.raises(ProviderError, match="non-ISO"):
        fetch_sheet_csv("u", WANT, GET(amb))
    df = fetch_sheet_csv("u", WANT, GET(amb), date_format="%m/%d/%Y")             # explicit => allowed
    assert list(df.index) == [dt.date(2026, 10, 9)]
    with pytest.raises(ProviderError, match="decimal"):
        fetch_sheet_csv("u", WANT, GET("Dates,USDIDR BGN Curncy\n2026-10-09,\"16.500,5\"\n"))
    df = fetch_sheet_csv("u", WANT, GET("Dates,USDIDR BGN Curncy\n2026-10-09,\"16.500,5\"\n"), decimal=",")
    assert df.iloc[0, 0] == 16500.5


def test_sheet_csv_rejects_html_dupes_and_hides_url():
    with pytest.raises(ProviderError, match="HTML"):
        fetch_sheet_csv("u", WANT, GET("<!DOCTYPE html><html>sign in</html>"))
    with pytest.raises(ProviderError, match="duplicate"):
        fetch_sheet_csv("u", WANT, GET("Dates,CO1 Comdty\n2026-10-09,1\n2026-10-09,2\n"))
    with pytest.raises(ProviderError, match="secret") as ei:
        fetch_sheet_csv("", WANT, GET(""))

    def boom(u):
        raise OSError("down " + u)
    with pytest.raises(ProviderError) as ei:
        fetch_sheet_csv("https://x.invalid/SECRET123", WANT, boom)
    assert "SECRET123" not in str(ei.value)


def test_yahoo_instruments_now_come_from_sheet_feed():
    for col in ("USDIDR BGN Curncy", "CO1 Comdty"):
        k = CFG["instruments"][col]
        assert k["provider"] == "sheet_csv" and k["csv_url_env"] == "SRC_YAHOO_SHEET_CSV" and k["column"] == col


def test_apps_script_logic():
    import subprocess
    r = subprocess.run(["node", str(ROOT / "tests/js/test_yahoo_feed.js")], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_number_parsing_is_strict_about_locale():
    from ingest.providers.web import _num
    assert _num("4,133.63") == 4133.63 and _num("4133.63") == 4133.63 and _num("1,234") == 1234.0
    assert _num("16.500,5") is None and _num("16,5,0") is None          # never a silently wrong number
    assert _num("16.500,5", ",") == 16500.5 and _num("6,740", ",") == 6.74 and _num("1.234.567", ",") == 1234567.0
    assert _num("abc") is None and _num("") is None


def test_blank_suspended_stock_is_not_restarted_from_stale_price(world):
    x, last, by = world
    assert by[last]["WSKT IJ EQUITY"] is None                     # real data: WSKT blank since 17 Aug
    days = idx_days(last, by, [D1]); days[D1]["WSKT IJ EQUITY"] = 123.0
    r = run(world, [D1], at(2026, 10, 12), idx=FakeIdx(days, zero=["WSKT"]))
    assert r.status == SUCCESS and read_state(x)["by_date"][D1]["WSKT IJ EQUITY"] is None        # zero volume => stale => stays blank
    days2 = idx_days(last, by, [D1]); days2[D1]["WSKT IJ EQUITY"] = 123.0
    import shutil as sh; x2 = world[0].parent / "again.xlsx"; sh.copy2(T_SEED_COPY := SEED, x2)
    r2 = run_ingest(str(x2), CFG, {}, lambda: FakeIdx(days2), {"http": None, "phei_store": None}, make_registry(by, last, [D1]), at(2026, 10, 12))
    assert read_state(x2)["by_date"][D1]["WSKT IJ EQUITY"] == 123.0                               # traded (volume>0) => genuine resumption


def test_every_header_column_has_a_source_rule_and_names_match_exactly():
    st = read_state(SEED)
    cols = st["header"][1:]
    from ingest.merge import is_equity
    unmapped = [c for c in cols if c not in CFG["instruments"] and not is_equity(c, CFG["dataset"]["stock_pattern"])]
    assert unmapped == [] and [k for k in CFG["instruments"] if k not in cols] == []
    assert len(cols) == 80 and sum(is_equity(c, CFG["dataset"]["stock_pattern"]) for c in cols) == 71


def test_missing_values_are_written_as_literal_NA_like_the_history(world):
    from openpyxl import load_workbook
    x, last, by = world
    days = idx_days(last, by, [D1]); days[D1].pop("BBCA IJ EQUITY", None)
    r = run(world, [D1], at(2026, 10, 12), idx=FakeIdx(days, drop=["BBCA"]))
    assert r.status == SUCCESS
    ws = load_workbook(x, read_only=True).worksheets[0]
    rows = list(ws.iter_rows(values_only=True)); hdr = list(rows[0]); new = dict(zip(hdr, rows[-1])); prev = dict(zip(hdr, rows[-2]))
    assert new["BBCA IJ EQUITY"] == "NA" and new["WSKT IJ EQUITY"] == "NA"          # absent / still-blank stock -> text "NA"
    assert isinstance(new["JCI Index"], float) and isinstance(new["XAU Curncy"], float)  # numbers stay numbers
    assert not any(v is None for v in rows[-1])                                       # no truly empty cell, same as history
    assert prev["WSKT IJ EQUITY"] == "NA"                                              # history cell untouched
    assert read_state(x)["by_date"][D1]["BBCA IJ EQUITY"] is None                      # and our reader still sees it as missing


def test_real_phei_seed_chains_from_last_stored_day_and_gap_is_detected(world, tmp_path):
    """seed/phei_history.csv = the two REAL PHEI values from the user's saved page (8 & 9 Oct 2026)."""
    from ingest.fetchers import REGISTRY
    x, last, by = world
    store = ROOT / "seed" / "phei_history.csv"
    reg = make_registry(by, last, [D1])
    reg["phei"] = REGISTRY["phei"]                                                    # REAL provider reading the seed store
    idx = FakeIdx(idx_days(last, by, [D1]))
    r = run_ingest(str(x), CFG, {}, lambda: idx, {"http": None, "phei_store": str(store)}, reg, at(2026, 10, 12))
    assert r.status == SUCCESS, (r.reason, r.instruments["IBPRCPI Index"].detail)
    expect = by[last]["IBPRCPI Index"] * 114.5095 / 114.4633
    assert read_state(x)["by_date"][D1]["IBPRCPI Index"] == pytest.approx(expect, rel=1e-9)
    # a day later with no PHEI capture in between => explicit failure, never a carried/guessed value
    x2 = tmp_path / "gap.xlsx"; shutil.copy2(world[0], x2)
    shutil.copy2(SEED, x2)
    days = idx_days(last, by, [D1, D2, dt.date(2026, 10, 13)])
    r2 = run_ingest(str(x2), CFG, {}, lambda: FakeIdx(days), {"http": None, "phei_store": str(store)},
                    {**make_registry(by, last, [D1, D2, dt.date(2026, 10, 13)]), "phei": REGISTRY["phei"]}, at(2026, 10, 14))
    assert r2.instruments["IBPRCPI Index"].status == "FAILED_MISSING" and r2.new_dates == ["2026-10-09"]


def test_release_fetch_seeds_phei_history(tmp_path):
    import subprocess, os
    env = {**os.environ, "GH_BIN": str(ROOT / "tests/fake_gh.py"), "FAKE_GH_DIR": str(tmp_path / "gh")}
    w = tmp_path / "w"
    r = subprocess.run([sys.executable, str(ROOT / "scripts/release.py"), "fetch", "--work", str(w), "--repo", "o/r", "--seed", str(SEED)], env=env, capture_output=True, text=True)
    assert r.returncode == 0 and (w / "phei_history.csv").read_text().count("\n") == 3


def test_ingest_summary_renders(tmp_path):
    import subprocess, json, os
    x = tmp_path / "raw_data.xlsx"; shutil.copy2(SEED, x)
    st = read_state(x); last, by = st["last_date"], st["by_date"]
    res = run_ingest(str(x), CFG, {}, lambda: FakeIdx(idx_days(last, by, [D1])), {"http": None, "phei_store": None}, make_registry(by, last, [D1]), at(2026, 10, 12))
    (tmp_path / "ingest_result.json").write_text(json.dumps(res.to_json(), default=str))
    out = subprocess.run([sys.executable, str(ROOT / "scripts/ingest_summary.py"), str(tmp_path)], capture_output=True, text=True).stdout
    assert "ingest status **SUCCESS**" in out and "Last rows of raw_data.xlsx" in out and "2026-10-09" in out and "| IBPRCPI Index |" in out
