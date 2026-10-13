# usage: Rscript state_cli.R make <dir> <n_total> <n_hist> [nomodels] | append <dir> <n_total> <n_hist> <n_new> | revise <dir> <n_total> <n_hist> <n_new>
source(file.path(Sys.getenv("REPO_ROOT"), "tests/R/helpers_synth.R"))
a <- commandArgs(TRUE); repo <- Sys.getenv("REPO_ROOT")
if (a[1] == "make") make_state(a[2], as.integer(a[3]), as.integer(a[4]), repo, with_models = !(length(a) > 4 && a[5] == "nomodels"))
if (a[1] == "append") { raw <- make_raw(as.integer(a[3])); append_days(a[2], raw, as.integer(a[4]), as.integer(a[5])) }
if (a[1] == "revise") { raw <- make_raw(as.integer(a[3])); raw[100, "AAAA IJ EQUITY"] <- raw[100, "AAAA IJ EQUITY"] * 1.15
  write.xlsx(raw[1:(as.integer(a[4]) + as.integer(a[5])), ], file.path(a[2], "raw_data.xlsx")) }
