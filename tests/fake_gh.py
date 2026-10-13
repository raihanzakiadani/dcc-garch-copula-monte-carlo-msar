#!/usr/bin/env python3
"""Minimal local stand-in for the subset of `gh release ...` used by scripts/release.py (tests only).
State dir: $FAKE_GH_DIR/<tag>/<asset>.  FAKE_GH_FAIL_UPLOAD=<tag> makes uploads to that tag fail midway."""
import json, os, shutil, sys, time
from pathlib import Path
R = Path(os.environ["FAKE_GH_DIR"]); R.mkdir(parents=True, exist_ok=True)
a = sys.argv[1:]
assert a[0] == "release"; cmd = a[1]
def opt(name, default=None):
    return a[a.index(name) + 1] if name in a else default
def files():
    out, skip = [], False
    for i, x in enumerate(a[3:], 3):
        if skip: skip = False; continue
        if x.startswith("--"):
            skip = x not in ("--clobber", "--yes", "--cleanup-tag", "--latest=false"); continue
        out.append(x)
    return out
tag = a[2] if len(a) > 2 else None
fail = os.environ.get("FAKE_GH_FAIL_UPLOAD")
if cmd == "view":
    sys.exit(0 if (R / tag).is_dir() else 1)
elif cmd == "create":
    if (R / tag).exists(): print("exists", file=sys.stderr); sys.exit(1)
    (R / tag).mkdir(); (R / tag / ".created").write_text(str(time.time()))
    for i, f in enumerate(files()):
        if fail == tag and i >= 1: print("simulated upload failure", file=sys.stderr); sys.exit(1)
        shutil.copy(f, R / tag / Path(f).name)
elif cmd == "upload":
    if fail == tag: print("simulated upload failure", file=sys.stderr); sys.exit(1)
    for f in files(): shutil.copy(f, R / tag / Path(f).name)
elif cmd == "download":
    p, d = opt("--pattern"), Path(opt("--dir")); d.mkdir(parents=True, exist_ok=True)
    src = R / tag / p
    if not src.exists(): print("asset not found", file=sys.stderr); sys.exit(1)
    shutil.copy(src, d / p)
elif cmd == "list":
    rows = [{"tagName": t.name, "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float((t / ".created").read_text())))} for t in R.iterdir() if t.is_dir()]
    print(json.dumps(rows))
elif cmd == "delete":
    shutil.rmtree(R / tag, ignore_errors=True)
