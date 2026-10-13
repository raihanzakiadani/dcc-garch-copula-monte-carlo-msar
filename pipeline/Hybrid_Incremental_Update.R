rm(list = ls())
options(scipen = 999, stringsAsFactors = FALSE)

# ---------------------------------------------------------------------------------------------
# [REFACTOR-NONINTERACTIVE] All locations come from environment variables set by the orchestrator
# (R/run_pipeline.R). No setwd() to a personal folder, no placeholder paths.
#   HYBRID_WORK_DIR        directory holding raw_data.xlsx + models + Output_*.xlsx for THIS run
#   PIPELINE_SCRIPT        path to pipeline/15092026.R (methodology source of truth)
#   PIPELINE_RUN_DIR       non-published scratch (backups, audit log, status json)
#   PIPELINE_MODE          DAILY | FULL | AUTO | RECALIBRATE   (default DAILY - never silently AUTO)
# ---------------------------------------------------------------------------------------------
.env_or <- function(name, default) { v <- Sys.getenv(name, unset = ""); if (nzchar(v)) v else default }
BASE_DIR <- normalizePath(.env_or("HYBRID_WORK_DIR", getwd()), winslash = "/", mustWork = TRUE)

PATH_PIPELINE_SCRIPT   <- .env_or("PIPELINE_SCRIPT", file.path(getwd(), "pipeline", "15092026.R"))
PATH_MARKOV_MODELS     <- file.path(BASE_DIR, "All_Markov_Models.rds")
PATH_JOINT_MODEL       <- file.path(BASE_DIR, "JointDistribution_Model.rds")
PATH_NEW_DATA          <- file.path(BASE_DIR, "raw_data.xlsx")
PATH_OUTPUT_DIR        <- BASE_DIR
RUN_DIR                <- .env_or("PIPELINE_RUN_DIR", file.path(BASE_DIR, "_run"))
PATH_BACKUP_DIR        <- file.path(RUN_DIR, "Backup_Models")
PATH_AUDIT_LOG_DIR     <- file.path(RUN_DIR, "Audit_Log")
PATH_STATUS_JSON       <- file.path(RUN_DIR, "hybrid_status.json")

if (!dir.exists(PATH_BACKUP_DIR)) dir.create(PATH_BACKUP_DIR, recursive = TRUE)
if (!dir.exists(PATH_AUDIT_LOG_DIR)) dir.create(PATH_AUDIT_LOG_DIR, recursive = TRUE)

MODE                        <- .env_or("PIPELINE_MODE", "DAILY")
RECALIBRATION_FREQUENCY_DAYS <- 7
N_STARTS_WARMSTART          <- 3
RERUN_SELECTION_ON_RECALIBRATE <- FALSE
VALIDATION_TOLERANCE_FILT_PROB <- 1e-6
HISTORICAL_REPLICA_TOLERANCE   <- 1e-6
PIPELINE_VERSION             <- "HYBRID_1.0"
MODEL_SCHEMA_VERSION         <- "1.0"

# [ADDED] DAILY must never publish a half-updated model set (some stocks at t, others at t-1).
# STRICT_ATOMIC=true: if ANY stock needs FULL, nothing is saved and the status file says why.
STRICT_ATOMIC <- !identical(tolower(.env_or("HYBRID_STRICT_ATOMIC", "true")), "false")

# [ADDED] On a GitHub-hosted runner a FULL run can exceed the 6 h job limit, so the DAILY job must not silently start one.
# HYBRID_ALLOW_FULL_FALLBACK=false: when no usable model exists, stop and report full_required=TRUE (run the FULL workflow instead).
ALLOW_FULL_FALLBACK <- !identical(tolower(.env_or("HYBRID_ALLOW_FULL_FALLBACK", "true")), "false")

USE_PARALLEL_HYBRID  <- TRUE
N_CORES_HYBRID        <- max(1, as.integer(.env_or("HYBRID_N_CORES", as.character(parallel::detectCores() - 1))))
PARALLEL_MIN_STOCKS   <- 2

# Only packages this script itself calls. (The original list also named foreach/doParallel/doRNG but this
# file never uses them; FULL mode runs pipeline/15092026.R which performs its own, complete package check.)
REQUIRED_PACKAGES_HYBRID <- c("readxl", "openxlsx", "numDeriv", "Matrix", "tools", "methods", "stats", "utils",
                              "parallel", "jsonlite")
.missing_h <- REQUIRED_PACKAGES_HYBRID[!vapply(REQUIRED_PACKAGES_HYBRID, requireNamespace, logical(1), quietly = TRUE)]
if (length(.missing_h) > 0) {
  stop("Paket R belum terpasang: ", paste(.missing_h, collapse = ", "), " - jalankan scripts/install_deps.R.")
}
HYBRID_STATUS <- list(mode_requested = MODE, mode_executed = NA_character_, ok = FALSE, n_stocks = 0L,
                      n_updated = 0L, n_up_to_date = 0L, needs_full = character(0), needs_full_reasons = list(),
                      excel_failed = character(0), new_stock_columns_without_model = character(0),
                      fallback_full = FALSE, fallback_reason = NA_character_, full_required = FALSE, last_data_date = NA_character_,
                      saved = FALSE, note = "")
suppressPackageStartupMessages({
  library(readxl)
  library(openxlsx)
  library(parallel)
})

AUDIT_LOG <- data.frame(
  Timestamp = character(0), Stock = character(0), Stage = character(0),
  Mode_Requested = character(0), Mode_Executed = character(0),
  Detail = character(0), Status = character(0), Runtime_Sec = numeric(0),
  stringsAsFactors = FALSE
)

audit_add <- function(stock, stage, mode_requested, mode_executed, detail, status, runtime_sec = NA_real_) {
  AUDIT_LOG <<- rbind(AUDIT_LOG, data.frame(
    Timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%OS3"),
    Stock = stock, Stage = stage, Mode_Requested = mode_requested,
    Mode_Executed = mode_executed, Detail = detail, Status = status,
    Runtime_Sec = runtime_sec, stringsAsFactors = FALSE
  ))
  cat(sprintf("[AUDIT] %-18s | %-24s | requested=%-12s executed=%-20s | %s | %s\n",
              stock, stage, mode_requested, mode_executed, status, detail))
}

file_md5_safe <- function(path) {
  if (!file.exists(path)) return(NA_character_)
  as.character(tools::md5sum(path))
}

data_fingerprint <- function(df) {
  tmp <- tempfile(fileext = ".rds")
  on.exit(unlink(tmp), add = TRUE)
  saveRDS(df, tmp, compress = FALSE)
  as.character(tools::md5sum(tmp))
}

safe_save_rds <- function(object, path, backup_dir) {
  if (file.exists(path)) {
    stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    backup_path <- file.path(backup_dir, paste0(tools::file_path_sans_ext(basename(path)),
                                                "_backup_", stamp, ".rds"))
    ok_backup <- file.copy(path, backup_path, overwrite = TRUE)
    if (!isTRUE(ok_backup)) {
      stop("safe_save_rds(): GAGAL membuat backup sebelum overwrite untuk ", path,
           " - proses save DIBATALKAN demi keamanan model existing.")
    }
    cat(">> [SAFE SAVE] Backup model lama dibuat:", backup_path, "\n")
  }
  tmp_path <- paste0(path, ".tmp_", format(Sys.time(), "%Y%m%d_%H%M%S"))
  saveRDS(object, tmp_path)
  verify <- tryCatch(readRDS(tmp_path), error = function(e) NULL)
  if (is.null(verify)) {
    unlink(tmp_path)
    stop("safe_save_rds(): file temporary GAGAL diverifikasi setelah ditulis - proses save DIBATALKAN untuk ", path)
  }
  ok_rename <- file.rename(tmp_path, path)
  if (!isTRUE(ok_rename)) {
    unlink(tmp_path)
    stop("safe_save_rds(): GAGAL merename file temporary menjadi target final untuk ", path)
  }
  cat(">> [SAFE SAVE] Model berhasil disimpan (via temp file + rename):", path, "\n")
  invisible(TRUE)
}

extract_function_block <- function(all_lines, start_idx) {
  n <- length(all_lines)
  brace_count <- 0
  started <- FALSE
  end_idx <- start_idx
  for (i in start_idx:n) {
    line_chars <- strsplit(all_lines[i], "")[[1]]
    for (ch in line_chars) {
      if (ch == "{") { brace_count <- brace_count + 1; started <- TRUE }
      if (ch == "}") { brace_count <- brace_count - 1 }
    }
    if (started && brace_count <= 0) {
      end_idx <- i
      break
    }
  }
  paste(all_lines[start_idx:end_idx], collapse = "\n")
}

build_pipeline_function_env <- function(source_path, function_names) {
  if (!file.exists(source_path)) {
    stop("build_pipeline_function_env(): file sumber metodologi tidak ditemukan: ", source_path)
  }
  all_lines <- readLines(source_path, warn = FALSE, encoding = "UTF-8")
  fn_env <- new.env(parent = globalenv())
  found <- character(0)
  missing_fn <- character(0)
  for (fn_name in function_names) {
    pattern <- paste0("^", fn_name, "\\s*<-\\s*function\\s*\\(")
    hit_idx <- grep(pattern, all_lines)
    if (length(hit_idx) == 0) {
      missing_fn <- c(missing_fn, fn_name)
      next
    }
    block_text <- extract_function_block(all_lines, hit_idx[1])
    eval(parse(text = block_text), envir = fn_env)
    found <- c(found, fn_name)
  }
  if (length(missing_fn) > 0) {
    stop("build_pipeline_function_env(): fungsi berikut TIDAK ditemukan secara verbatim pada ",
         source_path, " - proses dihentikan (tidak boleh mengarang implementasi pengganti): ",
         paste(missing_fn, collapse = ", "))
  }
  cat(">> [SOURCE AUDIT] Berhasil mengekstraksi", length(found), "fungsi verbatim dari", source_path, ":\n   ",
      paste(found, collapse = ", "), "\n")
  fn_env
}

REQUIRED_PIPELINE_FUNCTIONS <- c(
  "calc_log_return", "detect_suspend_blocks", "detect_transformation_type", "transform_series",
  "build_trans_matrix", "invert_trans_matrix", "hamilton_filter", "kim_smoother",
  "negloglik_ms", "generate_initial_theta", "build_lbfgsb_bounds",
  "diagnose_hessian_numerics", "robust_hessian_vcov",
  "negloglik_ms_t", "generate_initial_theta_t",
  "classify_regimes_by_sigma", "forecast_regime_prob", "expected_duration",
  "compute_steady_state"
)

PIPELINE_ENV <- build_pipeline_function_env(PATH_PIPELINE_SCRIPT, REQUIRED_PIPELINE_FUNCTIONS)

detect_stock_macro_columns <- function(raw_data, date_col) {
  all_numeric_cols <- names(raw_data)[-which(names(raw_data) == date_col)]
  stock_pattern <- "\\bIJ\\s*EQUITY\\b"
  stock_targets <- all_numeric_cols[grepl(stock_pattern, all_numeric_cols, ignore.case = TRUE)]
  macro_cols <- setdiff(all_numeric_cols, stock_targets)
  list(stock_targets = stock_targets, macro_cols = macro_cols)
}

read_and_clean_raw_data <- function(path) {
  raw_data <- readxl::read_excel(path, sheet = 1)
  raw_data <- as.data.frame(raw_data)
  date_col <- names(raw_data)[1]
  raw_data[[date_col]] <- as.Date(raw_data[[date_col]])
  raw_data <- raw_data[order(raw_data[[date_col]], seq_len(nrow(raw_data))), ]
  # [REFACTOR-DEDUPE] same policy as pipeline/15092026.R (RAW_DEDUPE_POLICY, default "last")
  .dedupe_policy <- Sys.getenv("RAW_DEDUPE_POLICY", unset = "last")
  n_dup <- sum(duplicated(raw_data[[date_col]]))
  if (n_dup > 0) {
    cat(">> [DATA QUALITY] PERINGATAN:", n_dup, "tanggal duplikat ditemukan pada dataset baru. Baris duplikat dihapus (policy =", .dedupe_policy, ").\n")
    raw_data <- raw_data[!duplicated(raw_data[[date_col]], fromLast = identical(.dedupe_policy, "last")), ]
  }
  rownames(raw_data) <- NULL
  list(raw_data = raw_data, date_col = date_col, n_dup = n_dup)
}

rebuild_full_model_df <- function(raw_data, date_col, stock_name, macro_cols_all,
                                  selected_variables, ar_order_p, lag_cols, pipeline_env) {
  
  vars_for_return <- c(stock_name, macro_cols_all)
  log_return_df <- data.frame(Dates = raw_data[[date_col]])
  
  for (v in vars_for_return) {
    if (v %in% macro_cols_all) {
      tinfo <- pipeline_env$detect_transformation_type(v)
      tval <- pipeline_env$transform_series(raw_data[[v]], tinfo$method)
      log_return_df[[v]] <- tval$value
    } else {
      log_return_df[[v]] <- pipeline_env$calc_log_return(raw_data[[v]])
    }
  }
  
  suspend_detect <- pipeline_env$detect_suspend_blocks(raw_data[[stock_name]], min_run = 3)
  if (length(suspend_detect$suspend_idx) > 0) {
    log_return_df[[stock_name]][suspend_detect$suspend_idx] <- NA
  }
  if (length(suspend_detect$post_resume_idx) > 0) {
    log_return_df[[stock_name]][suspend_detect$post_resume_idx] <- NA
  }
  
  log_return_df <- log_return_df[-1, ]
  rownames(log_return_df) <- NULL
  
  na_rows <- which(rowSums(is.na(log_return_df[, vars_for_return, drop = FALSE])) > 0)
  if (length(na_rows) > 0) {
    log_return_df <- log_return_df[-na_rows, ]
  }
  inf_check <- sapply(log_return_df[vars_for_return], function(x) any(is.infinite(x)))
  if (any(inf_check)) {
    log_return_df <- log_return_df[apply(is.finite(as.matrix(log_return_df[vars_for_return])), 1, all), ]
  }
  rownames(log_return_df) <- NULL
  
  df_p <- log_return_df
  if (ar_order_p > 0) {
    for (lag_i in 1:ar_order_p) {
      lag_name <- lag_cols[lag_i]
      df_p[[lag_name]] <- c(rep(NA_real_, lag_i), utils::head(df_p[[stock_name]], -lag_i))
    }
    valid_rows_p <- stats::complete.cases(df_p[, c(stock_name, selected_variables, lag_cols), drop = FALSE])
    df_p <- df_p[valid_rows_p, ]
    rownames(df_p) <- NULL
  }
  
  df_p
}

build_design_matrix <- function(model_df, stock_name, coef_names, lag_cols, selected_variables) {
  n <- nrow(model_df)
  X <- matrix(NA_real_, nrow = n, ncol = length(coef_names))
  colnames(X) <- coef_names
  for (cn in coef_names) {
    if (cn == "(Intercept)") {
      X[, cn] <- 1
    } else if (cn %in% lag_cols) {
      X[, cn] <- model_df[[cn]]
    } else {
      X[, cn] <- model_df[[cn]]
    }
  }
  y <- model_df[[stock_name]]
  list(y = y, X = X, Dates = model_df$Dates)
}

run_hamilton_and_smooth <- function(y, X, final_fit, pipeline_env) {
  dist_type <- if (!is.null(final_fit$nu_vec)) "t" else "norm"
  res_filt <- pipeline_env$hamilton_filter(
    y = y, X = X, beta_mat = final_fit$beta_mat, sigma_vec = final_fit$sigma_vec,
    P = final_fit$trans_mat, k = final_fit$k, dist = dist_type, nu_vec = final_fit$nu_vec
  )
  res_smooth <- pipeline_env$kim_smoother(res_filt$filt, res_filt$pred, final_fit$trans_mat, final_fit$k)
  list(loglik = res_filt$loglik, filt = t(res_filt$filt), smo = t(res_smooth))
}

validate_and_extend_stock_daily <- function(stock_name, model_entry, raw_data_new, date_col,
                                            macro_cols_all, pipeline_env, tol_replica) {
  
  final_fit <- model_entry$final_fit
  selected_variables <- model_entry$selected_variables
  ar_order_p <- model_entry$ar_order_p
  lag_cols <- final_fit$lag_cols
  coef_names <- final_fit$coef_names
  
  missing_macro <- setdiff(selected_variables, names(raw_data_new))
  if (!stock_name %in% names(raw_data_new)) {
    return(list(ok = FALSE, reason = paste0("Kolom saham '", stock_name, "' tidak ditemukan pada dataset baru.")))
  }
  if (length(missing_macro) > 0) {
    return(list(ok = FALSE, reason = paste0("Variabel makro terpilih tidak ditemukan pada dataset baru: ",
                                            paste(missing_macro, collapse = ", "))))
  }
  
  full_model_df <- rebuild_full_model_df(raw_data_new, date_col, stock_name, macro_cols_all,
                                         selected_variables, ar_order_p, lag_cols, pipeline_env)
  
  last_model_date <- final_fit$last_actual_date
  hist_part <- full_model_df[full_model_df$Dates <= last_model_date, ]
  new_part  <- full_model_df[full_model_df$Dates > last_model_date, ]
  
  if (nrow(new_part) == 0) {
    return(list(ok = TRUE, status = "UP_TO_DATE", n_new = 0))
  }
  
  if (nrow(hist_part) < 5) {
    return(list(ok = FALSE, reason = "Historical replica terlalu pendek untuk divalidasi."))
  }
  
  dm_hist <- build_design_matrix(hist_part, stock_name, coef_names, lag_cols, selected_variables)
  hist_check <- run_hamilton_and_smooth(dm_hist$y, dm_hist$X, final_fit, pipeline_env)
  
  n_hist_stored <- nrow(final_fit$filt_prob)
  n_hist_replica <- nrow(hist_check$filt)
  if (n_hist_replica != n_hist_stored) {
    return(list(ok = FALSE, reason = paste0(
      "Jumlah observasi historical hasil rekonstruksi (", n_hist_replica,
      ") TIDAK SAMA dengan jumlah observasi pada model tersimpan (", n_hist_stored,
      ") - indikasi perubahan pada data historis atau perbedaan preprocessing."
    )))
  }
  
  max_diff <- max(abs(hist_check$filt - final_fit$filt_prob))
  if (!is.finite(max_diff) || max_diff > tol_replica) {
    return(list(ok = FALSE, reason = paste0(
      "Rekonstruksi filtered probability historical TIDAK SAMA dengan model tersimpan (max abs diff = ",
      format(max_diff, scientific = TRUE), ", tolerance = ", tol_replica,
      ") - indikasi revisi data historis atau ketidakcocokan preprocessing. DAILY mode DIBATALKAN untuk saham ini."
    )))
  }
  
  cross_check_lag <- if (ar_order_p > 0) {
    computed_last_lags <- stats::setNames(rev(utils::tail(hist_part[[stock_name]], ar_order_p)), lag_cols)
    max(abs(computed_last_lags - final_fit$last_actual_lags))
  } else {
    0
  }
  if (!is.finite(cross_check_lag) || cross_check_lag > tol_replica) {
    return(list(ok = FALSE, reason = paste0(
      "last_actual_lags hasil rekonstruksi tidak konsisten dengan model tersimpan (max abs diff = ",
      format(cross_check_lag, scientific = TRUE), ")."
    )))
  }
  
  dm_full <- build_design_matrix(full_model_df, stock_name, coef_names, lag_cols, selected_variables)
  full_result <- run_hamilton_and_smooth(dm_full$y, dm_full$X, final_fit, pipeline_env)
  
  cls_result <- pipeline_env$classify_regimes_by_sigma(full_result$smo, final_fit$sigma_vec, final_fit$k)
  last_filt_row <- as.numeric(full_result$filt[nrow(full_result$filt), ])
  regime_forecast <- pipeline_env$forecast_regime_prob(as.matrix(final_fit$trans_mat), last_filt_row, horizon = 10)
  
  new_last_lags <- if (ar_order_p > 0) {
    stats::setNames(rev(utils::tail(full_model_df[[stock_name]], ar_order_p)), lag_cols)
  } else {
    NULL
  }
  new_last_date <- max(full_model_df$Dates)
  new_close_price <- raw_data_new[[stock_name]][which(raw_data_new[[date_col]] == new_last_date)[1]]
  
  updated_final_fit <- final_fit
  updated_final_fit$filt_prob <- full_result$filt
  updated_final_fit$smo_prob <- full_result$smo
  updated_final_fit$logLik <- full_result$loglik
  updated_final_fit$last_actual_date <- new_last_date
  updated_final_fit$last_actual_lags <- new_last_lags
  updated_final_fit$yesterday_close_price <- as.numeric(new_close_price)
  
  list(
    ok = TRUE, status = "DAILY_UPDATED",
    n_new = nrow(new_part), new_dates = new_part$Dates,
    updated_final_fit = updated_final_fit,
    regime_classification = data.frame(Dates = full_model_df$Dates,
                                       Regime_Number = cls_result$regime_class,
                                       Regime_Label = cls_result$regime_label),
    filtered_probability = data.frame(Dates = full_model_df$Dates,
                                      Filtered_Prob_State = full_result$filt),
    regime_forecast = regime_forecast,
    max_diff_replica = max_diff
  )
}

theta_from_final_fit <- function(final_fit, pipeline_env) {
  beta_flat <- as.numeric(final_fit$beta_mat)
  log_sigma <- log(final_fit$sigma_vec)
  eta <- pipeline_env$invert_trans_matrix(as.matrix(final_fit$trans_mat), final_fit$k)
  c(beta_flat, log_sigma, eta)
}

warmstart_reestimate_stock <- function(stock_name, model_entry, raw_data_new, date_col,
                                       macro_cols_all, pipeline_env, n_starts_warmstart) {
  
  final_fit_old <- model_entry$final_fit
  selected_variables <- model_entry$selected_variables
  ar_order_p <- model_entry$ar_order_p
  lag_cols <- final_fit_old$lag_cols
  coef_names <- final_fit_old$coef_names
  k <- final_fit_old$k
  n_params <- final_fit_old$n_params
  
  full_model_df <- rebuild_full_model_df(raw_data_new, date_col, stock_name, macro_cols_all,
                                         selected_variables, ar_order_p, lag_cols, pipeline_env)
  dm_full <- build_design_matrix(full_model_df, stock_name, coef_names, lag_cols, selected_variables)
  y <- dm_full$y
  X <- dm_full$X
  
  bounds <- pipeline_env$build_lbfgsb_bounds(k, n_params, n_extra_blocks = 0)
  theta0_warm <- theta_from_final_fit(final_fit_old, pipeline_env)
  
  candidates <- list()
  candidates[[1]] <- theta0_warm
  if (n_starts_warmstart > 1) {
    set.seed(20260914)
    for (s in 2:n_starts_warmstart) {
      candidates[[s]] <- theta0_warm + rnorm(length(theta0_warm), mean = 0, sd = 0.05 * (s - 1))
    }
  }
  
  best <- NULL
  for (s in seq_along(candidates)) {
    opt <- tryCatch(
      stats::optim(par = candidates[[s]], fn = pipeline_env$negloglik_ms, y = y, X = X,
                   k = k, n_params = n_params, method = "L-BFGS-B",
                   lower = bounds$lower, upper = bounds$upper,
                   hessian = FALSE, control = list(maxit = 2000, factr = 1e7, pgtol = 1e-8, trace = 0)),
      error = function(e) NULL
    )
    if (!is.null(opt) && is.finite(opt$value)) {
      if (is.null(best) || opt$value < best$value) best <- opt
    }
  }
  
  if (is.null(best)) {
    return(list(ok = FALSE, reason = "Warm-start optimization gagal konvergen pada seluruh starting values."))
  }
  
  hess_result <- pipeline_env$robust_hessian_vcov(
    objective_fn = pipeline_env$negloglik_ms, par = best$par,
    y = y, X = X, k = k, n_params = n_params,
    convergence_code = best$convergence, model_label = paste0(stock_name, "_WARMSTART_RECALIBRATE")
  )
  
  theta <- best$par
  idx <- 1
  beta_mat <- matrix(NA, nrow = n_params, ncol = k)
  for (i in 1:k) {
    beta_mat[, i] <- theta[idx:(idx + n_params - 1)]
    idx <- idx + n_params
  }
  log_sigma <- theta[idx:(idx + k - 1)]
  sigma_vec <- exp(log_sigma)
  idx <- idx + k
  eta <- theta[idx:(idx + k * (k - 1) - 1)]
  trans_mat <- pipeline_env$build_trans_matrix(eta, k)
  
  se_theta <- hess_result$se_theta
  se_beta <- matrix(NA_real_, nrow = n_params, ncol = k)
  idx2 <- 1
  for (i in 1:k) {
    se_beta[, i] <- se_theta[idx2:(idx2 + n_params - 1)]
    idx2 <- idx2 + n_params
  }
  
  rownames(beta_mat) <- coef_names
  colnames(beta_mat) <- paste0("Regime_", 1:k)
  rownames(se_beta) <- coef_names
  colnames(se_beta) <- paste0("Regime_", 1:k)
  rownames(trans_mat) <- paste0("State_", 1:k)
  colnames(trans_mat) <- paste0("State_", 1:k)
  
  refilt <- run_hamilton_and_smooth(y, X, list(beta_mat = beta_mat, sigma_vec = sigma_vec,
                                               trans_mat = trans_mat, k = k, nu_vec = NULL), pipeline_env)
  
  cls_result <- pipeline_env$classify_regimes_by_sigma(refilt$smo, sigma_vec, k)
  last_filt_row <- as.numeric(refilt$filt[nrow(refilt$filt), ])
  regime_forecast <- pipeline_env$forecast_regime_prob(as.matrix(trans_mat), last_filt_row, horizon = 10)
  
  new_last_lags <- if (ar_order_p > 0) {
    stats::setNames(rev(utils::tail(full_model_df[[stock_name]], ar_order_p)), lag_cols)
  } else {
    NULL
  }
  new_last_date <- max(full_model_df$Dates)
  new_close_price <- raw_data_new[[stock_name]][which(raw_data_new[[date_col]] == new_last_date)[1]]
  
  updated_final_fit <- final_fit_old
  updated_final_fit$theta <- theta
  updated_final_fit$beta_mat <- beta_mat
  updated_final_fit$se_beta <- se_beta
  updated_final_fit$sigma_vec <- sigma_vec
  updated_final_fit$se_sigma <- se_theta[(k * n_params + 1):(k * n_params + k)]
  updated_final_fit$eta <- eta
  updated_final_fit$trans_mat <- trans_mat
  updated_final_fit$filt_prob <- refilt$filt
  updated_final_fit$smo_prob <- refilt$smo
  updated_final_fit$logLik <- refilt$loglik
  updated_final_fit$convergence <- best$convergence
  updated_final_fit$hessian_mat <- hess_result$hessian
  updated_final_fit$vcov_mat <- hess_result$vcov_mat
  updated_final_fit$hessian_ok <- hess_result$hessian_ok
  updated_final_fit$se_valid <- hess_result$se_valid
  updated_final_fit$wald_valid <- hess_result$wald_valid
  updated_final_fit$optimizer_used <- "L-BFGS-B (warm-start recalibration, theta0 dari final_fit sebelumnya)"
  updated_final_fit$last_actual_date <- new_last_date
  updated_final_fit$last_actual_lags <- new_last_lags
  updated_final_fit$yesterday_close_price <- as.numeric(new_close_price)
  
  list(
    ok = TRUE, status = "WARMSTART_RECALIBRATED",
    updated_final_fit = updated_final_fit,
    regime_classification = data.frame(Dates = full_model_df$Dates,
                                       Regime_Number = cls_result$regime_class,
                                       Regime_Label = cls_result$regime_label),
    filtered_probability = data.frame(Dates = full_model_df$Dates,
                                      Filtered_Prob_State = refilt$filt),
    regime_forecast = regime_forecast,
    n_obs_used = nrow(full_model_df)
  )
}

update_stock_excel <- function(stock_name, daily_result, output_dir, mode_label) {
  stock_tag <- gsub("[^A-Za-z0-9]", "_", stock_name)
  excel_path <- file.path(output_dir, paste0("Output_MarkovRegimeSwitching_", stock_tag, ".xlsx"))
  if (!file.exists(excel_path)) {
    cat(">> [EXCEL] PERINGATAN: workbook existing tidak ditemukan untuk", stock_name,
        "- update sheet dilewati (RDS tetap diperbarui).\n")
    return(invisible(FALSE))
  }
  
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  backup_xlsx <- file.path(PATH_BACKUP_DIR,
                           paste0(tools::file_path_sans_ext(basename(excel_path)), "_backup_", stamp, ".xlsx"))
  file.copy(excel_path, backup_xlsx, overwrite = TRUE)
  
  wb <- openxlsx::loadWorkbook(excel_path)
  sheet_names <- openxlsx::sheets(wb)
  
  filt_df <- daily_result$filtered_probability
  colnames(filt_df) <- c("Dates", paste0("Filtered_Prob_State", 1:(ncol(filt_df) - 1)))
  if ("Filtered Probability" %in% sheet_names) openxlsx::removeWorksheet(wb, "Filtered Probability")
  openxlsx::addWorksheet(wb, "Filtered Probability")
  openxlsx::writeData(wb, "Filtered Probability", filt_df)
  
  if ("Regime Classification" %in% sheet_names) openxlsx::removeWorksheet(wb, "Regime Classification")
  openxlsx::addWorksheet(wb, "Regime Classification")
  openxlsx::writeData(wb, "Regime Classification", daily_result$regime_classification)
  
  if ("Regime Forecast (t+1 to t+10)" %in% sheet_names) openxlsx::removeWorksheet(wb, "Regime Forecast (t+1 to t+10)")
  openxlsx::addWorksheet(wb, "Regime Forecast (t+1 to t+10)")
  openxlsx::writeData(wb, "Regime Forecast (t+1 to t+10)", daily_result$regime_forecast)
  
  audit_note <- data.frame(
    Update_Timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    Update_Mode = mode_label,
    Pipeline_Version = PIPELINE_VERSION,
    Catatan = paste0(
      "Sheet 'Filtered Probability', 'Regime Classification', dan 'Regime Forecast (t+1 to t+10)' ",
      "diperbarui oleh Hybrid_Incremental_Update.R mode ", mode_label, ". Sheet lain (Estimated Parameters, ",
      "Best Subset Selection, model diagnostics, dsb.) TIDAK diubah pada mode DAILY karena parameter model ",
      "tidak diestimasi ulang - lihat RDS metadata untuk detail lengkap. Untuk hasil lengkap identik dengan ",
      "run interaktif penuh 15092026.R, jalankan mode FULL."
    ), stringsAsFactors = FALSE
  )
  if ("Update Audit" %in% sheet_names) openxlsx::removeWorksheet(wb, "Update Audit")
  openxlsx::addWorksheet(wb, "Update Audit")
  openxlsx::writeData(wb, "Update Audit", audit_note)
  
  tmp_xlsx <- paste0(excel_path, ".tmp_", stamp)
  openxlsx::saveWorkbook(wb, tmp_xlsx, overwrite = TRUE)
  ok_rename <- file.rename(tmp_xlsx, excel_path)
  if (!isTRUE(ok_rename)) {
    unlink(tmp_xlsx)
    cat(">> [EXCEL] PERINGATAN: gagal menulis workbook final untuk", stock_name, "- backup tetap tersedia di", backup_xlsx, "\n")
    return(invisible(FALSE))
  }
  cat(">> [EXCEL] Workbook untuk", stock_name, "berhasil diperbarui (backup:", backup_xlsx, ")\n")
  invisible(TRUE)
}

run_full_mode <- function() {
  cat("\n#####################################################################\n")
  cat("#  MODE FULL - MENJALANKAN ULANG 15092026.R SECARA VERBATIM\n")
  cat("#####################################################################\n\n")
  
  t0 <- Sys.time()
  # [REFACTOR-NONINTERACTIVE] original patched the source text of the pipeline in memory to swap the
  # file.choose() block. The pipeline now reads these variables itself, so it runs VERBATIM.
  Sys.setenv(PIPELINE_INPUT_XLSX = PATH_NEW_DATA, PIPELINE_OUTPUT_DIR = PATH_OUTPUT_DIR,
             PIPELINE_SKIP_INTERACTIVE_MC = "true")
  tmp_script <- PATH_PIPELINE_SCRIPT
  HYBRID_STATUS$mode_executed <<- "FULL"
  
  full_env <- new.env(parent = globalenv())
  old_wd <- getwd()
  result_ok <- tryCatch({
    sys.source(tmp_script, envir = full_env, chdir = FALSE)
    TRUE
  }, error = function(e) {
    cat(">> [FULL MODE] ERROR saat menjalankan pipeline penuh:", conditionMessage(e), "\n")
    FALSE
  })
  setwd(old_wd)
  
  runtime <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  
  if (!isTRUE(result_ok)) {
    audit_add("ALL", "FULL_MODE", "FULL", "FULL_FAILED", "Lihat log console untuk detail error.", "GAGAL", runtime)
    HYBRID_STATUS$ok <<- FALSE; HYBRID_STATUS$note <<- "FULL pipeline raised an error (see console log)."
    return(invisible(NULL))
  }
  
  all_markov_models_new <- full_env$all_markov_models
  joint_distribution_model_new <- full_env$joint_distribution_model
  
  if (is.null(all_markov_models_new) || length(all_markov_models_new) == 0) {
    audit_add("ALL", "FULL_MODE", "FULL", "FULL_FAILED", "all_markov_models tidak terbentuk setelah eksekusi penuh.", "GAGAL", runtime)
    HYBRID_STATUS$ok <<- FALSE; HYBRID_STATUS$note <<- "all_markov_models empty after FULL."
    return(invisible(NULL))
  }
  
  for (stock in names(all_markov_models_new)) {
    all_markov_models_new[[stock]]$model_version <- MODEL_SCHEMA_VERSION
    all_markov_models_new[[stock]]$pipeline_version <- PIPELINE_VERSION
    all_markov_models_new[[stock]]$last_data_date <- max(all_markov_models_new[[stock]]$final_fit$last_actual_date)
    all_markov_models_new[[stock]]$last_model_date <- all_markov_models_new[[stock]]$final_fit$last_actual_date
    all_markov_models_new[[stock]]$last_recalibration_date <- Sys.Date()
    all_markov_models_new[[stock]]$update_mode <- "FULL"
    all_markov_models_new[[stock]]$data_fingerprint_input <- file_md5_safe(PATH_NEW_DATA)
  }
  
  safe_save_rds(all_markov_models_new, PATH_MARKOV_MODELS, PATH_BACKUP_DIR)
  if (!is.null(joint_distribution_model_new)) {
    safe_save_rds(joint_distribution_model_new, PATH_JOINT_MODEL, PATH_BACKUP_DIR)
  }
  
  audit_add("ALL", "FULL_MODE", "FULL", "FULL_RE-ESTIMATION",
            paste0(length(all_markov_models_new), " saham berhasil diestimasi ulang penuh."), "BERHASIL", runtime)
  HYBRID_STATUS$ok <<- TRUE; HYBRID_STATUS$saved <<- TRUE
  HYBRID_STATUS$n_stocks <<- length(all_markov_models_new); HYBRID_STATUS$n_updated <<- length(all_markov_models_new)
  HYBRID_STATUS$last_data_date <<- as.character(max(vapply(all_markov_models_new, function(m) as.character(max(m$final_fit$last_actual_date)), character(1))))
  
  invisible(list(all_markov_models = all_markov_models_new, joint_distribution_model = joint_distribution_model_new))
}

decide_mode_for_stock <- function(stock_name, model_entry, new_data_max_date, mode_config) {
  if (is.null(model_entry) || is.null(model_entry$final_fit)) {
    return(list(decision = "FULL", reason = "Model existing tidak ditemukan untuk saham ini."))
  }
  last_model_date <- model_entry$final_fit$last_actual_date
  if (is.null(last_model_date) || is.na(last_model_date)) {
    return(list(decision = "FULL", reason = "last_actual_date tidak tersedia pada model existing."))
  }
  if (new_data_max_date <= last_model_date) {
    return(list(decision = "UP_TO_DATE", reason = "Tidak ada observasi baru setelah last_actual_date model existing."))
  }
  if (mode_config == "FULL") return(list(decision = "FULL", reason = "MODE dipaksa FULL oleh konfigurasi."))
  if (mode_config == "DAILY") return(list(decision = "DAILY", reason = "MODE dipaksa DAILY oleh konfigurasi."))
  if (mode_config == "RECALIBRATE") return(list(decision = "RECALIBRATE", reason = "MODE dipaksa RECALIBRATE oleh konfigurasi."))
  
  last_recal <- model_entry$last_recalibration_date
  if (is.null(last_recal) || is.na(last_recal)) last_recal <- last_model_date
  days_since_recal <- as.numeric(Sys.Date() - as.Date(last_recal))
  if (days_since_recal >= RECALIBRATION_FREQUENCY_DAYS) {
    return(list(decision = "RECALIBRATE",
                reason = paste0("AUTO: ", days_since_recal, " hari sejak recalibration terakhir >= threshold (",
                                RECALIBRATION_FREQUENCY_DAYS, " hari).")))
  }
  list(decision = "DAILY", reason = paste0("AUTO: ", days_since_recal,
                                           " hari sejak recalibration terakhir < threshold - gunakan DAILY filtering."))
}

run_single_stock_update_job <- function(stock_name, decision_label, model_entry, raw_data_new, date_col,
                                        macro_cols_all, pipeline_env, tol_replica, n_starts_warmstart) {
  t0 <- Sys.time()
  if (decision_label == "DAILY") {
    res <- tryCatch(
      validate_and_extend_stock_daily(stock_name, model_entry, raw_data_new, date_col,
                                      macro_cols_all, pipeline_env, tol_replica),
      error = function(e) list(ok = FALSE, reason = conditionMessage(e))
    )
  } else if (decision_label == "RECALIBRATE") {
    res <- tryCatch(
      warmstart_reestimate_stock(stock_name, model_entry, raw_data_new, date_col,
                                 macro_cols_all, pipeline_env, n_starts_warmstart),
      error = function(e) list(ok = FALSE, reason = conditionMessage(e))
    )
  } else {
    res <- list(ok = FALSE, reason = paste0("decision_label tidak dikenali: ", decision_label))
  }
  runtime <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  list(stock_name = stock_name, decision_label = decision_label, res = res, runtime = runtime)
}

run_daily_or_recalibrate_all_stocks <- function() {
  if (!file.exists(PATH_MARKOV_MODELS)) {
    cat(">> Model existing tidak ditemukan - mengalihkan seluruh proses ke MODE FULL.\n")
    if (!ALLOW_FULL_FALLBACK) {
      cat(">> [FULL_REQUIRED] Fallback FULL dinonaktifkan pada job ini (batas waktu runner). Jalankan workflow dengan mode FULL.\n")
      HYBRID_STATUS$full_required <<- TRUE; HYBRID_STATUS$ok <<- FALSE
      HYBRID_STATUS$note <<- "No usable model: FULL is required but fallback is disabled in this job."
      if (!isTRUE(HYBRID_STATUS$fallback_full)) { HYBRID_STATUS$fallback_reason <<- "All_Markov_Models.rds not found (first run)" }
      return(invisible(NULL))
    }
    if (!isTRUE(HYBRID_STATUS$fallback_full)) {   # keep the more specific reason if corruption was already detected
      HYBRID_STATUS$fallback_full <<- TRUE; HYBRID_STATUS$fallback_reason <<- "All_Markov_Models.rds not found (first run)"
    }
    run_full_mode()
    return(invisible(NULL))
  }
  
  all_markov_models <- readRDS(PATH_MARKOV_MODELS)
  data_read <- read_and_clean_raw_data(PATH_NEW_DATA)
  raw_data_new <- data_read$raw_data
  date_col <- data_read$date_col
  cols_detected <- detect_stock_macro_columns(raw_data_new, date_col)
  macro_cols_all <- cols_detected$macro_cols
  new_data_max_date <- max(raw_data_new[[date_col]], na.rm = TRUE)
  
  stocks_needing_full <- character(0)
  needs_full_reasons <- list()
  n_updated <- 0L
  jobs <- list()
  HYBRID_STATUS$mode_executed <<- if (identical(MODE, "AUTO")) "AUTO" else MODE
  HYBRID_STATUS$n_stocks <<- length(all_markov_models)
  HYBRID_STATUS$last_data_date <<- as.character(new_data_max_date)
  HYBRID_STATUS$new_stock_columns_without_model <<- setdiff(cols_detected$stock_targets, names(all_markov_models))
  
  for (stock_name in names(all_markov_models)) {
    t0 <- Sys.time()
    model_entry <- all_markov_models[[stock_name]]
    decision <- decide_mode_for_stock(stock_name, model_entry, new_data_max_date, MODE)
    
    if (decision$decision == "UP_TO_DATE") {
      audit_add(stock_name, "MODE_DECISION", MODE, "UP_TO_DATE", decision$reason, "OK",
                as.numeric(difftime(Sys.time(), t0, units = "secs")))
      next
    }
    if (decision$decision == "FULL") {
      audit_add(stock_name, "MODE_DECISION", MODE, "FULL", decision$reason, "OK",
                as.numeric(difftime(Sys.time(), t0, units = "secs")))
      stocks_needing_full <- c(stocks_needing_full, stock_name)
      next
    }
    if (decision$decision == "RECALIBRATE" && isTRUE(RERUN_SELECTION_ON_RECALIBRATE)) {
      audit_add(stock_name, "RECALIBRATE", MODE, "FULL",
                "RERUN_SELECTION_ON_RECALIBRATE = TRUE - variable selection ulang hanya tersedia melalui MODE FULL untuk saham ini.",
                "DIALIHKAN KE FULL")
      stocks_needing_full <- c(stocks_needing_full, stock_name)
      next
    }
    audit_add(stock_name, "MODE_DECISION", MODE, decision$decision, decision$reason, "OK",
              as.numeric(difftime(Sys.time(), t0, units = "secs")))
    jobs[[stock_name]] <- list(stock_name = stock_name, decision_label = decision$decision, model_entry = model_entry)
  }
  
  if (length(jobs) == 0) {
    cat(">> Tidak ada saham yang memerlukan DAILY atau RECALIBRATE saat ini.\n")
  } else {
    n_workers <- min(N_CORES_HYBRID, length(jobs))
    use_parallel_now <- isTRUE(USE_PARALLEL_HYBRID) && length(jobs) >= PARALLEL_MIN_STOCKS && n_workers > 1
    
    job_results <- NULL
    if (use_parallel_now) {
      cat("\n>> [PARALLEL] Menjalankan", length(jobs), "job DAILY/RECALIBRATE pada", n_workers, "core secara paralel...\n")
      cl <- tryCatch(parallel::makeCluster(n_workers, outfile = ""), error = function(e) NULL)
      if (!is.null(cl)) {
        parallel::clusterEvalQ(cl, { suppressPackageStartupMessages({ library(numDeriv); library(Matrix) }) })
        parallel::clusterExport(cl, varlist = c(
          "PIPELINE_ENV", "rebuild_full_model_df", "build_design_matrix", "run_hamilton_and_smooth",
          "validate_and_extend_stock_daily", "theta_from_final_fit", "warmstart_reestimate_stock",
          "run_single_stock_update_job", "raw_data_new", "date_col", "macro_cols_all",
          "HISTORICAL_REPLICA_TOLERANCE", "N_STARTS_WARMSTART"
        ), envir = environment())
        job_results <- tryCatch(
          parallel::parLapply(cl, jobs, function(job) {
            run_single_stock_update_job(job$stock_name, job$decision_label, job$model_entry,
                                        raw_data_new, date_col, macro_cols_all, PIPELINE_ENV,
                                        HISTORICAL_REPLICA_TOLERANCE, N_STARTS_WARMSTART)
          }),
          error = function(e) {
            cat(">> [PARALLEL] ERROR pada eksekusi paralel:", conditionMessage(e), "- fallback ke SEKUENSIAL.\n")
            NULL
          }
        )
        parallel::stopCluster(cl)
      } else {
        cat(">> [PARALLEL] makeCluster() gagal - fallback ke eksekusi SEKUENSIAL.\n")
      }
    }
    
    if (is.null(job_results)) {
      cat("\n>> Menjalankan", length(jobs), "job DAILY/RECALIBRATE secara SEKUENSIAL...\n")
      job_results <- lapply(jobs, function(job) {
        run_single_stock_update_job(job$stock_name, job$decision_label, job$model_entry,
                                    raw_data_new, date_col, macro_cols_all, PIPELINE_ENV,
                                    HISTORICAL_REPLICA_TOLERANCE, N_STARTS_WARMSTART)
      })
    }
    
    for (jr in job_results) {
      stock_name <- jr$stock_name
      decision_label <- jr$decision_label
      res <- jr$res
      runtime <- jr$runtime
      
      if (!isTRUE(res$ok)) {
        stage_label <- if (decision_label == "DAILY") "DAILY_UPDATE" else "RECALIBRATE"
        audit_add(stock_name, stage_label, MODE, paste0(decision_label, "_FAILED"), res$reason,
                  "GAGAL - fallback FULL diperlukan", runtime)
        stocks_needing_full <- c(stocks_needing_full, stock_name)
        needs_full_reasons[[stock_name]] <- res$reason
        next
      }
      
      if (decision_label == "DAILY") {
        if (identical(res$status, "UP_TO_DATE")) {
          audit_add(stock_name, "DAILY_UPDATE", MODE, "UP_TO_DATE", "Tidak ada observasi baru.", "OK", runtime)
          next
        }
        all_markov_models[[stock_name]]$final_fit <- res$updated_final_fit
        all_markov_models[[stock_name]]$update_mode <- "DAILY"
        all_markov_models[[stock_name]]$last_model_date <- res$updated_final_fit$last_actual_date
        all_markov_models[[stock_name]]$last_data_date <- new_data_max_date
        all_markov_models[[stock_name]]$model_version <- MODEL_SCHEMA_VERSION
        all_markov_models[[stock_name]]$pipeline_version <- PIPELINE_VERSION
        all_markov_models[[stock_name]]$data_fingerprint_input <- file_md5_safe(PATH_NEW_DATA)
        if (!isTRUE(update_stock_excel(stock_name, res, PATH_OUTPUT_DIR, "DAILY"))) HYBRID_STATUS$excel_failed <<- c(HYBRID_STATUS$excel_failed, stock_name)
        n_updated <- n_updated + 1L
        audit_add(stock_name, "DAILY_UPDATE", MODE, "DAILY_FILTERING",
                  paste0(res$n_new, " observasi baru diproses via fixed-parameter recursive filtering (max diff vs historical replica = ",
                         format(res$max_diff_replica, scientific = TRUE), ")."), "BERHASIL", runtime)
      } else if (decision_label == "RECALIBRATE") {
        all_markov_models[[stock_name]]$final_fit <- res$updated_final_fit
        all_markov_models[[stock_name]]$update_mode <- "RECALIBRATE_WARMSTART"
        all_markov_models[[stock_name]]$last_model_date <- res$updated_final_fit$last_actual_date
        all_markov_models[[stock_name]]$last_data_date <- new_data_max_date
        all_markov_models[[stock_name]]$last_recalibration_date <- Sys.Date()
        all_markov_models[[stock_name]]$model_version <- MODEL_SCHEMA_VERSION
        all_markov_models[[stock_name]]$pipeline_version <- PIPELINE_VERSION
        all_markov_models[[stock_name]]$data_fingerprint_input <- file_md5_safe(PATH_NEW_DATA)
        if (!isTRUE(update_stock_excel(stock_name, res, PATH_OUTPUT_DIR, "RECALIBRATE_WARMSTART"))) HYBRID_STATUS$excel_failed <<- c(HYBRID_STATUS$excel_failed, stock_name)
        n_updated <- n_updated + 1L
        audit_add(stock_name, "RECALIBRATE", MODE, "WARMSTART_RECALIBRATION",
                  paste0("Re-estimasi warm-start selesai dengan ", res$n_obs_used, " observasi (theta0 dari model sebelumnya)."),
                  "BERHASIL", runtime)
      }
    }
  }
  
  HYBRID_STATUS$n_updated <<- n_updated
  HYBRID_STATUS$needs_full <<- stocks_needing_full
  HYBRID_STATUS$needs_full_reasons <<- needs_full_reasons
  HYBRID_STATUS$n_up_to_date <<- length(all_markov_models) - n_updated - length(stocks_needing_full)
  
  if (length(stocks_needing_full) > 0 && isTRUE(STRICT_ATOMIC)) {
    cat("\n>> [STRICT_ATOMIC] ", length(stocks_needing_full), " saham memerlukan FULL (", paste(utils::head(stocks_needing_full, 10), collapse = ", "),
        "...). TIDAK ADA artefak yang disimpan agar tidak terbentuk model set campuran (sebagian t, sebagian t-1).\n", sep = "")
    HYBRID_STATUS$ok <<- FALSE; HYBRID_STATUS$saved <<- FALSE
    HYBRID_STATUS$note <<- "DAILY validation failed for >=1 stock; nothing saved (strict atomic)."
    return(invisible(NULL))
  }
  if (n_updated == 0L && length(stocks_needing_full) == 0L) {
    cat("\n>> [UP_TO_DATE] Tidak ada observasi baru untuk model manapun - RDS TIDAK ditulis ulang.\n")
    HYBRID_STATUS$ok <<- TRUE; HYBRID_STATUS$saved <<- FALSE; HYBRID_STATUS$note <<- "UP_TO_DATE"
    return(invisible(all_markov_models))
  }
  safe_save_rds(all_markov_models, PATH_MARKOV_MODELS, PATH_BACKUP_DIR)
  HYBRID_STATUS$ok <<- (length(stocks_needing_full) == 0L); HYBRID_STATUS$saved <<- TRUE
  
  if (length(stocks_needing_full) > 0) {
    cat("\n>> Saham berikut memerlukan MODE FULL (skema tidak kompatibel / validasi gagal / revisi data historis):\n   ",
        paste(stocks_needing_full, collapse = ", "), "\n")
    cat(">> Jalankan run_full_mode() secara terpisah, atau set MODE <- \"FULL\" dan jalankan ulang skrip ini,\n")
    cat("   untuk memproses saham-saham tersebut. Tidak dilakukan fallback otomatis diam-diam.\n")
  }
  
  invisible(all_markov_models)
}

run_validation_daily_vs_full <- function(stock_name, cutoff_date) {
  cat("\n#####################################################################\n")
  cat("#  VALIDATION MODE: DAILY vs FULL untuk", stock_name, "pada cutoff", as.character(cutoff_date), "\n")
  cat("#####################################################################\n\n")
  
  if (!file.exists(PATH_MARKOV_MODELS)) {
    stop("run_validation_daily_vs_full(): model existing tidak ditemukan, jalankan MODE FULL terlebih dahulu.")
  }
  all_markov_models <- readRDS(PATH_MARKOV_MODELS)
  model_entry <- all_markov_models[[stock_name]]
  if (is.null(model_entry)) stop("Saham tidak ditemukan pada model existing: ", stock_name)
  
  data_read <- read_and_clean_raw_data(PATH_NEW_DATA)
  raw_data_new <- data_read$raw_data
  date_col <- data_read$date_col
  cols_detected <- detect_stock_macro_columns(raw_data_new, date_col)
  macro_cols_all <- cols_detected$macro_cols
  
  raw_data_cutoff <- raw_data_new[raw_data_new[[date_col]] <= cutoff_date, ]
  
  daily_res <- tryCatch(
    validate_and_extend_stock_daily(stock_name, model_entry, raw_data_cutoff, date_col,
                                    macro_cols_all, PIPELINE_ENV, HISTORICAL_REPLICA_TOLERANCE),
    error = function(e) list(ok = FALSE, reason = conditionMessage(e))
  )
  
  if (!isTRUE(daily_res$ok)) {
    cat(">> [VALIDATION] DAILY filtering gagal:", daily_res$reason, "\n")
    return(invisible(NULL))
  }
  
  recal_res <- tryCatch(
    warmstart_reestimate_stock(stock_name, model_entry, raw_data_cutoff, date_col,
                               macro_cols_all, PIPELINE_ENV, N_STARTS_WARMSTART),
    error = function(e) list(ok = FALSE, reason = conditionMessage(e))
  )
  
  cat("\n>> [VALIDATION] Ringkasan Perbandingan DAILY (fixed-parameter filtering) vs WARM-START RECALIBRATION:\n")
  cat("   DAILY   - Filtered_Prob (baris terakhir)      :",
      paste(round(tail(daily_res$filtered_probability, 1)[, -1], 6), collapse = " / "), "\n")
  if (isTRUE(recal_res$ok)) {
    cat("   RECAL   - Filtered_Prob (baris terakhir)      :",
        paste(round(tail(recal_res$filtered_probability, 1)[, -1], 6), collapse = " / "), "\n")
    cat("   Catatan: DAILY mempertahankan parameter LAMA (beta_mat/sigma_vec/trans_mat tetap), sedangkan\n")
    cat("   RECALIBRATE mengestimasi ULANG seluruh parameter (warm-start). Perbedaan pada filtered probability\n")
    cat("   adalah KONSEKUENSI DESAIN HYBRID yang diharapkan apabila parameter berubah signifikan - BUKAN bug.\n")
    beta_diff <- max(abs(daily_res$updated_final_fit$beta_mat - recal_res$updated_final_fit$beta_mat))
    cat("   Max abs diff beta_mat (DAILY-lama vs RECAL-baru):", format(beta_diff, scientific = TRUE), "\n")
  } else {
    cat("   RECALIBRATE gagal:", recal_res$reason, "\n")
  }
  
  invisible(list(daily = daily_res, recalibrate = recal_res))
}

cat("\n#####################################################################\n")
cat("#  HYBRID INCREMENTAL UPDATE - Markov Regime Switching Pipeline\n")
cat("#  PIPELINE_VERSION:", PIPELINE_VERSION, " | MODE:", MODE, "\n")
cat("#####################################################################\n\n")

if (!file.exists(PATH_NEW_DATA)) {
  stop("Dataset tidak ditemukan pada ", PATH_NEW_DATA, " (HYBRID_WORK_DIR=", BASE_DIR, ").")
}

# A model RDS that exists but cannot be read is a corrupted state: do not crash silently, route to FULL.
if (file.exists(PATH_MARKOV_MODELS) && MODE %in% c("DAILY", "RECALIBRATE", "AUTO")) {
  .probe <- tryCatch(readRDS(PATH_MARKOV_MODELS), error = function(e) NULL)
  if (is.null(.probe) || !is.list(.probe) || length(.probe) == 0) {
    cat(">> [STATE] All_Markov_Models.rds tidak dapat dibaca / kosong -> dianggap rusak, dialihkan ke FULL.\n")
    HYBRID_STATUS$fallback_full <- TRUE; HYBRID_STATUS$fallback_reason <- "All_Markov_Models.rds unreadable/empty"
    unlink(PATH_MARKOV_MODELS)
  }
  rm(.probe)
}

if (MODE == "FULL") {
  run_full_mode()
} else if (MODE %in% c("DAILY", "RECALIBRATE", "AUTO")) {
  run_daily_or_recalibrate_all_stocks()
} else {
  stop("MODE tidak dikenali: ", MODE, " - gunakan salah satu dari FULL, DAILY, RECALIBRATE, AUTO.")
}

audit_log_path <- file.path(PATH_AUDIT_LOG_DIR, paste0("AuditLog_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv"))
write.csv(AUDIT_LOG, audit_log_path, row.names = FALSE)
cat("\n>> Audit log tersimpan pada:", audit_log_path, "\n")

HYBRID_STATUS$audit_log <- basename(audit_log_path)
jsonlite::write_json(HYBRID_STATUS, PATH_STATUS_JSON, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
cat(">> Status hybrid tersimpan pada:", PATH_STATUS_JSON, " | ok =", HYBRID_STATUS$ok, "| saved =", HYBRID_STATUS$saved, "\n")
if (!isTRUE(HYBRID_STATUS$ok)) quit(save = "no", status = 2)
