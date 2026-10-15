"""Static consistency between workflows and the R scripts (names, stage values, folder layout) + actionlint when available."""
import re, shutil, subprocess
from pathlib import Path
import pytest, yaml

ROOT = Path(__file__).resolve().parents[1]
WF = (ROOT / ".github/workflows/pipeline.yml").read_text()
PIPE = (ROOT / "pipeline/15092026.R").read_text()


def test_every_env_var_set_by_workflow_is_read_by_the_pipeline():
    for name in ("PIPELINE_STAGE", "PIPELINE_SHARD_INDEX", "PIPELINE_SHARD_COUNT", "PIPELINE_SHARD_DIR", "PIPELINE_INPUT_XLSX", "PIPELINE_OUTPUT_DIR"):
        assert name in WF, name
        assert f'Sys.getenv("{name}"' in PIPE, name


def test_stage_values_in_workflow_are_accepted_by_pipeline():
    allowed = set(re.search(r'PIPELINE_STAGE %in% c\(("all"[^)]*)\)', PIPE).group(1).replace('"', "").replace(" ", "").split(","))
    used = set(re.findall(r"PIPELINE_STAGE: (\w+)", WF))
    assert used == {"joint", "stocks", "merge"} and used <= allowed


def test_artifact_layout_matches_pipeline_defaults():
    # joint writes macro_stage.rds to <out>/_shards ; shard copies it next to its own shard rds ; merge overlays everything on work/
    assert 'PIPELINE_SHARD_DIR="$PWD/stage/joint/_shards"' in WF and "cp stage/joint/_shards/macro_stage.rds stage/shard/_shards/" in WF
    assert 'file.path(output_dir, "_shards")' in PIPE                         # merge job sets no PIPELINE_SHARD_DIR => work/_shards
    assert re.search(r"merge:.*?pattern: \"shard-\*\", path: work, merge-multiple: true", WF, re.S)


def test_staging_dirs_are_never_published():
    import json
    assert {"_shards", "_run", "Backup_Models"} <= set(json.loads((ROOT / "config/pipeline.json").read_text())["artifacts"]["never_publish"])


def test_merge_waits_for_everything_and_publish_only_in_merge_or_run():
    jobs = yaml.safe_load(WF)["jobs"]
    assert set(jobs["merge"]["needs"]) == {"plan", "prepare", "joint", "shards"}
    assert jobs["shards"]["strategy"]["fail-fast"] is False
    pub = [j for j, spec in jobs.items() if "ci_steps.sh publish" in str(spec) or "ci_run.sh" in str(spec)]
    assert sorted(pub) == ["merge", "run"]
    assert jobs["shards"]["timeout-minutes"] <= 360 and jobs["joint"]["timeout-minutes"] <= 360


def test_hosted_daily_cannot_start_full_fallback():
    assert "ALLOW_DAILY_FALLBACK_FULL: ${{ needs.plan.outputs.strategy == 'monolith' && 'true' || 'false' }}" in WF


@pytest.mark.skipif(shutil.which("actionlint") is None, reason="actionlint not installed")
def test_actionlint_clean():
    r = subprocess.run(["actionlint", *map(str, (ROOT / ".github/workflows").glob("*.yml"))], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_every_job_with_flaresolverr_waits_for_it():
    import glob
    for f in glob.glob(str(ROOT / ".github/workflows/*.yml")):
        d = yaml.safe_load(open(f).read())
        for name, job in d["jobs"].items():
            if "flaresolverr" in (job.get("services") or {}):
                assert "scripts/wait_flaresolverr.sh" in str(job["steps"]), f"{Path(f).name}:{name}"
