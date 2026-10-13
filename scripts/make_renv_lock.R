#!/usr/bin/env Rscript
# One-off (run after the first green install): freeze exact versions -> renv.lock, then commit it.
install.packages("renv"); renv::init(bare = TRUE, restart = FALSE)
pk <- trimws(readLines("config/r_packages.txt")); renv::install(pk[nzchar(pk)]); renv::snapshot(packages = pk, prompt = FALSE)
