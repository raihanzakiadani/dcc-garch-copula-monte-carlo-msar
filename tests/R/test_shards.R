# Tests of the sharding helpers extracted from pipeline/15092026.R (the real code), plus an RNG-equivalence proof with future.apply.
repo <- normalizePath(Sys.getenv("REPO_ROOT", getwd()))
source(file.path(repo, "tests/R/helpers_synth.R"))
results <- list(); chk <- function(n, ok, d = "") { results[[n]] <<- isTRUE(ok); cat(sprintf("[%s] %s %s\n", if (isTRUE(ok)) "PASS" else "FAIL", n, d)) }
H <- extract_functions(file.path(repo, "pipeline/15092026.R"),
  c("pipeline_shard_stocks", "pipeline_save_rds_atomic", "pipeline_save_macro_stage", "pipeline_load_macro_stage", "pipeline_save_shard", "pipeline_load_shards"),
  new.env(parent = globalenv()))
stocks <- sprintf("S%02d IJ EQUITY", 1:71)
err <- function(expr) tryCatch({ force(expr); "" }, error = function(e) conditionMessage(e))

# ---- partition ----
ok <- TRUE; bal <- TRUE
for (k in 1:20) { parts <- lapply(1:k, function(i) H$pipeline_shard_stocks(stocks, i, k))
  ok <- ok && identical(sort(unlist(parts)), sort(stocks)) && !anyDuplicated(unlist(parts))
  sz <- lengths(parts); bal <- bal && (max(sz) - min(sz) <= 1) }
chk("partisi 1..20 shard: gabungan = 71 saham, tanpa ganda", ok)
chk("partisi seimbang (selisih ukuran <= 1)", bal)

# ---- macro stage ----
td <- tempfile("shd_"); dir.create(td); md5 <- "abc123"
mdf <- data.frame(Dates = 1:3, a = 1:3, b = 4:6); mc <- c("a", "b")
H$pipeline_save_macro_stage(file.path(td, "macro_stage.rds"), mdf, mc, stocks, md5)
chk("macro_stage roundtrip", identical(H$pipeline_load_macro_stage(file.path(td, "macro_stage.rds"), mc, stocks, md5), mdf))
chk("macro_stage menolak input_md5 berbeda", grepl("BERBEDA", err(H$pipeline_load_macro_stage(file.path(td, "macro_stage.rds"), mc, stocks, "zzz"))))
chk("macro_stage menolak macro_cols berbeda", grepl("macro_cols", err(H$pipeline_load_macro_stage(file.path(td, "macro_stage.rds"), c("a"), stocks, md5))))
chk("macro_stage menolak stock_targets berbeda", grepl("stock_targets", err(H$pipeline_load_macro_stage(file.path(td, "macro_stage.rds"), mc, stocks[-1], md5))))
chk("macro_stage hilang -> error jelas", grepl("tahap 'joint'", err(H$pipeline_load_macro_stage(file.path(td, "none.rds"), mc, stocks, md5))))
chk("tidak ada file .tmp tersisa", length(list.files(td, pattern = "tmp_")) == 0)

# ---- shards: build 5 shards, one stock failed (NULL) ----
K <- 5; sd <- file.path(td, "sh"); fake <- function(st) list(final_fit = list(tag = st), stock = st)
for (i in 1:K) { ar <- setNames(vector("list", length(stocks)), stocks)
  for (st in H$pipeline_shard_stocks(stocks, i, K)) ar[st] <- list(if (st == "S07 IJ EQUITY") NULL else fake(st))
  H$pipeline_save_shard(sd, i, K, stocks, ar, md5, seconds = 100 * i) }
all <- H$pipeline_load_shards(sd, stocks, md5)
chk("merge: urutan = stock_targets, 71 elemen", identical(names(all), stocks) && length(all) == 71)
chk("merge: saham gagal tetap NULL (tidak hilang dari daftar)", "S07 IJ EQUITY" %in% names(all) && is.null(all[["S07 IJ EQUITY"]]))
chk("merge: hasil tiap saham utuh", all(vapply(setdiff(stocks, "S07 IJ EQUITY"), function(s) identical(all[[s]], fake(s)), logical(1))))
chk("merge: waktu shard tercatat", identical(as.numeric(attr(all, "shard_seconds")), 100 * (1:K)))
file.remove(file.path(sd, "shard_003.rds"))
chk("merge menolak shard hilang", grepl("tidak lengkap", err(H$pipeline_load_shards(sd, stocks, md5))))
ar <- setNames(vector("list", 71), stocks); for (st in H$pipeline_shard_stocks(stocks, 3, K)) ar[st] <- list(fake(st))
H$pipeline_save_shard(sd, 3, K, stocks, ar, "other_md5", 1)
chk("merge menolak shard dari raw_data berbeda", grepl("BERBEDA", err(H$pipeline_load_shards(sd, stocks, md5))))
H$pipeline_save_shard(sd, 3, K, stocks, ar, md5, 1); H$pipeline_save_shard(sd, 3, 6, stocks, ar, md5, 1)       # count mismatch (6)
saveRDS(readRDS(file.path(sd, "shard_003.rds")), file.path(sd, "shard_003.rds"))
chk("merge menolak shard_count tidak konsisten", grepl("COUNT berbeda", err(H$pipeline_load_shards(sd, stocks, md5))))
chk("merge menolak folder kosong", grepl("tidak ada shard", err(H$pipeline_load_shards(file.path(td, "empty"), stocks, md5))))

# ---- RNG equivalence: sharded run == unsharded run (same future.seed stream per stock) ----
if (requireNamespace("future.apply", quietly = TRUE) && requireNamespace("future", quietly = TRUE)) {
  work <- function(stock, keep = NULL) { if (!is.null(keep) && !(stock %in% keep)) return(NULL); c(runif(1), rnorm(1), sample(1e6, 1)) }
  for (pl in c("sequential", "multisession")) {
    if (pl == "multisession") future::plan(future::multisession, workers = 2) else future::plan(future::sequential)
    full <- future.apply::future_lapply(stocks, work, future.seed = 123); names(full) <- stocks
    merged <- setNames(vector("list", 71), stocks)
    for (i in 1:7) { keep <- H$pipeline_shard_stocks(stocks, i, 7)
      part <- future.apply::future_lapply(stocks, work, keep = keep, future.seed = 123); names(part) <- stocks
      for (st in keep) merged[st] <- list(part[[st]]) }
    chk(sprintf("seed identik: 7 shard digabung == satu kali jalan (plan=%s)", pl), identical(full, merged))
  }
  future::plan(future::sequential)
} else cat("[SKIP] future.apply tidak terpasang\n")

cat("\n==== ", sum(unlist(results)), "/", length(results), " checks passed ====\n")
if (!all(unlist(results))) quit(status = 1)
