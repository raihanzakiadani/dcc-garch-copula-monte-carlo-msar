"""IDX provider, ported from the old idx-to-sheets project (scraper.py).

Endpoints (copied from the old project, NOT independently verified in this audit):
  GET https://www.idx.co.id/primary/TradingSummary/GetStockSummary?date=YYYYMMDD&start=0&length=9999
  GET https://www.idx.co.id/primary/TradingSummary/GetIndexSummary?date=YYYYMMDD&start=0&length=9999
The old project needed curl_cffi (TLS impersonation) AND, for Cloudflare's JS challenge, a
FlareSolverr instance on a *self-hosted* runner. Whether this works from a GitHub-hosted
runner (datacenter IPs) is UNKNOWN until a live run; a failure is reported, never masked.
Field names ('StockCode', 'Close', 'IndexCode', 'Volume') follow IDX's public JSON; the code
raises ProviderError if they are absent instead of guessing.
"""
from __future__ import annotations

import os

import pandas as pd

from ..common import ProviderError, log

BASE_URL = "https://www.idx.co.id/primary"
WARMUP_URL = "https://www.idx.co.id/id/data-pasar/ringkasan-perdagangan/ringkasan-saham"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36")


class IdxHttp:
    """Thin wrapper; replaced by a fake in tests."""

    def __init__(self):
        try:
            from curl_cffi import requests as r  # type: ignore
        except ImportError as e:
            raise ProviderError("curl_cffi not installed") from e
        proxy = os.environ.get("PROXY_URL")
        self._r = r
        self._proxies = {"http": proxy, "https": proxy} if proxy else None
        self._s = r.Session(impersonate="chrome131", proxies=self._proxies)
        self._warm()

    def _warm(self):
        fs = os.environ.get("FLARESOLVERR_URL", "")
        if fs:
            resp = self._r.post(fs, json={"cmd": "request.get", "url": WARMUP_URL, "maxTimeout": 60000}, timeout=70)
            data = resp.json()
            if data.get("status") != "ok":
                raise ProviderError("FlareSolverr did not solve the challenge")
            for c in data["solution"].get("cookies", []):
                self._s.cookies.set(c["name"], c["value"], domain=".idx.co.id")
        else:
            try:
                self._s.get(WARMUP_URL, headers={"User-Agent": UA}, timeout=30)
            except Exception as e:  # noqa: BLE001
                log("WARN", "IDX warm-up failed", err=type(e).__name__)

    def get_json(self, path: str, params: dict) -> dict:
        resp = self._s.get(f"{BASE_URL}{path}", params=params, timeout=30, headers={
            "User-Agent": UA, "Accept": "application/json, text/plain, */*",
            "Referer": WARMUP_URL, "X-Requested-With": "XMLHttpRequest"})
        if resp.status_code != 200:
            raise ProviderError(f"IDX {path} HTTP {resp.status_code}")
        try:
            return resp.json()
        except Exception as e:  # noqa: BLE001
            raise ProviderError(f"IDX {path} returned non-JSON (Cloudflare challenge?)") from e


def _rows(http, path: str, date_str: str) -> list[dict]:
    data = http.get_json(path, {"date": date_str, "start": 0, "length": 9999})
    if not isinstance(data, dict) or "data" not in data:
        raise ProviderError(f"IDX {path}: unexpected response shape")
    return data["data"] or []


def stock_code(col: str) -> str:
    return col.split()[0].upper()


def fetch_idx(dates: list, equity_cols: list[str], index_cols: dict[str, str], http) -> tuple[dict, set, dict]:
    """Returns (values[date][col], trading_days, volume_zero[date]->list(cols)).

    trading_days = dates on which the index summary returned a row (the IDX calendar);
    an EMPTY response is 'not a trading day', an exception is a FAILURE.
    """
    values: dict = {}
    trading: set = set()
    zero_vol: dict = {}
    for d in dates:
        ds = d.strftime("%Y%m%d")
        idx_rows = _rows(http, "/TradingSummary/GetIndexSummary", ds)
        if not idx_rows:
            continue
        if "IndexCode" not in idx_rows[0] or "Close" not in idx_rows[0]:
            raise ProviderError("IndexSummary rows lack IndexCode/Close")
        trading.add(d)
        by_code = {str(r["IndexCode"]).upper(): r for r in idx_rows}
        day = {}
        for col, code in index_cols.items():
            r = by_code.get(code.upper())
            if r is not None and r.get("Close") not in (None, ""):
                day[col] = float(r["Close"])
        if equity_cols:
            st_rows = _rows(http, "/TradingSummary/GetStockSummary", ds)
            if st_rows and ("StockCode" not in st_rows[0] or "Close" not in st_rows[0]):
                raise ProviderError("StockSummary rows lack StockCode/Close")
            by_stock = {str(r["StockCode"]).upper(): r for r in st_rows}
            zv = []
            for col in equity_cols:
                r = by_stock.get(stock_code(col))
                if r is None or r.get("Close") in (None, ""):
                    continue            # absent => stays blank, never filled
                px = float(r["Close"])
                if px <= 0:
                    continue
                day[col] = px
                if float(r.get("Volume") or 0) == 0:
                    zv.append(col)
            zero_vol[d] = zv
        values[d] = day
    return values, trading, zero_vol
