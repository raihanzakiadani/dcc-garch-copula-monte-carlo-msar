# Shared helpers for the orchestration layer (CI only; not shipped with the Shiny app).
suppressPackageStartupMessages({ library(jsonlite) })

repo_root <- function() normalizePath(Sys.getenv("REPO_ROOT", getwd()), winslash = "/", mustWork = TRUE)
load_cfg  <- function(path = file.path(repo_root(), "config", "pipeline.json")) jsonlite::read_json(path, simplifyVector = FALSE)

ts_both <- function(t = Sys.time()) list(
  utc = format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  wib = format(t, "%Y-%m-%dT%H:%M:%S+07:00", tz = "Asia/Jakarta"))

log_msg <- function(level, ...) {
  cat(sprintf("[%s WIB] %-5s %s\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "Asia/Jakarta"), level, paste0(..., collapse = "")))
}

sha256_file <- function(path) digest::digest(file = path, algo = "sha256")

write_json_atomic <- function(x, path) {
  tmp <- paste0(path, ".tmp")
  jsonlite::write_json(x, tmp, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA)
  stopifnot(!is.null(jsonlite::read_json(tmp)))
  file.rename(tmp, path)
}

# Reuse the DASHBOARD's own acceptance test so we never publish something the app would reject.
load_app_validators <- function(app_file = file.path(repo_root(), "app", "app.R")) {
  env <- new.env(parent = globalenv())
  exprs <- parse(app_file, keep.source = FALSE)
  want <- c("validate_model_integrity", "get_macro_variable_list")
  for (e in exprs) {
    if (is.call(e) && identical(e[[1]], as.name("<-")) && is.name(e[[2]]) && as.character(e[[2]]) %in% want &&
        is.call(e[[3]]) && identical(e[[3]][[1]], as.name("function"))) eval(e, envir = env)
  }
  stopifnot(all(want %in% ls(env)))
  env
}
