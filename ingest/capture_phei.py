"""python -m ingest.capture_phei --store state/phei_history.csv   (run EVERY weekday evening, before anything else)."""
import argparse
import json
import sys

from .common import load_config, log
from .http import WebClient
from .phei_store import record
from .providers.web import parse_phei


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args(argv)
    cfg = load_config()
    url = "https://www.phei.co.id/en-us/Data/Bond-Indexes"
    row = cfg["instruments"]["IBPRCPI Index"].get("row_name", "INDOBeX Government Clean Price")
    try:
        parsed = parse_phei(WebClient().get_text(url), row)
        res = record(a.store, parsed)
        out = {"ok": True, "date": parsed["date"].isoformat(), "last": parsed["last"], **res}
        log("INFO", "PHEI captured", date=out["date"], last=out["last"], added=len(res["added"]), revisions=len(res["revisions"]))
        rc = 0
    except Exception as e:  # noqa: BLE001
        out = {"ok": False, "error": f"{type(e).__name__}: {e}"}
        log("ERROR", "PHEI capture failed", err=out["error"])
        rc = 1
    if a.out:
        open(a.out, "w").write(json.dumps(out, indent=2))
    return rc


if __name__ == "__main__":
    sys.exit(main())
