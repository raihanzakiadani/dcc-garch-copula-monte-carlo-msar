"""Incremental, idempotent, in-place append to raw_data.xlsx (history is never rewritten)."""
from __future__ import annotations

import datetime as dt
import math
import os
import re
import tempfile
from pathlib import Path

from openpyxl import load_workbook


NA_TEXT = "NA"


def _is_missing(v) -> bool:
    return v is None or (isinstance(v, float) and math.isnan(v))


def _to_float(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return None if (isinstance(v, float) and math.isnan(v)) else float(v)
    if isinstance(v, str):
        s = v.strip()
        if s == "" or s.upper() in ("NA", "N/A", "#N/A", "NAN"):
            return None
        try:
            return float(s)
        except ValueError:
            return None
    return None


def _to_date(v):
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    return None


def read_state(path: str | os.PathLike, dedupe_policy: str = "last") -> dict:
    wb = load_workbook(path, read_only=True, data_only=True)
    ws = wb.worksheets[0]
    it = ws.iter_rows(values_only=True)
    header = [h for h in next(it)]
    by_date: dict = {}
    n_rows = 0
    n_dup = 0
    for row in it:
        d = _to_date(row[0])
        if d is None:
            continue
        n_rows += 1
        rec = {header[i]: _to_float(row[i]) for i in range(1, len(header))}
        if d in by_date:
            n_dup += 1
            if dedupe_policy == "first":
                continue
        by_date[d] = rec
    wb.close()
    if not by_date:
        raise ValueError("raw_data has no dated rows")
    return {"header": header, "by_date": by_date, "last_date": max(by_date), "n_rows": n_rows, "n_dup": n_dup}


def append_rows(path: str | os.PathLike, rows: list[tuple[dt.date, dict]]) -> int:
    """Append rows at the bottom of the first sheet. Skips dates already present (idempotent)."""
    if not rows:
        return 0
    wb = load_workbook(path)
    ws = wb.worksheets[0]
    header = [c.value for c in ws[1]]
    existing = {_to_date(r[0].value) for r in ws.iter_rows(min_row=2) if r and r[0].value is not None}
    last_fmt = ws.cell(row=ws.max_row, column=1).number_format
    n = 0
    for d, vals in rows:
        if d in existing:
            continue
        # House convention of raw_data.xlsx: a missing value is the literal text "NA" (history has 0 truly empty cells).
        out = [dt.datetime(d.year, d.month, d.day)] + [NA_TEXT if _is_missing(vals.get(h)) else vals.get(h) for h in header[1:]]
        ws.append(out)
        ws.cell(row=ws.max_row, column=1).number_format = last_fmt
        existing.add(d)
        n += 1
    tmp = Path(tempfile.mkstemp(suffix=".xlsx", dir=str(Path(path).parent))[1])
    try:
        wb.save(tmp)
        chk = load_workbook(tmp, read_only=True)
        chk.close()
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()
    return n


def weekdays_between(start: dt.date, end: dt.date):
    d = start
    while d <= end:
        if d.weekday() < 5:
            yield d
        d += dt.timedelta(days=1)


def rel_diff(a: float, b: float) -> float:
    den = max(abs(a), abs(b), 1e-12)
    return abs(a - b) / den


def is_equity(col: str, pattern: str) -> bool:
    return re.search(pattern, col, flags=re.I) is not None
