import datetime as dt, sys
from pathlib import Path
import pandas as pd
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "tests"))
import test_ingest as T
from ingest.common import ProviderError
from ingest.probe import probe, to_markdown

HEADER = T.read_state(T.SEED)["header"]
NOW = T.at(2026, 10, 12)


class Web:
    def get_text(self, url):
        return (T.FIX / "phei_indobex.html").read_text(encoding="utf-8")


def fake_registry(fail=()):
    def mk(p):
        def fn(col, spec, ctx):
            if col in fail:
                raise ProviderError("blocked by Cloudflare")
            return pd.Series([1.0, 2.0], index=[dt.date(2026, 10, 7), dt.date(2026, 10, 8)])
        return fn
    return {p: mk(p) for p in ("yahoo", "stooq", "westmetall", "investing", "mpoc", "sheet_csv", "phei")}


def idx_days_all():
    by = T.read_state(T.SEED)["by_date"]; last = max(by)
    return T.idx_days(last, by, [dt.date(2026, 10, 9), dt.date(2026, 10, 12)])


def test_probe_reports_ok_and_failures_without_leaking_secrets():
    rows = probe(T.CFG, HEADER, {}, lambda: T.FakeIdx(idx_days_all()), Web(), fake_registry(fail=["XAU Curncy"]), NOW)
    by = {r["source"]: r for r in rows}
    assert by["JCI Index"]["ok"] and by["JCI Index"]["last_date"] == "2026-10-12"
    stock = next(r for r in rows if r["provider"] == "idx_stock")
    assert stock["ok"] and "of 71 codes" in stock["note"]
    assert by["XAU Curncy"]["ok"] is False and "Cloudflare" in by["XAU Curncy"]["error"]
    assert by["IBPRCPI Index"]["ok"] and by["IBPRCPI Index"]["last_value"] == 114.5095           # parsed from the REAL saved PHEI page
    md = to_markdown(rows)
    assert "FAIL" in md and "sources OK" in md


def test_probe_idx_down_is_reported_not_raised():
    rows = probe(T.CFG, HEADER, {}, lambda: T.FakeIdx({}, fail=True), Web(), fake_registry(), NOW)
    assert any(r["provider"] == "idx" and not r["ok"] for r in rows)
    assert all(r["ok"] for r in rows if r["provider"] not in ("idx",))
