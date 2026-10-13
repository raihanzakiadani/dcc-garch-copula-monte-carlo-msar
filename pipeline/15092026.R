rm(list = ls())
graphics.off()
options(scipen = 999, stringsAsFactors = FALSE)
set.seed(123)

required_packages <- c(
  "readxl",
  "openxlsx",
  "dplyr",
  "lubridate",
  "tseries",
  "moments",
  "car",
  "corrplot",
  "MASS",
  "ggplot2",
  "gridExtra",
  "scales",
  "reshape2",
  "zoo",
  "tibble",
  "rugarch",
  "rmgarch",
  "copula",
  "numDeriv",
  "Matrix",
  "foreach",
  "doParallel",
  "doRNG",
  "future",
  "future.apply"
)

# [REFACTOR-NONINTERACTIVE] original: require() + install.packages() on every run.
# Now: packages must be pre-installed (scripts/install_deps.R, pinned snapshot) - fail fast if not.
.missing_pkgs <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(.missing_pkgs) > 0) {
  stop("Paket R belum terpasang: ", paste(.missing_pkgs, collapse = ", "),
       " - jalankan scripts/install_deps.R (tidak ada install.packages() otomatis pada pipeline).")
}
for (pkg in required_packages) library(pkg, character.only = TRUE)

cat("=========================================================\n")
cat(" SELURUH PACKAGE BERHASIL DIPERIKSA / DIMUAT              \n")
cat("=========================================================\n\n")

# [REFACTOR-NONINTERACTIVE] original: choose.files()/file.choose() + setwd(dirname(input)).
# Now: input/output come from environment variables set by the orchestrator (R/run_pipeline.R).
input_path <- Sys.getenv("PIPELINE_INPUT_XLSX", unset = "")
output_dir <- Sys.getenv("PIPELINE_OUTPUT_DIR", unset = "")
if (!nzchar(input_path) || !file.exists(input_path)) {
  stop("PIPELINE_INPUT_XLSX tidak di-set atau file tidak ada: '", input_path, "'. ",
       "Pipeline tidak lagi interaktif (tidak ada file.choose()).")
}
if (!nzchar(output_dir)) output_dir <- dirname(input_path)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
input_path <- normalizePath(input_path, winslash = "/", mustWork = TRUE)
output_dir <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)
setwd(output_dir)   # staging directory of THIS run (never a personal/laptop path)

# =============================================================================================
# [REFACTOR-SHARDING] Optional stage split so FULL can run as several short GitHub jobs
# (GitHub-hosted jobs are hard-limited to 6 h). Default PIPELINE_STAGE="all" = the original single run.
#   joint : data prep + macro ARMA-GARCH + DCC-GARCH/Copula; saves macro_stage.rds for the shard jobs; stops.
#   stocks: loads macro_stage.rds and estimates ONLY the stocks of shard PIPELINE_SHARD_INDEX (of PIPELINE_SHARD_COUNT); saves the shard; stops.
#   merge : loads macro_stage.rds + ALL shards (validated), then runs the original post-loop code unchanged.
# Statistics are unchanged: same functions, same arguments, and each stock keeps its ORIGINAL future.seed RNG stream
# (the full stock list is kept and non-shard stocks are skipped inside the worker function).
# =============================================================================================
PIPELINE_STAGE <- tolower(Sys.getenv("PIPELINE_STAGE", unset = "all"))
if (!PIPELINE_STAGE %in% c("all", "joint", "stocks", "merge")) {
  stop("PIPELINE_STAGE harus salah satu dari all, joint, stocks, merge (diterima: '", PIPELINE_STAGE, "')")
}
PIPELINE_SHARD_DIR   <- Sys.getenv("PIPELINE_SHARD_DIR", unset = file.path(output_dir, "_shards"))
PIPELINE_SHARD_INDEX <- suppressWarnings(as.integer(Sys.getenv("PIPELINE_SHARD_INDEX", unset = "1")))
PIPELINE_SHARD_COUNT <- suppressWarnings(as.integer(Sys.getenv("PIPELINE_SHARD_COUNT", unset = "1")))
if (PIPELINE_STAGE == "stocks" && (is.na(PIPELINE_SHARD_INDEX) || is.na(PIPELINE_SHARD_COUNT) ||
                                   PIPELINE_SHARD_COUNT < 1L || PIPELINE_SHARD_INDEX < 1L || PIPELINE_SHARD_INDEX > PIPELINE_SHARD_COUNT)) {
  stop("PIPELINE_SHARD_INDEX/PIPELINE_SHARD_COUNT tidak valid: ", PIPELINE_SHARD_INDEX, "/", PIPELINE_SHARD_COUNT)
}
RUN_MACRO_AND_JOINT <- PIPELINE_STAGE %in% c("all", "joint")
MACRO_STAGE_FILE    <- file.path(PIPELINE_SHARD_DIR, "macro_stage.rds")
PIPELINE_INPUT_MD5  <- unname(tools::md5sum(input_path))
.stage_t0           <- Sys.time()

pipeline_shard_stocks <- function(stock_targets, index, count) {
  stock_targets[((seq_along(stock_targets) - 1L) %% count) + 1L == index]     # deterministic round-robin
}

pipeline_save_rds_atomic <- function(obj, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp_", Sys.getpid())
  saveRDS(obj, tmp)
  if (is.null(readRDS(tmp))) stop("verifikasi tulis gagal: ", path)
  if (!file.rename(tmp, path)) stop("gagal memindahkan ", tmp, " -> ", path)
  invisible(path)
}

pipeline_save_macro_stage <- function(file, macro_processed_df, macro_cols, stock_targets, input_md5) {
  pipeline_save_rds_atomic(list(macro_processed_df = macro_processed_df, macro_cols = macro_cols,
                                stock_targets = stock_targets, input_md5 = input_md5), file)
}

pipeline_load_macro_stage <- function(file, macro_cols, stock_targets, input_md5) {
  if (!file.exists(file)) stop("macro_stage.rds tidak ditemukan (", file, "): jalankan tahap 'joint' lebih dulu.")
  ms <- readRDS(file)
  if (!identical(ms$input_md5, input_md5)) stop("macro_stage.rds berasal dari raw_data.xlsx yang BERBEDA dari input tahap ini.")
  if (!identical(ms$macro_cols, macro_cols)) stop("macro_cols pada macro_stage.rds tidak sama dengan dataset saat ini.")
  if (!identical(ms$stock_targets, stock_targets)) stop("stock_targets pada macro_stage.rds tidak sama dengan dataset saat ini.")
  if (!is.data.frame(ms$macro_processed_df) || !all(macro_cols %in% names(ms$macro_processed_df))) stop("macro_processed_df tidak valid.")
  ms$macro_processed_df
}

pipeline_save_shard <- function(shard_dir, index, count, stock_targets, all_results, input_md5, seconds) {
  mine <- pipeline_shard_stocks(stock_targets, index, count)
  res  <- all_results[mine]
  names(res) <- mine
  pipeline_save_rds_atomic(list(index = index, count = count, stocks = mine, results = res, input_md5 = input_md5,
                                seconds = seconds, n_ok = sum(!vapply(res, is.null, logical(1)))),
                           file.path(shard_dir, sprintf("shard_%03d.rds", index)))
  invisible(mine)
}

pipeline_load_shards <- function(shard_dir, stock_targets, input_md5) {
  files <- list.files(shard_dir, pattern = "^shard_[0-9]+\\.rds$", full.names = TRUE)
  if (length(files) == 0) stop("tidak ada shard_*.rds pada ", shard_dir)
  shards <- lapply(files, readRDS)
  counts <- unique(vapply(shards, function(x) as.integer(x$count), integer(1)))
  if (length(counts) != 1L) stop("shard memiliki PIPELINE_SHARD_COUNT berbeda-beda: ", paste(counts, collapse = ","))
  idx <- sort(vapply(shards, function(x) as.integer(x$index), integer(1)))
  if (!identical(idx, seq_len(counts))) stop("shard tidak lengkap/ganda. Ada: ", paste(idx, collapse = ","), " | seharusnya 1..", counts)
  for (x in shards) {
    if (!identical(x$input_md5, input_md5)) stop("shard ", x$index, " dihitung dari raw_data.xlsx yang BERBEDA.")
    if (!identical(x$stocks, pipeline_shard_stocks(stock_targets, x$index, counts))) stop("daftar saham shard ", x$index, " tidak sesuai partisi.")
  }
  all_results <- setNames(vector("list", length(stock_targets)), stock_targets)
  for (x in shards) for (st in x$stocks) all_results[st] <- list(x$results[[st]])      # list(NULL) keeps failed stocks as NULL
  attr(all_results, "shard_seconds") <- vapply(shards[order(vapply(shards, function(x) x$index, numeric(1)))], function(x) as.numeric(x$seconds), numeric(1))
  all_results
}


cat("File input       :", input_path, "\n")
cat("Output directory :", output_dir, "\n\n")

plots_root <- file.path(output_dir, "Plots")
if (!dir.exists(plots_root)) dir.create(plots_root)


calc_log_return <- function(price_vector) {
  price_vector <- as.numeric(price_vector)
  lr <- c(NA, diff(log(price_vector)))
  return(lr)
}

detect_suspend_blocks <- function(price_vector, min_run = 3) {
  price_vector <- as.numeric(price_vector)
  n <- length(price_vector)
  if (n < min_run) {
    return(list(suspend_idx = integer(0), post_resume_idx = integer(0),
                blocks = data.frame(Block = integer(0), Start_Idx = integer(0),
                                    End_Idx = integer(0), N_Obs = integer(0))))
  }
  same_as_prev <- c(FALSE, !is.na(price_vector[-1]) & !is.na(price_vector[-n]) &
                      (price_vector[-1] == price_vector[-n]))
  run_id <- cumsum(!same_as_prev)
  run_len <- as.integer(ave(seq_len(n), run_id, FUN = length))
  suspend_mask <- run_len >= min_run & !is.na(price_vector)
  suspend_idx <- which(suspend_mask)
  blocks <- data.frame(Block = integer(0), Start_Idx = integer(0),
                       End_Idx = integer(0), N_Obs = integer(0))
  post_resume_idx <- integer(0)
  if (length(suspend_idx) > 0) {
    rid <- run_id[suspend_idx]
    split_idx <- split(suspend_idx, rid)
    blocks <- do.call(rbind, lapply(split_idx, function(ix) {
      data.frame(Block = NA_integer_, Start_Idx = min(ix), End_Idx = max(ix), N_Obs = length(ix))
    }))
    blocks <- blocks[order(blocks$Start_Idx), , drop = FALSE]
    blocks$Block <- seq_len(nrow(blocks))
    rownames(blocks) <- NULL
    post_resume_idx <- blocks$End_Idx + 1
    post_resume_idx <- post_resume_idx[post_resume_idx <= n]
  }
  list(suspend_idx = suspend_idx, post_resume_idx = post_resume_idx, blocks = blocks)
}

descriptive_stats_one <- function(x, var_name) {
  x <- x[!is.na(x)]
  n <- length(x)
  
  jb <- tryCatch(tseries::jarque.bera.test(x), error = function(e) NULL)
  
  data.frame(
    Variable          = var_name,
    N_Obs             = n,
    Mean              = mean(x),
    Median            = median(x),
    Min               = min(x),
    Max               = max(x),
    SD                = sd(x),
    Variance          = var(x),
    Skewness          = moments::skewness(x),
    Kurtosis          = moments::kurtosis(x),
    CoefVariation_pct = (sd(x) / mean(x)) * 100,
    JarqueBera_Stat   = if (!is.null(jb)) unname(jb$statistic) else NA,
    JarqueBera_pvalue = if (!is.null(jb)) jb$p.value else NA,
    Normality_Decision = if (!is.null(jb)) {
      ifelse(jb$p.value < 0.05, "Tidak Normal (tolak H0)", "Normal (gagal tolak H0)")
    } else NA,
    stringsAsFactors = FALSE
  )
}

auto_stationarity_test <- function(x, var_name, max_diff = 2, alpha = 0.05) {
  
  series <- x[!is.na(x)]
  d <- 0
  results <- list()
  
  repeat {
    adf <- tryCatch(tseries::adf.test(series, alternative = "stationary"),
                    error = function(e) NULL)
    kpss <- tryCatch(tseries::kpss.test(series, null = "Level"),
                     error = function(e) NULL)
    
    adf_stat  <- if (!is.null(adf)) unname(adf$statistic) else NA
    adf_p     <- if (!is.null(adf)) adf$p.value else NA
    kpss_stat <- if (!is.null(kpss)) unname(kpss$statistic) else NA
    kpss_p    <- if (!is.null(kpss)) kpss$p.value else NA
    
    is_stationary_adf  <- !is.na(adf_p) && adf_p < alpha
    is_stationary_kpss <- !is.na(kpss_p) && kpss_p > alpha
    
    results[[length(results) + 1]] <- data.frame(
      Variable        = var_name,
      Diff_Order      = d,
      ADF_Statistic   = adf_stat,
      ADF_pvalue      = adf_p,
      ADF_Decision    = ifelse(is_stationary_adf, "Stasioner", "Tidak Stasioner"),
      KPSS_Statistic  = kpss_stat,
      KPSS_pvalue     = kpss_p,
      KPSS_Decision   = ifelse(is_stationary_kpss, "Stasioner", "Tidak Stasioner"),
      Final_Decision  = ifelse(is_stationary_adf, "STASIONER", "NON-STASIONER"),
      stringsAsFactors = FALSE
    )
    
    if (is_stationary_adf || d >= max_diff) break
    
    series <- diff(series)
    d <- d + 1
  }
  
  final_table <- do.call(rbind, results)
  final_series_length <- length(series)
  
  list(
    table       = final_table,
    final_d     = d,
    final_series = series,
    stationary  = is_stationary_adf
  )
}

safe_slot <- function(obj, expr_list, default = NA) {
  for (expr in expr_list) {
    val <- tryCatch(eval(parse(text = expr)), error = function(e) NULL)
    if (!is.null(val)) return(val)
  }
  return(default)
}

expected_duration <- function(p_ii) {
  ifelse(p_ii >= 1, Inf, 1 / (1 - p_ii))
}

theme_thesis <- function() {
  theme_minimal(base_size = 12) +
    theme(
      plot.title       = element_text(face = "bold", size = 14, hjust = 0),
      plot.subtitle    = element_text(size = 10, color = "grey30"),
      axis.title       = element_text(face = "bold", size = 11),
      panel.grid.minor = element_blank(),
      legend.position  = "bottom",
      legend.title     = element_text(face = "bold"),
      plot.caption     = element_text(size = 8, color = "grey40")
    )
}

save_plot_hd <- function(plot_obj, filename, folder, width = 10, height = 6) {
  ggsave(filename = file.path(folder, paste0(filename, ".png")),
         plot = plot_obj, width = width, height = height, dpi = 300, bg = "white")
  ggsave(filename = file.path(folder, paste0(filename, ".pdf")),
         plot = plot_obj, width = width, height = height, bg = "white")
}

build_trans_matrix <- function(eta, k) {
  eta_mat <- matrix(eta, nrow = k - 1, ncol = k)
  P <- matrix(NA, nrow = k, ncol = k)
  for (j in 1:k) {
    logits <- c(eta_mat[, j], 0)
    probs  <- exp(logits) / sum(exp(logits))
    P[, j] <- probs
  }
  return(P)
}

invert_trans_matrix <- function(P, k) {
  eta <- numeric(k * (k - 1))
  idx <- 1
  for (j in 1:k) {
    p_ref <- P[k, j]
    for (i in 1:(k - 1)) {
      eta[idx] <- log(P[i, j] / p_ref)
      idx <- idx + 1
    }
  }
  return(eta)
}

hamilton_filter <- function(y, X, beta_mat, sigma_vec, P, k, dist = "norm", nu_vec = NULL) {
  Tt <- length(y)
  xi_pred <- matrix(NA, nrow = k, ncol = Tt)
  xi_filt <- matrix(NA, nrow = k, ncol = Tt)
  
  # [OPTIMASI - VEKTORISASI] mu dan densitas dihitung sekaligus untuk seluruh T x k
  # (operasi matriks), bukan dipanggil ulang per-t di dalam loop filter. Nilai yang
  # dihasilkan matematis identik dengan versi sapply per-t sebelumnya.
  mu_mat <- X %*% beta_mat  # T x k
  dens_mat <- matrix(NA_real_, nrow = Tt, ncol = k)
  if (dist == "t") {
    for (i in 1:k) {
      z_i <- (y - mu_mat[, i]) / sigma_vec[i]
      dens_mat[, i] <- stats::dt(z_i, df = nu_vec[i]) / sigma_vec[i]
    }
  } else {
    for (i in 1:k) {
      dens_mat[, i] <- dnorm(y, mean = mu_mat[, i], sd = sigma_vec[i])
    }
  }
  dens_mat[!is.finite(dens_mat) | dens_mat < 1e-300] <- 1e-300
  
  A <- rbind(diag(k) - P, rep(1, k))
  b <- c(rep(0, k), 1)
  ergodic <- tryCatch({
    sol <- qr.solve(A, b)
    sol[sol < 0] <- 0
    sol / sum(sol)
  }, error = function(e) rep(1 / k, k))
  
  loglik <- 0
  for (t in 1:Tt) {
    pred_t <- if (t == 1) ergodic else as.numeric(P %*% xi_filt[, t - 1])
    
    numerator <- dens_mat[t, ] * pred_t
    denom <- sum(numerator)
    if (!is.finite(denom) || denom <= 0) denom <- 1e-300
    
    xi_pred[, t] <- pred_t
    xi_filt[, t] <- numerator / denom
    loglik <- loglik + log(denom)
  }
  
  list(loglik = loglik, filt = xi_filt, pred = xi_pred, mu_mat = mu_mat, dens_mat = dens_mat)
}

kim_smoother <- function(xi_filt, xi_pred, P, k) {
  Tt <- ncol(xi_filt)
  xi_smooth <- matrix(NA, nrow = k, ncol = Tt)
  xi_smooth[, Tt] <- xi_filt[, Tt]
  
  for (t in (Tt - 1):1) {
    ratio <- xi_smooth[, t + 1] / xi_pred[, t + 1]
    ratio[!is.finite(ratio)] <- 0
    xi_smooth[, t] <- xi_filt[, t] * as.numeric(t(P) %*% ratio)
    s <- sum(xi_smooth[, t])
    if (s > 0) xi_smooth[, t] <- xi_smooth[, t] / s
  }
  return(xi_smooth)
}

negloglik_ms <- function(theta, y, X, k, n_params) {
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
  
  P <- tryCatch(build_trans_matrix(eta, k), error = function(e) NULL)
  if (is.null(P) || any(!is.finite(P))) return(1e10)
  
  res <- tryCatch(hamilton_filter(y, X, beta_mat, sigma_vec, P, k),
                  error = function(e) NULL)
  if (is.null(res) || !is.finite(res$loglik)) return(1e10)
  
  return(-res$loglik)
}

# [OPTIMASI - GRADIEN ANALITIK] Gradien dari negative log-likelihood model MS-Gaussian,
# dipakai sebagai argumen gr= pada optim() supaya L-BFGS-B tidak perlu menghitung gradien
# numerik (finite-difference) yang butuh (n_params+1) evaluasi hamilton_filter per iterasi.
#
# Metode: Fisher's identity / EM-gradient (standar untuk model Hidden Markov, lih. Hamilton
# 1994 Ch.22; Cappe, Moulines & Ryden 2005) - turunan blok beta & log-sigma dihitung eksak
# secara analitik dari probabilitas smoothed (Kim smoother). Blok eta (parameter transisi,
# selalu berjumlah k*(k-1) = 2 karena model ditetapkan k=2) dihitung via central
# finite-difference murah, karena turunan distribusi awal (ergodik) terhadap eta melibatkan
# differensiasi implisit yang rumit dan kontribusinya kecil - dua evaluasi tambahan per
# parameter eta ini praktis tidak menambah beban dibanding blok beta/sigma yang jumlahnya
# jauh lebih banyak (n_params x k). Sudah divalidasi: hasil identik dengan gradien numerik
# penuh sampai presisi floating-point, dan titik konvergen optim() sama dengan versi tanpa
# gradien analitik (lihat validasi terpisah sebelum revisi ini diterapkan).
neggrad_ms_gaussian <- function(theta, y, X, k, n_params) {
  n_beta_block  <- n_params * k
  n_sigma_block <- k
  n_eta_block   <- k * (k - 1)
  
  idx_beta  <- 1:n_beta_block
  idx_sigma <- (n_beta_block + 1):(n_beta_block + n_sigma_block)
  idx_eta   <- (n_beta_block + n_sigma_block + 1):(n_beta_block + n_sigma_block + n_eta_block)
  
  beta_mat  <- matrix(theta[idx_beta], nrow = n_params, ncol = k)
  log_sigma <- theta[idx_sigma]
  sigma_vec <- exp(log_sigma)
  eta       <- theta[idx_eta]
  
  P <- tryCatch(build_trans_matrix(eta, k), error = function(e) NULL)
  if (is.null(P) || any(!is.finite(P))) return(rep(0, length(theta)))
  
  f <- tryCatch(hamilton_filter(y, X, beta_mat, sigma_vec, P, k), error = function(e) NULL)
  if (is.null(f) || !is.finite(f$loglik)) return(rep(0, length(theta)))
  
  xi_filt <- f$filt; xi_pred <- f$pred; mu_mat <- f$mu_mat
  Tt <- length(y)
  
  xi_smooth <- matrix(NA_real_, nrow = k, ncol = Tt)
  xi_smooth[, Tt] <- xi_filt[, Tt]
  
  grad_beta <- matrix(0, nrow = n_params, ncol = k)
  grad_logsigma <- numeric(k)
  
  add_emission_grad <- function(t) {
    resid_t <- y[t] - mu_mat[t, ]
    for (i in 1:k) {
      grad_beta[, i] <<- grad_beta[, i] + xi_smooth[i, t] * X[t, ] * resid_t[i] / sigma_vec[i]^2
      grad_logsigma[i] <<- grad_logsigma[i] + xi_smooth[i, t] * (-1 + (resid_t[i]^2) / sigma_vec[i]^2)
    }
  }
  add_emission_grad(Tt)
  for (t in (Tt - 1):1) {
    ratio <- xi_smooth[, t + 1] / xi_pred[, t + 1]
    ratio[!is.finite(ratio)] <- 0
    xi_smooth[, t] <- xi_filt[, t] * as.numeric(t(P) %*% ratio)
    s <- sum(xi_smooth[, t])
    if (s > 0) xi_smooth[, t] <- xi_smooth[, t] / s
    add_emission_grad(t)
  }
  
  g_analytic <- -c(as.numeric(grad_beta), grad_logsigma)  # gradien beta+sigma (negloglik)
  
  eps <- 1e-6
  g_eta <- numeric(n_eta_block)
  for (m in seq_len(n_eta_block)) {
    tp <- theta; tp[idx_eta[m]] <- tp[idx_eta[m]] + eps
    tm <- theta; tm[idx_eta[m]] <- tm[idx_eta[m]] - eps
    g_eta[m] <- (negloglik_ms(tp, y, X, k, n_params) - negloglik_ms(tm, y, X, k, n_params)) / (2 * eps)
  }
  
  c(g_analytic, g_eta)
}

generate_initial_theta <- function(base_lm, k, n_params, jitter_sd = 0) {
  beta_ols  <- as.numeric(coef(base_lm))
  sigma_ols <- summary(base_lm)$sigma
  
  beta_start <- numeric(0)
  logsigma_start <- numeric(k)
  spread <- seq(-1, 1, length.out = k)
  
  for (i in 1:k) {
    beta_i <- beta_ols
    beta_i[1] <- beta_i[1] + spread[i] * sigma_ols * 0.5
    if (jitter_sd > 0) beta_i <- beta_i + rnorm(n_params, 0, jitter_sd)
    beta_start <- c(beta_start, beta_i)
    logsigma_start[i] <- log(sigma_ols * (1 + 0.5 * abs(spread[i]) + 1e-6))
  }
  
  diag_val <- 0.92
  P0 <- matrix((1 - diag_val) / (k - 1), nrow = k, ncol = k)
  diag(P0) <- diag_val
  eta_start <- invert_trans_matrix(P0, k)
  
  c(beta_start, logsigma_start, eta_start)
}

build_lbfgsb_bounds <- function(k, n_params, n_extra_blocks = 0,
                                bound_log_sigma = 15, bound_extra = 15, bound_eta = 30) {
  n_beta  <- k * n_params
  n_sigma <- k
  n_eta   <- k * (k - 1)
  n_extra <- n_extra_blocks * k
  
  lower <- c(rep(-Inf, n_beta), rep(-bound_log_sigma, n_sigma),
             rep(-bound_extra, n_extra), rep(-bound_eta, n_eta))
  upper <- c(rep(Inf, n_beta), rep(bound_log_sigma, n_sigma),
             rep(bound_extra, n_extra), rep(bound_eta, n_eta))
  
  list(lower = lower, upper = upper)
}

numerical_gradient <- function(fn, par, eps = 1e-6, ...) {
  n <- length(par)
  grad <- numeric(n)
  for (i in 1:n) {
    par_plus  <- par; par_plus[i]  <- par[i] + eps
    par_minus <- par; par_minus[i] <- par[i] - eps
    grad[i] <- (fn(par_plus, ...) - fn(par_minus, ...)) / (2 * eps)
  }
  grad
}

run_one_start <- function(s, base_lm, k, n_params, bounds, y, X, compute_hessian = TRUE,
                          screening_mode = c("standard", "fast_screening")) {
  screening_mode <- match.arg(screening_mode)
  jitter <- if (s == 1) 0 else 0.15
  theta0 <- generate_initial_theta(base_lm, k, n_params, jitter_sd = jitter)
  
  # [OPTIMASI - TOLERANSI BERTINGKAT] Tahap "fast_screening" (khusus pemilihan orde AR)
  # hanya perlu ranking BIC yang benar antar kandidat, bukan presisi estimasi akhir, jadi
  # toleransinya boleh jauh lebih longgar. Model final tetap pakai toleransi ketat seperti
  # semula (factr = 1e7, pgtol = 1e-8) - rigor hasil akhir tidak berubah sama sekali.
  optim_control <- if (isTRUE(compute_hessian)) {
    list(maxit = 2000, factr = 1e7, pgtol = 1e-8, trace = 0)
  } else if (screening_mode == "fast_screening") {
    list(maxit = 150, factr = 1e10, pgtol = 1e-5, trace = 0)
  } else {
    list(maxit = 300, factr = 1e9, pgtol = 1e-6, trace = 0)
  }
  
  err_msg <- NULL
  opt <- tryCatch(
    optim(par = theta0, fn = negloglik_ms, gr = neggrad_ms_gaussian,
          y = y, X = X, k = k, n_params = n_params,
          method = "L-BFGS-B", lower = bounds$lower, upper = bounds$upper,
          hessian = isTRUE(compute_hessian), control = optim_control),
    error = function(e) { err_msg <<- conditionMessage(e); NULL }
  )
  
  success <- !is.null(opt) && is.finite(opt$value)
  list(success = success, opt = opt, theta0 = theta0, start = s, error_message = err_msg)
}

fit_direct_mle <- function(k, base_lm, model_df, stock_name, n_starts = 5, compute_hessian = TRUE,
                           screening_mode = c("standard", "fast_screening")) {
  screening_mode <- match.arg(screening_mode)
  
  y <- model_df[[stock_name]]
  X <- model.matrix(base_lm)
  colnames(X) <- gsub("^`|`$", "", colnames(X))
  n_params <- ncol(X)
  
  bounds <- build_lbfgsb_bounds(k, n_params, n_extra_blocks = 0)
  
  best <- NULL
  best_theta0 <- NULL
  all_starts_log <- data.frame()
  cat(">> [Direct MLE - L-BFGS-B] Estimasi model k =", k, "regime dengan", n_starts, "starting values...\n")
  
  optim_start_time <- Sys.time()
  
  n_cores <- 1
  cl <- if (n_cores > 1) tryCatch(parallel::makeCluster(n_cores), error = function(e) NULL) else NULL
  
  if (!is.null(cl)) {
    doParallel::registerDoParallel(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    doRNG::registerDoRNG(123)
    
    start_results <- foreach::foreach(
      s = 1:n_starts,
      .export = c("run_one_start", "negloglik_ms", "neggrad_ms_gaussian", "generate_initial_theta",
                  "build_lbfgsb_bounds", "invert_trans_matrix", "build_trans_matrix",
                  "hamilton_filter"),
      .packages = c("stats")
    ) %dopar% {
      run_one_start(s, base_lm, k, n_params, bounds, y, X, compute_hessian = compute_hessian,
                    screening_mode = screening_mode)
    }
  } else {
    start_results <- lapply(1:n_starts, function(s)
      run_one_start(s, base_lm, k, n_params, bounds, y, X, compute_hessian = compute_hessian,
                    screening_mode = screening_mode))
  }
  
  for (res in start_results) {
    if (isTRUE(res$success)) {
      opt <- res$opt
      s   <- res$start
      cat("   >> Start", s, "- NegLogLik =", round(opt$value, 4),
          "| convergence code =", opt$convergence, "\n")
      all_starts_log <- rbind(all_starts_log, data.frame(
        Start = s, NegLogLik = opt$value, LogLik = -opt$value, Convergence_Code = opt$convergence
      ))
      if (is.null(best) || opt$value < best$value) { best <- opt; best_theta0 <- res$theta0 }
    } else if (!is.null(res$error_message)) {
      cat("   >> Start", res$start, "gagal dieksekusi:", res$error_message, "\n")
    }
  }
  
  
  computation_time_sec <- as.numeric(difftime(Sys.time(), optim_start_time, units = "secs"))
  
  if (is.null(best)) {
    cat(">> ERROR: Seluruh multi-start optimisasi (k =", k, ") gagal konvergen.\n")
    return(NULL)
  }
  
  if (isTRUE(compute_hessian)) {
    optim_trace_raw <- tryCatch(
      capture.output(
        invisible(optim(par = best_theta0, fn = negloglik_ms, gr = neggrad_ms_gaussian,
                        y = y, X = X, k = k, n_params = n_params,
                        method = "L-BFGS-B", lower = bounds$lower, upper = bounds$upper, hessian = FALSE,
                        control = list(maxit = 2000, factr = 1e7, pgtol = 1e-8, trace = 1, REPORT = 1)))
      ), error = function(e) character(0)
    )
    value_lines <- grep("value", optim_trace_raw, value = TRUE)
    optim_trace_df <- if (length(value_lines) > 0) {
      extract_num <- function(s) {
        s <- trimws(s)
        toks <- strsplit(s, "\\s+")[[1]]
        suppressWarnings(as.numeric(toks[length(toks)]))
      }
      step_label <- ifelse(grepl("^initial", value_lines), "Starting Value",
                           ifelse(grepl("^final", value_lines), "Final (Converged)",
                                  gsub("^iter\\s*([0-9]+).*", "Iterasi \\1", value_lines)))
      df <- data.frame(Tahap = step_label, NegLogLik = sapply(value_lines, extract_num),
                       stringsAsFactors = FALSE)
      df$LogLik <- -df$NegLogLik
      rownames(df) <- NULL
      n_df <- nrow(df)
      keep_idx <- unique(c(1, 2, 3, n_df))
      keep_idx <- keep_idx[keep_idx >= 1 & keep_idx <= n_df]
      df[keep_idx, ]
    } else {
      data.frame(Tahap = c("Starting Value", "Final (Converged)"),
                 NegLogLik = c(NA, best$value), LogLik = c(NA, -best$value))
    }
  } else {
    optim_trace_df <- data.frame(Tahap = c("Starting Value", "Final (Converged)"),
                                 NegLogLik = c(NA, best$value), LogLik = c(NA, -best$value),
                                 Catatan = "Jejak iterasi lengkap dilewati untuk model KANDIDAT (efisiensi) - tersedia untuk model FINAL.")
  }
  
  if (isTRUE(compute_hessian)) {
    refine_outcome <- tryCatch({
      pre_grad <- tryCatch(
        neggrad_ms_gaussian(best$par, y = y, X = X, k = k, n_params = n_params),
        error = function(e) rep(NA_real_, length(best$par))
      )
      pre_grad_norm <- sqrt(sum(pre_grad^2, na.rm = TRUE))
      GRADIENT_NORM_REFINE_THRESHOLD <- 1e-3
      needs_refinement <- (!is.finite(pre_grad_norm)) ||
        (pre_grad_norm > GRADIENT_NORM_REFINE_THRESHOLD) || (best$convergence != 0)
      
      if (isTRUE(needs_refinement)) {
        cat(">> [REFINEMENT] Gradient norm k =", k, "=", round(pre_grad_norm, 6),
            "(convergence code =", best$convergence, ") - refinement multi-start tambahan...\n")
        
        N_REFINEMENT_STARTS <- 4
        refinement_candidates <- list(list(par = best$par, value = best$value,
                                           convergence = best$convergence, grad_norm = pre_grad_norm))
        
        for (r in seq_len(N_REFINEMENT_STARTS)) {
          jitter_sd_r <- stats::runif(1, min = 0.005, max = 0.05)
          par0_r <- best$par + stats::rnorm(length(best$par), mean = 0, sd = jitter_sd_r)
          par0_r <- pmin(pmax(par0_r, bounds$lower), bounds$upper)
          
          opt_r <- tryCatch(
            optim(par = par0_r, fn = negloglik_ms, gr = neggrad_ms_gaussian,
                  y = y, X = X, k = k, n_params = n_params,
                  method = "L-BFGS-B", lower = bounds$lower, upper = bounds$upper, hessian = FALSE,
                  control = list(maxit = 2000, factr = 1e7, pgtol = 1e-9)),
            error = function(e) NULL
          )
          if (is.null(opt_r) || !is.finite(opt_r$value)) next
          
          grad_r <- tryCatch(
            neggrad_ms_gaussian(opt_r$par, y = y, X = X, k = k, n_params = n_params),
            error = function(e) rep(NA_real_, length(opt_r$par))
          )
          grad_norm_r <- sqrt(sum(grad_r^2, na.rm = TRUE))
          
          refinement_candidates[[length(refinement_candidates) + 1]] <- list(
            par = opt_r$par, value = opt_r$value, convergence = opt_r$convergence, grad_norm = grad_norm_r
          )
        }
        
        converged_ok <- Filter(function(cand) isTRUE(cand$convergence == 0) && is.finite(cand$grad_norm), refinement_candidates)
        pool_for_selection <- if (length(converged_ok) > 0) converged_ok else refinement_candidates
        values_pool <- sapply(pool_for_selection, function(cand) cand$value)
        gradnorm_pool <- sapply(pool_for_selection, function(cand) ifelse(is.finite(cand$grad_norm), cand$grad_norm, Inf))
        best_idx_pool <- order(values_pool, gradnorm_pool)[1]
        best_refined <- pool_for_selection[[best_idx_pool]]
        
        if (is.finite(best_refined$value) && best_refined$value <= best$value + 1e-6 &&
            is.finite(best_refined$grad_norm) && best_refined$grad_norm <= pre_grad_norm) {
          list(refined = TRUE, par = best_refined$par, value = best_refined$value,
               convergence = best_refined$convergence, grad_norm = best_refined$grad_norm,
               grad_norm_before = pre_grad_norm)
        } else {
          list(refined = FALSE, grad_norm_before = pre_grad_norm)
        }
      } else {
        list(refined = FALSE, grad_norm_before = pre_grad_norm)
      }
    }, error = function(e) {
      cat(">> [REFINEMENT] PERINGATAN: refinement gagal dieksekusi (", conditionMessage(e),
          ") - solusi multi-start semula tetap dipertahankan.\n")
      list(refined = FALSE, grad_norm_before = NA_real_)
    })
    
    if (isTRUE(refine_outcome$refined)) {
      best$par         <- refine_outcome$par
      best$value       <- refine_outcome$value
      best$convergence <- refine_outcome$convergence
      cat(">> [REFINEMENT] Solusi diperbaiki - gradient norm baru =", round(refine_outcome$grad_norm, 6),
          "(sebelumnya", round(refine_outcome$grad_norm_before, 6), "), NegLogLik =", round(best$value, 6),
          ", convergence code =", best$convergence, "\n")
    }
  }
  
  n_theta <- length(best$par)
  
  if (isTRUE(compute_hessian)) {
    hess_result <- robust_hessian_vcov(
      objective_fn = negloglik_ms, par = best$par, y = y, X = X, k = k, n_params = n_params,
      convergence_code = best$convergence, rank_tol = 1e-8,
      fallback_hessian = best$hessian, model_label = paste0("Gaussian, k = ", k)
    )
    
    best$hessian <- hess_result$hessian
    hess_diag  <- hess_result$hess_diag
    vcov_mat   <- hess_result$vcov_mat
    se_theta   <- hess_result$se_theta
    hessian_ok <- hess_result$hessian_ok
    se_valid   <- hess_result$se_valid
    wald_valid <- hess_result$wald_valid
    
    if (!isTRUE(hessian_ok)) {
      cat(">> PERINGATAN: Hessian pada model k =", k, "TIDAK positive definite (",
          hess_diag$n_negative_eigenvalues, "dari", length(best$par),
          "eigenvalue <= toleransi 1e-8) walaupun telah dihitung ulang via numDeriv::hessian()",
          "(Richardson Extrapolation) dan dikoreksi via Matrix::nearPD() (Higham, 2002). Sesuai",
          "regularity conditions MLE (Self & Liang, 1987), pseudo-inverse TIDAK dipakai sebagai",
          "dasar inferensi utama. Seluruh standard error, z-statistic, Wald statistic, p-value,",
          "dan confidence interval diisi NA (last resort) - estimasi parameter & log-likelihood",
          "TETAP VALID dan ditampilkan.\n")
    }
    
    hess_eigen <- hess_diag$eigenvalues
    hess_condition_number <- hess_diag$condition_number
  } else {
    cat("   >> [EFISIENSI] compute_hessian = FALSE - Hessian & SE dilewati untuk model k =", k,
        "(hanya LogLik/AIC/BIC/HQIC/convergence dipakai pada tahap pemilihan model).\n")
    hess_diag              <- NULL
    vcov_mat               <- matrix(NA_real_, n_theta, n_theta)
    se_theta               <- rep(NA_real_, n_theta)
    hessian_ok             <- NA
    se_valid               <- NA
    wald_valid             <- NA
    hess_eigen             <- rep(NA_real_, n_theta)
    hess_condition_number  <- NA_real_
  }
  
  final_gradient <- tryCatch(
    neggrad_ms_gaussian(best$par, y = y, X = X, k = k, n_params = n_params),
    error = function(e) rep(NA_real_, length(best$par))
  )
  gradient_norm <- sqrt(sum(final_gradient^2, na.rm = TRUE))
  
  theta <- best$par
  idx <- 1
  beta_mat <- matrix(NA, nrow = n_params, ncol = k)
  se_beta  <- matrix(NA, nrow = n_params, ncol = k)
  for (i in 1:k) {
    beta_mat[, i] <- theta[idx:(idx + n_params - 1)]
    se_beta[, i]  <- se_theta[idx:(idx + n_params - 1)]
    idx <- idx + n_params
  }
  log_sigma   <- theta[idx:(idx + k - 1)]
  se_logsigma <- se_theta[idx:(idx + k - 1)]
  sigma_vec   <- exp(log_sigma)
  se_sigma    <- sigma_vec * se_logsigma
  idx <- idx + k
  eta <- theta[idx:(idx + k * (k - 1) - 1)]
  se_eta <- se_theta[idx:(idx + k * (k - 1) - 1)]
  P <- build_trans_matrix(eta, k)
  
  filt_res <- hamilton_filter(y, X, beta_mat, sigma_vec, P, k)
  smo_prob <- kim_smoother(filt_res$filt, filt_res$pred, P, k)
  
  list(
    k            = k,
    n_params     = n_params,
    theta        = theta,
    beta_mat     = beta_mat,
    se_beta      = se_beta,
    sigma_vec    = sigma_vec,
    se_sigma     = se_sigma,
    eta          = eta,
    se_eta       = se_eta,
    trans_mat    = P,
    filt_prob    = t(filt_res$filt),
    smo_prob     = t(smo_prob),
    logLik       = -best$value,
    convergence  = best$convergence,
    convergence_message = if (!is.null(best$message)) best$message else NA_character_,
    n_iter       = unname(best$counts[1]),
    n_iter_grad  = unname(best$counts[2]),
    hessian_ok   = hessian_ok,
    se_valid     = se_valid,
    wald_valid   = wald_valid,
    coef_names   = colnames(X),
    hessian_mat  = best$hessian,
    vcov_mat     = vcov_mat,
    hessian_eigenvalues = hess_eigen,
    hessian_condition_number = hess_condition_number,
    hessian_diagnostics = hess_diag,
    gradient_norm = gradient_norm,
    computation_time_sec = computation_time_sec,
    optim_trace  = optim_trace_df,
    theta0_winning = best_theta0,
    all_starts_log = all_starts_log,
    optimizer_used = "L-BFGS-B"
  )
}

diagnose_hessian_numerics <- function(hessian_mat, param_names = NULL,
                                      convergence_code = NA,
                                      boundary_params = NULL,
                                      rank_tol = 1e-8) {
  p <- nrow(hessian_mat)
  if (is.null(param_names)) param_names <- paste0("P", seq_len(p))
  
  eig <- tryCatch(eigen(hessian_mat, symmetric = TRUE, only.values = TRUE)$values,
                  error = function(e) rep(NA_real_, p))
  eig_finite <- eig[is.finite(eig)]
  
  is_pd <- length(eig_finite) == p && all(eig_finite > rank_tol)
  n_negative_eig <- sum(eig_finite <= rank_tol)
  
  cond_number <- if (length(eig_finite) > 0 && min(abs(eig_finite)) > 0) {
    max(abs(eig_finite)) / min(abs(eig_finite))
  } else NA
  
  rcond_value <- tryCatch(rcond(hessian_mat), error = function(e) NA_real_)
  det_value <- if (length(eig_finite) == p) tryCatch(prod(eig_finite), error = function(e) NA_real_) else NA_real_
  
  rank_hess <- tryCatch(qr(hessian_mat, tol = rank_tol)$rank, error = function(e) NA)
  is_singular <- !is.na(rank_hess) && rank_hess < p
  
  vcov_approx <- tryCatch({
    v <- solve(hessian_mat)
    if (any(diag(v) < 0)) stop("negative variance")
    v
  }, error = function(e) tryCatch(MASS::ginv(hessian_mat), error = function(e2) NULL))
  
  high_corr_pairs <- data.frame()
  if (!is.null(vcov_approx) && p > 1) {
    corr_mat <- tryCatch(cov2cor(vcov_approx), error = function(e) NULL)
    if (!is.null(corr_mat)) {
      for (i in 1:(p - 1)) for (j in (i + 1):p) {
        cij <- corr_mat[i, j]
        if (!is.na(cij) && abs(cij) > 0.95) {
          high_corr_pairs <- rbind(high_corr_pairs, data.frame(
            Param_1 = param_names[i], Param_2 = param_names[j], Correlation = cij
          ))
        }
      }
    }
  }
  
  diagnosis <- character(0)
  if (is_pd) {
    diagnosis <- c(diagnosis, "Hessian positive definite - tidak ada indikasi masalah numerik pada titik optimum.")
  } else {
    if (n_negative_eig > 0) {
      diagnosis <- c(diagnosis, paste0(n_negative_eig, " dari ", p, " eigenvalue Hessian <= toleransi (",
                                       rank_tol, ") - titik optimum yang ditemukan tidak memenuhi second-order ",
                                       "condition secara penuh (indikasi saddle point atau konvergensi prematur)."))
    }
    if (is_singular) {
      diagnosis <- c(diagnosis, paste0("Hessian singular/near-singular (rank numerik = ", rank_hess, " dari ", p,
                                       " parameter) - mengindikasikan parameter tidak teridentifikasi penuh ",
                                       "(identification problem, lih. Hamilton, 1994, Ch.22; Psaradakis & Spagnolo, 2003)."))
    }
    if (!is.na(cond_number) && cond_number > 1e6) {
      diagnosis <- c(diagnosis, paste0("Condition number Hessian sangat besar (",
                                       format(cond_number, scientific = TRUE, digits = 3),
                                       ") - indikasi multikolinearitas parameter / model over-parameterized ",
                                       "relatif terhadap informasi yang tersedia dalam data (Belsley, Kuh & Welsch, 1980)."))
    }
    if (nrow(high_corr_pairs) > 0) {
      diagnosis <- c(diagnosis, paste0(nrow(high_corr_pairs), " pasangan parameter memiliki korelasi > 0.95 - ",
                                       "indikasi kuat non-identifiability lokal antar parameter tersebut."))
    }
  }
  if (!is.null(boundary_params) && length(boundary_params) > 0) {
    diagnosis <- c(diagnosis, paste0("Parameter mendekati batas ruang parameter terdeteksi: ",
                                     paste(boundary_params, collapse = "; "),
                                     " - MLE pada/dekat batas parameter dapat menyebabkan Hessian singular ",
                                     "dan distribusi asimtotik non-standar (Self & Liang, 1987)."))
  }
  if (!is.na(convergence_code) && convergence_code != 0) {
    diagnosis <- c(diagnosis, paste0("Convergence code optimizer = ", convergence_code,
                                     " (bukan 0) - optimisasi kemungkinan belum konvergen sempurna."))
  }
  if (length(diagnosis) == 0) diagnosis <- "Tidak ada indikasi masalah numerik teridentifikasi."
  
  list(
    is_positive_definite = is_pd, n_negative_eigenvalues = n_negative_eig, eigenvalues = eig,
    min_eigenvalue = if (length(eig_finite) > 0) min(eig_finite) else NA_real_,
    max_eigenvalue = if (length(eig_finite) > 0) max(eig_finite) else NA_real_,
    condition_number = cond_number, reciprocal_condition_number = rcond_value,
    determinant = det_value, rank = rank_hess, full_rank_expected = p,
    is_singular = is_singular, high_correlation_pairs = high_corr_pairs,
    diagnosis_text = diagnosis, convergence_code = convergence_code
  )
}

robust_hessian_vcov <- function(objective_fn, par, ..., convergence_code = NA,
                                rank_tol = 1e-8, fallback_hessian = NULL,
                                model_label = "") {
  
  p <- length(par)
  
  eig_is_pd <- function(H) {
    ev <- tryCatch(eigen(H, symmetric = TRUE, only.values = TRUE)$values,
                   error = function(e) rep(NA_real_, p))
    ev_finite <- ev[is.finite(ev)]
    isTRUE(length(ev_finite) == p && all(ev_finite > rank_tol))
  }
  
  hessian_new <- tryCatch(
    numDeriv::hessian(func = objective_fn, x = par, ...),
    error = function(e) {
      warning(paste0("[REFACTOR] numDeriv::hessian() gagal dieksekusi",
                     if (nzchar(model_label)) paste0(" (", model_label, ")") else "",
                     ": ", conditionMessage(e),
                     " - fallback ke Hessian bawaan optim()."))
      NULL
    }
  )
  if (is.null(hessian_new)) hessian_new <- fallback_hessian
  
  final_hessian <- hessian_new
  
  if (isTRUE(eig_is_pd(hessian_new))) {
    vcov_mat   <- solve(hessian_new)
    se_theta   <- suppressWarnings(sqrt(diag(vcov_mat)))
    hessian_ok <- TRUE
    se_valid   <- TRUE
    wald_valid <- TRUE
  } else {
    H_near_result <- tryCatch(
      Matrix::nearPD(hessian_new, corr = FALSE, keepDiag = FALSE, do2eigen = TRUE),
      error = function(e) {
        warning(paste0("[REFACTOR] Matrix::nearPD() gagal dieksekusi",
                       if (nzchar(model_label)) paste0(" (", model_label, ")") else "",
                       ": ", conditionMessage(e), "."))
        NULL
      }
    )
    
    if (!is.null(H_near_result)) {
      H_near <- as.matrix(H_near_result$mat)
      final_hessian <- H_near
      if (isTRUE(eig_is_pd(H_near))) {
        vcov_mat   <- solve(H_near)
        se_theta   <- suppressWarnings(sqrt(diag(vcov_mat)))
        hessian_ok <- TRUE
        se_valid   <- TRUE
        wald_valid <- TRUE
      } else {
        message(paste0("[REFACTOR] Hessian", if (nzchar(model_label)) paste0(" (", model_label, ")") else "",
                       " tetap TIDAK positive definite setelah koreksi Matrix::nearPD() - ",
                       "SE/Wald/CI diisi NA (last resort)."))
        vcov_mat   <- matrix(NA_real_, p, p)
        se_theta   <- rep(NA_real_, p)
        hessian_ok <- FALSE
        se_valid   <- FALSE
        wald_valid <- FALSE
      }
    } else {
      vcov_mat   <- matrix(NA_real_, p, p)
      se_theta   <- rep(NA_real_, p)
      hessian_ok <- FALSE
      se_valid   <- FALSE
      wald_valid <- FALSE
    }
  }
  
  hess_diag <- diagnose_hessian_numerics(
    final_hessian, param_names = paste0("theta_", seq_along(par)),
    convergence_code = convergence_code, rank_tol = rank_tol
  )
  
  list(
    hessian    = final_hessian,
    vcov_mat   = vcov_mat,
    se_theta   = se_theta,
    hessian_ok = hessian_ok,
    se_valid   = se_valid,
    wald_valid = wald_valid,
    hess_diag  = hess_diag
  )
}
negloglik_ms_t <- function(theta, y, X, k, n_params) {
  idx <- 1
  beta_mat <- matrix(NA, nrow = n_params, ncol = k)
  for (i in 1:k) {
    beta_mat[, i] <- theta[idx:(idx + n_params - 1)]
    idx <- idx + n_params
  }
  log_sigma <- theta[idx:(idx + k - 1)]
  sigma_vec <- exp(log_sigma)
  idx <- idx + k
  gamma_nu <- theta[idx:(idx + k - 1)]
  nu_vec <- 2 + exp(gamma_nu)
  idx <- idx + k
  eta <- theta[idx:(idx + k * (k - 1) - 1)]
  
  P <- tryCatch(build_trans_matrix(eta, k), error = function(e) NULL)
  if (is.null(P) || any(!is.finite(P))) return(1e10)
  
  res <- tryCatch(hamilton_filter(y, X, beta_mat, sigma_vec, P, k, dist = "t", nu_vec = nu_vec),
                  error = function(e) NULL)
  if (is.null(res) || !is.finite(res$loglik)) return(1e10)
  
  return(-res$loglik)
}

generate_initial_theta_t <- function(base_lm, k, n_params, jitter_sd = 0, nu_start = 8) {
  base_gaussian <- generate_initial_theta(base_lm, k, n_params, jitter_sd = jitter_sd)
  beta_block     <- base_gaussian[1:(k * n_params)]
  logsigma_block <- base_gaussian[(k * n_params + 1):(k * n_params + k)]
  eta_block      <- base_gaussian[(k * n_params + k + 1):length(base_gaussian)]
  gamma_nu_block <- rep(log(nu_start - 2), k)
  c(beta_block, logsigma_block, gamma_nu_block, eta_block)
}

run_one_start_t <- function(s, base_lm, k, n_params, bounds, y, X, compute_hessian = TRUE) {
  jitter <- if (s == 1) 0 else 0.15
  theta0 <- generate_initial_theta_t(base_lm, k, n_params, jitter_sd = jitter)
  
  optim_control <- if (isTRUE(compute_hessian)) {
    list(maxit = 2000, factr = 1e7, pgtol = 1e-8, trace = 0)
  } else {
    list(maxit = 300, factr = 1e9, pgtol = 1e-6, trace = 0)
  }
  
  err_msg <- NULL
  opt <- tryCatch(
    optim(par = theta0, fn = negloglik_ms_t, y = y, X = X, k = k, n_params = n_params,
          method = "L-BFGS-B", lower = bounds$lower, upper = bounds$upper,
          hessian = isTRUE(compute_hessian), control = optim_control),
    error = function(e) { err_msg <<- conditionMessage(e); NULL }
  )
  
  success <- !is.null(opt) && is.finite(opt$value)
  list(success = success, opt = opt, theta0 = theta0, start = s, error_message = err_msg)
}

fit_direct_mle_t <- function(k, base_lm, model_df, stock_name, n_starts = 5, compute_hessian = TRUE) {
  
  y <- model_df[[stock_name]]
  X <- model.matrix(base_lm)
  colnames(X) <- gsub("^`|`$", "", colnames(X))
  n_params <- ncol(X)
  
  bounds <- build_lbfgsb_bounds(k, n_params, n_extra_blocks = 1)
  
  best <- NULL
  best_theta0 <- NULL
  all_starts_log <- data.frame()
  cat(">> [Direct MLE - L-BFGS-B, Student-t] Estimasi model k =", k, "regime dengan", n_starts, "starting values...\n")
  
  optim_start_time <- Sys.time()
  
  n_cores <- 1
  cl <- if (n_cores > 1) tryCatch(parallel::makeCluster(n_cores), error = function(e) NULL) else NULL
  
  if (!is.null(cl)) {
    doParallel::registerDoParallel(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    doRNG::registerDoRNG(123)
    
    start_results <- foreach::foreach(
      s = 1:n_starts,
      .export = c("run_one_start_t", "negloglik_ms_t", "generate_initial_theta_t",
                  "build_lbfgsb_bounds", "invert_trans_matrix", "build_trans_matrix",
                  "hamilton_filter"),
      .packages = c("stats")
    ) %dopar% {
      run_one_start_t(s, base_lm, k, n_params, bounds, y, X, compute_hessian = compute_hessian)
    }
  } else {
    start_results <- lapply(1:n_starts, function(s)
      run_one_start_t(s, base_lm, k, n_params, bounds, y, X, compute_hessian = compute_hessian))
  }
  
  for (res in start_results) {
    if (isTRUE(res$success)) {
      opt <- res$opt
      s   <- res$start
      cat("   >> Start", s, "(Student-t) - NegLogLik =", round(opt$value, 4),
          "| convergence code =", opt$convergence, "\n")
      all_starts_log <- rbind(all_starts_log, data.frame(
        Start = s, NegLogLik = opt$value, LogLik = -opt$value, Convergence_Code = opt$convergence
      ))
      if (is.null(best) || opt$value < best$value) { best <- opt; best_theta0 <- res$theta0 }
    } else if (!is.null(res$error_message)) {
      cat("   >> Start", res$start, "(Student-t) gagal dieksekusi:", res$error_message, "\n")
    }
  }
  
  
  computation_time_sec <- as.numeric(difftime(Sys.time(), optim_start_time, units = "secs"))
  
  if (is.null(best)) {
    cat(">> PERINGATAN: Seluruh multi-start optimisasi Student-t (k =", k, ") gagal konvergen.",
        "Model pembanding Student-t TIDAK tersedia untuk saham ini; hasil Gaussian tetap dipakai",
        "sebagai model utama (tidak ada perubahan pada keputusan model).\n")
    return(NULL)
  }
  
  
  if (isTRUE(compute_hessian)) {
    optim_trace_raw <- tryCatch(
      capture.output(
        invisible(optim(par = best_theta0, fn = negloglik_ms_t, y = y, X = X, k = k, n_params = n_params,
                        method = "L-BFGS-B", lower = bounds$lower, upper = bounds$upper, hessian = FALSE,
                        control = list(maxit = 2000, factr = 1e7, pgtol = 1e-8, trace = 1, REPORT = 1)))
      ), error = function(e) character(0)
    )
    value_lines_t <- grep("value", optim_trace_raw, value = TRUE)
    optim_trace_df <- if (length(value_lines_t) > 0) {
      extract_num_t <- function(s) {
        s <- trimws(s)
        toks <- strsplit(s, "\\s+")[[1]]
        suppressWarnings(as.numeric(toks[length(toks)]))
      }
      step_label_t <- ifelse(grepl("^initial", value_lines_t), "Starting Value",
                             ifelse(grepl("^final", value_lines_t), "Final (Converged)",
                                    gsub("^iter\\s*([0-9]+).*", "Iterasi \\1", value_lines_t)))
      df_t <- data.frame(Tahap = step_label_t, NegLogLik = sapply(value_lines_t, extract_num_t),
                         stringsAsFactors = FALSE)
      df_t$LogLik <- -df_t$NegLogLik
      rownames(df_t) <- NULL
      n_df_t <- nrow(df_t)
      keep_idx_t <- unique(c(1, 2, 3, n_df_t))
      keep_idx_t <- keep_idx_t[keep_idx_t >= 1 & keep_idx_t <= n_df_t]
      df_t[keep_idx_t, ]
    } else {
      data.frame(Tahap = c("Starting Value", "Final (Converged)"),
                 NegLogLik = c(NA, best$value), LogLik = c(NA, -best$value))
    }
  } else {
    optim_trace_df <- data.frame(Tahap = c("Starting Value", "Final (Converged)"),
                                 NegLogLik = c(NA, best$value), LogLik = c(NA, -best$value),
                                 Catatan = "Jejak iterasi lengkap dilewati untuk model KANDIDAT (efisiensi) - tersedia untuk model FINAL.")
  }
  
  if (isTRUE(compute_hessian)) {
    refine_outcome <- tryCatch({
      pre_grad <- tryCatch(
        numerical_gradient(negloglik_ms_t, best$par, y = y, X = X, k = k, n_params = n_params),
        error = function(e) rep(NA_real_, length(best$par))
      )
      pre_grad_norm <- sqrt(sum(pre_grad^2, na.rm = TRUE))
      GRADIENT_NORM_REFINE_THRESHOLD_T <- 1e-3
      needs_refinement <- (!is.finite(pre_grad_norm)) ||
        (pre_grad_norm > GRADIENT_NORM_REFINE_THRESHOLD_T) || (best$convergence != 0)
      
      if (isTRUE(needs_refinement)) {
        cat(">> [REFINEMENT] Gradient norm k =", k, "=", round(pre_grad_norm, 6),
            "(convergence code =", best$convergence, ") - refinement multi-start tambahan...\n")
        
        N_REFINEMENT_STARTS_T <- 4
        refinement_candidates <- list(list(par = best$par, value = best$value,
                                           convergence = best$convergence, grad_norm = pre_grad_norm))
        
        for (r in seq_len(N_REFINEMENT_STARTS_T)) {
          jitter_sd_r <- stats::runif(1, min = 0.005, max = 0.05)
          par0_r <- best$par + stats::rnorm(length(best$par), mean = 0, sd = jitter_sd_r)
          par0_r <- pmin(pmax(par0_r, bounds$lower), bounds$upper)
          
          opt_r <- tryCatch(
            optim(par = par0_r, fn = negloglik_ms_t, y = y, X = X, k = k, n_params = n_params,
                  method = "L-BFGS-B", lower = bounds$lower, upper = bounds$upper, hessian = FALSE,
                  control = list(maxit = 2000, factr = 1e7, pgtol = 1e-9)),
            error = function(e) NULL
          )
          if (is.null(opt_r) || !is.finite(opt_r$value)) next
          
          grad_r <- tryCatch(
            numerical_gradient(negloglik_ms_t, opt_r$par, y = y, X = X, k = k, n_params = n_params),
            error = function(e) rep(NA_real_, length(opt_r$par))
          )
          grad_norm_r <- sqrt(sum(grad_r^2, na.rm = TRUE))
          
          refinement_candidates[[length(refinement_candidates) + 1]] <- list(
            par = opt_r$par, value = opt_r$value, convergence = opt_r$convergence, grad_norm = grad_norm_r
          )
        }
        
        converged_ok <- Filter(function(cand) isTRUE(cand$convergence == 0) && is.finite(cand$grad_norm), refinement_candidates)
        pool_for_selection <- if (length(converged_ok) > 0) converged_ok else refinement_candidates
        values_pool <- sapply(pool_for_selection, function(cand) cand$value)
        gradnorm_pool <- sapply(pool_for_selection, function(cand) ifelse(is.finite(cand$grad_norm), cand$grad_norm, Inf))
        best_idx_pool <- order(values_pool, gradnorm_pool)[1]
        best_refined <- pool_for_selection[[best_idx_pool]]
        
        if (is.finite(best_refined$value) && best_refined$value <= best$value + 1e-6 &&
            is.finite(best_refined$grad_norm) && best_refined$grad_norm <= pre_grad_norm) {
          list(refined = TRUE, par = best_refined$par, value = best_refined$value,
               convergence = best_refined$convergence, grad_norm = best_refined$grad_norm,
               grad_norm_before = pre_grad_norm)
        } else {
          list(refined = FALSE, grad_norm_before = pre_grad_norm)
        }
      } else {
        list(refined = FALSE, grad_norm_before = pre_grad_norm)
      }
    }, error = function(e) {
      cat(">> [REFINEMENT] PERINGATAN: refinement gagal dieksekusi (", conditionMessage(e),
          ") - solusi multi-start semula tetap dipertahankan.\n")
      list(refined = FALSE, grad_norm_before = NA_real_)
    })
    
    if (isTRUE(refine_outcome$refined)) {
      best$par         <- refine_outcome$par
      best$value       <- refine_outcome$value
      best$convergence <- refine_outcome$convergence
      cat(">> [REFINEMENT] Solusi diperbaiki - gradient norm baru =", round(refine_outcome$grad_norm, 6),
          "(sebelumnya", round(refine_outcome$grad_norm_before, 6), "), NegLogLik =", round(best$value, 6),
          ", convergence code =", best$convergence, "\n")
    }
  }
  
  n_theta <- length(best$par)
  
  if (isTRUE(compute_hessian)) {
    hess_result <- robust_hessian_vcov(
      objective_fn = negloglik_ms_t, par = best$par, y = y, X = X, k = k, n_params = n_params,
      convergence_code = best$convergence, rank_tol = 1e-8,
      fallback_hessian = best$hessian, model_label = paste0("Student-t, k = ", k)
    )
    
    best$hessian <- hess_result$hessian
    hess_diag  <- hess_result$hess_diag
    vcov_mat   <- hess_result$vcov_mat
    se_theta   <- hess_result$se_theta
    hessian_ok <- hess_result$hessian_ok
    se_valid   <- hess_result$se_valid
    wald_valid <- hess_result$wald_valid
    
    if (!isTRUE(hessian_ok)) {
      cat(">> PERINGATAN: Hessian pada model Student-t k =", k, "TIDAK positive definite (",
          hess_diag$n_negative_eigenvalues, "dari", length(best$par),
          "eigenvalue <= toleransi 1e-8) walaupun telah dihitung ulang via numDeriv::hessian()",
          "(Richardson Extrapolation) dan dikoreksi via Matrix::nearPD() (Higham, 2002). Sesuai",
          "regularity conditions MLE, pseudo-inverse TIDAK dipakai sebagai dasar inferensi utama.",
          "Seluruh standard error, z-statistic, Wald statistic, p-value, dan confidence interval",
          "diisi NA (last resort) - estimasi parameter & log-likelihood TETAP VALID dan ditampilkan.\n")
    }
  } else {
    cat("   >> [EFISIENSI] compute_hessian = FALSE - Hessian & SE dilewati untuk model Student-t k =", k,
        "(hanya LogLik/AIC/BIC/HQIC dipakai pada tahap perbandingan Gaussian vs Student-t).\n")
    hess_diag  <- NULL
    vcov_mat   <- matrix(NA_real_, n_theta, n_theta)
    se_theta   <- rep(NA_real_, n_theta)
    hessian_ok <- NA
    se_valid   <- NA
    wald_valid <- NA
  }
  
  theta <- best$par
  idx <- 1
  beta_mat <- matrix(NA, nrow = n_params, ncol = k)
  se_beta  <- matrix(NA, nrow = n_params, ncol = k)
  for (i in 1:k) {
    beta_mat[, i] <- theta[idx:(idx + n_params - 1)]
    se_beta[, i]  <- se_theta[idx:(idx + n_params - 1)]
    idx <- idx + n_params
  }
  log_sigma   <- theta[idx:(idx + k - 1)]
  se_logsigma <- se_theta[idx:(idx + k - 1)]
  sigma_vec   <- exp(log_sigma)
  se_sigma    <- sigma_vec * se_logsigma
  idx <- idx + k
  gamma_nu    <- theta[idx:(idx + k - 1)]
  se_gamma_nu <- se_theta[idx:(idx + k - 1)]
  nu_vec      <- 2 + exp(gamma_nu)
  se_nu       <- exp(gamma_nu) * se_gamma_nu
  idx <- idx + k
  eta <- theta[idx:(idx + k * (k - 1) - 1)]
  se_eta <- se_theta[idx:(idx + k * (k - 1) - 1)]
  P <- build_trans_matrix(eta, k)
  
  filt_res <- hamilton_filter(y, X, beta_mat, sigma_vec, P, k, dist = "t", nu_vec = nu_vec)
  smo_prob <- kim_smoother(filt_res$filt, filt_res$pred, P, k)
  
  if (!is.null(hess_diag)) {
    hess_eigen <- hess_diag$eigenvalues
    hess_cn    <- hess_diag$condition_number
  } else {
    hess_eigen <- rep(NA_real_, n_theta)
    hess_cn    <- NA_real_
  }
  
  final_gradient <- tryCatch(
    numerical_gradient(negloglik_ms_t, best$par, y = y, X = X, k = k, n_params = n_params),
    error = function(e) rep(NA_real_, length(best$par))
  )
  gradient_norm <- sqrt(sum(final_gradient^2, na.rm = TRUE))
  
  list(
    k = k, n_params = n_params, theta = theta, beta_mat = beta_mat, se_beta = se_beta,
    sigma_vec = sigma_vec, se_sigma = se_sigma, nu_vec = nu_vec, se_nu = se_nu,
    eta = eta, se_eta = se_eta, trans_mat = P,
    filt_prob = t(filt_res$filt), smo_prob = t(smo_prob),
    logLik = -best$value, convergence = best$convergence,
    convergence_message = if (!is.null(best$message)) best$message else NA_character_,
    n_iter = unname(best$counts[1]), n_iter_grad = unname(best$counts[2]),
    hessian_ok = hessian_ok, se_valid = se_valid, wald_valid = wald_valid,
    coef_names = colnames(X),
    hessian_mat = best$hessian, vcov_mat = vcov_mat,
    hessian_eigenvalues = hess_eigen, hessian_condition_number = hess_cn,
    hessian_diagnostics = hess_diag,
    gradient_norm = gradient_norm,
    computation_time_sec = computation_time_sec,
    optim_trace = optim_trace_df, theta0_winning = best_theta0, all_starts_log = all_starts_log,
    optimizer_used = "L-BFGS-B"
  )
}


classify_regimes_by_sigma <- function(smo_prob, sigma_vec, k) {
  prob_df <- as.data.frame(smo_prob)
  regime_class <- apply(prob_df, 1, which.max)
  
  sigma_order <- order(sigma_vec)
  labels_ordered <- if (k == 2) c("Bull (Volatilitas Rendah)", "Bear (Volatilitas Tinggi)") else
    c("Bull (Volatilitas Rendah)", "Normal/Transisi", "Bear (Volatilitas Tinggi)")
  label_map <- setNames(labels_ordered, sigma_order)
  regime_label <- label_map[as.character(regime_class)]
  
  list(regime_class = regime_class, regime_label = regime_label, label_map = label_map)
}

sanitize_tag <- function(x) {
  gsub("[^A-Za-z0-9]", "_", x)
}

mk_sheet_name <- function(tag, suffix) {
  nm <- paste0(tag, "_", suffix)
  substr(nm, 1, 31)
}

plot_acf_pacf <- function(x, var_name, plots_dir, max_lag = 20) {
  x <- as.numeric(x[!is.na(x)])
  n <- length(x)
  max_lag <- min(max_lag, floor(n / 4))
  
  acf_obj  <- stats::acf(x,  lag.max = max_lag, plot = FALSE)
  pacf_obj <- stats::pacf(x, lag.max = max_lag, plot = FALSE)
  ci <- 1.96 / sqrt(n)
  
  acf_df  <- data.frame(Lag = as.numeric(acf_obj$lag)[-1],  ACF  = as.numeric(acf_obj$acf)[-1])
  pacf_df <- data.frame(Lag = as.numeric(pacf_obj$lag),     PACF = as.numeric(pacf_obj$acf))
  
  tag <- sanitize_tag(var_name)
  
  p_acf <- ggplot(acf_df, aes(x = Lag, y = ACF)) +
    geom_col(fill = "#1f78b4", width = 0.6) +
    geom_hline(yintercept = c(-ci, ci), linetype = "dashed", color = "red") +
    geom_hline(yintercept = 0, color = "black", linewidth = 0.3) +
    labs(title = paste("Plot ACF -", var_name),
         subtitle = "Identifikasi Box-Jenkins - garis putus-putus = batas signifikansi 95%",
         x = "Lag", y = "Autocorrelation") +
    theme_thesis()
  save_plot_hd(p_acf, paste0("ACF_", tag), plots_dir)
  
  p_pacf <- ggplot(pacf_df, aes(x = Lag, y = PACF)) +
    geom_col(fill = "#33a02c", width = 0.6) +
    geom_hline(yintercept = c(-ci, ci), linetype = "dashed", color = "red") +
    geom_hline(yintercept = 0, color = "black", linewidth = 0.3) +
    labs(title = paste("Plot PACF -", var_name),
         subtitle = "Identifikasi Box-Jenkins - garis putus-putus = batas signifikansi 95%",
         x = "Lag", y = "Partial Autocorrelation") +
    theme_thesis()
  save_plot_hd(p_pacf, paste0("PACF_", tag), plots_dir)
  
  list(acf_df = acf_df, pacf_df = pacf_df)
}

select_arma_order <- function(x, var_name, max_p = 3, max_q = 3) {
  x <- as.numeric(x[!is.na(x)])
  n <- length(x)
  
  candidates <- expand.grid(p = 0:max_p, q = 0:max_q)
  candidates <- candidates[!(candidates$p == 0 & candidates$q == 0), ]
  
  comparison_table <- data.frame()
  fit_store <- list()
  
  for (i in seq_len(nrow(candidates))) {
    p <- candidates$p[i]; q <- candidates$q[i]
    key <- paste0("p", p, "_q", q)
    fit <- tryCatch(
      suppressWarnings(stats::arima(x, order = c(p, 0, q), method = "ML",
                                    optim.control = list(maxit = 500))),
      error = function(e) NULL
    )
    if (!is.null(fit) && is.finite(fit$aic)) {
      k_par <- length(fit$coef) + 1
      bic_val <- fit$aic + (log(n) - 2) * k_par
      comparison_table <- rbind(comparison_table, data.frame(
        Variable = var_name, p = p, q = q,
        LogLik = as.numeric(fit$loglik), AIC = fit$aic, BIC = bic_val,
        stringsAsFactors = FALSE
      ))
      fit_store[[key]] <- fit
    }
  }
  
  if (nrow(comparison_table) == 0) {
    return(list(comparison_table = NULL, fit_store = NULL))
  }
  
  comparison_table <- comparison_table[order(comparison_table$BIC), ]
  rownames(comparison_table) <- NULL
  list(comparison_table = comparison_table, fit_store = fit_store)
}

white_noise_test <- function(residuals, lag = 10, fitdf = 0) {
  residuals <- residuals[!is.na(residuals)]
  fitdf <- max(0, min(fitdf, lag - 1))
  
  lb <- tryCatch(Box.test(residuals, lag = lag, type = "Ljung-Box", fitdf = fitdf),
                 error = function(e) NULL)
  if (is.null(lb)) {
    return(list(pass = FALSE, statistic = NA, p_value = NA,
                decision = "Uji Ljung-Box gagal dihitung"))
  }
  pass <- !is.na(lb$p.value) && lb$p.value > 0.05
  list(
    pass = pass, statistic = unname(lb$statistic), p_value = lb$p.value,
    decision = ifelse(pass,
                      "White Noise (gagal tolak H0, residual tidak terautokorelasi)",
                      "Bukan White Noise (tolak H0, residual masih terautokorelasi)")
  )
}

arch_lm_test <- function(residuals, lag = 5) {
  e  <- as.numeric(residuals[!is.na(residuals)])
  e2 <- e^2
  n  <- length(e2)
  
  if (n <= lag + 2) {
    return(list(pass_no_arch = TRUE, statistic = NA, p_value = NA,
                decision = "Observasi tidak cukup untuk uji ARCH-LM"))
  }
  
  df_lm <- data.frame(e2 = e2[(lag + 1):n])
  for (l in 1:lag) df_lm[[paste0("lag", l)]] <- e2[(lag + 1 - l):(n - l)]
  
  fit_lm <- tryCatch(lm(e2 ~ ., data = df_lm), error = function(e) NULL)
  if (is.null(fit_lm)) {
    return(list(pass_no_arch = TRUE, statistic = NA, p_value = NA,
                decision = "Uji ARCH-LM gagal dihitung"))
  }
  
  r2 <- summary(fit_lm)$r.squared
  LM <- nrow(df_lm) * r2
  p_val <- 1 - pchisq(LM, df = lag)
  no_arch <- !is.na(p_val) && p_val > 0.05
  
  list(
    pass_no_arch = no_arch, statistic = LM, p_value = p_val,
    decision = ifelse(no_arch,
                      "Tidak terdapat efek ARCH (homoskedastis kondisional)",
                      "Terdapat efek ARCH signifikan (heteroskedastisitas kondisional)")
  )
}

select_garch_order <- function(x, var_name, arma_order = c(0, 0),
                               max_garch_p = 2, max_garch_q = 2,
                               distributions = c("norm", "std", "sstd", "ged")) {
  x <- as.numeric(x[!is.na(x)])
  candidates <- expand.grid(m = 1:max_garch_p, nq = 1:max_garch_q,
                            dist = distributions, stringsAsFactors = FALSE)
  
  comparison_table <- data.frame()
  fit_store <- list()
  
  for (i in seq_len(nrow(candidates))) {
    m <- candidates$m[i]; nq <- candidates$nq[i]; dist <- candidates$dist[i]
    key <- paste0("m", m, "_n", nq, "_", dist)
    
    spec <- tryCatch(rugarch::ugarchspec(
      variance.model = list(model = "sGARCH", garchOrder = c(m, nq)),
      mean.model     = list(armaOrder = arma_order, include.mean = TRUE),
      distribution.model = dist
    ), error = function(e) NULL)
    if (is.null(spec)) next
    
    fit <- tryCatch(
      suppressWarnings(rugarch::ugarchfit(spec, data = x, solver = "hybrid",
                                          solver.control = list(trace = 0))),
      error = function(e) NULL
    )
    
    if (!is.null(fit) && isTRUE(fit@fit$convergence == 0)) {
      ic <- tryCatch(rugarch::infocriteria(fit), error = function(e) NULL)
      if (!is.null(ic)) {
        comparison_table <- rbind(comparison_table, data.frame(
          Variable = var_name, GARCH_p = m, GARCH_q = nq, Distribution = dist,
          AIC = ic["Akaike", 1], BIC = ic["Bayes", 1], stringsAsFactors = FALSE
        ))
        fit_store[[key]] <- fit
      }
    }
  }
  
  if (nrow(comparison_table) == 0) {
    return(list(comparison_table = NULL, fit_store = NULL))
  }
  
  comparison_table <- comparison_table[order(comparison_table$BIC), ]
  rownames(comparison_table) <- NULL
  list(comparison_table = comparison_table, fit_store = fit_store)
}

document_garch_distribution_selection <- function(x, var_name, arma_order, garch_order,
                                                  distributions = c("norm", "std", "sstd", "ged")) {
  x <- as.numeric(x[!is.na(x)])
  
  result_table <- data.frame()
  for (dist in distributions) {
    spec <- tryCatch(rugarch::ugarchspec(
      variance.model = list(model = "sGARCH", garchOrder = garch_order),
      mean.model     = list(armaOrder = arma_order, include.mean = TRUE),
      distribution.model = dist
    ), error = function(e) NULL)
    
    fit <- if (!is.null(spec)) {
      tryCatch(suppressWarnings(rugarch::ugarchfit(spec, data = x, solver = "hybrid",
                                                   solver.control = list(trace = 0))),
               error = function(e) NULL)
    } else NULL
    
    if (!is.null(fit)) {
      converged <- isTRUE(fit@fit$convergence == 0)
      ic <- tryCatch(rugarch::infocriteria(fit), error = function(e) NULL)
      ll <- tryCatch(as.numeric(likelihood(fit)), error = function(e) NA)
      n_par <- tryCatch(length(coef(fit)), error = function(e) NA)
      result_table <- rbind(result_table, data.frame(
        Variable = var_name, Distribution = dist,
        ARMA_Order = paste0("(", arma_order[1], ",", arma_order[2], ")"),
        GARCH_Order = paste0("(", garch_order[1], ",", garch_order[2], ")"),
        LogLikelihood = ll,
        AIC  = if (!is.null(ic)) ic["Akaike", 1] else NA,
        BIC  = if (!is.null(ic)) ic["Bayes", 1] else NA,
        HQIC = if (!is.null(ic)) ic["Hannan-Quinn", 1] else NA,
        N_Param = n_par, Convergence = ifelse(converged, "Konvergen", "TIDAK Konvergen"),
        stringsAsFactors = FALSE
      ))
    } else {
      result_table <- rbind(result_table, data.frame(
        Variable = var_name, Distribution = dist,
        ARMA_Order = paste0("(", arma_order[1], ",", arma_order[2], ")"),
        GARCH_Order = paste0("(", garch_order[1], ",", garch_order[2], ")"),
        LogLikelihood = NA, AIC = NA, BIC = NA, HQIC = NA, N_Param = NA,
        Convergence = "GAGAL DIESTIMASI", stringsAsFactors = FALSE
      ))
    }
  }
  
  result_table$Rank_BIC <- NA
  converged_idx <- which(result_table$Convergence == "Konvergen")
  if (length(converged_idx) > 0) {
    result_table$Rank_BIC[converged_idx] <- rank(result_table$BIC[converged_idx])
  }
  result_table <- result_table[order(is.na(result_table$Rank_BIC), result_table$Rank_BIC), ]
  rownames(result_table) <- NULL
  
  result_table
}

garch_diagnostic_check <- function(fit, lag = 10) {
  std_resid <- as.numeric(residuals(fit, standardize = TRUE))
  
  lb_std   <- white_noise_test(std_resid,   lag = lag)
  lb_std2  <- white_noise_test(std_resid^2, lag = lag)
  arch_std <- arch_lm_test(std_resid, lag = 5)
  
  pass <- isTRUE(lb_std$pass) && isTRUE(lb_std2$pass) && isTRUE(arch_std$pass_no_arch)
  
  list(pass = pass, ljung_box_std = lb_std, ljung_box_std2 = lb_std2,
       arch_lm_std = arch_std, std_resid = std_resid)
}

run_macro_pipeline_one <- function(var_name, price_series, dates, plots_root, wb_macro,
                                   max_p = 3, max_q = 3,
                                   max_garch_p = 2, max_garch_q = 2,
                                   garch_dists = c("norm", "std", "sstd", "ged")) {
  
  cat("\n-----------------------------------------------------------------\n")
  cat(" MACROECONOMICS PIPELINE - VARIABEL:", var_name, "\n")
  cat("-----------------------------------------------------------------\n")
  
  tag <- sanitize_tag(var_name)
  plots_dir <- file.path(plots_root, "Macro", tag)
  if (!dir.exists(plots_dir)) dir.create(plots_dir, recursive = TRUE)
  
  transform_info <- detect_transformation_type(var_name)
  n_before <- sum(!is.na(price_series))
  transformed <- transform_series(price_series, transform_info$method)
  raw_val <- transformed$value
  ret_df  <- data.frame(Dates = dates, Value = raw_val)
  ret_df  <- ret_df[-1, ]
  rownames(ret_df) <- NULL
  ret_df  <- ret_df[is.finite(ret_df$Value), ]
  n_after <- nrow(ret_df)
  
  transform_doc <- data.frame(
    Variable            = var_name,
    Metode_Transformasi = transform_info$method,
    Alasan              = transform_info$reason,
    Formula             = transformed$formula,
    N_Obs_Sebelum       = n_before,
    N_Obs_Sesudah       = n_after,
    N_Missing_Dihasilkan = n_before - n_after - 1,
    stringsAsFactors = FALSE
  )
  
  p_before <- ggplot(data.frame(Dates = dates, Value = as.numeric(price_series)),
                     aes(x = Dates, y = Value)) +
    geom_line(color = "grey40", linewidth = 0.4) +
    labs(title = paste("Data Sebelum Transformasi (Level) -", var_name),
         x = "Tanggal", y = "Nilai Level") +
    theme_thesis()
  save_plot_hd(p_before, paste0("BeforeTransform_", tag), plots_dir)
  
  p_after <- ggplot(ret_df, aes(x = Dates, y = Value)) +
    geom_line(color = "#1f78b4", linewidth = 0.4) +
    labs(title = paste("Data Sesudah Transformasi (", transform_info$method, ") -", var_name),
         x = "Tanggal", y = "Nilai Transformasi") +
    theme_thesis()
  save_plot_hd(p_after, paste0("AfterTransform_", tag), plots_dir)
  
  cat(">>", var_name, "- Metode transformasi terpilih:", transform_info$method,
      "(", transform_info$reason, ")\n")
  
  desc_row <- descriptive_stats_one(ret_df$Value, var_name)
  
  stat_res     <- auto_stationarity_test(ret_df$Value, var_name)
  d_applied    <- stat_res$final_d
  work_series  <- as.numeric(stat_res$final_series)
  work_dates   <- ret_df$Dates[(d_applied + 1):nrow(ret_df)]
  
  cat(">>", var_name, "- orde differencing terpakai (d):", d_applied,
      "| status stasioner:", stat_res$stationary, "\n")
  
  invisible(plot_acf_pacf(work_series, var_name, plots_dir))
  
  arma_search <- select_arma_order(work_series, var_name, max_p = max_p, max_q = max_q)
  if (is.null(arma_search$comparison_table)) {
    stop(paste("Seluruh kandidat model ARMA gagal konvergen untuk variabel makro:", var_name))
  }
  
  tbl_arma <- arma_search$comparison_table
  arma_attempt_log <- data.frame()
  chosen_arma <- NULL
  
  for (i in seq_len(nrow(tbl_arma))) {
    p <- tbl_arma$p[i]; q <- tbl_arma$q[i]
    key <- paste0("p", p, "_q", q)
    cand_fit   <- arma_search$fit_store[[key]]
    cand_resid <- as.numeric(residuals(cand_fit))
    wn <- white_noise_test(cand_resid, lag = 10, fitdf = p + q)
    
    arma_attempt_log <- rbind(arma_attempt_log, data.frame(
      Variable = var_name, p = p, q = q, BIC = tbl_arma$BIC[i],
      LjungBox_pvalue = wn$p_value, Status = ifelse(wn$pass, "Lulus (White Noise)", "Tidak Lulus - Naikkan Ordo")
    ))
    
    if (isTRUE(wn$pass)) {
      chosen_arma <- list(p = p, q = q, fit = cand_fit, resid = cand_resid, wn = wn)
      break
    }
  }
  
  if (is.null(chosen_arma)) {
    p <- tbl_arma$p[1]; q <- tbl_arma$q[1]; key <- paste0("p", p, "_q", q)
    cand_fit   <- arma_search$fit_store[[key]]
    cand_resid <- as.numeric(residuals(cand_fit))
    wn <- white_noise_test(cand_resid, lag = 10, fitdf = p + q)
    chosen_arma <- list(p = p, q = q, fit = cand_fit, resid = cand_resid, wn = wn)
    cat(">> PERINGATAN:", var_name, "- tidak ada kandidat ARMA dalam rentang order [0,",
        max_p, "]x[0,", max_q, "] yang lolos uji white noise. Digunakan model dengan",
        "BIC terbaik: ARMA(", p, ",", q, "), residual masih menunjukkan indikasi",
        "autokorelasi (lihat sheet ARMA Search).\n")
  } else {
    cat(">>", var_name, "- Model ARMA(", chosen_arma$p, ",", chosen_arma$q,
        ") terpilih (BIC terbaik yang lolos white noise).\n")
  }
  
  arma_fit    <- chosen_arma$fit
  arma_order  <- c(chosen_arma$p, chosen_arma$q)
  arma_resid  <- chosen_arma$resid
  arma_fitted <- work_series - arma_resid
  
  arch_test <- arch_lm_test(arma_resid, lag = 5)
  cat(">>", var_name, "- Uji ARCH-LM:", arch_test$decision,
      "(p-value =", round(arch_test$p_value, 4), ")\n")
  
  garch_used        <- FALSE
  garch_comparison  <- NULL
  garch_attempt_log <- data.frame()
  garch_diag        <- NULL
  garch_model_desc  <- "Tidak digunakan (efek ARCH tidak signifikan pada residual ARMA)"
  chosen_garch_order   <- c(1, 1)
  chosen_garch_dist    <- "norm"
  garch_dist_doc_table <- NULL
  
  final_cond_mean <- arma_fitted
  final_cond_var  <- rep(var(arma_resid, na.rm = TRUE), length(arma_resid))
  final_std_resid <- arma_resid / sqrt(final_cond_var)
  final_fitted    <- arma_fitted
  final_resid     <- arma_resid
  
  if (!isTRUE(arch_test$pass_no_arch)) {
    cat(">>", var_name, "- Melanjutkan ke estimasi ARMA-GARCH (seleksi orde & distribusi)...\n")
    garch_search <- select_garch_order(work_series, var_name, arma_order = arma_order,
                                       max_garch_p = max_garch_p, max_garch_q = max_garch_q,
                                       distributions = garch_dists)
    
    if (!is.null(garch_search$comparison_table)) {
      tbl_garch  <- garch_search$comparison_table
      garch_comparison <- tbl_garch
      chosen_garch <- NULL
      
      for (i in seq_len(nrow(tbl_garch))) {
        key <- paste0("m", tbl_garch$GARCH_p[i], "_n", tbl_garch$GARCH_q[i], "_", tbl_garch$Distribution[i])
        cand_fit_g <- garch_search$fit_store[[key]]
        diag_g <- garch_diagnostic_check(cand_fit_g)
        
        garch_attempt_log <- rbind(garch_attempt_log, data.frame(
          Variable = var_name, GARCH_p = tbl_garch$GARCH_p[i], GARCH_q = tbl_garch$GARCH_q[i],
          Distribution = tbl_garch$Distribution[i], BIC = tbl_garch$BIC[i],
          Status = ifelse(diag_g$pass, "Lulus Diagnostik", "Tidak Lulus - Coba Kandidat Lain")
        ))
        
        if (isTRUE(diag_g$pass)) {
          chosen_garch <- list(fit = cand_fit_g, diag = diag_g, p = tbl_garch$GARCH_p[i],
                               q = tbl_garch$GARCH_q[i], dist = tbl_garch$Distribution[i])
          break
        }
      }
      
      if (is.null(chosen_garch)) {
        key <- paste0("m", tbl_garch$GARCH_p[1], "_n", tbl_garch$GARCH_q[1], "_", tbl_garch$Distribution[1])
        cand_fit_g <- garch_search$fit_store[[key]]
        diag_g <- garch_diagnostic_check(cand_fit_g)
        chosen_garch <- list(fit = cand_fit_g, diag = diag_g, p = tbl_garch$GARCH_p[1],
                             q = tbl_garch$GARCH_q[1], dist = tbl_garch$Distribution[1])
        cat(">> PERINGATAN:", var_name, "- tidak ada kombinasi GARCH & distribusi yang lolos",
            "seluruh diagnostik. Digunakan model dengan BIC terbaik: GARCH(", chosen_garch$p,
            ",", chosen_garch$q, ") -", chosen_garch$dist, ".\n")
      } else {
        cat(">>", var_name, "- Model GARCH(", chosen_garch$p, ",", chosen_garch$q,
            ") - Distribusi:", chosen_garch$dist, "terpilih (lolos diagnostik).\n")
      }
      
      garch_used       <- TRUE
      garch_diag       <- chosen_garch$diag
      garch_model_desc <- paste0("ARMA(", arma_order[1], ",", arma_order[2],
                                 ")-GARCH(", chosen_garch$p, ",", chosen_garch$q,
                                 ") - Distribusi: ", chosen_garch$dist)
      chosen_garch_order <- c(chosen_garch$p, chosen_garch$q)
      chosen_garch_dist  <- chosen_garch$dist
      
      garch_dist_doc_table <- document_garch_distribution_selection(
        work_series, var_name, arma_order, chosen_garch_order, garch_dists
      )
      
      final_cond_mean <- as.numeric(fitted(chosen_garch$fit))
      final_cond_var  <- as.numeric(sigma(chosen_garch$fit))^2
      final_std_resid <- as.numeric(residuals(chosen_garch$fit, standardize = TRUE))
      final_resid     <- as.numeric(residuals(chosen_garch$fit, standardize = FALSE))
      final_fitted    <- final_cond_mean
    } else {
      cat(">> PERINGATAN:", var_name, "- seluruh kandidat GARCH gagal konvergen;",
          "digunakan hasil model ARMA saja (conditional variance konstan).\n")
    }
  } else {
    cat(">>", var_name, "- Efek ARCH tidak signifikan; variabel dilanjutkan tanpa GARCH.\n")
  }
  
  final_cond_vol <- sqrt(final_cond_var)
  
  final_df <- data.frame(
    Dates                  = work_dates,
    ConditionalMean        = final_cond_mean,
    ConditionalVariance    = final_cond_var,
    ConditionalVolatility  = final_cond_vol,
    StandardizedResidual   = final_std_resid,
    FittedValue            = final_fitted,
    Residual               = final_resid
  )
  
  post_lb_std   <- white_noise_test(final_std_resid, lag = 10)
  post_lb_std2  <- white_noise_test(final_std_resid^2, lag = 10)
  post_arch_std <- arch_lm_test(final_std_resid, lag = 5)
  post_jb_std   <- tryCatch(tseries::jarque.bera.test(final_std_resid[is.finite(final_std_resid)]),
                            error = function(e) NULL)
  
  post_garch_diag_table <- data.frame(
    Variable = var_name, Model_Final = garch_model_desc,
    LjungBox_StdResid_Stat = post_lb_std$statistic, LjungBox_StdResid_p = post_lb_std$p_value,
    LjungBox_StdResid_Keputusan = post_lb_std$decision,
    LjungBox_SqStdResid_Stat = post_lb_std2$statistic, LjungBox_SqStdResid_p = post_lb_std2$p_value,
    LjungBox_SqStdResid_Keputusan = post_lb_std2$decision,
    ARCH_LM_Stat = post_arch_std$statistic, ARCH_LM_p = post_arch_std$p_value,
    ARCH_LM_Keputusan = post_arch_std$decision,
    JarqueBera_Stat = if (!is.null(post_jb_std)) unname(post_jb_std$statistic) else NA,
    JarqueBera_p    = if (!is.null(post_jb_std)) post_jb_std$p.value else NA,
    JarqueBera_Keputusan = if (!is.null(post_jb_std)) {
      ifelse(post_jb_std$p.value < 0.05, "Tidak Normal (tolak H0)", "Normal (gagal tolak H0)")
    } else NA,
    Mean_StdResid = mean(final_std_resid, na.rm = TRUE),
    SD_StdResid   = sd(final_std_resid, na.rm = TRUE),
    stringsAsFactors = FALSE
  )
  
  p_density <- ggplot(data.frame(StdResidual = final_std_resid), aes(x = StdResidual)) +
    geom_density(fill = "#1f78b4", alpha = 0.5, color = "#1f78b4") +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "red", linewidth = 0.8, linetype = "dashed") +
    labs(title = paste("Density Plot Standardized Residual (Post-Model) -", var_name),
         x = "Standardized Residual", y = "Density") +
    theme_thesis()
  save_plot_hd(p_density, paste0("PostModel_Density_", tag), plots_dir)
  
  invisible(plot_acf_pacf(final_std_resid, paste("StdResid", var_name), plots_dir))
  
  sq_acf_obj <- stats::acf(final_std_resid[is.finite(final_std_resid)]^2, lag.max = 20, plot = FALSE)
  sq_acf_df  <- data.frame(Lag = as.numeric(sq_acf_obj$lag)[-1], ACF = as.numeric(sq_acf_obj$acf)[-1])
  ci_sq <- 1.96 / sqrt(length(final_std_resid))
  p_sqacf <- ggplot(sq_acf_df, aes(x = Lag, y = ACF)) +
    geom_col(fill = "#e31a1c", width = 0.6) +
    geom_hline(yintercept = c(-ci_sq, ci_sq), linetype = "dashed", color = "red") +
    geom_hline(yintercept = 0, color = "black", linewidth = 0.3) +
    labs(title = paste("ACF Squared Standardized Residual (Post-Model) -", var_name),
         x = "Lag", y = "ACF Kuadrat Residual") +
    theme_thesis()
  save_plot_hd(p_sqacf, paste0("PostModel_SqResidACF_", tag), plots_dir)
  
  cat(">>", var_name, "- Post-model diagnostic: Ljung-Box (std) p =", round(post_lb_std$p_value, 4),
      "| ARCH-LM (std) p =", round(post_arch_std$p_value, 4), "\n")
  
  p_mean <- ggplot(final_df, aes(x = Dates, y = ConditionalMean)) +
    geom_line(color = "#1f78b4", linewidth = 0.4) +
    labs(title = paste("Conditional Mean -", var_name, "(", garch_model_desc, ")"),
         x = "Tanggal", y = "Conditional Mean") +
    theme_thesis()
  save_plot_hd(p_mean, paste0("ConditionalMean_", tag), plots_dir)
  
  p_vol <- ggplot(final_df, aes(x = Dates, y = ConditionalVolatility)) +
    geom_line(color = "#e31a1c", linewidth = 0.4) +
    labs(title = paste("Conditional Volatility -", var_name),
         x = "Tanggal", y = "Conditional Volatility (Std. Dev.)") +
    theme_thesis()
  save_plot_hd(p_vol, paste0("ConditionalVolatility_", tag), plots_dir)
  
  p_std <- ggplot(final_df, aes(x = Dates, y = StandardizedResidual)) +
    geom_line(color = "grey40", linewidth = 0.3) +
    geom_hline(yintercept = c(-2, 2), linetype = "dashed", color = "red") +
    labs(title = paste("Standardized Residual -", var_name), x = "Tanggal", y = "Standardized Residual") +
    theme_thesis()
  save_plot_hd(p_std, paste0("StdResidual_", tag), plots_dir)
  
  p_qq <- ggplot(final_df, aes(sample = StandardizedResidual)) +
    stat_qq(color = "#1f78b4") + stat_qq_line(color = "red") +
    labs(title = paste("QQ Plot Standardized Residual -", var_name),
         x = "Theoretical Quantiles", y = "Sample Quantiles") +
    theme_thesis()
  save_plot_hd(p_qq, paste0("QQPlot_", tag), plots_dir)
  
  p_hist <- ggplot(final_df, aes(x = StandardizedResidual)) +
    geom_histogram(aes(y = after_stat(density)), bins = 30, fill = "#1f78b4", color = "white", alpha = 0.8) +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "red", linewidth = 0.8) +
    labs(title = paste("Histogram Standardized Residual -", var_name), x = "Standardized Residual", y = "Density") +
    theme_thesis()
  save_plot_hd(p_hist, paste0("Histogram_", tag), plots_dir)
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "Transform"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "Transform"), transform_doc)
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "Desc"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "Desc"), desc_row)
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "Stationarity"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "Stationarity"), stat_res$table)
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "ARMA_Search"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "ARMA_Search"), arma_attempt_log)
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "ARCH_LM"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "ARCH_LM"), data.frame(
    Variable = var_name, LM_Statistic = arch_test$statistic,
    p_value = arch_test$p_value, Keputusan = arch_test$decision
  ))
  
  if (garch_used) {
    openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "GARCH_Search"))
    openxlsx::writeData(wb_macro, mk_sheet_name(tag, "GARCH_Search"), garch_attempt_log)
    
    openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "GARCH_Diagnostic"))
    openxlsx::writeData(wb_macro, mk_sheet_name(tag, "GARCH_Diagnostic"), data.frame(
      Variable = var_name,
      LjungBox_StdResid_p    = garch_diag$ljung_box_std$p_value,
      LjungBox_StdResid_Keputusan = garch_diag$ljung_box_std$decision,
      LjungBox_SqStdResid_p  = garch_diag$ljung_box_std2$p_value,
      LjungBox_SqStdResid_Keputusan = garch_diag$ljung_box_std2$decision,
      ARCH_LM_StdResid_p     = garch_diag$arch_lm_std$p_value,
      ARCH_LM_StdResid_Keputusan = garch_diag$arch_lm_std$decision
    ))
    
    if (!is.null(garch_dist_doc_table)) {
      openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "GARCH_DistSelect"))
      openxlsx::writeData(wb_macro, mk_sheet_name(tag, "GARCH_DistSelect"), garch_dist_doc_table)
      openxlsx::writeData(wb_macro, mk_sheet_name(tag, "GARCH_DistSelect"),
                          data.frame(Catatan = paste0(
                            "Seluruh kandidat distribusi diestimasi pada orde ARMA-GARCH yang SAMA ",
                            "(", garch_model_desc, ") agar perbandingan murni mencerminkan pengaruh ",
                            "bentuk distribusi error. Distribusi terpilih (Rank_BIC = 1) konsisten ",
                            "dengan hasil seleksi utama pada sheet GARCH_Search.")),
                          startRow = nrow(garch_dist_doc_table) + 3)
    }
  }
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "PostModel_Diag"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "PostModel_Diag"), post_garch_diag_table)
  
  openxlsx::addWorksheet(wb_macro, mk_sheet_name(tag, "Final_Output"))
  openxlsx::writeData(wb_macro, mk_sheet_name(tag, "Final_Output"), final_df)
  
  cat(">>", var_name, "- Model final:", garch_model_desc, "\n")
  cat(">> Macroeconomics pipeline untuk", var_name, "SELESAI.\n")
  
  list(
    var_name          = var_name,
    transform_method  = transform_info$method,
    d_applied         = d_applied,
    arma_order        = arma_order,
    garch_used        = garch_used,
    garch_model_desc  = garch_model_desc,
    garch_order       = chosen_garch_order,
    garch_distribution = chosen_garch_dist,
    garch_dist_doc_table = garch_dist_doc_table,
    work_series       = work_series,
    work_dates        = work_dates,
    desc_row          = desc_row,
    stationarity_table = stat_res$table,
    arma_attempt_log  = arma_attempt_log,
    garch_comparison  = garch_comparison,
    garch_attempt_log = garch_attempt_log,
    post_garch_diag_table = post_garch_diag_table,
    final_df          = final_df,
    arma_fit_object   = arma_fit,
    garch_fit_object  = if (garch_used) chosen_garch$fit else NULL,
    residual_sd_arma_only = if (!garch_used) sd(final_resid, na.rm = TRUE) else NA_real_
  )
}

detect_transformation_type <- function(var_name) {
  nm <- toupper(var_name)
  
  is_yield <- grepl("GOVT", nm) || grepl("YIELD", nm)
  
  is_bond_index <- grepl("IBPA", nm) || grepl("BOND\\s*INDEX", nm)
  
  if (is_yield || is_bond_index) {
    return(list(method = "difference",
                reason = ifelse(is_yield,
                                "Yield obligasi (bukan price series) -> First Difference",
                                "Bond Index -> First Difference")))
  }
  
  list(method = "log_return", reason = "Price series (Index/Curncy/Comdty/Equity) -> Log Return")
}

transform_series <- function(price_vector, method) {
  price_vector <- as.numeric(price_vector)
  if (method == "log_return") {
    val <- c(NA, diff(log(price_vector)))
    formula_txt <- "r_t = ln(P_t / P_(t-1))"
  } else {
    val <- c(NA, diff(price_vector))
    formula_txt <- "d_t = P_t - P_(t-1)"
  }
  list(value = val, formula = formula_txt)
}

compute_steady_state <- function(P, k) {
  A <- rbind(diag(k) - P, rep(1, k))
  b <- c(rep(0, k), 1)
  tryCatch({
    sol <- qr.solve(A, b)
    sol[sol < 0] <- 0
    sol / sum(sol)
  }, error = function(e) rep(1 / k, k))
}

normality_summary_one <- function(x, label) {
  x <- x[!is.na(x)]
  n <- length(x)
  
  jb <- tryCatch(tseries::jarque.bera.test(x), error = function(e) NULL)
  sw <- if (n >= 3 && n <= 5000) tryCatch(shapiro.test(x), error = function(e) NULL) else NULL
  
  data.frame(
    Kelompok         = label,
    N_Obs            = n,
    Mean             = mean(x),
    Median           = median(x),
    SD               = sd(x),
    Min              = min(x),
    Max              = max(x),
    Skewness         = moments::skewness(x),
    Kurtosis         = moments::kurtosis(x),
    JarqueBera_Stat  = if (!is.null(jb)) unname(jb$statistic) else NA,
    JarqueBera_p     = if (!is.null(jb)) jb$p.value else NA,
    JarqueBera_Keputusan = if (!is.null(jb)) {
      ifelse(jb$p.value < 0.05, "Tidak Normal", "Normal")
    } else NA,
    ShapiroWilk_Stat = if (!is.null(sw)) unname(sw$statistic) else NA,
    ShapiroWilk_p    = if (!is.null(sw)) sw$p.value else NA,
    ShapiroWilk_Keputusan = if (!is.null(sw)) {
      ifelse(sw$p.value < 0.05, "Tidak Normal", "Normal")
    } else "N/A (n di luar rentang 3-5000)",
    stringsAsFactors = FALSE
  )
}

forecast_regime_prob <- function(P, last_prob, horizon = 10) {
  k <- length(last_prob)
  forecast_mat <- matrix(NA, nrow = horizon, ncol = k)
  cur <- as.numeric(last_prob)
  for (h in 1:horizon) {
    cur <- as.numeric(P %*% cur)
    cur <- cur / sum(cur)
    forecast_mat[h, ] <- cur
  }
  colnames(forecast_mat) <- paste0("Prob_State", 1:k)
  data.frame(Horizon = paste0("t+", 1:horizon), forecast_mat, check.names = FALSE)
}

anderson_darling_uniform <- function(u) {
  u <- sort(u[!is.na(u)])
  n <- length(u)
  u <- pmin(pmax(u, 1e-10), 1 - 1e-10)
  i <- 1:n
  A2 <- -n - mean((2 * i - 1) * (log(u) + log(1 - rev(u))))
  A2_adj <- A2 * (1 + 0.75 / n + 2.25 / n^2)
  decision <- ifelse(A2_adj > 2.492, "Tolak H0 (bukan Uniform(0,1))", "Gagal Tolak H0 (konsisten Uniform(0,1))")
  list(statistic = A2_adj, critical_value_5pct = 2.492, decision = decision)
}

wald_test_general <- function(theta_hat, vcov_full, R, r = NULL, df = NULL) {
  theta_hat <- as.numeric(theta_hat)
  R         <- as.matrix(R)
  vcov_full <- as.matrix(vcov_full)
  
  if (ncol(R) != length(theta_hat)) {
    stop("wald_test_general(): jumlah kolom R (", ncol(R), ") harus sama dengan panjang theta_hat (",
         length(theta_hat), ").")
  }
  if (nrow(vcov_full) != length(theta_hat) || ncol(vcov_full) != length(theta_hat)) {
    stop("wald_test_general(): dimensi vcov_full (", nrow(vcov_full), "x", ncol(vcov_full),
         ") harus bujursangkar dan sama dengan panjang theta_hat (", length(theta_hat), ").")
  }
  if (is.null(r)) r <- rep(0, nrow(R))
  if (length(r) != nrow(R)) {
    stop("wald_test_general(): panjang r (", length(r), ") harus sama dengan jumlah baris R (", nrow(R), ").")
  }
  
  if (anyNA(theta_hat) || anyNA(vcov_full) || any(!is.finite(vcov_full))) {
    warning("wald_test_general(): theta_hat atau vcov_full mengandung NA/Inf (Hessian/VCOV tidak valid) - ",
            "Wald statistic diisi NA.")
    return(list(statistic = NA_real_, df = if (!is.null(df)) df else NA_integer_,
                p_value = NA_real_, valid = FALSE,
                message = "theta_hat/vcov_full mengandung NA/Inf - Wald test tidak dapat dihitung."))
  }
  
  Rtheta_r <- as.numeric(R %*% theta_hat - r)
  RVR      <- R %*% vcov_full %*% t(R)
  
  rank_R  <- tryCatch(qr(R)$rank, error = function(e) NA_integer_)
  df_use  <- if (!is.null(df)) df else rank_R
  
  RVR_inv <- tryCatch(solve(RVR), error = function(e) NULL)
  
  if (is.null(RVR_inv) || is.na(rank_R) || rank_R < nrow(R)) {
    warning("wald_test_general(): R %*% V %*% t(R) singular atau restriction matrix TIDAK full rank - ",
            "Wald statistic diisi NA (bukan dipaksakan via pseudo-inverse).")
    return(list(statistic = NA_real_, df = df_use, p_value = NA_real_, valid = FALSE,
                message = "R V R' singular / rank(R) tidak penuh - hasil Wald test TIDAK VALID."))
  }
  
  W <- as.numeric(t(Rtheta_r) %*% RVR_inv %*% Rtheta_r)
  if (!is.finite(W) || W < 0) {
    warning("wald_test_general(): statistik Wald tidak valid (non-finite atau negatif) - diisi NA.")
    return(list(statistic = NA_real_, df = df_use, p_value = NA_real_, valid = FALSE,
                message = "Statistik Wald non-finite/negatif - hasil TIDAK VALID."))
  }
  
  p_val <- 1 - stats::pchisq(W, df = df_use)
  list(statistic = W, df = df_use, p_value = p_val, valid = TRUE, message = "OK")
}

wald_regime_equality_test <- function(final_fit, alpha = 0.05) {
  beta_mat <- final_fit$beta_mat
  vcov_mat <- final_fit$vcov_mat
  coef_names <- final_fit$coef_names
  p <- nrow(beta_mat)
  k <- ncol(beta_mat)
  
  display_labels <- gsub("^L([0-9]+)_Return$", "AR(\\1)", coef_names)
  
  hessian_ok <- isTRUE(final_fit$hessian_ok)
  vcov_beta  <- if (!is.null(vcov_mat) && nrow(vcov_mat) >= k * p) {
    vcov_mat[1:(k * p), 1:(k * p), drop = FALSE]
  } else {
    matrix(NA_real_, k * p, k * p)
  }
  theta_beta <- as.numeric(beta_mat)
  
  build_R_row <- function(param_idx, regime_pair) {
    Rrow <- matrix(0, nrow = 1, ncol = k * p)
    Rrow[1, (regime_pair[1] - 1) * p + param_idx] <-  1
    Rrow[1, (regime_pair[2] - 1) * p + param_idx] <- -1
    Rrow
  }
  
  decision_text <- function(pval) {
    if (is.na(pval)) {
      "Tidak dapat ditentukan (Wald test tidak valid - lih. kolom Interpretation)"
    } else if (pval < alpha) {
      "Terdapat perubahan pengaruh antar-regime (tolak H0: koefisien sama)"
    } else {
      "Tidak terdapat bukti yang cukup bahwa pengaruh berbeda antar-regime (gagal menolak H0: koefisien sama)"
    }
  }
  interp_text <- function(res, alpha) {
    if (!isTRUE(res$valid)) {
      paste0("Wald test TIDAK VALID: ", res$message)
    } else if (res$p_value < alpha) {
      paste0("H0: koefisien sama antar-regime DITOLAK pada alpha = ", alpha,
             " (p-value = ", signif(res$p_value, 4), ") - koefisien berbeda secara statistik antar-regime.")
    } else {
      paste0("Gagal menolak H0: koefisien sama antar-regime pada alpha = ", alpha,
             " (p-value = ", signif(res$p_value, 4), ") - TIDAK terdapat bukti cukup adanya perbedaan pengaruh.")
    }
  }
  
  out <- data.frame()
  regime_pairs <- if (k >= 2) utils::combn(1:k, 2, simplify = FALSE) else list()
  
  for (m in seq_len(p)) {
    est_all <- beta_mat[m, ]
    names(est_all) <- paste0("Regime_", 1:k)
    est_all_str <- paste(paste0("Regime_", 1:k, "=", signif(est_all, 6)), collapse = "; ")
    
    if (k == 2) {
      Rmat <- build_R_row(m, c(1, 2))
      res  <- if (hessian_ok) {
        wald_test_general(theta_beta, vcov_beta, Rmat, r = 0, df = 1)
      } else {
        list(statistic = NA_real_, df = 1, p_value = NA_real_, valid = FALSE,
             message = "Hessian/VCOV final tidak valid - Wald test regime-equality tidak dapat dihitung.")
      }
      out <- rbind(out, data.frame(
        Parameter = display_labels[m], Comparison = "Regime 1 vs Regime 2 (Global)",
        Estimate_Regime_1 = unname(est_all[1]), Estimate_Regime_2 = unname(est_all[2]),
        Difference = unname(est_all[1] - est_all[2]),
        Estimates_All_Regimes = est_all_str,
        Wald_Statistic = res$statistic, df = res$df, p_value = res$p_value, Alpha = alpha,
        Decision = decision_text(res$p_value), Interpretation = interp_text(res, alpha),
        stringsAsFactors = FALSE
      ))
    } else {
      Rmat_global <- matrix(0, nrow = k - 1, ncol = k * p)
      for (j in 2:k) {
        Rmat_global[j - 1, (1 - 1) * p + m] <-  1
        Rmat_global[j - 1, (j - 1) * p + m] <- -1
      }
      res_global <- if (hessian_ok) {
        wald_test_general(theta_beta, vcov_beta, Rmat_global, r = rep(0, k - 1), df = k - 1)
      } else {
        list(statistic = NA_real_, df = k - 1, p_value = NA_real_, valid = FALSE,
             message = "Hessian/VCOV final tidak valid - Wald test regime-equality tidak dapat dihitung.")
      }
      out <- rbind(out, data.frame(
        Parameter = display_labels[m], Comparison = paste0("Global (H0: beta sama pada seluruh ", k, " regime)"),
        Estimate_Regime_1 = NA_real_, Estimate_Regime_2 = NA_real_, Difference = NA_real_,
        Estimates_All_Regimes = est_all_str,
        Wald_Statistic = res_global$statistic, df = res_global$df, p_value = res_global$p_value, Alpha = alpha,
        Decision = decision_text(res_global$p_value), Interpretation = interp_text(res_global, alpha),
        stringsAsFactors = FALSE
      ))
      
      for (pr in regime_pairs) {
        Rmat_pair <- build_R_row(m, pr)
        res_pair  <- if (hessian_ok) {
          wald_test_general(theta_beta, vcov_beta, Rmat_pair, r = 0, df = 1)
        } else {
          list(statistic = NA_real_, df = 1, p_value = NA_real_, valid = FALSE,
               message = "Hessian/VCOV final tidak valid - Wald test regime-equality tidak dapat dihitung.")
        }
        out <- rbind(out, data.frame(
          Parameter = display_labels[m], Comparison = paste0("Regime ", pr[1], " vs Regime ", pr[2]),
          Estimate_Regime_1 = unname(est_all[pr[1]]), Estimate_Regime_2 = unname(est_all[pr[2]]),
          Difference = unname(est_all[pr[1]] - est_all[pr[2]]),
          Estimates_All_Regimes = est_all_str,
          Wald_Statistic = res_pair$statistic, df = res_pair$df, p_value = res_pair$p_value, Alpha = alpha,
          Decision = decision_text(res_pair$p_value), Interpretation = interp_text(res_pair, alpha),
          stringsAsFactors = FALSE
        ))
      }
    }
  }
  rownames(out) <- NULL
  out
}

SECTOR_MANDATORY_FACTOR_MAP <- list(
  "BBCA" = list(sector = "Perbankan/Financial", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "BBNI" = list(sector = "Perbankan/Financial", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "BBRI" = list(sector = "Perbankan/Financial", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "BBTN" = list(sector = "Perbankan/Financial", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "BMRI" = list(sector = "Perbankan/Financial", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "ICBP" = list(sector = "Consumer Staples/FMCG (Food)", factors = c("IBPRCPI Index", "USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "INDF" = list(sector = "Consumer Staples/FMCG (Food)", factors = c("IBPRCPI Index", "USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "UNVR" = list(sector = "Consumer Staples/FMCG (Food)", factors = c("IBPRCPI Index", "USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "AMRT" = list(sector = "Retail/Consumer Discretionary", factors = c("USDIDR BGN Curncy", "IBPRCPI Index", "GTIDR1Y Govt")),
  "ERAA" = list(sector = "Retail/Consumer Discretionary", factors = c("USDIDR BGN Curncy", "IBPRCPI Index", "GTIDR1Y Govt")),
  "MAPI" = list(sector = "Retail/Consumer Discretionary", factors = c("USDIDR BGN Curncy", "IBPRCPI Index", "GTIDR1Y Govt")),
  "AALI" = list(sector = "Plantation/Agribusiness", factors = c("XW1 Comdty", "KO1 Comdty")),
  "LSIP" = list(sector = "Plantation/Agribusiness", factors = c("XW1 Comdty", "KO1 Comdty")),
  "SIMP" = list(sector = "Plantation/Agribusiness", factors = c("XW1 Comdty", "KO1 Comdty")),
  "CPIN" = list(sector = "Poultry/Animal Feed", factors = c("XW1 Comdty", "KO1 Comdty")),
  "JPFA" = list(sector = "Poultry/Animal Feed", factors = c("XW1 Comdty", "KO1 Comdty")),
  "AUTO" = list(sector = "Automotive/Multi-Industry", factors = c("USDIDR BGN Curncy", "CLA Comdty")),
  "ASII" = list(sector = "Automotive/Multi-Industry", factors = c("USDIDR BGN Curncy", "CLA Comdty")),
  "UNTR" = list(sector = "Heavy Equipment/Mining Contractor", factors = c("CLA Comdty", "LMNIDS03 LME Comdty")),
  "JSMR" = list(sector = "Infrastructure/Toll Road", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "TLKM" = list(sector = "Telecommunications/Tower", factors = c("USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "ISAT" = list(sector = "Telecommunications/Tower", factors = c("USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "EXCL" = list(sector = "Telecommunications/Tower", factors = c("USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "TOWR" = list(sector = "Telecommunications/Tower (Bond-Sensitive - IBPA)", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "TBIG" = list(sector = "Telecommunications/Tower", factors = c("USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "WIFI" = list(sector = "Telecommunications/Tower", factors = c("USDIDR BGN Curncy", "GTIDR1Y Govt")),
  "WIKA" = list(sector = "Construction/Infrastructure", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "WSKT" = list(sector = "Construction/Infrastructure", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "PTPP" = list(sector = "Construction/Infrastructure", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "WSBP" = list(sector = "Construction/Infrastructure", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "WTON" = list(sector = "Construction/Infrastructure", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "INCO" = list(sector = "Mining/Metals (Nickel)", factors = c("LMNIDS03 LME Comdty", "USDIDR BGN Curncy")),
  "TINS" = list(sector = "Mining/Metals (Tin)", factors = c("LMNIDS03 LME Comdty", "USDIDR BGN Curncy")),
  "NCKL" = list(sector = "Mining/Metals (Nickel)", factors = c("LMNIDS03 LME Comdty", "USDIDR BGN Curncy")),
  "MDKA" = list(sector = "Mining/Metals (Nickel/Gold/Copper)", factors = c("LMNIDS03 LME Comdty", "XAU Curncy")),
  "AMMN" = list(sector = "Mining/Metals (Copper/Gold)", factors = c("LMNIDS03 LME Comdty", "XAU Curncy")),
  "MBMA" = list(sector = "Mining/Metals (Nickel/Battery)", factors = c("LMNIDS03 LME Comdty", "USDIDR BGN Curncy")),
  "ANTM" = list(sector = "Mining/Metals (Gold & Nickel)", factors = c("XAU Curncy", "LMNIDS03 LME Comdty")),
  "SMGR" = list(sector = "Cement/Building Materials", factors = c("GTIDR1Y Govt", "CLA Comdty")),
  "INTP" = list(sector = "Cement/Building Materials", factors = c("GTIDR1Y Govt", "CLA Comdty")),
  "INKP" = list(sector = "Pulp & Paper", factors = c("USDIDR BGN Curncy", "CLA Comdty")),
  "KRAS" = list(sector = "Steel", factors = c("LMNIDS03 LME Comdty", "USDIDR BGN Curncy")),
  "BSDE" = list(sector = "Property/Real Estate", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "SMRA" = list(sector = "Property/Real Estate", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "CTRA" = list(sector = "Property/Real Estate", factors = c("GTIDR1Y Govt", "USDIDR BGN Curncy")),
  "ADRO" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "PTBA" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "ITMG" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "HRUM" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "ADMR" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "BUMI" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "AADI" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "CUAN" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "DEWA" = list(sector = "Coal Mining/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "PGAS" = list(sector = "Oil & Gas/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "MEDC" = list(sector = "Oil & Gas/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "ESSA" = list(sector = "Oil & Gas/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "PGEO" = list(sector = "Oil & Gas/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "AKRA" = list(sector = "Oil & Gas/Energy", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "BRPT" = list(sector = "Petrochemicals/Chemicals", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "BUKA" = list(sector = "Technology/Media/Digital", factors = c("USDIDR BGN Curncy", "IBPRCPI Index")),
  "EMTK" = list(sector = "Technology/Media/Digital", factors = c("USDIDR BGN Curncy", "IBPRCPI Index")),
  "SCMA" = list(sector = "Technology/Media/Digital", factors = c("USDIDR BGN Curncy", "IBPRCPI Index")),
  "KLBF" = list(sector = "Healthcare/Pharmaceuticals", factors = c("IBPRCPI Index", "USDIDR BGN Curncy")),
  "MIKA" = list(sector = "Healthcare/Pharmaceuticals", factors = c("IBPRCPI Index", "USDIDR BGN Curncy")),
  "GIAA" = list(sector = "Aviation/Transportation", factors = c("CLA Comdty", "USDIDR BGN Curncy")),
  "HRTA" = list(sector = "Gold Jewelry/Precious Metals Retail", factors = c("XAU Curncy", "USDIDR BGN Curncy"))
)

SECTOR_MANDATORY_FACTOR_DEFAULT <- list(sector = "Diversified/Lainnya", factors = c("USDIDR BGN Curncy"))

get_sector_mandatory_factors <- function(stock_name, macro_cols_available) {
  code_clean <- toupper(trimws(gsub("\\s*IJ\\s*EQUITY.*$", "", stock_name, ignore.case = TRUE)))
  entry <- SECTOR_MANDATORY_FACTOR_MAP[[code_clean]]
  if (is.null(entry)) entry <- SECTOR_MANDATORY_FACTOR_DEFAULT
  factors_avail <- entry$factors[entry$factors %in% macro_cols_available]
  list(sector = entry$sector, mandatory_factors = factors_avail, ticker_code = code_clean)
}

best_subset_selection_constrained <- function(dep_var, candidate_vars, data_df, mandatory_vars,
                                              min_selected = 4L, bic_tol = 1e-6) {
  
  mandatory_vars <- unique(mandatory_vars)
  sel_cols   <- c(dep_var, candidate_vars)
  valid_rows <- stats::complete.cases(data_df[, sel_cols, drop = FALSE])
  sel_df     <- data_df[valid_rows, sel_cols, drop = FALSE]
  n_obs      <- nrow(sel_df)
  n_cand     <- length(candidate_vars)
  
  result <- list(
    dependent_variable   = dep_var,
    candidate_variables  = candidate_vars,
    mandatory_variables  = mandatory_vars,
    min_selected         = min_selected,
    n_candidate          = n_cand,
    n_obs_selection      = n_obs,
    selected_variables   = character(0),
    number_selected      = 0L,
    sse                  = NA_real_,
    bic                  = NA_real_,
    subset_size          = NA_integer_,
    n_subsets_evaluated  = 0L,
    n_subsets_constrained_space = 0L,
    selection_status     = "GAGAL",
    failure_reason       = NA_character_,
    all_subsets_table    = data.frame()
  )
  
  if (dep_var %in% candidate_vars) {
    result$failure_reason <- paste0("Dependent variable '", dep_var, "' ditemukan pada candidate_vars - ",
                                    "dependent variable tidak boleh menjadi predictor.")
    return(result)
  }
  
  if (!all(mandatory_vars %in% candidate_vars)) {
    result$failure_reason <- paste0("Mandatory variable(s) berikut tidak terdapat pada candidate_vars: ",
                                    paste(setdiff(mandatory_vars, candidate_vars), collapse = ", "), ".")
    return(result)
  }
  
  effective_min_selected <- max(as.integer(min_selected), length(mandatory_vars))
  if (effective_min_selected > n_cand) {
    result$failure_reason <- paste0("Jumlah mandatory variables (", length(mandatory_vars),
                                    ") + minimum selection (", min_selected, ") melebihi jumlah candidate ",
                                    "variables yang tersedia (", n_cand, ").")
    return(result)
  }
  
  min_obs_required <- n_cand + 3
  if (n_obs < min_obs_required) {
    result$failure_reason <- paste0("Observasi valid (n = ", n_obs, ") tidak mencukupi untuk Best Subset ",
                                    "dengan ", n_cand, " candidate predictors (minimum dibutuhkan sekitar ",
                                    min_obs_required, " observasi).")
    return(result)
  }
  
  size_candidates <- effective_min_selected:n_cand
  all_subsets_list <- unlist(
    lapply(size_candidates, function(k) {
      combs_k <- combn(candidate_vars, k, simplify = FALSE)
      Filter(function(v) all(mandatory_vars %in% v), combs_k)
    }),
    recursive = FALSE
  )
  result$n_subsets_constrained_space <- length(all_subsets_list)
  
  if (length(all_subsets_list) == 0) {
    result$failure_reason <- paste0("Tidak ada subset valid yang memenuhi constraint minimum ",
                                    effective_min_selected, " variabel dengan mandatory variable(s): ",
                                    paste(mandatory_vars, collapse = ", "), ".")
    return(result)
  }
  
  subset_rows <- vector("list", length(all_subsets_list))
  
  for (i in seq_along(all_subsets_list)) {
    vars_i    <- all_subsets_list[[i]]
    k_i       <- length(vars_i)
    formula_i <- as.formula(paste0("`", dep_var, "` ~ ", paste0("`", vars_i, "`", collapse = " + ")))
    fit_i     <- tryCatch(lm(formula_i, data = sel_df), error = function(e) NULL)
    
    if (is.null(fit_i)) {
      subset_rows[[i]] <- data.frame(
        Subset_ID = i, Subset_Size = k_i, N_Variables = k_i,
        Variables = paste(vars_i, collapse = " + "), N_Obs = n_obs,
        Contains_Mandatory = all(mandatory_vars %in% vars_i),
        SSE = NA_real_, N_Params = k_i + 1, LogLik = NA_real_, BIC = NA_real_,
        Status = "Gagal Estimasi OLS", stringsAsFactors = FALSE
      )
      next
    }
    
    resid_i  <- stats::residuals(fit_i)
    sse_i    <- sum(resid_i^2)
    n_params_i <- k_i + 1
    sigma2_i <- sse_i / n_obs
    
    if (!is.finite(sigma2_i) || sigma2_i <= 0) {
      ll_i <- NA_real_; bic_i <- NA_real_; status_i <- "Gagal (variance residual <= 0)"
    } else {
      ll_i       <- -0.5 * n_obs * (log(2 * pi) + log(sigma2_i) + 1)
      k_total_i  <- n_params_i + 1
      bic_i      <- -2 * ll_i + k_total_i * log(n_obs)
      status_i   <- "Berhasil"
    }
    
    subset_rows[[i]] <- data.frame(
      Subset_ID = i, Subset_Size = k_i, N_Variables = k_i,
      Variables = paste(vars_i, collapse = " + "), N_Obs = n_obs,
      Contains_Mandatory = all(mandatory_vars %in% vars_i),
      SSE = sse_i, N_Params = n_params_i, LogLik = ll_i, BIC = bic_i,
      Status = status_i, stringsAsFactors = FALSE
    )
  }
  
  all_subsets_table <- do.call(rbind, subset_rows)
  result$n_subsets_evaluated <- nrow(all_subsets_table)
  
  valid_subsets <- all_subsets_table[all_subsets_table$Status == "Berhasil" & is.finite(all_subsets_table$BIC), ]
  
  if (nrow(valid_subsets) == 0) {
    result$all_subsets_table <- all_subsets_table
    result$failure_reason <- paste0("Seluruh ", nrow(all_subsets_table),
                                    " subset (dalam constrained space) GAGAL diestimasi atau menghasilkan BIC ",
                                    "tidak terhingga.")
    return(result)
  }
  
  min_bic  <- min(valid_subsets$BIC)
  near_min <- valid_subsets[abs(valid_subsets$BIC - min_bic) <= bic_tol, ]
  if (nrow(near_min) > 1) {
    near_min <- near_min[order(near_min$Subset_Size, near_min$Variables), ]
  }
  best_row <- near_min[1, ]
  
  ord_idx <- order(all_subsets_table$BIC, na.last = TRUE)
  all_subsets_table <- all_subsets_table[ord_idx, ]
  rownames(all_subsets_table) <- NULL
  all_subsets_table$Rank_BIC <- NA_integer_
  n_valid <- sum(is.finite(all_subsets_table$BIC))
  if (n_valid > 0) all_subsets_table$Rank_BIC[seq_len(n_valid)] <- seq_len(n_valid)
  all_subsets_table$Terpilih <- ifelse(all_subsets_table$Subset_ID == best_row$Subset_ID,
                                       "TERPILIH (BIC minimum, constrained)", "")
  
  selected_vars_best <- all_subsets_list[[best_row$Subset_ID]]
  
  result$selected_variables <- selected_vars_best
  result$number_selected    <- length(selected_vars_best)
  result$sse                <- best_row$SSE
  result$bic                <- best_row$BIC
  result$subset_size        <- best_row$Subset_Size
  result$selection_status   <- "BERHASIL"
  result$failure_reason     <- NA_character_
  result$all_subsets_table  <- all_subsets_table
  
  result
}


raw_data <- readxl::read_excel(input_path, sheet = 1)
raw_data <- as.data.frame(raw_data)

date_col <- names(raw_data)[1]
raw_data[[date_col]] <- as.Date(raw_data[[date_col]])

raw_data <- raw_data[order(raw_data[[date_col]], seq_len(nrow(raw_data))), ]

# [REFACTOR-DEDUPE] original kept the FIRST row per date. Policy is now explicit via
# RAW_DEDUPE_POLICY ("last" default = the later-ingested row supersedes; "first" = legacy behaviour).
.dedupe_policy <- Sys.getenv("RAW_DEDUPE_POLICY", unset = "last")
n_dup <- sum(duplicated(raw_data[[date_col]]))
if (n_dup > 0) {
  cat(">> PERINGATAN: Ditemukan", n_dup, "tanggal duplikat. Baris duplikat dihapus (policy =", .dedupe_policy, ").\n")
  raw_data <- raw_data[!duplicated(raw_data[[date_col]], fromLast = identical(.dedupe_policy, "last")), ]
}

aggregate_to_5day_blocks <- function(df, date_col) {
  n_daily  <- nrow(df)
  n_blocks <- floor(n_daily / 5)
  n_used   <- n_blocks * 5
  n_dropped_rows <- n_daily - n_used
  
  if (n_blocks == 0) {
    stop("aggregate_to_5day_blocks(): kurang dari 5 observasi harian tersedia - ",
         "tidak dapat membentuk satu pun blok 5-trading-day non-overlapping.")
  }
  
  if (n_dropped_rows > 0) {
    cat(">> [AGREGASI 5-HARI] PERINGATAN: blok terakhir TIDAK LENGKAP (hanya",
        n_dropped_rows, "dari 5 trading days tersisa) - blok ini DILEWATI dari",
        "estimation sample (tidak ada padding/interpolation/synthetic observation).",
        "Tanggal harian yang dilewati:",
        paste(as.character(df[[date_col]][(n_used + 1):n_daily]), collapse = ", "), "\n")
  }
  
  block_last_idx <- seq(5, n_used, by = 5)
  df_5d <- df[block_last_idx, , drop = FALSE]
  rownames(df_5d) <- NULL
  
  if (anyDuplicated(df_5d[[date_col]]) != 0) {
    stop("aggregate_to_5day_blocks(): ditemukan tanggal period DUPLIKAT pasca-agregasi.")
  }
  if (is.unsorted(df_5d[[date_col]], strictly = TRUE)) {
    stop("aggregate_to_5day_blocks(): tanggal period pasca-agregasi TIDAK strictly ",
         "increasing - indikasi blok overlap atau data input tidak terurut dengan benar.")
  }
  if (nrow(df_5d) != n_blocks) {
    stop("aggregate_to_5day_blocks(): jumlah observasi pasca-agregasi (", nrow(df_5d),
         ") tidak sama dengan floor(N_daily/5) = ", n_blocks, " - audit ulang logika blok.")
  }
  
  cat(">> [AGREGASI 5-HARI] Raw daily observations           :", n_daily, "\n")
  cat(">> [AGREGASI 5-HARI] 5-day observations (non-overlap) :", nrow(df_5d), "\n")
  cat(">> [AGREGASI 5-HARI] Dropped incomplete final block   :",
      if (n_dropped_rows > 0) paste0("YA (", n_dropped_rows, " observasi harian)") else "TIDAK ADA", "\n")
  cat(">> [AGREGASI 5-HARI] 5-day sample start / end         :",
      as.character(min(df_5d[[date_col]])), "/", as.character(max(df_5d[[date_col]])), "\n")
  cat(">> [AGREGASI 5-HARI] Metode agregasi                  : last-observation-of-block",
      "(level/price); return/transformasi dihitung SETELAHNYA pada tahap masing-masing",
      "(calc_log_return utk saham; detect_transformation_type/transform_series utk makro)",
      "-> otomatis menjadi cumulative 5-day return.\n\n")
  
  attr(df_5d, "frequency")            <- "5-trading-day non-overlapping"
  attr(df_5d, "aggregation_method")   <- "last-observation-of-block (level/price)"
  attr(df_5d, "n_daily_raw")          <- n_daily
  attr(df_5d, "n_incomplete_block_dropped_rows") <- n_dropped_rows
  df_5d
}

cat("\n#####################################################################\n")
cat("#  AGREGASI FREKUENSI: DAILY -> 5-TRADING-DAY NON-OVERLAPPING BLOCKS\n")
cat("#####################################################################\n")

raw_data_daily <- raw_data
raw_data <- raw_data_daily

missing_summary <- data.frame(
  Variable    = names(raw_data),
  N_Missing   = sapply(raw_data, function(x) sum(is.na(x))),
  Pct_Missing = round(sapply(raw_data, function(x) mean(is.na(x)) * 100), 3),
  row.names = NULL
)
cat("\n--- Ringkasan Missing Value (Raw Data) ---\n")
print(missing_summary)

all_numeric_cols <- names(raw_data)[-which(names(raw_data) == date_col)]

stock_pattern <- "\\bIJ\\s*EQUITY\\b"
stock_targets <- all_numeric_cols[grepl(stock_pattern, all_numeric_cols, ignore.case = TRUE)]

if (length(stock_targets) == 0) {
  legacy_tickers <- c("BBCA IJ EQUITY", "PGAS IJ EQUITY", "ADRO IJ EQUITY", "ANTM IJ EQUITY")
  stock_targets <- legacy_tickers[legacy_tickers %in% all_numeric_cols]
  if (length(stock_targets) > 0) {
    cat(">> PERINGATAN: Tidak ada kolom yang cocok dengan pola 'IJ EQUITY'.",
        "Menggunakan daftar ticker cadangan (legacy) yang ditemukan pada dataset.\n")
  }
}

if (length(stock_targets) == 0) {
  stop(paste0("Tidak ditemukan kolom saham pada dataset. Pastikan nama kolom saham ",
              "mengikuti konvensi Bloomberg '<TICKER> IJ EQUITY'."))
}

macro_cols <- setdiff(all_numeric_cols, stock_targets)

if (length(macro_cols) == 0) {
  stop("Tidak ditemukan kolom variabel makroekonomi pada dataset (seluruh kolom terdeteksi sebagai saham).")
}

cat("\nJumlah ticker saham terdeteksi (dinamis)       :", length(stock_targets), "\n")
cat("Variabel dependen (saham) yang akan diproses  :", paste(stock_targets, collapse = ", "), "\n")
cat("Jumlah variabel makroekonomi independen        :", length(macro_cols), "\n")
cat("Daftar variabel makro                           :", paste(macro_cols, collapse = ", "), "\n\n")

MACRO_MAX_P              <- 3
MACRO_MAX_Q              <- 3
MACRO_MAX_GARCH_P        <- 2
MACRO_MAX_GARCH_Q        <- 2
MACRO_GARCH_DISTRIBUTIONS <- c("norm", "std", "sstd", "ged")

cat("\n#####################################################################\n")
cat("#  MEMULAI MACROECONOMICS PIPELINE (", length(macro_cols), "VARIABEL MAKRO )\n")
cat("#####################################################################\n")

if (RUN_MACRO_AND_JOINT) {
wb_macro <- openxlsx::createWorkbook()
macro_pipeline_results <- list()

for (v in macro_cols) {
  macro_pipeline_results[[v]] <- tryCatch({
    run_macro_pipeline_one(
      var_name      = v,
      price_series  = raw_data[[v]],
      dates         = raw_data[[date_col]],
      plots_root    = plots_root,
      wb_macro      = wb_macro,
      max_p         = MACRO_MAX_P,
      max_q         = MACRO_MAX_Q,
      max_garch_p   = MACRO_MAX_GARCH_P,
      max_garch_q   = MACRO_MAX_GARCH_Q,
      garch_dists   = MACRO_GARCH_DISTRIBUTIONS
    )
  }, error = function(e) {
    cat("\n>> ERROR FATAL pada macroeconomics pipeline variabel", v, ":", conditionMessage(e), "\n")
    NULL
  })
}

failed_macro <- macro_cols[sapply(macro_pipeline_results, is.null)]
if (length(failed_macro) > 0) {
  stop(paste0("Macroeconomics pipeline GAGAL pada variabel: ",
              paste(failed_macro, collapse = ", "),
              ". Periksa log error di atas sebelum melanjutkan ke pipeline Markov."))
}

macro_model_summary <- do.call(rbind, lapply(macro_pipeline_results, function(res) {
  data.frame(
    Variable   = res$var_name,
    Diff_Order = res$d_applied,
    ARMA_Order = paste0("(", res$arma_order[1], ",", res$arma_order[2], ")"),
    GARCH_Used = res$garch_used,
    Model_Final = res$garch_model_desc,
    stringsAsFactors = FALSE
  )
}))
openxlsx::addWorksheet(wb_macro, "Model Summary")
openxlsx::writeData(wb_macro, "Model Summary", macro_model_summary)

cat("\n--- RINGKASAN MODEL AKHIR MACROECONOMICS PIPELINE ---\n")
print(macro_model_summary)

macro_processed_df <- NULL
for (v in macro_cols) {
  res <- macro_pipeline_results[[v]]
  col_df <- data.frame(Dates = res$work_dates)
  col_df[[v]] <- res$work_series
  macro_processed_df <- if (is.null(macro_processed_df)) {
    col_df
  } else {
    merge(macro_processed_df, col_df, by = "Dates", all = TRUE)
  }
}
macro_processed_df <- macro_processed_df[order(macro_processed_df$Dates), ]
} else {
  # [REFACTOR-SHARDING] stages 'stocks'/'merge': macro results come from the 'joint' job (validated against this input).
  macro_processed_df <- pipeline_load_macro_stage(MACRO_STAGE_FILE, macro_cols, stock_targets, PIPELINE_INPUT_MD5)
  cat(">> [STAGE", PIPELINE_STAGE, "] macro_processed_df dimuat dari", MACRO_STAGE_FILE, "\n")
}
rownames(macro_processed_df) <- NULL

if (RUN_MACRO_AND_JOINT) {
macro_excel_path <- file.path(output_dir, "Output_MacroeconomicsPipeline.xlsx")
openxlsx::saveWorkbook(wb_macro, macro_excel_path, overwrite = TRUE)
cat("\n>> File Excel Macroeconomics Pipeline berhasil disimpan:", macro_excel_path, "\n")

macro_summary_path <- file.path(output_dir, "Summary_MacroeconomicsPipeline.txt")
sink(macro_summary_path)
cat("================================================================\n")
cat(" RINGKASAN HASIL MACROECONOMICS PIPELINE (ARMA / ARMA-GARCH)\n")
cat(" Tanggal analisis:", as.character(Sys.Date()), "\n")
cat("================================================================\n\n")
cat("RINGKASAN MODEL AKHIR TIAP VARIABEL MAKRO\n")
cat("-----------------------------------------\n")
print(macro_model_summary)
cat("\n\nCATATAN: Detail lengkap tiap tahapan (statistik deskriptif, uji\n")
cat("stasioneritas, pencarian orde ARMA, uji ARCH-LM, pencarian orde GARCH,\n")
cat("dan diagnostik) untuk masing-masing variabel makro tersedia pada file\n")
cat("Excel:", macro_excel_path, "\n")
sink()
cat(">> Summary_MacroeconomicsPipeline.txt berhasil disimpan:", macro_summary_path, "\n")

cat("\n#####################################################################\n")
cat("#  MACROECONOMICS PIPELINE SELESAI - LANJUT KE PIPELINE MARKOV\n")
cat("#####################################################################\n\n")

cat("\n#####################################################################\n")
cat("#  MEMULAI DCC-GARCH & STUDENT-T COPULA (JOINT DISTRIBUTION F(X))\n")
cat("#####################################################################\n")

bagian_4c_status <- tryCatch({
  
  dcc_copula_dir <- file.path(plots_root, "DCC_Copula")
  if (!dir.exists(dcc_copula_dir)) dir.create(dcc_copula_dir, recursive = TRUE)
  wb_dcc <- openxlsx::createWorkbook()
  
  dcc_dates_list <- lapply(macro_pipeline_results, function(res) res$work_dates)
  common_dates <- Reduce(intersect, dcc_dates_list)
  common_dates <- sort(as.Date(common_dates, origin = "1970-01-01"))
  
  cat(">> Jumlah observasi beririsan (seluruh variabel makro):", length(common_dates), "\n")
  
  dcc_input_matrix <- sapply(macro_cols, function(v) {
    res <- macro_pipeline_results[[v]]
    idx <- match(common_dates, res$work_dates)
    res$work_series[idx]
  })
  colnames(dcc_input_matrix) <- macro_cols
  rownames(dcc_input_matrix) <- as.character(common_dates)
  
  complete_rows <- stats::complete.cases(dcc_input_matrix)
  dcc_input_matrix <- dcc_input_matrix[complete_rows, , drop = FALSE]
  dcc_dates_final  <- common_dates[complete_rows]
  
  cat(">> Dimensi matriks input (deret stasioner) untuk DCC-GARCH:",
      nrow(dcc_input_matrix), "x", ncol(dcc_input_matrix), "\n")
  
  if (nrow(dcc_input_matrix) < 50) {
    stop("Observasi beririsan terlalu sedikit (<50) untuk estimasi DCC-GARCH yang stabil.")
  }
  
  uspec_list <- lapply(macro_cols, function(v) {
    res_v <- macro_pipeline_results[[v]]
    rugarch::ugarchspec(
      variance.model = list(model = "sGARCH", garchOrder = res_v$garch_order),
      mean.model     = list(armaOrder = res_v$arma_order, include.mean = TRUE),
      distribution.model = res_v$garch_distribution
    )
  })
  names(uspec_list) <- macro_cols
  
  uspec_spec_summary <- do.call(rbind, lapply(macro_cols, function(v) {
    res_v <- macro_pipeline_results[[v]]
    data.frame(
      Variable = v,
      ARMA_Order = paste0("(", res_v$arma_order[1], ",", res_v$arma_order[2], ")"),
      GARCH_Order = paste0("(", res_v$garch_order[1], ",", res_v$garch_order[2], ")"),
      Distribution_Diminta = res_v$garch_distribution,
      Sumber = ifelse(res_v$garch_used, "Hasil seleksi individual Bagian 4B",
                      "Default GARCH(1,1)-Normal (variabel ini tidak menunjukkan efek ARCH signifikan pada Bagian 4B)"),
      stringsAsFactors = FALSE
    )
  }))
  cat(">> Spesifikasi univariate per-variabel untuk multispec() DCC-GARCH:\n")
  print(uspec_spec_summary)
  
  uspec_multi <- tryCatch(rugarch::multispec(uspec_list),
                          error = function(e) {
                            cat(">> PERINGATAN: multispec() dengan spesifikasi individual gagal dibangun:",
                                conditionMessage(e), "- fallback ke GARCH(1,1)-Normal seragam.\n")
                            uspec_fallback <- rugarch::ugarchspec(
                              variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
                              mean.model     = list(armaOrder = c(0, 0), include.mean = TRUE),
                              distribution.model = "norm"
                            )
                            rugarch::multispec(replicate(ncol(dcc_input_matrix), uspec_fallback))
                          })
  
  if (!identical(colnames(dcc_input_matrix), names(uspec_list))) {
    stop(paste0("Audit BAGIAN 4C: urutan kolom dcc_input_matrix (",
                paste(colnames(dcc_input_matrix), collapse = ", "),
                ") tidak sama dengan urutan uspec_list (",
                paste(names(uspec_list), collapse = ", "),
                "). Estimasi dihentikan untuk mencegah setiap variabel diestimasi ",
                "dengan spesifikasi variabel lain (silent mismatch)."))
  }
  cat(">> Verifikasi kesesuaian urutan variabel (data vs spesifikasi): OK.\n")
  
  DCC_UNIVARIATE_SOLVER <- "hybrid"
  cat(">> Tahap 1 DCC-GARCH: mengestimasi", length(uspec_list), "model univariate via rugarch::multifit()",
      "(solver = '", DCC_UNIVARIATE_SOLVER, "', konsisten dengan Bagian 4B)...\n", sep = "")
  
  multi_fit <- tryCatch(
    rugarch::multifit(uspec_multi, data = dcc_input_matrix,
                      solver = DCC_UNIVARIATE_SOLVER, solver.control = list(trace = 0)),
    error = function(e) {
      cat(">> PERINGATAN: multifit() gagal:", conditionMessage(e), "\n")
      NULL
    }
  )
  
  univariate_audit_table <- NULL
  if (!is.null(multi_fit)) {
    univariate_audit_table <- do.call(rbind, lapply(seq_along(macro_cols), function(i) {
      v <- macro_cols[i]
      fit_i <- tryCatch(multi_fit@fit[[i]], error = function(e) NULL)
      res_v <- macro_pipeline_results[[v]]
      if (is.null(fit_i)) {
        return(data.frame(Variable = v, Convergence = "GAGAL (objek fit tidak tersedia)",
                          Distribution_Diminta = res_v$garch_distribution, Distribution_Terpakai = NA,
                          Distribution_Konsisten = NA, LogLik = NA, stringsAsFactors = FALSE))
      }
      conv_code <- tryCatch(fit_i@fit$convergence, error = function(e) NA)
      dist_used <- tryCatch(fit_i@model$modeldesc$distribution, error = function(e) NA)
      ll_i      <- tryCatch(as.numeric(likelihood(fit_i)), error = function(e) NA)
      data.frame(
        Variable = v,
        Convergence = ifelse(is.na(conv_code), "TIDAK DIKETAHUI",
                             ifelse(conv_code == 0, "Konvergen", paste0("TIDAK Konvergen (code=", conv_code, ")"))),
        Distribution_Diminta = res_v$garch_distribution,
        Distribution_Terpakai = dist_used,
        Distribution_Konsisten = isTRUE(dist_used == res_v$garch_distribution),
        LogLik = round(ll_i, 4),
        stringsAsFactors = FALSE
      )
    }))
    
    n_nonconv <- sum(grepl("TIDAK Konvergen|GAGAL", univariate_audit_table$Convergence))
    n_dist_mismatch <- sum(!isTRUE(univariate_audit_table$Distribution_Konsisten) &
                             !is.na(univariate_audit_table$Distribution_Terpakai))
    
    cat(">> Audit hasil multifit() - Tahap 1 DCC-GARCH:\n")
    print(univariate_audit_table)
    cat(">> Jumlah model TIDAK konvergen pada Tahap 1:", n_nonconv, "dari", length(macro_cols), "\n")
    if (n_dist_mismatch > 0) {
      cat(">> PERINGATAN: ditemukan", n_dist_mismatch, "variabel dengan distribusi TERPAKAI berbeda",
          "dari yang DIMINTA - periksa sheet 'Univariate Fit Audit'.\n")
    } else {
      cat(">> Verifikasi distribusi marginal: SELURUH variabel memakai distribusi sesuai hasil",
          "seleksi Bagian 4B (tidak ada yang dipaksa menjadi Normal).\n")
    }
  }
  
  dcc_spec <- rmgarch::dccspec(uspec = uspec_multi, dccOrder = c(1, 1), distribution = "mvt")
  
  fit_dcc_stage2 <- function(use_scale) {
    tryCatch(
      rmgarch::dccfit(dcc_spec, data = dcc_input_matrix, solver = "solnp",
                      fit.control = list(eval.se = TRUE, stationarity = TRUE, scale = use_scale),
                      fit = multi_fit),
      error = function(e) {
        cat(">> PERINGATAN: dccfit() (Tahap 2, scale =", use_scale, ") gagal:", conditionMessage(e), "\n")
        NULL
      }
    )
  }
  
  dcc_fit <- NULL
  dcc_scale_used <- FALSE
  if (!is.null(multi_fit)) {
    cat(">> Tahap 2 DCC-GARCH: mengestimasi parameter korelasi dinamis (dccfit, fit = multi_fit,",
        "univariate TIDAK diestimasi ulang)...\n")
    dcc_fit <- fit_dcc_stage2(FALSE)
    
    if (!is.null(dcc_fit)) {
      hess_check <- tryCatch(dcc_fit@mfit$Hessian, error = function(e) NULL)
      pd_check <- if (!is.null(hess_check)) {
        eig_check <- tryCatch(eigen(hess_check, only.values = TRUE, symmetric = TRUE)$values, error = function(e) NA)
        all(is.finite(eig_check)) && all(eig_check > 0)
      } else NA
      if (isFALSE(pd_check)) {
        cat(">> Hessian Tahap 2 TIDAK positive definite dengan scale=FALSE - mencoba ulang",
            "dengan fit.control$scale=TRUE (remedi numerik standar per dokumentasi rmgarch)...\n")
        dcc_fit_rescaled <- fit_dcc_stage2(TRUE)
        if (!is.null(dcc_fit_rescaled)) {
          hess_check2 <- tryCatch(dcc_fit_rescaled@mfit$Hessian, error = function(e) NULL)
          pd_check2 <- if (!is.null(hess_check2)) {
            eig_check2 <- tryCatch(eigen(hess_check2, only.values = TRUE, symmetric = TRUE)$values, error = function(e) NA)
            all(is.finite(eig_check2)) && all(eig_check2 > 0)
          } else NA
          if (isTRUE(pd_check2)) {
            cat(">> Hessian POSITIVE DEFINITE setelah penskalaan data (scale=TRUE) - hasil",
                "dengan penskalaan digunakan sebagai hasil akhir.\n")
            dcc_fit <- dcc_fit_rescaled
            dcc_scale_used <- TRUE
          } else {
            cat(">> Hessian TETAP tidak positive definite meskipun dengan penskalaan data.",
                "Estimasi (scale=FALSE) tetap dipakai; diagnosis lengkap pada sheet",
                "'DCC Hessian Diagnostics'.\n")
          }
        }
      }
    }
  } else {
    cat(">> Tahap 2 DILEWATI: Tahap 1 (multifit) gagal sepenuhnya.\n")
  }
  dcc_success <- !is.null(dcc_fit)
  
  if (dcc_success) {
    cat(">> Estimasi DCC-GARCH BERHASIL.\n")
    
    dcc_matcoef <- tryCatch(dcc_fit@mfit$matcoef, error = function(e) NULL)
    se_source_note <- NA
    
    if (!is.null(dcc_matcoef) && ncol(dcc_matcoef) >= 4) {
      dcc_coef  <- dcc_matcoef[, 1]
      dcc_se    <- dcc_matcoef[, 2]
      dcc_tstat <- dcc_matcoef[, 3]
      dcc_pval  <- dcc_matcoef[, 4]
      names(dcc_coef) <- rownames(dcc_matcoef)
      se_source_note <- "Package rmgarch (dcc_fit@mfit$matcoef) - sumber resmi, direkomendasikan dokumentasi package."
    } else {
      cat(">> PERINGATAN: dcc_fit@mfit$matcoef tidak tersedia pada objek hasil estimasi ini.",
          "Standard Error dihitung via fallback inverse-Hessian (lihat catatan pada output).\n")
      dcc_coef <- coef(dcc_fit)
      dcc_hessian_raw <- tryCatch(dcc_fit@mfit$Hessian, error = function(e) NULL)
      dcc_vcov_fallback <- NULL
      if (!is.null(dcc_hessian_raw)) {
        v_pos <- tryCatch(solve(dcc_hessian_raw), error = function(e) NULL)
        v_neg <- tryCatch(solve(-dcc_hessian_raw), error = function(e) NULL)
        if (!is.null(v_pos) && all(diag(v_pos) > 0, na.rm = TRUE)) {
          dcc_vcov_fallback <- v_pos
        } else if (!is.null(v_neg) && all(diag(v_neg) > 0, na.rm = TRUE)) {
          dcc_vcov_fallback <- v_neg
        }
      }
      if (!is.null(dcc_vcov_fallback)) {
        dcc_se <- sqrt(diag(dcc_vcov_fallback))
        se_source_note <- "FALLBACK: inverse Hessian numerik (dcc_fit@mfit$Hessian) - matcoef package tidak tersedia."
      } else {
        dcc_se <- rep(NA_real_, length(dcc_coef))
        se_source_note <- paste0("TIDAK TERSEDIA: package rmgarch tidak menyediakan matcoef, dan Hessian ",
                                 "(dcc_fit@mfit$Hessian) tidak dapat diinversi menjadi matriks varians ",
                                 "yang valid (non-positive-definite pada kedua konvensi tanda). Standard ",
                                 "Error TIDAK dapat dihitung untuk hasil estimasi ini; nilai Estimate tetap valid.")
      }
      dcc_tstat <- dcc_coef / dcc_se
      dcc_pval  <- 2 * (1 - pnorm(abs(dcc_tstat)))
    }
    
    dcc_param_table <- data.frame(
      Parameter = names(dcc_coef), Estimate = as.numeric(dcc_coef),
      Std_Error = as.numeric(dcc_se), t_statistic = as.numeric(dcc_tstat), p_value = as.numeric(dcc_pval),
      CI_Lower_95 = as.numeric(dcc_coef) - 1.96 * as.numeric(dcc_se),
      CI_Upper_95 = as.numeric(dcc_coef) + 1.96 * as.numeric(dcc_se),
      Signifikansi = ifelse(is.na(dcc_pval), "N/A",
                            ifelse(dcc_pval < 0.01, "***", ifelse(dcc_pval < 0.05, "**",
                                                                  ifelse(dcc_pval < 0.10, "*", "tidak signifikan")))),
      stringsAsFactors = FALSE
    )
    
    dcc_ab <- dcc_coef[grepl("dcca|dccb", names(dcc_coef), ignore.case = TRUE)]
    dcc_persistence <- sum(dcc_ab, na.rm = TRUE)
    
    dcc_ll    <- tryCatch(as.numeric(likelihood(dcc_fit)), error = function(e) NA)
    n_dcc_par <- length(dcc_coef)
    n_dcc_obs <- nrow(dcc_input_matrix)
    dcc_aic  <- -2 * dcc_ll + 2 * n_dcc_par
    dcc_bic  <- -2 * dcc_ll + n_dcc_par * log(n_dcc_obs)
    dcc_hqic <- -2 * dcc_ll + 2 * n_dcc_par * log(log(n_dcc_obs))
    
    dcc_model_summary <- data.frame(
      Item = c("Jumlah Variabel", "Jumlah Observasi", "DCC Order", "Distribusi",
               "Persistence (alpha+beta)", "Log-Likelihood", "AIC", "BIC", "HQIC",
               "Status Stasioneritas DCC", "Sumber Standard Error", "Solver Univariate (Tahap 1)",
               "Solver DCC (Tahap 2)", "Data Direskalakan (fit.control$scale)"),
      Nilai = c(ncol(dcc_input_matrix), n_dcc_obs, "(1,1)", "Multivariate-t",
                round(dcc_persistence, 4), round(dcc_ll, 4), round(dcc_aic, 3),
                round(dcc_bic, 3), round(dcc_hqic, 3),
                ifelse(dcc_persistence < 1, "Stasioner (alpha+beta < 1)",
                       "TIDAK Stasioner (alpha+beta >= 1)"),
                se_source_note, DCC_UNIVARIATE_SOLVER, "solnp",
                ifelse(dcc_scale_used, "YA (diaktifkan sebagai remedi Hessian - lihat DCC Hessian Diagnostics)", "TIDAK"))
    )
    
    univariate_persistence_flags <- character(0)
    if (!is.null(multi_fit)) {
      for (i in seq_along(macro_cols)) {
        fit_i <- tryCatch(multi_fit@fit[[i]], error = function(e) NULL)
        if (!is.null(fit_i)) {
          coef_i <- tryCatch(coef(fit_i), error = function(e) NULL)
          if (!is.null(coef_i)) {
            ab_i <- coef_i[grepl("^alpha|^beta", names(coef_i))]
            persist_i <- sum(ab_i, na.rm = TRUE)
            if (isTRUE(persist_i > 0.995)) {
              univariate_persistence_flags <- c(univariate_persistence_flags,
                                                paste0(macro_cols[i], ": alpha+beta = ", round(persist_i, 4),
                                                       " (near-unit-root pada tahap univariate)"))
            }
          }
        }
      }
    }
    
    dcc_boundary_flags <- character(0)
    if (!is.na(dcc_persistence) && dcc_persistence > 0.98) {
      dcc_boundary_flags <- c(dcc_boundary_flags,
                              paste0("alpha+beta = ", round(dcc_persistence, 4),
                                     " (mendekati batas stasioneritas 1)"))
    }
    if (length(univariate_persistence_flags) > 0) {
      dcc_boundary_flags <- c(dcc_boundary_flags, univariate_persistence_flags)
    }
    dcc_hessian_for_diag <- tryCatch(dcc_fit@mfit$Hessian, error = function(e) NULL)
    if (!is.null(dcc_hessian_for_diag)) {
      dcc_hess_diag <- diagnose_hessian_numerics(
        dcc_hessian_for_diag, param_names = names(dcc_coef),
        convergence_code = tryCatch(dcc_fit@mfit$convergence, error = function(e) NA),
        boundary_params = if (length(dcc_boundary_flags) > 0) dcc_boundary_flags else NULL
      )
      dcc_hessian_diag_table <- data.frame(
        Item = c("Positive Definite", "Jumlah Eigenvalue Negatif/Nol", "Condition Number",
                 "Rank Numerik", "Dimensi Penuh", "Singular/Near-Singular",
                 "Jumlah Pasangan Parameter Korelasi > 0.95"),
        Nilai = c(dcc_hess_diag$is_positive_definite, dcc_hess_diag$n_negative_eigenvalues,
                  round(dcc_hess_diag$condition_number, 3), dcc_hess_diag$rank,
                  dcc_hess_diag$full_rank_expected, dcc_hess_diag$is_singular,
                  nrow(dcc_hess_diag$high_correlation_pairs))
      )
      dcc_hessian_diagnosis_text <- data.frame(Diagnosis = dcc_hess_diag$diagnosis_text)
      cat(">> Diagnosis numerik Hessian DCC-GARCH:\n")
      for (dtxt in dcc_hess_diag$diagnosis_text) cat("   -", dtxt, "\n")
    } else {
      dcc_hessian_diag_table <- data.frame(Item = "Hessian", Nilai = "Tidak tersedia pada objek dcc_fit")
      dcc_hessian_diagnosis_text <- data.frame(Diagnosis = paste0(
        "Slot Hessian (dcc_fit@mfit$Hessian) tidak tersedia sehingga diagnosis numerik lengkap ",
        "tidak dapat dilakukan. Persistence (alpha+beta) tetap dapat diperiksa: ",
        round(dcc_persistence, 4), "."))
    }
    
    dcc_rcor <- rcor(dcc_fit)
    avg_corr_mat <- apply(dcc_rcor, c(1, 2), mean)
    dimnames(avg_corr_mat) <- list(macro_cols, macro_cols)
    uncond_corr_mat <- cor(dcc_input_matrix, use = "pairwise.complete.obs")
    
    pair_idx <- combn(macro_cols, 2)
    dcc_timevar_list <- vector("list", ncol(pair_idx))
    for (pi in seq_len(ncol(pair_idx))) {
      a <- pair_idx[1, pi]; b <- pair_idx[2, pi]
      ia <- which(macro_cols == a); ib <- which(macro_cols == b)
      dcc_timevar_list[[pi]] <- data.frame(
        Dates = dcc_dates_final, Pair = paste0(a, " - ", b), Correlation = dcc_rcor[ia, ib, ]
      )
    }
    dcc_timevar_df <- do.call(rbind, dcc_timevar_list)
    
    corr_melt <- reshape2::melt(avg_corr_mat)
    p_dcc_heat <- ggplot(corr_melt, aes(Var1, Var2, fill = value)) +
      geom_tile(color = "white") +
      geom_text(aes(label = round(value, 2)), size = 3) +
      scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B", midpoint = 0,
                           limits = c(-1, 1), name = "Rata-rata\nKorelasi") +
      labs(title = "Rata-rata Dynamic Conditional Correlation (DCC-GARCH)", x = NULL, y = NULL) +
      theme_thesis() + theme(axis.text.x = element_text(angle = 45, hjust = 1))
    save_plot_hd(p_dcc_heat, "DCC_Average_Correlation_Heatmap", dcc_copula_dir, width = 9, height = 8)
    
    pairs_to_plot <- unique(dcc_timevar_df$Pair)[1:min(8, length(unique(dcc_timevar_df$Pair)))]
    p_dcc_tv <- ggplot(dcc_timevar_df[dcc_timevar_df$Pair %in% pairs_to_plot, ],
                       aes(x = Dates, y = Correlation, color = Pair)) +
      geom_line(linewidth = 0.4) +
      labs(title = "Time-Varying Dynamic Conditional Correlation (DCC-GARCH)",
           subtitle = "Ditampilkan maksimum 8 pasangan pertama; seluruh pasangan tersedia pada file Excel",
           x = "Tanggal", y = "Korelasi Dinamis") +
      theme_thesis()
    save_plot_hd(p_dcc_tv, "DCC_TimeVarying_Correlation", dcc_copula_dir, width = 11, height = 6)
    
    openxlsx::addWorksheet(wb_dcc, "DCC Parameters")
    openxlsx::writeData(wb_dcc, "DCC Parameters", dcc_param_table)
    openxlsx::addWorksheet(wb_dcc, "DCC Model Summary")
    openxlsx::writeData(wb_dcc, "DCC Model Summary", dcc_model_summary)
    openxlsx::addWorksheet(wb_dcc, "DCC Hessian Diagnostics")
    openxlsx::writeData(wb_dcc, "DCC Hessian Diagnostics", dcc_hessian_diag_table)
    openxlsx::writeData(wb_dcc, "DCC Hessian Diagnostics",
                        data.frame(Catatan = "Diagnosis Naratif:"),
                        startRow = nrow(dcc_hessian_diag_table) + 3)
    openxlsx::writeData(wb_dcc, "DCC Hessian Diagnostics", dcc_hessian_diagnosis_text,
                        startRow = nrow(dcc_hessian_diag_table) + 4)
    openxlsx::addWorksheet(wb_dcc, "Univariate Spec per Variable")
    openxlsx::writeData(wb_dcc, "Univariate Spec per Variable", uspec_spec_summary)
    if (!is.null(univariate_audit_table)) {
      openxlsx::addWorksheet(wb_dcc, "Univariate Fit Audit")
      openxlsx::writeData(wb_dcc, "Univariate Fit Audit", univariate_audit_table)
      openxlsx::writeData(wb_dcc, "Univariate Fit Audit",
                          data.frame(Catatan = paste0(
                            "Kolom Distribution_Konsisten memverifikasi bahwa distribusi yang benar-benar ",
                            "terpakai pada estimasi Tahap 1 (multifit) SESUAI dengan hasil seleksi ",
                            "individual Bagian 4B (Distribution_Diminta), sehingga dapat dipastikan tidak ",
                            "ada variabel yang diam-diam dipaksa menjadi Normal akibat implementasi kode.")),
                          startRow = nrow(univariate_audit_table) + 3)
    }
    openxlsx::addWorksheet(wb_dcc, "Average Correlation")
    openxlsx::writeData(wb_dcc, "Average Correlation",
                        tibble::rownames_to_column(as.data.frame(avg_corr_mat), "Variable"))
    openxlsx::addWorksheet(wb_dcc, "Unconditional Correlation")
    openxlsx::writeData(wb_dcc, "Unconditional Correlation",
                        tibble::rownames_to_column(as.data.frame(uncond_corr_mat), "Variable"))
    openxlsx::addWorksheet(wb_dcc, "TimeVarying Correlation")
    openxlsx::writeData(wb_dcc, "TimeVarying Correlation", dcc_timevar_df)
    
    cat(">> DCC-GARCH: seluruh output tersimpan.\n")
    copula_input <- tryCatch(residuals(dcc_fit, standardize = TRUE),
                             error = function(e) dcc_input_matrix)
  } else {
    cat(">> DCC-GARCH tidak berhasil diestimasi - tahap Copula akan menggunakan",
        "standardized residual ARMA(-GARCH) univariat (Bagian 4B) secara langsung.\n")
    copula_input <- dcc_input_matrix
    
    openxlsx::addWorksheet(wb_dcc, "Univariate Spec per Variable")
    openxlsx::writeData(wb_dcc, "Univariate Spec per Variable", uspec_spec_summary)
    if (!is.null(univariate_audit_table)) {
      openxlsx::addWorksheet(wb_dcc, "Univariate Fit Audit")
      openxlsx::writeData(wb_dcc, "Univariate Fit Audit", univariate_audit_table)
      openxlsx::writeData(wb_dcc, "Univariate Fit Audit",
                          data.frame(Catatan = "Tahap 2 (estimasi parameter DCC) GAGAL - lihat log console untuk pesan error lengkap. Tabel ini menunjukkan status Tahap 1 (univariate) sebagai titik awal penelusuran."),
                          startRow = nrow(univariate_audit_table) + 3)
    }
  }
  
  copula_input <- as.matrix(copula_input)
  colnames(copula_input) <- macro_cols
  
  U <- copula::pobs(copula_input)
  colnames(U) <- macro_cols
  
  pit_uniformity_table <- do.call(rbind, lapply(macro_cols, function(v) {
    u_v <- U[, v]
    ks <- tryCatch(ks.test(u_v, "punif"), error = function(e) NULL)
    ad <- anderson_darling_uniform(u_v)
    data.frame(
      Variable = v,
      KS_Statistic = if (!is.null(ks)) unname(ks$statistic) else NA,
      KS_pvalue    = if (!is.null(ks)) ks$p.value else NA,
      KS_Keputusan = if (!is.null(ks)) {
        ifelse(ks$p.value > 0.05, "Konsisten Uniform(0,1)", "Tidak Konsisten Uniform(0,1)")
      } else NA,
      AD_Statistic = ad$statistic, AD_Keputusan = ad$decision,
      stringsAsFactors = FALSE
    )
  }))
  
  U_long <- reshape2::melt(as.data.frame(U))
  p_pit_hist <- ggplot(U_long, aes(x = value)) +
    geom_histogram(bins = 20, fill = "#1f78b4", color = "white") +
    facet_wrap(~variable, scales = "free_y") +
    labs(title = "Histogram Probability Integral Transform (PIT) - Seluruh Variabel Makro",
         x = "u = F(x)", y = "Frekuensi") +
    theme_thesis()
  save_plot_hd(p_pit_hist, "PIT_Histogram_AllVars", dcc_copula_dir, width = 12, height = 9)
  
  p_pit_qq <- ggplot(U_long, aes(sample = value)) +
    stat_qq(distribution = qunif, color = "#1f78b4") +
    stat_qq_line(distribution = qunif, color = "red") +
    facet_wrap(~variable, scales = "free") +
    labs(title = "QQ Plot Uniform(0,1) - PIT Seluruh Variabel Makro") +
    theme_thesis()
  save_plot_hd(p_pit_qq, "PIT_QQPlot_AllVars", dcc_copula_dir, width = 12, height = 9)
  
  cat(">> PIT selesai. Ringkasan uji keseragaman Uniform(0,1):\n")
  print(pit_uniformity_table)
  
  d_copula <- ncol(U)
  copula_candidates <- list(
    "Student-t" = copula::tCopula(dim = d_copula, dispstr = "un", df.fixed = FALSE),
    "Gaussian"  = copula::normalCopula(dim = d_copula, dispstr = "un"),
    "Clayton"   = copula::claytonCopula(dim = d_copula),
    "Gumbel"    = copula::gumbelCopula(dim = d_copula),
    "Frank"     = copula::frankCopula(dim = d_copula)
  )
  
  copula_fit_results <- list()
  copula_comparison  <- data.frame()
  
  for (cname in names(copula_candidates)) {
    fit_c <- tryCatch(copula::fitCopula(copula_candidates[[cname]], data = U, method = "ml"),
                      error = function(e) {
                        cat(">> PERINGATAN: Estimasi copula", cname, "gagal:", conditionMessage(e), "\n")
                        NULL
                      })
    if (!is.null(fit_c)) {
      ll_c   <- fit_c@loglik
      npar_c <- length(fit_c@estimate)
      aic_c  <- -2 * ll_c + 2 * npar_c
      bic_c  <- -2 * ll_c + npar_c * log(nrow(U))
      copula_fit_results[[cname]] <- fit_c
      copula_comparison <- rbind(copula_comparison, data.frame(
        Copula = cname, N_Param = npar_c, LogLik = ll_c, AIC = aic_c, BIC = bic_c
      ))
    }
  }
  
  if (nrow(copula_comparison) == 0) {
    stop("Seluruh kandidat model Copula gagal diestimasi.")
  }
  
  copula_comparison <- copula_comparison[order(copula_comparison$BIC), ]
  rownames(copula_comparison) <- NULL
  copula_comparison$Rank_BIC <- seq_len(nrow(copula_comparison))
  
  cat(">> Ranking model Copula berdasarkan BIC:\n")
  print(copula_comparison)
  
  best_copula_name <- copula_comparison$Copula[1]
  best_copula_fit  <- copula_fit_results[[best_copula_name]]
  cat(">> Copula terbaik terpilih:", best_copula_name, "(BIC terkecil)\n")
  
  tcop_detail <- NULL
  if ("Student-t" %in% names(copula_fit_results)) {
    tfit <- copula_fit_results[["Student-t"]]
    tcop_est <- tfit@estimate
    tcop_se  <- tryCatch(sqrt(diag(vcov(tfit))), error = function(e) rep(NA, length(tcop_est)))
    
    n_rho <- d_copula * (d_copula - 1) / 2
    pair_names <- combn(macro_cols, 2)
    rho_names  <- paste0("rho_", pair_names[1, ], "_", pair_names[2, ])
    param_names <- c(rho_names, "df (nu)")
    if (length(param_names) != length(tcop_est)) param_names <- paste0("param_", seq_along(tcop_est))
    
    tcop_param_table <- data.frame(
      Parameter = param_names, Estimate = tcop_est, Std_Error = tcop_se,
      t_statistic = tcop_est / tcop_se, p_value = 2 * (1 - pnorm(abs(tcop_est / tcop_se))),
      CI_Lower_95 = tcop_est - 1.96 * tcop_se, CI_Upper_95 = tcop_est + 1.96 * tcop_se,
      stringsAsFactors = FALSE
    )
    
    nu_est  <- tcop_est[length(tcop_est)]
    rho_mat <- diag(d_copula)
    rho_mat[lower.tri(rho_mat)] <- tcop_est[1:n_rho]
    rho_mat <- rho_mat + t(rho_mat) - diag(diag(rho_mat))
    diag(rho_mat) <- 1
    dimnames(rho_mat) <- list(macro_cols, macro_cols)
    
    tail_dep_mat <- matrix(NA, d_copula, d_copula, dimnames = list(macro_cols, macro_cols))
    for (a in 1:d_copula) for (b in 1:d_copula) {
      if (a != b) {
        rho_ab <- rho_mat[a, b]
        tail_dep_mat[a, b] <- 2 * pt(-sqrt((nu_est + 1) * (1 - rho_ab) / (1 + rho_ab)), df = nu_est + 1)
      }
    }
    diag(tail_dep_mat) <- 1
    
    kendall_tau_mat  <- cor(U, method = "kendall")
    spearman_rho_mat <- cor(U, method = "spearman")
    
    tcop_detail <- list(param_table = tcop_param_table, rho_matrix = rho_mat, nu = nu_est,
                        tail_dependence = tail_dep_mat, kendall_tau = kendall_tau_mat,
                        spearman_rho = spearman_rho_mat)
    
    td_melt <- reshape2::melt(tail_dep_mat)
    p_td <- ggplot(td_melt, aes(Var1, Var2, fill = value)) +
      geom_tile(color = "white") + geom_text(aes(label = round(value, 3)), size = 3) +
      scale_fill_gradient(low = "white", high = "#B2182B", name = "Tail\nDependence", na.value = "grey90") +
      labs(title = "Student-t Copula: Tail Dependence Coefficient", x = NULL, y = NULL) +
      theme_thesis() + theme(axis.text.x = element_text(angle = 45, hjust = 1))
    save_plot_hd(p_td, "StudentT_TailDependence_Heatmap", dcc_copula_dir, width = 9, height = 8)
    
    cat(">> Student-t Copula: df (nu) =", round(nu_est, 3), "\n")
  }
  
  gof_method_used <- "Cramer-von Mises (Sn, multiplier bootstrap)"
  gof_result <- if ("Student-t" %in% names(copula_fit_results)) {
    tryCatch(
      copula::gofCopula(copula_candidates[["Student-t"]], x = U, N = 100,
                        method = "Sn", simulation = "mult"),
      error = function(e) {
        cat(">> Cramer-von Mises GOF tidak dapat diterapkan pada Student-t Copula dengan",
            "df diestimasi (keterbatasan package 'copula' terhadap bootstrap refitting df",
            "non-fixed):", conditionMessage(e), "\n")
        cat(">> Beralih ke prosedur validasi alternatif: PIT diagnostics berbasis",
            "Rosenblatt Transform (Genest, Quessy & Remillard, 2006).\n")
        NULL
      }
    )
  } else NULL
  
  rosenblatt_diag <- NULL
  if (is.null(gof_result) && "Student-t" %in% names(copula_fit_results)) {
    gof_method_used <- "Rosenblatt Transform PIT Diagnostics (Genest, Quessy & Remillard, 2006)"
    rosenblatt_U <- tryCatch(
      copula::cCopula(U, copula = copula_fit_results[["Student-t"]]@copula, indices = 1:d_copula),
      error = function(e) {
        cat(">> PERINGATAN: Rosenblatt Transform gagal dihitung:", conditionMessage(e), "\n")
        NULL
      }
    )
    if (!is.null(rosenblatt_U)) {
      colnames(rosenblatt_U) <- macro_cols
      rosenblatt_uniformity <- do.call(rbind, lapply(macro_cols, function(v) {
        uv <- rosenblatt_U[, v]
        ks <- tryCatch(ks.test(uv, "punif"), error = function(e) NULL)
        ad <- anderson_darling_uniform(uv)
        data.frame(Variable = v,
                   KS_Statistic = if (!is.null(ks)) unname(ks$statistic) else NA,
                   KS_pvalue    = if (!is.null(ks)) ks$p.value else NA,
                   AD_Statistic = ad$statistic, AD_Keputusan = ad$decision,
                   stringsAsFactors = FALSE)
      }))
      rosenblatt_indep_cor <- cor(rosenblatt_U, method = "pearson")
      max_abs_offdiag_cor <- max(abs(rosenblatt_indep_cor[upper.tri(rosenblatt_indep_cor)]))
      
      n_reject_uniformity <- sum(rosenblatt_uniformity$KS_pvalue < 0.05, na.rm = TRUE)
      overall_decision <- if (n_reject_uniformity == 0 && max_abs_offdiag_cor < 0.10) {
        "Konsisten dengan Student-t Copula (seluruh dimensi Uniform(0,1), independensi antar-dimensi terpenuhi)"
      } else if (n_reject_uniformity <= round(0.1 * length(macro_cols))) {
        "Cukup Konsisten (sebagian kecil dimensi menyimpang - dapat diterima pada data finansial riil)"
      } else {
        "Indikasi Lack-of-Fit (banyak dimensi menyimpang dari Uniform(0,1)/independensi)"
      }
      
      rosenblatt_diag <- list(uniformity_table = rosenblatt_uniformity,
                              independence_cor_matrix = rosenblatt_indep_cor,
                              max_abs_offdiag_correlation = max_abs_offdiag_cor,
                              n_dimensions_reject_uniformity = n_reject_uniformity,
                              overall_decision = overall_decision)
      
      cat(">> Rosenblatt Transform GOF selesai. Keputusan:", overall_decision, "\n")
    }
  }
  
  gof_table <- if (!is.null(gof_result)) {
    data.frame(Test = "Cramer-von Mises (Sn, multiplier bootstrap, N=100)",
               Statistic = unname(gof_result$statistic), p_value = gof_result$p.value,
               Keputusan = ifelse(gof_result$p.value > 0.05,
                                  "Gagal Tolak H0 (Student-t Copula sesuai dengan data)",
                                  "Tolak H0 (Student-t Copula belum sepenuhnya sesuai)"))
  } else if (!is.null(rosenblatt_diag)) {
    data.frame(Test = gof_method_used, Statistic = rosenblatt_diag$max_abs_offdiag_correlation,
               p_value = NA, Keputusan = rosenblatt_diag$overall_decision)
  } else {
    data.frame(Test = "Cramer-von Mises / Rosenblatt Transform", Statistic = NA, p_value = NA,
               Keputusan = "Tidak dapat dihitung (lihat log peringatan di console)")
  }
  
  if (!is.null(rosenblatt_diag)) {
    openxlsx::addWorksheet(wb_dcc, "Rosenblatt PIT Diagnostics")
    openxlsx::writeData(wb_dcc, "Rosenblatt PIT Diagnostics", rosenblatt_diag$uniformity_table)
    openxlsx::writeData(wb_dcc, "Rosenblatt PIT Diagnostics",
                        data.frame(Catatan = paste0(
                          "Matriks korelasi antar-dimensi hasil Rosenblatt Transform (idealnya ",
                          "mendekati matriks identitas apabila copula terspesifikasi dengan benar). ",
                          "Korelasi off-diagonal absolut maksimum = ",
                          round(rosenblatt_diag$max_abs_offdiag_correlation, 4), ".")),
                        startRow = nrow(rosenblatt_diag$uniformity_table) + 3)
    openxlsx::writeData(wb_dcc, "Rosenblatt PIT Diagnostics",
                        tibble::rownames_to_column(as.data.frame(rosenblatt_diag$independence_cor_matrix), "Variable"),
                        startRow = nrow(rosenblatt_diag$uniformity_table) + 5)
  }
  
  joint_distribution_model <- list(
    metodologi       = "Sklar's Theorem: F(x1,...,xd) = C(F1(x1),...,Fd(xd))",
    variabel_makro   = macro_cols,
    dimensi          = d_copula,
    marginal_models  = macro_pipeline_results,
    dcc_garch_fit    = if (dcc_success) dcc_fit else NULL,
    copula_terbaik   = list(nama = best_copula_name, fit = best_copula_fit,
                            comparison_table = copula_comparison),
    student_t_detail = tcop_detail,
    gof_student_t    = gof_table,
    gof_method       = gof_method_used,
    rosenblatt_diagnostics = rosenblatt_diag,
    pit_matrix       = U,
    correlation_structure = if (dcc_success) {
      list(average_dcc = avg_corr_mat, unconditional = uncond_corr_mat)
    } else NULL,
    tanggal_estimasi = Sys.Date(),
    catatan = paste0("Objek ini merepresentasikan Joint Distribution F(X) hasil integrasi ",
                     "marginal ARMA(-GARCH) (Bagian 4B), DCC-GARCH (4C.2), dan ", best_copula_name,
                     " Copula (4C.4) terpilih berdasarkan BIC. Siap dipakai sebagai input ",
                     "Conditional Monte Carlo Simulation pada tahap penelitian berikutnya ",
                     "(belum diimplementasikan pada script ini sesuai permintaan).")
  )
  
  joint_dist_path <- file.path(output_dir, "JointDistribution_Model.rds")
  saveRDS(joint_distribution_model, joint_dist_path)
  cat("\n>> Objek Joint Distribution F(X) berhasil disimpan:", joint_dist_path, "\n")
  cat(">> Siap dipakai langsung pada tahap Monte Carlo Simulation berikutnya.\n")
  
  openxlsx::addWorksheet(wb_dcc, "PIT Uniformity Test")
  openxlsx::writeData(wb_dcc, "PIT Uniformity Test", pit_uniformity_table)
  openxlsx::addWorksheet(wb_dcc, "Copula Comparison")
  openxlsx::writeData(wb_dcc, "Copula Comparison", copula_comparison)
  openxlsx::addWorksheet(wb_dcc, "GOF Student-t Copula")
  openxlsx::writeData(wb_dcc, "GOF Student-t Copula", gof_table)
  
  if (!is.null(tcop_detail)) {
    openxlsx::addWorksheet(wb_dcc, "StudentT Copula Params")
    openxlsx::writeData(wb_dcc, "StudentT Copula Params", tcop_detail$param_table)
    openxlsx::addWorksheet(wb_dcc, "StudentT Rho Matrix")
    openxlsx::writeData(wb_dcc, "StudentT Rho Matrix",
                        tibble::rownames_to_column(as.data.frame(tcop_detail$rho_matrix), "Variable"))
    openxlsx::addWorksheet(wb_dcc, "StudentT Tail Dependence")
    openxlsx::writeData(wb_dcc, "StudentT Tail Dependence",
                        tibble::rownames_to_column(as.data.frame(tcop_detail$tail_dependence), "Variable"))
    openxlsx::addWorksheet(wb_dcc, "Kendall Tau")
    openxlsx::writeData(wb_dcc, "Kendall Tau",
                        tibble::rownames_to_column(as.data.frame(tcop_detail$kendall_tau), "Variable"))
    openxlsx::addWorksheet(wb_dcc, "Spearman Rho")
    openxlsx::writeData(wb_dcc, "Spearman Rho",
                        tibble::rownames_to_column(as.data.frame(tcop_detail$spearman_rho), "Variable"))
  }
  
  dcc_copula_excel_path <- file.path(output_dir, "Output_DCC_Copula_JointDistribution.xlsx")
  openxlsx::saveWorkbook(wb_dcc, dcc_copula_excel_path, overwrite = TRUE)
  cat(">> File Excel DCC-GARCH & Copula berhasil disimpan:", dcc_copula_excel_path, "\n")
  
  dcc_copula_summary_path <- file.path(output_dir, "Summary_DCC_Copula.txt")
  sink(dcc_copula_summary_path)
  cat("================================================================\n")
  cat(" RINGKASAN DCC-GARCH & STUDENT-T COPULA (JOINT DISTRIBUTION F(X))\n")
  cat(" Tanggal analisis:", as.character(Sys.Date()), "\n")
  cat("================================================================\n\n")
  if (dcc_success) { cat("DCC-GARCH MODEL SUMMARY\n"); print(dcc_model_summary); cat("\n\n") }
  cat("RANKING MODEL COPULA (BIC)\n"); print(copula_comparison); cat("\n\n")
  cat("GOODNESS-OF-FIT STUDENT-T COPULA\n"); print(gof_table); cat("\n\n")
  cat("CATATAN: Objek lengkap (marginal models, DCC-GARCH fit, Copula fit)\n")
  cat("tersimpan pada:", joint_dist_path, "\nuntuk digunakan pada tahap Monte Carlo Simulation berikutnya.\n")
  sink()
  cat(">> Summary_DCC_Copula.txt berhasil disimpan:", dcc_copula_summary_path, "\n")
  
  "SUKSES"
  
}, error = function(e) {
  cat("\n>> PERINGATAN: BAGIAN 4C (DCC-GARCH & Copula) mengalami error dan DILEWATI:\n")
  cat("   ", conditionMessage(e), "\n")
  cat("   Pipeline akan TETAP MELANJUTKAN ke Markov Regime Switching (Bagian 5/6).\n")
  "GAGAL"
})

cat("\n#####################################################################\n")
cat("#  BAGIAN 4C SELESAI (status:", bagian_4c_status, ") - LANJUT KE PIPELINE MARKOV\n")
cat("#####################################################################\n\n")
}

if (PIPELINE_STAGE == "joint") {
  if (!identical(bagian_4c_status, "SUKSES")) {
    cat(">> [STAGE joint] BAGIAN 4C GAGAL - menghentikan lebih awal agar jam komputasi tahap saham tidak terbuang.\n")
    quit(save = "no", status = 3)
  }
  pipeline_save_macro_stage(MACRO_STAGE_FILE, macro_processed_df, macro_cols, stock_targets, PIPELINE_INPUT_MD5)
  cat(">> [STAGE joint] selesai dalam", round(as.numeric(difftime(Sys.time(), .stage_t0, units = "mins")), 1), "menit. macro_stage.rds:", MACRO_STAGE_FILE, "\n")
  quit(save = "no", status = 0)
}


run_pipeline <- function(stock_name, raw_data, macro_cols, date_col, output_dir, plots_root,
                         n_starts = 1, macro_processed_df = NULL,
                         use_student_t_full_mle = FALSE,
                         n_dup_global = NULL, missing_summary_global = NULL) {
  n_dup <- if (!is.null(n_dup_global)) n_dup_global else sum(duplicated(raw_data[[date_col]]))
  missing_summary <- if (!is.null(missing_summary_global)) {
    missing_summary_global
  } else {
    data.frame(Catatan = "missing_summary_global tidak disediakan pada pemanggilan run_pipeline() - lih. Bagian 4.")
  }
  
  cat("\n\n#####################################################################\n")
  cat("#  MEMULAI PIPELINE ANALISIS UNTUK SAHAM:", stock_name, "\n")
  cat("#####################################################################\n\n")
  
  stock_tag <- gsub("[^A-Za-z0-9]", "_", stock_name)
  plots_dir <- file.path(plots_root, stock_tag)
  if (!dir.exists(plots_dir)) dir.create(plots_dir, recursive = TRUE)
  
  wb <- openxlsx::createWorkbook()
  
  openxlsx::addWorksheet(wb, "Raw Data")
  openxlsx::writeData(wb, "Raw Data", raw_data)
  
  vars_for_return <- c(stock_name, macro_cols)
  log_return_df <- data.frame(Dates = raw_data[[date_col]])
  
  for (v in vars_for_return) {
    if (!is.null(macro_processed_df) && v %in% macro_cols) {
      merge_idx <- match(log_return_df$Dates, macro_processed_df$Dates)
      log_return_df[[v]] <- macro_processed_df[[v]][merge_idx]
    } else {
      log_return_df[[v]] <- calc_log_return(raw_data[[v]])
    }
  }
  
  suspend_detect <- detect_suspend_blocks(raw_data[[stock_name]], min_run = 3)
  n_suspend_blocks <- nrow(suspend_detect$blocks)
  n_suspend_pruned <- length(suspend_detect$suspend_idx) + length(suspend_detect$post_resume_idx)
  suspend_log_table <- data.frame(
    Stock = stock_name,
    Suspend_Terdeteksi = ifelse(n_suspend_blocks > 0, "Ya", "Tidak"),
    Jumlah_Blok_Suspend = n_suspend_blocks,
    Jumlah_Observasi_Diprune = n_suspend_pruned,
    stringsAsFactors = FALSE
  )
  suspend_block_table <- data.frame(
    Stock = character(0), Block = integer(0),
    Tanggal_Awal = character(0), Tanggal_Akhir = character(0),
    N_Obs_Suspend = integer(0), N_Obs_Return_PascaSuspend_Dibuang = integer(0)
  )
  if (n_suspend_blocks > 0) {
    for (bi in seq_len(n_suspend_blocks)) {
      blk <- suspend_detect$blocks[bi, ]
      has_post_resume <- (blk$End_Idx + 1) %in% suspend_detect$post_resume_idx
      suspend_block_table <- rbind(suspend_block_table, data.frame(
        Stock = stock_name,
        Block = blk$Block,
        Tanggal_Awal = as.character(raw_data[[date_col]][blk$Start_Idx]),
        Tanggal_Akhir = as.character(raw_data[[date_col]][blk$End_Idx]),
        N_Obs_Suspend = blk$N_Obs,
        N_Obs_Return_PascaSuspend_Dibuang = as.integer(has_post_resume)
      ))
    }
    cat(">> [SUSPEND DETECTION]", stock_name, "-", n_suspend_blocks,
        "blok suspend terdeteksi (harga identik >= 3 hari berturut-turut), total",
        n_suspend_pruned, "observasi di-prune dari dataset estimasi.\n")
    log_return_df[[stock_name]][suspend_detect$suspend_idx] <- NA
    log_return_df[[stock_name]][suspend_detect$post_resume_idx] <- NA
  } else {
    cat(">> [SUSPEND DETECTION]", stock_name,
        "- tidak ada periode suspend terdeteksi (tidak ada harga identik >= 3 hari berturut-turut).\n")
  }
  
  log_return_df <- log_return_df[-1, ]
  rownames(log_return_df) <- NULL
  
  na_rows <- which(rowSums(is.na(log_return_df[ , vars_for_return, drop = FALSE])) > 0)
  if (length(na_rows) > 0) {
    cat(">> Ditemukan", length(na_rows), "baris dengan NA pasca log-return. Baris dihapus.\n")
    log_return_df <- log_return_df[-na_rows, ]
  }
  
  inf_check <- sapply(log_return_df[vars_for_return], function(x) any(is.infinite(x)))
  if (any(inf_check)) {
    cat(">> PERINGATAN: Nilai tak-hingga (Inf) ditemukan pada:",
        paste(names(inf_check)[inf_check], collapse = ", "), "- baris terkait dihapus.\n")
    log_return_df <- log_return_df[apply(is.finite(as.matrix(log_return_df[vars_for_return])), 1, all), ]
  }
  
  suspend_log_table$Jumlah_Observasi_Final_Estimasi <- nrow(log_return_df)
  
  openxlsx::addWorksheet(wb, "Suspend Detection")
  openxlsx::writeData(wb, "Suspend Detection", suspend_log_table)
  if (nrow(suspend_block_table) > 0) {
    openxlsx::writeData(wb, "Suspend Detection", suspend_block_table,
                        startRow = nrow(suspend_log_table) + 4)
  } else {
    openxlsx::writeData(wb, "Suspend Detection",
                        data.frame(Catatan = "Tidak ada blok suspend terdeteksi untuk saham ini."),
                        startRow = nrow(suspend_log_table) + 4)
  }
  
  openxlsx::addWorksheet(wb, "Log Return")
  openxlsx::writeData(wb, "Log Return", log_return_df)
  
  preprocessing_summary <- data.frame(
    Tahapan = c(
      "Jumlah observasi awal (raw)",
      "Jumlah duplicate date dihapus",
      "Jumlah observasi setelah log-return",
      "Jumlah baris NA dihapus pasca transformasi",
      "Jumlah observasi final (siap analisis)",
      "Rentang tanggal awal",
      "Rentang tanggal akhir"
    ),
    Nilai = c(
      nrow(raw_data),
      n_dup,
      nrow(raw_data) - 1,
      length(na_rows),
      nrow(log_return_df),
      as.character(min(log_return_df$Dates)),
      as.character(max(log_return_df$Dates))
    )
  )
  openxlsx::addWorksheet(wb, "Preprocessing")
  openxlsx::writeData(wb, "Preprocessing", preprocessing_summary)
  openxlsx::writeData(wb, "Preprocessing", missing_summary, startRow = nrow(preprocessing_summary) + 4)
  
  desc_list <- lapply(vars_for_return, function(v) descriptive_stats_one(log_return_df[[v]], v))
  desc_table <- do.call(rbind, desc_list)
  
  openxlsx::addWorksheet(wb, "Descriptive Statistics")
  openxlsx::writeData(wb, "Descriptive Statistics", desc_table)
  
  cat(">> Statistik deskriptif selesai dihitung.\n")
  
  stationarity_results <- list()
  stationary_series_list <- list()
  diff_order_summary <- data.frame()
  
  for (v in vars_for_return) {
    res <- auto_stationarity_test(log_return_df[[v]], v)
    stationarity_results[[v]] <- res$table
    stationary_series_list[[v]] <- res$final_series
    diff_order_summary <- rbind(diff_order_summary, data.frame(
      Variable = v,
      Final_Diff_Order = res$final_d,
      Stationary = res$stationary
    ))
  }
  
  adf_kpss_table <- do.call(rbind, stationarity_results)
  adf_kpss_table$Interpretasi <- ifelse(
    adf_kpss_table$Final_Decision == "STASIONER",
    "Variabel stasioner pada tingkat differencing ini; dapat digunakan langsung dalam model.",
    "Variabel belum stasioner; differencing lebih lanjut diperlukan/dibatasi pada max_diff."
  )
  
  openxlsx::addWorksheet(wb, "ADF Test")
  openxlsx::writeData(wb, "ADF Test", adf_kpss_table[, c("Variable","Diff_Order","ADF_Statistic",
                                                         "ADF_pvalue","ADF_Decision","Interpretasi")])
  
  openxlsx::addWorksheet(wb, "KPSS Test")
  openxlsx::writeData(wb, "KPSS Test", adf_kpss_table[, c("Variable","Diff_Order","KPSS_Statistic",
                                                          "KPSS_pvalue","KPSS_Decision")])
  
  openxlsx::addWorksheet(wb, "Stationarity Summary")
  openxlsx::writeData(wb, "Stationarity Summary", diff_order_summary)
  
  cat(">> Uji stasioneritas (ADF & KPSS) selesai. Ringkasan differencing:\n")
  print(diff_order_summary)
  
  max_d <- max(diff_order_summary$Final_Diff_Order)
  
  model_df <- log_return_df
  if (max_d > 0) {
    cat(">> Menerapkan differencing tingkat", max_d, "secara seragam pada seluruh variabel",
        "agar observasi tetap sejajar.\n")
    trimmed <- model_df[(max_d + 1):nrow(model_df), "Dates", drop = FALSE]
    for (v in vars_for_return) {
      diffed <- diff(model_df[[v]], differences = max_d)
      trimmed[[v]] <- diffed
    }
    model_df <- trimmed
  }
  rownames(model_df) <- NULL
  
  aux_formula <- as.formula(paste0("`", stock_name, "` ~ ", paste0("`", macro_cols, "`", collapse = " + ")))
  aux_lm <- lm(aux_formula, data = model_df)
  
  vif_values <- tryCatch(car::vif(aux_lm), error = function(e) {
    cat(">> PERINGATAN: VIF gagal dihitung (kemungkinan multikolinearitas sempurna). Pesan:", conditionMessage(e), "\n")
    setNames(rep(NA, length(macro_cols)), macro_cols)
  })
  
  vif_table <- data.frame(
    Variable = names(vif_values),
    VIF      = as.numeric(vif_values)
  )
  vif_table$Keputusan <- ifelse(
    is.na(vif_table$VIF), "Tidak dapat dihitung",
    ifelse(vif_table$VIF > 10, "Multikolinearitas TINGGI (VIF > 10)",
           ifelse(vif_table$VIF > 5, "Multikolinearitas SEDANG (VIF > 5)",
                  "Tidak ada indikasi multikolinearitas"))
  )
  
  openxlsx::addWorksheet(wb, "VIF")
  openxlsx::writeData(wb, "VIF", vif_table)
  openxlsx::writeData(wb, "VIF",
                      data.frame(Catatan = "Rekomendasi: Jika VIF > 10 pada satu atau lebih variabel, pertimbangkan untuk mengeluarkan salah satu variabel yang berkorelasi tinggi, menggunakan Principal Component Analysis (PCA), atau menerapkan Ridge Regression sebagai alternatif (Kutner et al., 2005)."),
                      startRow = nrow(vif_table) + 3)
  
  cor_matrix <- cor(model_df[, macro_cols], use = "pairwise.complete.obs")
  cor_df <- as.data.frame(cor_matrix)
  cor_df <- tibble::rownames_to_column(cor_df, "Variable")
  
  openxlsx::addWorksheet(wb, "Correlation Matrix")
  openxlsx::writeData(wb, "Correlation Matrix", cor_df)
  
  cor_melt <- reshape2::melt(cor_matrix)
  p_corr <- ggplot(cor_melt, aes(Var1, Var2, fill = value)) +
    geom_tile(color = "white") +
    geom_text(aes(label = round(value, 2)), size = 3) +
    scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B",
                         midpoint = 0, limits = c(-1, 1), name = "Korelasi") +
    labs(title = paste("Correlation Matrix - Variabel Makroekonomi (", stock_name, ")"),
         x = NULL, y = NULL) +
    theme_thesis() +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
  
  save_plot_hd(p_corr, "Correlation_Heatmap", plots_dir, width = 9, height = 8)
  
  cat(">> Uji multikolinearitas (VIF & korelasi) selesai.\n")
  
  sector_map_result <- get_sector_mandatory_factors(stock_name, macro_cols)
  mandatory_vars_stock <- unique(c("JCI Index", sector_map_result$mandatory_factors))
  mandatory_vars_stock <- mandatory_vars_stock[mandatory_vars_stock %in% macro_cols]
  
  cat("\n>> [BEST SUBSET] Sektor terdeteksi untuk", stock_name, ":", sector_map_result$sector, "\n")
  cat(">> [BEST SUBSET] Mandatory variables (JCI + sector-specific):",
      paste(mandatory_vars_stock, collapse = ", "), "\n")
  cat(">> [BEST SUBSET] Memulai constrained Best Subset Selection untuk", stock_name, "-",
      length(macro_cols), "candidate macro variables, minimum 4 variabel terpilih,",
      "mandatory:", paste(mandatory_vars_stock, collapse = ", "), "...\n")
  
  best_subset_result <- best_subset_selection_constrained(
    dep_var        = stock_name,
    candidate_vars = macro_cols,
    data_df        = model_df,
    mandatory_vars = mandatory_vars_stock,
    min_selected   = 4L
  )
  
  if (identical(best_subset_result$selection_status, "BERHASIL")) {
    selected_macro_cols <- best_subset_result$selected_variables
    cat(">> [BEST SUBSET]", best_subset_result$n_subsets_evaluated, "dari",
        best_subset_result$n_subsets_constrained_space, "subset (constrained space) dievaluasi.",
        "Subset TERPILIH (BIC minimum):\n")
    cat("   Selected variables :", paste(selected_macro_cols, collapse = ", "), "\n")
    cat("   Subset size        :", best_subset_result$subset_size, "\n")
    cat("   BIC (screening)    :", round(best_subset_result$bic, 4), "\n")
    cat("   SSE (screening)    :", round(best_subset_result$sse, 6), "\n")
    cat(">> [BEST SUBSET] Hanya", length(selected_macro_cols), "variabel makro TERPILIH di atas yang",
        "diteruskan ke dynamic specification & estimasi MS-AR (BUKAN seluruh",
        length(macro_cols), "candidate variables).\n")
  } else {
    selected_macro_cols <- character(0)
    cat(">> [BEST SUBSET] GAGAL:", best_subset_result$failure_reason, "\n")
    cat(">> [BEST SUBSET] MS-AR TIDAK akan dijalankan untuk", stock_name, "karena Best Subset Selection gagal.\n")
  }
  
  bs_export_table <- best_subset_result$all_subsets_table
  openxlsx::addWorksheet(wb, "Best Subset Selection")
  if (nrow(bs_export_table) > 0) {
    openxlsx::writeData(wb, "Best Subset Selection", bs_export_table)
    openxlsx::writeData(wb, "Best Subset Selection", data.frame(
      Catatan = paste0(
        "Constrained exhaustive Best Subset Selection terhadap ", length(macro_cols), " candidate macro ",
        "variables, dependent variable = ", stock_name, ". Constraint: minimum ", best_subset_result$min_selected,
        " variabel terpilih, WAJIB memuat: ", paste(mandatory_vars_stock, collapse = ", "), " (JCI Index + ",
        "sector-specific mandatory factor sektor '", sector_map_result$sector, "'). Total subset pada ",
        "constrained space = ", best_subset_result$n_subsets_constrained_space, ", dievaluasi = ",
        best_subset_result$n_subsets_evaluated, ". Kriteria UTAMA pemilihan subset adalah BIC MINIMUM (bukan ",
        "SSE/RSS). Tie-breaking eksplisit: (1) BIC minimum, (2) jika BIC identik dalam numerical tolerance ",
        "pilih subset lebih parsimonious (jumlah predictor lebih sedikit), (3) jika masih identik gunakan ",
        "deterministic lexical ordering agar hasil reproducible. Best Subset HANYA melakukan screening ",
        "variabel makro eksogen - TIDAK memasukkan lag return/orde AR (dynamic specification tetap ditentukan ",
        "terpisah pada sheet 'AR Order Selection') dan TIDAK memasukkan parameter Markov Switching apa pun."
      )), startRow = nrow(bs_export_table) + 3)
  } else {
    openxlsx::writeData(wb, "Best Subset Selection",
                        data.frame(Catatan = paste0("Best Subset Selection GAGAL: ", best_subset_result$failure_reason)))
  }
  
  openxlsx::addWorksheet(wb, "Best Subset Summary")
  bs_summary_row <- data.frame(
    Stock                  = stock_name,
    Sector_Classification  = sector_map_result$sector,
    Mandatory_Variables    = paste(mandatory_vars_stock, collapse = ", "),
    N_Candidate_Variables  = length(macro_cols),
    Candidate_Variables    = paste(macro_cols, collapse = ", "),
    Min_Selected_Required  = best_subset_result$min_selected,
    Selected_Variables     = if (length(selected_macro_cols) > 0) paste(selected_macro_cols, collapse = ", ") else "-",
    N_Selected             = length(selected_macro_cols),
    SSE                    = best_subset_result$sse,
    BIC                    = best_subset_result$bic,
    Subset_Size            = best_subset_result$subset_size,
    N_Obs_Selection        = best_subset_result$n_obs_selection,
    N_Subsets_Constrained_Space = best_subset_result$n_subsets_constrained_space,
    N_Subsets_Evaluated    = best_subset_result$n_subsets_evaluated,
    Status                 = best_subset_result$selection_status,
    Failure_Reason         = ifelse(is.na(best_subset_result$failure_reason), "-", best_subset_result$failure_reason),
    stringsAsFactors = FALSE
  )
  openxlsx::writeData(wb, "Best Subset Summary", bs_summary_row)
  
  if (length(selected_macro_cols) == 0) {
    bs_fail_excel_path <- file.path(output_dir, paste0("Output_MarkovRegimeSwitching_", stock_tag, ".xlsx"))
    openxlsx::saveWorkbook(wb, bs_fail_excel_path, overwrite = TRUE)
    cat(">> [BEST SUBSET] Workbook (sheet Best Subset) tetap disimpan:", bs_fail_excel_path, "\n")
    return(list(
      excel_path          = bs_fail_excel_path,
      summary_path        = NA,
      best_k              = NA,
      final_fit           = NULL,
      best_subset         = best_subset_result,
      selected_variables  = character(0),
      sector_classification = sector_map_result$sector,
      status              = "GAGAL - Best Subset Selection tidak menghasilkan subset valid"
    ))
  }
  
  bs_consistency_ok <- isTRUE(length(selected_macro_cols) >= 4) &&
    isTRUE("JCI Index" %in% selected_macro_cols) &&
    isTRUE(all(mandatory_vars_stock %in% selected_macro_cols)) &&
    isTRUE(all(selected_macro_cols %in% colnames(model_df))) &&
    isTRUE(!any(duplicated(selected_macro_cols))) &&
    isTRUE(all(selected_macro_cols %in% macro_cols)) &&
    isTRUE(!(stock_name %in% selected_macro_cols))
  
  if (!isTRUE(bs_consistency_ok)) {
    cat(">> [BEST SUBSET] GAGAL: hasil Best Subset Selection untuk", stock_name,
        "TIDAK memenuhi konsistensi minimum (>=4 variabel, JCI Index wajib, mandatory sektor",
        "wajib, seluruh variabel terpilih terdapat pada model_df & macro_cols, tanpa duplikasi,",
        "dependent variable tidak ikut terpilih) - MS-AR TIDAK dijalankan untuk saham ini.\n")
    bs_fail_excel_path2 <- file.path(output_dir, paste0("Output_MarkovRegimeSwitching_", stock_tag, ".xlsx"))
    openxlsx::saveWorkbook(wb, bs_fail_excel_path2, overwrite = TRUE)
    return(list(
      excel_path          = bs_fail_excel_path2,
      summary_path        = NA,
      best_k              = NA,
      final_fit           = NULL,
      best_subset         = best_subset_result,
      selected_variables  = character(0),
      sector_classification = sector_map_result$sector,
      status              = "GAGAL - hasil Best Subset Selection tidak konsisten"
    ))
  }
  
  
  cat("\n>> [MS-AR] Tahap identifikasi orde AR (Box-Jenkins): plot ACF/PACF return", stock_name, "...\n")
  acf_pacf_ret <- plot_acf_pacf(model_df[[stock_name]], paste0(stock_name, "_Return"), plots_dir, max_lag = 20)
  
  openxlsx::addWorksheet(wb, "ACF PACF Return")
  openxlsx::writeData(wb, "ACF PACF Return",
                      data.frame(Catatan = paste0("Plot ACF & PACF return ", stock_name, " tersimpan pada folder ",
                                                  "Plots (PNG & PDF resolusi tinggi) - identifikasi awal orde AR ",
                                                  "mengikuti prosedur Box-Jenkins (Box, Jenkins, Reinsel & Ljung, 2015).")))
  openxlsx::writeData(wb, "ACF PACF Return", acf_pacf_ret$acf_df, startRow = 3)
  openxlsx::writeData(wb, "ACF PACF Return", acf_pacf_ret$pacf_df, startRow = nrow(acf_pacf_ret$acf_df) + 6)
  
  build_ms_ar_dataset <- function(base_df, p) {
    df_p <- base_df
    lag_cols_p <- character(0)
    if (p > 0) {
      for (lag_i in 1:p) {
        lag_name <- paste0("L", lag_i, "_Return")
        df_p[[lag_name]] <- c(rep(NA_real_, lag_i), utils::head(df_p[[stock_name]], -lag_i))
        lag_cols_p <- c(lag_cols_p, lag_name)
      }
      valid_rows_p <- stats::complete.cases(df_p[, c(stock_name, selected_macro_cols, lag_cols_p), drop = FALSE])
      df_p <- df_p[valid_rows_p, ]
      rownames(df_p) <- NULL
    }
    
    rhs_p <- c(lag_cols_p, selected_macro_cols)
    formula_p <- as.formula(paste0("`", stock_name, "` ~ ", paste0("`", rhs_p, "`", collapse = " + ")))
    
    X_macro_p <- df_p[, selected_macro_cols, drop = FALSE]
    means_p <- colMeans(X_macro_p, na.rm = TRUE)
    sds_p   <- apply(X_macro_p, 2, sd, na.rm = TRUE)
    sds_p[sds_p == 0 | !is.finite(sds_p)] <- 1
    
    df_p_mle <- df_p
    df_p_mle[, selected_macro_cols] <- scale(X_macro_p, center = means_p, scale = sds_p)
    
    lm_p <- lm(formula_p, data = df_p_mle)
    
    list(model_df = df_p, model_df_mle = df_p_mle, lag_cols = lag_cols_p,
         formula = formula_p, base_lm = lm_p, n_params = length(coef(lm_p)),
         scaling_params = list(means = means_p, sds = sds_p))
  }
  
  cat(">> [MS-AR] Memilih orde AR (p) secara OBJEKTIF via BIC pada model Markov Switching",
      "(kandidat p = 0,1,2,3; regime baseline k = 2 - Hamilton 1994, Krolzig 1997,",
      "Psaradakis & Spagnolo 2003)...\n")
  
  AR_ORDER_CANDIDATES <- c(1, 2, 3, 4, 5)
  AR_K_BASELINE <- 2
  ar_order_table <- data.frame()
  ar_dataset_store <- list()
  
  for (p_cand in AR_ORDER_CANDIDATES) {
    ds_p <- build_ms_ar_dataset(model_df, p_cand)
    ar_dataset_store[[as.character(p_cand)]] <- ds_p
    
    fit_p <- tryCatch(
      fit_direct_mle(AR_K_BASELINE, ds_p$base_lm, ds_p$model_df, stock_name,
                     n_starts = n_starts, compute_hessian = FALSE, screening_mode = "fast_screening"),
      error = function(e) NULL
    )
    
    if (!is.null(fit_p) && is.finite(fit_p$logLik)) {
      n_obs_p <- nrow(ds_p$model_df)
      n_est_params_p <- (ds_p$n_params + 1) * AR_K_BASELINE + AR_K_BASELINE * (AR_K_BASELINE - 1)
      ll_p   <- fit_p$logLik
      aic_p  <- -2 * ll_p + 2 * n_est_params_p
      bic_p  <- -2 * ll_p + n_est_params_p * log(n_obs_p)
      hqic_p <- -2 * ll_p + 2 * n_est_params_p * log(log(n_obs_p))
      ar_order_table <- rbind(ar_order_table, data.frame(
        AR_Order = p_cand, N_Obs = n_obs_p, N_Param_Regresi = ds_p$n_params,
        N_Param_Total = n_est_params_p, LogLikelihood = ll_p, AIC = aic_p,
        HQIC = hqic_p, BIC = bic_p, Convergence = fit_p$convergence,
        Status = "Berhasil", stringsAsFactors = FALSE
      ))
    } else {
      ar_order_table <- rbind(ar_order_table, data.frame(
        AR_Order = p_cand, N_Obs = nrow(ds_p$model_df), N_Param_Regresi = ds_p$n_params,
        N_Param_Total = NA, LogLikelihood = NA, AIC = NA, HQIC = NA, BIC = NA,
        Convergence = NA, Status = "Gagal Konvergen", stringsAsFactors = FALSE
      ))
    }
  }
  
  valid_ar <- ar_order_table[ar_order_table$Status == "Berhasil" & !is.na(ar_order_table$BIC), ]
  if (nrow(valid_ar) == 0) {
    cat(">> PERINGATAN: Seluruh kandidat orde AR GAGAL konvergen - fallback ke p = 0",
        "(model MS tanpa komponen autoregressive, setara spesifikasi MRSR sebelumnya).\n")
    best_p <- 0
  } else {
    best_p <- valid_ar$AR_Order[which.min(valid_ar$BIC)]
  }
  ar_order_table$Terpilih <- ifelse(ar_order_table$AR_Order == best_p, "TERPILIH (BIC terkecil)", "")
  
  cat(">> [MS-AR] Orde AR TERPILIH: p =", best_p,
      if (nrow(valid_ar) > 0) paste0("(BIC = ", round(min(valid_ar$BIC), 3), ")") else "(fallback)", "\n")
  print(ar_order_table)
  
  openxlsx::addWorksheet(wb, "AR Order Selection")
  openxlsx::writeData(wb, "AR Order Selection", ar_order_table)
  openxlsx::writeData(wb, "AR Order Selection", data.frame(
    Catatan = paste0("Orde AR (p) dipilih berdasarkan BIC TERKECIL pada estimasi model Markov Switching ",
                     "k = ", AR_K_BASELINE, " regime (baseline) untuk kandidat p = 0,1,2,3, mengikuti Hamilton ",
                     "(1994), Krolzig (1997), Psaradakis & Spagnolo (2003), Franses & van Dijk (2000). Model ",
                     "regime ditetapkan k = 2 (2-state) dan digunakan langsung pada tahap estimasi berikutnya ",
                     "dengan spesifikasi MS-AR orde p = ", best_p, " ini.")),
    startRow = nrow(ar_order_table) + 3)
  
  ms_ar_final_dataset <- ar_dataset_store[[as.character(best_p)]]
  model_df       <- ms_ar_final_dataset$model_df
  model_df_mle   <- ms_ar_final_dataset$model_df_mle
  lag_cols       <- ms_ar_final_dataset$lag_cols
  ar_order_p     <- best_p
  scaling_params <- ms_ar_final_dataset$scaling_params
  base_formula   <- ms_ar_final_dataset$formula
  base_lm        <- ms_ar_final_dataset$base_lm
  n_params       <- ms_ar_final_dataset$n_params
  
  cat(">> [MS-AR] Dataset final dibentuk dengan p =", ar_order_p, "-", length(lag_cols), "variabel lag AR",
      "ditambah", length(selected_macro_cols), "variabel makro TERPILIH (dari", length(macro_cols),
      "candidate, hasil constrained Best Subset Selection). Observasi efektif:", nrow(model_df), "\n")
  
  stock_valid_daily5d_idx <- which(!is.na(raw_data[[stock_name]]))
  if (length(stock_valid_daily5d_idx) == 0) {
    stop("Saham ", stock_name, ": tidak ditemukan satu pun observasi 5-hari valid ",
         "(harga selalu NA) - saham dilewati (skipped).")
  }
  listing_start_date <- raw_data[[date_col]][min(stock_valid_daily5d_idx)]
  sample_start_date  <- min(log_return_df$Dates)
  sample_end_date    <- max(model_df$Dates)
  n_obs_5d            <- nrow(model_df)
  
  if (n_obs_5d <= n_params) {
    stop("Saham ", stock_name, ": observasi 5-hari pasca listing/trimming lag AR (p = ",
         ar_order_p, ") hanya berjumlah ", n_obs_5d, " - TIDAK CUKUP untuk mengestimasi ",
         n_params, " parameter regresi. Saham dilewati (skipped) - pertimbangkan memakai ",
         "orde AR lebih rendah atau menunggu histori data lebih panjang.")
  }
  
  stock_5d_metadata <- list(
    stock_name              = stock_name,
    frequency                = "5-trading-day non-overlapping",
    aggregation_method        = "last-observation-of-block (level/price)",
    listing_start_date        = listing_start_date,
    sample_start_date         = sample_start_date,
    sample_end_date           = sample_end_date,
    n_obs_5d                  = n_obs_5d,
    ar_order                  = ar_order_p
  )
  
  cat(">> [5-HARI/LISTING]", stock_name, "- First valid 5-day observation :", as.character(listing_start_date), "\n")
  cat(">> [5-HARI/LISTING]", stock_name, "- Last valid observation        :", as.character(sample_end_date), "\n")
  cat(">> [5-HARI/LISTING]", stock_name, "- N 5-day observations (est.)   :", n_obs_5d, "\n")
  cat(">> [5-HARI/LISTING]", stock_name, "- AR order (p)                  :", ar_order_p, "\n")
  cat(">> [5-HARI/LISTING]", stock_name, "- N observations used for estimation:", n_obs_5d, "\n\n")
  
  openxlsx::writeData(wb, "Preprocessing",
                      data.frame(
                        Tahapan = c("Frequency", "Aggregation Method", "Listing Start Date (first valid 5-day obs)",
                                    "Sample Start Date (return valid, pra lag AR)", "Sample End Date (estimation, pasca lag AR)",
                                    "N Obs 5-day (estimation)", "AR Order (p)"),
                        Nilai = c(stock_5d_metadata$frequency, stock_5d_metadata$aggregation_method,
                                  as.character(stock_5d_metadata$listing_start_date),
                                  as.character(stock_5d_metadata$sample_start_date),
                                  as.character(stock_5d_metadata$sample_end_date),
                                  stock_5d_metadata$n_obs_5d, stock_5d_metadata$ar_order)
                      ),
                      startRow = nrow(preprocessing_summary) + nrow(missing_summary) + 8)
  
  cat(">> Mengestimasi model dengan regime k = 2 (2-state, Direct Maximum Likelihood - BFGS)...\n")
  
  fit_2state <- fit_direct_mle(2, base_lm, model_df, stock_name, n_starts = n_starts, compute_hessian = FALSE)
  
  extract_ic <- function(fit, k) {
    if (is.null(fit)) {
      return(data.frame(Regime = paste0(k, "-State"), LogLikelihood = NA, AIC = NA, BIC = NA, HQIC = NA, Status = "Gagal Konvergen"))
    }
    ll <- fit$logLik
    n_obs <- nrow(model_df)
    n_est_params <- (n_params + 1) * k + k * (k - 1)
    aic  <- -2 * ll + 2 * n_est_params
    bic  <- -2 * ll + n_est_params * log(n_obs)
    hqic <- -2 * ll + 2 * n_est_params * log(log(n_obs))
    status <- if (fit$convergence == 0) "Konvergen" else paste0("convergence code = ", fit$convergence, " (periksa kembali)")
    data.frame(Regime = paste0(k, "-State"), LogLikelihood = ll, AIC = aic, BIC = bic,
               HQIC = hqic, Status = status)
  }
  
  model_comparison <- extract_ic(fit_2state, 2)
  
  openxlsx::addWorksheet(wb, "Model Selection")
  openxlsx::writeData(wb, "Model Selection", model_comparison)
  
  cat(">> Ringkasan model:\n")
  print(model_comparison)
  
  valid_models <- model_comparison[!is.na(model_comparison$BIC), ]
  if (nrow(valid_models) == 0) {
    stop("Model 2-state gagal konvergen. Periksa kembali data input.")
  }
  best_row <- valid_models[1, ]
  best_k <- 2
  best_fit <- fit_2state
  
  openxlsx::writeData(wb, "Model Selection",
                      data.frame(Keputusan = paste0("Model langsung ditetapkan sebagai regime k = 2 (2-state), tanpa ",
                                                    "membandingkan dengan model 3-state. ", best_row$Regime,
                                                    " (BIC = ", round(best_row$BIC, 3), ", AIC = ", round(best_row$AIC, 3), ")")),
                      startRow = nrow(model_comparison) + 3)
  
  cat(">> MODEL TERPILIH:", best_row$Regime, "(langsung ditetapkan k = 2, tanpa perbandingan dengan 3-state)\n")
  
  final_fit_gaussian <- best_fit
  
  unstandardize_ms_fit <- function(fit_obj, scaling_params, macro_cols) {
    if (is.null(fit_obj) || is.null(scaling_params)) return(fit_obj)
    
    p  <- fit_obj$n_params
    kk <- fit_obj$k
    
    A <- diag(p)
    coef_names_fo <- fit_obj$coef_names
    coef_names_clean <- gsub("^`|`$", "", coef_names_fo)
    macro_positions <- match(macro_cols, coef_names_clean)
    if (anyNA(macro_positions)) {
      stop("unstandardize_ms_fit(): tidak seluruh macro_cols ditemukan pada coef_names fit_obj - ",
           "periksa kesesuaian formula MS-AR (build_ms_ar_dataset) dengan scaling_params.")
    }
    A[1, macro_positions] <- -scaling_params$means / scaling_params$sds
    for (i in seq_along(macro_cols)) {
      A[macro_positions[i], macro_positions[i]] <- 1 / scaling_params$sds[i]
    }
    
    beta_orig <- A %*% fit_obj$beta_mat
    
    N <- nrow(fit_obj$vcov_mat)
    Tmat <- diag(N)
    for (i in 1:kk) {
      rows <- ((i - 1) * p + 1):(i * p)
      Tmat[rows, rows] <- A
    }
    vcov_orig     <- Tmat %*% fit_obj$vcov_mat %*% t(Tmat)
    se_theta_orig <- suppressWarnings(sqrt(diag(vcov_orig)))
    
    se_beta_orig <- matrix(NA_real_, nrow = p, ncol = kk)
    idx <- 1
    for (i in 1:kk) {
      se_beta_orig[, i] <- se_theta_orig[idx:(idx + p - 1)]
      idx <- idx + p
    }
    
    rownames(beta_orig)    <- fit_obj$coef_names
    colnames(beta_orig)    <- paste0("Regime_", 1:kk)
    rownames(se_beta_orig) <- fit_obj$coef_names
    colnames(se_beta_orig) <- paste0("Regime_", 1:kk)
    
    fit_obj$beta_mat <- beta_orig
    fit_obj$se_beta  <- se_beta_orig
    fit_obj$vcov_mat <- vcov_orig
    fit_obj
  }
  
  final_fit_gaussian <- unstandardize_ms_fit(final_fit_gaussian, scaling_params, selected_macro_cols)
  cat(">> [REFACTOR] Koefisien, SE, dan Vcov model Gaussian dikembalikan ke skala asli.\n")
  
  final_fit <- final_fit_gaussian
  
  cat("\n>> [MODEL SELECTION] Mengestimasi Markov Switching dengan densitas Student-t",
      "(k =", best_k, "regime) sebagai pembanding terhadap Gaussian, untuk pemilihan",
      "model final berbasis kriteria informasi (BIC utama)...\n")
  
  if (isTRUE(use_student_t_full_mle)) {
    fit_t <- tryCatch(fit_direct_mle_t(best_k, base_lm, model_df, stock_name, n_starts = n_starts, compute_hessian = FALSE),
                      error = function(e) {
                        cat(">> PERINGATAN: Estimasi Student-t Markov Switching gagal dieksekusi:",
                            conditionMessage(e), "\n")
                        NULL
                      })
    final_fit_studentt <- unstandardize_ms_fit(fit_t, scaling_params, selected_macro_cols)
    fit_t <- final_fit_studentt
    cat(">> [REFACTOR] Koefisien, SE, dan Vcov model Student-t dikembalikan ke skala asli.\n")
  } else {
    cat(">> [PERFORMA] use_student_t_full_mle = FALSE - estimasi Student-t MLE PENUH DILEWATI.",
        "Gaussian dipakai sebagai estimator utama; nu heavy-tail diestimasi POST-HOC",
        "setelah model final terpilih (lih. Bagian 5.9E-2).\n")
    fit_t <- NULL
    final_fit_studentt <- NULL
  }
  
  n_est_params_gaussian <- (n_params + 1) * best_k + best_k * (best_k - 1)
  gaussian_ll   <- final_fit_gaussian$logLik
  gaussian_aic  <- -2 * gaussian_ll + 2 * n_est_params_gaussian
  gaussian_bic  <- -2 * gaussian_ll + n_est_params_gaussian * log(nrow(model_df))
  gaussian_hqic <- -2 * gaussian_ll + 2 * n_est_params_gaussian * log(log(nrow(model_df)))
  
  model_selection_table <- data.frame(
    Model = "Gaussian", LogLikelihood = round(gaussian_ll, 4), AIC = round(gaussian_aic, 3),
    BIC = round(gaussian_bic, 3), HQIC = round(gaussian_hqic, 3),
    N_Param = n_est_params_gaussian, Status = "Tersedia", stringsAsFactors = FALSE
  )
  
  if (!is.null(fit_t)) {
    n_est_params_studentt <- n_est_params_gaussian + best_k
    studentt_ll   <- fit_t$logLik
    studentt_aic  <- -2 * studentt_ll + 2 * n_est_params_studentt
    studentt_bic  <- -2 * studentt_ll + n_est_params_studentt * log(nrow(model_df))
    studentt_hqic <- -2 * studentt_ll + 2 * n_est_params_studentt * log(log(nrow(model_df)))
    
    model_selection_table <- rbind(model_selection_table, data.frame(
      Model = "Student-t", LogLikelihood = round(studentt_ll, 4), AIC = round(studentt_aic, 3),
      BIC = round(studentt_bic, 3), HQIC = round(studentt_hqic, 3),
      N_Param = n_est_params_studentt, Status = "Tersedia", stringsAsFactors = FALSE
    ))
  } else {
    status_msg_t <- if (!isTRUE(use_student_t_full_mle)) {
      "Dinonaktifkan (use_student_t_full_mle = FALSE) - Gaussian dipakai sebagai estimator utama; nu diestimasi post-hoc"
    } else {
      "Estimasi Gagal - Gaussian dipakai sebagai model final"
    }
    model_selection_table <- rbind(model_selection_table, data.frame(
      Model = "Student-t", LogLikelihood = NA, AIC = NA, BIC = NA, HQIC = NA,
      N_Param = NA, Status = status_msg_t,
      stringsAsFactors = FALSE
    ))
  }
  
  valid_candidates <- model_selection_table[model_selection_table$Status == "Tersedia" &
                                              !is.na(model_selection_table$BIC), ]
  best_model_name <- valid_candidates$Model[which.min(valid_candidates$BIC)]
  model_selection_table$Terpilih <- ifelse(model_selection_table$Model == best_model_name, "YA (Model Final)", "")
  
  cat(">> Model Selection (BIC sebagai kriteria utama):\n")
  print(model_selection_table)
  cat(">> MODEL FINAL TERPILIH:", best_model_name, "(BIC =",
      round(min(valid_candidates$BIC), 3), ")\n")
  
  cat("\n>> [EFISIENSI - HESSIAN] Menghitung ulang HANYA model final terpilih (",
      best_model_name, ", k =", best_k, ") dengan compute_hessian = TRUE",
      "(numDeriv::hessian()/nearPD() SATU KALI per saham)...\n")
  
  if (best_model_name == "Student-t") {
    fit_t_final <- tryCatch(
      fit_direct_mle_t(best_k, base_lm, model_df, stock_name, n_starts = n_starts, compute_hessian = TRUE),
      error = function(e) {
        cat(">> PERINGATAN: Estimasi ulang Student-t (final, dengan Hessian) gagal:",
            conditionMessage(e), "- fallback ke kandidat tanpa SE.\n")
        NULL
      }
    )
    if (!is.null(fit_t_final)) {
      final_fit_studentt <- unstandardize_ms_fit(fit_t_final, scaling_params, selected_macro_cols)
      fit_t <- final_fit_studentt
    }
  } else {
    fit_gaussian_final <- tryCatch(
      fit_direct_mle(best_k, base_lm, model_df, stock_name, n_starts = n_starts, compute_hessian = TRUE),
      error = function(e) {
        cat(">> PERINGATAN: Estimasi ulang Gaussian (final, dengan Hessian) gagal:",
            conditionMessage(e), "- fallback ke kandidat tanpa SE.\n")
        NULL
      }
    )
    if (!is.null(fit_gaussian_final)) {
      final_fit_gaussian <- unstandardize_ms_fit(fit_gaussian_final, scaling_params, selected_macro_cols)
    }
  }
  cat(">> [EFISIENSI - HESSIAN] Estimasi ulang model final selesai - SE, vcov, dan Wald test",
      "kini tersedia HANYA untuk model final terpilih.\n")
  
  final_fit <- if (best_model_name == "Student-t") final_fit_studentt else final_fit_gaussian
  final_fit_distribution <- best_model_name
  
  final_fit$ar_order <- ar_order_p
  final_fit$lag_cols <- lag_cols
  
  last_actual_lags_val <- NULL
  if (ar_order_p > 0) {
    actual_ret_series <- model_df[[stock_name]]
    last_actual_lags_val <- stats::setNames(
      rev(utils::tail(actual_ret_series, ar_order_p)),
      lag_cols
    )
  }
  final_fit$last_actual_lags <- last_actual_lags_val
  
  last_date_used <- suppressWarnings(max(model_df$Dates, na.rm = TRUE))
  final_fit$last_actual_date <- last_date_used
  final_fit$yesterday_close_price <- tryCatch({
    idx_close <- which(raw_data[[date_col]] == last_date_used)
    if (length(idx_close) >= 1 && stock_name %in% names(raw_data)) {
      as.numeric(raw_data[[stock_name]][idx_close[1]])
    } else {
      NA_real_
    }
  }, error = function(e) NA_real_)
  
  cat(">> [MC KOMPATIBILITAS] final_fit dilengkapi: ar_order =", final_fit$ar_order,
      "| Yesterday_Close_Price =", final_fit$yesterday_close_price,
      "| basis tanggal =", as.character(final_fit$last_actual_date), "\n")
  
  openxlsx::addWorksheet(wb, "Model Selection (Gauss vs T)")
  openxlsx::writeData(wb, "Model Selection (Gauss vs T)", model_selection_table)
  openxlsx::writeData(wb, "Model Selection (Gauss vs T)",
                      data.frame(Catatan = paste0(
                        "Model dipilih berdasarkan BIC terkecil (kriteria utama, Schwarz 1978), ",
                        "didukung AIC/HQIC/Log-Likelihood. Model TERPILIH (", best_model_name,
                        ") menjadi SATU-SATUNYA sumber (single source of truth) bagi SELURUH tabel, ",
                        "visualisasi, dan interpretasi pada file Excel ini - termasuk sheet 'Estimated ",
                        "Parameters', 'Transition Matrix', 'Filtered Probability', 'Regime ",
                        "Classification', dan seluruh sheet turunan lainnya pada Bagian 5.9.")),
                      startRow = nrow(model_selection_table) + 3)
  
  if (!is.null(fit_t)) {
    lr_stat_t <- 2 * (studentt_ll - gaussian_ll)
    lr_df_t <- best_k
    lr_pvalue_t <- 1 - pchisq(lr_stat_t, df = lr_df_t)
    
    t_vs_gaussian_comparison <- data.frame(
      Kriteria = c("Log-Likelihood", "AIC", "BIC", "HQIC", "Jumlah Parameter",
                   "LR Statistic (vs Gaussian, indikatif)", "LR df", "LR p-value (indikatif)"),
      Gaussian = c(round(gaussian_ll, 4), round(gaussian_aic, 3), round(gaussian_bic, 3),
                   round(gaussian_hqic, 3), n_est_params_gaussian, NA, NA, NA),
      Student_t = c(round(studentt_ll, 4), round(studentt_aic, 3), round(studentt_bic, 3),
                    round(studentt_hqic, 3), n_est_params_studentt, round(lr_stat_t, 4), lr_df_t,
                    signif(lr_pvalue_t, 4))
    )
    cat(">> CATATAN METODOLOGIS: LR test bersifat indikatif (nu->infinity berada pada batas",
        "ruang parameter - Self & Liang, 1987); keputusan model final tetap mengacu BIC.\n")
    
    X_full_early <- model.matrix(base_formula, data = model_df)
    coef_names_t <- fit_t$coef_names
    coef_names_t <- gsub("^L([0-9]+)_Return$", "AR(\\1)", coef_names_t)
    t_coef_table <- data.frame()
    for (i in 1:best_k) {
      for (j in seq_along(coef_names_t)) {
        b  <- fit_t$beta_mat[j, i]; se <- fit_t$se_beta[j, i]
        z <- if (!is.na(se) && se > 0) b / se else NA
        pval <- if (!is.na(z)) 2 * (1 - pnorm(abs(z))) else NA
        t_coef_table <- rbind(t_coef_table, data.frame(
          Regime = paste0("Regime_", i), Parameter = coef_names_t[j], Estimate = b, Std_Error = se,
          Z_Statistic = z, p_value = pval, CI_Lower_95 = b - 1.96 * se, CI_Upper_95 = b + 1.96 * se
        ))
      }
      t_coef_table <- rbind(t_coef_table, data.frame(
        Regime = paste0("Regime_", i), Parameter = "Sigma", Estimate = fit_t$sigma_vec[i],
        Std_Error = fit_t$se_sigma[i], Z_Statistic = NA, p_value = NA, CI_Lower_95 = NA, CI_Upper_95 = NA
      ))
      t_coef_table <- rbind(t_coef_table, data.frame(
        Regime = paste0("Regime_", i), Parameter = "Nu (derajat kebebasan)", Estimate = fit_t$nu_vec[i],
        Std_Error = fit_t$se_nu[i], Z_Statistic = NA, p_value = NA,
        CI_Lower_95 = fit_t$nu_vec[i] - 1.96 * fit_t$se_nu[i], CI_Upper_95 = fit_t$nu_vec[i] + 1.96 * fit_t$se_nu[i]
      ))
    }
    
    fitted_by_regime_t <- sapply(1:best_k, function(r) as.numeric(X_full_early %*% fit_t$beta_mat[, r]))
    cls_gaussian <- classify_regimes_by_sigma(final_fit_gaussian$smo_prob, final_fit_gaussian$sigma_vec, best_k)
    cls_studentt <- classify_regimes_by_sigma(fit_t$smo_prob, fit_t$sigma_vec, best_k)
    regime_class_t <- cls_studentt$regime_class
    
    resid_t <- model_df[[stock_name]] - sapply(seq_along(regime_class_t), function(t) fitted_by_regime_t[t, regime_class_t[t]])
    std_resid_t <- ave(resid_t, regime_class_t, FUN = function(x) (x - mean(x)) / sd(x))
    normality_per_regime_t <- do.call(rbind, lapply(1:best_k, function(i) {
      normality_summary_one(std_resid_t[regime_class_t == i], paste0("Regime_", i, "_StudentT"))
    }))
    
    classification_agreement_pct <- mean(cls_gaussian$regime_label == cls_studentt$regime_label) * 100
    cat(">> Kesesuaian klasifikasi regime (Gaussian vs Student-t, berdasarkan label Bull/Bear):",
        round(classification_agreement_pct, 2), "%\n")
    
    t_model_summary <- data.frame(
      Item = c("Jumlah Regime", "Metode Estimasi", "Densitas Emisi", "Convergence Code",
               "Status Hessian", "Log-Likelihood", "AIC", "BIC", "HQIC",
               "Kesesuaian Klasifikasi Regime vs Gaussian (%)", "Terpilih Sebagai Model Final"),
      Nilai = c(best_k, "Direct Maximum Likelihood (BFGS, multi-start)", "Student-t (heavy-tailed)",
                fit_t$convergence, ifelse(fit_t$hessian_ok, "Positive Definite", "TIDAK Positive Definite"),
                round(studentt_ll, 4), round(studentt_aic, 3), round(studentt_bic, 3), round(studentt_hqic, 3),
                round(classification_agreement_pct, 2), ifelse(best_model_name == "Student-t", "YA", "TIDAK"))
    )
    
    openxlsx::addWorksheet(wb, "StudentT MS Summary")
    openxlsx::writeData(wb, "StudentT MS Summary", t_model_summary)
    openxlsx::addWorksheet(wb, "StudentT vs Gaussian")
    openxlsx::writeData(wb, "StudentT vs Gaussian", t_vs_gaussian_comparison)
    openxlsx::addWorksheet(wb, "StudentT Coefficients")
    openxlsx::writeData(wb, "StudentT Coefficients", t_coef_table)
    openxlsx::addWorksheet(wb, "StudentT Residual Normality")
    openxlsx::writeData(wb, "StudentT Residual Normality", normality_per_regime_t)
    openxlsx::writeData(wb, "StudentT Residual Normality",
                        data.frame(Catatan = "Bandingkan dengan sheet 'Residual Diagnostics per Regime' (yang memakai model FINAL terpilih) untuk menilai kesesuaian normalitas residual."),
                        startRow = nrow(normality_per_regime_t) + 3)
    
    cat(">> Perbandingan Gaussian vs Student-t selesai. Model final yang dipakai SELURUH",
        "pipeline berikutnya:", best_model_name, "\n")
  } else {
    catatan_t <- if (!isTRUE(use_student_t_full_mle)) {
      paste0("Estimasi Student-t Markov Switching PENUH (fit_direct_mle_t) DINONAKTIFKAN pada ",
             "konfigurasi refactor performa saat ini (use_student_t_full_mle = FALSE) - Gaussian ",
             "Maximum Likelihood (fit_direct_mle) dipakai sebagai estimator UTAMA untuk seluruh ",
             "saham. Sebagai gantinya, derajat kebebasan (nu) heavy-tail diestimasi secara ",
             "POST-HOC (setelah model Gaussian final diperoleh) melalui MASS::fitdistr() pada ",
             "standardized residual per regime - lihat sheet 'PostHoc Student-t Nu'. Estimasi nu ",
             "ini BERSIFAT INFORMATIF SAJA (indikasi tingkat heavy-tail residual) dan TIDAK ",
             "memengaruhi likelihood, BIC, klasifikasi regime, maupun parameter Gaussian manapun. ",
             "Fungsi fit_direct_mle_t() TETAP tersedia utuh pada script dan dapat diaktifkan ",
             "kembali dengan run_pipeline(..., use_student_t_full_mle = TRUE).")
    } else {
      paste0("Model pembanding Student-t Markov Switching TIDAK tersedia untuk saham ini - ",
             "seluruh multi-start optimisasi gagal konvergen (lihat log console). Model ",
             "final yang dipakai adalah Gaussian (satu-satunya model yang berhasil diestimasi).")
    }
    openxlsx::addWorksheet(wb, "StudentT MS Summary")
    openxlsx::writeData(wb, "StudentT MS Summary", data.frame(Catatan = catatan_t))
  }
  
  coef_names <- final_fit$coef_names
  coef_names <- gsub("^L([0-9]+)_Return$", "AR(\\1)", coef_names)
  
  coef_df <- as.data.frame(t(final_fit$beta_mat))
  colnames(coef_df) <- coef_names
  coef_df$Sigma <- final_fit$sigma_vec
  if (!is.null(final_fit$nu_vec)) coef_df$Nu <- final_fit$nu_vec
  coef_df <- tibble::rownames_to_column(coef_df, "RegimeIndex")
  coef_df$Regime <- paste0("Regime_", coef_df$RegimeIndex)
  extra_cols <- if (!is.null(final_fit$nu_vec)) c("Sigma", "Nu") else "Sigma"
  coef_df <- coef_df[, c("Regime", coef_names, extra_cols)]
  
  se_df <- as.data.frame(t(final_fit$se_beta))
  colnames(se_df) <- coef_names
  se_df$Sigma <- final_fit$se_sigma
  if (!is.null(final_fit$se_nu)) se_df$Nu <- final_fit$se_nu
  
  ar_stationarity_table <- data.frame()
  if (ar_order_p > 0) {
    ar_row_idx <- match(lag_cols, final_fit$coef_names)
    for (i in 1:best_k) {
      phi_i <- final_fit$beta_mat[ar_row_idx, i]
      names(phi_i) <- lag_cols
      
      char_poly <- c(1, -phi_i)
      roots_i <- tryCatch(polyroot(char_poly), error = function(e) NA_complex_)
      min_mod_root <- if (all(!is.na(roots_i))) min(Mod(roots_i)) else NA_real_
      is_stationary <- if (!is.na(min_mod_root)) min_mod_root > 1 else NA
      
      persistence_i <- sum(phi_i)
      
      row_i <- data.frame(
        Regime = paste0("Regime_", i),
        stringsAsFactors = FALSE
      )
      for (l in seq_along(phi_i)) {
        row_i[[paste0("Phi_AR(", l, ")")]] <- unname(phi_i[l])
      }
      row_i$Persistence_SumPhi <- persistence_i
      row_i$Min_Modulus_Akar_Karakteristik <- min_mod_root
      row_i$Status_Stasioner <- ifelse(is.na(is_stationary), "Tidak dapat dihitung",
                                       ifelse(is_stationary, "STASIONER (seluruh akar di luar unit circle)",
                                              "TIDAK STASIONER (terdapat akar di dalam/pada unit circle)"))
      ar_stationarity_table <- rbind(ar_stationarity_table, row_i)
    }
    
    cat(">> [MS-AR] Diagnostik stasioneritas AR per regime (akar karakteristik):\n")
    print(ar_stationarity_table[, c("Regime", "Persistence_SumPhi", "Status_Stasioner")])
    
    openxlsx::addWorksheet(wb, "AR Stationarity Diagnostics")
    openxlsx::writeData(wb, "AR Stationarity Diagnostics", ar_stationarity_table)
    openxlsx::writeData(wb, "AR Stationarity Diagnostics", data.frame(
      Catatan = paste0("Stasioneritas dites via akar polinomial karakteristik 1 - phi_1*z - ... - phi_p*z^p = 0 ",
                       "(Hamilton, 1994; Tsay, 2010) - regime STASIONER apabila SELURUH akar berada DI LUAR ",
                       "unit circle (modulus > 1). Persistence_SumPhi (jumlah koefisien AR) adalah ukuran ",
                       "deskriptif tambahan (BUKAN kriteria formal) - nilai mendekati 1 mengindikasikan ",
                       "dinamika return yang sangat persisten pada regime tersebut.")),
      startRow = nrow(ar_stationarity_table) + 3)
  } else {
    openxlsx::addWorksheet(wb, "AR Stationarity Diagnostics")
    openxlsx::writeData(wb, "AR Stationarity Diagnostics", data.frame(
      Catatan = "Orde AR terpilih p = 0 (lih. sheet 'AR Order Selection') - model setara MRSR tanpa komponen autoregressive, diagnostik stasioneritas AR tidak berlaku."))
  }
  
  trans_mat <- final_fit$trans_mat
  filt_prob <- final_fit$filt_prob
  smo_prob  <- final_fit$smo_prob
  final_ll  <- final_fit$logLik
  
  openxlsx::addWorksheet(wb, "Estimated Parameters")
  openxlsx::writeData(wb, "Estimated Parameters", coef_df)
  openxlsx::writeData(wb, "Estimated Parameters", data.frame(Catatan = "Standard Error (dari inverse Hessian, Direct Maximum Likelihood):"),
                      startRow = nrow(coef_df) + 3)
  openxlsx::writeData(wb, "Estimated Parameters", se_df, startRow = nrow(coef_df) + 4)
  
  trans_display <- t(trans_mat)
  trans_df <- as.data.frame(trans_display)
  colnames(trans_df) <- paste0("To_State_", 1:ncol(trans_df))
  trans_df <- tibble::rownames_to_column(trans_df, "From_State")
  
  diag_p <- diag(as.matrix(trans_mat))
  exp_dur <- expected_duration(diag_p)
  duration_df <- data.frame(State = paste0("State_", 1:length(diag_p)),
                            Persistence_Prob = diag_p,
                            Expected_Duration_Days = exp_dur)
  
  openxlsx::addWorksheet(wb, "Transition Matrix")
  openxlsx::writeData(wb, "Transition Matrix", trans_df)
  openxlsx::writeData(wb, "Transition Matrix", duration_df, startRow = nrow(trans_df) + 4)
  
  filt_df <- as.data.frame(filt_prob)
  colnames(filt_df) <- paste0("Filtered_Prob_State", 1:ncol(filt_df))
  filt_df <- cbind(Dates = model_df$Dates, filt_df)
  
  openxlsx::addWorksheet(wb, "Filtered Probability")
  openxlsx::writeData(wb, "Filtered Probability", filt_df)
  
  cls_result <- classify_regimes_by_sigma(smo_prob, final_fit$sigma_vec, best_k)
  regime_class <- cls_result$regime_class
  regime_label <- cls_result$regime_label
  label_map    <- cls_result$label_map
  
  class_df <- data.frame(
    Dates = model_df$Dates,
    Regime_Number = regime_class,
    Regime_Label  = regime_label
  )
  
  openxlsx::addWorksheet(wb, "Regime Classification")
  openxlsx::writeData(wb, "Regime Classification", class_df)
  
  cat(">> Estimasi akhir (Direct MLE - BFGS), Hamilton Filter & Kim Smoother selesai. Log-Likelihood =", final_ll, "\n")
  
  n_obs_model <- nrow(model_df)
  n_est_params_final <- (n_params + 1) * best_k + best_k * (best_k - 1) +
    ifelse(!is.null(final_fit$nu_vec), best_k, 0)
  final_aic  <- -2 * final_ll + 2 * n_est_params_final
  final_bic  <- -2 * final_ll + n_est_params_final * log(n_obs_model)
  final_hqic <- -2 * final_ll + 2 * n_est_params_final * log(log(n_obs_model))
  
  convergence_status <- if (final_fit$convergence == 0) {
    "Konvergen (optim() convergence code = 0)"
  } else {
    paste0("PERINGATAN: convergence code = ", final_fit$convergence, " - optimisasi mungkin belum konvergen sempurna")
  }
  hessian_status <- ifelse(final_fit$hessian_ok,
                           "Positive Definite (SE valid berdasarkan inverse Hessian, eigenvalue > 1e-8)",
                           "TIDAK Positive Definite - SE/Wald/CI diisi NA (regularity conditions MLE tidak terpenuhi, lih. Self & Liang 1987)")
  n_iter <- final_fit$n_iter
  
  ar_stationarity_overall <- if (ar_order_p > 0 && nrow(ar_stationarity_table) > 0) {
    if (all(grepl("^STASIONER", ar_stationarity_table$Status_Stasioner))) {
      "STASIONER pada seluruh regime"
    } else if (any(grepl("^TIDAK STASIONER", ar_stationarity_table$Status_Stasioner))) {
      "TIDAK STASIONER pada satu atau lebih regime - lih. sheet 'AR Stationarity Diagnostics'"
    } else {
      "Tidak dapat ditentukan pada satu/lebih regime - lih. sheet 'AR Stationarity Diagnostics'"
    }
  } else {
    "N/A (orde AR p = 0, model setara MRSR)"
  }
  
  model_summary_df <- data.frame(
    Item = c("Spesifikasi Model", "Jumlah Regime Terpilih", "Orde Autoregressive (p) Terpilih",
             "Variabel Lag AR", "Densitas Emisi (Model Final Terpilih)", "Metode Estimasi",
             "Algoritma Optimisasi", "Status Konvergensi", "Status Hessian", "Jumlah Evaluasi Fungsi",
             "Log-Likelihood", "AIC", "BIC", "HQIC", "Jumlah Observasi Efektif (setelah lag)",
             "Jumlah Parameter Diestimasi", "Status Stasioneritas AR (seluruh regime)"),
    Nilai = c("Markov Switching Autoregressive (MS-AR) - Hamilton (1989, 1994), Krolzig (1997)",
              best_k, ar_order_p,
              ifelse(length(lag_cols) > 0, paste(lag_cols, collapse = ", "), "Tidak ada (p = 0)"),
              final_fit_distribution, "Direct Maximum Likelihood",
              ifelse(!is.null(final_fit$optimizer_used), final_fit$optimizer_used, "L-BFGS-B"),
              convergence_status, hessian_status, as.character(n_iter),
              final_ll, final_aic, final_bic, final_hqic, n_obs_model, n_est_params_final,
              ar_stationarity_overall)
  )
  openxlsx::addWorksheet(wb, "Model Summary")
  openxlsx::writeData(wb, "Model Summary", model_summary_df)
  
  wald_table <- data.frame()
  coef_numeric <- coef_df[ , !(names(coef_df) %in% c("Regime")), drop = FALSE]
  se_matrix <- se_df
  
  for (i in 1:nrow(coef_numeric)) {
    for (j in 1:ncol(coef_numeric)) {
      b  <- suppressWarnings(as.numeric(coef_numeric[i, j]))
      se <- suppressWarnings(as.numeric(se_matrix[i, j]))
      if (!is.na(b) && !is.na(se) && se > 0) {
        wald_stat <- (b / se)^2
        p_val <- 1 - pchisq(wald_stat, df = 1)
        wald_table <- rbind(wald_table, data.frame(
          Regime = coef_df$Regime[i],
          Parameter = names(coef_numeric)[j],
          Estimate = b,
          Std_Error = se,
          Wald_Statistic = wald_stat,
          p_value = p_val,
          Signifikansi = ifelse(p_val < 0.01, "***",
                                ifelse(p_val < 0.05, "**",
                                       ifelse(p_val < 0.10, "*", "tidak signifikan")))
        ))
      }
    }
  }
  if (nrow(wald_table) == 0) {
    wald_table <- data.frame(Catatan = "Wald test tidak dapat dihitung otomatis - std. error tidak tersedia (Hessian bermasalah). Silakan cek objek 'final_fit' secara manual.")
  }
  openxlsx::addWorksheet(wb, "Wald Test")
  openxlsx::writeData(wb, "Wald Test", wald_table)
  
  wald_regime_diff_table <- tryCatch(
    wald_regime_equality_test(final_fit, alpha = 0.05),
    error = function(e) {
      cat(">> PERINGATAN: Wald test regime-equality gagal dihitung:", conditionMessage(e), "\n")
      data.frame(Catatan = paste0("Wald test regime-equality tidak dapat dihitung otomatis: ",
                                  conditionMessage(e)))
    }
  )
  openxlsx::addWorksheet(wb, "Wald Test Regime Difference")
  openxlsx::writeData(wb, "Wald Test Regime Difference", wald_regime_diff_table)
  openxlsx::writeData(wb, "Wald Test Regime Difference", data.frame(
    Catatan = c(
      "Pengujian ini BERBEDA dari sheet 'Wald Test': H0 di sini adalah KOEFISIEN SAMA ANTAR-REGIME",
      "(H0: beta_regime_i = beta_regime_j), BUKAN H0: beta = 0. Statistik Wald memakai full joint",
      "variance-covariance matrix (final_fit$vcov_mat, skala asli) via restriction matrix umum,",
      "BUKAN rumus ad-hoc var(beta_i)+var(beta_j)-2cov(beta_i,beta_j). Jika Hessian/VCOV final TIDAK",
      "valid, hasil diisi NA (lih. kolom Interpretation) - bukan dipaksakan via pseudo-inverse.",
      "Untuk model dengan k >= 3 regime, baris 'Global' menguji kesamaan pada SELURUH regime",
      "sekaligus (df = k-1); baris pairwise ('Regime i vs Regime j') adalah follow-up test."
    )
  ), startRow = nrow(wald_regime_diff_table) + 3)
  
  cat(">> Wald Test Regime Difference (equality restriction antar-regime) selesai dihitung.\n")
  
  X_full_lb   <- model.matrix(base_formula, data = model_df)
  fitted_by_regime_lb <- sapply(1:best_k, function(r) as.numeric(X_full_lb %*% final_fit$beta_mat[, r]))
  fitted_reg  <- tryCatch(
    sapply(seq_along(regime_class), function(t) fitted_by_regime_lb[t, regime_class[t]]),
    error = function(e) rep(NA, nrow(model_df))
  )
  raw_resid   <- model_df[[stock_name]] - fitted_reg
  raw_resid  <- raw_resid[!is.na(raw_resid)]
  std_resid  <- (raw_resid - mean(raw_resid)) / sd(raw_resid)
  
  lb_test <- tryCatch(Box.test(std_resid, lag = 10, type = "Ljung-Box"),
                      error = function(e) NULL)
  
  lb_table <- data.frame(
    Test = "Ljung-Box Test (lag = 10)",
    Statistic = if (!is.null(lb_test)) unname(lb_test$statistic) else NA,
    p_value   = if (!is.null(lb_test)) lb_test$p.value else NA,
    Decision  = if (!is.null(lb_test)) {
      ifelse(lb_test$p.value > 0.05,
             "Tidak terdapat autokorelasi signifikan pada residual (model memenuhi syarat)",
             "Terdapat autokorelasi signifikan pada residual (model perlu spesifikasi ulang)")
    } else NA
  )
  openxlsx::addWorksheet(wb, "Ljung-Box Test")
  openxlsx::writeData(wb, "Ljung-Box Test", lb_table)
  
  residual_df <- data.frame(
    Dates = model_df$Dates[1:length(raw_resid)],
    Raw_Residual = raw_resid,
    Standardized_Residual = std_resid
  )
  openxlsx::addWorksheet(wb, "Residual Diagnostics")
  openxlsx::writeData(wb, "Residual Diagnostics", residual_df)
  
  cat(">> Diagnostik model (Wald Test & Ljung-Box Test) selesai.\n")
  
  optim_trace_sheet <- final_fit$optim_trace
  
  hessian_df <- as.data.frame(final_fit$hessian_mat)
  colnames(hessian_df) <- paste0("P", seq_len(ncol(hessian_df)))
  vcov_df <- as.data.frame(final_fit$vcov_mat)
  colnames(vcov_df) <- paste0("P", seq_len(ncol(vcov_df)))
  corr_param_mat <- tryCatch(cov2cor(final_fit$vcov_mat),
                             error = function(e) matrix(NA, nrow(final_fit$vcov_mat), ncol(final_fit$vcov_mat)))
  corr_param_df <- as.data.frame(corr_param_mat)
  colnames(corr_param_df) <- paste0("P", seq_len(ncol(corr_param_df)))
  eigen_df <- data.frame(Eigenvalue_Index = seq_along(final_fit$hessian_eigenvalues),
                         Eigenvalue = final_fit$hessian_eigenvalues)
  
  null_lm  <- lm(as.formula(paste0("`", stock_name, "` ~ 1")), data = model_df)
  null_ll  <- as.numeric(logLik(null_lm))
  pseudo_r2 <- 1 - exp((2 / n_obs_model) * (null_ll - final_ll))
  lr_stat  <- -2 * (null_ll - final_ll)
  lr_df    <- max(n_est_params_final - length(coef(null_lm)) - 1, 1)
  lr_pvalue <- 1 - pchisq(lr_stat, df = lr_df)
  caic_val <- -2 * final_ll + n_est_params_final * (log(n_obs_model) + 1)
  
  optim_summary_extended <- data.frame(
    Item = c("Jumlah Observasi", "Jumlah Regime", "Metode Estimasi", "Algoritma Optimisasi",
             "Convergence Code", "Convergence Message", "Status Konvergensi",
             "Jumlah Evaluasi Fungsi", "Jumlah Evaluasi Gradien", "Waktu Komputasi (detik)",
             "Norm Gradien pada Solusi Akhir",
             "factr (toleransi konvergensi relatif)", "pgtol (toleransi norm gradien)",
             "Status Hessian (Positive Definite)", "Minimum Eigenvalue Hessian",
             "Maksimum Eigenvalue Hessian", "Rank Hessian", "Dimensi Penuh (Jumlah Parameter)",
             "Determinant Hessian", "Condition Number Hessian", "Reciprocal Condition Number",
             "Status Validitas Standard Error", "Status Validitas Wald Test",
             "Log-Likelihood Starting Value", "Log-Likelihood Akhir",
             "Log-Likelihood Model Null (Intercept-only)",
             "Pseudo R-squared (Cox & Snell)", "Likelihood Ratio Statistic",
             "Likelihood Ratio df", "Likelihood Ratio p-value",
             "AIC", "BIC", "HQIC", "CAIC"),
    Nilai = c(n_obs_model, best_k, "Direct Maximum Likelihood",
              ifelse(!is.null(final_fit$optimizer_used), final_fit$optimizer_used, "L-BFGS-B"),
              as.character(final_fit$convergence),
              ifelse(!is.null(final_fit$convergence_message) && !is.na(final_fit$convergence_message),
                     final_fit$convergence_message, "Tidak tersedia"),
              convergence_status, as.character(n_iter), as.character(final_fit$n_iter_grad),
              ifelse(!is.null(final_fit$computation_time_sec), round(final_fit$computation_time_sec, 3), NA),
              ifelse(!is.null(final_fit$gradient_norm), signif(final_fit$gradient_norm, 6), NA),
              "1e7 (Byrd, Lu, Nocedal & Zhu, 1995 - moderate accuracy)", "1e-8",
              final_fit$hessian_ok,
              signif(final_fit$hessian_diagnostics$min_eigenvalue, 6),
              signif(final_fit$hessian_diagnostics$max_eigenvalue, 6),
              final_fit$hessian_diagnostics$rank, final_fit$hessian_diagnostics$full_rank_expected,
              signif(final_fit$hessian_diagnostics$determinant, 6),
              round(final_fit$hessian_condition_number, 3),
              signif(final_fit$hessian_diagnostics$reciprocal_condition_number, 6),
              ifelse(final_fit$se_valid, "VALID", "TIDAK VALID (NA - Hessian tidak positive definite)"),
              ifelse(final_fit$wald_valid, "VALID", "TIDAK VALID (NA - Hessian tidak positive definite)"),
              round(-optim_trace_sheet$NegLogLik[1], 4), round(final_ll, 4), round(null_ll, 4),
              round(pseudo_r2, 4), round(lr_stat, 4), lr_df, signif(lr_pvalue, 4),
              round(final_aic, 3), round(final_bic, 3), round(final_hqic, 3), round(caic_val, 3))
  )
  
  theta_start_end_df <- data.frame(
    Parameter_Index = seq_along(final_fit$theta),
    Starting_Value = final_fit$theta0_winning,
    Estimated_Value = final_fit$theta
  )
  
  openxlsx::addWorksheet(wb, "Optimization Diagnostics")
  openxlsx::writeData(wb, "Optimization Diagnostics", optim_summary_extended)
  openxlsx::writeData(wb, "Optimization Diagnostics",
                      data.frame(Catatan = paste0(
                        "Jejak Iterasi Optimisasi ", ifelse(!is.null(final_fit$optimizer_used), final_fit$optimizer_used, "L-BFGS-B"),
                        " (Starting Value, iterasi awal, Final):")),
                      startRow = nrow(optim_summary_extended) + 3)
  openxlsx::writeData(wb, "Optimization Diagnostics", optim_trace_sheet, startRow = nrow(optim_summary_extended) + 4)
  openxlsx::writeData(wb, "Optimization Diagnostics",
                      data.frame(Catatan = "Starting Values vs Estimated Values (parameter awal & akhir, starting value pemenang multi-start):"),
                      startRow = nrow(optim_summary_extended) + nrow(optim_trace_sheet) + 7)
  openxlsx::writeData(wb, "Optimization Diagnostics", theta_start_end_df,
                      startRow = nrow(optim_summary_extended) + nrow(optim_trace_sheet) + 8)
  if (!final_fit$se_valid) {
    openxlsx::writeData(wb, "Optimization Diagnostics",
                        data.frame(Peringatan = paste0(
                          "Hessian TIDAK positive definite (", final_fit$hessian_diagnostics$n_negative_eigenvalues,
                          " dari ", final_fit$hessian_diagnostics$full_rank_expected, " eigenvalue <= toleransi 1e-8). ",
                          "Sesuai regularity conditions MLE (Self & Liang, 1987), pseudo-inverse TIDAK dipakai ",
                          "sebagai dasar inferensi. Seluruh standard error, z-statistic, Wald statistic, p-value, ",
                          "dan confidence interval pada sheet-sheet lain (Wald Test, Regime Coefficients Full, dsb.) ",
                          "BERNILAI NA. Estimasi parameter (Estimate) & Log-Likelihood TETAP VALID secara asimtotik.")),
                        startRow = nrow(optim_summary_extended) + nrow(optim_trace_sheet) + nrow(theta_start_end_df) + 11)
  }
  
  openxlsx::addWorksheet(wb, "Hessian Matrix")
  openxlsx::writeData(wb, "Hessian Matrix", hessian_df)
  openxlsx::addWorksheet(wb, "VCOV Matrix")
  openxlsx::writeData(wb, "VCOV Matrix", vcov_df)
  openxlsx::addWorksheet(wb, "Parameter Correlation Matrix")
  openxlsx::writeData(wb, "Parameter Correlation Matrix", corr_param_df)
  openxlsx::addWorksheet(wb, "Hessian Eigenvalues")
  openxlsx::writeData(wb, "Hessian Eigenvalues", eigen_df)
  
  cat(">> Optimization and Hessian Diagnostics lengkap (", ifelse(!is.null(final_fit$optimizer_used), final_fit$optimizer_used, "L-BFGS-B"),
      ", eigenvalue, condition number, determinant, gradient norm, waktu komputasi,",
      "Pseudo R2, LR Test, CAIC) tersimpan.\n")
  
  
  ms_boundary_flags <- character(0)
  diag_p_boundary <- diag(as.matrix(trans_mat))
  for (i in seq_along(diag_p_boundary)) {
    if (diag_p_boundary[i] > 0.995) {
      ms_boundary_flags <- c(ms_boundary_flags, paste0("Persistence Regime_", i, " = ",
                                                       round(diag_p_boundary[i], 5),
                                                       " (mendekati batas atas 1 - near-absorbing state)"))
    } else if (diag_p_boundary[i] < 0.005) {
      ms_boundary_flags <- c(ms_boundary_flags, paste0("Persistence Regime_", i, " = ",
                                                       round(diag_p_boundary[i], 5),
                                                       " (mendekati batas bawah 0)"))
    }
  }
  
  ms_hess_diag <- diagnose_hessian_numerics(
    final_fit$hessian_mat, param_names = paste0("theta_", seq_len(nrow(final_fit$hessian_mat))),
    convergence_code = final_fit$convergence,
    boundary_params = if (length(ms_boundary_flags) > 0) ms_boundary_flags else NULL
  )
  
  local_optimum_flag <- "Tidak dapat dievaluasi (log multi-start tidak tersedia)"
  n_distinct_optima <- NA
  if (!is.null(final_fit$all_starts_log) && nrow(final_fit$all_starts_log) > 1) {
    ll_spread <- final_fit$all_starts_log$NegLogLik
    ll_range <- max(ll_spread) - min(ll_spread)
    n_distinct_optima <- length(unique(round(ll_spread, 2)))
    local_optimum_flag <- if (n_distinct_optima > 1) {
      paste0("TERDETEKSI ", n_distinct_optima, " nilai NegLogLik BERBEDA dari ", nrow(final_fit$all_starts_log),
             " starting values (rentang = ", round(ll_range, 4), ") - indikasi permukaan likelihood ",
             "non-convex dengan lebih dari satu local optimum. Model final tetap menggunakan hasil BIC/",
             "NegLogLik TERBAIK di antara seluruh starting values (multi-start L-BFGS-B).")
    } else {
      paste0("Seluruh ", nrow(final_fit$all_starts_log), " starting values konvergen ke NegLogLik yang ",
             "SAMA - tidak ada indikasi local optimum pada rentang starting values yang dicoba.")
    }
  }
  
  sigma_ratio_matrix <- outer(final_fit$sigma_vec, final_fit$sigma_vec, function(a, b) pmin(a, b) / pmax(a, b))
  diag(sigma_ratio_matrix) <- NA
  max_sigma_ratio <- suppressWarnings(max(sigma_ratio_matrix, na.rm = TRUE))
  regime_collapse_flag <- if (is.finite(max_sigma_ratio) && max_sigma_ratio > 0.85) {
    paste0("INDIKASI REGIME TIDAK TERPISAH SECARA STATISTIK: rasio sigma terdekat antar-regime = ",
           round(max_sigma_ratio, 4), " (mendekati 1). Kedua regime memiliki volatilitas yang serupa, ",
           "berpotensi menyebabkan identification problem/Hessian near-singular (Hamilton, 1994, Ch.22).")
  } else {
    paste0("Regime terpisah secara memadai (rasio sigma terdekat antar-regime = ",
           round(max_sigma_ratio, 4), ", di bawah ambang batas 0.85).")
  }
  
  obs_per_param <- n_obs_model / n_est_params_final
  overparam_flag <- if (obs_per_param < 10) {
    paste0("PERINGATAN OVERPARAMETERIZATION: rasio observasi:parameter = ", round(obs_per_param, 2),
           " (di bawah pedoman umum minimal ~10-20 observasi per parameter untuk estimasi MLE yang ",
           "stabil, lih. Harrell, 2015). Pertimbangkan mengurangi jumlah regime atau jumlah variabel ",
           "independen apabila Hessian tidak positive definite.")
  } else {
    paste0("Rasio observasi:parameter = ", round(obs_per_param, 2),
           " (memadai berdasarkan pedoman umum minimal ~10-20 observasi per parameter).")
  }
  
  gradient_norm_flag <- if (!is.null(final_fit$gradient_norm) && is.finite(final_fit$gradient_norm)) {
    if (final_fit$gradient_norm > 1) {
      paste0("Norm gradien pada solusi akhir CUKUP BESAR (", signif(final_fit$gradient_norm, 4),
             ") meskipun convergence code = ", final_fit$convergence, " - indikasi permukaan log-",
             "likelihood landai (flat) di sekitar solusi, weak parameter identifiability, atau ",
             "kriteria konvergensi factr terpenuhi sebelum norm gradien benar-benar kecil.")
    } else {
      paste0("Norm gradien pada solusi akhir kecil (", signif(final_fit$gradient_norm, 4),
             ") - konsisten dengan titik stasioner yang valid (first-order optimality condition terpenuhi).")
    }
  } else "Norm gradien tidak dapat dihitung."
  
  ill_conditioned_flag <- if (!is.na(ms_hess_diag$condition_number) && ms_hess_diag$condition_number > 1e12) {
    paste0("HESSIAN SANGAT ILL-CONDITIONED: condition number = ",
           format(ms_hess_diag$condition_number, scientific = TRUE, digits = 3),
           " (> 10^12) - Reciprocal Condition Number = ",
           format(ms_hess_diag$reciprocal_condition_number, scientific = TRUE, digits = 3),
           ". Meskipun mungkin masih lolos uji positive definite (eigenvalue > 1e-8), inversi Hessian",
           " (solve()) pada kondisi ini berisiko kehilangan presisi numerik signifikan - hasil SE/CI",
           " perlu diinterpretasikan dengan sangat hati-hati. Kemungkinan penyebab: multikolinearitas",
           " parameter, redundansi parameter, atau model over-parameterized.")
  } else {
    paste0("Condition number Hessian dalam rentang wajar (",
           ifelse(is.na(ms_hess_diag$condition_number), "NA", format(ms_hess_diag$condition_number, scientific = TRUE, digits = 3)),
           ", di bawah ambang 10^12).")
  }
  
  ms_diagnostic_summary <- data.frame(
    Aspek = c("Hessian Positive Definite", "Jumlah Eigenvalue Bermasalah (<=0)", "Condition Number",
              "Reciprocal Condition Number", "Rank Numerik Hessian", "Dimensi Penuh Diharapkan",
              "Singular/Near-Singular", "Jumlah Pasangan Parameter Korelasi Tinggi (>0.95)",
              "Norm Gradien Solusi Akhir", "Indikasi Local Optimum",
              "Jumlah Nilai Optimum Berbeda (Multi-Start)", "Indikasi Regime Collapse",
              "Rasio Sigma Terdekat Antar-Regime", "Rasio Observasi:Parameter",
              "Convergence Code Optimizer", "Ill-Conditioned (Condition Number > 1e12)"),
    Hasil = c(ms_hess_diag$is_positive_definite, ms_hess_diag$n_negative_eigenvalues,
              round(ms_hess_diag$condition_number, 3), signif(ms_hess_diag$reciprocal_condition_number, 6),
              ms_hess_diag$rank, ms_hess_diag$full_rank_expected,
              ms_hess_diag$is_singular, nrow(ms_hess_diag$high_correlation_pairs),
              signif(final_fit$gradient_norm, 6),
              isTRUE(!is.na(n_distinct_optima) && n_distinct_optima > 1),
              ifelse(is.na(n_distinct_optima), "N/A", n_distinct_optima),
              isTRUE(max_sigma_ratio > 0.85), round(max_sigma_ratio, 4),
              round(obs_per_param, 2), final_fit$convergence,
              isTRUE(!is.na(ms_hess_diag$condition_number) && ms_hess_diag$condition_number > 1e12))
  )
  
  ms_diagnosis_narrative <- data.frame(
    Diagnosis = c(ms_hess_diag$diagnosis_text, local_optimum_flag, regime_collapse_flag,
                  overparam_flag, gradient_norm_flag, ill_conditioned_flag)
  )
  
  openxlsx::addWorksheet(wb, "MS Hessian Diagnostics")
  openxlsx::writeData(wb, "MS Hessian Diagnostics", ms_diagnostic_summary)
  openxlsx::writeData(wb, "MS Hessian Diagnostics", data.frame(Catatan = "Diagnosis Naratif Lengkap:"),
                      startRow = nrow(ms_diagnostic_summary) + 3)
  openxlsx::writeData(wb, "MS Hessian Diagnostics", ms_diagnosis_narrative,
                      startRow = nrow(ms_diagnostic_summary) + 4)
  if (!is.null(final_fit$all_starts_log)) {
    openxlsx::writeData(wb, "MS Hessian Diagnostics", data.frame(Catatan = "Log Seluruh Starting Values (Multi-Start):"),
                        startRow = nrow(ms_diagnostic_summary) + nrow(ms_diagnosis_narrative) + 6)
    openxlsx::writeData(wb, "MS Hessian Diagnostics", final_fit$all_starts_log,
                        startRow = nrow(ms_diagnostic_summary) + nrow(ms_diagnosis_narrative) + 7)
  }
  
  cat(">> Diagnosis numerik & identifikasi Markov Switching (local optimum, regime collapse,",
      "parameter boundary, overparameterization, gradient norm, ill-conditioning) tersimpan.\n")
  for (dtxt in ms_hess_diag$diagnosis_text) cat("   -", dtxt, "\n")
  cat("   -", local_optimum_flag, "\n")
  cat("   -", regime_collapse_flag, "\n")
  cat("   -", overparam_flag, "\n")
  cat("   -", gradient_norm_flag, "\n")
  cat("   -", ill_conditioned_flag, "\n")
  
  X_full_ext <- model.matrix(base_formula, data = model_df)
  
  regime_coef_full <- data.frame()
  for (i in 1:best_k) {
    for (j in seq_along(coef_names)) {
      b  <- final_fit$beta_mat[j, i]
      se <- final_fit$se_beta[j, i]
      z    <- if (!is.na(se) && se > 0) b / se else NA
      wald <- if (!is.na(z)) z^2 else NA
      pval <- if (!is.na(wald)) 1 - pchisq(wald, df = 1) else NA
      regime_coef_full <- rbind(regime_coef_full, data.frame(
        Regime = paste0("Regime_", i), Parameter = coef_names[j],
        Estimate = b, Std_Error = se, Z_Statistic = z, Wald_Statistic = wald, p_value = pval,
        CI_Lower_95 = b - 1.96 * se, CI_Upper_95 = b + 1.96 * se,
        Signifikansi = ifelse(is.na(pval), "N/A",
                              ifelse(pval < 0.01, "***", ifelse(pval < 0.05, "**",
                                                                ifelse(pval < 0.10, "*", "tidak signifikan")))),
        Keputusan = ifelse(is.na(pval), "Tidak dapat diuji",
                           ifelse(pval < 0.05, "Signifikan (tolak H0: beta=0)", "Tidak Signifikan (gagal tolak H0)")),
        stringsAsFactors = FALSE
      ))
    }
  }
  openxlsx::addWorksheet(wb, "Regime Coefficients Full")
  openxlsx::writeData(wb, "Regime Coefficients Full", regime_coef_full)
  
  sigma_order_cmp <- order(coef_df$Sigma)
  bull_idx <- sigma_order_cmp[1]; bear_idx <- sigma_order_cmp[length(sigma_order_cmp)]
  regime_comparison <- data.frame()
  for (j in seq_along(coef_names)) {
    b_bull <- final_fit$beta_mat[j, bull_idx]
    b_bear <- final_fit$beta_mat[j, bear_idx]
    sign_change <- sign(b_bull) != sign(b_bear)
    magnitude_change <- abs(b_bear) - abs(b_bull)
    regime_comparison <- rbind(regime_comparison, data.frame(
      Parameter = coef_names[j], Koef_Bull = b_bull, Koef_Bear = b_bear,
      Perubahan_Tanda = ifelse(sign_change, "YA (arah pengaruh berbalik)", "TIDAK"),
      Perubahan_Magnitude = magnitude_change,
      Interpretasi = ifelse(sign_change,
                            "Arah pengaruh variabel berbalik antara Bull dan Bear Regime",
                            ifelse(magnitude_change > 0, "Pengaruh variabel MENGUAT pada Bear Regime",
                                   "Pengaruh variabel MELEMAH pada Bear Regime")),
      stringsAsFactors = FALSE
    ))
  }
  openxlsx::addWorksheet(wb, "Regime Comparison (Bull-Bear)")
  openxlsx::writeData(wb, "Regime Comparison (Bull-Bear)", regime_comparison)
  
  ranking_list <- list()
  for (i in 1:best_k) {
    sub <- regime_coef_full[regime_coef_full$Regime == paste0("Regime_", i) &
                              regime_coef_full$Parameter != "(Intercept)", ]
    sub$Rank_AbsCoef <- rank(-abs(sub$Estimate))
    sub$Rank_Signifikansi <- rank(ifelse(is.na(sub$p_value), Inf, sub$p_value))
    ranking_list[[i]] <- sub[order(sub$Rank_AbsCoef),
                             c("Regime", "Parameter", "Estimate", "p_value", "Rank_AbsCoef", "Rank_Signifikansi")]
  }
  ranking_table <- do.call(rbind, ranking_list)
  openxlsx::addWorksheet(wb, "Variable Ranking per Regime")
  openxlsx::writeData(wb, "Variable Ranking per Regime", ranking_table)
  
  dominant_text <- sapply(1:best_k, function(i) {
    sub <- ranking_list[[i]]
    top_var <- sub$Parameter[which.min(sub$Rank_AbsCoef)]
    paste0("Regime_", i, ": variabel paling dominan (|koefisien| terbesar) adalah '", top_var, "'.")
  })
  openxlsx::writeData(wb, "Variable Ranking per Regime", data.frame(Interpretasi_Otomatis = dominant_text),
                      startRow = nrow(ranking_table) + 3)
  
  marginal_effect_table <- data.frame()
  for (i in 1:best_k) {
    obs_idx <- which(regime_class == i)
    if (length(obs_idx) < 2) next
    y_mean_i <- mean(model_df[[stock_name]][obs_idx], na.rm = TRUE)
    for (j in seq_along(selected_macro_cols)) {
      col_j <- which(coef_names == selected_macro_cols[j])
      if (length(col_j) == 0) next
      beta_j <- final_fit$beta_mat[col_j, i]
      x_mean_i <- mean(X_full_ext[obs_idx, col_j], na.rm = TRUE)
      elasticity <- if (isTRUE(y_mean_i != 0)) beta_j * (x_mean_i / y_mean_i) else NA
      marginal_effect_table <- rbind(marginal_effect_table, data.frame(
        Regime = paste0("Regime_", i), Variable = selected_macro_cols[j],
        Marginal_Effect = beta_j, Mean_X_Regime = x_mean_i, Mean_Y_Regime = y_mean_i,
        Elasticity = elasticity, stringsAsFactors = FALSE
      ))
    }
  }
  openxlsx::addWorksheet(wb, "Marginal Effect & Elasticity")
  openxlsx::writeData(wb, "Marginal Effect & Elasticity", marginal_effect_table)
  openxlsx::writeData(wb, "Marginal Effect & Elasticity",
                      data.frame(Catatan = paste0("Pada model regresi linear (Gaussian), marginal effect = koefisien ",
                                                  "regresi (konstan, tidak bergantung nilai X). Elastisitas dihitung ",
                                                  "pada rata-rata kondisional X dan Y tiap regime.")),
                      startRow = nrow(marginal_effect_table) + 3)
  
  cat(">> Regime coefficients (full output), regime comparison, ranking, dan",
      "marginal effect/elasticity tersimpan.\n")
  
  steady_state <- compute_steady_state(as.matrix(trans_mat), best_k)
  diag_p_master <- diag(as.matrix(trans_mat))
  switch_freq <- 1 - diag_p_master
  
  markov_param_master <- data.frame(
    Regime = paste0("Regime_", 1:best_k),
    Intercept = final_fit$beta_mat[1, ],
    Sigma = final_fit$sigma_vec,
    SE_Sigma = final_fit$se_sigma,
    Persistence_Prob = diag_p_master,
    Expected_Duration_Days = expected_duration(diag_p_master),
    Steady_State_Probability = steady_state,
    Expected_Switching_Frequency = switch_freq
  )
  openxlsx::addWorksheet(wb, "Markov Parameter Master")
  openxlsx::writeData(wb, "Markov Parameter Master", markov_param_master)
  
  eta_labels <- character(0)
  for (j in 1:best_k) for (i in 1:(best_k - 1)) {
    eta_labels <- c(eta_labels, paste0("eta[Baris", i, "_Kolom", j, "]"))
  }
  eta_z <- final_fit$eta / final_fit$se_eta
  eta_p <- 2 * (1 - pnorm(abs(eta_z)))
  eta_table <- data.frame(
    Parameter = eta_labels, Estimate = final_fit$eta, Std_Error = final_fit$se_eta,
    Z_Statistic = eta_z, p_value = eta_p,
    CI_Lower_95 = final_fit$eta - 1.96 * final_fit$se_eta,
    CI_Upper_95 = final_fit$eta + 1.96 * final_fit$se_eta,
    Signifikansi = ifelse(eta_p < 0.01, "***", ifelse(eta_p < 0.05, "**",
                                                      ifelse(eta_p < 0.10, "*", "tidak signifikan")))
  )
  openxlsx::addWorksheet(wb, "Transition Params (Logit)")
  openxlsx::writeData(wb, "Transition Params (Logit)", eta_table)
  openxlsx::writeData(wb, "Transition Params (Logit)",
                      data.frame(Catatan = paste0("Parameter eta adalah parameter transisi pada skala logit/softmax ",
                                                  "sebagaimana dioptimasi langsung oleh model (Bagian 3.8). Titik estimasi ",
                                                  "matriks probabilitas P (skala 0-1) tersedia pada sheet 'Transition Matrix'; ",
                                                  "confidence interval P dapat diturunkan lebih lanjut via Delta Method dari eta ini.")),
                      startRow = nrow(eta_table) + 3)
  
  regime_vol_rank      <- order(-markov_param_master$Sigma)
  regime_persist_rank  <- order(-markov_param_master$Persistence_Prob)
  regime_occupied_rank <- order(-markov_param_master$Steady_State_Probability)
  interp_markov_param <- c(
    paste0("Regime dengan volatilitas TERTINGGI: ", markov_param_master$Regime[regime_vol_rank[1]],
           " (sigma = ", round(markov_param_master$Sigma[regime_vol_rank[1]], 5), ")."),
    paste0("Regime PALING PERSISTEN: ", markov_param_master$Regime[regime_persist_rank[1]],
           " (p = ", round(markov_param_master$Persistence_Prob[regime_persist_rank[1]], 4),
           ", expected duration = ", round(markov_param_master$Expected_Duration_Days[regime_persist_rank[1]], 2), " hari)."),
    paste0("Regime PALING SERING DITEMPATI: ", markov_param_master$Regime[regime_occupied_rank[1]],
           " (", round(markov_param_master$Steady_State_Probability[regime_occupied_rank[1]] * 100, 2), "% dari waktu)."),
    "Probabilitas perpindahan antar regime tersedia lengkap pada sheet 'Transition Matrix'."
  )
  openxlsx::writeData(wb, "Markov Parameter Master", data.frame(Interpretasi_Otomatis = interp_markov_param),
                      startRow = nrow(markov_param_master) + 3)
  
  cat(">> Markov Parameter Master Table (persistence, expected duration, steady-state,",
      "switching frequency, parameter transisi) tersimpan.\n")
  
  fitted_by_regime <- sapply(1:best_k, function(r) as.numeric(X_full_ext %*% final_fit$beta_mat[, r]))
  regime_resid_full <- model_df[[stock_name]] -
    sapply(seq_along(regime_class), function(t) fitted_by_regime[t, regime_class[t]])
  
  regime_resid_df <- data.frame(
    Dates = model_df$Dates, Regime = paste0("Regime_", regime_class),
    Actual = model_df[[stock_name]],
    Fitted = sapply(seq_along(regime_class), function(t) fitted_by_regime[t, regime_class[t]]),
    Residual = regime_resid_full
  )
  regime_resid_df$Standardized_Residual <- ave(regime_resid_df$Residual, regime_resid_df$Regime,
                                               FUN = function(x) (x - mean(x)) / sd(x))
  
  normality_per_regime <- do.call(rbind, lapply(1:best_k, function(i) {
    normality_summary_one(regime_resid_df$Standardized_Residual[regime_resid_df$Regime == paste0("Regime_", i)],
                          paste0("Regime_", i))
  }))
  
  lb_per_regime <- do.call(rbind, lapply(1:best_k, function(i) {
    r_i <- regime_resid_df$Standardized_Residual[regime_resid_df$Regime == paste0("Regime_", i)]
    wn  <- white_noise_test(r_i, lag = min(10, max(1, floor(length(r_i) / 2))))
    data.frame(Regime = paste0("Regime_", i), N_Obs = length(r_i),
               LjungBox_Statistic = wn$statistic, LjungBox_p = wn$p_value, Keputusan = wn$decision)
  }))
  
  openxlsx::addWorksheet(wb, "Residual Diagnostics per Regime")
  openxlsx::writeData(wb, "Residual Diagnostics per Regime", normality_per_regime)
  openxlsx::writeData(wb, "Residual Diagnostics per Regime",
                      data.frame(Catatan = "Uji Ljung-Box per Regime (bersifat indikatif - lihat catatan metodologis pada kode):"),
                      startRow = nrow(normality_per_regime) + 3)
  openxlsx::writeData(wb, "Residual Diagnostics per Regime", lb_per_regime, startRow = nrow(normality_per_regime) + 4)
  
  nu_posthoc_table <- do.call(rbind, lapply(1:best_k, function(i) {
    r_i <- regime_resid_df$Standardized_Residual[regime_resid_df$Regime == paste0("Regime_", i)]
    r_i <- r_i[is.finite(r_i)]
    
    if (length(r_i) < 15) {
      return(data.frame(Regime = paste0("Regime_", i), N_Obs = length(r_i),
                        Nu_Estimate = NA_real_, SE_Nu = NA_real_,
                        Interpretasi = "N_Obs < 15 - estimasi nu post-hoc tidak dilakukan (sampel terlalu kecil)."))
    }
    
    fit_nu <- tryCatch(
      MASS::fitdistr(r_i, densfun = "t", start = list(df = 5), m = 0, s = 1, method = "BFGS"),
      error = function(e) {
        tryCatch(MASS::fitdistr(r_i, densfun = "t",
                                start = list(m = mean(r_i), s = stats::sd(r_i), df = 5)),
                 error = function(e2) NULL)
      })
    
    if (is.null(fit_nu)) {
      return(data.frame(Regime = paste0("Regime_", i), N_Obs = length(r_i),
                        Nu_Estimate = NA_real_, SE_Nu = NA_real_,
                        Interpretasi = "MASS::fitdistr() gagal konvergen untuk regime ini."))
    }
    
    nu_est <- unname(fit_nu$estimate["df"])
    se_nu  <- tryCatch(unname(fit_nu$sd["df"]), error = function(e) NA_real_)
    nu_capped_note <- if (!is.na(nu_est) && nu_est > 1000) TRUE else FALSE
    
    interp_nu <- if (is.na(nu_est)) {
      "Estimasi nu tidak tersedia."
    } else if (nu_capped_note) {
      paste0("nu = ", format(round(nu_est, 1), scientific = TRUE), " (> 1000, secara praktis TAK",
             " TERHINGGA) - residual regime ini SANGAT MENDEKATI distribusi Normal (heavy-tail",
             " TIDAK terdeteksi); estimasi numerik nu pada nilai sebesar ini bersifat TIDAK",
             " presisi/non-identifiable (lih. Fan & Yao, 2003) - interpretasikan sebagai 'mendekati",
             " Normal', BUKAN nilai nu yang presisi.")
    } else if (nu_est < 5) {
      paste0("nu = ", round(nu_est, 2), " (< 5) - residual regime ini menunjukkan HEAVY-TAIL",
             " yang KUAT (ekor distribusi jauh lebih tebal dibanding Normal); interpretasikan",
             " selang kepercayaan/uji berbasis Normal pada regime ini dengan hati-hati.")
    } else if (nu_est < 30) {
      paste0("nu = ", round(nu_est, 2), " (5-30) - residual regime ini menunjukkan HEAVY-TAIL",
             " MODERAT dibanding distribusi Normal.")
    } else {
      paste0("nu = ", round(nu_est, 2), " (> 30) - residual regime ini MENDEKATI distribusi",
             " Normal (heavy-tail lemah/tidak signifikan secara praktis).")
    }
    
    data.frame(Regime = paste0("Regime_", i), N_Obs = length(r_i),
               Nu_Estimate = round(nu_est, 4), SE_Nu = round(se_nu, 4), Interpretasi = interp_nu)
  }))
  
  openxlsx::addWorksheet(wb, "PostHoc Student-t Nu")
  openxlsx::writeData(wb, "PostHoc Student-t Nu", nu_posthoc_table)
  openxlsx::writeData(wb, "PostHoc Student-t Nu", data.frame(
    Catatan = paste0(
      "Estimasi derajat kebebasan (nu) Student-t di atas bersifat POST-HOC dan INFORMATIF SAJA - ",
      "dihitung via MASS::fitdistr() pada standardized residual PER REGIME dari model Gaussian ",
      "FINAL yang sudah terpilih (bukan bagian dari proses optimisasi Markov Switching). Nilai nu ",
      "TIDAK memengaruhi likelihood, BIC, klasifikasi regime, filtered/smoothed probability, ",
      "maupun parameter beta/sigma model Gaussian manapun. Semakin kecil nu, semakin tebal ekor ",
      "(heavy-tail) distribusi residual pada regime tersebut dibanding distribusi Normal.")),
    startRow = nrow(nu_posthoc_table) + 3)
  
  cat(">> [BARU] Estimasi post-hoc derajat kebebasan (nu) Student-t per regime",
      "(MASS::fitdistr, informatif) tersimpan pada sheet 'PostHoc Student-t Nu'.\n")
  
  openxlsx::addWorksheet(wb, "Residual Data per Regime")
  openxlsx::writeData(wb, "Residual Data per Regime", regime_resid_df)
  
  p_reg_qq <- ggplot(regime_resid_df, aes(sample = Standardized_Residual)) +
    stat_qq(color = "#1f78b4") + stat_qq_line(color = "red") + facet_wrap(~Regime) +
    labs(title = paste("QQ Plot Residual per Regime -", stock_name)) + theme_thesis()
  save_plot_hd(p_reg_qq, "Residual_QQPlot_perRegime", plots_dir, width = 10, height = 6)
  
  p_reg_hist <- ggplot(regime_resid_df, aes(x = Standardized_Residual)) +
    geom_histogram(aes(y = after_stat(density)), bins = 25, fill = "#1f78b4", color = "white", alpha = 0.8) +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "red") + facet_wrap(~Regime) +
    labs(title = paste("Histogram Residual per Regime -", stock_name)) + theme_thesis()
  save_plot_hd(p_reg_hist, "Residual_Histogram_perRegime", plots_dir, width = 10, height = 6)
  
  p_reg_dens <- ggplot(regime_resid_df, aes(x = Standardized_Residual, fill = Regime)) +
    geom_density(alpha = 0.5) +
    labs(title = paste("Density Plot Residual per Regime -", stock_name)) + theme_thesis()
  save_plot_hd(p_reg_dens, "Residual_Density_perRegime", plots_dir)
  
  p_reg_ts <- ggplot(regime_resid_df, aes(x = Dates, y = Residual, color = Regime)) +
    geom_line(linewidth = 0.3) +
    labs(title = paste("Residual Time Series berdasarkan Regime -", stock_name)) + theme_thesis()
  save_plot_hd(p_reg_ts, "Residual_TimeSeries_perRegime", plots_dir)
  
  p_reg_box <- ggplot(regime_resid_df, aes(x = Regime, y = Standardized_Residual, fill = Regime)) +
    geom_boxplot() +
    labs(title = paste("Boxplot Residual per Regime -", stock_name)) + theme_thesis()
  save_plot_hd(p_reg_box, "Residual_Boxplot_perRegime", plots_dir)
  
  for (i in 1:best_k) {
    r_i <- regime_resid_df$Standardized_Residual[regime_resid_df$Regime == paste0("Regime_", i)]
    if (length(r_i) >= 15) {
      invisible(plot_acf_pacf(r_i, paste0("Residual_Regime_", i, "_", stock_tag), plots_dir,
                              max_lag = min(20, floor(length(r_i) / 3))))
    }
  }
  
  cat(">> Diagnostik residual per regime (normalitas, Ljung-Box, visualisasi faceted) tersimpan.\n")
  
  last_filt_prob <- as.numeric(filt_prob[nrow(filt_prob), ])
  forecast_horizon <- 10
  regime_forecast <- forecast_regime_prob(as.matrix(trans_mat), last_filt_prob, horizon = forecast_horizon)
  prob_cols_fc <- grep("^Prob_State", names(regime_forecast), value = TRUE)
  regime_forecast$Expected_Regime <- apply(regime_forecast[, prob_cols_fc, drop = FALSE], 1,
                                           function(r) paste0("State", which.max(r)))
  bull_state_idx <- which.max(steady_state)
  regime_forecast$Cumulative_Avg_Prob_BullState <-
    cumsum(regime_forecast[[paste0("Prob_State", bull_state_idx)]]) / seq_len(nrow(regime_forecast))
  
  openxlsx::addWorksheet(wb, "Regime Forecast (t+1 to t+10)")
  openxlsx::writeData(wb, "Regime Forecast (t+1 to t+10)", regime_forecast)
  
  forecast_long <- reshape2::melt(regime_forecast[, c("Horizon", prob_cols_fc)], id.vars = "Horizon")
  forecast_long$Horizon <- factor(forecast_long$Horizon, levels = paste0("t+", 1:forecast_horizon))
  p_forecast <- ggplot(forecast_long, aes(x = Horizon, y = value, color = variable, group = variable)) +
    geom_line(linewidth = 0.6) + geom_point() +
    labs(title = paste("Forecast Regime Probability (t+1 s.d. t+10) -", stock_name),
         x = "Horizon", y = "Probabilitas", color = "State") +
    theme_thesis()
  save_plot_hd(p_forecast, "Regime_Forecast_Probability", plots_dir)
  
  interp_forecast <- paste0(
    "Pada horizon t+", forecast_horizon, ", regime dengan probabilitas tertinggi diperkirakan adalah ",
    regime_forecast$Expected_Regime[forecast_horizon], " (probabilitas = ",
    round(max(regime_forecast[forecast_horizon, prob_cols_fc]), 4),
    "), mengindikasikan kecenderungan kondisi pasar ke depan berdasarkan struktur transisi hasil estimasi."
  )
  openxlsx::writeData(wb, "Regime Forecast (t+1 to t+10)", data.frame(Interpretasi = interp_forecast),
                      startRow = nrow(regime_forecast) + 3)
  
  cat(">> Forecast regime probability (t+1 s.d. t+10) tersimpan.\n")
  
  weighted_fitted <- sapply(seq_len(nrow(smo_prob)), function(t) sum(fitted_by_regime[t, ] * smo_prob[t, ]))
  classification_confidence <- apply(smo_prob, 1, max)
  
  full_state_df <- data.frame(
    Dates = model_df$Dates,
    Actual_Return = model_df[[stock_name]],
    Most_Likely_Regime = regime_class,
    Regime_Label = regime_label,
    Classification_Confidence = classification_confidence,
    Fitted_Value_Classified = sapply(seq_along(regime_class), function(t) fitted_by_regime[t, regime_class[t]]),
    Fitted_Value_ProbWeighted = weighted_fitted,
    Residual = regime_resid_full,
    Standardized_Residual = regime_resid_df$Standardized_Residual,
    Prediction_Error = model_df[[stock_name]] - weighted_fitted
  )
  for (i in 1:best_k) full_state_df[[paste0("Filtered_Prob_State", i)]] <- filt_prob[, i]
  for (i in 1:best_k) full_state_df[[paste0("Smoothed_Prob_State", i)]] <- smo_prob[, i]
  
  openxlsx::addWorksheet(wb, "Full State Extraction")
  openxlsx::writeData(wb, "Full State Extraction", full_state_df)
  
  p_overlay_top <- ggplot(full_state_df, aes(x = Dates, y = Actual_Return, color = Regime_Label)) +
    geom_line(linewidth = 0.3) +
    labs(title = paste("Actual Return berdasarkan Regime -", stock_name), x = NULL, y = "Return") +
    theme_thesis() + theme(legend.position = "top")
  
  smo_long <- reshape2::melt(full_state_df[, c("Dates", grep("^Smoothed_Prob_State", names(full_state_df), value = TRUE))],
                             id.vars = "Dates")
  p_overlay_bottom <- ggplot(smo_long, aes(x = Dates, y = value, color = variable)) +
    geom_line(linewidth = 0.4) +
    labs(x = "Tanggal", y = "Smoothed Probability", color = "State") +
    theme_thesis()
  
  overlay_combined <- gridExtra::arrangeGrob(p_overlay_top, p_overlay_bottom, ncol = 1, heights = c(1, 1))
  ggsave(filename = file.path(plots_dir, "Overlay_Return_Regime_Probability.png"),
         plot = overlay_combined, width = 11, height = 8, dpi = 300, bg = "white")
  ggsave(filename = file.path(plots_dir, "Overlay_Return_Regime_Probability.pdf"),
         plot = overlay_combined, width = 11, height = 8, bg = "white")
  
  actual_fitted_long <- reshape2::melt(
    full_state_df[, c("Dates", "Actual_Return", "Fitted_Value_ProbWeighted")],
    id.vars = "Dates", variable.name = "Series", value.name = "Return"
  )
  p_actual_fitted <- ggplot(actual_fitted_long, aes(x = Dates, y = Return, color = Series)) +
    geom_line(linewidth = 0.35) +
    scale_color_manual(values = c("Actual_Return" = "grey40", "Fitted_Value_ProbWeighted" = "#e31a1c"),
                       labels = c("Actual Return", "Fitted (Probability-Weighted, MS-AR)")) +
    labs(title = paste("Actual vs Fitted Return (MS-AR, Probability-Weighted) -", stock_name),
         subtitle = paste0("Orde AR p = ", ar_order_p, ", k = ", best_k, " regime"),
         x = "Tanggal", y = "Return", color = NULL) +
    theme_thesis() + theme(legend.position = "top")
  save_plot_hd(p_actual_fitted, "Actual_vs_Fitted_MSAR", plots_dir, width = 11, height = 6)
  
  cat(">> Full State Extraction table & overlay plot (actual return, regime,",
      "filtered/smoothed probability) tersimpan.\n")
  
  
  
  p_return <- ggplot(log_return_df, aes(x = Dates, y = .data[[stock_name]])) +
    geom_line(color = "#1f78b4", linewidth = 0.4) +
    labs(title = paste("Historical Log Return -", stock_name),
         x = "Tanggal", y = "Log Return") +
    theme_thesis()
  save_plot_hd(p_return, "Historical_Return", plots_dir)
  
  filt_long <- reshape2::melt(filt_df, id.vars = "Dates")
  p_filt <- ggplot(filt_long, aes(x = Dates, y = value, color = variable)) +
    geom_line(linewidth = 0.5) +
    labs(title = paste("Filtered State Probabilities (Hamilton Filter) -", stock_name),
         x = "Tanggal", y = "Probabilitas", color = "State") +
    theme_thesis()
  save_plot_hd(p_filt, "Filtered_Probabilities", plots_dir)
  
  p_regime <- ggplot(class_df, aes(x = Dates, y = 1, fill = Regime_Label)) +
    geom_tile() +
    scale_fill_brewer(palette = "RdYlGn", direction = -1) +
    labs(title = paste("Regime Classification Over Time -", stock_name),
         x = "Tanggal", y = NULL, fill = "Regime") +
    theme_thesis() +
    theme(axis.text.y = element_blank())
  save_plot_hd(p_regime, "Regime_Classification", plots_dir, height = 3)
  
  tm_melt <- reshape2::melt(as.matrix(trans_mat))
  p_tm <- ggplot(tm_melt, aes(Var2, Var1, fill = value)) +
    geom_tile(color = "white") +
    geom_text(aes(label = round(value, 3)), size = 4) +
    scale_fill_gradient(low = "white", high = "#08519c", name = "Probabilitas") +
    labs(title = paste("Transition Probability Matrix -", stock_name),
         x = "To State", y = "From State") +
    theme_thesis()
  save_plot_hd(p_tm, "Transition_Matrix_Heatmap", plots_dir, width = 6, height = 5)
  
  p_resid <- ggplot(residual_df, aes(x = Dates, y = Standardized_Residual)) +
    geom_line(color = "grey40", linewidth = 0.3) +
    geom_hline(yintercept = c(-2, 2), linetype = "dashed", color = "red") +
    labs(title = paste("Standardized Residual Plot -", stock_name),
         x = "Tanggal", y = "Standardized Residual") +
    theme_thesis()
  save_plot_hd(p_resid, "Residual_Plot", plots_dir)
  
  p_qq <- ggplot(residual_df, aes(sample = Standardized_Residual)) +
    stat_qq(color = "#1f78b4") +
    stat_qq_line(color = "red") +
    labs(title = paste("QQ Plot Standardized Residual -", stock_name),
         x = "Theoretical Quantiles", y = "Sample Quantiles") +
    theme_thesis()
  save_plot_hd(p_qq, "QQ_Plot_Residual", plots_dir)
  
  p_hist <- ggplot(residual_df, aes(x = Standardized_Residual)) +
    geom_histogram(aes(y = after_stat(density)), bins = 30, fill = "#1f78b4", color = "white", alpha = 0.8) +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "red", linewidth = 0.8) +
    labs(title = paste("Histogram Standardized Residual -", stock_name),
         x = "Standardized Residual", y = "Density") +
    theme_thesis()
  save_plot_hd(p_hist, "Histogram_Residual", plots_dir)
  
  cat(">> Seluruh visualisasi berhasil disimpan pada folder:", plots_dir, "\n")
  
  interpretation_text <- c(
    paste0("1. Model Markov Regime Switching Regression terbaik untuk ", stock_name,
           " adalah model dengan ", best_k, " regime, diestimasi menggunakan Direct Maximum Likelihood",
           " (optimisasi BFGS, multi-start) dan dipilih berdasarkan nilai BIC terkecil (",
           round(best_row$BIC, 3), ")."),
    paste0("2. Densitas emisi model FINAL yang terpilih (Model Selection berbasis BIC, Gaussian vs ",
           "Student-t): ", final_fit_distribution, ". ",
           if (isTRUE(use_student_t_full_mle)) {
             paste0("Detail perbandingan kedua kandidat model tersedia pada sheet 'Model Selection ",
                    "(Gauss vs T)' dan 'StudentT vs Gaussian'.")
           } else {
             paste0("Estimasi Student-t MLE PENUH dinonaktifkan pada konfigurasi ini (refactor ",
                    "performa) - Gaussian dipakai sebagai estimator utama; estimasi derajat ",
                    "kebebasan (nu) heavy-tail POST-HOC (informatif) tersedia pada sheet ",
                    "'PostHoc Student-t Nu'.")
           }),
    paste0("3. Log-likelihood akhir model = ", round(final_ll, 4),
           ", dengan AIC = ", round(final_aic, 3), ", BIC = ", round(final_bic, 3),
           ", dan HQIC = ", round(final_hqic, 3), "."),
    paste0("4. Expected duration tiap regime (dalam hari observasi): ",
           paste(paste0(duration_df$State, " = ", round(duration_df$Expected_Duration_Days, 2)), collapse = "; "), "."),
    paste0("5. Hasil uji Ljung-Box pada lag 10 menunjukkan: ", lb_table$Decision, "."),
    paste0("6. Hasil uji multikolinearitas menunjukkan variabel dengan VIF > 10 (indikasi tinggi): ",
           ifelse(any(vif_table$VIF > 10, na.rm = TRUE),
                  paste(vif_table$Variable[which(vif_table$VIF > 10)], collapse = ", "),
                  "TIDAK ADA (seluruh variabel independen bebas dari multikolinearitas tinggi).")),
    paste0("7. Status Hessian hasil optimisasi BFGS: ", hessian_status, "."),
    "8. Interpretasi lebih lanjut mengenai signifikansi koefisien tiap regime dapat dilihat pada sheet 'Wald Test' (H0: beta = 0), pengujian formal apakah pengaruh suatu variabel BERBEDA antar-regime dapat dilihat pada sheet 'Wald Test Regime Difference' (H0: koefisien sama antar-regime), dan klasifikasi kondisi pasar (Bull/Bear) dapat dilihat pada sheet 'Regime Classification'."
  )
  interp_df <- data.frame(Interpretasi = interpretation_text)
  openxlsx::addWorksheet(wb, "Interpretation")
  openxlsx::writeData(wb, "Interpretation", interp_df)
  
  excel_output_path <- file.path(output_dir, paste0("Output_MarkovRegimeSwitching_", stock_tag, ".xlsx"))
  openxlsx::saveWorkbook(wb, excel_output_path, overwrite = TRUE)
  cat(">> File Excel output berhasil disimpan:", excel_output_path, "\n")
  
  summary_path <- file.path(output_dir, paste0("Summary_", stock_tag, ".txt"))
  sink(summary_path)
  cat("================================================================\n")
  cat(" RINGKASAN HASIL ANALISIS MARKOV REGIME SWITCHING REGRESSION\n")
  cat(" (Direct Maximum Likelihood - BFGS | Model Final Terpilih:", final_fit_distribution, ")\n")
  cat(" Saham (Variabel Dependen):", stock_name, "\n")
  cat(" Tanggal analisis:", as.character(Sys.Date()), "\n")
  cat("================================================================\n\n")
  
  cat("1. RINGKASAN DATA\n")
  cat("-----------------\n")
  print(preprocessing_summary)
  cat("\n\n2. STATISTIK DESKRIPTIF\n")
  cat("-----------------\n")
  print(desc_table)
  cat("\n\n3. UJI STASIONERITAS\n")
  cat("-----------------\n")
  print(diff_order_summary)
  cat("\n\n4. UJI MULTIKOLINEARITAS (VIF)\n")
  cat("-----------------\n")
  print(vif_table)
  cat("\n\n5. MODEL REGIME K = 2 (2-STATE)\n")
  cat("-----------------\n")
  print(model_comparison)
  cat("\n\n5B. MODEL SELECTION (GAUSSIAN VS STUDENT-T)\n")
  cat("-----------------\n")
  print(model_selection_table)
  cat("\n\n6. MODEL TERPILIH & RINGKASAN\n")
  cat("-----------------\n")
  print(model_summary_df)
  cat("\n\n7. TRANSITION MATRIX & EXPECTED DURATION\n")
  cat("-----------------\n")
  print(trans_df)
  print(duration_df)
  cat("\n\n8. UJI LJUNG-BOX (AUTOKORELASI RESIDUAL)\n")
  cat("-----------------\n")
  print(lb_table)
  cat("\n\n9. INTERPRETASI RINGKAS\n")
  cat("-----------------\n")
  for (line in interpretation_text) cat("-", line, "\n")
  sink()
  
  cat(">> Summary.txt berhasil disimpan:", summary_path, "\n")
  
  cat("\n#####################################################################\n")
  cat("#  PIPELINE UNTUK SAHAM", stock_name, "SELESAI\n")
  cat("#####################################################################\n\n")
  
  return(list(
    excel_path = excel_output_path,
    summary_path = summary_path,
    best_k = best_k,
    final_fit = final_fit,
    sample_start_date  = stock_5d_metadata$sample_start_date,
    sample_end_date    = stock_5d_metadata$sample_end_date,
    n_obs_5d           = stock_5d_metadata$n_obs_5d,
    listing_start_date = stock_5d_metadata$listing_start_date,
    frequency          = stock_5d_metadata$frequency,
    aggregation_method = stock_5d_metadata$aggregation_method,
    best_subset            = best_subset_result,
    selected_variables      = selected_macro_cols,
    sector_classification   = sector_map_result$sector,
    mandatory_variables     = mandatory_vars_stock,
    ar_order_p              = ar_order_p
  ))
}

N_STARTS_MULTISTART <- 3

USE_STUDENT_T_FULL_MLE <- FALSE

shard_stocks <- if (PIPELINE_STAGE == "stocks") pipeline_shard_stocks(stock_targets, PIPELINE_SHARD_INDEX, PIPELINE_SHARD_COUNT) else stock_targets
if (PIPELINE_STAGE == "merge") {
  all_results <- pipeline_load_shards(PIPELINE_SHARD_DIR, stock_targets, PIPELINE_INPUT_MD5)
  cat(">> [STAGE merge]", length(stock_targets), "saham dirakit dari", length(attr(all_results, "shard_seconds")), "shard.\n")
} else {
  all_results <- list()

  N_CORES_STOCK_LOOP <- parallel::detectCores()
  cat(">> [REFACTOR - PERFORMA] Memparalelkan loop", length(stock_targets), "saham pada",
      N_CORES_STOCK_LOOP, "core dengan DYNAMIC LOAD BALANCING (future.apply) - pekerja yang",
      "selesai duluan langsung mengambil saham berikutnya, tidak menunggu batch statis...\n")

  # [OPTIMASI - LOAD BALANCING] future_lapply mendistribusikan tugas secara dinamis: setiap
  # worker meminta saham berikutnya begitu selesai, bukan dibagi rata di awal (statis). Ini
  # penting karena beban komputasi tiap saham berbeda-beda (tergantung jumlah variabel makro
  # terpilih & orde AR), jadi core tidak menganggur menunggu satu saham "berat" yang kebagian
  # ke satu worker saja. future.seed menjaga reproducibility RNG per-saham (setara doRNG).
  plan_ok <- tryCatch({
    future::plan(future::multisession, workers = N_CORES_STOCK_LOOP)
    TRUE
  }, error = function(e) { cat(">> future::plan() gagal:", conditionMessage(e), "\n"); FALSE })

  if (isTRUE(plan_ok)) {
    all_results_list <- tryCatch(
      future.apply::future_lapply(
        stock_targets,
        function(stock) {
          # [REFACTOR-SHARDING] keep the FULL list (=> original per-stock RNG stream) but skip stocks of other shards
          if (PIPELINE_STAGE == "stocks" && !(stock %in% shard_stocks)) return(NULL)
          tryCatch({
            run_pipeline(
              stock_name = stock,
              raw_data   = raw_data,
              macro_cols = macro_cols,
              date_col   = date_col,
              output_dir = output_dir,
              plots_root = plots_root,
              n_starts   = N_STARTS_MULTISTART,
              macro_processed_df = macro_processed_df,
              use_student_t_full_mle = USE_STUDENT_T_FULL_MLE,
              n_dup_global = n_dup, missing_summary_global = missing_summary
            )
          }, error = function(e) {
            cat("\n>> ERROR FATAL pada pipeline saham", stock, ":", conditionMessage(e), "\n")
            NULL
          })
        },
        future.seed = 123,
        future.globals = ls(envir = .GlobalEnv),
        future.packages = required_packages
      ),
      error = function(e) {
        cat(">> ERROR FATAL pada eksekusi paralel loop saham:", conditionMessage(e), "\n")
        NULL
      }
    )
    future::plan(future::sequential)
  
    if (!is.null(all_results_list)) {
      names(all_results_list) <- stock_targets
      all_results <- all_results_list
    }
  } else {
    warning("[REFACTOR] future::plan() gagal - fallback ke eksekusi saham SEKUENSIAL.")
    for (stock in stock_targets) {
      if (PIPELINE_STAGE == "stocks" && !(stock %in% shard_stocks)) next
      all_results[[stock]] <- tryCatch({
        run_pipeline(
          stock_name = stock,
          raw_data   = raw_data,
          macro_cols = macro_cols,
          date_col   = date_col,
          output_dir = output_dir,
          plots_root = plots_root,
          n_starts   = N_STARTS_MULTISTART,
          macro_processed_df = macro_processed_df,
          use_student_t_full_mle = USE_STUDENT_T_FULL_MLE,
          n_dup_global = n_dup, missing_summary_global = missing_summary
        )
      }, error = function(e) {
        cat("\n>> ERROR FATAL pada pipeline saham", stock, ":", conditionMessage(e), "\n")
        cat(">> Pipeline untuk saham lain (jika ada) akan tetap dilanjutkan.\n\n")
        NULL
      })
    }
  }

  if (PIPELINE_STAGE == "stocks") {
    if (is.null(names(all_results))) stop("[STAGE stocks] eksekusi paralel gagal total: tidak ada hasil.")
    pipeline_save_shard(PIPELINE_SHARD_DIR, PIPELINE_SHARD_INDEX, PIPELINE_SHARD_COUNT, stock_targets, all_results, PIPELINE_INPUT_MD5,
                        as.numeric(difftime(Sys.time(), .stage_t0, units = "secs")))
    n_ok <- sum(!vapply(all_results[shard_stocks], is.null, logical(1)))
    cat(">> [STAGE stocks] shard", PIPELINE_SHARD_INDEX, "/", PIPELINE_SHARD_COUNT, ":", n_ok, "dari", length(shard_stocks),
        "saham berhasil dalam", round(as.numeric(difftime(Sys.time(), .stage_t0, units = "mins")), 1), "menit.\n")
    quit(save = "no", status = if (n_ok == 0L) 2L else 0L)
  }
}

cat("\n\n=========================================================\n")
cat(" SELURUH ANALISIS SELESAI DILAKSANAKAN\n")
cat("=========================================================\n")
for (stock in names(all_results)) {
  if (!is.null(all_results[[stock]])) {
    cat("-", stock, ": Excel =", all_results[[stock]]$excel_path, "\n")
  } else {
    cat("-", stock, ": GAGAL - periksa log error di atas.\n")
  }
}
cat("\nSeluruh file Excel, folder Plots, dan Summary.txt tersimpan pada:\n", output_dir, "\n")

all_markov_models <- list()
for (stock in names(all_results)) {
  if (!is.null(all_results[[stock]]) && !is.null(all_results[[stock]]$final_fit)) {
    all_markov_models[[stock]] <- list(
      final_fit = all_results[[stock]]$final_fit,
      best_k    = all_results[[stock]]$best_k,
      sample_start_date  = all_results[[stock]]$sample_start_date,
      sample_end_date    = all_results[[stock]]$sample_end_date,
      n_obs_5d           = all_results[[stock]]$n_obs_5d,
      listing_start_date = all_results[[stock]]$listing_start_date,
      frequency          = all_results[[stock]]$frequency,
      aggregation_method = all_results[[stock]]$aggregation_method,
      selected_variables      = all_results[[stock]]$selected_variables,
      best_subset             = all_results[[stock]]$best_subset,
      sector_classification   = all_results[[stock]]$sector_classification,
      mandatory_variables      = all_results[[stock]]$mandatory_variables,
      ar_order_p               = all_results[[stock]]$ar_order_p
    )
  }
}

for (stock in names(all_markov_models)) {
  sv_check <- all_markov_models[[stock]]$selected_variables
  if (is.null(sv_check) || length(sv_check) == 0) {
    stop("[BEST SUBSET] Model Markov untuk saham '", stock, "' TIDAK memiliki metadata ",
         "selected_variables yang valid - hentikan penyimpanan All_Markov_Models.rds daripada ",
         "mengizinkan Monte Carlo fallback diam-diam ke seluruh macro variables.")
  }
  if (length(sv_check) < 4 || !("JCI Index" %in% sv_check)) {
    stop("[BEST SUBSET] Model Markov untuk saham '", stock, "' TIDAK memenuhi constraint minimum ",
         "4 variabel/JCI Index wajib - periksa kembali best_subset_selection_constrained().")
  }
}

if (length(all_markov_models) > 0) {
  all_markov_models_path <- file.path(output_dir, "All_Markov_Models.rds")
  saveRDS(all_markov_models, all_markov_models_path)
  cat(">> [MONTE CARLO] Seluruh model Markov Switching (", length(all_markov_models),
      "dari", length(all_results), "saham) berhasil diringkas & disimpan sebagai",
      "SATU objek tunggal (termasuk metadata selected_variables per saham):\n   ",
      all_markov_models_path, "\n")
} else {
  cat(">> [MONTE CARLO] PERINGATAN: Tidak ada model Markov Switching yang berhasil",
      "diestimasi - modul Monte Carlo Bagian 7 TIDAK dapat dijalankan.\n")
}

bs_agg_rows <- list()
for (stock in names(all_results)) {
  res_s <- all_results[[stock]]
  if (is.null(res_s)) next
  bs_s <- res_s$best_subset
  sel_s <- res_s$selected_variables
  bs_agg_rows[[stock]] <- data.frame(
    Stock = stock,
    Sector_Classification = if (!is.null(res_s$sector_classification)) res_s$sector_classification else NA,
    Mandatory_Variables = if (!is.null(res_s$mandatory_variables)) paste(res_s$mandatory_variables, collapse = ", ") else "-",
    N_Candidate_Variables = if (!is.null(bs_s)) bs_s$n_candidate else NA,
    Selected_Variables = if (!is.null(sel_s) && length(sel_s) > 0) paste(sel_s, collapse = ", ") else "-",
    N_Selected = if (!is.null(sel_s)) length(sel_s) else NA,
    BIC = if (!is.null(bs_s)) bs_s$bic else NA,
    SSE = if (!is.null(bs_s)) bs_s$sse else NA,
    AR_Order_p = if (!is.null(res_s$ar_order_p)) res_s$ar_order_p else NA,
    Status = if (!is.null(bs_s)) bs_s$selection_status else "GAGAL - pipeline tidak menghasilkan hasil",
    stringsAsFactors = FALSE
  )
}
if (length(bs_agg_rows) > 0) {
  bs_agg_table <- do.call(rbind, bs_agg_rows)
  rownames(bs_agg_table) <- NULL
  wb_bs_agg <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb_bs_agg, "Best Subset - All Stocks")
  openxlsx::writeData(wb_bs_agg, "Best Subset - All Stocks", bs_agg_table)
  openxlsx::writeData(wb_bs_agg, "Best Subset - All Stocks", data.frame(
    Catatan = paste0("Ringkasan agregat hasil constrained Best Subset Selection (BIC minimum, minimum 4 ",
                     "variabel, JCI Index wajib, sector-specific mandatory factor wajib) untuk seluruh ",
                     nrow(bs_agg_table), " saham - setiap saham diseleksi SECARA INDEPENDEN (subset dapat ",
                     "berbeda antar-emiten). Detail lengkap constrained subset space per-saham tersedia ",
                     "pada sheet 'Best Subset Selection' di workbook masing-masing saham.")),
    startRow = nrow(bs_agg_table) + 3)
  bs_agg_path <- file.path(output_dir, "Output_BestSubsetSelection_AllStocks.xlsx")
  openxlsx::saveWorkbook(wb_bs_agg, bs_agg_path, overwrite = TRUE)
  cat(">> [BEST SUBSET] Ringkasan agregat variable selection seluruh saham disimpan:\n   ", bs_agg_path, "\n")
}

mc_load_estimation_objects <- function(output_dir) {
  jd <- if (exists("joint_distribution_model", envir = .GlobalEnv)) {
    cat(">> [LOADER] Joint Distribution F(X) dibaca dari OBJEK IN-MEMORY (sesi saat ini).\n")
    get("joint_distribution_model", envir = .GlobalEnv)
  } else {
    jd_path <- file.path(output_dir, "JointDistribution_Model.rds")
    if (!file.exists(jd_path)) {
      stop("File 'JointDistribution_Model.rds' tidak ditemukan pada: ", output_dir,
           " - pastikan Bagian 4C (DCC-GARCH & Copula) telah berhasil dijalankan.")
    }
    cat(">> [LOADER] Joint Distribution F(X) dibaca dari file:", jd_path, "\n")
    readRDS(jd_path)
  }
  
  mm <- if (exists("all_markov_models", envir = .GlobalEnv) &&
            length(get("all_markov_models", envir = .GlobalEnv)) > 0) {
    cat(">> [LOADER] Model Markov Switching (45 saham) dibaca dari OBJEK IN-MEMORY (sesi saat ini).\n")
    get("all_markov_models", envir = .GlobalEnv)
  } else {
    mm_path <- file.path(output_dir, "All_Markov_Models.rds")
    if (!file.exists(mm_path)) {
      stop("File 'All_Markov_Models.rds' tidak ditemukan pada: ", output_dir,
           " - pastikan Bagian 5/6 (Markov Switching seluruh saham) telah berhasil dijalankan.")
    }
    cat(">> [LOADER] Model Markov Switching (45 saham) dibaca dari file:", mm_path, "\n")
    readRDS(mm_path)
  }
  
  list(joint_dist = jd, markov_models = mm)
}

mc_conditional_copula_sample <- function(N, tcop_fit, d, shock_idx, shock_u) {
  cop_obj <- tryCatch({
    if (methods::is(tcop_fit, "fitCopula")) tcop_fit@copula else tcop_fit
  }, error = function(e) tcop_fit)
  
  other_idx <- setdiff(seq_len(d), shock_idx)
  
  U <- matrix(NA_real_, nrow = N, ncol = d)
  for (j in seq_along(shock_idx)) U[, shock_idx[j]] <- shock_u[j]
  U[, other_idx] <- matrix(stats::runif(N * length(other_idx)), nrow = N)
  
  U_cond <- tryCatch(
    copula::cCopula(U, indices = other_idx, copula = cop_obj, inverse = TRUE),
    error = function(e) {
      cat("   >> [PERINGATAN] copula::cCopula() gagal dieksekusi (", conditionMessage(e),
          ") - fallback ke metode Acceptance-Rejection (10x oversampling)...\n")
      NULL
    }
  )
  
  if (!is.null(U_cond) && !anyNA(U_cond)) {
    U[, other_idx] <- U_cond
    return(pmin(pmax(U, 1e-6), 1 - 1e-6))
  }
  
  n_try <- N * 10
  raw <- tryCatch(copula::rCopula(n_try, cop_obj), error = function(e) NULL)
  if (is.null(raw)) {
    stop("Sampling Student-t Copula GAGAL TOTAL (baik cCopula() maupun rCopula() gagal) - ",
         "periksa kembali objek copula_terbaik$fit pada JointDistribution_Model.rds.")
  }
  if (length(shock_idx) == 1) {
    dist_to_shock <- abs(raw[, shock_idx] - shock_u)
  } else {
    target_mat <- matrix(shock_u, nrow = n_try, ncol = length(shock_idx), byrow = TRUE)
    dist_to_shock <- sqrt(rowSums((raw[, shock_idx, drop = FALSE] - target_mat)^2))
  }
  keep <- order(dist_to_shock)[seq_len(min(N, n_try))]
  U_fb <- raw[keep, , drop = FALSE]
  for (j in seq_along(shock_idx)) U_fb[, shock_idx[j]] <- shock_u[j]
  if (nrow(U_fb) < N) {
    extra_idx <- sample(seq_len(nrow(U_fb)), N - nrow(U_fb), replace = TRUE)
    U_fb <- rbind(U_fb, U_fb[extra_idx, , drop = FALSE])
  }
  pmin(pmax(U_fb, 1e-6), 1 - 1e-6)
}

mc_resolve_name <- function(target, available) {
  if (target %in% available) return(target)
  norm_target <- trimws(tolower(target))
  norm_avail  <- trimws(tolower(available))
  idx <- match(norm_target, norm_avail)
  if (!is.na(idx)) return(available[idx])
  NA_character_
}

mc_uniform_to_macro_returns <- function(U, marginal_models, macro_cols) {
  N <- nrow(U)
  d <- length(macro_cols)
  macro_ret <- matrix(NA_real_, nrow = N, ncol = d)
  colnames(macro_ret) <- macro_cols
  
  avail_marginal_names <- names(marginal_models)
  not_found_vars <- character(0)
  
  for (j in seq_len(d)) {
    vname <- macro_cols[j]
    resolved_name <- mc_resolve_name(vname, avail_marginal_names)
    mdl <- if (!is.na(resolved_name)) marginal_models[[resolved_name]] else NULL
    
    if (is.null(mdl)) {
      not_found_vars <- c(not_found_vars, vname)
      u_j <- pmin(pmax(U[, j], 1e-6), 1 - 1e-6)
      macro_ret[, j] <- stats::qnorm(u_j)
      next
    }
    u_j <- pmin(pmax(U[, j], 1e-6), 1 - 1e-6)
    
    if (isTRUE(mdl$garch_used) && !is.null(mdl$garch_fit_object)) {
      fc <- tryCatch(rugarch::ugarchforecast(mdl$garch_fit_object, n.ahead = 1), error = function(e) NULL)
      if (!is.null(fc)) {
        mu_fc    <- as.numeric(rugarch::fitted(fc))[1]
        sigma_fc <- as.numeric(rugarch::sigma(fc))[1]
        cf <- tryCatch(rugarch::coef(mdl$garch_fit_object), error = function(e) NULL)
        skew_par  <- if (!is.null(cf) && "skew" %in% names(cf)) unname(cf["skew"]) else 1
        shape_par <- if (!is.null(cf) && "shape" %in% names(cf)) unname(cf["shape"]) else 5
        z_j <- tryCatch(
          rugarch::qdist(distribution = mdl$garch_distribution, p = u_j,
                         mu = 0, sigma = 1, skew = skew_par, shape = shape_par),
          error = function(e) stats::qnorm(u_j)
        )
        macro_ret[, j] <- mu_fc + sigma_fc * z_j
      } else {
        sdx <- if (!is.null(mdl$residual_sd_arma_only) && is.finite(mdl$residual_sd_arma_only)) {
          mdl$residual_sd_arma_only
        } else 1
        macro_ret[, j] <- stats::qnorm(u_j, mean = 0, sd = sdx)
      }
    } else {
      mu_fc <- tryCatch({
        p_arma <- stats::predict(mdl$arma_fit_object, n.ahead = 1)
        as.numeric(p_arma$pred)[1]
      }, error = function(e) 0)
      sdx <- if (!is.null(mdl$residual_sd_arma_only) && is.finite(mdl$residual_sd_arma_only)) {
        mdl$residual_sd_arma_only
      } else 1
      macro_ret[, j] <- mu_fc + sdx * stats::qnorm(u_j)
    }
  }
  
  if (length(not_found_vars) > 0) {
    cat("\n   >> !!! [PERINGATAN PENTING] Model marginal ARMA-GARCH TIDAK ditemukan untuk",
        length(not_found_vars), "dari", d, "variabel makro: [", paste(not_found_vars, collapse = "; "), "]\n")
    cat("   >> Kolom tersebut memakai fallback qnorm() standar (BUKAN model ARMA-GARCH asli variabel",
        "tersebut) - hasil untuk variabel ini KURANG AKURAT. Nama variabel pada 'marginal_models'",
        "tersedia:", paste(avail_marginal_names, collapse = "; "), "\n")
    cat("   >> Periksa apakah JointDistribution_Model.rds berasal dari RUN YANG SAMA dengan macro_cols",
        "saat ini (mis. Bagian 4C dijalankan ulang dengan variabel makro yang berbeda tanpa",
        "memperbarui file .rds) - lih. dokumentasi mc_load_estimation_objects().\n\n")
  }
  
  macro_ret
}

mc_shock_to_quantile <- function(shock_value_pct, var_name, marginal_models) {
  resolved_name <- mc_resolve_name(var_name, names(marginal_models))
  mdl <- if (!is.na(resolved_name)) marginal_models[[resolved_name]] else NULL
  if (is.null(mdl)) {
    cat("   >> !!! [PERINGATAN PENTING] Model marginal untuk variabel shock '", var_name,
        "' TIDAK ditemukan - konversi shock->quantile memakai fallback pnorm() netral (kurang akurat).",
        " Nama tersedia:", paste(names(marginal_models), collapse = "; "), "\n")
    return(0.5)
  }
  
  shock_dec <- shock_value_pct / 100
  hist_series <- mdl$work_series
  mu_hist <- mean(hist_series, na.rm = TRUE)
  sd_hist <- stats::sd(hist_series, na.rm = TRUE)
  if (!is.finite(sd_hist) || sd_hist <= 0) sd_hist <- 1
  z <- (shock_dec - mu_hist) / sd_hist
  
  u <- if (isTRUE(mdl$garch_used) && !is.null(mdl$garch_fit_object)) {
    cf <- tryCatch(rugarch::coef(mdl$garch_fit_object), error = function(e) NULL)
    skew_par  <- if (!is.null(cf) && "skew" %in% names(cf)) unname(cf["skew"]) else 1
    shape_par <- if (!is.null(cf) && "shape" %in% names(cf)) unname(cf["shape"]) else 5
    tryCatch(
      rugarch::pdist(distribution = mdl$garch_distribution, q = z, mu = 0, sigma = 1,
                     skew = skew_par, shape = shape_par),
      error = function(e) stats::pnorm(z)
    )
  } else {
    stats::pnorm(z)
  }
  min(max(u, 1e-6), 1 - 1e-6)
}

mc_predict_stock <- function(macro_ret, final_fit, use_significant, alpha) {
  beta_mat <- final_fit$beta_mat
  se_beta  <- final_fit$se_beta
  coef_names <- final_fit$coef_names
  k <- ncol(beta_mat)
  n_params <- nrow(beta_mat)
  
  if (isTRUE(use_significant)) {
    beta_use <- beta_mat
    for (i in seq_len(k)) {
      se_i <- se_beta[, i]
      z_i  <- ifelse(!is.na(se_i) & se_i > 0, beta_mat[, i] / se_i, NA)
      p_i  <- ifelse(!is.na(z_i), 2 * (1 - stats::pnorm(abs(z_i))), NA)
      not_sig <- is.na(p_i) | p_i >= alpha
      beta_use[not_sig, i] <- 0
    }
  } else {
    beta_use <- beta_mat
  }
  
  lag_cols_ff <- if (!is.null(final_fit$lag_cols)) final_fit$lag_cols else character(0)
  n_sim_local <- nrow(macro_ret)
  macro_cols_avail <- colnames(macro_ret)
  
  X_mc <- matrix(NA_real_, nrow = n_sim_local, ncol = n_params)
  colnames(X_mc) <- coef_names
  
  for (j in seq_len(n_params)) {
    nm       <- coef_names[j]
    nm_clean <- gsub("^`|`$", "", nm)
    
    if (nm_clean == "(Intercept)") {
      X_mc[, j] <- 1
    } else if (nm_clean %in% lag_cols_ff) {
      lag_val <- final_fit$last_actual_lags[[nm_clean]]
      if (is.null(lag_val) || length(lag_val) != 1 || !is.finite(lag_val)) {
        stop("mc_predict_stock(): nilai actual lag '", nm_clean, "' tidak tersedia/tidak valid pada ",
             "final_fit$last_actual_lags - Monte Carlo untuk model MS-AR ini tidak dapat dijalankan.")
      }
      X_mc[, j] <- lag_val
    } else if (nm_clean %in% macro_cols_avail) {
      X_mc[, j] <- macro_ret[, nm_clean]
    } else {
      stop("mc_predict_stock(): predictor '", nm_clean, "' pada final_fit$coef_names tidak ditemukan ",
           "pada macro_ret (variabel makro skenario) maupun daftar lag AR (final_fit$lag_cols) - ",
           "design matrix Monte Carlo tidak dapat dibentuk secara konsisten dengan model final.")
    }
  }
  
  if (ncol(X_mc) != nrow(beta_use)) {
    stop("mc_predict_stock(): jumlah kolom X_mc (", ncol(X_mc), ") tidak sama dengan jumlah baris ",
         "final_fit$beta_mat (", nrow(beta_use), ").")
  }
  if (!identical(colnames(X_mc), coef_names)) {
    stop("mc_predict_stock(): nama/urutan kolom X_mc tidak identik dengan final_fit$coef_names.")
  }
  if (anyNA(X_mc) || any(!is.finite(X_mc))) {
    stop("mc_predict_stock(): terdapat NA/Inf pada predictor X_mc sebelum matrix multiplication - ",
         "prediksi Monte Carlo dibatalkan untuk saham ini.")
  }
  
  return_per_regime <- X_mc %*% beta_use
  
  w <- final_fit$smo_prob[nrow(final_fit$smo_prob), ]
  w <- w / sum(w)
  
  list(expected_return = as.numeric(return_per_regime %*% w),
       return_per_regime = return_per_regime, weights = w)
}

mc_summarize_stock <- function(ret_vec) {
  c(
    ExpectedReturn_pct = mean(ret_vec, na.rm = TRUE) * 100,
    StdDev_pct          = stats::sd(ret_vec, na.rm = TRUE) * 100,
    VaR5_pct             = stats::quantile(ret_vec, probs = 0.05, na.rm = TRUE, names = FALSE) * 100,
    ProbLoss_pct         = mean(ret_vec < 0, na.rm = TRUE) * 100
  )
}

mc_run_scenario <- function(shock_vars, shock_values, n_sim, use_significant, alpha,
                            estimation_objects, output_dir, seed = 123) {
  
  jd <- estimation_objects$joint_dist
  mm <- estimation_objects$markov_models
  macro_cols <- jd$variabel_makro
  d <- length(macro_cols)
  marginal_models <- jd$marginal_models
  tcop_fit <- jd$copula_terbaik$fit
  
  shock_idx <- match(shock_vars, macro_cols)
  if (any(is.na(shock_idx))) {
    stop("Variabel shock tidak ditemukan pada daftar variabel makro: ",
         paste(shock_vars[is.na(shock_idx)], collapse = ", "))
  }
  
  shock_u <- vapply(seq_along(shock_vars), function(j) {
    mc_shock_to_quantile(shock_values[j], shock_vars[j], marginal_models)
  }, numeric(1))
  
  cat("\n>> [SKENARIO] Variabel di-shock       :", paste(shock_vars, collapse = ", "), "\n")
  cat(">> [SKENARIO] Nilai shock (% return)   :", paste(shock_values, collapse = ", "), "\n")
  cat(">> [SKENARIO] Quantile copula (hasil konversi):", paste(round(shock_u, 4), collapse = ", "), "\n")
  cat(">> [SKENARIO] Jumlah simulasi           :", n_sim, "| Random seed:", seed, "\n\n")
  
  set.seed(seed)
  cat(">> Tahap 1/3: Sampling kondisional Student-t Copula (", n_sim, "iterasi)...\n")
  U <- mc_conditional_copula_sample(n_sim, tcop_fit, d, shock_idx, shock_u)
  
  cat(">> Tahap 2/3: Transformasi Uniform -> Return Makro Aktual (inverse CDF marginal)...\n")
  macro_ret <- mc_uniform_to_macro_returns(U, marginal_models, macro_cols)
  for (j in seq_along(shock_idx)) macro_ret[, shock_idx[j]] <- shock_values[j] / 100
  colnames(macro_ret) <- macro_cols
  
  other_idx_check <- setdiff(seq_along(macro_cols), shock_idx)
  if (length(other_idx_check) > 0) {
    sd_other <- apply(macro_ret[, other_idx_check, drop = FALSE], 2, stats::sd)
    degenerate_vars <- macro_cols[other_idx_check][sd_other < 1e-12 | !is.finite(sd_other)]
    if (length(degenerate_vars) > 0) {
      cat("\n>> !!! [PERINGATAN KRITIS] Variabel makro berikut memiliki variansi ~0 antar-simulasi",
          "(TIDAK BERUBAH sama sekali walau di-shock/skenario berbeda):",
          paste(degenerate_vars, collapse = ", "), "\n")
      cat(">> Ini KEMUNGKINAN BESAR menyebabkan Expected Return/Std Dev/VaR SELALU SAMA berapa pun",
          "skenarionya. Periksa: (1) apakah JointDistribution_Model.rds konsisten dengan macro_cols",
          "saat ini, (2) log 'PERINGATAN PENTING' di atas terkait model marginal yang tidak ditemukan.\n\n")
    }
  }
  
  cat(">> Tahap 3/3: Prediksi return", length(mm), "saham (paralel, model Markov Switching)...\n")
  
  stock_names <- names(mm)
  n_cores <- max(1, parallel::detectCores() - 1)
  cl <- tryCatch(parallel::makeCluster(n_cores), error = function(e) NULL)
  
  run_one_stock <- function(sname, mm_local, macro_ret_local, use_significant_local, alpha_local, macro_cols_ref) {
    tryCatch({
      ff <- mm_local[[sname]]$final_fit
      if (is.null(ff)) stop("final_fit tidak tersedia")
      lag_cols_ff <- if (!is.null(ff$lag_cols)) ff$lag_cols else character(0)
      coef_macro  <- setdiff(ff$coef_names[-1], lag_cols_ff)
      avail_cols  <- colnames(macro_ret_local)
      
      exact_ok <- all(coef_macro %in% avail_cols)
      
      if (exact_ok) {
        mr <- macro_ret_local[, coef_macro, drop = FALSE]
      } else {
        coef_macro_norm <- trimws(tolower(coef_macro))
        avail_norm      <- trimws(tolower(avail_cols))
        match_idx <- match(coef_macro_norm, avail_norm)
        
        if (!anyNA(match_idx)) {
          mr <- macro_ret_local[, avail_cols[match_idx], drop = FALSE]
          colnames(mr) <- coef_macro
        } else if (length(coef_macro) == length(macro_cols_ref) &&
                   identical(sort(trimws(tolower(macro_cols_ref))), sort(avail_norm))) {
          mr <- macro_ret_local[, macro_cols_ref, drop = FALSE]
          colnames(mr) <- coef_macro
          warning(paste0("Nama variabel makro TIDAK cocok persis untuk saham ", sname,
                         " - dipetakan berdasarkan URUTAN (fallback). Periksa kembali penulisan",
                         " nama variabel (spasi/huruf besar-kecil) pada model_df/macro_cols."))
        } else {
          missing_vars <- setdiff(coef_macro, avail_cols)
          stop(paste0("Variabel makro pada model saham TIDAK LENGKAP pada matriks simulasi - ",
                      "variabel yang tidak ditemukan: [", paste(missing_vars, collapse = "; "),
                      "]. Variabel tersedia pada skenario: [", paste(avail_cols, collapse = "; "), "]."))
        }
      }
      
      pred <- mc_predict_stock(mr, ff, use_significant_local, alpha_local)
      list(ok = TRUE, value = pred$expected_return,
           yesterday_close = if (!is.null(ff$yesterday_close_price)) ff$yesterday_close_price else NA_real_,
           ar_order = if (!is.null(ff$ar_order)) ff$ar_order else 0L)
    }, error = function(e) list(ok = FALSE, error = conditionMessage(e)))
  }
  
  if (!is.null(cl)) {
    doParallel::registerDoParallel(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    cat("   >> Eksekusi PARALEL pada", n_cores, "core...\n")
    res_list <- foreach::foreach(
      sname = stock_names,
      .export = c("mc_predict_stock"),
      .packages = c("stats")
    ) %dopar% {
      run_one_stock(sname, mm, macro_ret, use_significant, alpha, macro_cols)
    }
  } else {
    warning("[MONTE CARLO] parallel::makeCluster() gagal - fallback ke eksekusi sekuensial.")
    pb <- utils::txtProgressBar(min = 0, max = length(stock_names), style = 3)
    res_list <- vector("list", length(stock_names))
    for (i in seq_along(stock_names)) {
      res_list[[i]] <- run_one_stock(stock_names[i], mm, macro_ret, use_significant, alpha, macro_cols)
      utils::setTxtProgressBar(pb, i)
    }
    close(pb)
  }
  
  result_matrix <- matrix(NA_real_, nrow = n_sim, ncol = length(stock_names))
  colnames(result_matrix) <- stock_names
  failed_stocks <- character(0)
  yesterday_close_vec <- stats::setNames(rep(NA_real_, length(stock_names)), stock_names)
  ar_order_vec         <- stats::setNames(rep(NA_integer_, length(stock_names)), stock_names)
  
  for (i in seq_along(stock_names)) {
    r <- res_list[[i]]
    if (is.null(r) || !isTRUE(r$ok)) {
      cat("   >> [PERINGATAN] Saham", stock_names[i], "DILEWATI:",
          if (!is.null(r$error)) r$error else "hasil tidak valid", "\n")
      failed_stocks <- c(failed_stocks, stock_names[i])
    } else {
      result_matrix[, i] <- r$value
      yesterday_close_vec[stock_names[i]] <- r$yesterday_close
      ar_order_vec[stock_names[i]]        <- r$ar_order
    }
  }
  
  valid_stocks <- setdiff(stock_names, failed_stocks)
  if (length(valid_stocks) == 0) stop("SELURUH saham gagal diprediksi pada skenario ini.")
  result_matrix <- result_matrix[, valid_stocks, drop = FALSE]
  
  ranking_table <- do.call(rbind, lapply(valid_stocks, function(s) {
    stat <- mc_summarize_stock(result_matrix[, s])
    data.frame(Kode_Saham = s,
               Yesterday_Close_Price = unname(yesterday_close_vec[s]),
               ExpectedReturn_pct = unname(stat["ExpectedReturn_pct"]),
               StdDev_pct = unname(stat["StdDev_pct"]),
               VaR5_pct = unname(stat["VaR5_pct"]),
               ProbLoss_pct = unname(stat["ProbLoss_pct"]),
               AR_Order = unname(ar_order_vec[s]),
               stringsAsFactors = FALSE)
  }))
  rownames(ranking_table) <- NULL
  ranking_table <- ranking_table[order(-ranking_table$ExpectedReturn_pct), ]
  ranking_table$Rank <- seq_len(nrow(ranking_table))
  ranking_table <- ranking_table[, c("Rank", "Kode_Saham", "Yesterday_Close_Price", "ExpectedReturn_pct",
                                     "StdDev_pct", "VaR5_pct", "ProbLoss_pct", "AR_Order")]
  
  list(result_matrix = result_matrix, ranking_table = ranking_table,
       failed_stocks = failed_stocks, shock_vars = shock_vars,
       shock_values = shock_values, n_sim = n_sim, use_significant = use_significant,
       alpha = alpha, seed = seed)
}

mc_export_scenario <- function(scenario_result, output_dir) {
  shock_tag <- paste(mapply(function(v, val) {
    paste0(gsub("[^A-Za-z0-9]", "", v), "_", ifelse(val >= 0, "+", ""), val, "pct")
  }, scenario_result$shock_vars, scenario_result$shock_values), collapse = "_")
  
  ts_tag <- format(Sys.time(), "%Y%m%d_%H%M%S")
  base_name <- paste0("Shock_", shock_tag, "_", ts_tag)
  
  mc_dir <- file.path(output_dir, "MonteCarlo")
  if (!dir.exists(mc_dir)) dir.create(mc_dir, recursive = TRUE)
  
  rds_path <- file.path(mc_dir, paste0(base_name, "_RawMatrix.rds"))
  saveRDS(scenario_result$result_matrix, rds_path)
  
  wb_mc <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb_mc, "Ranking")
  openxlsx::writeData(wb_mc, "Ranking", scenario_result$ranking_table)
  
  top5 <- utils::head(scenario_result$ranking_table, 5)
  bot5 <- utils::tail(scenario_result$ranking_table, 5)
  openxlsx::addWorksheet(wb_mc, "Top5 & Bottom5")
  openxlsx::writeData(wb_mc, "Top5 & Bottom5",
                      data.frame(Kategori = "5 SAHAM EXPECTED RETURN TERTINGGI"), startRow = 1)
  openxlsx::writeData(wb_mc, "Top5 & Bottom5", top5, startRow = 2)
  openxlsx::writeData(wb_mc, "Top5 & Bottom5",
                      data.frame(Kategori = "5 SAHAM EXPECTED RETURN TERENDAH (PALING BERISIKO)"),
                      startRow = nrow(top5) + 5)
  openxlsx::writeData(wb_mc, "Top5 & Bottom5", bot5, startRow = nrow(top5) + 6)
  
  if (length(scenario_result$failed_stocks) > 0) {
    openxlsx::addWorksheet(wb_mc, "Saham Gagal")
    openxlsx::writeData(wb_mc, "Saham Gagal", data.frame(Kode_Saham = scenario_result$failed_stocks))
  }
  
  openxlsx::addWorksheet(wb_mc, "Skenario")
  openxlsx::writeData(wb_mc, "Skenario", data.frame(
    Variabel_Shock  = paste(scenario_result$shock_vars, collapse = ", "),
    Nilai_Shock_pct = paste(scenario_result$shock_values, collapse = ", "),
    Jumlah_Simulasi = scenario_result$n_sim,
    Random_Seed     = scenario_result$seed,
    Koef_Signifikan_Saja = scenario_result$use_significant,
    Alpha           = scenario_result$alpha,
    Tanggal         = as.character(Sys.time()),
    stringsAsFactors = FALSE
  ))
  
  xlsx_path <- file.path(mc_dir, paste0(base_name, "_Results.xlsx"))
  openxlsx::saveWorkbook(wb_mc, xlsx_path, overwrite = TRUE)
  
  csv_path <- file.path(mc_dir, paste0(base_name, "_Ranking.csv"))
  utils::write.csv(scenario_result$ranking_table, csv_path, row.names = FALSE)
  
  txt_path <- file.path(mc_dir, paste0(base_name, "_Summary.txt"))
  sink(txt_path)
  cat("================================================================\n")
  cat(" RINGKASAN SKENARIO MONTE CARLO STRESS TESTING\n")
  cat(" Tanggal :", as.character(Sys.time()), "\n")
  cat("================================================================\n\n")
  cat("Variabel Shock   :", paste(scenario_result$shock_vars, collapse = ", "), "\n")
  cat("Nilai Shock (%)  :", paste(scenario_result$shock_values, collapse = ", "), "\n")
  cat("Jumlah Simulasi  :", scenario_result$n_sim, "\n")
  cat("Random Seed      :", scenario_result$seed, "\n")
  cat("Koef. Signifikan Saja:", scenario_result$use_significant,
      "(alpha =", scenario_result$alpha, ")\n\n")
  cat("TABEL RANKING SAHAM\n"); print(scenario_result$ranking_table); cat("\n")
  if (length(scenario_result$failed_stocks) > 0) {
    cat("SAHAM DILEWATI (gagal diprediksi):", paste(scenario_result$failed_stocks, collapse = ", "), "\n")
  }
  sink()
  
  cat("\n>> [EKSPOR] Hasil skenario disimpan:\n")
  cat("   - Excel   :", xlsx_path, "\n")
  cat("   - CSV     :", csv_path, "\n")
  cat("   - RDS     :", rds_path, "\n")
  cat("   - Summary :", txt_path, "\n")
  
  invisible(list(xlsx_path = xlsx_path, csv_path = csv_path, rds_path = rds_path,
                 txt_path = txt_path, mc_dir = mc_dir))
}

mc_plot_stock_distribution <- function(scenario_result, stock_code, output_dir) {
  if (!(stock_code %in% colnames(scenario_result$result_matrix))) {
    cat(">> [PERINGATAN] Kode saham '", stock_code, "' tidak ditemukan pada hasil simulasi",
        "(mungkin salah ketik atau saham tersebut gagal/dilewati pada skenario ini).\n")
    return(invisible(NULL))
  }
  ret_vec <- scenario_result$result_matrix[, stock_code] * 100
  
  plot_dir <- file.path(output_dir, "Plots", "MonteCarlo")
  if (!dir.exists(plot_dir)) dir.create(plot_dir, recursive = TRUE)
  
  df_plot <- data.frame(Return = ret_vec)
  
  p_hist <- ggplot2::ggplot(df_plot, ggplot2::aes(x = Return)) +
    ggplot2::geom_histogram(ggplot2::aes(y = ggplot2::after_stat(density)),
                            bins = 60, fill = "#1f78b4", color = "white", alpha = 0.85) +
    ggplot2::geom_density(color = "#e31a1c", linewidth = 0.8) +
    ggplot2::geom_vline(xintercept = mean(ret_vec), linetype = "dashed", color = "black") +
    ggplot2::labs(title = paste("Distribusi Return Simulasi -", stock_code),
                  subtitle = paste("Skenario shock:", paste(scenario_result$shock_vars, collapse = ", ")),
                  x = "Return (%)", y = "Density") +
    ggplot2::theme_minimal(base_size = 12)
  
  p_qq <- ggplot2::ggplot(df_plot, ggplot2::aes(sample = Return)) +
    ggplot2::stat_qq(color = "#1f78b4") + ggplot2::stat_qq_line(color = "#e31a1c") +
    ggplot2::labs(title = paste("QQ Plot Return Simulasi -", stock_code),
                  x = "Theoretical Quantiles", y = "Sample Quantiles") +
    ggplot2::theme_minimal(base_size = 12)
  
  ts_tag <- format(Sys.time(), "%Y%m%d_%H%M%S")
  hist_path <- file.path(plot_dir, paste0("Histogram_", stock_code, "_", ts_tag, ".png"))
  qq_path   <- file.path(plot_dir, paste0("QQPlot_", stock_code, "_", ts_tag, ".png"))
  ggplot2::ggsave(hist_path, p_hist, width = 8, height = 5, dpi = 150)
  ggplot2::ggsave(qq_path, p_qq, width = 8, height = 5, dpi = 150)
  
  print(p_hist)
  
  cat(">> [PLOT] Histogram & QQ Plot disimpan:\n   -", hist_path, "\n   -", qq_path, "\n")
  invisible(list(hist_path = hist_path, qq_path = qq_path))
}

mc_ask_yes_no <- function(prompt_text, default = FALSE) {
  repeat {
    ans <- tolower(trimws(readline(prompt_text)))
    if (ans %in% c("y", "yes", "ya")) return(TRUE)
    if (ans %in% c("n", "no", "tidak")) return(FALSE)
    if (ans == "") return(default)
    cat("   >> Input tidak dikenali - ketik 'yes' atau 'no'.\n")
  }
}

mc_run_interactive <- function(output_dir) {
  cat("\n#####################################################################\n")
  cat("#  MODUL CONDITIONAL MONTE CARLO STRESS TESTING - MARKOV SWITCHING   #\n")
  cat("#  (model SUDAH terestimasi - modul ini TIDAK mengestimasi ulang)    #\n")
  cat("#####################################################################\n\n")
  cat(">> [PENTING] Modul ini memakai readline() untuk input interaktif. Jalankan SELURUH\n")
  cat("   script via tombol 'Source' RStudio atau source('Coba_Markov.R') - JANGAN copy-paste\n")
  cat("   seluruh isi file langsung ke Console, karena baris-baris SISA di clipboard akan\n")
  cat("   ikut 'dibaca' sebagai jawaban readline() (menyebabkan prompt & jawaban tampak\n")
  cat("   tertukar/kacau seperti '################...' muncul sebagai jawaban). Apabila hal\n")
  cat("   ini terjadi, ketik 'stop' pada prompt manapun untuk keluar, lalu jalankan ULANG\n")
  cat("   HANYA mc_run_interactive(output_dir) dari console (BUKAN seluruh file).\n\n")
  
  estimation_objects <- tryCatch(mc_load_estimation_objects(output_dir), error = function(e) {
    cat(">> ERROR:", conditionMessage(e), "\n")
    NULL
  })
  if (is.null(estimation_objects)) {
    cat(">> Modul Monte Carlo TIDAK dapat dijalankan - lihat pesan error di atas.\n")
    return(invisible(NULL))
  }
  
  macro_cols_available <- estimation_objects$joint_dist$variabel_makro
  cat(">> Variabel makro tersedia (", length(macro_cols_available), "):\n")
  cat("   ", paste(macro_cols_available, collapse = ", "), "\n\n")
  cat(">> Jumlah model saham tersedia:", length(estimation_objects$markov_models), "\n\n")
  
  repeat {
    cat("--------------------------------------------------------------\n")
    cat("KONFIGURASI SKENARIO BARU (model TIDAK diestimasi ulang)\n")
    cat("--------------------------------------------------------------\n")
    
    n_sim <- suppressWarnings(as.integer(readline("Jumlah simulasi per skenario [default 100000]: ")))
    if (is.na(n_sim) || n_sim <= 0) n_sim <- 100000
    
    seed_input <- suppressWarnings(as.integer(readline("Random seed [default 123]: ")))
    if (is.na(seed_input)) seed_input <- 123
    
    use_sig <- mc_ask_yes_no(
      "Gunakan hanya koefisien SIGNIFIKAN untuk setiap emiten? (yes/no) [default no]: ",
      default = FALSE)
    
    alpha <- 0.1
    if (isTRUE(use_sig)) {
      alpha_input <- suppressWarnings(as.numeric(readline("Tingkat signifikansi alpha [default 0.1]: ")))
      if (!is.na(alpha_input) && alpha_input > 0 && alpha_input < 1) alpha <- alpha_input
    }
    
    var_input <- readline("Masukkan variabel makro yang mengalami shock (pisahkan dengan koma): ")
    shock_vars <- trimws(strsplit(var_input, ",")[[1]])
    shock_vars <- shock_vars[nzchar(shock_vars)]
    
    if (length(shock_vars) == 0) {
      cat(">> Tidak ada variabel dimasukkan - skenario dibatalkan.\n\n")
    } else if (!all(shock_vars %in% macro_cols_available)) {
      salah <- setdiff(shock_vars, macro_cols_available)
      cat(">> PERINGATAN: variabel berikut tidak dikenali:", paste(salah, collapse = ", "), "\n")
      cat(">> Nama variabel harus PERSIS SAMA dengan daftar di atas. Skenario dibatalkan.\n\n")
    } else {
      val_input <- readline(paste0("Masukkan nilai shock untuk ", length(shock_vars),
                                   " variabel (% return, pisahkan koma): "))
      shock_values <- suppressWarnings(as.numeric(trimws(strsplit(val_input, ",")[[1]])))
      
      if (length(shock_values) != length(shock_vars) || anyNA(shock_values)) {
        cat(">> ERROR: jumlah nilai shock TIDAK SESUAI dengan jumlah variabel, atau ada nilai bukan angka.\n")
        cat(">> Skenario dibatalkan - silakan ulangi.\n\n")
      } else {
        t0 <- Sys.time()
        scenario_result <- tryCatch(
          mc_run_scenario(shock_vars, shock_values, n_sim, use_sig, alpha,
                          estimation_objects, output_dir, seed = seed_input),
          error = function(e) {
            cat(">> ERROR pada eksekusi skenario:", conditionMessage(e), "\n")
            NULL
          }
        )
        
        if (!is.null(scenario_result)) {
          elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2)
          cat("\n>> [SELESAI] Skenario selesai dalam", elapsed, "menit.\n\n")
          cat(">> TABEL RANKING SAHAM (Expected Return tertinggi -> terendah):\n")
          print(scenario_result$ranking_table)
          
          cat("\n>> 5 SAHAM EXPECTED RETURN TERTINGGI:\n")
          print(utils::head(scenario_result$ranking_table, 5))
          cat("\n>> 5 SAHAM EXPECTED RETURN TERENDAH (PALING BERISIKO):\n")
          print(utils::tail(scenario_result$ranking_table, 5))
          
          mc_export_scenario(scenario_result, output_dir)
          
          if (mc_ask_yes_no("\nIngin melihat histogram/QQ plot untuk saham tertentu? (yes/no) [default no]: ",
                            default = FALSE)) {
            kode <- trimws(readline("Masukkan kode saham (mis. BBCA): "))
            mc_plot_stock_distribution(scenario_result, kode, output_dir)
          }
        }
      }
    }
    
    lanjut <- tolower(trimws(readline("\nIngin menjalankan skenario shock lain? (yes/no/stop): ")))
    if (lanjut %in% c("no", "n", "stop", "tidak")) {
      cat("\n>> Modul Monte Carlo Stress Testing DIHENTIKAN atas permintaan pengguna.\n")
      cat(">> Seluruh model (Markov & Joint Distribution) TETAP tersimpan di memori/RDS -\n")
      cat("   jalankan kembali mc_run_interactive(output_dir) kapan pun untuk skenario baru\n")
      cat("   TANPA perlu mengestimasi ulang model apa pun.\n")
      break
    }
    cat("\n")
  }
  
  invisible(NULL)
}

# [REFACTOR-NONINTERACTIVE] original called mc_run_interactive() unconditionally. It is built on
# readline(); under Rscript readline() returns "" immediately and the repeat-loops can spin forever.
# The module itself is unchanged and still available interactively (RStudio) - only auto-start is gated.
if (length(all_markov_models) > 0 && interactive() && !identical(Sys.getenv("PIPELINE_SKIP_INTERACTIVE_MC"), "true")) {
  mc_run_interactive(output_dir)
} else if (length(all_markov_models) > 0) {
  cat(">> [NONINTERACTIVE] Modul Monte Carlo interaktif (Bagian 7) dilewati. Model & RDS sudah tersimpan;",
      "jalankan mc_run_interactive(output_dir) secara manual bila diperlukan.\n")
} else {
  cat(">> Modul Monte Carlo Bagian 7 TIDAK dijalankan otomatis (tidak ada model Markov",
      "yang tersedia). Jalankan manual via mc_run_interactive(output_dir) setelah",
      "memastikan All_Markov_Models.rds & JointDistribution_Model.rds tersedia.\n")
}