"""IdxHttp against fake curl_cffi session + fake FlareSolverr (no network). Models the failure seen on GitHub (HTTP 403)."""
import json, sys
from pathlib import Path
import pytest
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ingest.common import ProviderError
from ingest.providers.idx import IdxHttp, fetch_idx
import datetime as dt

OK_SOL = {"status": "ok", "solution": {"status": 200, "userAgent": "UA-FROM-FLARE", "cookies": [{"name": "cf_clearance", "value": "abc"}, {"name": "x", "value": "1"}], "response": ""}}
JSON_BODY = {"data": [{"IndexCode": "COMPOSITE", "Close": 6100.5}]}


class Resp:
    def __init__(self, code, body=None):
        self.status_code, self._b = code, body
    def json(self):
        if self._b is None: raise ValueError("no json")
        return self._b


class Cookies:
    def __init__(self): self.jar = []
    def set(self, name, value, domain=None): self.jar.append((name, value, domain))


class Session:
    def __init__(self, handler): self.handler, self.cookies, self.calls = handler, Cookies(), []
    def get(self, url, params=None, headers=None, timeout=None):
        self.calls.append({"url": url, "params": params, "headers": headers}); return self.handler(url, params, headers, self)


def flare(responses, log):
    def post(payload, timeout):
        log.append(payload)
        r = responses[min(len(log) - 1, len(responses) - 1)]
        if isinstance(r, Exception): raise r
        return r
    return post


def test_cookies_and_flaresolverr_user_agent_are_replayed(monkeypatch):
    monkeypatch.setenv("FLARESOLVERR_URL", "http://localhost:8191/v1")
    s = Session(lambda *a: Resp(200, JSON_BODY)); calls = []
    h = IdxHttp(session=s, flare_post=flare([OK_SOL], calls))
    out = h.get_json("/TradingSummary/GetIndexSummary", {"date": "20261009", "start": 0, "length": 9999})
    assert out == JSON_BODY
    assert ("cf_clearance", "abc", ".idx.co.id") in s.cookies.jar                      # cookie replayed
    hdr = s.calls[-1]["headers"]
    assert hdr["User-Agent"] == "UA-FROM-FLARE"                                          # the piece that was missing: UA must match the cookie
    assert hdr["X-Requested-With"] == "XMLHttpRequest" and "sec-ch-ua" in hdr and hdr["Sec-Fetch-Mode"] == "cors"
    assert calls[0]["url"].endswith("/ringkasan-saham") and len(calls) == 1               # no browser fallback needed


def test_403_falls_back_to_real_browser_request(monkeypatch):
    monkeypatch.setenv("FLARESOLVERR_URL", "http://localhost:8191/v1")
    s = Session(lambda *a: Resp(403)); calls = []
    page = {"status": "ok", "solution": {"status": 200, "response": "<html><body><pre>" + json.dumps(JSON_BODY).replace('"', "&quot;") + "</pre></body></html>"}}
    h = IdxHttp(session=s, flare_post=flare([OK_SOL, page], calls))
    out = h.get_json("/TradingSummary/GetIndexSummary", {"date": "20261009", "start": 0, "length": 9999})
    assert out == JSON_BODY
    assert "GetIndexSummary?date=20261009&start=0&length=9999" in calls[1]["url"]


def test_both_layers_fail_gives_explicit_error(monkeypatch):
    monkeypatch.setenv("FLARESOLVERR_URL", "http://localhost:8191/v1")
    s = Session(lambda *a: Resp(403)); calls = []
    bad = {"status": "ok", "solution": {"status": 403, "response": "Just a moment"}}
    h = IdxHttp(session=s, flare_post=flare([OK_SOL, bad], calls))
    with pytest.raises(ProviderError) as e:
        h.get_json("/TradingSummary/GetIndexSummary", {"date": "20261009"})
    assert "direct HTTP 403" in str(e.value) and "via FlareSolverr HTTP 403" in str(e.value)


def test_flaresolverr_unreachable_degrades_to_plain_mode(monkeypatch):
    monkeypatch.setenv("FLARESOLVERR_URL", "http://localhost:8191/v1")
    s = Session(lambda url, p, h, sess: Resp(200, JSON_BODY)); calls = []
    h = IdxHttp(session=s, flare_post=flare([ConnectionError("refused")], calls))
    assert s.cookies.jar == [] and h.ua.startswith("Mozilla/5.0")
    assert h.get_json("/x", {}) == JSON_BODY
    s2 = Session(lambda *a: Resp(403)); h2 = IdxHttp(session=s2, flare_post=flare([ConnectionError("refused")] * 3, []))
    with pytest.raises(ProviderError) as e:
        h2.get_json("/x", {})
    assert "FlareSolverr unreachable" in str(e.value)


def test_challenge_not_solved_does_not_crash_and_is_reported(monkeypatch):
    monkeypatch.setenv("FLARESOLVERR_URL", "http://localhost:8191/v1")
    s = Session(lambda *a: Resp(403)); notok = {"status": "error", "message": "Cloudflare detected"}
    h = IdxHttp(session=s, flare_post=flare([notok], []))
    with pytest.raises(ProviderError):
        h.get_json("/x", {})


def test_fetch_idx_works_through_idxhttp(monkeypatch):
    monkeypatch.setenv("FLARESOLVERR_URL", "http://localhost:8191/v1")
    def handler(url, params, headers, sess):
        if "IndexSummary" in url: return Resp(200, {"data": [{"IndexCode": "COMPOSITE", "Close": 6100.5}]})
        return Resp(200, {"data": [{"StockCode": "BBCA", "Close": 5950, "Volume": 10}]})
    h = IdxHttp(session=Session(handler), flare_post=flare([OK_SOL], []))
    vals, trading, _ = fetch_idx([dt.date(2026, 10, 9)], ["BBCA IJ EQUITY"], {"JCI Index": "COMPOSITE"}, h)
    assert vals[dt.date(2026, 10, 9)] == {"JCI Index": 6100.5, "BBCA IJ EQUITY": 5950.0}
