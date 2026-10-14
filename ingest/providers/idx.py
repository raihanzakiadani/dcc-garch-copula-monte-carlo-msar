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
IMPERSONATE = "chrome131"
DEFAULT_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/131.0.0.0 Safari/537.36")
UA = DEFAULT_UA

# Header sets copied from the old idx-to-sheets project (scraper.py), which is known to work with FlareSolverr.
_SEC = {"sec-ch-ua": '"Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"', "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"Windows"'}


def page_headers(ua: str) -> dict:
    return {"User-Agent": ua, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "id-ID,id;q=0.9,en-US;q=0.8,en;q=0.7", "Accept-Encoding": "gzip, deflate, br",
            "Upgrade-Insecure-Requests": "1", **_SEC, "Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}


def api_headers(ua: str) -> dict:
    return {"User-Agent": ua, "Referer": WARMUP_URL, "Accept": "application/json, text/plain, */*",
            "Accept-Language": "id-ID,id;q=0.9,en-US;q=0.8,en;q=0.7", "Accept-Encoding": "gzip, deflate, br",
            "X-Requested-With": "XMLHttpRequest", **_SEC, "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"}


class IdxHttp:
    """Two layers, as in the old project plus a fallback:
      1. FlareSolverr solves the Cloudflare challenge once; its cookies AND its User-Agent are replayed on a curl_cffi session
         (a cf_clearance cookie is bound to the browser fingerprint, so the UA must match - this was the missing piece).
      2. If the API still answers 403/503/non-JSON, FlareSolverr itself performs the API request in a real browser and the JSON is
         taken from the rendered page.
    `session` / `flare_post` are injectable for tests."""

    def __init__(self, session=None, flare_post=None):
        self._flare_url = os.environ.get("FLARESOLVERR_URL", "http://localhost:8191/v1").strip()   # same default as the old project
        proxy = os.environ.get("PROXY_URL")
        self._proxies = {"http": proxy, "https": proxy} if proxy else None
        self._r = None
        if session is None:
            try:
                from curl_cffi import requests as r  # type: ignore
            except ImportError as e:
                raise ProviderError("curl_cffi not installed") from e
            self._r = r
            session = r.Session(impersonate=IMPERSONATE, proxies=self._proxies)
        self._s = session
        self._post = flare_post or self._default_post
        self.ua = DEFAULT_UA
        self._flare_session = None
        self._warm()

    def _default_post(self, payload: dict, timeout: int) -> dict:
        return self._r.post(self._flare_url, json=payload, timeout=timeout).json()

    def _solve(self, url: str) -> tuple[dict, str]:
        data = self._post({"cmd": "request.get", "url": url, "maxTimeout": 60000}, 75)
        if data.get("status") != "ok":
            raise ProviderError(f"FlareSolverr did not solve the challenge: {str(data.get('message'))[:120]}")
        sol = data["solution"]
        return {c["name"]: c["value"] for c in sol.get("cookies", [])}, (sol.get("userAgent") or DEFAULT_UA)

    def _warm(self):
        if self._flare_url:
            try:
                cookies, ua = self._solve(WARMUP_URL)
                for name, value in cookies.items():
                    self._s.cookies.set(name, value, domain=".idx.co.id")
                self.ua = ua
                log("INFO", "IDX warm-up via FlareSolverr", cookies=len(cookies), ua_replayed="yes")
                return
            except Exception as e:  # noqa: BLE001
                log("WARN", "FlareSolverr warm-up failed; falling back to plain curl_cffi warm-up", err=str(e)[:120] or type(e).__name__)
        try:
            r = self._s.get(WARMUP_URL, headers=page_headers(self.ua), timeout=30)
            log("INFO", "plain IDX warm-up", status=r.status_code)
        except Exception as e:  # noqa: BLE001
            log("WARN", "plain IDX warm-up failed", err=type(e).__name__)

    def _flare_json(self, url: str) -> dict:
        from ..http import _unwrap_pre
        payload = {"cmd": "request.get", "url": url, "maxTimeout": 60000}
        if self._flare_session:
            payload["session"] = self._flare_session
        data = self._post(payload, 75)
        if data.get("status") != "ok":
            raise ProviderError(f"FlareSolverr: {str(data.get('message'))[:100]}")
        sol = data["solution"]
        if int(sol.get("status", 0)) != 200:
            raise ProviderError(f"HTTP {sol.get('status')}")
        import json
        try:
            return json.loads(_unwrap_pre(sol.get("response", "")))
        except ValueError:
            raise ProviderError("non-JSON page") from None

    def get_json(self, path: str, params: dict) -> dict:
        url = f"{BASE_URL}{path}"
        err = ""
        try:
            resp = self._s.get(url, params=params, headers=api_headers(self.ua), timeout=30)
            if resp.status_code == 200:
                try:
                    return resp.json()
                except Exception:  # noqa: BLE001
                    err = "non-JSON (challenge page?)"
            else:
                err = f"HTTP {resp.status_code}"
        except Exception as e:  # noqa: BLE001
            err = type(e).__name__
        if self._flare_url:                                              # layer 2: let the real browser do the request
            from urllib.parse import urlencode
            try:
                return self._flare_json(f"{url}?{urlencode(params)}")
            except ProviderError as e2:
                raise ProviderError(f"IDX {path}: direct {err}; via FlareSolverr {e2}") from None
            except Exception as e2:  # noqa: BLE001
                raise ProviderError(f"IDX {path}: direct {err}; FlareSolverr unreachable ({type(e2).__name__})") from None
        raise ProviderError(f"IDX {path} {err}")


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
