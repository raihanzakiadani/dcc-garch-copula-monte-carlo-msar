"""'Published CSV' provider (Google Sheets > File > Share > Publish to web > CSV, one tab).

Used for Yahoo-sourced series (USDIDR, Brent): a Google Sheet fills the feed (Apps Script in apps_script/yahoo_feed.gs
or GOOGLEFINANCE formulas) and this provider only transports it - the same hand-off pattern as the old idx-to-sheets
project. The URL is a SECRET and is never logged.

Expected layout: first column 'Dates' (YYYY-MM-DD, optionally followed by a time), other columns named exactly like the
model columns. Locale is never guessed: other date layouts need an explicit `date_format`, decimal commas need
decimal=",". Blank spacer rows are ignored; duplicate dates are refused.
"""
from __future__ import annotations

import datetime as dt
import io
import re

import pandas as pd

from ..common import ProviderError
from .web import _num

_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}")


def fetch_sheet_csv(url: str, wanted: list[str], http_get_text, decimal: str = ".", date_format: str | None = None) -> pd.DataFrame:
    if not url:
        raise ProviderError("CSV URL secret is empty/not configured")
    try:
        text = http_get_text(url)
    except Exception as e:  # noqa: BLE001  (message must not leak the URL)
        raise ProviderError(f"CSV download failed: {type(e).__name__}") from None
    if text.lstrip()[:15].lower().startswith(("<!doctype", "<html")):
        raise ProviderError("got an HTML page instead of CSV (sheet not published to web as CSV, or sign-in page)")
    try:
        df = pd.read_csv(io.StringIO(text), dtype=str, keep_default_na=False)
    except Exception as e:  # noqa: BLE001
        raise ProviderError(f"CSV not parseable: {type(e).__name__}") from None
    if df.shape[1] < 2 or df.columns[0].strip().lower() not in ("dates", "date"):
        raise ProviderError("CSV first column must be 'Dates'")
    df = df.rename(columns={df.columns[0]: "Dates"})
    keep = [c for c in df.columns if c == "Dates" or c.strip() in wanted]
    df = df[keep].rename(columns=lambda c: c.strip())
    dates = {}
    for i, raw in df["Dates"].items():
        raw = raw.strip()
        if raw == "":
            if all(str(v).strip() == "" for v in df.drop(columns="Dates").loc[i]):
                continue                                   # blank spacer row
            raise ProviderError("CSV row has values but no date")
        if _ISO.match(raw):
            d = dt.date.fromisoformat(raw[:10])
        elif date_format:
            try:
                d = dt.datetime.strptime(raw, date_format).date()
            except ValueError:
                raise ProviderError(f"date '{raw[:20]}' does not match date_format") from None
        else:
            raise ProviderError("non-ISO date in CSV (use TEXT(date,\"yyyy-mm-dd\") in the sheet, or set date_format)")
        if d in dates:
            raise ProviderError("CSV has duplicate dates; refusing to guess which is right")
        dates[d] = i
    if not dates:
        raise ProviderError("CSV has no data rows")
    out = pd.DataFrame(index=sorted(dates))
    for c in wanted:
        if c in df.columns:
            vals = {d: _num(str(df.at[i, c]), decimal) for d, i in dates.items()}
            s = pd.Series(vals, dtype=float)
            bad = [d for d, i in dates.items() if str(df.at[i, c]).strip() not in ("", "#N/A", "N/A") and pd.isna(vals[d])]
            if bad:
                raise ProviderError(f"column '{c}': {len(bad)} value(s) do not match decimal='{decimal}' (decimal comma? set decimal=',')")
            out[c] = s
    out.index.name = "Dates"
    return out
