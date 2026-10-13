suppressPackageStartupMessages(library(readxl))
source("tests/R/helpers_synth.R")                       # extract_functions()
pipe <- extract_functions("pipeline/15092026.R", c("calc_log_return","detect_suspend_blocks","detect_transformation_type","transform_series"), new.env(parent=globalenv()))
orig <- suppressWarnings(as.data.frame(read_excel("seed/raw_data.xlsx", sheet = 1)))
new  <- suppressWarnings(as.data.frame(read_excel(Sys.getenv("INGESTED_XLSX", "/tmp/ingested.xlsx"), sheet = 1)))
chk <- function(n, ok, d="") cat(sprintf("[%s] %s %s\n", if (ok) "PASS" else "FAIL", n, d))
chk("nama & urutan kolom identik dengan file asli", identical(names(orig), names(new)))
chk("tanggal terbaca sebagai tanggal", inherits(new[[1]], "POSIXct") && !anyNA(new[[1]]))
chk("baris +2, urut naik, tanpa duplikat", nrow(new) == nrow(orig) + 2 && !is.unsorted(new[[1]]) && !anyDuplicated(new[[1]]))
num <- function(df) { m <- as.data.frame(lapply(df[-1], function(v) suppressWarnings(as.numeric(v))), check.names = FALSE); m }
no <- num(orig); nn <- num(new)
chk("riwayat lama sama persis setelah as.numeric (semua sel)", isTRUE(all.equal(no, nn[seq_len(nrow(no)), ], check.attributes = FALSE)))
tail2 <- nn[(nrow(nn)-1):nrow(nn), ]; prev <- nn[nrow(nn)-2, ]
chk("makro+JCI di 2 baris baru terisi (tanpa NA)", !anyNA(tail2[, c("JCI Index","USDIDR BGN Curncy","CO1 Comdty","XAU Curncy","XW1 Comdty","KO1 Comdty","LMNIDS03 LME Comdty","IBPRCPI Index","GTIDR1Y Govt")]))
eq <- grep("IJ EQUITY", names(nn), value = TRUE)
extra <- Sys.getenv("EXPECT_NA_EXTRA", "")
expected_na <- union(eq[is.na(prev[eq])], if (nzchar(extra)) strsplit(extra, ";")[[1]] else character(0))
chk("nilai hilang = teks NA dibaca R sebagai NA, tepat pada saham yang diharapkan (yang kosong tetap kosong)",
    setequal(eq[is.na(tail2[2, eq])], expected_na), paste("NA:", paste(eq[is.na(tail2[2, eq])], collapse = ",")))
# hitung return dengan fungsi pipeline asli pada data gabungan
bad <- character(0)
for (nm in setdiff(names(nn), eq)) {
  ty <- pipe$detect_transformation_type(nm)$method; tr <- pipe$transform_series(nn[[nm]], ty)$value
  r <- tail(tr, 2); if (any(!is.finite(r)) || any(abs(r) > 0.2)) bad <- c(bad, sprintf("%s(%s)=%s", nm, ty, paste(signif(r,3), collapse="/")))
}
chk("return makro/JCI baris baru finite & wajar (<20%)", length(bad) == 0, paste(bad, collapse="; "))
lr <- sapply(eq, function(nm) { v <- abs(tail(pipe$calc_log_return(nn[[nm]]), 2)); v <- v[is.finite(v)]; if (length(v)) max(v) else NA_real_ })
chk("return saham baris baru finite & tidak ada loncatan besar", all(lr[!is.na(lr)] < 0.1),
    sprintf("%d saham terhitung, max |r|=%.4f, %d saham kosong (dilewati)", sum(!is.na(lr)), max(lr, na.rm = TRUE), sum(is.na(lr))))
