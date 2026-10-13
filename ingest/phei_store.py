"""PHEI shows ONE day only, so each day's observation must be captured and persisted by us.

store: CSV  date,value,kind   (kind = last | previous)   - lives in its own release asset (see publish docs),
so a failure elsewhere in the pipeline never loses a PHEI day.  'last' (authoritative) is never overwritten by
a later 'previous' value; a differing re-observation is reported as a revision, not applied.
"""
from __future__ import annotations

import csv
import datetime as dt
from pathlib import Path

import pandas as pd


def load(path) -> dict:
    p = Path(path)
    out: dict = {}
    if p.exists():
        with open(p, newline="", encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                out[dt.date.fromisoformat(r["date"])] = (float(r["value"]), r["kind"])
    return out


def prev_weekday(d: dt.date) -> dt.date:
    d -= dt.timedelta(days=1)
    while d.weekday() >= 5:
        d -= dt.timedelta(days=1)
    return d


def record(path, parsed: dict) -> dict:
    """parsed = parse_phei() result. Returns {'added': [...], 'revisions': [...]}"""
    st = load(path)
    added, revisions = [], []
    d, last, prev = parsed["date"], parsed["last"], parsed["previous"]
    pd_ = prev_weekday(d)
    for date, val, kind in ((pd_, prev, "previous"), (d, last, "last")):
        if date in st:
            old, okind = st[date]
            if abs(old - val) > 1e-9 and (kind == "last" or okind == "last"):
                revisions.append({"date": date.isoformat(), "stored": old, "seen": val, "kind": kind})
            if kind == "last" and okind == "previous":
                st[date] = (val, "last"); added.append(date.isoformat())
            continue
        st[date] = (val, kind); added.append(date.isoformat())
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(path) + ".tmp")
    with open(tmp, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh); w.writerow(["date", "value", "kind"])
        for k in sorted(st):
            w.writerow([k.isoformat(), repr(st[k][0]), st[k][1]])
    tmp.replace(path)
    return {"added": added, "revisions": revisions}


def as_series(path) -> pd.Series:
    st = load(path)
    if not st:
        from .common import ProviderError
        raise ProviderError("phei history empty - capture has never run")
    return pd.Series({k: v[0] for k, v in st.items()}).sort_index()
