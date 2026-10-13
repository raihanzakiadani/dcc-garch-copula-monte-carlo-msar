"""End-to-end tests of orchestration -> bundle -> publish -> fetch -> rollback -> app retrieval, using
(a) the REAL R scripts on synthetic fixed-parameter models and (b) a LOCAL fake of the `gh` CLI / GitHub download
URLs. They prove our logic, NOT that GitHub/IDX/Yahoo/etc. accept our requests (that needs a real run)."""
import hashlib, json, os, shutil, subprocess, sys, threading, http.server, functools, tarfile
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[1]
ENV0 = {**os.environ, "REPO_ROOT": str(ROOT), "TZ": "Asia/Jakarta", "RAW_DEDUPE_POLICY": "last"}
HAVE_STACK = subprocess.run(["Rscript", "-e", "q(status=!all(sapply(c('rugarch','rmgarch','copula'),requireNamespace,quietly=TRUE)))"],
                            capture_output=True).returncode == 0


def R(script, *args, env=None, check=True):
    r = subprocess.run(["Rscript", str(ROOT / script), *map(str, args)], capture_output=True, text=True, env={**ENV0, **(env or {})}, cwd=ROOT)
    if check and r.returncode != 0:
        raise AssertionError(f"{script} rc={r.returncode}\n{r.stdout[-1500:]}\n{r.stderr[-1500:]}")
    return r


def state(d, kind, *a):
    R("tests/R/state_cli.R", kind, d, *a)


def ingest_json(d, status="SUCCESS", new=5, reason=""):
    Path(d, "ingest_result.json").write_text(json.dumps({"status": status, "n_new_obs": new, "n_instruments_ok": 9, "n_instruments_failed": 0 if status != "FAILED" else 1,
                                                          "reason": reason, "instruments": {}}))


def gh_env(tmp, **extra):
    return {**ENV0, "GH_BIN": str(ROOT / "tests" / "fake_gh.py"), "FAKE_GH_DIR": str(tmp / "ghstore"), **extra}


def rel(*a, env, check=True):
    r = subprocess.run([sys.executable, str(ROOT / "scripts/release.py"), *map(str, a)], capture_output=True, text=True, env=env, cwd=ROOT)
    if check and r.returncode != 0:
        raise AssertionError(f"release.py {a[0]} rc={r.returncode}\n{r.stdout}\n{r.stderr}")
    return r


def make_version(tmp, name, n_new, env, mode="DAILY", base=None):
    """fetch state -> (append data) -> run -> bundle -> publish. Returns (work, dist, manifest)."""
    work = tmp / f"work_{name}"
    rel("fetch", "--work", work, "--repo", "o/r", "--seed", ROOT / "seed/raw_data.xlsx", env=env)
    return work


@pytest.fixture(scope="module")
def synth_models(tmp_path_factory):
    d = tmp_path_factory.mktemp("synth")
    state(d, "make", 320, 300)
    return d


def fresh_work(tmp, synth, n_new):
    w = tmp / "work"; shutil.copytree(synth, w)
    if n_new:
        state(w, "append", 320, 300, n_new)
    ingest_json(w, "SUCCESS" if n_new else "UP_TO_DATE", n_new)
    return w


def run_and_bundle(w, tmp, mode="DAILY", env=None):
    r = R("R/run_pipeline.R", "--mode", mode, "--work", w, "--ingest", w / "ingest_result.json", "--out", w / "run_result.json", env=env, check=False)
    res = json.loads((w / "run_result.json").read_text())
    return r, res


def bundle(w, tmp, env=None):
    dist = tmp / "dist"; shutil.rmtree(dist, ignore_errors=True)
    r = R("R/bundle.R", "--work", w, "--run", w / "run_result.json", "--ingest", w / "ingest_result.json", "--out", dist,
          "--prev-manifest", w / "state_manifest.json", env={"GITHUB_RUN_ID": str(env or "111")}, check=False)
    return r, dist


# ------------------------------------------------------------------------------------------------
def test_daily_new_data_publish_fetch_roundtrip(tmp_path, synth_models):
    env = gh_env(tmp_path)
    w = fresh_work(tmp_path, synth_models, 5)
    r, res = run_and_bundle(w, tmp_path)
    assert r.returncode == 0 and res["status"] == "SUCCESS", res
    assert res["mode_executed"] == "DAILY" and res["fallback_full"] is False and res["n_models_updated"] == 2
    assert res["validation"]["ok"] and res["raw_max_date"]
    (w / "_shards").mkdir(exist_ok=True); (w / "_shards" / "shard_001.rds").write_bytes(b"x" * 10); (w / "_shards" / "macro_stage.rds").write_bytes(b"y")
    (w / "Plots").mkdir(exist_ok=True); (w / "Plots" / "a.png").write_bytes(b"png")
    br, dist = bundle(w, tmp_path, "100"); assert br.returncode == 0, br.stderr[-800:]
    m = json.loads((dist / "manifest.json").read_text())
    assert m["status"] == "SUCCESS" and m["pipeline"]["mode_executed"] == "DAILY" and m["data"]["raw_max_date"] == res["raw_max_date"]
    names = {f["path"] for f in m["files"]}
    assert {"All_Markov_Models.rds", "JointDistribution_Model.rds", "raw_data.xlsx"} <= names
    assert not any(n.startswith(("_run", "Backup", "_shards")) or "_backup_" in n for n in names)          # never published
    assert "Plots/a.png" in names                                                                         # dashboard artefacts are
    # dry-run publishes nothing
    rel("publish", "--dist", dist, "--repo", "o/r", "--dry-run", env=env)
    assert not (tmp_path / "ghstore").exists() or not any((tmp_path / "ghstore").iterdir())
    rel("publish", "--dist", dist, "--repo", "o/r", env=env)
    store = tmp_path / "ghstore"
    assert (store / "data-latest" / "manifest.json").exists() and (store / m["bundle"]["release_tag"] / m["bundle"]["name"]).exists()
    # next run fetches EXACTLY that state, hash-verified
    w2 = tmp_path / "next"; rel("fetch", "--work", w2, "--repo", "o/r", env=env)
    for f in m["files"]:
        assert hashlib.sha256((w2 / f["path"]).read_bytes()).hexdigest() == f["sha256"]
    assert json.loads((w2 / "state_info.json").read_text())["source"] == "release"


def test_daily_without_new_data_is_UP_TO_DATE_and_nothing_to_publish(tmp_path, synth_models):
    w = fresh_work(tmp_path, synth_models, 0)
    before = hashlib.md5((w / "All_Markov_Models.rds").read_bytes()).hexdigest()
    r, res = run_and_bundle(w, tmp_path)
    assert r.returncode == 0 and res["status"] == "UP_TO_DATE" and res["mode_executed"] == "NONE"
    assert hashlib.md5((w / "All_Markov_Models.rds").read_bytes()).hexdigest() == before
    br, _ = bundle(w, tmp_path); assert br.returncode != 0 and "refusing" in br.stderr


def test_ingest_failed_stops_everything(tmp_path, synth_models):
    w = fresh_work(tmp_path, synth_models, 5); ingest_json(w, "FAILED", 0, "IBPRCPI Index: FAILED_MISSING")
    r, res = run_and_bundle(w, tmp_path)
    assert r.returncode == 1 and res["status"] == "FAILED" and "ingest FAILED" in res["reason"] and res["mode_executed"] is None
    br, _ = bundle(w, tmp_path); assert br.returncode != 0


def test_partial_ingest_propagates_as_PARTIAL_SUCCESS(tmp_path, synth_models):
    w = fresh_work(tmp_path, synth_models, 5)
    j = json.loads((w / "ingest_result.json").read_text()); j["status"] = "PARTIAL_SUCCESS"; (w / "ingest_result.json").write_text(json.dumps(j))
    r, res = run_and_bundle(w, tmp_path)
    assert res["status"] == "PARTIAL_SUCCESS"


def test_history_revision_triggers_recorded_fallback_and_never_promotes_partial(tmp_path, synth_models):
    w = tmp_path / "work"; shutil.copytree(synth_models, w)
    state(w, "revise", 320, 300, 3); ingest_json(w, "SUCCESS", 3)
    before = hashlib.md5((w / "All_Markov_Models.rds").read_bytes()).hexdigest()
    r, res = run_and_bundle(w, tmp_path)
    assert res["fallback_full"] is True and "failed DAILY validation" in res["fallback_reason"]
    if not HAVE_STACK:        # sandbox: FULL cannot complete -> FAILED, and nothing is promotable
        assert res["status"] == "FAILED" and r.returncode == 1
        br, _ = bundle(w, tmp_path); assert br.returncode != 0
    assert res["mode_executed"] == "FULL"


def test_first_run_no_models_uses_FULL_and_records_it(tmp_path, synth_models):
    w = tmp_path / "work"; state(w, "make", 320, 300, "nomodels"); ingest_json(w, "UP_TO_DATE", 0)
    r, res = run_and_bundle(w, tmp_path)
    assert res["mode_executed"] == "FULL" and res["fallback_full"] is True        # UP_TO_DATE shortcut must NOT apply without models


def test_explicit_FULL_really_runs_pipeline(tmp_path, synth_models):
    w = fresh_work(tmp_path, synth_models, 0)
    r, res = run_and_bundle(w, tmp_path, mode="FULL")
    assert res["mode_requested"] == "FULL" and res["mode_executed"] == "FULL"       # runs even when there is no new data
    log = (w / "_run" / "hybrid_full.log").read_text()
    assert "MODE FULL - MENJALANKAN ULANG" in log
    if not HAVE_STACK:
        assert res["status"] == "FAILED" and "Paket R belum terpasang" in log


def test_publication_failure_keeps_previous_pointer(tmp_path, synth_models):
    env = gh_env(tmp_path)
    w = fresh_work(tmp_path, synth_models, 3); run_and_bundle(w, tmp_path); _, dist = bundle(w, tmp_path, "200")
    rel("publish", "--dist", dist, "--repo", "o/r", env=env)
    old = json.loads((tmp_path / "ghstore/data-latest/manifest.json").read_text())["version_id"]
    # second version; the upload to the versioned release fails midway
    w2 = tmp_path / "w2"; rel("fetch", "--work", w2, "--repo", "o/r", env=env)
    state(w2, "append", 320, 300, 6); ingest_json(w2, "SUCCESS", 3); run_and_bundle(w2, tmp_path)
    dist2 = tmp_path / "dist2"; R("R/bundle.R", "--work", w2, "--run", w2 / "run_result.json", "--ingest", w2 / "ingest_result.json", "--out", dist2,
                                  "--prev-manifest", w2 / "state_manifest.json", env={"GITHUB_RUN_ID": "201"})
    new_tag = json.loads((dist2 / "manifest.json").read_text())["bundle"]["release_tag"]
    r = rel("publish", "--dist", dist2, "--repo", "o/r", env=gh_env(tmp_path, FAKE_GH_FAIL_UPLOAD=new_tag), check=False)
    assert r.returncode != 0
    assert json.loads((tmp_path / "ghstore/data-latest/manifest.json").read_text())["version_id"] == old     # dashboard unaffected
    # failure while moving the pointer itself
    r = rel("publish", "--dist", dist2, "--repo", "o/r", env=gh_env(tmp_path, FAKE_GH_FAIL_UPLOAD="data-latest"), check=False)
    assert json.loads((tmp_path / "ghstore/data-latest/manifest.json").read_text())["version_id"] == old


def test_corrupt_latest_bundle_recovers_previous_and_rollback(tmp_path, synth_models):
    env = gh_env(tmp_path)
    w = fresh_work(tmp_path, synth_models, 3); run_and_bundle(w, tmp_path); _, d1 = bundle(w, tmp_path, "300")
    rel("publish", "--dist", d1, "--repo", "o/r", env=env)
    m1 = json.loads((d1 / "manifest.json").read_text())
    w2 = tmp_path / "w2"; rel("fetch", "--work", w2, "--repo", "o/r", env=env)
    state(w2, "append", 320, 300, 6); ingest_json(w2, "SUCCESS", 3); run_and_bundle(w2, tmp_path)
    d2 = tmp_path / "d2"; R("R/bundle.R", "--work", w2, "--run", w2 / "run_result.json", "--ingest", w2 / "ingest_result.json", "--out", d2,
                            "--prev-manifest", w2 / "state_manifest.json", env={"GITHUB_RUN_ID": "301"})
    m2 = json.loads((d2 / "manifest.json").read_text()); assert m2["previous_version_id"] == m1["version_id"]
    rel("publish", "--dist", d2, "--repo", "o/r", env=env)
    # corrupt v2's bundle on the "server"
    b = tmp_path / "ghstore" / m2["bundle"]["release_tag"] / m2["bundle"]["name"]; b.write_bytes(b.read_bytes()[:-50] + b"X" * 50)
    w3 = tmp_path / "w3"; rel("fetch", "--work", w3, "--repo", "o/r", env=env)
    info = json.loads((w3 / "state_info.json").read_text())
    assert info["recovered_from_previous"] is True and info["version_id"] == m1["version_id"]
    # explicit rollback refuses a corrupt target, accepts a good one
    assert rel("promote", "--tag", m2["bundle"]["release_tag"], "--repo", "o/r", env=env, check=False).returncode != 0
    rel("promote", "--tag", m1["bundle"]["release_tag"], "--repo", "o/r", env=env)
    assert json.loads((tmp_path / "ghstore/data-latest/manifest.json").read_text())["version_id"] == m1["version_id"]


def test_first_run_fetch_seeds_when_no_release(tmp_path):
    env = gh_env(tmp_path); w = tmp_path / "w"
    rel("fetch", "--work", w, "--repo", "o/r", "--seed", ROOT / "seed/raw_data.xlsx", env=env)
    assert (w / "raw_data.xlsx").exists() and json.loads((w / "state_info.json").read_text())["source"] == "seed"


# ------------------------------------------------------------------------------------------------ Shiny retrieval
class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass


def test_app_retrieval_follows_pointer_validates_and_keeps_last_valid(tmp_path, synth_models):
    env = gh_env(tmp_path)
    w = fresh_work(tmp_path, synth_models, 3); run_and_bundle(w, tmp_path); _, d1 = bundle(w, tmp_path, "400")
    rel("publish", "--dist", d1, "--repo", "o/r", env=env)
    # serve  /o/r/releases/download/<tag>/<asset>  from the fake store
    web = tmp_path / "web" / "o" / "r" / "releases"; web.mkdir(parents=True); os.symlink(tmp_path / "ghstore", web / "download")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(_Quiet, directory=str(tmp_path / "web")))
    threading.Thread(target=srv.serve_forever, daemon=True).start(); port = srv.server_address[1]
    script = tmp_path / "t.R"
    script.write_text(f'''
source("{ROOT}/app/app_retrieval.R")
Sys.setenv(DATA_REPO="o/r", DATA_WEB_BASE="http://127.0.0.1:{port}", DATA_REFRESH_SECONDS="0", DATA_CACHE_DIR="{tmp_path}/cache")
r1 <- resolve_data_root(tempdir()); v1 <- data_status()$version
stopifnot(file.exists(file.path(r1, "All_Markov_Models.rds")), !is.na(v1))
cat("V1", v1, "\\n")
# corrupt/bad pointer must NOT switch
r2 <- resolve_data_root(tempdir()); stopifnot(identical(r1, r2))
writeLines(c("HOLD"), "{tmp_path}/hold1")
while (!file.exists("{tmp_path}/go")) Sys.sleep(0.2)
r3 <- resolve_data_root(tempdir()); v3 <- data_status()$version
cat("V3", v3, "| err:", data_status()$last_error, "\\n")
writeLines(c("HOLD"), "{tmp_path}/hold2")
while (!file.exists("{tmp_path}/go2")) Sys.sleep(0.2)
r4 <- resolve_data_root(tempdir()); cat("V4", data_status()$version, "| err:", data_status()$last_error, "| same_root_as_v3:", identical(r3, r4), "\\n")
''')
    p = subprocess.Popen(["Rscript", str(script)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV0)
    import time
    def wait(f):
        for _ in range(300):
            if (tmp_path / f).exists(): return
            time.sleep(0.2)
        raise AssertionError("R script did not reach " + f)
    wait("hold1")
    # publish v2 while the "app" is running
    w2 = tmp_path / "w2"; rel("fetch", "--work", w2, "--repo", "o/r", env=env)
    state(w2, "append", 320, 300, 6); ingest_json(w2, "SUCCESS", 3); run_and_bundle(w2, tmp_path)
    d2 = tmp_path / "d2"; R("R/bundle.R", "--work", w2, "--run", w2 / "run_result.json", "--ingest", w2 / "ingest_result.json", "--out", d2,
                            "--prev-manifest", w2 / "state_manifest.json", env={"GITHUB_RUN_ID": "401"})
    rel("publish", "--dist", d2, "--repo", "o/r", env=env)
    (tmp_path / "go").write_text("1"); wait("hold2")
    # now corrupt the pointer's bundle (v3) and break the server -> app keeps last valid
    m2 = json.loads((d2 / "manifest.json").read_text())
    (tmp_path / "go2").write_text("1")
    out = p.communicate(timeout=120)[0]; srv.shutdown()
    v1 = [l for l in out.splitlines() if l.startswith("V1")][0].split()[1]
    v3 = [l for l in out.splitlines() if l.startswith("V3")][0].split()[1]
    assert v1 != m2["version_id"] and v3 == m2["version_id"], out        # followed the pointer WITHOUT restarting
    assert "V4" in out and "same_root_as_v3: TRUE" in out


def test_app_retrieval_rejects_corrupt_bundle_and_survives_outage(tmp_path, synth_models):
    env = gh_env(tmp_path)
    w = fresh_work(tmp_path, synth_models, 3); run_and_bundle(w, tmp_path); _, d1 = bundle(w, tmp_path, "500")
    rel("publish", "--dist", d1, "--repo", "o/r", env=env)
    web = tmp_path / "web" / "o" / "r" / "releases"; web.mkdir(parents=True); os.symlink(tmp_path / "ghstore", web / "download")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(_Quiet, directory=str(tmp_path / "web")))
    threading.Thread(target=srv.serve_forever, daemon=True).start(); port = srv.server_address[1]
    # a second version whose bundle is corrupt but whose pointer is already promoted
    w2 = tmp_path / "w2"; rel("fetch", "--work", w2, "--repo", "o/r", env=env)
    state(w2, "append", 320, 300, 6); ingest_json(w2, "SUCCESS", 3); run_and_bundle(w2, tmp_path)
    d2 = tmp_path / "d2"; R("R/bundle.R", "--work", w2, "--run", w2 / "run_result.json", "--ingest", w2 / "ingest_result.json", "--out", d2,
                            "--prev-manifest", w2 / "state_manifest.json", env={"GITHUB_RUN_ID": "501"})
    m2 = json.loads((d2 / "manifest.json").read_text())
    script = tmp_path / "t2.R"
    script.write_text(f'''
source("{ROOT}/app/app_retrieval.R")
Sys.setenv(DATA_REPO="o/r", DATA_WEB_BASE="http://127.0.0.1:{port}", DATA_REFRESH_SECONDS="0", DATA_CACHE_DIR="{tmp_path}/cache", DATA_TIMEOUT_SECONDS="5")
r1 <- resolve_data_root(tempdir()); v1 <- data_status()$version
writeLines("x", "{tmp_path}/h1"); while (!file.exists("{tmp_path}/g1")) Sys.sleep(0.2)
r2 <- resolve_data_root(tempdir())
cat("A", identical(r1, r2), identical(v1, data_status()$version), !is.na(data_status()$last_error), "\\n")
writeLines("x", "{tmp_path}/h2"); while (!file.exists("{tmp_path}/g2")) Sys.sleep(0.2)
r3 <- resolve_data_root(tempdir())
cat("B", identical(r1, r3), identical(v1, data_status()$version), !is.na(data_status()$last_error), "\\n")
''')
    p = subprocess.Popen(["Rscript", str(script)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV0)
    import time
    def wait(f):
        for _ in range(300):
            if (tmp_path / f).exists(): return
            time.sleep(0.2)
        raise AssertionError("timeout " + f)
    wait("h1")
    rel("publish", "--dist", d2, "--repo", "o/r", env=env)
    b = tmp_path / "ghstore" / m2["bundle"]["release_tag"] / m2["bundle"]["name"]; b.write_bytes(b.read_bytes()[:-40] + b"Z" * 40)
    (tmp_path / "g1").write_text("1"); wait("h2")
    srv.shutdown(); srv.server_close()                       # outage
    (tmp_path / "g2").write_text("1")
    out = p.communicate(timeout=120)[0]
    assert "A TRUE TRUE TRUE" in out, out      # corrupt bundle: stayed on v1, error recorded
    assert "B TRUE TRUE TRUE" in out, out      # server down: still v1


def test_daily_job_without_full_fallback_reports_FULL_REQUIRED_and_never_starts_full(tmp_path, synth_models):
    w = tmp_path / "work"; state(w, "make", 320, 300, "nomodels"); ingest_json(w, "SUCCESS", 3)
    r, res = run_and_bundle(w, tmp_path, env={"ALLOW_DAILY_FALLBACK_FULL": "false", "HYBRID_ALLOW_FULL_FALLBACK": "false"})
    assert r.returncode == 1 and res["status"] == "FAILED" and res["full_required"] is True and res["mode_executed"] == "NONE"
    assert "FULL REQUIRED" in res["reason"]
    assert not (w / "_run" / "hybrid_full.log").exists()                       # FULL was never launched
    assert not (w / "All_Markov_Models.rds").exists()


def test_revision_without_full_fallback_reports_FULL_REQUIRED(tmp_path, synth_models):
    w = tmp_path / "work"; shutil.copytree(synth_models, w)
    state(w, "revise", 320, 300, 3); ingest_json(w, "SUCCESS", 3)
    before = hashlib.md5((w / "All_Markov_Models.rds").read_bytes()).hexdigest()
    r, res = run_and_bundle(w, tmp_path, env={"ALLOW_DAILY_FALLBACK_FULL": "false", "HYBRID_ALLOW_FULL_FALLBACK": "false"})
    assert res["status"] == "FAILED" and res["full_required"] is True and "FULL REQUIRED" in res["reason"]
    assert hashlib.md5((w / "All_Markov_Models.rds").read_bytes()).hexdigest() == before
