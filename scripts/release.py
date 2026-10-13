#!/usr/bin/env python3
"""Artifact store on GitHub Releases (uses the `gh` CLI; GH_BIN overrides for tests).

Layout
  release  data-<version_id>   immutable: bundle-<version_id>.tar.gz + manifest.json
  release  data-latest         mutable POINTER: only manifest.json, uploaded LAST (= atomic promotion)
  release  phei-history        mutable: phei_history.csv (PHEI shows one day only, so it is stored separately)

  release.py fetch   --work work --repo O/R --seed seed/raw_data.xlsx
  release.py publish --dist dist --repo O/R [--dry-run] [--keep 14]
  release.py phei-push --store work/phei_history.csv --repo O/R
  release.py promote --tag data-<version_id> --repo O/R        (rollback)
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, tarfile, tempfile
from pathlib import Path

GH = os.environ.get("GH_BIN", "gh")
LATEST = "data-latest"
PHEI_TAG = "phei-history"


def gh(*a, check=True, capture=True):
    r = subprocess.run([GH, *a], capture_output=capture, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"gh {' '.join(a[:3])} failed: {(r.stderr or r.stdout).strip()[:300]}")
    return r


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def exists(repo, tag):
    return gh("release", "view", tag, "--repo", repo, "--json", "tagName", check=False).returncode == 0


def download(repo, tag, pattern, d):
    Path(d).mkdir(parents=True, exist_ok=True)
    gh("release", "download", tag, "--repo", repo, "--pattern", pattern, "--dir", str(d), "--clobber")


def load_version(repo, tag, dest):
    """download + verify a version bundle; returns manifest. Raises on any hash mismatch."""
    tmp = Path(tempfile.mkdtemp())
    download(repo, tag, "manifest.json", tmp)
    m = json.loads((tmp / "manifest.json").read_text())
    download(repo, tag, m["bundle"]["name"], tmp)
    b = tmp / m["bundle"]["name"]
    if sha256(b) != m["bundle"]["sha256"]:
        raise RuntimeError(f"bundle sha256 mismatch for {tag}")
    ex = tmp / "x"; ex.mkdir()
    with tarfile.open(b) as t:
        t.extractall(ex)                      # noqa: S202 (our own, hash-verified archive)
    for f in m["files"]:
        p = ex / f["path"]
        if not p.exists() or sha256(p) != f["sha256"]:
            raise RuntimeError(f"file hash mismatch in {tag}: {f['path']}")
    dest = Path(dest); dest.mkdir(parents=True, exist_ok=True)
    for f in m["files"]:
        (dest / f["path"]).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ex / f["path"], dest / f["path"])
    shutil.rmtree(tmp, ignore_errors=True)
    return m


def cmd_fetch(a):
    work = Path(a.work); work.mkdir(parents=True, exist_ok=True)
    info = {"source": None, "version_id": None, "recovered_from_previous": False}
    if exists(a.repo, LATEST):
        tmp = Path(tempfile.mkdtemp()); download(a.repo, LATEST, "manifest.json", tmp)
        ptr = json.loads((tmp / "manifest.json").read_text())
        tag, tried = ptr["bundle"]["release_tag"], []
        while tag and tag not in tried:
            tried.append(tag)
            try:
                m = load_version(a.repo, tag, work)
                (work / "state_manifest.json").write_text(json.dumps(m))
                info.update(source="release", version_id=m["version_id"], recovered_from_previous=len(tried) > 1)
                break
            except Exception as e:  # noqa: BLE001
                print(f"WARN: state {tag} unusable ({e}); trying previous version", file=sys.stderr)
                prev = None
                try:
                    t2 = Path(tempfile.mkdtemp()); download(a.repo, tag, "manifest.json", t2)
                    pv = json.loads((t2 / "manifest.json").read_text()).get("previous_version_id")
                    prev = f"data-{pv}" if pv else None
                except Exception:  # noqa: BLE001
                    pass
                tag = prev
        else:
            raise SystemExit("ERROR: no valid previous state could be restored")
        if info["source"] is None:
            raise SystemExit("ERROR: no valid previous state could be restored")
    else:
        if not Path(a.seed).exists():
            raise SystemExit("ERROR: no data-latest release and no seed file")
        shutil.copy2(a.seed, work / "raw_data.xlsx")
        info.update(source="seed")
        print("NOTE: first run - seeded from", a.seed, "(no models: DAILY will fall back to FULL, recorded)")
    if exists(a.repo, PHEI_TAG):
        try:
            download(a.repo, PHEI_TAG, "phei_history.csv", work)
        except RuntimeError:
            pass
    seed_phei = Path(a.seed).with_name("phei_history.csv")
    if not (work / "phei_history.csv").exists() and seed_phei.exists():
        shutil.copy2(seed_phei, work / "phei_history.csv")          # 2 real PHEI values (8 & 9 Oct 2026) so IBPRCPI can be chained
    (work / "state_info.json").write_text(json.dumps(info))
    print(json.dumps(info))


def cmd_publish(a):
    dist = Path(a.dist); m = json.loads((dist / "manifest.json").read_text())
    tag, bundle = m["bundle"]["release_tag"], dist / m["bundle"]["name"]
    if sha256(bundle) != m["bundle"]["sha256"]:
        raise SystemExit("ERROR: bundle changed after manifest was written")
    if a.dry_run:
        print(f"[DRY RUN] would create {tag}, upload {bundle.name} + manifest.json, then point {LATEST} at it; nothing published")
        return
    if exists(a.repo, tag):
        raise SystemExit(f"ERROR: {tag} already exists (versions are immutable)")
    gh("release", "create", tag, str(bundle), str(dist / "manifest.json"), "--repo", a.repo, "--title", f"data {m['version_id']} [{m['status']}]",
       "--notes", f"mode={m['pipeline']['mode_executed']} raw_max_date={m['data']['raw_max_date']} status={m['status']} run={m['pipeline'].get('run_url')}",
       "--latest=false")
    # verify the versioned release is complete BEFORE promoting
    chk = Path(tempfile.mkdtemp()); load_version(a.repo, tag, chk)
    # ---- promotion = the last, atomic step ----
    if not exists(a.repo, LATEST):
        gh("release", "create", LATEST, str(dist / "manifest.json"), "--repo", a.repo, "--title", "latest dashboard data (pointer)",
           "--notes", "Pointer release. Do not edit by hand; use the rollback workflow.", "--latest=false")
    else:
        gh("release", "upload", LATEST, str(dist / "manifest.json"), "--repo", a.repo, "--clobber")
    print(f"PROMOTED {m['version_id']} -> {LATEST}")
    prune(a.repo, a.keep, protect={tag, m["previous_version_id"] and f"data-{m['previous_version_id']}"})


def prune(repo, keep, protect):
    out = json.loads(gh("release", "list", "--repo", repo, "--limit", "200", "--json", "tagName,createdAt").stdout or "[]")
    tags = sorted((r for r in out if r["tagName"].startswith("data-2")), key=lambda r: r["createdAt"], reverse=True)
    for r in tags[keep:]:
        if r["tagName"] not in protect:
            gh("release", "delete", r["tagName"], "--repo", repo, "--yes", "--cleanup-tag", check=False)
            print("pruned", r["tagName"])


def cmd_phei_push(a):
    if not Path(a.store).exists():
        raise SystemExit("ERROR: no phei store")
    if exists(a.repo, PHEI_TAG):
        gh("release", "upload", PHEI_TAG, a.store, "--repo", a.repo, "--clobber")
    else:
        gh("release", "create", PHEI_TAG, a.store, "--repo", a.repo, "--title", "PHEI daily capture history",
           "--notes", "One row per day captured from phei.co.id; PHEI shows a single day only.", "--latest=false")
    print("phei history pushed")


def cmd_promote(a):
    tmp = Path(tempfile.mkdtemp()); download(a.repo, a.tag, "manifest.json", tmp)
    load_version(a.repo, a.tag, Path(tempfile.mkdtemp()))          # must verify before it becomes 'latest'
    gh("release", "upload", LATEST, str(tmp / "manifest.json"), "--repo", a.repo, "--clobber")
    print(f"ROLLED BACK pointer -> {a.tag}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="c", required=True)
    f = sub.add_parser("fetch"); f.add_argument("--work", required=True); f.add_argument("--repo", required=True); f.add_argument("--seed", default="seed/raw_data.xlsx")
    p = sub.add_parser("publish"); p.add_argument("--dist", required=True); p.add_argument("--repo", required=True); p.add_argument("--dry-run", action="store_true"); p.add_argument("--keep", type=int, default=14)
    h = sub.add_parser("phei-push"); h.add_argument("--store", required=True); h.add_argument("--repo", required=True)
    r = sub.add_parser("promote"); r.add_argument("--tag", required=True); r.add_argument("--repo", required=True)
    a = ap.parse_args()
    {"fetch": cmd_fetch, "publish": cmd_publish, "phei-push": cmd_phei_push, "promote": cmd_promote}[a.c](a)
