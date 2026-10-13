# ---------------------------------------------------------------------------------------------------------
# Data retrieval for the deployed Shiny app (added; the rest of app.R is unchanged).
#
# The pipeline publishes versioned bundles to GitHub Releases and moves a tiny pointer (release `data-latest`,
# asset manifest.json) LAST.  This file makes the running app follow that pointer, so new data needs NO republish.
#
# Environment variables (server side only - nothing here is ever sent to the browser):
#   DATA_REPO            owner/repo that holds the releases            (required for remote mode)
#   DATA_GITHUB_TOKEN    fine-grained PAT, "Contents: read-only" on that one repo (needed only if repo is PRIVATE)
#   DATA_REFRESH_SECONDS how often a new session re-checks the pointer (default 300)
#   DATA_TIMEOUT_SECONDS per-request timeout (default 30; bundle download gets 4x)
#   DATA_CACHE_DIR       writable cache (default: <tempdir>/idxdata)
#   DATA_WEB_BASE / DATA_API_BASE   overrides for tests / GitHub Enterprise (defaults: github.com / api.github.com)
# Behaviour: validate (sha256 of bundle AND every file, RDS readable) -> only then switch to the new version;
# any failure keeps the last valid version; if nothing was ever downloaded, falls back to the snapshot shipped
# inside the app folder (if present).  A mixed set (new models + old dataset) is impossible: one bundle = one version.
# ---------------------------------------------------------------------------------------------------------
.DATA_STATE <- new.env(parent = emptyenv())
.DATA_STATE$root <- NULL; .DATA_STATE$version <- NA_character_; .DATA_STATE$checked <- as.POSIXct(0, origin = "1970-01-01")
.DATA_STATE$last_error <- NA_character_; .DATA_STATE$manifest <- NULL

.dr_env <- function(k, d = "") { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) v else d }
.dr_log <- function(...) message(sprintf("[data %s] %s", format(Sys.time(), "%H:%M:%S"), paste0(..., collapse = "")))
.dr_required <- c("All_Markov_Models.rds", "JointDistribution_Model.rds", "raw_data.xlsx")

.dr_get <- function(url, dest, token = "", accept = NULL, timeout = 30) {
  old <- options(timeout = timeout); on.exit(options(old), add = TRUE)
  hdr <- c("User-Agent" = "idx-risk-dashboard")
  if (nzchar(token)) hdr <- c(hdr, Authorization = paste("Bearer", token))
  if (!is.null(accept)) hdr <- c(hdr, Accept = accept)
  rc <- suppressWarnings(utils::download.file(url, dest, mode = "wb", quiet = TRUE, method = "libcurl", headers = hdr))
  if (!identical(as.integer(rc), 0L) || !file.exists(dest) || file.size(dest) == 0) stop("download failed")
  invisible(dest)
}

# Resolve a release asset to a downloadable URL (private repos must go through the API; public uses the CDN URL).
.dr_asset <- function(repo, tag, name, token, dest, timeout) {
  if (!nzchar(token)) {
    return(.dr_get(sprintf("%s/%s/releases/download/%s/%s", .dr_env("DATA_WEB_BASE", "https://github.com"), repo, tag, name), dest, "", NULL, timeout))
  }
  meta <- tempfile(fileext = ".json")
  .dr_get(sprintf("%s/repos/%s/releases/tags/%s", .dr_env("DATA_API_BASE", "https://api.github.com"), repo, tag), meta, token, "application/vnd.github+json", timeout)
  j <- jsonlite::read_json(meta); unlink(meta)
  hit <- Filter(function(a) identical(a$name, name), j$assets)
  if (length(hit) == 0) stop("asset not found in release")
  .dr_get(hit[[1]]$url, dest, token, "application/octet-stream", timeout)   # token is NOT forwarded to the storage redirect by libcurl
}

.dr_sha <- function(p) digest::digest(file = p, algo = "sha256")

.dr_install_version <- function(repo, token, m, cache, timeout) {
  vid <- m$version_id; final <- file.path(cache, "versions", vid)
  if (dir.exists(final)) return(final)
  part <- paste0(final, ".partial"); unlink(part, recursive = TRUE); dir.create(part, recursive = TRUE)
  on.exit(unlink(part, recursive = TRUE), add = TRUE)
  tgz <- file.path(cache, paste0(vid, ".tar.gz"))
  on.exit(unlink(tgz), add = TRUE)
  .dr_asset(repo, m$bundle$release_tag, m$bundle$name, token, tgz, timeout * 4)
  if (!identical(.dr_sha(tgz), m$bundle$sha256)) stop("bundle sha256 mismatch")
  utils::untar(tgz, exdir = part)
  for (f in m$files) {
    p <- file.path(part, f$path)
    if (!file.exists(p) || !identical(.dr_sha(p), f$sha256)) stop("file hash mismatch: ", f$path)
  }
  for (f in .dr_required) if (!file.exists(file.path(part, f))) stop("required file missing: ", f)
  for (f in c("All_Markov_Models.rds", "JointDistribution_Model.rds")) readRDS(file.path(part, f))   # must be readable
  if (!file.rename(part, final)) stop("could not activate version")
  final
}

.dr_prune <- function(cache, keep = 3) {
  d <- list.dirs(file.path(cache, "versions"), recursive = FALSE)
  if (length(d) <= keep) return(invisible())
  d <- d[order(file.info(d)$mtime, decreasing = TRUE)]
  for (x in d[-seq_len(keep)]) if (!identical(normalizePath(x), normalizePath(.DATA_STATE$root %||% ""))) unlink(x, recursive = TRUE)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# Main entry. Returns the directory the app should load from.  Never throws.
resolve_data_root <- function(local_fallback = getwd()) {
  repo <- .dr_env("DATA_REPO"); token <- .dr_env("DATA_GITHUB_TOKEN")
  every <- as.numeric(.dr_env("DATA_REFRESH_SECONDS", "300")); timeout <- as.numeric(.dr_env("DATA_TIMEOUT_SECONDS", "30"))
  cache <- .dr_env("DATA_CACHE_DIR", file.path(tempdir(), "idxdata"))
  has_local <- all(file.exists(file.path(local_fallback, .dr_required[1:2])))
  if (!nzchar(repo)) {                                    # remote mode not configured: legacy behaviour
    return(if (!is.null(.DATA_STATE$root)) .DATA_STATE$root else local_fallback)
  }
  fresh <- !is.null(.DATA_STATE$root) && as.numeric(difftime(Sys.time(), .DATA_STATE$checked, units = "secs")) < every
  if (fresh) return(.DATA_STATE$root)
  dir.create(file.path(cache, "versions"), recursive = TRUE, showWarnings = FALSE)
  res <- tryCatch({
    ptr <- tempfile(fileext = ".json"); on.exit(unlink(ptr), add = TRUE)
    .dr_asset(repo, .dr_env("DATA_TAG_LATEST", "data-latest"), "manifest.json", token, ptr, timeout)
    m <- jsonlite::read_json(ptr)
    if (is.null(m$version_id) || is.null(m$bundle$sha256)) stop("pointer manifest malformed")
    if (!identical(m$version_id, .DATA_STATE$version)) {
      root <- .dr_install_version(repo, token, m, cache, timeout)
      .DATA_STATE$root <- root; .DATA_STATE$version <- m$version_id; .DATA_STATE$manifest <- m
      .dr_log("switched to version ", m$version_id, " (raw_max_date ", m$data$raw_max_date, ", status ", m$status, ")")
      .dr_prune(cache)
    }
    .DATA_STATE$last_error <- NA_character_
    TRUE
  }, error = function(e) { .DATA_STATE$last_error <- conditionMessage(e); .dr_log("refresh failed, keeping last valid data: ", conditionMessage(e)); FALSE })
  .DATA_STATE$checked <- Sys.time()          # also after failure: do not hammer GitHub on every session
  if (!is.null(.DATA_STATE$root)) return(.DATA_STATE$root)
  if (has_local) { .dr_log("no remote data yet; using snapshot bundled with the app"); return(local_fallback) }
  local_fallback                              # app.R's own setup-error page will explain what is missing
}

data_status <- function() list(version = .DATA_STATE$version, root = .DATA_STATE$root, last_error = .DATA_STATE$last_error,
                               checked = .DATA_STATE$checked, manifest = .DATA_STATE$manifest)
