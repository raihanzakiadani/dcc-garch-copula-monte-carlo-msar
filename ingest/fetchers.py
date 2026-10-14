"""Registry: provider name -> function(col, spec, ctx) -> pd.Series(date->value). IDX is handled separately
(its response doubles as the exchange calendar)."""
from __future__ import annotations

from . import phei_store
from .common import ProviderError
from .providers import web
from .providers.sheet_csv import fetch_sheet_csv


def _yahoo(col, spec, ctx):
    return web.parse_yahoo_chart(ctx["http"].get_text(web.yahoo_url(spec["symbol"])), spec.get("field", "adjclose"))


def _stooq(col, spec, ctx):
    return web.parse_stooq(ctx["http"].get_text(spec["url"]), spec.get("column", "Close"))


def _westmetall(col, spec, ctx):
    return web.parse_westmetall(ctx["http"].get_text(spec["url"]), spec["column"])


def _investing(col, spec, ctx):
    return web.parse_investing(ctx["http"].get_text(spec["url"]), spec.get("decimal", "."))


def _mpoc(col, spec, ctx):
    return web.parse_mpoc(ctx["http"].get_text(spec["url"]), spec.get("table_header_contains", ""),
                          spec.get("value_header", ""), spec.get("date_format", "%d/%m/%Y"))


def _phei(col, spec, ctx):
    return phei_store.as_series(ctx["phei_store"])


def _sheet_csv(col, spec, ctx):
    if not str(ctx["env"].get(spec["csv_url_env"], "")).strip():
        raise ProviderError(f"{spec['csv_url_env']} is EMPTY in this job: add it under GitHub > Settings > Secrets and variables > Actions > "
                            f"the *Secrets* tab (a Variable does not work), exact name, then re-run")
    df = fetch_sheet_csv(ctx["env"].get(spec["csv_url_env"], ""), [spec.get("column", col)], ctx["http"].get_text,
                         spec.get("decimal", "."), spec.get("date_format"))
    if spec.get("column", col) != col and spec["column"] in df.columns:
        df = df.rename(columns={spec["column"]: col})
    if col not in df.columns:
        raise ProviderError(f"column absent in {spec['csv_url_env']} feed")
    return df[col].dropna()


REGISTRY = {"yahoo": _yahoo, "stooq": _stooq, "westmetall": _westmetall, "investing": _investing,
            "mpoc": _mpoc, "phei": _phei, "sheet_csv": _sheet_csv}
