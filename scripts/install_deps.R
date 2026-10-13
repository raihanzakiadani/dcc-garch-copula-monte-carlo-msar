#!/usr/bin/env Rscript
# Installs R packages from a DATE-PINNED Posit Package Manager snapshot (reproducible; binaries on Linux = fast).
# Snapshot date: config/r_snapshot.txt (override: CRAN_SNAPSHOT_DATE). The date was NOT verified against PPM from the
# authoring sandbox (no network to it) - if the first CI run reports 404, pick another date.
# For exact per-package pinning run scripts/make_renv_lock.R once and commit renv.lock.
root <- Sys.getenv("REPO_ROOT", getwd())
snap <- Sys.getenv("CRAN_SNAPSHOT_DATE", trimws(readLines(file.path(root, "config", "r_snapshot.txt"), warn = FALSE)[1]))
repo <- sprintf("https://packagemanager.posit.co/cran/__linux__/noble/%s", snap)
pk <- trimws(readLines(file.path(root, "config", "r_packages.txt"), warn = FALSE)); pk <- pk[nzchar(pk) & !startsWith(pk, "#")]
if (file.exists(file.path(root, "renv.lock"))) {
  install.packages("renv", repos = repo); renv::restore(lockfile = file.path(root, "renv.lock"), prompt = FALSE)
} else {
  options(repos = c(CRAN = repo), Ncpus = max(1L, parallel::detectCores()))
  # bootstrap with HTTPUserAgent so PPM serves Linux binaries
  options(HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(), paste(getRversion(), R.version["platform"], R.version["arch"], R.version["os"])))
  need <- setdiff(pk, rownames(installed.packages()))
  if (length(need)) install.packages(need, dependencies = c("Depends", "Imports", "LinkingTo"))
}
bad <- pk[!vapply(pk, requireNamespace, logical(1), quietly = TRUE)]
if (length(bad)) stop("could not install: ", paste(bad, collapse = ", "))
cat("R packages OK (snapshot ", snap, ")\n", sep = "")
si <- capture.output(sessionInfo()); writeLines(si, file.path(root, "sessionInfo.txt"))
