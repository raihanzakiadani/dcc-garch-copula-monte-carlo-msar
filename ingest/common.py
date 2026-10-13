"""Shared helpers: config, time (WIB/UTC), status constants, structured logging."""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo

WIB = ZoneInfo("Asia/Jakarta")
UTC = ZoneInfo("UTC")

SUCCESS = "SUCCESS"
PARTIAL_SUCCESS = "PARTIAL_SUCCESS"
FAILED = "FAILED"
UP_TO_DATE = "UP_TO_DATE"

REPO_ROOT = Path(__file__).resolve().parents[1]


def load_config(path: str | os.PathLike | None = None) -> dict:
    p = Path(path or os.environ.get("PIPELINE_CONFIG") or REPO_ROOT / "config" / "pipeline.json")
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def now_utc() -> dt.datetime:
    return dt.datetime.now(tz=UTC)


def fmt_both(ts: dt.datetime) -> dict:
    return {"utc": ts.astimezone(UTC).isoformat(timespec="seconds"),
            "wib": ts.astimezone(WIB).isoformat(timespec="seconds")}


def log(level: str, msg: str, **kv) -> None:
    extra = " ".join(f"{k}={v}" for k, v in kv.items())
    print(f"[{now_utc().astimezone(WIB).strftime('%Y-%m-%d %H:%M:%S')} WIB] {level:<5} {msg} {extra}".rstrip(),
          file=sys.stderr if level in ("ERROR", "WARN") else sys.stdout, flush=True)


class ProviderError(RuntimeError):
    """Source unreachable / malformed. Distinct from 'no data for that day'."""


@dataclass
class InstrumentResult:
    name: str
    required: bool
    provider: str
    status: str = "PENDING"          # OK_NEW | OK_NO_NEW | FAILED | FAILED_ANCHOR | FAILED_MISSING
    detail: str = ""
    last_value_date: str | None = None
    n_new_values: int = 0
    n_carried: int = 0
    diag: dict = field(default_factory=dict)


@dataclass
class IngestResult:
    started: dict = field(default_factory=dict)
    finished: dict = field(default_factory=dict)
    last_date_before: str | None = None
    last_date_after: str | None = None
    new_dates: list = field(default_factory=list)
    blocked_dates: list = field(default_factory=list)
    row_limit: str | None = None
    warnings: list = field(default_factory=list)
    revisions: list = field(default_factory=list)
    instruments: dict = field(default_factory=dict)
    status: str = "PENDING"
    reason: str = ""

    def to_json(self) -> dict:
        d = self.__dict__.copy()
        d["instruments"] = {k: v.__dict__ for k, v in self.instruments.items()}
        d["n_instruments_ok"] = sum(1 for v in self.instruments.values() if not v.status.startswith("FAILED"))
        d["n_instruments_failed"] = sum(1 for v in self.instruments.values() if v.status.startswith("FAILED"))
        d["n_new_obs"] = len(self.new_dates)
        return d
