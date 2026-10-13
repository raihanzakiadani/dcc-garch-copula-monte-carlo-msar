#!/usr/bin/env Rscript
# Writes shard_meta_<NNN>.json next to each shard RDS (readable by Python for the Summary). usage: Rscript scripts/shard_meta.R <shard_dir>
d <- commandArgs(TRUE)[1]
for (f in list.files(d, pattern = "^shard_[0-9]+\\.rds$", full.names = TRUE)) {
  x <- readRDS(f)
  jsonlite::write_json(list(index = x$index, count = x$count, n_stocks = length(x$stocks), n_ok = x$n_ok, seconds = x$seconds,
                            failed = names(x$results)[vapply(x$results, is.null, logical(1))]),
                       file.path(dirname(f), sub("\\.rds$", ".json", sub("^shard_", "shard_meta_", basename(f)))), auto_unbox = TRUE, pretty = TRUE)
}
