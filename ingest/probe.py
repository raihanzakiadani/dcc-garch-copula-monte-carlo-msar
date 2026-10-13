"""Export-only probe: can each source be reached and parsed RIGHT NOW? No model, no state, nothing is written or published.

  python -m ingest.probe --seed seed/raw_data.xlsx            (exit 1 if any source fails)

For every instrument it reports rows fetched, newest date + value, or the failure reason (never the URL/secret).
IDX is probed for the last weekdays and for how many of the 71 expected stock codes it returns.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import sys

from .common import WIB, ProviderError, load_config, now_utc
from .fetchers import REGISTRY
from .merge import is_equity, read_state, weekdays_between
from .providers.idx import fetch_idx, stock_code
from .providers.web import parse_phei


def _err(e: Exception) -> str:
    msg = str(e) if isinstance(e, ProviderError) else type(e).__name__
    return msg[:160]


def probe(cfg: dict, header: list[str], env, idx_http_factory, web_client, registry=None, now=None) -> list[dict]:
    registry, now = registry or REGISTRY, now or now_utc()
    out: list[dict] = []
    ds, inst = cfg["dataset"], cfg["instruments"]
    cols = header[1:]
    eq_cols = [c for c in cols if c not in inst and is_equity(c, ds["stock_pattern"])]
    idx_cols = {c: inst[c]["idx_index_code"] for c in cols if inst.get(c, {}).get("provider") == "idx_index"}

    # ---- IDX (index + stocks) ----
    try:
        today = now.astimezone(WIB).date()
        days = [d for d in weekdays_between(today - dt.timedelta(days=7), today)][-4:]
        vals, trading, _ = fetch_idx(days, eq_cols, idx_cols, idx_http_factory())
        got_days = sorted(trading)
        for c in idx_cols:
            ser = [(d, vals[d][c]) for d in got_days if c in vals.get(d, {})]
            if ser:
                out.append({"source": c, "provider": "idx_index", "ok": True, "rows": len(ser), "last_date": str(ser[-1][0]), "last_value": ser[-1][1], "note": f"trading days seen: {len(got_days)} of {len(days)} weekdays"})
            else:
                out.append({"source": c, "provider": "idx_index", "ok": False, "error": "IDX reachable but returned no index rows for the last weekdays (holiday window?)"})
        if got_days:
            last = got_days[-1]
            n = sum(1 for c in eq_cols if c in vals.get(last, {}))
            out.append({"source": f"{len(eq_cols)} IDX stock codes", "provider": "idx_stock", "ok": n > 0, "rows": n, "last_date": str(last),
                        "note": f"{n} of {len(eq_cols)} codes returned a close" + ("" if n == len(eq_cols) else "; missing: " + ", ".join(stock_code(c) for c in eq_cols if c not in vals.get(last, {}))[:150])})
    except Exception as e:  # noqa: BLE001
        out.append({"source": "IDX (JCI + stocks)", "provider": "idx", "ok": False, "error": _err(e)})

    # ---- web sources through the registry ----
    ctx = {"env": env, "http": web_client, "phei_store": None, "now": now}
    for c in cols:
        sp = inst.get(c)
        if not sp or sp["provider"] in ("idx_index", "idx_stock"):
            continue
        try:
            if sp["provider"] == "phei":
                p = parse_phei(web_client.get_text("https://www.phei.co.id/en-us/Data/Bond-Indexes"), sp.get("row_name", "INDOBeX Government Clean Price"))
                out.append({"source": c, "provider": "phei", "ok": True, "rows": 2, "last_date": str(p["date"]), "last_value": p["last"], "note": f"previous={p['previous']} (page shows ONE day only)"})
                continue
            s = registry[sp["provider"]](c, sp, ctx)
            out.append({"source": c, "provider": sp["provider"], "ok": True, "rows": int(len(s)), "last_date": str(s.index.max()), "last_value": float(s.iloc[-1]),
                        "note": f"oldest in feed: {s.index.min()}"})
        except Exception as e:  # noqa: BLE001
            out.append({"source": c, "provider": sp["provider"], "ok": False, "error": _err(e)})
    return out


def to_markdown(rows: list[dict]) -> str:
    ok = sum(r["ok"] for r in rows)
    lines = [f"## Export probe: {ok}/{len(rows)} sources OK", "", "| source | provider | result | rows | newest | value | note |", "|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['source']} | {r['provider']} | {'OK' if r['ok'] else 'FAIL'} | {r.get('rows', '')} | {r.get('last_date', '')} | {r.get('last_value', '')} | {r.get('error') or r.get('note', '')} |")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", default="seed/raw_data.xlsx")
    a = ap.parse_args(argv)
    cfg = load_config()
    header = read_state(a.seed, cfg["dataset"]["dedupe_policy"])["header"]
    try:
        from .http import WebClient
        from .providers.idx import IdxHttp
        client = WebClient()
        idx_factory = IdxHttp
    except Exception as e:  # noqa: BLE001
        print(f"cannot start HTTP client: {_err(e)}")
        return 1
    rows = probe(cfg, header, os.environ, idx_factory, client)
    md = to_markdown(rows)
    print(md)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(md + "\n")
    return 0 if all(r["ok"] for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
