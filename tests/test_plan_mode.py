import datetime as dt, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from plan_mode import plan
U = dt.timezone.utc
P = dict(repo="me/x", expected_repo="me/x", ref="main", default_branch="main", allow_hosted_full=True)


def test_cron_1800_wib_is_1100_utc_same_date_and_friday_is_full():
    fri = dt.datetime(2026, 10, 9, 11, 0, tzinfo=U)          # Fri 18:00 WIB
    assert plan("schedule", {}, fri, **P)["mode"] == "FULL"
    assert plan("schedule", {}, dt.datetime(2026, 10, 8, 11, 0, tzinfo=U), **P)["mode"] == "DAILY"


def test_delayed_run_still_uses_wib_day():
    late_fri = dt.datetime(2026, 10, 9, 16, 59, tzinfo=U)    # 23:59 WIB Friday (very late) -> still Friday
    assert plan("schedule", {}, late_fri, **P)["mode"] == "FULL"
    sat_wib = dt.datetime(2026, 10, 9, 17, 5, tzinfo=U)      # 00:05 WIB Saturday: not Friday anymore
    assert plan("schedule", {}, sat_wib, **P)["mode"] == "DAILY"


def test_manual_defaults_to_dry_run_and_respects_mode():
    r = plan("workflow_dispatch", {"mode": "FULL"}, dt.datetime(2026, 10, 8, 3, tzinfo=U), **P)
    assert r["mode"] == "FULL" and r["dry_run"] is True
    assert plan("workflow_dispatch", {"mode": "DAILY", "dry_run": "false"}, dt.datetime(2026, 10, 8, 3, tzinfo=U), **P)["dry_run"] is False


def test_wrong_repo_or_branch_guards():
    now = dt.datetime(2026, 10, 8, 11, tzinfo=U)
    assert plan("schedule", {}, now, **{**P, "repo": "fork/x"})["ok"] is False
    assert plan("schedule", {}, now, **{**P, "expected_repo": ""})["ok"] is False
    r = plan("workflow_dispatch", {"mode": "DAILY", "dry_run": "false"}, now, **{**P, "ref": "feature"})
    assert r["dry_run"] is True and r["ok"]


def test_strategies():
    fri, thu = dt.datetime(2026, 10, 9, 11, 0, tzinfo=U), dt.datetime(2026, 10, 8, 11, 0, tzinfo=U)
    Q = {**P, "allow_hosted_full": False}
    r = plan("schedule", {}, fri, **Q)                                             # nothing configured
    assert r["mode"] == "DAILY" and r["strategy"] == "skipped" and r["full_skipped"] and r["timeout"] == 350
    r = plan("schedule", {}, fri, **{**Q, "full_shards": 12})                      # sharded on hosted runners
    assert (r["mode"], r["strategy"], r["shards"], r["runner"], r["timeout"]) == ("FULL", "sharded", 12, "ubuntu-24.04", 350)
    assert r["matrix"] == list(range(1, 13))
    r = plan("schedule", {}, fri, **{**Q, "full_runner": "my-vps"})                # self-hosted monolith
    assert (r["strategy"], r["runner"], r["timeout"], r["matrix"]) == ("monolith", "my-vps", 7000, [])
    r = plan("schedule", {}, fri, **{**Q, "full_runner": "my-vps", "full_shards": 8})
    assert r["strategy"] == "sharded"                                              # explicit sharding wins
    assert plan("workflow_dispatch", {"mode": "FULL"}, fri, **Q)["ok"] is False    # manual FULL with nothing configured
    r = plan("schedule", {}, thu, **{**Q, "full_shards": 12})
    assert (r["mode"], r["strategy"], r["matrix"]) == ("DAILY", "daily", [])      # other days stay cheap


def test_bad_shard_counts_are_rejected():
    now = dt.datetime(2026, 10, 9, 11, tzinfo=U)
    for n in (1, 101, 500):
        assert plan("schedule", {}, now, **{**P, "allow_hosted_full": False, "full_shards": n})["ok"] is False


def test_daily_never_allows_full_fallback_on_hosted():
    now = dt.datetime(2026, 10, 8, 11, tzinfo=U)
    assert plan("schedule", {}, now, **{**P, "allow_hosted_full": True})["allow_daily_fallback"] is False
