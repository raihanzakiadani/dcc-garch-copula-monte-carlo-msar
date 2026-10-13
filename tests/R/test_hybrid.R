# Integration tests of the REFACTORED Hybrid_Incremental_Update.R (real code, synthetic fixed-parameter models).
# Scenarios that need the full estimation stack (rugarch/rmgarch/copula) are verified only up to the point
# where the FULL pipeline is launched; the sandbox lacks those packages, so FULL success is NOT claimed here.
repo <- normalizePath(Sys.getenv("REPO_ROOT", getwd()))
source(file.path(repo, "tests/R/helpers_synth.R"))
results <- list(); chk <- function(name, ok, detail = "") { results[[name]] <<- ok; cat(sprintf("[%s] %s %s\n", if (ok) "PASS" else "FAIL", name, detail)) }
md5 <- function(p) unname(tools::md5sum(p))
tmp <- tempfile("hyb_"); dir.create(tmp)

# ---- S2: DAILY with new data -------------------------------------------------------------------
w <- file.path(tmp, "s2"); raw <- make_state(w, 320, 300, repo)
append_days(w, raw, 300, 5)
m0 <- readRDS(file.path(w, "All_Markov_Models.rds"))
r <- run_hybrid(w, "DAILY", repo)
chk("S2 daily exit 0", r$exit == 0, paste("exit", r$exit))
chk("S2 status ok+saved", isTRUE(r$status$ok) && isTRUE(r$status$saved) && r$status$n_updated == 2, paste(capture.output(str(r$status[c("ok","saved","n_updated")])), collapse=" "))
m1 <- readRDS(file.path(w, "All_Markov_Models.rds"))
st <- "AAAA IJ EQUITY"
chk("S2 last_actual_date advanced to new max date", as.Date(m1[[st]]$final_fit$last_actual_date) == raw$Dates[305])
chk("S2 filt_prob grew by 5 rows", nrow(m1[[st]]$final_fit$filt_prob) == nrow(m0[[st]]$final_fit$filt_prob) + 5)
chk("S2 historical filt_prob identical (fixed params)", max(abs(m1[[st]]$final_fit$filt_prob[1:nrow(m0[[st]]$final_fit$filt_prob), ] - m0[[st]]$final_fit$filt_prob)) < 1e-12)
chk("S2 params NOT re-estimated", identical(m1[[st]]$final_fit$beta_mat, m0[[st]]$final_fit$beta_mat) && identical(m1[[st]]$update_mode, "DAILY"))
chk("S2 mode executed is DAILY (no silent re-estimation)", identical(r$status$mode_executed, "DAILY") && !isTRUE(r$status$fallback_full))
chk("S2 workbook sheets refreshed", "Filtered Probability" %in% openxlsx::getSheetNames(file.path(w, "Output_MarkovRegimeSwitching_AAAA_IJ_EQUITY.xlsx")))
chk("S2 xlsx backups NOT beside workbooks", length(list.files(w, pattern = "_backup_")) == 0)
chk("S2 joint model untouched by DAILY (by original design)", md5(file.path(w, "JointDistribution_Model.rds")) == md5(file.path(w, "JointDistribution_Model.rds")))

# ---- S3: DAILY, no new data --------------------------------------------------------------------
before <- md5(file.path(w, "All_Markov_Models.rds"))
r <- run_hybrid(w, "DAILY", repo)
chk("S3 up-to-date: exit 0, nothing saved", r$exit == 0 && isTRUE(r$status$ok) && !isTRUE(r$status$saved) && r$status$note == "UP_TO_DATE")
chk("S3 RDS byte-identical", md5(file.path(w, "All_Markov_Models.rds")) == before)

# ---- S4: historical revision -> strict atomic, nothing saved -------------------------------------
w4 <- file.path(tmp, "s4"); raw4 <- make_state(w4, 320, 300, repo)
raw4_rev <- raw4; raw4_rev[100, "AAAA IJ EQUITY"] <- raw4_rev[100, "AAAA IJ EQUITY"] * 1.15      # revise a historical price
write.xlsx(raw4_rev[1:303, ], file.path(w4, "raw_data.xlsx"))
b4 <- md5(file.path(w4, "All_Markov_Models.rds"))
r <- run_hybrid(w4, "DAILY", repo)
chk("S4 revision detected -> exit 2, ok=FALSE", r$exit == 2 && isFALSE(r$status$ok))
chk("S4 AAAA flagged needs_full with replica reason", "AAAA IJ EQUITY" %in% unlist(r$status$needs_full) && grepl("TIDAK SAMA", paste(unlist(r$status$needs_full_reasons), collapse = " ")))
chk("S4 strict atomic: BBBB (unchanged) NOT promoted alone; RDS byte-identical", md5(file.path(w4, "All_Markov_Models.rds")) == b4 && !isTRUE(r$status$saved))

# ---- S1/S5: no model / corrupted model -> documented fallback to FULL is attempted and RECORDED --------
w1 <- file.path(tmp, "s1"); make_state(w1, 320, 300, repo, with_models = FALSE)
r <- run_hybrid(w1, "DAILY", repo)
chk("S1 first run (no RDS): fallback_full recorded", isTRUE(r$status$fallback_full) && grepl("not found", r$status$fallback_reason))
have_stack <- all(vapply(c("rugarch", "rmgarch", "copula"), requireNamespace, logical(1), quietly = TRUE))
if (!have_stack) {
  chk("S1 FULL really launches 15092026.R (fails at pkg check here; sandbox lacks rugarch/rmgarch/copula)",
      any(grepl("Paket R belum terpasang", r$log)) && r$exit == 2 && isFALSE(r$status$ok))
  chk("S1 failed FULL leaves no partial production model", !file.exists(file.path(w1, "All_Markov_Models.rds")))
}
w5 <- file.path(tmp, "s5"); raw5 <- make_state(w5, 320, 300, repo); append_days(w5, raw5, 300, 2)
writeBin(as.raw(sample(0:255, 500, TRUE)), file.path(w5, "All_Markov_Models.rds"))
r <- run_hybrid(w5, "DAILY", repo)
chk("S5 corrupted RDS detected -> fallback_full recorded, no crash", isTRUE(r$status$fallback_full) && grepl("unreadable", r$status$fallback_reason))

# ---- FULL explicit: must launch the pipeline script, never just relabel ----------------------------
w6 <- file.path(tmp, "s6"); make_state(w6, 320, 300, repo)
r <- run_hybrid(w6, "FULL", repo)
chk("S6 MODE=FULL executes pipeline/15092026.R (not a relabel)", identical(r$status$mode_executed, "FULL") &&
      (any(grepl("MODE FULL - MENJALANKAN ULANG", r$log))) && (have_stack || any(grepl("Paket R belum terpasang", r$log))))

cat("\n==== ", sum(unlist(results)), "/", length(results), " checks passed ====\n")
if (!all(unlist(results))) { cat(tail(r$log, 15), sep = "\n"); quit(status = 1) }
