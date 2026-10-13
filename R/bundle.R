#!/usr/bin/env Rscript
# Build the publishable bundle + manifest from a validated work dir.
#   Rscript R/bundle.R --work work --run work/run_result.json --ingest work/ingest_result.json --out dist [--prev-manifest prev.json]
# Only dashboard artefacts are packed (config$artifacts$publish_globs); backups/logs/_run are never included.
source(file.path(Sys.getenv("REPO_ROOT", getwd()), "R", "common.R"))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a)) || identical(a, "")) b else a
a <- commandArgs(trailingOnly = TRUE); args <- list(); i <- 1
while (i <= length(a)) { if (startsWith(a[i], "--")) { args[[substring(a[i], 3)]] <- a[i + 1]; i <- i + 2 } else i <- i + 1 }
work <- normalizePath(args$work); cfg <- load_cfg(); out <- args$out %||% "dist"
run <- jsonlite::read_json(args$run %||% file.path(work, "run_result.json"))
ing <- jsonlite::read_json(args$ingest %||% file.path(work, "ingest_result.json"))
prev <- if (!is.null(args[["prev-manifest"]]) && file.exists(args[["prev-manifest"]])) jsonlite::read_json(args[["prev-manifest"]]) else NULL
if (!run$status %in% c("SUCCESS", "PARTIAL_SUCCESS")) stop("refusing to bundle a run with status ", run$status)

gl <- unlist(cfg$artifacts$publish_globs); nv <- unlist(cfg$artifacts$never_publish)
files <- character(0)
for (g in gl) {
  hit <- Sys.glob(file.path(work, g))
  for (h in hit) files <- c(files, if (dir.exists(h)) list.files(h, recursive = TRUE, full.names = TRUE) else h)
}
rel <- sub(paste0("^", gsub("([.|()\\^{}+$*?]|\\[|\\])", "\\\\\\1", work), "/?"), "", unique(files))
blocked <- vapply(rel, function(r) any(vapply(nv, function(p) grepl(glob2rx(p), basename(r)) || startsWith(r, paste0(p, "/")), logical(1))), logical(1))
rel <- sort(rel[!blocked])
if (length(rel) == 0) stop("nothing to publish")

run_id <- Sys.getenv("GITHUB_RUN_ID", "local"); now <- Sys.time()
version_id <- paste0(format(now, "%Y%m%dT%H%M%SZ", tz = "UTC"), "-", run_id)
dir.create(out, recursive = TRUE, showWarnings = FALSE)
stage <- file.path(out, "stage"); unlink(stage, recursive = TRUE); dir.create(stage)
for (r in rel) { dir.create(dirname(file.path(stage, r)), recursive = TRUE, showWarnings = FALSE); file.copy(file.path(work, r), file.path(stage, r)) }
bundle_name <- paste0("bundle-", version_id, ".tar.gz"); bundle <- file.path(out, bundle_name)
old <- setwd(stage); utils::tar(normalizePath(bundle, mustWork = FALSE), files = ".", compression = "gzip", tar = "internal"); setwd(old)
bundle <- normalizePath(bundle)

repo_full <- Sys.getenv("GITHUB_REPOSITORY", "local/local")
manifest <- list(
  schema_version = 1L, version_id = version_id, status = run$status, created = ts_both(now),
  pipeline = list(mode_requested = run$mode_requested, mode_executed = run$mode_executed, fallback_full = isTRUE(run$fallback_full),
                  fallback_reason = run$fallback_reason, code_version = run$pipeline_version, git_sha = Sys.getenv("GITHUB_SHA", "local"),
                  run_id = run_id, run_url = if (run_id != "local") sprintf("%s/%s/actions/runs/%s", Sys.getenv("GITHUB_SERVER_URL", "https://github.com"), repo_full, run_id) else NA),
  data = list(raw_max_date = run$raw_max_date, new_observations = ing$n_new_obs, ingest_status = ing$status,
              instruments_ok = ing$n_instruments_ok, instruments_failed = ing$n_instruments_failed,
              failed_instruments = names(Filter(function(x) startsWith(x$status, "FAILED"), ing$instruments))),
  model = list(n_issuers = run$n_models, issuers_updated_this_run = run$n_models_updated, model_last_date_max = run$model_last_date_max,
               model_last_date_min = run$model_last_date_min,
               joint_distribution_last_full_run = if (isTRUE(run$joint_model_refreshed)) version_id else (prev$model$joint_distribution_last_full_run %||% "unknown"),
               joint_distribution_note = "DAILY updates regime probabilities only; JointDistribution_Model.rds is re-estimated by FULL (Fridays)."),
  validation = list(ok = isTRUE(run$validation$ok), warnings = run$warnings, stages = run$stages),
  previous_version_id = prev$version_id %||% NA,
  bundle = list(name = bundle_name, sha256 = sha256_file(bundle), size_bytes = file.size(bundle),
                release_tag = paste0(cfg$publish$release_tag_prefix, version_id)),
  files = lapply(rel, function(r) list(path = r, sha256 = sha256_file(file.path(work, r)), size = file.size(file.path(work, r))))
)
write_json_atomic(manifest, file.path(out, "manifest.json"))
unlink(stage, recursive = TRUE)
cat("BUNDLE:", bundle, sprintf("(%.1f MB, %d files)\n", file.size(bundle) / 1e6, length(rel)))
cat("VERSION_ID=", version_id, "\n", sep = "")
