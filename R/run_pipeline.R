#!/usr/bin/env Rscript
# Orchestrator: validates ingest result -> runs DAILY (hybrid) or FULL (pipeline) in the WORK dir -> validates
# artifacts -> writes run_result.json. It never touches production: production = the last published release.
#   Rscript R/run_pipeline.R --mode DAILY|FULL --work work --ingest work/ingest_result.json --out work/run_result.json
source(file.path(Sys.getenv("REPO_ROOT", getwd()), "R", "common.R"))

parse_args <- function(a) {
  out <- list(); i <- 1
  while (i <= length(a)) { if (startsWith(a[i], "--")) { out[[substring(a[i], 3)]] <- a[i + 1]; i <- i + 2 } else i <- i + 1 }
  out
}
args <- parse_args(commandArgs(trailingOnly = TRUE))
`%||%` <- function(a, b) if (is.null(a) || is.na(a) || !nzchar(a)) b else a
mode <- toupper(args$mode %||% Sys.getenv("PIPELINE_MODE", "DAILY"))
if (!mode %in% c("DAILY", "FULL")) stop("mode must be DAILY or FULL (AUTO is deliberately not allowed in CI)")
work <- normalizePath(args$work %||% "work", mustWork = TRUE)
ingest_path <- args$ingest %||% file.path(work, "ingest_result.json")
out_path <- args$out %||% file.path(work, "run_result.json")
allow_fallback <- !identical(tolower(Sys.getenv("ALLOW_DAILY_FALLBACK_FULL", "true")), "false")
repo <- repo_root(); cfg <- load_cfg()
run_dir <- file.path(work, "_run"); dir.create(run_dir, showWarnings = FALSE, recursive = TRUE)

res <- list(mode_requested = mode, mode_executed = NA_character_, status = "FAILED", reason = "", fallback_full = FALSE,
            fallback_reason = NA_character_, stages = list(), started = ts_both(), raw_max_date = NA_character_,
            n_models = 0L, n_models_updated = 0L, warnings = list(), validation = list(ok = FALSE, issues = list()),
            pipeline_version = NA_character_, joint_model_refreshed = FALSE)
t_stage <- function(name, expr) {
  t0 <- Sys.time(); v <- force(expr)
  res$stages[[name]] <<- list(seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), done = TRUE)
  invisible(v)
}
finish <- function(status, reason = "") {
  res$status <<- status; res$reason <<- reason; res$finished <- ts_both()
  write_json_atomic(res, out_path)
  log_msg("INFO", "run finished status=", status, " mode_executed=", res$mode_executed, " reason=", reason)
  quit(save = "no", status = if (status == "FAILED") 1 else 0)
}

# ---- stage 1: ingest verdict ----
ing <- tryCatch(jsonlite::read_json(ingest_path, simplifyVector = FALSE), error = function(e) NULL)
if (is.null(ing)) finish("FAILED", "ingest_result.json missing/unreadable")
res$ingest_status <- ing$status; res$new_obs <- ing$n_new_obs; res$instruments_ok <- ing$n_instruments_ok
res$instruments_failed <- ing$n_instruments_failed
res$stages$ingest <- list(seconds = NA, done = TRUE, status = ing$status)
if (identical(ing$status, "FAILED")) finish("FAILED", paste("ingest FAILED:", ing$reason))

raw_path <- file.path(work, "raw_data.xlsx")
raw <- t_stage("read_raw", suppressWarnings(readxl::read_excel(raw_path, sheet = 1)))
res$raw_max_date <- as.character(max(as.Date(raw[[1]]), na.rm = TRUE))
model_path <- file.path(work, "All_Markov_Models.rds")
prev_models <- if (file.exists(model_path)) tryCatch(readRDS(model_path), error = function(e) NULL) else NULL
prev_n <- length(prev_models)

# ---- nothing new and DAILY: do not estimate, do not rewrite ----
if (mode == "DAILY" && identical(ing$status, "UP_TO_DATE") && !is.null(prev_models) && prev_n > 0) {
  res$mode_executed <- "NONE"; res$n_models <- prev_n
  finish("UP_TO_DATE", "no new observations; models untouched")
}

run_hybrid <- function(m) {
  env <- c(HYBRID_WORK_DIR = work, PIPELINE_SCRIPT = file.path(repo, "pipeline", "15092026.R"), PIPELINE_RUN_DIR = run_dir,
           PIPELINE_MODE = m, REPO_ROOT = repo, RAW_DEDUPE_POLICY = cfg$dataset$dedupe_policy, TZ = "Asia/Jakarta")
  log_f <- file.path(run_dir, sprintf("hybrid_%s.log", tolower(m)))
  rc <- suppressWarnings(system2("Rscript", file.path(repo, "pipeline", "Hybrid_Incremental_Update.R"),
                                 env = paste0(names(env), "=", env), stdout = log_f, stderr = log_f))
  sj <- file.path(run_dir, "hybrid_status.json")
  list(rc = rc, status = if (file.exists(sj)) jsonlite::read_json(sj, simplifyVector = TRUE) else NULL, log = log_f)
}
tail_log <- function(f, n = 25) if (file.exists(f)) paste(utils::tail(readLines(f, warn = FALSE), n), collapse = "\n") else ""

executed <- mode
hy <- t_stage(paste0("model_", tolower(mode)), run_hybrid(mode))
if (mode == "DAILY" && isTRUE(hy$status$full_required)) {          # no usable model and FULL fallback is disabled in this job
  res$full_required <- TRUE; res$mode_executed <- "NONE"
  finish("FAILED", "FULL REQUIRED (no usable model). Run the workflow with mode FULL.")
}
if (mode == "DAILY" && !isTRUE(hy$status$ok) && length(hy$status$needs_full) > 0) {
  reason <- paste0(length(hy$status$needs_full), " stock(s) failed DAILY validation: ", paste(utils::head(hy$status$needs_full, 5), collapse = ", "))
  if (!allow_fallback) { res$full_required <- TRUE; res$mode_executed <- "NONE"; finish("FAILED", paste0("FULL REQUIRED: ", reason, " (fallback to FULL disabled in this job)")) }
  log_msg("WARN", "DAILY -> FULL fallback: ", reason)
  res$fallback_full <- TRUE; res$fallback_reason <- reason
  hy <- t_stage("model_full_fallback", run_hybrid("FULL")); executed <- "FULL"
}
res$mode_executed <- if (isTRUE(hy$status$fallback_full) || res$fallback_full) "FULL" else executed
if (isTRUE(hy$status$fallback_full) && !res$fallback_full) { res$fallback_full <- TRUE; res$fallback_reason <- hy$status$fallback_reason }
res$pipeline_version <- "HYBRID_1.0"
if (!isTRUE(hy$status$ok) || hy$rc != 0) {
  res$log_tail <- tail_log(hy$log)
  finish("FAILED", paste0("model stage failed (rc=", hy$rc, "): ", hy$status$note %||% "see hybrid log"))
}
res$joint_model_refreshed <- identical(res$mode_executed, "FULL")
res$n_models_updated <- as.integer(hy$status$n_updated %||% 0L)

# ---- stage: artifact validation (uses the dashboard's own acceptance function) ----
v <- t_stage("validate_artifacts", {
  issues <- character(0)
  for (f in unlist(cfg$artifacts$required_core_files)) {
    p <- file.path(work, f); if (!file.exists(p) || file.size(p) == 0) issues <- c(issues, paste("missing/empty:", f))
  }
  mm <- tryCatch(readRDS(model_path), error = function(e) NULL)
  jd <- tryCatch(readRDS(file.path(work, "JointDistribution_Model.rds")), error = function(e) NULL)
  if (is.null(mm) || is.null(jd)) issues <- c(issues, "RDS unreadable") else {
    ap <- load_app_validators(file.path(repo, "app", "app.R"))
    iv <- ap$validate_model_integrity(mm, jd); issues <- c(issues, iv$issues)
    res$n_models <- length(mm)
    if (prev_n > 0) {
      lost <- setdiff(names(prev_models), names(mm)); res$stocks_lost <- as.list(lost)
      frac <- length(lost) / prev_n
      if (frac > (cfg$dataset$max_lost_stock_fraction %||% 0.1)) issues <- c(issues, sprintf("%d of %d previous stocks lost (%.0f%%)", length(lost), prev_n, 100 * frac))
      else if (length(lost) > 0) res$warnings[[length(res$warnings) + 1]] <- paste("stocks lost vs previous:", paste(lost, collapse = ","))
    }
    ld <- vapply(mm, function(m) as.character(max(as.Date(m$final_fit$last_actual_date))), character(1))
    res$model_last_date_max <- max(ld); res$model_last_date_min <- min(ld)
    if (as.Date(max(ld)) < as.Date(res$raw_max_date) - 10) issues <- c(issues, paste("models not advancing: newest model date", max(ld), "vs raw", res$raw_max_date))
    miss_wb <- names(mm)[!file.exists(file.path(work, paste0("Output_MarkovRegimeSwitching_", gsub("[^A-Za-z0-9]", "_", names(mm)), ".xlsx")))]
    if (length(miss_wb) > 0) res$warnings[[length(res$warnings) + 1]] <- paste("no per-issuer workbook for:", paste(utils::head(miss_wb, 8), collapse = ","))
  }
  if (length(hy$status$excel_failed) > 0) res$warnings[[length(res$warnings) + 1]] <- paste("workbook refresh failed:", paste(hy$status$excel_failed, collapse = ","))
  if (length(hy$status$new_stock_columns_without_model) > 0) res$warnings[[length(res$warnings) + 1]] <- paste("dataset stocks without a model (need FULL):", paste(hy$status$new_stock_columns_without_model, collapse = ","))
  issues
})
res$validation <- list(ok = length(v) == 0, issues = as.list(v))
if (length(v) > 0) finish("FAILED", paste("artifact validation failed:", paste(utils::head(v, 3), collapse = " | ")))

partial <- identical(ing$status, "PARTIAL_SUCCESS") || length(res$warnings) > 0
finish(if (partial) "PARTIAL_SUCCESS" else "SUCCESS", if (partial) "completed with warnings (see warnings / ingest result)" else "")
