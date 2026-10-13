"""Parsers + fetchers for the web sources chosen by the user.

Every parse_* function is a PURE function (HTML/JSON text -> pandas Series date->float) so it can be tested on
saved pages. VERIFIED = tested against a page the user saved on 2026-10-09; UNVERIFIED = written from the known
page/API structure but never run against a real sample (see docs/DATA_SOURCES.md).
"""
from __future__ import annotations

import datetime as dt
import json
import re

import pandas as pd
from bs4 import BeautifulSoup

from ..common import ProviderError


_DOT = re.compile(r"^[+-]?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$")      # 1,234.50 | 1234.5
_COMMA = re.compile(r"^[+-]?(\d{1,3}(\.\d{3})+|\d+)(,\d+)?$")    # 1.234,50 | 1234,5


def _num(s: str, decimal: str = ".") -> float | None:
    """Strict: a string that does not match the declared locale returns None instead of a wrong number
    (e.g. '16.500,5' read with decimal='.' must NOT become 16.5005)."""
    s = s.strip().replace("\xa0", "").replace(" ", "").rstrip("%")
    if s in ("", "-", "--", "N/A"):
        return None
    if decimal == ",":
        if not _COMMA.match(s):
            return None
        s = s.replace(".", "").replace(",", ".")
    else:
        if not _DOT.match(s):
            return None
        s = s.replace(",", "")
    try:
        return float(s)
    except ValueError:
        return None


def _series(d: dict) -> pd.Series:
    if not d:
        raise ProviderError("parsed 0 rows")
    s = pd.Series(d).sort_index()
    s.index = pd.Index([x for x in s.index], name="Dates")
    return s


# ------------------------------------------------------------------ Stooq (VERIFIED on saved pages)
def parse_stooq(html: str, column: str = "Close") -> pd.Series:
    soup = BeautifulSoup(html, "html.parser")
    t = soup.find("table", id="fth1")
    if t is None:
        raise ProviderError("stooq: table#fth1 not found (layout change or challenge page)")
    rows = t.find_all("tr")
    hdr = [c.get_text(strip=True) for c in rows[0].find_all(["th", "td"])]
    if "Date" not in hdr or column not in hdr:
        raise ProviderError(f"stooq: header lacks Date/{column}: {hdr}")
    out = {}
    for r in rows[1:]:
        c = [x.get_text(strip=True) for x in r.find_all("td")]
        try:
            d = dt.datetime.strptime(c[hdr.index("Date")], "%d %b %Y").date()
        except (ValueError, IndexError):
            continue
        v = _num(c[hdr.index(column)])
        if v is not None:
            out[d] = v
    return _series(out)


# ------------------------------------------------------------------ Westmetall (VERIFIED)
def parse_westmetall(html: str, column: str = "LME Nickel Cash-Settlement") -> pd.Series:
    soup = BeautifulSoup(html, "html.parser")
    t = soup.find("table")
    if t is None:
        raise ProviderError("westmetall: no table")
    rows = t.find_all("tr")
    hdr = [c.get_text(" ", strip=True) for c in rows[0].find_all(["th", "td"])]
    if column not in hdr:
        raise ProviderError(f"westmetall: column '{column}' not in {hdr}")
    out = {}
    for r in rows[1:]:
        c = [x.get_text(strip=True) for x in r.find_all("td")]
        try:
            d = dt.datetime.strptime(c[0], "%d. %B %Y").date()
        except (ValueError, IndexError):
            continue
        v = _num(c[hdr.index(column)])
        if v is not None:
            out[d] = v
    return _series(out)


# ------------------------------------------------------------------ PHEI (VERIFIED on saved page)
def parse_phei(html: str, row_name: str = "INDOBeX Government Clean Price") -> dict:
    """Returns {'date': date of 'Last', 'previous': float, 'last': float}. The page shows ONE day only."""
    soup = BeautifulSoup(html, "html.parser")
    lab = soup.find(id=re.compile(r"indobexdata_lblDate$"))
    if lab is None:
        raise ProviderError("phei: lblDate not found")
    try:
        d = dt.datetime.strptime(lab.get_text(strip=True), "%d %B %Y").date()
    except ValueError:
        raise ProviderError(f"phei: unparseable date '{lab.get_text(strip=True)}'") from None
    t = soup.find("table", id=re.compile(r"indobexdata_gvDailyDate$"))
    if t is None:
        raise ProviderError("phei: INDOBeX table not found")
    for tr in t.find_all("tr"):
        if tr.find("table"):
            continue
        c = [x.get_text(" ", strip=True) for x in tr.find_all(["td", "th"])]
        c = [x for x in c if x != ""]
        if len(c) >= 4 and c[1] == row_name:
            prev, last = _num(c[2]), _num(c[3])
            if prev is None or last is None:
                raise ProviderError("phei: non-numeric Previous/Last")
            return {"date": d, "previous": prev, "last": last, "row": row_name}
    raise ProviderError(f"phei: row '{row_name}' not found (index renamed?)")


# ------------------------------------------------------------------ Yahoo chart API (UNVERIFIED live)
def parse_yahoo_chart(text: str, field: str = "adjclose") -> pd.Series:
    try:
        j = json.loads(text)
        res = j["chart"]["result"][0]
        ts = res["timestamp"]
        off = int(res["meta"].get("gmtoffset", 0))
        ind = res["indicators"]
        vals = (ind.get("adjclose") or [{}])[0].get("adjclose") if field == "adjclose" else None
        if vals is None:
            vals = ind["quote"][0]["close"]
    except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError) as e:
        raise ProviderError(f"yahoo: unexpected JSON ({type(e).__name__})") from None
    out = {}
    for t, v in zip(ts, vals):
        if v is None:
            continue
        out[(dt.datetime.fromtimestamp(t + off, dt.timezone.utc)).date()] = float(v)
    return _series(out)


def yahoo_url(symbol: str, range_: str = "3mo") -> str:
    from urllib.parse import quote
    return f"https://query1.finance.yahoo.com/v8/finance/chart/{quote(symbol, safe='')}?range={range_}&interval=1d&events=history"


# ------------------------------------------------------------------ Investing.com (UNVERIFIED)
def parse_investing(html: str, decimal: str = ".") -> pd.Series:
    """id.investing.com: dd/mm/yyyy dates and decimal COMMA ("6,740") -> decimal=","; www: decimal=".".
    Never guessed: the caller states it in config."""
    soup = BeautifulSoup(html, "html.parser")
    best = None
    for t in soup.find_all("table"):
        rows = t.find_all("tr")
        if len(rows) < 5:
            continue
        hdr = [c.get_text(" ", strip=True).lower() for c in rows[0].find_all(["th", "td"])]
        if any(h in ("tanggal", "date") for h in hdr) and any(h in ("terakhir", "price", "close", "penutupan") for h in hdr):
            best = (t, hdr)
            break
    if best is None:
        raise ProviderError("investing: historical table not found (layout/challenge)")
    t, hdr = best
    di = next(i for i, h in enumerate(hdr) if h in ("tanggal", "date"))
    pi = next(i for i, h in enumerate(hdr) if h in ("terakhir", "price", "close", "penutupan"))
    out = {}
    for r in t.find_all("tr")[1:]:
        c = [x.get_text(strip=True) for x in r.find_all("td")]
        if len(c) <= max(di, pi):
            continue
        d = None
        for fmt in ("%d/%m/%Y", "%d.%m.%Y", "%b %d, %Y", "%m/%d/%Y"):
            try:
                d = dt.datetime.strptime(c[di], fmt).date()
                break
            except ValueError:
                pass
        v = _num(c[pi], decimal)
        if d is not None and v is not None:
            out[d] = v
    return _series(out)


# ------------------------------------------------------------------ MPOC (UNVERIFIED - needs sample page)
def parse_mpoc(html: str, header_contains: str, value_header: str, date_format: str = "%d/%m/%Y") -> pd.Series:
    """MPOC's layout was not available to this audit. The caller MUST configure which table/column to use
    (config: mpoc_table_header_contains, mpoc_value_header). Unconfigured => explicit failure."""
    if not header_contains or not value_header:
        raise ProviderError("mpoc: parser not configured (no sample page was available) - see docs/DATA_SOURCES.md")
    soup = BeautifulSoup(html, "html.parser")
    for t in soup.find_all("table"):
        rows = t.find_all("tr")
        if not rows:
            continue
        hdr = [c.get_text(" ", strip=True) for c in rows[0].find_all(["th", "td"])]
        if any(header_contains.lower() in h.lower() for h in hdr) and any(value_header.lower() in h.lower() for h in hdr):
            vi = next(i for i, h in enumerate(hdr) if value_header.lower() in h.lower())
            out = {}
            for r in rows[1:]:
                c = [x.get_text(strip=True) for x in r.find_all("td")]
                if len(c) <= vi:
                    continue
                try:
                    d = dt.datetime.strptime(c[0], date_format).date()
                except ValueError:
                    continue
                v = _num(c[vi])
                if v is not None:
                    out[d] = v
            return _series(out)
    raise ProviderError("mpoc: configured table/column not found")
