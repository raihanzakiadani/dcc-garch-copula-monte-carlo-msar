# Synthetic-world builder for DAILY-mode tests. Parameters are FIXED (not estimated): the point is to
# exercise the real Hybrid_Incremental_Update.R filtering/validation code with controlled data.
suppressPackageStartupMessages({ library(openxlsx); library(jsonlite) })

extract_functions <- function(file, names, env) {
  exprs <- parse(file, keep.source = FALSE)
  for (e in exprs) {
    if (is.call(e) && identical(e[[1]], as.name("<-")) && is.name(e[[2]]) &&
        as.character(e[[2]]) %in% names && is.call(e[[3]]) && identical(e[[3]][[1]], as.name("function"))) {
      eval(e, envir = env)
    }
  }
  missing <- setdiff(names, ls(env)); if (length(missing)) stop("not found: ", paste(missing, collapse = ","))
  env
}

PIPE_FUNS <- c("calc_log_return", "detect_suspend_blocks", "detect_transformation_type", "transform_series",
               "hamilton_filter", "kim_smoother", "classify_regimes_by_sigma", "forecast_regime_prob")
HYB_FUNS  <- c("rebuild_full_model_df", "build_design_matrix", "run_hamilton_and_smooth")

make_raw <- function(n, seed = 11) {
  set.seed(seed)
  d <- seq(as.Date("2024-01-01"), by = "day", length.out = n * 2); d <- d[!(format(d, "%u") %in% c("6", "7"))][1:n]
  jci  <- 7000 * exp(cumsum(rnorm(n, 0, 0.008)))
  xau  <- 2000 * exp(cumsum(rnorm(n, 0, 0.006)))
  gt   <- 6.5 + cumsum(rnorm(n, 0, 0.01))
  reg  <- numeric(n); s <- 1; for (i in 1:n) { s <- if (runif(1) < ifelse(s == 1, 0.05, 0.1)) 3 - s else s; reg[i] <- s }
  mk <- function(b, a) { r <- 0.0005 + b * diff(c(log(jci[1]), log(jci))) + rnorm(n, 0, ifelse(reg == 1, 0.01, 0.03)); 1000 * exp(cumsum(r)) }
  co1 <- 80 * exp(cumsum(rnorm(n, 0, 0.012))); ko1 <- 4500 * exp(cumsum(rnorm(n, 0, 0.01)))
  data.frame(Dates = d, `JCI Index` = round(jci, 3), `XAU Curncy` = round(xau, 2), `GTIDR1Y Govt` = round(gt, 3),
             `CO1 Comdty` = round(co1, 2), `KO1 Comdty` = round(ko1, 0),
             `AAAA IJ EQUITY` = round(mk(0.4), 0), `BBBB IJ EQUITY` = round(mk(0.7), 0), check.names = FALSE)
}

fit_entry <- function(raw, stock, pipe, hyb, upto) {
  d <- raw[raw$Dates <= upto, ]
  macros <- c("JCI Index", "XAU Curncy", "GTIDR1Y Govt", "CO1 Comdty", "KO1 Comdty")
  lag_cols <- "AR1"; sel <- c("JCI Index", "XAU Curncy", "CO1 Comdty", "KO1 Comdty")
  coef_names <- c("(Intercept)", sel, "AR1")
  df <- hyb$rebuild_full_model_df(d, "Dates", stock, macros, sel, 1L, lag_cols, pipe)
  dm <- hyb$build_design_matrix(df, stock, coef_names, lag_cols, sel)
  ff <- list(beta_mat = matrix(c(0.0005, 0.4, 0.02, 0.01, 0.01, 0.05, -0.0010, 0.7, -0.02, 0.0, 0.02, -0.05), nrow = 6),
             sigma_vec = c(0.01, 0.03), trans_mat = matrix(c(0.95, 0.05, 0.10, 0.90), 2, 2), k = 2L,
             nu_vec = NULL, lag_cols = lag_cols, coef_names = coef_names)
  res <- hyb$run_hamilton_and_smooth(dm$y, dm$X, ff, pipe)
  ff$filt_prob <- res$filt; ff$smo_prob <- res$smo; ff$logLik <- res$loglik
  ff$last_actual_date <- max(df$Dates)
  ff$last_actual_lags <- setNames(rev(tail(df[[stock]], 1L)), lag_cols)
  ff$yesterday_close_price <- tail(d[[stock]], 1)
  list(final_fit = ff, selected_variables = sel, ar_order_p = 1L, last_recalibration_date = Sys.Date())
}

# Build <dir> as a production-like state: raw_data.xlsx (n_hist rows) + models + per-stock workbooks.
make_state <- function(dir, n_total = 320, n_hist = 300, repo = getwd(), with_models = TRUE) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  raw <- make_raw(n_total)
  pipe <- extract_functions(file.path(repo, "pipeline/15092026.R"), PIPE_FUNS, new.env(parent = globalenv()))
  hyb  <- extract_functions(file.path(repo, "pipeline/Hybrid_Incremental_Update.R"), HYB_FUNS, new.env(parent = globalenv()))
  environment(hyb$rebuild_full_model_df) <- hyb
  for (nm in HYB_FUNS) environment(hyb[[nm]]) <- hyb
  hyb$pipeline_env <- NULL
  upto <- raw$Dates[n_hist]
  write.xlsx(raw[1:n_hist, ], file.path(dir, "raw_data.xlsx"))
  if (with_models) {
    models <- list()
    for (st in c("AAAA IJ EQUITY", "BBBB IJ EQUITY")) {
      models[[st]] <- fit_entry(raw, st, pipe, hyb, upto)
      tag <- gsub("[^A-Za-z0-9]", "_", st)
      wb <- createWorkbook(); addWorksheet(wb, "Estimated Parameters"); writeData(wb, 1, data.frame(x = 1))
      saveWorkbook(wb, file.path(dir, paste0("Output_MarkovRegimeSwitching_", tag, ".xlsx")), overwrite = TRUE)
    }
    saveRDS(models, file.path(dir, "All_Markov_Models.rds"))
    saveRDS(list(variabel_makro = c("JCI Index", "XAU Curncy", "GTIDR1Y Govt", "CO1 Comdty", "KO1 Comdty"),
                 marginal_models = list(a = 1), copula_terbaik = list(fit = 1)),
            file.path(dir, "JointDistribution_Model.rds"))
  }
  invisible(raw)
}

append_days <- function(dir, raw, n_hist, n_new) {
  write.xlsx(raw[1:(n_hist + n_new), ], file.path(dir, "raw_data.xlsx"))
}

run_hybrid <- function(workdir, mode, repo = getwd(), extra_env = character(0)) {
  run_dir <- file.path(workdir, "_run"); if (dir.exists(run_dir)) unlink(run_dir, recursive = TRUE)
  env <- c(HYBRID_WORK_DIR = workdir, PIPELINE_SCRIPT = file.path(repo, "pipeline/15092026.R"),
           PIPELINE_RUN_DIR = run_dir, PIPELINE_MODE = mode, HYBRID_N_CORES = "1", extra_env)
  out <- suppressWarnings(system2("Rscript", file.path(repo, "pipeline/Hybrid_Incremental_Update.R"),
                                  env = paste0(names(env), "=", env), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status"); if (is.null(st)) st <- 0L
  sj <- file.path(run_dir, "hybrid_status.json")
  list(exit = st, log = out, status = if (file.exists(sj)) fromJSON(sj) else NULL)
}
