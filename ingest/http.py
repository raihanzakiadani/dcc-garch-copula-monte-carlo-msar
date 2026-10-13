"""HTTP client for bot-protected sites: curl_cffi (browser TLS impersonation) first, FlareSolverr as
fallback - the same mechanism as the old idx-to-sheets project (scraper.py), generalised to any URL.

FLARESOLVERR_URL (e.g. http://localhost:8191/v1) points to a FlareSolverr container. In GitHub Actions it
runs as a service container (see .github/workflows/pipeline.yml). Whether a given site lets a datacenter IP
through is only knowable by running it; every failure surfaces as ProviderError, never as fake data.
"""
from __future__ import annotations

import os
import re

from .common import ProviderError, log

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36")
_CHALLENGE = re.compile(r"just a moment|cf-chl|attention required|enable javascript and cookies", re.I)


def _unwrap_pre(body: str) -> str:
    """Browsers wrap raw JSON in <pre>; FlareSolverr returns that HTML."""
    m = re.search(r"<pre[^>]*>(.*?)</pre>", body, re.S | re.I)
    if m and body.lstrip().startswith("<"):
        import html
        return html.unescape(m.group(1))
    return body


class WebClient:
    def __init__(self):
        self._flare = os.environ.get("FLARESOLVERR_URL", "").strip()
        proxy = os.environ.get("PROXY_URL")
        self._proxies = {"http": proxy, "https": proxy} if proxy else None
        try:
            from curl_cffi import requests as r  # type: ignore
            self._r = r
            self._s = r.Session(impersonate="chrome131", proxies=self._proxies)
        except ImportError:
            self._r = self._s = None
            if not self._flare:
                raise ProviderError("curl_cffi not installed and FLARESOLVERR_URL not set") from None

    def _direct(self, url, headers):
        if self._s is None:
            return None
        h = {"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9,id;q=0.8"}
        h.update(headers or {})
        try:
            resp = self._s.get(url, headers=h, timeout=40)
        except Exception as e:  # noqa: BLE001
            log("WARN", "direct request failed", err=type(e).__name__)
            return None
        if resp.status_code == 200 and not _CHALLENGE.search(resp.text[:3000]):
            return resp.text
        return None

    def _via_flare(self, url):
        resp = self._r.post(self._flare, json={"cmd": "request.get", "url": url, "maxTimeout": 60000}, timeout=75) \
            if self._r else __import__("urllib.request").request.urlopen(  # pragma: no cover
                __import__("urllib.request").request.Request(self._flare, data=__import__("json").dumps(
                    {"cmd": "request.get", "url": url, "maxTimeout": 60000}).encode(),
                    headers={"Content-Type": "application/json"}), timeout=75)
        data = resp.json()
        if data.get("status") != "ok":
            raise ProviderError("FlareSolverr could not solve the challenge")
        sol = data["solution"]
        if int(sol.get("status", 0)) != 200:
            raise ProviderError(f"HTTP {sol.get('status')} via FlareSolverr")
        return _unwrap_pre(sol.get("response", ""))

    def get_text(self, url: str, headers: dict | None = None) -> str:
        body = self._direct(url, headers)
        if body is not None:
            return body
        if not self._flare:
            raise ProviderError("blocked or failed and no FLARESOLVERR_URL configured")
        try:
            return self._via_flare(url)
        except ProviderError:
            raise
        except Exception as e:  # noqa: BLE001
            raise ProviderError(f"FlareSolverr request failed: {type(e).__name__}") from None
