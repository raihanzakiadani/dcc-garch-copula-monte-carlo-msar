"""CLI: python -m ingest.run_ingest --xlsx work/raw_data.xlsx --out work/ingest_result.json --phei-store work/phei_history.csv

Design (all derived from the audit of raw_data.xlsx):
  * Row calendar = EVERY weekday (history has 0 missing weekdays; IDX holidays appear as flat carried values).
  * A date is only finalised once ALL sources have settled for it (per-instrument final_lag_hours_wib).
  * Different vendors => levels differ. Non-IDX series are CHAIN-LINKED on their own returns/differences
    (level_t = level_{t-1} x src_t/src_{t-1}, or + (src_t - src_{t-1})) so the splice creates no artificial jump.
  * Closed market (no print) => carry last level (history convention), bounded by max_carry_days; a dead feed
    is FAILED_STALE, never silently carried forever.  Unreachable source => FAILED, never carried.
  * FAILED => dataset byte-identical to before. Exit 1 only for FAILED.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd

from .common import (FAILED, PARTIAL_SUCCESS, SUCCESS, UP_TO_DATE, WIB, IngestResult, InstrumentResult,
                     ProviderError, fmt_both, load_config, log, now_utc)
from .fetchers import REGISTRY
from .merge import append_rows, is_equity, read_state, rel_diff, weekdays_between
from .providers.idx import fetch_idx


def eligible_date(now: dt.datetime, lag_hours: float) -> dt.date:
    """Latest weekday d such that now >= 00:00 WIB(d) + lag_hours."""
    n = now.astimezone(WIB)
    d = n.date()
    while True:
        start = dt.datetime(d.year, d.month, d.day, tzinfo=WIB)
        if d.weekday() < 5 and n >= start + dt.timedelta(hours=lag_hours):
            return d
        d -= dt.timedelta(days=1)


def _tf(vals: pd.Series, kind: str) -> pd.Series:
    return np.log(vals).diff() if kind == "log" else vals.diff()


def run_ingest(xlsx: str, cfg: dict, env: dict | None = None, idx_http_factory=None, ctx_extra: dict | None = None,
               registry: dict | None = None, now: dt.datetime | None = None) -> IngestResult:
    import os
    env = os.environ if env is None else env
    registry = registry or REGISTRY
    ds = cfg["dataset"]
    now = now or now_utc()
    res = IngestResult(started=fmt_both(now))
    st = read_state(xlsx, ds["dedupe_policy"])
    header, by_date, last = st["header"], st["by_date"], st["last_date"]
    res.last_date_before = last.isoformat()
    cols = header[1:]
    cfg_inst = cfg["instruments"]
    eq_cols = [c for c in cols if c not in cfg_inst and is_equity(c, ds["stock_pattern"])]

    def spec_of(c):
        return cfg_inst.get(c) or cfg["equity_default"]

    for c in cols:
        sp = spec_of(c)
        res.instruments[c] = InstrumentResult(c, bool(sp["required"]), sp["provider"])
        if c not in cfg_inst and c not in eq_cols:
            res.instruments[c].required = True
            res.instruments[c].status, res.instruments[c].detail = "FAILED", "no source rule in config/pipeline.json"

    # ---------- row limit: newest weekday that every REQUIRED source has settled ----------
    req_lags = [spec_of(c)["final_lag_hours_wib"] for c in cols if res.instruments[c].required]
    row_limit = min(eligible_date(now, lag) for lag in req_lags)
    if (row_limit - last).days > ds["max_catchup_days"]:
        row_limit = last + dt.timedelta(days=ds["max_catchup_days"])
    res.row_limit = row_limit.isoformat()
    window_start = last - dt.timedelta(days=ds["revision_lookback_days"] + 30)

    # ---------- fetch ----------
    series: dict = {c: pd.Series(dtype=float) for c in cols}
    trading: set | None = None
    zero_vol: dict = {}
    idx_cols = {c: cfg_inst[c]["idx_index_code"] for c in cols if cfg_inst.get(c, {}).get("provider") == "idx_index"}
    if idx_cols or eq_cols:
        try:
            http = (idx_http_factory or __import__("ingest.providers.idx", fromlist=["IdxHttp"]).IdxHttp)()
            days = list(weekdays_between(last - dt.timedelta(days=ds["revision_lookback_days"]), row_limit))
            vals, trading, zero_vol = fetch_idx(days, eq_cols, idx_cols, http)
            tmp: dict = {c: {} for c in list(idx_cols) + eq_cols}
            for d, day in vals.items():
                for c, v in day.items():
                    tmp[c][d] = v
            for c, dct in tmp.items():
                series[c] = pd.Series(dct, dtype=float).sort_index()
            nz = sum(len(v) for v in zero_vol.values())
            if nz:
                log("INFO", "equity closes with zero volume kept as-is (historical convention)", n=nz)
        except ProviderError as e:
            for c in list(idx_cols) + eq_cols:
                res.instruments[c].status, res.instruments[c].detail = "FAILED", f"IDX provider: {e}"
            log("ERROR", "IDX provider failed", err=str(e))
    ctx = {"env": env, "http": None, "phei_store": None, "now": now}
    ctx.update(ctx_extra or {})
    for c in cols:
        sp = spec_of(c)
        if sp["provider"] in ("idx_index", "idx_stock") or res.instruments[c].status.startswith("FAILED"):
            continue
        fn = registry.get(sp["provider"])
        try:
            if fn is None:
                raise ProviderError(f"unknown provider '{sp['provider']}'")
            series[c] = fn(c, sp, ctx)
        except ProviderError as e:
            res.instruments[c].status, res.instruments[c].detail = "FAILED", f"{sp['provider']}: {e}"
            log("ERROR", "provider failed", col=c, provider=sp["provider"], err=str(e))
        except Exception as e:  # noqa: BLE001  (never leak URLs/secrets)
            res.instruments[c].status, res.instruments[c].detail = "FAILED", f"{sp['provider']}: {type(e).__name__}"
            log("ERROR", "provider crashed", col=c, err=type(e).__name__)

    # ---------- consistency checks vs stored history ----------
    stored_ser = {c: pd.Series({d: r[c] for d, r in by_date.items() if r.get(c) is not None}).sort_index() for c in cols}
    prev_level, src_last = {}, {}
    for c in cols:
        r, sp = res.instruments[c], spec_of(c)
        if r.status.startswith("FAILED"):
            continue
        s, stored = series[c], stored_ser[c]
        prev_level[c] = stored.iloc[-1] if len(stored) else None
        if s.empty:
            r.status, r.detail = ("FAILED_MISSING", "source returned no values") if r.required else ("NO_DATA", "no values (unlisted/delisted?)")
            continue
        if sp["splice"] == "level_exact":
            fa, sa = s.get(last), by_date[last].get(c)
            if fa is not None and sa is not None and rel_diff(fa, sa) > ds["anchor_rel_tolerance"]:
                r.status, r.detail = "FAILED_ANCHOR", f"source {last}={fa} vs stored {sa}: definition mismatch or revision"
            src_last[c] = fa
            continue
        before = s[[d <= last for d in s.index]]
        if before.empty:
            r.status, r.detail = "FAILED_MISSING", f"source has no print on/before last stored date {last}"
            continue
        src_last[c] = float(before.iloc[-1])
        b_date = before.index[-1]
        if b_date != last:
            # The chain base must describe the SAME state as the last stored row. If the newest source print is older than the last
            # stored day and the stored level moved in between, chaining from it would count that move twice.
            sv_b, sv_l = stored.get(b_date), stored.get(last)
            if sv_b is None or sv_l is None or abs(sv_b - sv_l) > 1e-9 * max(1.0, abs(sv_l)):
                r.status = "FAILED_MISSING"
                r.detail = (f"newest source print on/before {last} is {b_date}, and the stored level changed since then: "
                            f"chaining would double count that move (need a source print for {last})")
                continue
        # overlap diagnostics on the transformed (return/diff) series
        win = [d for d in stored.index if d <= last and (last - d).days <= ds["overlap_window_weekdays"] * 7 // 5]
        j = pd.concat([stored.loc[win], s], axis=1, keys=["st", "src"], join="inner", sort=True).dropna()
        j = j[j.index <= last]
        diag = {"n_overlap": int(len(j))}
        if len(j) >= ds["overlap_min_n"]:
            rr = pd.concat([_tf(j["st"], sp["transform"]), _tf(j["src"], sp["transform"])], axis=1).dropna()
            corr = float(rr.corr().iloc[0, 1]) if len(rr) > 3 else float("nan")
            diag.update({"return_corr": round(corr, 3), "mean_abs_diff": round(float((rr.iloc[:, 0] - rr.iloc[:, 1]).abs().mean()), 5),
                         "level_ratio_mean": round(float((j["st"] / j["src"]).mean()), 4)})
            mc = sp.get("min_overlap_corr")
            if mc is not None and not (corr >= mc):
                r.status, r.detail = "FAILED_DIAG", f"return corr vs stored history {corr:.3f} < {mc}: not the same series (or feed broke)"
        else:
            diag["note"] = "overlap too short to verify definition (unverified; monitor corr in later runs)"
            res.warnings.append(f"{c}: definition UNVERIFIED (overlap n={len(j)})")
        r.diag = diag

    # ---------- revisions (level_exact only; reported, never applied) ----------
    look = last - dt.timedelta(days=ds["revision_lookback_days"])
    for c in cols:
        if res.instruments[c].status.startswith("FAILED") or spec_of(c)["splice"] != "level_exact":
            continue
        for d, v in series[c].items():
            sv = by_date.get(d, {}).get(c)
            if look <= d <= last and sv is not None and rel_diff(v, sv) > ds["revision_rel_tolerance"]:
                res.revisions.append({"date": d.isoformat(), "instrument": c, "stored": sv, "source": float(v)})

    if trading is None and idx_cols and any(res.instruments[c].status.startswith("FAILED") for c in idx_cols):
        res.status, res.reason = FAILED, "IDX unavailable: JCI/equities cannot be updated"

    # ---------- build rows: every weekday, contiguous prefix of complete days ----------
    rows, blocked = [], False
    # What to do when a REQUIRED instrument has no usable value for a day (outage, blocked, wrong series, dead feed, absurd jump):
    #   "na"    write the text "NA" for that cell (house convention), keep going, never claim SUCCESS (PARTIAL_SUCCESS + warnings);
    #           gives up (blocks) after max_consecutive_na days in a row so a dead feed cannot silently produce NA forever.
    #   "block" write no row at all, so the gap is caught up automatically once the source recovers.
    # JCI/IDX is never NA-filled: without it holidays cannot be told apart from outages.
    policy = str(cfg.get("ingest", {}).get("on_required_failure", "block")).lower()
    max_na = int(cfg.get("ingest", {}).get("max_consecutive_na", 5))
    na_run = {c: 0 for c in cols}
    na_cells: dict = {}

    na_reason: dict = {}

    def miss(c, d, why, bad, day_na, status=None, detail=None):
        """A day-level gap must not switch the instrument off for the rest of the run (tomorrow it may print again)."""
        if policy == "na" and c not in idx_cols and na_run[c] < max_na:
            na_run[c] += 1
            day_na.append(c)
            na_reason[c] = detail or why
            return
        if status:
            res.instruments[c].status, res.instruments[c].detail = status, detail or why
        bad.append(f"{c}: {why}" + (f" (more than {max_na} NA days in a row)" if policy == "na" and c not in idx_cols else ""))

    carry_run = {c: 0 for c in cols}
    tail_run = {c: 0 for c in cols}
    blank_state = {c: by_date[last].get(c) is None for c in cols}     # last stored ROW blank (suspended/unlisted)
    carried = {c: 0 for c in cols}
    if res.status != FAILED:
        for d in weekdays_between(last + dt.timedelta(days=1), row_limit):
            if blocked:
                res.blocked_dates.append(d.isoformat())
                continue
            row, bad, day_na, snap = {}, [], [], (dict(prev_level), dict(src_last), dict(carry_run), dict(tail_run), dict(na_run))
            for c in cols:
                r, sp = res.instruments[c], spec_of(c)
                if r.status.startswith("FAILED"):
                    if r.required:
                        miss(c, d, r.status, bad, day_na)
                    continue
                v = series[c].get(d)
                is_idx = sp["provider"] in ("idx_index", "idx_stock")
                if v is not None and sp["provider"] == "idx_stock" and blank_state.get(c) and c in zero_vol.get(d, ()):
                    continue            # blank (suspended/unlisted) stock + zero-volume close = stale price, not an observation
                if v is None:
                    if is_idx and trading is not None and d in trading:
                        continue                                  # traded day, code absent: stay blank
                    if prev_level.get(c) is None or blank_state.get(c):
                        continue                                      # blank stays blank: never resurrect an old price
                    if sp.get("closed_calendar") == "idx":           # Indonesian-market series: no print is only OK on an IDX holiday
                        if trading is not None and d in trading:
                            if r.required:
                                miss(c, d, f"FAILED_MISSING {d}", bad, day_na, "FAILED_MISSING", f"no print for {d} although IDX traded (capture missed?)")
                            continue
                    elif not is_idx and not (series[c].index > d).any():   # tail: cannot tell 'closed' from 'not published'
                        tail_run[c] += 1
                        if tail_run[c] > ds["tail_carry_days"]:
                            if r.required:
                                miss(c, d, "FAILED_STALE", bad, day_na, "FAILED_STALE", f"no print after {series[c].index.max()} (feed stale)")
                            continue
                    carry_run[c] += 1
                    if carry_run[c] > sp.get("max_carry_days", 5):
                        if r.required:
                            miss(c, d, "FAILED_STALE", bad, day_na, "FAILED_STALE", f"no new print for >{sp.get('max_carry_days', 5)} consecutive weekdays (dead feed?)")
                        continue
                    row[c] = prev_level[c]
                    carried[c] += 1
                    na_run[c] = 0
                    continue
                carry_run[c] = 0
                tail_run[c] = 0
                if sp["splice"] == "level_exact":
                    new, base = v, prev_level.get(c)
                    if base and base > 0 and abs(math.log(v / base)) > ds["max_abs_daily_logret"]:
                        (miss(c, d, f"|logret|>{ds['max_abs_daily_logret']}", bad, day_na) if r.required else log("WARN", "optional value dropped by sanity check", col=c, date=d))
                        continue
                else:
                    sl, pl = src_last.get(c), prev_level.get(c)
                    if sl is None or pl is None or v <= 0 and sp["transform"] == "log":
                        miss(c, d, "cannot chain (no base level)", bad, day_na)
                        continue
                    if sp["splice"] == "chain_return":
                        if abs(math.log(v / sl)) > ds["max_abs_daily_logret"]:
                            miss(c, d, f"source |logret|>{ds['max_abs_daily_logret']}", bad, day_na)
                            continue
                        new = pl * v / sl
                    else:
                        if abs(v - sl) > ds["max_abs_diff_yield_pp"]:
                            miss(c, d, f"source |diff|>{ds['max_abs_diff_yield_pp']}", bad, day_na)
                            continue
                        new = pl + (v - sl)
                    src_last[c] = float(v)
                row[c] = float(new)
                prev_level[c] = float(new)
                blank_state[c] = False
                na_run[c] = 0
                r.n_new_values += 1
            if bad:
                blocked = True
                prev_level, src_last, carry_run, tail_run, na_run = snap
                res.blocked_dates.append(d.isoformat())
                res.reason = f"{d}: " + "; ".join(bad[:6])
                continue
            for c in day_na:
                na_cells.setdefault(c, []).append(d.isoformat())
            rows.append((d, row))
        res.na_written = na_cells
        for c in na_cells:                                   # the instrument is degraded (never SUCCESS) but kept alive for later days
            if not res.instruments[c].status.startswith("FAILED"):
                res.instruments[c].status = "FAILED_NA"
                res.instruments[c].detail = f"NA written on {len(na_cells[c])} day(s); last reason: {na_reason.get(c, '')}"[:200]
        for c, ds_ in na_cells.items():
            res.warnings.append(f"{c}: \"NA\" written for {len(ds_)} day(s) {ds_[:6]}{'...' if len(ds_) > 6 else ''} - the R model drops rows with NA in model variables")
        n = append_rows(xlsx, rows)
        assert n == len(rows), "append skipped a date that was supposedly new"
        res.new_dates = [d.isoformat() for d, _ in rows]
        for c in cols:
            res.instruments[c].n_carried = carried[c]
            if res.instruments[c].status == "PENDING":
                res.instruments[c].status = "OK_NEW" if res.instruments[c].n_new_values else "OK_NO_NEW"
        res.last_date_after = rows[-1][0].isoformat() if rows else res.last_date_before
        any_req = any(r.required and r.status.startswith("FAILED") for r in res.instruments.values())
        any_opt = any((not r.required) and r.status.startswith("FAILED") for r in res.instruments.values())
        if rows:
            res.status = PARTIAL_SUCCESS if (any_req or any_opt or blocked or res.revisions or na_cells) else SUCCESS
        elif blocked or any_req:
            res.status, res.reason = FAILED, res.reason or "required instrument(s) failed"
        elif row_limit <= last:
            res.status, res.reason = UP_TO_DATE, f"no weekday finalised after {last} yet (row_limit={row_limit})"
        else:
            res.status, res.reason = FAILED, "weekdays pending but no row could be built"
    else:
        res.last_date_after = res.last_date_before
    res.finished = fmt_both(now_utc())
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xlsx", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--phei-store", default=None)
    ap.add_argument("--config", default=None)
    a = ap.parse_args(argv)
    cfg = load_config(a.config)
    work = Path(a.xlsx)
    snap = Path(tempfile.mkdtemp()) / "pre_ingest.xlsx"
    shutil.copy2(work, snap)
    try:
        from .http import WebClient
        res = run_ingest(str(work), cfg, ctx_extra={"http": WebClient(), "phei_store": a.phei_store})
    except Exception as e:  # noqa: BLE001
        shutil.copy2(snap, work)
        res = IngestResult(status=FAILED, reason=f"unhandled: {type(e).__name__}: {e}")
    if res.status == FAILED:
        shutil.copy2(snap, work)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(res.to_json(), indent=2, default=str), encoding="utf-8")
    failed = {k: v.detail for k, v in res.instruments.items() if v.status.startswith("FAILED")}
    log("INFO", "ingest finished", status=res.status, new_obs=len(res.new_dates), failed=len(failed), reason=res.reason)
    for k, v in list(failed.items())[:12]:
        log("WARN", f"instrument failed: {k}", detail=v)
    for k, v in res.instruments.items():
        if v.diag.get("return_corr") is not None:
            log("INFO", f"definition check {k}", **v.diag)
    for w in res.warnings:
        log("WARN", w)
    return 1 if res.status == FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
