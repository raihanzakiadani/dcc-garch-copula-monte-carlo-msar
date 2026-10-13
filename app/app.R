library(shiny)
library(magrittr)
library(DT)
library(ggplot2)
library(plotly)
library(htmlwidgets)
library(openxlsx)
library(gridExtra)
library(png)
library(copula)
library(rugarch)
library(methods)


DEFAULT_ROOT_DIR <- getwd()

# [REFACTOR-DATA-RETRIEVAL] data now follows the latest published bundle (GitHub Releases) - see app_retrieval.R.
# Without DATA_REPO set the app behaves exactly as before (loads files from its own folder).
source(file.path(DEFAULT_ROOT_DIR, "app_retrieval.R"), local = FALSE)

CUSTOM_CSS_TEXT <- "  :root{
    --mc-navy:#0D223C;
    --mc-teal:#123A4C;
    --mc-green:#31AE5C;
    --mc-green2:#30B759;
    --mc-sidebar-bg:#F9F9F9;
    --mc-card-bg:#FFFFFF;
    --mc-card-border:#D6D6D6;
    --mc-input-bg:#D9D9D9;
    --mc-table-header-bg:#DCDCDC;
    --mc-btn-simulate:#217A5B;
    --mc-btn-simulate-hover:#1C6A4E;
    --mc-btn-report:#17515C;
    --mc-btn-report-hover:#12414A;
    --mc-text-dark:#1A1A1A;
    --mc-text-muted:#5A5A5A;
    --mc-red:#C0392B;
    --mc-green-text:#1E8449;
    --mc-critical:#D64545;
    --mc-warning:#E08A1E;
    --mc-caution:#E6B800;
    --mc-info:#1E78C8;
    --mc-radius-card:10px;
    --mc-radius-input:6px;
    --mc-header-h:88px;
    --mc-sidebar-w:320px;
    --mc-font: -apple-system, \"Segoe UI\", Roboto, Arial, sans-serif;
  }
  
  html, body{ background:var(--mc-sidebar-bg); font-family:var(--mc-font); color:var(--mc-text-dark); }
  * { box-sizing:border-box; }
  .container-fluid{ padding:0 !important; max-width:100% !important; }
  
  .mc-header{
    width:100%;
    min-height:var(--mc-header-h);
    background:linear-gradient(100deg, var(--mc-navy) 0%, var(--mc-navy) 28%, var(--mc-teal) 46%, var(--mc-green) 78%, var(--mc-green2) 100%);
    display:flex; align-items:flex-start; justify-content:space-between;
    padding:14px 28px 0 20px;
    position:relative;
  }
  .mc-header-left{ display:flex; align-items:center; flex:0 0 auto; padding-top:2px; }
  .mc-logo-img{ height:44px; width:auto; display:block; }
  .mc-header-title{ padding-left:24px; padding-top:2px; flex:1; min-width:0; }
  .mc-header-title h1{
    color:#ffffff; font-size:22px; font-weight:800; margin:0 0 8px 0; line-height:1.25;
  }
  .mc-header-title h1 .light{ font-weight:400; }
  .mc-header-title hr{ border:none; border-top:1px solid rgba(255,255,255,.35); margin:0 0 8px 0; }
  .mc-navtabs{ display:flex; align-items:center; gap:30px; }
  .mc-navtabs a{
    color:rgba(255,255,255,.75); font-size:15px; font-weight:600; text-decoration:none;
    cursor:pointer; padding-bottom:2px; border:none; background:none;
  }
  .mc-navtabs a.active{ color:#ffffff; font-weight:800; }
  .mc-navtabs a:hover{ color:#ffffff; }
  .mc-header-right{
    background:rgba(255,255,255,.14); border-radius:8px; padding:7px 14px;
    color:#ffffff; text-align:right; margin-top:2px;
    flex:0 0 auto; align-self:flex-start;
    width:-moz-fit-content; width:fit-content; max-width:100%;
    white-space:nowrap;
  }
  .mc-header-right .lbl{ font-weight:800; font-size:12px; display:block; white-space:nowrap; }
  .mc-header-right .val{ font-size:14px; font-weight:600; display:block; margin-top:2px; white-space:nowrap; }
  
  .mc-body{ display:flex; align-items:flex-start; width:100%; min-height:calc(100vh - 88px); }
  .mc-sidebar{
    width:var(--mc-sidebar-w); flex:0 0 var(--mc-sidebar-w);
    background:var(--mc-sidebar-bg); border-right:1px solid #e6e6e6;
    padding:14px 14px 24px 14px; min-height:100%;
  }
  .mc-content{ flex:1; min-width:0; padding:14px 20px 30px 20px; }
  
  .mc-card{
    background:var(--mc-card-bg); border:1px solid var(--mc-card-border);
    border-radius:var(--mc-radius-card); padding:16px 18px; margin-bottom:14px;
  }
  .mc-card h3.mc-card-title{
    font-size:17px; font-weight:800; margin:0 0 10px 0; padding-bottom:10px;
    border-bottom:1px solid #cfcfcf;
  }
  .mc-sidebar .mc-card{ padding:12px 14px; margin-bottom:10px; background:var(--mc-card-bg); }
  .mc-sidebar .mc-card label.mc-label{ font-weight:800; font-size:13px; display:block; margin-bottom:4px; }
  .mc-sidebar .mc-card p.mc-help{ font-size:11px; color:var(--mc-text-muted); margin:0 0 8px 0; }
  
  .mc-grid-2{ display:grid; grid-template-columns:1fr 1fr; gap:16px; align-items:stretch; }
  
  .mc-grid-2-top{ display:grid; grid-template-columns:1fr 1fr; gap:16px; align-items:start; }
  .mc-grid-2-top .mc-col{ display:flex; flex-direction:column; gap:16px; min-width:0; }
  .mc-grid-2-top .mc-col > .mc-card{ margin-bottom:0; }
  
  .mc-radio-row{ display:flex; gap:28px; margin-top:2px; }
  .mc-sidebar .form-check{ padding-left:26px; }
  .mc-sidebar .form-check-input{ width:16px; height:16px; margin-left:-26px; margin-top:2px; }
  
  .mc-numeric input.form-control, .mc-shock-input input.form-control{
    background:var(--mc-input-bg) !important; border:none !important; border-radius:var(--mc-radius-input) !important;
    height:34px; font-size:13px; color:#333;
  }
  .mc-numeric label, .mc-shock-input label{ font-weight:800; font-size:13px; margin-bottom:4px; }
  
  .mc-varcheck-grid{ display:flex; gap:18px; margin-top:6px; align-items:flex-start; }
  .mc-varcheck-col{ display:flex; flex-direction:column; gap:8px; flex:1; min-width:0; }
  .mc-varcheck-item{ display:flex; align-items:center; gap:8px; }
  .mc-varcheck-label{ font-size:13px; margin:0; cursor:pointer; user-select:none; }
  input.mc-varcheck-box{
    appearance:none; -webkit-appearance:none; width:16px; height:16px; min-width:16px; border-radius:50%;
    border:2px solid #4a4a4a; background:#fff; cursor:pointer; position:relative; margin:0;
  }
  input.mc-varcheck-box:checked{ background:var(--mc-btn-simulate); border-color:var(--mc-btn-simulate); }
  input.mc-varcheck-box:checked::after{
    content:\"\"; position:absolute; left:2px; top:2px; width:6px; height:6px; border-radius:50%; background:#fff;
  }
  
  .mc-shock-input input:disabled{ opacity:.45; cursor:not-allowed; }
  .mc-shock-input label.disabled-label{ opacity:.45; }
  
  .mc-sidebar-btn{
    width:100%; text-align:left; color:#fff !important; font-weight:800; font-size:15px;
    border:none; border-radius:8px; padding:12px 16px; margin-top:10px;
  }
  .mc-sidebar-btn .mc-btn-icon{ margin-right:10px; }
  .mc-btn-simulate{ background:var(--mc-btn-simulate) !important; }
  .mc-btn-simulate:hover{ background:var(--mc-btn-simulate-hover) !important; }
  .mc-btn-report{ background:var(--mc-btn-report) !important; }
  .mc-btn-report:hover{ background:var(--mc-btn-report-hover) !important; }
  
  table.mc-table{ width:100%; border-collapse:collapse; font-size:13px; background:var(--mc-table-header-bg); border-radius:6px; overflow:hidden; }
  table.mc-table thead th{
    background:var(--mc-table-header-bg); font-weight:800; text-align:center; padding:10px 8px;
    border-bottom:1px solid #bcbcbc;
  }
  table.mc-table thead th:first-child{ text-align:left; }
  table.mc-table tbody td{ padding:9px 8px; text-align:center; border-bottom:1px solid #c7c7c7; background:var(--mc-table-header-bg); }
  table.mc-table tbody td:first-child{ text-align:left; font-weight:800; }
  table.mc-table tbody tr:last-child td{ border-bottom:none; }
  table.mc-table tbody tr:hover td{ background:#cfcfcf; }
  .mc-neg{ color:var(--mc-red); font-weight:800; }
  .mc-pos{ color:var(--mc-green-text); font-weight:800; }
  
  .mc-alert-row{ display:flex; align-items:flex-start; gap:14px; padding:10px 0; border-bottom:1px solid #f0f0f0; }
  .mc-alert-row:last-child{ border-bottom:none; }
  .mc-alert-icon{ width:26px; height:26px; flex:0 0 auto; margin-top:2px; object-fit:contain; }
  .mc-alert-text{ font-size:14px; line-height:1.45; color:#222; }
  .mc-alert-meta{ font-size:11px; color:var(--mc-text-muted); margin-top:2px; }
  .mc-alert-seeall{ text-align:right; margin-top:8px; }
  .mc-alert-seeall a{ color:#1a56db; font-weight:700; text-decoration:underline; font-size:13px; }
  .mc-severity-badge{
    display:inline-block; font-size:10px; font-weight:800; border-radius:4px; padding:2px 8px;
    color:#fff; text-transform:uppercase; letter-spacing:.4px;
  }
  .mc-badge-critical{ background:var(--mc-critical); }
  .mc-badge-warning{ background:var(--mc-warning); }
  .mc-badge-caution{ background:var(--mc-caution); color:#3a2c00; }
  .mc-badge-information{ background:var(--mc-info); }
  
  .mc-summary-grid{ display:grid; grid-template-columns:repeat(6,1fr); gap:12px; margin-bottom:14px; }
  .mc-summary-card{
    background:#fff; border:1px solid var(--mc-card-border); border-radius:10px; padding:14px;
    text-align:left;
  }
  .mc-summary-card .mc-sc-label{ font-size:11px; color:var(--mc-text-muted); font-weight:700; text-transform:uppercase; }
  .mc-summary-card .mc-sc-value{ font-size:22px; font-weight:800; margin-top:6px; }
  
  .mc-loading-overlay{
    position:fixed; inset:0; z-index:99999; display:flex; align-items:center; justify-content:center;
    background:rgba(13,34,60,.35); backdrop-filter:blur(6px); -webkit-backdrop-filter:blur(6px);
  }
  .mc-loading-panel{
    background:#fff; border-radius:14px; padding:34px 46px; width:420px; text-align:center;
    box-shadow:0 18px 50px rgba(0,0,0,.35);
  }
  .mc-loading-spinner{
    width:56px; height:56px; margin:0 auto 18px auto; border-radius:50%;
    border:5px solid #e2e2e2; border-top-color:var(--mc-btn-simulate); animation:mc-spin 0.9s linear infinite;
  }
  @keyframes mc-spin{ to{ transform:rotate(360deg); } }
  .mc-loading-title{ font-weight:800; font-size:16px; margin-bottom:6px; color:#0D223C; }
  .mc-loading-stage{ font-size:13px; color:#555; min-height:18px; }
  .mc-loading-bar-track{ width:100%; height:6px; background:#eee; border-radius:6px; margin-top:16px; overflow:hidden; }
  .mc-loading-bar-fill{ height:100%; width:35%; background:linear-gradient(90deg,var(--mc-navy),var(--mc-green)); border-radius:6px;
    animation:mc-indeterminate 1.4s ease-in-out infinite; }
  @keyframes mc-indeterminate{
    0%{ transform:translateX(-100%); width:35%; }
    50%{ width:55%; }
    100%{ transform:translateX(220%); width:35%; }
  }
  
  .mc-about-toc{ position:sticky; top:14px; }
  .mc-about-toc-title{ font-size:10px; font-weight:800; text-transform:uppercase; letter-spacing:.6px; color:var(--mc-text-muted); margin:2px 0 10px 2px; }
  .mc-about-toc-list a{
    display:block; font-size:12.5px; font-weight:600; color:#444; text-decoration:none;
    padding:7px 0 7px 12px; border-left:2px solid #e2e2e2; line-height:1.3;
  }
  .mc-about-toc-list a:hover{ color:var(--mc-navy); border-left-color:var(--mc-btn-simulate); }
  .mc-about-doc-header{ border-bottom:2px solid var(--mc-navy); padding-bottom:16px; margin-bottom:26px; }
  .mc-about-doc-label{ font-size:10.5px; font-weight:800; letter-spacing:.8px; text-transform:uppercase; color:var(--mc-btn-simulate); margin-bottom:8px; }
  .mc-about-doc-header h2{ font-size:22px; font-weight:800; color:var(--mc-navy); margin:0 0 8px 0; }
  .mc-about-doc-meta{ font-size:12px; color:var(--mc-text-muted); }
  .mc-about-doc-meta span{ margin-right:6px; }
  .mc-about-section{ margin-bottom:32px; padding-bottom:28px; border-bottom:1px solid #ececec; }
  .mc-about-section p{ max-width:900px; }
  .mc-about-section:last-child{ border-bottom:none; margin-bottom:0; padding-bottom:0; }
  .mc-about-section-num{ font-size:11px; font-weight:800; color:var(--mc-btn-simulate); letter-spacing:.4px; display:block; margin-bottom:4px; }
  .mc-about-section h3{ font-size:16.5px; font-weight:800; color:var(--mc-navy); margin:0 0 12px 0; }
  .mc-about-section h4{ font-weight:800; font-size:13.5px; margin:18px 0 6px 0; color:#123A4C; }
  .mc-about-section h4:first-of-type{ margin-top:4px; }
  .mc-about-section p{ font-size:13.5px; color:#2b2b2b; line-height:1.7; margin:0 0 10px 0; }
  .mc-eq{ display:flex; align-items:center; gap:16px; margin:22px 0; }
  .mc-eq-body{ flex:1; min-width:0; overflow-x:auto; text-align:center; padding:2px 0; }
  .mc-eq-num{ flex:0 0 auto; font-size:12px; color:var(--mc-text-muted); font-family:Georgia, Cambria, serif; }
  .mc-ref-list{ font-size:12.5px; color:#333; line-height:1.85; padding-left:18px; }
  .mc-model-table{ width:100%; border-collapse:collapse; font-size:12.5px; margin-top:6px; }
  .mc-model-table th{ text-align:left; font-size:10.5px; text-transform:uppercase; letter-spacing:.3px; color:var(--mc-text-muted); font-weight:700; padding:8px 10px; border-bottom:1px solid #d8d8d8; }
  .mc-model-table td{ padding:11px 10px; border-bottom:1px solid #eee; vertical-align:top; line-height:1.55; }
  .mc-model-table tr:last-child td{ border-bottom:none; }
  .mc-model-table td.mc-model-code{ font-weight:800; color:var(--mc-navy); white-space:nowrap; }
  .mc-model-table td.mc-model-name{ color:#444; }
  .mc-about-table{ width:100%; border-collapse:collapse; font-size:12.5px; margin:8px 0 18px 0; }
  .mc-about-table th{ text-align:left; background:#F4F5F6; font-size:10.5px; text-transform:uppercase; letter-spacing:.3px; color:#555; font-weight:700; padding:9px 10px; border-bottom:1px solid #d8d8d8; }
  .mc-about-table td{ padding:11px 10px; border-bottom:1px solid #ececec; vertical-align:top; line-height:1.6; color:#2b2b2b; }
  .mc-about-table td.field-col{ font-weight:800; color:var(--mc-navy); white-space:nowrap; }
  .mc-about-table td.loc-col{ color:#666; white-space:nowrap; }
  .mc-about-table tr:last-child td{ border-bottom:none; }
  .mc-about-author{
    display:flex; gap:16px; align-items:flex-start; border:1px solid var(--mc-card-border);
    border-radius:8px; padding:18px; background:#FBFBFB;
  }
  .mc-about-author-mark{
    width:42px; height:42px; border-radius:6px; background:var(--mc-navy);
    flex:0 0 auto; display:flex; align-items:center; justify-content:center; color:#fff; font-weight:800; font-size:14px; letter-spacing:.3px;
  }
  .mc-not-available{ color:#999; font-style:italic; font-size:13px; }
  .mc-wald-invalid{ background:#FFF4E5; border:1px solid #F0C36D; border-radius:8px; padding:10px 14px; font-size:13px; color:#7a5200; margin-top:8px; }
  .mc-issuer-meta-grid{ display:grid; grid-template-columns:repeat(4,1fr); gap:10px; margin-bottom:10px; }
  .mc-issuer-meta-item{ background:#F9F9F9; border-radius:8px; padding:10px 12px; }
  .mc-issuer-meta-item .k{ font-size:10px; color:#777; text-transform:uppercase; font-weight:700; }
  .mc-issuer-meta-item .v{ font-size:13px; font-weight:700; margin-top:2px; }
  
  .mc-mae-grid{ display:grid; grid-template-columns:repeat(auto-fit, minmax(160px, 1fr)); gap:12px; }
  .mc-mae-card{ border:1px solid var(--mc-card-border); border-radius:8px; padding:12px; text-align:center; }
  .mc-mae-card.best{ border-color:var(--mc-btn-simulate); background:#EFFbF5; }
  .mc-mae-card .mm-label{ font-size:12px; font-weight:700; color:#555; }
  .mc-mae-card .mm-value{ font-size:20px; font-weight:800; margin-top:4px; }
  .mc-mae-note{ font-size:11px; color:var(--mc-text-muted); margin-top:8px; text-align:right; }
  
  .mc-tabs-2{ display:flex; gap:8px; margin-bottom:12px; }
  .mc-tabs-2 button{ border:1px solid var(--mc-card-border); background:#fff; border-radius:6px; padding:6px 14px; font-weight:700; font-size:12px; cursor:pointer;}
  .mc-tabs-2 button.active{ background:var(--mc-btn-simulate); color:#fff; border-color:var(--mc-btn-simulate); }
  
  @media (max-width: 1100px){
    .mc-summary-grid{ grid-template-columns:repeat(3,1fr); }
    .mc-grid-2{ grid-template-columns:1fr; }
    .mc-grid-2-top{ grid-template-columns:1fr; }
  }
  "

CUSTOM_JS_TEXT <- "(function() {
    var overlayId = \"mc-loading-overlay-el\";
  
    function buildOverlay(stageText) {
      var existing = document.getElementById(overlayId);
      if (existing) existing.remove();
  
      var overlay = document.createElement(\"div\");
      overlay.id = overlayId;
      overlay.className = \"mc-loading-overlay\";
      overlay.innerHTML =
        '<div class=\"mc-loading-panel\">' +
          '<div class=\"mc-loading-spinner\"></div>' +
          '<div class=\"mc-loading-title\">Running Monte Carlo Stress Test</div>' +
          '<div class=\"mc-loading-stage\" id=\"mc-loading-stage-text\">' + stageText + '</div>' +
          '<div class=\"mc-loading-bar-track\"><div class=\"mc-loading-bar-fill\"></div></div>' +
        '</div>';
      document.body.appendChild(overlay);
    }
  
    Shiny.addCustomMessageHandler(\"mc-show-loading\", function(msg) {
      buildOverlay(msg.stage || \"Loading model objects\");
    });
  
    Shiny.addCustomMessageHandler(\"mc-update-stage\", function(msg) {
      var el = document.getElementById(\"mc-loading-stage-text\");
      if (el) el.innerText = msg.stage;
    });
  
    Shiny.addCustomMessageHandler(\"mc-hide-loading\", function(msg) {
      var existing = document.getElementById(overlayId);
      if (existing) existing.remove();
    });
  })();
  "

fmt_num_id <- function(x, digits = 3) {
  if (length(x) == 0) return("N/A")
  ifelse(is.finite(x), formatC(x, format = "f", digits = digits, big.mark = ".", decimal.mark = ","), "N/A")
}

fmt_pct_id <- function(x, digits = 3) {
  if (length(x) == 0) return("N/A")
  ifelse(is.finite(x), paste0(formatC(x, format = "f", digits = digits, big.mark = ".", decimal.mark = ","), "%"), "N/A")
}

fmt_int_id <- function(x) {
  if (length(x) == 0) return("N/A")
  ifelse(is.finite(x), formatC(round(x), format = "d", big.mark = "."), "N/A")
}

fmt_price_id <- function(x) {
  if (length(x) == 0) return("N/A")
  ifelse(is.finite(x), paste0("Rp", formatC(round(x), format = "d", big.mark = ".")), "N/A")
}

clean_ticker <- function(x) {
  toupper(trimws(gsub("[ _]?IJ[ _]EQUITY.*$", "", x, ignore.case = TRUE)))
}

ticker_to_tag <- function(x) {
  gsub("[^A-Za-z0-9]", "_", x)
}

safe_val <- function(x, default = NA) {
  if (is.null(x) || length(x) == 0) return(default)
  x
}

pct_class <- function(x) {
  if (length(x) == 0) return("")
  ifelse(is.finite(x), ifelse(x < 0, "mc-neg", "mc-pos"), "")
}


VAR_DISPLAY_CONFIG <- list(
  list(actual = "JCI Index",            checkbox_label = "JCI Index",   shock_label = "JCI Shock (%):"),
  list(actual = "USDIDR BGN Curncy",     checkbox_label = "USDIDR",      shock_label = "USDIDR Shock (%):"),
  list(actual = "CLA Comdty",            checkbox_label = "CLA Comdty",  shock_label = "CLA Comdty Shock (%):"),
  list(actual = "XAU Curncy",            checkbox_label = "XAU Curncy",  shock_label = "XAU Curncy Shock (%):"),
  list(actual = "XW1 Comdty",            checkbox_label = "XW1 Comdty",  shock_label = "XW1 Comdty Shock (%):"),
  list(actual = "KO1 Comdty",            checkbox_label = "KO1 Comdty",  shock_label = "KO1 Comdty Shock (%):"),
  list(actual = "LMNIDS03 LME Comdty",   checkbox_label = "Nickel",      shock_label = "Nickel Shock (%):"),
  list(actual = "IBPRCPI Index",         checkbox_label = "IBPRCPI",     shock_label = "IBRCPI Index Shock (%):"),
  list(actual = "GTIDR1Y Govt",          checkbox_label = "GTIDR1Y Govt",shock_label = "GTIDR 1Y Govt Shock (%):")
)

get_var_display_config <- function(macro_vars_available) {
  cfg <- VAR_DISPLAY_CONFIG
  resolved <- lapply(cfg, function(x) {
    x$actual_resolved <- mc_resolve_name(x$actual, macro_vars_available)
    x
  })
  Filter(function(x) !is.na(x$actual_resolved), resolved)
}

var_input_id <- function(actual_name) {
  paste0("var_", gsub("[^A-Za-z0-9]", "_", actual_name))
}

shock_input_id <- function(actual_name) {
  paste0("shock_", gsub("[^A-Za-z0-9]", "_", actual_name))
}


fuzzy_match_sheet <- function(sheet_names, patterns) {
  norm <- function(x) tolower(gsub("[^a-z0-9]", "", tolower(x)))
  sn_norm <- norm(sheet_names)
  for (p in patterns) {
    p_norm <- norm(p)
    hit <- which(sn_norm == p_norm)
    if (length(hit) > 0) return(sheet_names[hit[1]])
  }
  for (p in patterns) {
    p_norm <- norm(p)
    hit <- which(grepl(p_norm, sn_norm, fixed = TRUE))
    if (length(hit) > 0) return(sheet_names[hit[1]])
  }
  NA_character_
}

safe_read_sheet <- function(wb_path, patterns) {
  if (is.null(wb_path) || is.na(wb_path) || !file.exists(wb_path)) return(NULL)
  sheets <- tryCatch(openxlsx::getSheetNames(wb_path), error = function(e) NULL)
  if (is.null(sheets)) return(NULL)
  target <- fuzzy_match_sheet(sheets, patterns)
  if (is.na(target)) return(NULL)
  df <- tryCatch(
    openxlsx::read.xlsx(wb_path, sheet = target, detectDates = TRUE, sep.names = " "),
    error = function(e) {
      tryCatch(openxlsx::read.xlsx(wb_path, sheet = target, detectDates = TRUE),
               error = function(e2) NULL)
    }
  )
  if (is.null(df) || nrow(df) == 0) return(NULL)
  attr(df, "source_sheet") <- target
  df
}

get_wald_test_table <- function(wb_path) {
  safe_read_sheet(wb_path, c("Wald Test", "WaldTest", "Wald", "Uji Wald"))
}

get_best_subset_table <- function(wb_path) {
  safe_read_sheet(wb_path, c("Best Subset Selection", "Best Subset", "BestSubset"))
}

get_model_comparison_table <- function(wb_path) {
  safe_read_sheet(wb_path, c("Full State Extraction", "Actual vs Predicted", "Model Comparison", "Forecast",
                             "Actual_vs_Predicted", "Prediction", "Fitted"))
}

get_coefficients_table <- function(wb_path) {
  safe_read_sheet(wb_path, c("Coefficients", "Coefficient", "Estimasi Koefisien", "Beta"))
}

get_regime_forecast_table <- function(wb_path) {
  safe_read_sheet(wb_path, c("Regime Forecast (t+1 to t+10)", "Regime Forecast", "RegimeForecast",
                             "Forecast Regime"))
}

mc_regime_volatility_labels <- function(wb_path, n_states) {
  if (is.null(n_states) || is.na(n_states) || n_states < 1) return(character(0))
  generic <- paste("Regime", seq_len(n_states))
  
  sigma <- rep(NA_real_, n_states)
  ep <- safe_read_sheet(wb_path, c("Estimated Parameters", "EstimatedParameters"))
  if (!is.null(ep)) {
    reg_col <- column_exists(ep, c("Regime"))
    sig_col <- column_exists(ep, c("Sigma", "Std_Dev", "Standard_Deviation"))
    if (!is.na(reg_col) && !is.na(sig_col)) {
      lbl <- trimws(as.character(ep[[reg_col]]))
      val <- suppressWarnings(as.numeric(ep[[sig_col]]))
      for (k in seq_len(n_states)) {
        hit <- which(!is.na(lbl) & nzchar(lbl) & grepl(paste0(k, "$"), lbl) & !is.na(val))
        if (length(hit) > 0) sigma[k] <- val[hit[1]]
      }
    }
  }
  if (!any(is.na(sigma)) && length(unique(sigma)) == n_states) {
    tiers <- if (n_states == 2) {
      c("Low Volatility", "High Volatility")
    } else if (n_states == 3) {
      c("Low Volatility", "Medium Volatility", "High Volatility")
    } else {
      paste0("Volatility Tier ", seq_len(n_states))
    }
    out <- character(n_states)
    out[order(sigma)] <- tiers
    return(out)
  }
  
  rc <- safe_read_sheet(wb_path, c("Regime Classification", "RegimeClassification"))
  if (!is.null(rc)) {
    num_col <- column_exists(rc, c("Regime_Number", "RegimeNumber", "Regime"))
    lab_col <- column_exists(rc, c("Regime_Label", "RegimeLabel", "Label"))
    if (!is.na(num_col) && !is.na(lab_col)) {
      nums <- suppressWarnings(as.integer(rc[[num_col]]))
      labs <- trimws(as.character(rc[[lab_col]]))
      out <- generic
      for (k in seq_len(n_states)) {
        hit <- which(!is.na(nums) & nums == k & !is.na(labs) & nzchar(labs))
        if (length(hit) == 0) next
        tl <- tolower(labs[hit[1]])
        out[k] <- if (grepl("tinggi|high|bear", tl)) {
          "High Volatility"
        } else if (grepl("rendah|low|bull", tl)) {
          "Low Volatility"
        } else labs[hit[1]]
      }
      return(out)
    }
  }
  generic
}

build_regime_forecast_display <- function(wb_path) {
  df <- get_regime_forecast_table(wb_path)
  if (is.null(df)) return(NULL)
  h_col <- column_exists(df, c("Horizon", "Horison", "Step"))
  if (is.na(h_col)) return(NULL)
  
  hz <- trimws(as.character(df[[h_col]]))
  keep <- !is.na(hz) & grepl("^t\\s*\\+\\s*[0-9]+$", hz)
  if (!any(keep)) return(NULL)
  df <- df[keep, , drop = FALSE]
  hz <- gsub("\\s+", "", hz[keep])
  
  nn <- tolower(gsub("[^A-Za-z0-9]", "", names(df)))
  idx <- grep("^probstate[0-9]+$", nn)
  if (length(idx) == 0) return(NULL)
  state_no <- suppressWarnings(as.integer(sub("^probstate", "", nn[idx])))
  ord <- order(state_no)
  idx <- idx[ord]
  state_no <- state_no[ord]
  n_states <- max(state_no, na.rm = TRUE)
  
  labels <- mc_regime_volatility_labels(wb_path, n_states)
  if (length(labels) < n_states) labels <- paste("Regime", seq_len(n_states))
  
  out <- data.frame(Horizon = hz, stringsAsFactors = FALSE, check.names = FALSE)
  for (j in seq_along(idx)) {
    out[[paste0("P(", labels[state_no[j]], ")")]] <- suppressWarnings(as.numeric(df[[idx[j]]]))
  }
  
  exp_col <- column_exists(df, c("Expected_Regime", "ExpectedRegime", "Most_Likely_Regime"))
  if (!is.na(exp_col)) {
    ev <- trimws(as.character(df[[exp_col]]))
    k  <- suppressWarnings(as.integer(gsub("[^0-9]", "", ev)))
    out[["Most Likely Regime"]] <- ifelse(!is.na(k) & k >= 1 & k <= n_states, labels[k], ev)
  }
  
  cum_col <- column_exists(df, c("Cumulative_Avg_Prob_BullState", "Cumulative_Avg_Prob"))
  if (!is.na(cum_col) && "Low Volatility" %in% labels) {
    out[["Cumulative Avg P(Low Volatility)"]] <- suppressWarnings(as.numeric(df[[cum_col]]))
  }
  
  if (nrow(out) == 0) return(NULL)
  attr(out, "regime_labels") <- labels
  out
}

column_exists <- function(df, patterns) {
  if (is.null(df)) return(NA_character_)
  norm <- function(x) tolower(gsub("[^a-z0-9]", "", x))
  cn_norm <- norm(colnames(df))
  for (p in patterns) {
    hit <- which(cn_norm == norm(p))
    if (length(hit) > 0) return(colnames(df)[hit[1]])
  }
  for (p in patterns) {
    hit <- which(grepl(norm(p), cn_norm, fixed = TRUE))
    if (length(hit) > 0) return(colnames(df)[hit[1]])
  }
  NA_character_
}

get_col_safe <- function(df, patterns) {
  if (is.null(df)) return(NULL)
  cname <- column_exists(df, patterns)
  if (is.na(cname)) return(NULL)
  df[[cname]]
}


mc_load_estimation_objects <- function(output_dir) {
  jd <- if (exists("joint_distribution_model", envir = .GlobalEnv)) {
    get("joint_distribution_model", envir = .GlobalEnv)
  } else {
    jd_path <- file.path(output_dir, "JointDistribution_Model.rds")
    if (!file.exists(jd_path)) {
      stop("File 'JointDistribution_Model.rds' tidak ditemukan pada: ", output_dir,
           " - pastikan pipeline DCC-GARCH & Copula telah berhasil dijalankan.")
    }
    readRDS(jd_path)
  }
  
  mm <- if (exists("all_markov_models", envir = .GlobalEnv) &&
            length(get("all_markov_models", envir = .GlobalEnv)) > 0) {
    get("all_markov_models", envir = .GlobalEnv)
  } else {
    mm_path <- file.path(output_dir, "All_Markov_Models.rds")
    if (!file.exists(mm_path)) {
      stop("File 'All_Markov_Models.rds' tidak ditemukan pada: ", output_dir,
           " - pastikan pipeline Markov Switching seluruh issuer telah berhasil dijalankan.")
    }
    readRDS(mm_path)
  }
  
  list(joint_dist = jd, markov_models = mm)
}

mc_resolve_name <- function(target, available) {
  if (length(target) == 0 || length(available) == 0) return(NA_character_)
  target <- as.character(target)[1]
  if (is.na(target)) return(NA_character_)
  available <- as.character(available)
  if (target %in% available) return(target)
  norm_target <- trimws(tolower(target))
  norm_avail  <- trimws(tolower(available))
  idx <- match(norm_target, norm_avail)
  if (!is.na(idx)) return(available[idx])
  squash <- function(z) gsub("[^a-z0-9]", "", tolower(z))
  idx2 <- match(squash(target), squash(available))
  if (!is.na(idx2)) return(available[idx2])
  NA_character_
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
    error = function(e) NULL
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
  
  attr(macro_ret, "not_found_vars") <- not_found_vars
  macro_ret
}

mc_shock_to_quantile <- function(shock_value_pct, var_name, marginal_models) {
  resolved_name <- mc_resolve_name(var_name, names(marginal_models))
  mdl <- if (!is.na(resolved_name)) marginal_models[[resolved_name]] else NULL
  if (is.null(mdl)) return(0.5)
  
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
                            estimation_objects, output_dir, seed = 123,
                            progress_callback = NULL,
                            shock_input_mode = "pct", shock_input_values = NULL,
                            shock_current_levels = NULL) {
  
  notify <- function(stage) if (!is.null(progress_callback)) progress_callback(stage)
  
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
  
  notify("Preparing shock scenario")
  shock_u <- vapply(seq_along(shock_vars), function(j) {
    mc_shock_to_quantile(shock_values[j], shock_vars[j], marginal_models)
  }, numeric(1))
  
  set.seed(seed)
  
  notify("Running conditional Monte Carlo")
  U <- mc_conditional_copula_sample(n_sim, tcop_fit, d, shock_idx, shock_u)
  macro_ret <- mc_uniform_to_macro_returns(U, marginal_models, macro_cols)
  for (j in seq_along(shock_idx)) macro_ret[, shock_idx[j]] <- shock_values[j] / 100
  colnames(macro_ret) <- macro_cols
  
  other_idx_check <- setdiff(seq_along(macro_cols), shock_idx)
  degenerate_vars <- character(0)
  if (length(other_idx_check) > 0) {
    sd_other <- apply(macro_ret[, other_idx_check, drop = FALSE], 2, stats::sd)
    degenerate_vars <- macro_cols[other_idx_check][sd_other < 1e-12 | !is.finite(sd_other)]
  }
  
  notify("Calculating issuer-level statistics")
  stock_names <- names(mm)
  n_stocks <- length(stock_names)
  
  run_one_stock <- function(sname) {
    tryCatch({
      ff <- mm[[sname]]$final_fit
      if (is.null(ff)) stop("final_fit tidak tersedia")
      lag_cols_ff <- if (!is.null(ff$lag_cols)) ff$lag_cols else character(0)
      coef_macro  <- setdiff(ff$coef_names[-1], lag_cols_ff)
      avail_cols  <- colnames(macro_ret)
      
      exact_ok <- all(coef_macro %in% avail_cols)
      
      if (exact_ok) {
        mr <- macro_ret[, coef_macro, drop = FALSE]
      } else {
        coef_macro_norm <- trimws(tolower(coef_macro))
        avail_norm      <- trimws(tolower(avail_cols))
        match_idx <- match(coef_macro_norm, avail_norm)
        
        if (!anyNA(match_idx)) {
          mr <- macro_ret[, avail_cols[match_idx], drop = FALSE]
          colnames(mr) <- coef_macro
        } else if (length(coef_macro) == length(macro_cols) &&
                   identical(sort(trimws(tolower(macro_cols))), sort(avail_norm))) {
          mr <- macro_ret[, macro_cols, drop = FALSE]
          colnames(mr) <- coef_macro
        } else {
          missing_vars <- setdiff(coef_macro, avail_cols)
          stop(paste0("Variabel makro pada model saham TIDAK LENGKAP pada matriks simulasi - ",
                      "variabel yang tidak ditemukan: [", paste(missing_vars, collapse = "; "),
                      "]. Variabel tersedia pada skenario: [", paste(avail_cols, collapse = "; "), "]."))
        }
      }
      
      pred <- mc_predict_stock(mr, ff, use_significant, alpha)
      list(ok = TRUE, value = pred$expected_return,
           yesterday_close = if (!is.null(ff$yesterday_close_price)) ff$yesterday_close_price else NA_real_,
           ar_order = if (!is.null(ff$ar_order)) ff$ar_order else 0L)
    }, error = function(e) list(ok = FALSE, error = conditionMessage(e)))
  }
  
  res_list <- vector("list", n_stocks)
  for (i in seq_along(stock_names)) {
    res_list[[i]] <- run_one_stock(stock_names[i])
    if (i %% 5 == 0 || i == n_stocks) {
      notify(paste0("Calculating issuer-level statistics (", i, "/", n_stocks, ")"))
    }
  }
  
  result_matrix <- matrix(NA_real_, nrow = n_sim, ncol = length(stock_names))
  colnames(result_matrix) <- stock_names
  failed_stocks <- character(0)
  failed_reasons <- character(0)
  yesterday_close_vec <- stats::setNames(rep(NA_real_, length(stock_names)), stock_names)
  ar_order_vec         <- stats::setNames(rep(NA_integer_, length(stock_names)), stock_names)
  
  for (i in seq_along(stock_names)) {
    r <- res_list[[i]]
    if (is.null(r) || !isTRUE(r$ok)) {
      failed_stocks <- c(failed_stocks, stock_names[i])
      failed_reasons <- c(failed_reasons, if (!is.null(r$error)) r$error else "hasil tidak valid")
    } else {
      result_matrix[, i] <- r$value
      yesterday_close_vec[stock_names[i]] <- r$yesterday_close
      ar_order_vec[stock_names[i]]        <- r$ar_order
    }
  }
  
  valid_stocks <- setdiff(stock_names, failed_stocks)
  if (length(valid_stocks) == 0) stop("SELURUH issuer gagal diprediksi pada skenario ini.")
  result_matrix <- result_matrix[, valid_stocks, drop = FALSE]
  
  notify("Generating portfolio impact")
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
  
  notify("Preparing dashboard results")
  list(result_matrix = result_matrix, ranking_table = ranking_table,
       failed_stocks = failed_stocks, failed_reasons = failed_reasons,
       degenerate_vars = degenerate_vars,
       shock_vars = shock_vars, shock_values = shock_values, n_sim = n_sim,
       use_significant = use_significant, alpha = alpha, seed = seed,
       macro_cols = macro_cols, timestamp = Sys.time(),
       shock_input_mode = shock_input_mode,
       shock_input_values = if (is.null(shock_input_values)) shock_values else shock_input_values,
       shock_current_levels = if (is.null(shock_current_levels)) rep(NA_real_, length(shock_values)) else shock_current_levels,
       shock_values_pct_equivalent = shock_values)
}

mc_export_scenario <- function(scenario_result, output_dir) {
  shock_tag <- if (mc_is_level_mode(scenario_result)) {
    paste(mapply(function(v, inp, val) {
      paste0(gsub("[^A-Za-z0-9]", "", v), "_Lvl", inp, "_", ifelse(val >= 0, "+", ""), round(val, 2), "pct")
    }, scenario_result$shock_vars, mc_shock_input_values(scenario_result), scenario_result$shock_values),
    collapse = "_")
  } else {
    paste(mapply(function(v, val) {
      paste0(gsub("[^A-Za-z0-9]", "", v), "_", ifelse(val >= 0, "+", ""), val, "pct")
    }, scenario_result$shock_vars, scenario_result$shock_values), collapse = "_")
  }
  
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
    Shock_Input_Mode     = mc_shock_mode_label(scenario_result),
    Shock_Input_Values   = paste(mc_shock_input_values(scenario_result), collapse = ", "),
    Shock_Current_Levels = paste(mc_shock_current_levels(scenario_result), collapse = ", "),
    Shock_Pct_Equivalent = paste(scenario_result$shock_values, collapse = ", "),
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
  cat("Mode Input Shock :", mc_shock_mode_label(scenario_result), "\n")
  if (mc_is_level_mode(scenario_result)) {
    cat("Target Level     :", paste(mc_shock_input_values(scenario_result), collapse = ", "), "\n")
    cat("Level Saat Ini   :", paste(mc_shock_current_levels(scenario_result), collapse = ", "), "\n")
  }
  cat("Jumlah Simulasi  :", scenario_result$n_sim, "\n")
  cat("Random Seed      :", scenario_result$seed, "\n")
  cat("Koef. Signifikan Saja:", scenario_result$use_significant,
      "(alpha =", scenario_result$alpha, ")\n\n")
  cat("TABEL RANKING SAHAM\n"); print(scenario_result$ranking_table); cat("\n")
  if (length(scenario_result$failed_stocks) > 0) {
    cat("SAHAM DILEWATI (gagal diprediksi):", paste(scenario_result$failed_stocks, collapse = ", "), "\n")
  }
  sink()
  
  invisible(list(xlsx_path = xlsx_path, csv_path = csv_path, rds_path = rds_path,
                 txt_path = txt_path, mc_dir = mc_dir))
}

mc_plot_stock_distribution <- function(scenario_result, stock_code, output_dir, save_to_disk = TRUE) {
  if (!(stock_code %in% colnames(scenario_result$result_matrix))) {
    return(NULL)
  }
  ret_vec <- scenario_result$result_matrix[, stock_code] * 100
  expected_ret <- mean(ret_vec)
  var95 <- stats::quantile(ret_vec, probs = 0.05, names = FALSE)
  
  df_plot <- data.frame(Return = ret_vec)
  
  p_hist <- ggplot2::ggplot(df_plot, ggplot2::aes(x = Return)) +
    ggplot2::geom_histogram(ggplot2::aes(y = ggplot2::after_stat(density)),
                            bins = 60, fill = "#1f78b4", color = "white", alpha = 0.85) +
    ggplot2::geom_density(color = "#e31a1c", linewidth = 0.8) +
    ggplot2::geom_vline(xintercept = expected_ret, linetype = "dashed", color = "#0D223C", linewidth = 0.8) +
    ggplot2::geom_vline(xintercept = 0, linetype = "dotted", color = "#666666", linewidth = 0.6) +
    ggplot2::geom_vline(xintercept = var95, linetype = "dashed", color = "#C0392B", linewidth = 0.8) +
    ggplot2::labs(title = paste("Monte Carlo Return Distribution -", clean_ticker(stock_code)),
                  subtitle = if (mc_is_level_mode(scenario_result)) {
                    paste0("Shock scenario: ", paste(mc_shock_level_descriptions(scenario_result), collapse = "; "))
                  } else {
                    paste0("Shock scenario: ",
                           paste(scenario_result$shock_vars, collapse = ", "), " = ",
                           paste(scenario_result$shock_values, collapse = ", "), "%")
                  },
                  x = "Simulated Return (%)", y = "Density") +
    ggplot2::theme_minimal(base_size = 12)
  
  hist_path <- NA_character_
  if (isTRUE(save_to_disk)) {
    plot_dir <- file.path(output_dir, "Plots", "MonteCarlo")
    if (!dir.exists(plot_dir)) dir.create(plot_dir, recursive = TRUE)
    ts_tag <- format(Sys.time(), "%Y%m%d_%H%M%S")
    hist_path <- file.path(plot_dir, paste0("Histogram_", ticker_to_tag(stock_code), "_", ts_tag, ".png"))
    tryCatch(ggplot2::ggsave(hist_path, p_hist, width = 8, height = 5, dpi = 150), error = function(e) NULL)
  }
  
  list(plot = p_hist, hist_path = hist_path, expected_return = expected_ret, var95 = var95)
}


REQUIRED_CORE_FILES <- c("All_Markov_Models.rds", "JointDistribution_Model.rds")

discover_root_structure <- function(root_dir) {
  status <- list(root_dir = root_dir, valid = FALSE, missing = character(0), messages = character(0))
  
  if (!dir.exists(root_dir)) {
    status$messages <- c(status$messages, paste0("Directory tidak ditemukan: ", root_dir))
    return(status)
  }
  
  for (f in REQUIRED_CORE_FILES) {
    fp <- file.path(root_dir, f)
    if (!file.exists(fp)) status$missing <- c(status$missing, f)
  }
  
  status$all_rds   <- list.files(root_dir, pattern = "\\.rds$", recursive = TRUE, full.names = TRUE)
  status$all_xlsx  <- list.files(root_dir, pattern = "\\.xlsx$", recursive = TRUE, full.names = TRUE)
  status$all_csv   <- list.files(root_dir, pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
  status$all_png   <- list.files(root_dir, pattern = "\\.png$", recursive = TRUE, full.names = TRUE)
  status$all_pdf   <- list.files(root_dir, pattern = "\\.pdf$", recursive = TRUE, full.names = TRUE)
  status$plots_dir <- file.path(root_dir, "Plots")
  status$mc_dir    <- file.path(root_dir, "MonteCarlo")
  
  status$valid <- length(status$missing) == 0
  status
}

load_core_models <- function(root_dir) {
  objs <- mc_load_estimation_objects(root_dir)
  list(
    joint_dist    = objs$joint_dist,
    markov_models = objs$markov_models
  )
}

build_issuer_registry <- function(markov_models, root_dir) {
  raw_names <- names(markov_models)
  if (length(raw_names) == 0) return(data.frame())
  
  registry <- lapply(raw_names, function(nm) {
    mdl <- markov_models[[nm]]
    tag <- ticker_to_tag(nm)
    wb_candidates <- list.files(root_dir, pattern = paste0("^Output_MarkovRegimeSwitching_", tag, ".*\\.xlsx$"),
                                recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    plot_dir_candidates <- list.files(file.path(root_dir, "Plots"), pattern = paste0("^", tag, "$"),
                                      full.names = TRUE, ignore.case = TRUE)
    
    data.frame(
      raw_ticker   = nm,
      clean_ticker = clean_ticker(nm),
      tag          = tag,
      sector       = safe_val(mdl$sector_classification, "Not Available"),
      best_k       = safe_val(mdl$best_k, NA_integer_),
      n_selected   = length(safe_val(mdl$selected_variables, character(0))),
      selected_variables = paste(safe_val(mdl$selected_variables, character(0)), collapse = ", "),
      mandatory_variables = paste(safe_val(mdl$mandatory_variables, character(0)), collapse = ", "),
      ar_order     = safe_val(mdl$ar_order_p, NA_integer_),
      frequency    = safe_val(mdl$frequency, "Not Available"),
      aggregation_method = safe_val(mdl$aggregation_method, "Not Available"),
      sample_start = safe_val(as.character(mdl$sample_start_date), "Not Available"),
      sample_end   = safe_val(as.character(mdl$sample_end_date), "Not Available"),
      workbook_path = if (length(wb_candidates) > 0) wb_candidates[1] else NA_character_,
      plots_dir     = if (length(plot_dir_candidates) > 0) plot_dir_candidates[1] else NA_character_,
      has_final_fit = !is.null(mdl$final_fit),
      stringsAsFactors = FALSE
    )
  })
  
  out <- do.call(rbind, registry)
  out[order(out$clean_ticker), ]
}

get_macro_variable_list <- function(joint_dist) {
  vars <- tryCatch(joint_dist$variabel_makro, error = function(e) NULL)
  if (is.null(vars) || length(vars) == 0) return(character(0))
  vars
}

validate_model_integrity <- function(markov_models, joint_dist) {
  issues <- character(0)
  macro_vars <- get_macro_variable_list(joint_dist)
  
  if (length(macro_vars) == 0) {
    issues <- c(issues, "JointDistribution_Model.rds tidak memiliki daftar variabel makro (variabel_makro).")
  }
  if (is.null(joint_dist$marginal_models) || length(joint_dist$marginal_models) == 0) {
    issues <- c(issues, "JointDistribution_Model.rds tidak memiliki marginal_models yang valid.")
  }
  if (is.null(joint_dist$copula_terbaik) || is.null(joint_dist$copula_terbaik$fit)) {
    issues <- c(issues, "JointDistribution_Model.rds tidak memiliki objek fit Student-t Copula yang valid.")
  }
  
  if (length(markov_models) == 0) {
    issues <- c(issues, "All_Markov_Models.rds kosong - tidak ada model issuer yang tersedia.")
  }
  
  for (nm in names(markov_models)) {
    mdl <- markov_models[[nm]]
    ff <- mdl$final_fit
    if (is.null(ff)) {
      issues <- c(issues, paste0("Issuer '", nm, "': final_fit tidak tersedia."))
      next
    }
    sv <- mdl$selected_variables
    if (is.null(sv) || length(sv) < 4 || !("JCI Index" %in% sv)) {
      issues <- c(issues, paste0("Issuer '", nm, "': selected_variables tidak memenuhi constraint minimum ",
                                 "(>=4 variabel & JCI Index wajib)."))
    }
    if (is.null(ff$beta_mat) || is.null(ff$coef_names)) {
      issues <- c(issues, paste0("Issuer '", nm, "': beta_mat/coef_names tidak tersedia pada final_fit."))
      next
    }
    if (nrow(ff$beta_mat) != length(ff$coef_names)) {
      issues <- c(issues, paste0("Issuer '", nm, "': dimensi beta_mat tidak sama dengan panjang coef_names."))
    }
  }
  
  list(ok = length(issues) == 0, issues = issues)
}


safe_as_date_id <- function(x) {
  if (inherits(x, "Date")) return(x)
  if (inherits(x, "POSIXt")) return(as.Date(x))
  if (is.numeric(x)) return(as.Date(x, origin = "1899-12-30"))
  x_chr <- trimws(as.character(x))
  out <- as.Date(rep(NA_character_, length(x_chr)))
  iso <- suppressWarnings(as.Date(x_chr, format = "%Y-%m-%d"))
  out[!is.na(iso)] <- iso[!is.na(iso)]
  remaining <- is.na(out) & !is.na(x_chr) & nzchar(x_chr)
  if (any(remaining)) {
    dmy <- suppressWarnings(as.Date(x_chr[remaining], format = "%d/%m/%Y"))
    out[remaining][!is.na(dmy)] <- dmy[!is.na(dmy)]
  }
  remaining <- is.na(out) & !is.na(x_chr) & nzchar(x_chr)
  if (any(remaining)) {
    serial <- suppressWarnings(as.numeric(x_chr[remaining]))
    out[remaining][!is.na(serial)] <- as.Date(serial[!is.na(serial)], origin = "1899-12-30")
  }
  out
}

calc_log_return <- function(price_vector) {
  price_vector <- as.numeric(price_vector)
  c(NA, diff(log(price_vector)))
}

calc_first_diff <- function(x) {
  x <- as.numeric(x)
  c(NA, diff(x))
}

detect_transformation_type <- function(markov_model) {
  tt <- tryCatch(markov_model$final_fit$transformation_type, error = function(e) NULL)
  if (!is.null(tt) && nzchar(tt)) return(tt)
  "log_return"
}

find_raw_data_path <- function(root_dir) {
  cands <- list.files(root_dir, pattern = "^raw_data.*\\.xlsx$", full.names = TRUE,
                      recursive = TRUE, ignore.case = TRUE)
  if (length(cands) > 0) return(cands[1])
  NULL
}

# ---------------------------------------------------------------------------
# Shock input mode layer ("Percentage Change" vs "Direct Price / Level").
# Direct Price / Level is ONLY an input layer: target levels are converted to
# percentage-change equivalents with ((P1 / P0) - 1) * 100 (P0 = latest valid
# observation in raw_data) BEFORE entering the existing shock machinery.
# ---------------------------------------------------------------------------
SHOCK_MODE_CHOICES <- c("Percentage Change" = "pct", "Direct Price / Level" = "level")

shock_label_for_mode <- function(cfg_item, mode = "pct") {
  if (identical(mode, "level")) {
    lbl <- sub("\\s*Shock \\(%\\):\\s*$", " Target Level:", cfg_item$shock_label)
    if (identical(lbl, cfg_item$shock_label)) lbl <- paste0(cfg_item$checkbox_label, " Target Level:")
    lbl
  } else {
    cfg_item$shock_label
  }
}

mc_latest_raw_levels <- function(root_dir, var_names) {
  var_names <- as.character(var_names)
  empty_info <- function(msg) list(level = NA_real_, date = as.Date(NA), column = NA_character_,
                                   sheet = NA_character_, error = msg)
  out <- stats::setNames(lapply(var_names, function(v) empty_info(NULL)), var_names)
  fail_all <- function(msg) stats::setNames(lapply(var_names, function(v) empty_info(msg)), var_names)
  if (length(var_names) == 0) return(out)
  
  raw_path <- if (length(root_dir) == 0 || is.na(root_dir[1])) NULL else find_raw_data_path(root_dir[1])
  if (is.null(raw_path)) return(fail_all("raw_data file was not found"))
  sheets <- tryCatch(openxlsx::getSheetNames(raw_path), error = function(e) NULL)
  if (is.null(sheets) || length(sheets) == 0) return(fail_all("raw_data file could not be read"))
  
  rest <- sheets[-1]
  sheet_order <- c(sheets[1], rest[!grepl("return|log", rest, ignore.case = TRUE)])
  
  for (sh in sheet_order) {
    pending <- var_names[vapply(out, function(z) !is.finite(z$level), logical(1))]
    if (length(pending) == 0) break
    df <- tryCatch(openxlsx::read.xlsx(raw_path, sheet = sh, detectDates = TRUE, sep.names = " "),
                   error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) next
    date_col <- column_exists(df, c("Dates", "Date", "Tanggal"))
    if (is.na(date_col)) next
    dts <- safe_as_date_id(df[[date_col]])
    avail <- setdiff(names(df), date_col)
    for (v in pending) {
      col <- mc_resolve_name(v, avail)
      if (is.na(col)) next
      vals <- if (is.numeric(df[[col]])) df[[col]] else suppressWarnings(as.numeric(as.character(df[[col]])))
      valid <- which(!is.na(dts) & is.finite(vals))
      if (length(valid) == 0) next
      last_date <- max(dts[valid])
      pick <- utils::tail(valid[dts[valid] == last_date], 1)
      out[[v]] <- list(level = vals[pick], date = last_date, column = col, sheet = sh, error = NULL)
    }
  }
  
  for (v in var_names) {
    if (!is.finite(out[[v]]$level) && is.null(out[[v]]$error)) {
      out[[v]]$error <- "no valid observation was found for this variable in raw_data"
    }
  }
  out
}

mc_level_to_pct <- function(target_level, current_level, var_name = "variable") {
  if (length(target_level) != 1 || !is.numeric(target_level) || !is.finite(target_level)) {
    stop("Target level for ", var_name, " must be a valid finite number.", call. = FALSE)
  }
  if (length(current_level) != 1 || !is.numeric(current_level) || !is.finite(current_level) || current_level <= 0) {
    stop("Current level for ", var_name, " from raw_data is not valid (must be a finite number greater than zero), ",
         "so the percentage change cannot be computed.", call. = FALSE)
  }
  pct <- (target_level / current_level - 1) * 100
  if (!is.finite(pct) || pct <= -100) {
    stop("Target level for ", var_name, " must be greater than zero (an equivalent change of -100% or lower is not valid).",
         call. = FALSE)
  }
  pct
}

mc_convert_levels_to_pct <- function(shock_vars, target_levels, levels_info) {
  current <- rep(NA_real_, length(shock_vars))
  pct <- rep(NA_real_, length(shock_vars))
  for (j in seq_along(shock_vars)) {
    info <- if (is.null(levels_info)) NULL else levels_info[[shock_vars[j]]]
    if (is.null(info) || !is.finite(info$level)) {
      why <- if (!is.null(info) && !is.null(info$error)) paste0(" (", info$error, ")") else ""
      stop("Current level for ", shock_vars[j], " could not be obtained from raw_data", why,
           ". The Direct Price / Level scenario was cancelled.", call. = FALSE)
    }
    current[j] <- info$level
    pct[j] <- mc_level_to_pct(target_levels[j], info$level, shock_vars[j])
  }
  list(pct = pct, current = current)
}

mc_scenario_input_mode <- function(sr) {
  m <- sr$shock_input_mode
  if (is.null(m) || length(m) == 0 || is.na(m[1])) "pct" else as.character(m[1])
}

mc_is_level_mode <- function(sr) identical(mc_scenario_input_mode(sr), "level")

mc_shock_mode_label <- function(sr) {
  if (mc_is_level_mode(sr)) "Direct Price / Level" else "Percentage Change"
}

mc_shock_input_values <- function(sr) {
  if (mc_is_level_mode(sr) && !is.null(sr$shock_input_values)) sr$shock_input_values else sr$shock_values
}

mc_shock_current_levels <- function(sr) {
  if (mc_is_level_mode(sr) && !is.null(sr$shock_current_levels)) sr$shock_current_levels
  else rep("N/A", length(sr$shock_vars))
}

mc_shock_display_values <- function(sr) {
  if (mc_is_level_mode(sr)) round(sr$shock_values, 4) else sr$shock_values
}

mc_shock_level_descriptions <- function(sr) {
  vapply(seq_along(sr$shock_vars), function(j) {
    paste0(sr$shock_vars[j], " target ", fmt_num_id(mc_shock_input_values(sr)[j], 2), " (",
           ifelse(sr$shock_values[j] >= 0, "+", ""), fmt_num_id(sr$shock_values[j], 3),
           "% vs current ", fmt_num_id(sr$shock_current_levels[j], 2), ")")
  }, character(1))
}


get_issuer_log_return_panel <- function(wb_path) {
  df <- safe_read_sheet(wb_path, c("Log Return"))
  if (is.null(df)) return(NULL)
  date_col <- column_exists(df, c("Dates", "Date", "Tanggal"))
  if (is.na(date_col)) return(NULL)
  names(df)[names(df) == date_col] <- "Date"
  df$Date <- safe_as_date_id(df$Date)
  value_cols <- setdiff(names(df), "Date")
  for (cc in value_cols) {
    if (!is.numeric(df[[cc]])) df[[cc]] <- suppressWarnings(as.numeric(as.character(df[[cc]])))
  }
  df <- df[!is.na(df$Date), , drop = FALSE]
  if (nrow(df) == 0) return(NULL)
  df[order(df$Date), , drop = FALSE]
}

mc_split_variable_list <- function(vars_txt) {
  if (length(vars_txt) == 0) return(character(0))
  vars_txt <- as.character(vars_txt)[1]
  if (is.na(vars_txt) || !nzchar(trimws(vars_txt))) return(character(0))
  parts <- trimws(strsplit(vars_txt, "\\+|,")[[1]])
  parts <- parts[nzchar(parts)]
  unique(parts)
}

get_issuer_best_subset_selected_vars <- function(wb_path) {
  summ <- safe_read_sheet(wb_path, c("Best Subset Summary", "BestSubsetSummary"))
  if (!is.null(summ) && nrow(summ) > 0) {
    sel_col <- column_exists(summ, c("Selected_Variables", "SelectedVariables", "Variabel_Terpilih"))
    if (!is.na(sel_col)) {
      out <- mc_split_variable_list(summ[[sel_col]][1])
      if (length(out) > 0) return(out)
    }
  }
  bs <- get_best_subset_table(wb_path)
  if (is.null(bs) || nrow(bs) == 0) return(character(0))
  var_col <- column_exists(bs, c("Variables", "Variabel"))
  if (is.na(var_col)) return(character(0))
  terpilih_col <- column_exists(bs, c("Terpilih"))
  bic_col <- column_exists(bs, c("Rank_BIC", "RankBIC"))
  row_idx <- NA_integer_
  if (!is.na(terpilih_col)) {
    flag <- trimws(as.character(bs[[terpilih_col]]))
    hits <- which(!is.na(flag) & nzchar(flag))
    if (length(hits) > 0) row_idx <- hits[1]
  }
  if (is.na(row_idx) && !is.na(bic_col)) {
    rk <- suppressWarnings(as.numeric(bs[[bic_col]]))
    if (any(!is.na(rk))) row_idx <- which.min(rk)
  }
  if (is.na(row_idx)) row_idx <- 1L
  mc_split_variable_list(bs[[var_col]][row_idx])
}

build_issuer_regression_data <- function(issuer_row) {
  if (is.null(issuer_row) || nrow(issuer_row) == 0) return(NULL)
  wb_path <- issuer_row$workbook_path
  panel <- get_issuer_log_return_panel(wb_path)
  if (is.null(panel)) return(NULL)
  
  stock_col <- mc_resolve_name(issuer_row$raw_ticker, names(panel))
  if (is.na(stock_col) && !is.null(issuer_row$clean_ticker)) {
    stock_col <- mc_resolve_name(issuer_row$clean_ticker, names(panel))
  }
  if (is.na(stock_col) && !is.null(issuer_row$clean_ticker)) {
    stock_col <- mc_resolve_name(paste(issuer_row$clean_ticker, "IJ EQUITY"), names(panel))
  }
  if (is.na(stock_col)) {
    macro_known <- vapply(VAR_DISPLAY_CONFIG, function(x) x$actual, character(1))
    macro_resolved <- vapply(macro_known, function(v) mc_resolve_name(v, names(panel)), character(1))
    macro_resolved <- macro_resolved[!is.na(macro_resolved)]
    leftovers <- setdiff(names(panel), c("Date", macro_resolved))
    leftovers <- leftovers[vapply(leftovers, function(cc) is.numeric(panel[[cc]]), logical(1))]
    if (length(leftovers) > 0) stock_col <- leftovers[1]
  }
  if (is.na(stock_col)) return(NULL)
  if (all(is.na(panel[[stock_col]]))) return(NULL)
  
  attr(panel, "stock_col") <- stock_col
  panel
}

fit_simple_regression <- function(panel, stock_col, jci_col = "JCI Index") {
  if (is.null(panel) || is.na(stock_col)) return(NULL)
  jci_resolved <- mc_resolve_name(jci_col, names(panel))
  if (is.na(jci_resolved)) return(NULL)
  dat <- data.frame(Date = panel$Date, y = panel[[stock_col]],
                    panel[, jci_resolved, drop = FALSE], check.names = FALSE)
  dat <- dat[stats::complete.cases(dat), ]
  if (nrow(dat) < 15) return(NULL)
  formula_txt <- paste0("y ~ `", jci_resolved, "`")
  fit <- tryCatch(stats::lm(stats::as.formula(formula_txt), data = dat), error = function(e) NULL)
  if (is.null(fit)) return(NULL)
  smry <- summary(fit)
  coefs <- smry$coefficients
  if (nrow(coefs) < 2) return(NULL)
  list(
    fit = fit, dates = dat$Date, fitted = unname(stats::fitted(fit)),
    r_squared = smry$r.squared, adj_r_squared = smry$adj.r.squared,
    residual_se = smry$sigma, n_obs = nrow(dat),
    intercept = coefs[1, 1], intercept_se = coefs[1, 2],
    beta_jci = coefs[2, 1], beta_jci_se = coefs[2, 2], beta_jci_p = coefs[2, 4],
    used_vars = jci_resolved
  )
}

fit_multiple_regression <- function(panel, stock_col, selected_vars) {
  if (is.null(panel) || is.na(stock_col)) return(NULL)
  selected_vars <- trimws(as.character(selected_vars))
  selected_vars <- selected_vars[!is.na(selected_vars) & nzchar(selected_vars)]
  if (length(selected_vars) == 0) return(NULL)
  resolved_vars <- vapply(selected_vars, function(v) mc_resolve_name(v, names(panel)), character(1))
  resolved_vars <- unique(resolved_vars[!is.na(resolved_vars)])
  resolved_vars <- setdiff(resolved_vars, stock_col)
  if (length(resolved_vars) == 0) return(NULL)
  dat <- data.frame(Date = panel$Date, y = panel[[stock_col]],
                    panel[, resolved_vars, drop = FALSE], check.names = FALSE)
  dat <- dat[stats::complete.cases(dat), ]
  if (nrow(dat) < 15) return(NULL)
  formula_txt <- paste0("y ~ ", paste0("`", resolved_vars, "`", collapse = " + "))
  fit <- tryCatch(stats::lm(stats::as.formula(formula_txt), data = dat), error = function(e) NULL)
  if (is.null(fit)) return(NULL)
  smry <- summary(fit)
  list(
    fit = fit, dates = dat$Date, fitted = unname(stats::fitted(fit)),
    r_squared = smry$r.squared, adj_r_squared = smry$adj.r.squared,
    residual_se = smry$sigma, n_obs = nrow(dat),
    coefficients = smry$coefficients, used_vars = resolved_vars
  )
}

predict_under_shock <- function(reg_fit, shock_vars, shock_values) {
  if (is.null(reg_fit)) return(NA_real_)
  fit <- reg_fit$fit
  coef_names <- names(stats::coef(fit))
  pred_names <- gsub("^`|`$", "", coef_names[-1])
  new_row <- as.list(stats::setNames(rep(0, length(pred_names)), pred_names))
  for (j in seq_along(shock_vars)) {
    vname <- shock_vars[j]
    cn <- coef_names[coef_names == paste0("`", vname, "`") | coef_names == vname]
    if (length(cn) == 0) {
      resolved <- mc_resolve_name(vname, pred_names)
      if (!is.na(resolved)) cn <- resolved
    }
    if (length(cn) > 0) {
      key <- gsub("^`|`$", "", cn[1])
      new_row[[key]] <- shock_values[j] / 100
    }
  }
  new_df <- as.data.frame(new_row, check.names = FALSE)
  pred <- tryCatch(stats::predict(fit, newdata = new_df), error = function(e) NA_real_)
  unname(pred[1])
}

get_my_model_actual_fitted <- function(wb_path) {
  df <- get_model_comparison_table(wb_path)
  if (is.null(df)) return(NULL)
  
  date_col   <- column_exists(df, c("Dates", "Date", "Tanggal"))
  actual_col <- column_exists(df, c("Actual_Return", "Actual", "Return_Actual", "Aktual"))
  fit_col    <- column_exists(df, c("Fitted_Value_ProbWeighted", "Fitted_Value", "Predicted", "Fitted", "My Model"))
  
  if (is.na(date_col) || is.na(actual_col) || is.na(fit_col)) return(NULL)
  
  out <- data.frame(
    Date    = safe_as_date_id(df[[date_col]]),
    Actual  = suppressWarnings(as.numeric(df[[actual_col]])),
    MyModel = suppressWarnings(as.numeric(df[[fit_col]]))
  )
  out <- out[stats::complete.cases(out), ]
  if (nrow(out) == 0) return(NULL)
  out
}

build_historical_comparison_bundle <- function(root_dir, issuer_row, markov_model) {
  my_model <- get_my_model_actual_fitted(issuer_row$workbook_path)
  
  panel <- build_issuer_regression_data(issuer_row)
  stock_col <- if (!is.null(panel)) attr(panel, "stock_col") else NA_character_
  
  selected_vars <- safe_val(markov_model$selected_variables, character(0))
  if (length(selected_vars) == 0) {
    selected_vars <- get_issuer_best_subset_selected_vars(issuer_row$workbook_path)
  }
  
  simple_reg <- if (!is.null(panel)) fit_simple_regression(panel, stock_col, "JCI Index") else NULL
  multi_reg  <- if (!is.null(panel)) fit_multiple_regression(panel, stock_col, selected_vars) else NULL
  
  combined <- NULL
  if (!is.null(panel)) {
    combined <- data.frame(Date = panel$Date, Actual = panel[[stock_col]])
    if (!is.null(simple_reg)) {
      combined <- merge(combined, data.frame(Date = simple_reg$dates, SimpleRegression = simple_reg$fitted),
                        by = "Date", all.x = TRUE)
    }
    if (!is.null(multi_reg)) {
      combined <- merge(combined, data.frame(Date = multi_reg$dates, MultipleRegression = multi_reg$fitted),
                        by = "Date", all.x = TRUE)
    }
    if (!is.null(my_model)) {
      combined <- merge(combined, my_model[, c("Date", "MyModel")], by = "Date", all.x = TRUE)
    }
    combined <- combined[order(combined$Date), ]
  } else if (!is.null(my_model)) {
    combined <- my_model
  }
  
  mae_cols_present <- if (!is.null(combined)) {
    intersect(c("Actual", "MyModel", "SimpleRegression", "MultipleRegression"), names(combined))
  } else character(0)
  common_valid <- if (!is.null(combined) && length(mae_cols_present) >= 2) {
    stats::complete.cases(combined[, mae_cols_present, drop = FALSE])
  } else NULL
  n_obs_common <- if (!is.null(common_valid)) sum(common_valid) else 0L
  
  mae_from_common_sample <- function(model_col) {
    if (is.null(combined) || is.null(common_valid) || !(model_col %in% names(combined))) return(NA_real_)
    if (n_obs_common < 15) return(NA_real_)
    mean(abs(combined$Actual[common_valid] - combined[[model_col]][common_valid]), na.rm = TRUE)
  }
  
  mae_my_model <- mae_from_common_sample("MyModel")
  mae_multi    <- mae_from_common_sample("MultipleRegression")
  mae_simple   <- mae_from_common_sample("SimpleRegression")
  
  sample_label <- if (!is.null(combined) && !is.null(common_valid) && n_obs_common > 0) {
    dd <- combined$Date[common_valid]
    dd <- dd[!is.na(dd)]
    if (length(dd) > 0) paste0(format(min(dd), "%b %Y"), " - ", format(max(dd), "%b %Y")) else NA_character_
  } else NA_character_
  
  list(
    combined = combined, available = !is.null(combined),
    mae_my_model = mae_my_model, mae_simple = mae_simple, mae_multiple = mae_multi,
    n_obs_common = n_obs_common, sample_label = sample_label,
    selected_vars = selected_vars,
    simple_reg = simple_reg, multi_reg = multi_reg,
    unavailable_reason = if (is.null(combined)) {
      paste0("No 'Full State Extraction' sheet and no 'Log Return' sheet could be found in ",
             issuer_row$clean_ticker, "'s MS-AR output workbook, so the historical comparison ",
             "cannot be computed.")
    } else NA_character_
  )
}

build_regression_benchmark <- function(root_dir, issuer_row, markov_model, shock_vars, shock_values) {
  panel <- build_issuer_regression_data(issuer_row)
  stock_col <- if (!is.null(panel)) attr(panel, "stock_col") else NA_character_
  
  selected_vars <- safe_val(markov_model$selected_variables, character(0))
  if (length(selected_vars) == 0) {
    selected_vars <- get_issuer_best_subset_selected_vars(issuer_row$workbook_path)
  }
  
  simple_reg <- if (!is.null(panel)) fit_simple_regression(panel, stock_col, "JCI Index") else NULL
  multi_reg  <- if (!is.null(panel)) fit_multiple_regression(panel, stock_col, selected_vars) else NULL
  
  simple_pred <- if (!is.null(simple_reg) && "JCI Index" %in% shock_vars) {
    predict_under_shock(simple_reg, shock_vars[shock_vars == "JCI Index"],
                        shock_values[shock_vars == "JCI Index"])
  } else if (!is.null(simple_reg)) {
    NA_real_
  } else NA_real_
  
  multi_pred <- if (!is.null(multi_reg)) predict_under_shock(multi_reg, shock_vars, shock_values) else NA_real_
  
  list(
    series_available = !is.null(panel),
    n_obs = if (!is.null(panel)) sum(stats::complete.cases(panel)) else 0,
    simple_reg = simple_reg, multi_reg = multi_reg,
    simple_pred_pct = simple_pred * 100, multi_pred_pct = multi_pred * 100,
    transformation_type = detect_transformation_type(markov_model)
  )
}

build_comparison_table_row <- function(bench, mc_pred_pct) {
  data.frame(
    Method = c("HRA Bloomberg (JCI)", "XLTP XMUR Bloomberg (Best Subset)", "Monte Carlo Simulation"),
    Predicted_Return_pct = c(bench$simple_pred_pct, bench$multi_pred_pct, mc_pred_pct),
    N_Obs = c(
      if (!is.null(bench$simple_reg)) bench$simple_reg$n_obs else NA_integer_,
      if (!is.null(bench$multi_reg)) bench$multi_reg$n_obs else NA_integer_,
      NA_integer_
    ),
    stringsAsFactors = FALSE
  )
}

ALERT_CONFIG <- list(
  expected_return_critical_pct = -3.0,
  expected_return_warning_pct  = -1.0,
  expected_return_positive_pct = 1.0,
  var95_critical_pct           = -5.0,
  var95_warning_pct            = -3.0,
  probloss_critical_pct        = 80,
  probloss_warning_pct         = 60,
  sector_impact_warning_pct    = -1.5,
  sector_impact_positive_pct   = 1.0,
  sensitivity_top_n            = 3,
  concentration_share_pct      = 40,
  data_update_note             = TRUE
)

.alert_id_counter <- local({
  i <- 0
  function() { i <<- i + 1; i }
})

new_alert <- function(severity, title, issuer, sector, metric, value, threshold, description) {
  data.frame(
    id = .alert_id_counter(),
    severity = severity,
    title = title,
    issuer = ifelse(is.null(issuer) || is.na(issuer), "-", issuer),
    sector = ifelse(is.null(sector) || is.na(sector), "-", sector),
    metric = metric,
    value = value,
    threshold = threshold,
    description = description,
    stringsAsFactors = FALSE
  )
}

severity_rank <- function(sev) {
  match(sev, c("Critical", "Warning", "Caution", "Information"))
}

generate_alerts <- function(scenario_result, markov_models, issuer_registry) {
  alerts <- list()
  rk <- scenario_result$ranking_table
  if (is.null(rk) || nrow(rk) == 0) return(data.frame())
  
  sector_of <- function(ticker) {
    if (is.null(issuer_registry) || nrow(issuer_registry) == 0) return(NA)
    issuer_registry$sector[match(ticker, issuer_registry$raw_ticker)]
  }
  
  worst <- rk[which.min(rk$ExpectedReturn_pct), ]
  worst_sev <- if (worst$ExpectedReturn_pct <= ALERT_CONFIG$expected_return_critical_pct) "Critical" else "Warning"
  alerts[[length(alerts) + 1]] <- new_alert(
    worst_sev, "Highest potential loss issuer", clean_ticker(worst$Kode_Saham), sector_of(worst$Kode_Saham),
    "ExpectedReturn_pct", worst$ExpectedReturn_pct, ALERT_CONFIG$expected_return_critical_pct,
    paste0("The shock scenario identifies ", clean_ticker(worst$Kode_Saham),
           " as the issuer with the highest potential loss across the portfolio, with an expected ",
           "return of ", fmt_pct_id(worst$ExpectedReturn_pct), " and a probability of loss of ",
           fmt_pct_id(worst$ProbLoss_pct), ".")
  )
  
  best <- rk[which.max(rk$ExpectedReturn_pct), ]
  alerts[[length(alerts) + 1]] <- new_alert(
    "Information", "Best performing issuer", clean_ticker(best$Kode_Saham), sector_of(best$Kode_Saham),
    "ExpectedReturn_pct", best$ExpectedReturn_pct, ALERT_CONFIG$expected_return_positive_pct,
    paste0(clean_ticker(best$Kode_Saham), " shows the most favorable expected outcome under this scenario, ",
           "with an expected return of ", fmt_pct_id(best$ExpectedReturn_pct), " and a probability of loss ",
           "of only ", fmt_pct_id(best$ProbLoss_pct), ".")
  )
  
  crit_var <- rk[rk$VaR5_pct <= ALERT_CONFIG$var95_critical_pct, ]
  if (nrow(crit_var) > 0) {
    crit_var <- crit_var[order(crit_var$VaR5_pct), ]
    for (i in seq_len(min(5, nrow(crit_var)))) {
      r <- crit_var[i, ]
      alerts[[length(alerts) + 1]] <- new_alert(
        "Critical", "Severe Value-at-Risk breach", clean_ticker(r$Kode_Saham), sector_of(r$Kode_Saham),
        "VaR5_pct", r$VaR5_pct, ALERT_CONFIG$var95_critical_pct,
        paste0(clean_ticker(r$Kode_Saham), " shows a VaR 95% (lower 5th percentile return) of ",
               fmt_pct_id(r$VaR5_pct), ", exceeding the critical threshold of ",
               fmt_pct_id(ALERT_CONFIG$var95_critical_pct), " under this scenario.")
      )
    }
  }
  
  warn_var <- rk[rk$VaR5_pct <= ALERT_CONFIG$var95_warning_pct & rk$VaR5_pct > ALERT_CONFIG$var95_critical_pct, ]
  if (nrow(warn_var) > 0) {
    warn_var <- warn_var[order(warn_var$VaR5_pct), ]
    for (i in seq_len(min(3, nrow(warn_var)))) {
      r <- warn_var[i, ]
      alerts[[length(alerts) + 1]] <- new_alert(
        "Warning", "Elevated Value-at-Risk", clean_ticker(r$Kode_Saham), sector_of(r$Kode_Saham),
        "VaR5_pct", r$VaR5_pct, ALERT_CONFIG$var95_warning_pct,
        paste0(clean_ticker(r$Kode_Saham), " shows an elevated VaR 95% of ", fmt_pct_id(r$VaR5_pct),
               " under this scenario, above the warning threshold of ", fmt_pct_id(ALERT_CONFIG$var95_warning_pct), ".")
      )
    }
  }
  
  high_pl <- rk[rk$ProbLoss_pct >= ALERT_CONFIG$probloss_critical_pct, ]
  if (nrow(high_pl) > 0) {
    high_pl <- high_pl[order(-high_pl$ProbLoss_pct), ]
    for (i in seq_len(min(5, nrow(high_pl)))) {
      r <- high_pl[i, ]
      alerts[[length(alerts) + 1]] <- new_alert(
        "Critical", "High probability of loss", clean_ticker(r$Kode_Saham), sector_of(r$Kode_Saham),
        "ProbLoss_pct", r$ProbLoss_pct, ALERT_CONFIG$probloss_critical_pct,
        paste0(clean_ticker(r$Kode_Saham), " has a ", fmt_pct_id(r$ProbLoss_pct),
               " probability of loss under this scenario, indicating a high likelihood of a negative outcome.")
      )
    }
  }
  
  warn_pl <- rk[rk$ProbLoss_pct >= ALERT_CONFIG$probloss_warning_pct & rk$ProbLoss_pct < ALERT_CONFIG$probloss_critical_pct, ]
  if (nrow(warn_pl) > 0) {
    warn_pl <- warn_pl[order(-warn_pl$ProbLoss_pct), ]
    for (i in seq_len(min(3, nrow(warn_pl)))) {
      r <- warn_pl[i, ]
      alerts[[length(alerts) + 1]] <- new_alert(
        "Warning", "Moderately elevated probability of loss", clean_ticker(r$Kode_Saham), sector_of(r$Kode_Saham),
        "ProbLoss_pct", r$ProbLoss_pct, ALERT_CONFIG$probloss_warning_pct,
        paste0(clean_ticker(r$Kode_Saham), " shows a ", fmt_pct_id(r$ProbLoss_pct), " probability of loss, ",
               "above the warning threshold of ", fmt_pct_id(ALERT_CONFIG$probloss_warning_pct), ".")
      )
    }
  }
  
  if (!is.null(issuer_registry) && nrow(issuer_registry) > 0) {
    rk_sector <- merge(rk, issuer_registry[, c("raw_ticker", "sector")],
                       by.x = "Kode_Saham", by.y = "raw_ticker", all.x = TRUE)
    if (nrow(rk_sector) > 0 && !all(is.na(rk_sector$sector))) {
      sector_avg <- stats::aggregate(ExpectedReturn_pct ~ sector, data = rk_sector, FUN = mean)
      
      bad_sectors <- sector_avg[sector_avg$ExpectedReturn_pct <= ALERT_CONFIG$sector_impact_warning_pct &
                                  sector_avg$sector != "Not Available", ]
      if (nrow(bad_sectors) > 0) {
        bad_sectors <- bad_sectors[order(bad_sectors$ExpectedReturn_pct), ]
        for (i in seq_len(min(4, nrow(bad_sectors)))) {
          s <- bad_sectors[i, ]
          alerts[[length(alerts) + 1]] <- new_alert(
            "Warning", "Sector-wide negative impact", NA, s$sector,
            "Sector_Avg_ExpectedReturn_pct", s$ExpectedReturn_pct, ALERT_CONFIG$sector_impact_warning_pct,
            paste0("Increased downside risk has been observed in the ", s$sector, " sector, with an ",
                   "average expected return of ", fmt_pct_id(s$ExpectedReturn_pct),
                   " across issuers in this scenario, warranting closer monitoring.")
          )
        }
      }
      
      good_sectors <- sector_avg[sector_avg$ExpectedReturn_pct >= ALERT_CONFIG$sector_impact_positive_pct &
                                   sector_avg$sector != "Not Available", ]
      if (nrow(good_sectors) > 0) {
        good_sectors <- good_sectors[order(-good_sectors$ExpectedReturn_pct), ]
        for (i in seq_len(min(2, nrow(good_sectors)))) {
          s <- good_sectors[i, ]
          alerts[[length(alerts) + 1]] <- new_alert(
            "Information", "Sector showing resilience", NA, s$sector,
            "Sector_Avg_ExpectedReturn_pct", s$ExpectedReturn_pct, ALERT_CONFIG$sector_impact_positive_pct,
            paste0("The ", s$sector, " sector shows a positive average expected return of ",
                   fmt_pct_id(s$ExpectedReturn_pct), " under this scenario, outperforming the broader portfolio.")
          )
        }
      }
    }
  }
  
  shocked_vars <- scenario_result$shock_vars
  for (v in shocked_vars) {
    sens <- list()
    for (sname in names(markov_models)) {
      if (!(sname %in% rk$Kode_Saham)) next
      ff <- markov_models[[sname]]$final_fit
      if (is.null(ff) || is.null(ff$beta_mat) || is.null(ff$coef_names)) next
      row_idx <- which(gsub("^`|`$", "", ff$coef_names) == v)
      if (length(row_idx) == 0) next
      beta_avg <- mean(ff$beta_mat[row_idx[1], ], na.rm = TRUE)
      sens[[sname]] <- beta_avg
    }
    if (length(sens) == 0) next
    sens_v <- unlist(sens)
    top_idx <- order(-abs(sens_v))[seq_len(min(ALERT_CONFIG$sensitivity_top_n, length(sens_v)))]
    for (i in top_idx) {
      sname <- names(sens_v)[i]
      alerts[[length(alerts) + 1]] <- new_alert(
        "Caution", paste0("High sensitivity to ", v), clean_ticker(sname), sector_of(sname),
        "Beta_Coefficient", sens_v[i], NA,
        paste0(clean_ticker(sname), " carries a directly-estimated regression coefficient of ",
               fmt_num_id(sens_v[i]), " on ", v, ", making it one of the issuers most directly ",
               "sensitive to this shocked factor in the current scenario.")
      )
    }
  }
  
  n_not_selected <- sum(vapply(names(markov_models), function(sname) {
    sv <- markov_models[[sname]]$selected_variables
    sname %in% rk$Kode_Saham && !is.null(sv) && length(intersect(shocked_vars, sv)) == 0
  }, logical(1)))
  if (n_not_selected > 0 && length(shocked_vars) > 0) {
    alerts[[length(alerts) + 1]] <- new_alert(
      "Information", "Indirect exposure via copula dependence", NA, NA,
      "N_Issuers_No_Direct_Exposure", n_not_selected, 0,
      paste0(n_not_selected, " issuer(s) do not use the shocked variable(s) (",
             paste(shocked_vars, collapse = ", "), ") directly as a predictor. Any impact on these issuers ",
             "is transmitted indirectly through the estimated DCC-GARCH/Student-t Copula dependence structure ",
             "on the other macro factors they do use.")
    )
  }
  
  neg_rk <- rk[rk$ExpectedReturn_pct < 0, ]
  if (nrow(neg_rk) >= 3) {
    total_neg <- sum(abs(neg_rk$ExpectedReturn_pct))
    top3_neg <- sum(abs(utils::head(neg_rk[order(neg_rk$ExpectedReturn_pct), ]$ExpectedReturn_pct, 3)))
    share <- if (total_neg > 0) top3_neg / total_neg * 100 else 0
    if (share >= ALERT_CONFIG$concentration_share_pct) {
      top3_names <- clean_ticker(utils::head(neg_rk[order(neg_rk$ExpectedReturn_pct), ]$Kode_Saham, 3))
      alerts[[length(alerts) + 1]] <- new_alert(
        "Caution", "Downside risk is concentrated", NA, NA,
        "Top3_Share_of_Negative_Return_pct", share, ALERT_CONFIG$concentration_share_pct,
        paste0("The three most negatively affected issuers (", paste(top3_names, collapse = ", "),
               ") account for ", fmt_pct_id(share), " of the portfolio's total negative expected return ",
               "under this scenario, indicating concentrated rather than broad-based downside risk.")
      )
    }
  }
  
  if (length(scenario_result$failed_stocks) > 0) {
    alerts[[length(alerts) + 1]] <- new_alert(
      "Warning", "Issuer(s) could not be simulated", NA, NA,
      "Failed_Stocks_Count", length(scenario_result$failed_stocks), 0,
      paste0(length(scenario_result$failed_stocks), " issuer(s) could not be simulated under this ",
             "scenario and were excluded from the ranking: ",
             paste(clean_ticker(scenario_result$failed_stocks), collapse = ", "), ".")
    )
  }
  
  if (length(scenario_result$degenerate_vars) > 0) {
    alerts[[length(alerts) + 1]] <- new_alert(
      "Caution", "Potential data integrity issue", NA, NA,
      "Degenerate_Macro_Vars", length(scenario_result$degenerate_vars), 0,
      paste0("The following unshocked macro variable(s) show near-zero variance across simulations, ",
             "which may indicate a missing marginal model: ",
             paste(scenario_result$degenerate_vars, collapse = ", "), ".")
    )
  }
  
  if (isTRUE(ALERT_CONFIG$data_update_note)) {
    date_range <- tryCatch({
      starts <- suppressWarnings(as.Date(issuer_registry$sample_start))
      ends   <- suppressWarnings(as.Date(issuer_registry$sample_end))
      list(min = min(starts, na.rm = TRUE), max = max(ends, na.rm = TRUE))
    }, error = function(e) NULL)
    range_txt <- if (!is.null(date_range) && all(is.finite(as.numeric(c(date_range$min, date_range$max))))) {
      paste0("covering the period from ", format(date_range$min, "%d %B %Y"), " through ",
             format(date_range$max, "%d %B %Y"))
    } else {
      "based on the latest available dataset"
    }
    alerts[[length(alerts) + 1]] <- new_alert(
      "Information", "Data coverage note", NA, NA, "Data_Coverage", NA, NA,
      paste0("Model estimates are based on daily closing price data, ", range_txt, ".")
    )
  }
  
  alerts[[length(alerts) + 1]] <- new_alert(
    "Information", "Simulation configuration", NA, NA, "N_Sim", scenario_result$n_sim, NA,
    paste0("This scenario was evaluated using ", format(scenario_result$n_sim, big.mark = ","),
           " conditional Monte Carlo draws", if (isTRUE(scenario_result$use_significant)) {
             paste0(", restricting each issuer's regression to coefficients significant at alpha = ",
                    scenario_result$alpha, " (Wald test)")
           } else ", using all constrained best-subset predictors regardless of significance", ".")
  )
  
  if (length(alerts) == 0) return(data.frame())
  out <- do.call(rbind, alerts)
  out$sev_rank <- severity_rank(out$severity)
  out <- out[order(out$sev_rank, out$value), ]
  out$sev_rank <- NULL
  rownames(out) <- NULL
  out
}

build_report_narrative <- function(scenario_result, alerts, issuer_registry) {
  rk <- scenario_result$ranking_table
  worst <- rk[which.min(rk$ExpectedReturn_pct), ]
  best  <- rk[which.max(rk$ExpectedReturn_pct), ]
  port_er <- mean(rk$ExpectedReturn_pct, na.rm = TRUE)
  port_var <- mean(rk$VaR5_pct, na.rm = TRUE)
  port_pl <- mean(rk$ProbLoss_pct, na.rm = TRUE)
  n_neg <- sum(rk$ExpectedReturn_pct < 0, na.rm = TRUE)
  
  shock_desc <- if (mc_is_level_mode(scenario_result)) {
    paste(mc_shock_level_descriptions(scenario_result), collapse = ", ")
  } else {
    paste(mapply(function(v, val) paste0(v, " ", ifelse(val >= 0, "+", ""), val, "%"),
                 scenario_result$shock_vars, scenario_result$shock_values), collapse = ", ")
  }
  
  overview <- paste0(
    "This report presents the results of a conditional Monte Carlo stress test applied to the current ",
    "portfolio of ", nrow(rk), " issuers. The scenario shocks the following market factor(s): ",
    shock_desc, ", simulated across ", format(scenario_result$n_sim, big.mark = ","), " conditional ",
    "draws from the estimated Student-t Copula joint distribution. Unshocked macro factors are drawn ",
    "conditionally on the shocked factor(s), preserving the dependence structure estimated via DCC-GARCH ",
    "and the Student-t Copula."
  )
  
  portfolio_para <- paste0(
    "At the portfolio level, the average expected one-period return across simulated issuers is ",
    fmt_pct_id(port_er), ", with an average VaR 95% (lower 5th percentile return) of ", fmt_pct_id(port_var),
    " and an average probability of loss of ", fmt_pct_id(port_pl), ". Under this scenario, ", n_neg,
    " out of ", nrow(rk), " issuers show a negative expected return, while ", clean_ticker(worst$Kode_Saham),
    " and ", clean_ticker(best$Kode_Saham), " mark the two extremes of the return distribution."
  )
  
  risk_para <- paste0(
    "Key risk indicators for this scenario include the portfolio-average VaR 95% of ", fmt_pct_id(port_var),
    " and probability of loss of ", fmt_pct_id(port_pl), ". ",
    if (length(scenario_result$failed_stocks) > 0) {
      paste0(length(scenario_result$failed_stocks), " issuer(s) could not be simulated under this scenario ",
             "and were excluded from portfolio-level statistics.")
    } else {
      "All issuers in the portfolio were successfully simulated under this scenario."
    }
  )
  
  limitations_para <- paste0(
    "This stress test is a scenario analysis conditional on the estimated Markov Switching Autoregressive, ",
    "DCC-GARCH, and Student-t Copula models, and does not constitute a forecast of actual future returns. ",
    "Results depend on model assumptions, the estimation sample, and the constrained best-subset predictor ",
    "selection performed independently for each issuer (minimum four variables, with JCI Index and a ",
    "sector-specific mandatory factor always included). Where a model's Hessian was not positive definite, ",
    "standard errors and Wald inference for that issuer may not be available, though point estimates remain valid."
  )
  
  conclusion_para <- paste0(
    "Overall, the portfolio shows an average expected return of ", fmt_pct_id(port_er), " under the shock ",
    "scenario described above, with ", clean_ticker(worst$Kode_Saham), " representing the primary source ",
    "of downside risk. Risk management attention should be directed toward issuers and sectors flagged in ",
    "the alerts section of this report."
  )
  
  list(overview = overview, portfolio = portfolio_para, risk = risk_para,
       limitations = limitations_para, conclusion = conclusion_para, shock_desc = shock_desc,
       worst = worst, best = best, port_er = port_er, port_var = port_var, port_pl = port_pl)
}

build_sector_narrative <- function(sector_name, sector_rows) {
  avg_er <- mean(sector_rows$ExpectedReturn_pct, na.rm = TRUE)
  avg_var <- mean(sector_rows$VaR5_pct, na.rm = TRUE)
  avg_pl <- mean(sector_rows$ProbLoss_pct, na.rm = TRUE)
  n_neg <- sum(sector_rows$ExpectedReturn_pct < 0, na.rm = TRUE)
  best_in_sector <- sector_rows[which.max(sector_rows$ExpectedReturn_pct), ]
  worst_in_sector <- sector_rows[which.min(sector_rows$ExpectedReturn_pct), ]
  tone <- if (avg_er < -1.5) "under significant pressure" else if (avg_er < 0) "showing mild downside pressure" else "holding up relatively well"
  paste0(
    "The ", sector_name, " sector (", nrow(sector_rows), " issuer(s) in this portfolio) is ", tone,
    " under this scenario, with an average expected return of ", fmt_pct_id(avg_er), " and an average ",
    "probability of loss of ", fmt_pct_id(avg_pl), ". Average VaR 95% across issuers in this sector is ",
    fmt_pct_id(avg_var), ". ", clean_ticker(worst_in_sector$Kode_Saham), " is the weakest performer in the ",
    "sector (", fmt_pct_id(worst_in_sector$ExpectedReturn_pct), "), while ", clean_ticker(best_in_sector$Kode_Saham),
    " is the strongest (", fmt_pct_id(best_in_sector$ExpectedReturn_pct), "). ", n_neg, " of ", nrow(sector_rows),
    " issuer(s) in this sector show a negative expected return under this scenario."
  )
}

build_issuer_narrative <- function(rk_row, reg_row, mdl) {
  sv <- safe_val(reg_row$selected_variables, "Not Available")
  mv <- safe_val(reg_row$mandatory_variables, "Not Available")
  k <- safe_val(mdl$best_k, "Not Available")
  tone <- if (rk_row$ExpectedReturn_pct < -1) "a notable expected loss" else if (rk_row$ExpectedReturn_pct < 0) "a mild expected loss" else "a positive expected return"
  paste0(
    clean_ticker(rk_row$Kode_Saham), " (", safe_val(reg_row$sector, "Not Available"), ") is modelled with a ",
    k, "-regime Markov Switching Autoregressive specification of AR order ", safe_val(rk_row$AR_Order, "Not Available"),
    ". Its constrained best-subset predictor set is: ", sv, " (mandatory factor(s): ", mv, "). Under the ",
    "current shock scenario, the model implies ", tone, ", with an expected return of ",
    fmt_pct_id(rk_row$ExpectedReturn_pct), ", a return standard deviation of ", fmt_pct_id(rk_row$StdDev_pct),
    ", a VaR 95% of ", fmt_pct_id(rk_row$VaR5_pct), ", and a probability of loss of ", fmt_pct_id(rk_row$ProbLoss_pct), "."
  )
}

pdf_wrap_text <- function(text, width = 100) {
  paste(strwrap(text, width = width), collapse = "\n")
}

pdf_page_header <- function(subtitle) {
  grid::grid.text("Monte Carlo Stress Testing Report", x = 0.045, y = 0.975, just = c("left", "top"),
                  gp = grid::gpar(fontsize = 15, fontface = "bold", col = "#1E8449"))
  grid::grid.text(subtitle, x = 0.955, y = 0.975, just = c("right", "top"),
                  gp = grid::gpar(fontsize = 9, col = "#1E8449", fontface = "bold"))
  grid::grid.lines(x = c(0.045, 0.955), y = c(0.955, 0.955), gp = grid::gpar(col = "#1E8449", lwd = 1.6))
}

pdf_page_footer <- function(page_label, generated_at) {
  grid::grid.text(paste0("Generated ", format(generated_at, "%d %B %Y %H:%M"), "  |  Scenario: Shock_",
                         format(generated_at, "%Y%m%d_%H%M%S"), "  |  Monte Carlo Stress Testing Dashboard"),
                  x = 0.045, y = 0.025, just = c("left", "bottom"), gp = grid::gpar(fontsize = 6.5, col = "#666666"))
  grid::grid.text(page_label, x = 0.955, y = 0.025, just = c("right", "bottom"),
                  gp = grid::gpar(fontsize = 7, col = "#666666"))
}

pdf_section_heading <- function(text, x, y) {
  grid::grid.text(text, x = x, y = y, just = c("left", "top"),
                  gp = grid::gpar(fontsize = 10.5, fontface = "bold", col = "#1E8449"))
}

pdf_body_text <- function(text, x, y, width_chars = 118, fontsize = 7.8, color = "#111111") {
  grid::grid.text(pdf_wrap_text(text, width_chars), x = x, y = y, just = c("left", "top"),
                  gp = grid::gpar(fontsize = fontsize, col = color, lineheight = 1.25))
}

pdf_make_table_grob <- function(df, digits_pct_cols = character(0), fontsize = 7) {
  df_display <- df
  for (cn in digits_pct_cols) {
    if (cn %in% names(df_display)) df_display[[cn]] <- fmt_pct_id(df_display[[cn]])
  }
  theme <- gridExtra::ttheme_default(
    core = list(fg_params = list(fontsize = fontsize, col = "#111111"),
                bg_params = list(fill = c("#FFFFFF", "#EFF7F2")),
                padding = grid::unit(c(3, 2.2), "mm")),
    colhead = list(fg_params = list(fontsize = fontsize, fontface = "bold", col = "white"),
                   bg_params = list(fill = "#1E8449"), padding = grid::unit(c(3, 2.2), "mm"))
  )
  gridExtra::tableGrob(df_display, rows = NULL, theme = theme)
}

pdf_find_issuer_image <- function(root_dir, tag) {
  dir_path <- file.path(root_dir, "Plots", tag)
  if (!dir.exists(dir_path)) return(NULL)
  preferred <- file.path(dir_path, "Overlay_Return_Regime_Probability.png")
  if (file.exists(preferred)) return(preferred)
  pngs <- list.files(dir_path, pattern = "\\.png$", full.names = TRUE)
  if (length(pngs) > 0) return(pngs[1])
  NULL
}

pdf_draw_issuer_block <- function(x0, width, rk_row, reg_row, mdl, root_dir, scenario_result) {
  y <- 1.0
  grid::pushViewport(grid::viewport(x = x0, y = 0.5, width = width, height = 1.0, just = "left"))
  
  er_color <- if (rk_row$ExpectedReturn_pct < 0) "#C0392B" else "#1E8449"
  grid::grid.text(clean_ticker(rk_row$Kode_Saham), x = 0, y = 0.985, just = c("left", "top"),
                  gp = grid::gpar(fontsize = 11, fontface = "bold", col = "#111111"))
  grid::grid.text(fmt_pct_id(rk_row$ExpectedReturn_pct), x = 1, y = 0.985, just = c("right", "top"),
                  gp = grid::gpar(fontsize = 11, fontface = "bold", col = er_color))
  grid::grid.text(safe_val(reg_row$sector, "Not Available"), x = 0, y = 0.945, just = c("left", "top"),
                  gp = grid::gpar(fontsize = 7.5, col = "#555555", fontface = "italic"))
  grid::grid.lines(x = c(0, 1), y = c(0.92, 0.92), gp = grid::gpar(col = "#CCCCCC", lwd = 0.8))
  
  narrative <- build_issuer_narrative(rk_row, reg_row, mdl)
  grid::grid.text(pdf_wrap_text(narrative, 62), x = 0, y = 0.895, just = c("left", "top"),
                  gp = grid::gpar(fontsize = 7, col = "#222222", lineheight = 1.25))
  
  stat_tbl <- data.frame(
    Metric = c("Expected Return", "Std. Deviation", "VaR 95%", "Probability of Loss"),
    Value = c(fmt_pct_id(rk_row$ExpectedReturn_pct), fmt_pct_id(rk_row$StdDev_pct),
              fmt_pct_id(rk_row$VaR5_pct), fmt_pct_id(rk_row$ProbLoss_pct))
  )
  grid::pushViewport(grid::viewport(x = 0, y = 0.60, width = 1, height = 0.16, just = c("left", "top")))
  grid::grid.draw(pdf_make_table_grob(stat_tbl, fontsize = 6.6))
  grid::popViewport()
  
  img_path <- pdf_find_issuer_image(root_dir, ticker_to_tag(rk_row$Kode_Saham))
  chart_grob <- NULL
  if (!is.null(img_path) && requireNamespace("png", quietly = TRUE)) {
    chart_grob <- tryCatch({
      img <- png::readPNG(img_path)
      grid::rasterGrob(img, interpolate = TRUE)
    }, error = function(e) NULL)
  }
  if (is.null(chart_grob) && rk_row$Kode_Saham %in% colnames(scenario_result$result_matrix)) {
    chart_grob <- tryCatch({
      p <- mc_plot_stock_distribution(scenario_result, rk_row$Kode_Saham, root_dir, save_to_disk = FALSE)$plot +
        ggplot2::theme(legend.position = "none", plot.title = ggplot2::element_blank(),
                       plot.subtitle = ggplot2::element_blank(), axis.title = ggplot2::element_text(size = 6),
                       axis.text = ggplot2::element_text(size = 5))
      ggplot2::ggplotGrob(p)
    }, error = function(e) NULL)
  }
  if (!is.null(chart_grob)) {
    grid::pushViewport(grid::viewport(x = 0, y = 0.40, width = 1, height = 0.38, just = c("left", "top")))
    grid::grid.draw(chart_grob)
    grid::popViewport()
  }
  
  grid::popViewport()
}

render_stress_report <- function(scenario_result, alerts, issuer_registry, root_dir, output_path) {
  ok <- tryCatch({
    if (!requireNamespace("gridExtra", quietly = TRUE)) stop("Package 'gridExtra' is required for PDF report generation.")
    grDevices::pdf(output_path, width = 8.27, height = 11.69, onefile = TRUE)
    on.exit(grDevices::dev.off(), add = TRUE)
    
    narrative <- build_report_narrative(scenario_result, alerts, issuer_registry)
    rk <- scenario_result$ranking_table
    rk_display <- rk
    rk_display$Kode_Saham <- clean_ticker(rk_display$Kode_Saham)
    generated_at <- Sys.time()
    
    rk_sector <- NULL
    sector_impact <- NULL
    if (!is.null(issuer_registry) && nrow(issuer_registry) > 0) {
      rk_sector <- merge(rk, issuer_registry[, c("raw_ticker", "sector")],
                         by.x = "Kode_Saham", by.y = "raw_ticker", all.x = TRUE)
      if (nrow(rk_sector) > 0 && !all(is.na(rk_sector$sector))) {
        agg <- stats::aggregate(ExpectedReturn_pct ~ sector, data = rk_sector, FUN = mean)
        agg <- agg[order(agg$ExpectedReturn_pct), ]
        names(agg) <- c("Sector", "Avg. Expected Return")
        sector_impact <- agg
      }
    }
    
    shock_df <- data.frame(Variable = scenario_result$shock_vars, `Shock (%)` = mc_shock_display_values(scenario_result),
                           check.names = FALSE)
    if (mc_is_level_mode(scenario_result)) {
      shock_df[["Target Level"]] <- fmt_num_id(mc_shock_input_values(scenario_result), 2)
      shock_df[["Current Level"]] <- fmt_num_id(mc_shock_current_levels(scenario_result), 2)
    }
    scenario_meta <- data.frame(
      Setting = c("Simulations", "Significant Only", "Alpha", "Issuers Simulated", "Issuers Excluded"),
      Value = c(format(scenario_result$n_sim, big.mark = ","),
                ifelse(isTRUE(scenario_result$use_significant), "Yes", "No"),
                scenario_result$alpha, nrow(rk), length(scenario_result$failed_stocks))
    )
    portfolio_summary <- data.frame(
      Metric = c("Avg. Expected Return", "Avg. VaR 95%", "Avg. Probability of Loss"),
      Value = c(fmt_pct_id(mean(rk$ExpectedReturn_pct, na.rm = TRUE), 3),
                fmt_pct_id(mean(rk$VaR5_pct, na.rm = TRUE), 3),
                fmt_pct_id(mean(rk$ProbLoss_pct, na.rm = TRUE), 2))
    )
    
    grid::grid.newpage()
    pdf_page_header("Scenario Overview & Portfolio Impact")
    pdf_section_heading("Scenario Overview", 0.045, 0.925)
    pdf_body_text(narrative$overview, 0.045, 0.905, width_chars = 122)
    
    grid::pushViewport(grid::viewport(x = 0.045, y = 0.735, width = 0.44, height = 0.16, just = c("left", "top")))
    grid::grid.draw(pdf_make_table_grob(shock_df))
    grid::popViewport()
    grid::pushViewport(grid::viewport(x = 0.515, y = 0.735, width = 0.44, height = 0.16, just = c("left", "top")))
    grid::grid.draw(pdf_make_table_grob(scenario_meta))
    grid::popViewport()
    
    pdf_section_heading("Portfolio Impact", 0.045, 0.565)
    pdf_body_text(narrative$portfolio, 0.045, 0.545, width_chars = 122)
    grid::pushViewport(grid::viewport(x = 0.045, y = 0.44, width = 0.44, height = 0.11, just = c("left", "top")))
    grid::grid.draw(pdf_make_table_grob(portfolio_summary))
    grid::popViewport()
    if (!is.null(sector_impact)) {
      grid::pushViewport(grid::viewport(x = 0.515, y = 0.44, width = 0.44, height = 0.32, just = c("left", "top")))
      grid::grid.draw(pdf_make_table_grob(sector_impact, digits_pct_cols = "Avg. Expected Return"))
      grid::popViewport()
    }
    
    top5 <- utils::head(rk_display[order(-rk_display$ExpectedReturn_pct), c("Rank","Kode_Saham","ExpectedReturn_pct","VaR5_pct","ProbLoss_pct")], 5)
    bot5 <- utils::head(rk_display[order(rk_display$ExpectedReturn_pct), c("Rank","Kode_Saham","ExpectedReturn_pct","VaR5_pct","ProbLoss_pct")], 5)
    names(top5) <- names(bot5) <- c("Rank", "Issuer", "Exp. Return", "VaR 95%", "Prob. Loss")
    
    pdf_section_heading("Top 5 Best Performing Issuers", 0.045, 0.235)
    grid::pushViewport(grid::viewport(x = 0.045, y = 0.215, width = 0.44, height = 0.16, just = c("left", "top")))
    grid::grid.draw(pdf_make_table_grob(top5, digits_pct_cols = c("Exp. Return", "VaR 95%", "Prob. Loss")))
    grid::popViewport()
    pdf_section_heading("Top 5 Worst Performing Issuers", 0.515, 0.235)
    grid::pushViewport(grid::viewport(x = 0.515, y = 0.215, width = 0.44, height = 0.16, just = c("left", "top")))
    grid::grid.draw(pdf_make_table_grob(bot5, digits_pct_cols = c("Exp. Return", "VaR 95%", "Prob. Loss")))
    grid::popViewport()
    pdf_page_footer("Page 1", generated_at)
    
    if (!is.null(rk_sector) && !all(is.na(rk_sector$sector))) {
      sectors_present <- unique(rk_sector$sector[!is.na(rk_sector$sector) & rk_sector$sector != "Not Available"])
      sectors_present <- sectors_present[order(stats::ave(rk_sector$ExpectedReturn_pct, rk_sector$sector, FUN = mean)[match(sectors_present, rk_sector$sector)])]
      
      chunk_size <- 4
      n_pages <- ceiling(length(sectors_present) / chunk_size)
      for (pg in seq_len(max(1, n_pages))) {
        grid::grid.newpage()
        pdf_page_header("Sector Deep-Dive")
        idx_start <- (pg - 1) * chunk_size + 1
        idx_end <- min(pg * chunk_size, length(sectors_present))
        y_cursor <- 0.93
        for (si in idx_start:idx_end) {
          s <- sectors_present[si]
          sector_rows <- rk[rk$Kode_Saham %in% rk_sector$Kode_Saham[rk_sector$sector == s], ]
          if (nrow(sector_rows) == 0) next
          pdf_section_heading(s, 0.045, y_cursor)
          para <- build_sector_narrative(s, sector_rows)
          pdf_body_text(para, 0.045, y_cursor - 0.02, width_chars = 122, fontsize = 7.6)
          y_cursor <- y_cursor - 0.225
        }
        pdf_page_footer(paste0("Page ", 1 + pg), generated_at)
      }
    }
    
    spotlight <- rbind(utils::head(rk[order(-rk$ExpectedReturn_pct), ], 5),
                       utils::head(rk[order(rk$ExpectedReturn_pct), ], 5))
    spotlight <- spotlight[!duplicated(spotlight$Kode_Saham), ]
    n_spot_pages <- ceiling(nrow(spotlight) / 2)
    for (pg in seq_len(n_spot_pages)) {
      grid::grid.newpage()
      pdf_page_header("Issuer Spotlight")
      idx1 <- (pg - 1) * 2 + 1
      idx2 <- min(idx1 + 1, nrow(spotlight))
      row1 <- spotlight[idx1, ]
      reg1 <- issuer_registry[issuer_registry$raw_ticker == row1$Kode_Saham, ][1, ]
      mdl1 <- lookup_best_k(issuer_registry, row1$Kode_Saham)
      pdf_draw_issuer_block(0.045, 0.44, row1, reg1, mdl1, root_dir, scenario_result)
      if (idx2 != idx1) {
        row2 <- spotlight[idx2, ]
        reg2 <- issuer_registry[issuer_registry$raw_ticker == row2$Kode_Saham, ][1, ]
        mdl2 <- lookup_best_k(issuer_registry, row2$Kode_Saham)
        pdf_draw_issuer_block(0.515, 0.44, row2, reg2, mdl2, root_dir, scenario_result)
      }
      pdf_page_footer(paste0("Page ", 1 + max(1, n_pages_var(rk_sector)) + pg), generated_at)
    }
    
    grid::grid.newpage()
    pdf_page_header("Alerts, Diagnostics & Conclusion")
    pdf_section_heading("Key Risk Indicators", 0.045, 0.925)
    pdf_body_text(narrative$risk, 0.045, 0.905, width_chars = 122)
    pdf_section_heading("Model Diagnostics & Limitations", 0.045, 0.82)
    pdf_body_text(narrative$limitations, 0.045, 0.80, width_chars = 122)
    
    pdf_section_heading("Alerts Summary", 0.045, 0.66)
    if (!is.null(alerts) && nrow(alerts) > 0) {
      al_display <- alerts[, c("severity", "title", "issuer", "description")]
      al_display$description <- vapply(al_display$description, function(x) pdf_wrap_text(x, 78), character(1))
      names(al_display) <- c("Severity", "Alert", "Issuer", "Description")
      grid::pushViewport(grid::viewport(x = 0.045, y = 0.64, width = 0.91, height = 0.44, just = c("left", "top")))
      grid::grid.draw(pdf_make_table_grob(al_display, fontsize = 6.4))
      grid::popViewport()
      y_conclusion <- 0.16
    } else {
      pdf_body_text("No alerts were triggered under this scenario.", 0.045, 0.64, width_chars = 122)
      y_conclusion <- 0.50
    }
    
    pdf_section_heading("Conclusion", 0.045, y_conclusion)
    pdf_body_text(narrative$conclusion, 0.045, y_conclusion - 0.02, width_chars = 122)
    pdf_body_text(
      paste0("This report was generated automatically from a previously estimated Markov Switching ",
             "Autoregressive / DCC-GARCH / Student-t Copula model. No model re-estimation was performed; ",
             "results reflect a conditional simulation given the shock scenario above and should be ",
             "interpreted as scenario analysis, not as a forecast."),
      0.045, y_conclusion - 0.09, width_chars = 122, fontsize = 7)
    pdf_page_footer("Final Page", generated_at)
    
    TRUE
  }, error = function(e) {
    conditionMessage(e)
  })
  
  if (isTRUE(ok)) list(ok = TRUE, path = output_path) else list(ok = FALSE, error = ok)
}

lookup_best_k <- function(issuer_registry, raw_ticker) {
  list(best_k = issuer_registry$best_k[issuer_registry$raw_ticker == raw_ticker][1])
}

n_pages_var <- function(rk_sector) {
  if (is.null(rk_sector) || all(is.na(rk_sector$sector))) return(0)
  s <- unique(rk_sector$sector[!is.na(rk_sector$sector) & rk_sector$sector != "Not Available"])
  ceiling(length(s) / 4)
}


show_loading_overlay <- function(session, stage_text) {
  session$sendCustomMessage("mc-show-loading", list(stage = stage_text))
}

update_loading_stage <- function(session, stage_text) {
  session$sendCustomMessage("mc-update-stage", list(stage = stage_text))
}

hide_loading_overlay <- function(session) {
  session$sendCustomMessage("mc-hide-loading", list())
}

run_scenario_with_overlay <- function(session, rv, shock_vars, shock_values, n_sim, use_significant, alpha,
                                      shock_input_mode = "pct", shock_input_values = NULL,
                                      shock_current_levels = NULL) {
  show_loading_overlay(session, "Loading model objects")
  
  result <- tryCatch({
    estimation_objects <- list(joint_dist = rv$joint_dist, markov_models = rv$markov_models)
    
    update_loading_stage(session, "Preparing shock scenario")
    
    sr <- mc_run_scenario(
      shock_vars = shock_vars, shock_values = shock_values, n_sim = n_sim,
      use_significant = use_significant, alpha = alpha,
      estimation_objects = estimation_objects, output_dir = rv$root_dir, seed = 123,
      progress_callback = function(stage) update_loading_stage(session, stage),
      shock_input_mode = shock_input_mode, shock_input_values = shock_input_values,
      shock_current_levels = shock_current_levels
    )
    
    update_loading_stage(session, "Preparing dashboard results")
    alerts <- generate_alerts(sr, rv$markov_models, rv$issuer_registry)
    
    list(ok = TRUE, scenario_result = sr, alerts = alerts)
  }, error = function(e) {
    list(ok = FALSE, error = conditionMessage(e))
  })
  
  hide_loading_overlay(session)
  
  if (isTRUE(result$ok)) {
    rv$scenario_result <- result$scenario_result
    rv$scenario_export_paths <- NULL
    rv$alerts <- result$alerts
    n_failed <- length(result$scenario_result$failed_stocks)
    msg <- if (n_failed > 0) {
      paste0("Scenario completed. ", n_failed, " issuer(s) could not be simulated and were excluded from the ranking.")
    } else {
      "Scenario completed successfully."
    }
    showNotification(msg, type = if (n_failed > 0) "warning" else "message", duration = 6)
  } else {
    showNotification(paste("Scenario failed:", result$error), type = "error", duration = 12)
  }
  
  invisible(result)
}

reset_scenario <- function(rv) {
  rv$scenario_result <- NULL
  rv$scenario_export_paths <- NULL
  rv$alerts <- NULL
}


APP_TABS <- c("home" = "Home", "issuer" = "Issuer Details", "portfolio" = "Portfolio Impact", "about" = "About")

BPJS_LOGO_B64 <- paste0(
  "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"
)

get_latest_data_date <- function(root_dir) {
  raw_path <- find_raw_data_path(root_dir)
  if (is.null(raw_path)) return(NA)
  sheets <- tryCatch(openxlsx::getSheetNames(raw_path), error = function(e) NULL)
  if (is.null(sheets)) return(NA)
  df <- tryCatch(openxlsx::read.xlsx(raw_path, sheet = sheets[1], detectDates = TRUE), error = function(e) NULL)
  if (is.null(df)) return(NA)
  date_col <- column_exists(df, c("Dates", "Date", "Tanggal"))
  if (is.na(date_col)) return(NA)
  dts <- suppressWarnings(as.Date(df[[date_col]]))
  dts <- dts[!is.na(dts)]
  if (length(dts) == 0) return(NA)
  max(dts)
}

render_app_header <- function(session, current_tab, latest_date = NA) {
  nav_links <- lapply(names(APP_TABS), function(key) {
    tags$a(
      class = if (identical(key, current_tab)) "active" else NULL,
      onclick = sprintf("Shiny.setInputValue('%s', '%s', {priority: 'event'})", "app_nav_click", key),
      APP_TABS[[key]]
    )
  })
  
  date_label <- if (is.na(latest_date)) "Not Available" else format(latest_date, "%d %B %Y")
  
  div(class = "mc-header",
      div(class = "mc-header-left",
          tags$img(class = "mc-logo-img", src = paste0("data:image/png;base64,", BPJS_LOGO_B64),
                   alt = "BPJS Ketenagakerjaan")
      ),
      div(class = "mc-header-title",
          tags$h1(HTML("Dashboard Stress Testing Portfolio: <span class='light'>Markov Regression Autoregressive-DCC-GARCH-Student-t Copula</span>")),
          tags$hr(),
          div(class = "mc-navtabs", nav_links)
      ),
      div(class = "mc-header-right",
          tags$span(class = "lbl", "Last Updated:"),
          tags$span(class = "val", date_label)
      )
  )
}


ALERT_ICON_CRITICAL_B64 <- paste0(
  "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"
)
ALERT_ICON_INFO_B64 <- paste0(
  "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"
)
ALERT_ICON_CAUTION_B64 <- paste0(
  "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"
)

LEFT_COLUMN_VARS  <- c("JCI Index", "USDIDR BGN Curncy", "IBPRCPI Index", "LMNIDS03 LME Comdty", "GTIDR1Y Govt")
RIGHT_COLUMN_VARS <- c("CLA Comdty", "XAU Curncy", "XW1 Comdty", "KO1 Comdty")

mod_home_ui <- function(id) {
  ns <- NS(id)
  
  tagList(
    div(class = "mc-body",
        div(class = "mc-sidebar",
            
            div(class = "mc-card",
                tags$label(class = "mc-label", "Include only variables that are statistically significant:"),
                tags$p(class = "mc-help", "According to the Wald test (alpha: 10%)."),
                div(class = "mc-radio-row",
                    radioButtons(ns("use_significant"), NULL, choices = c("Yes" = "yes", "No" = "no"),
                                 selected = "no", inline = TRUE)
                )
            ),
            
            div(class = "mc-card mc-numeric",
                tags$label(class = "mc-label", "Number of Monte Carlo Scenarios:"),
                numericInput(ns("n_sim"), NULL, value = 10000, min = 100, max = 200000, step = 1000)
            ),
            
            div(class = "mc-card",
                tags$label(class = "mc-label", "Select Variables for Stress Testing:"),
                uiOutput(ns("var_checkboxes"))
            ),
            
            div(class = "mc-card",
                tags$label(class = "mc-label", "Shock Input Mode:"),
                tags$p(class = "mc-help", "Enter shocks as a percentage change, or as a target price / level."),
                div(class = "mc-radio-row",
                    radioButtons(ns("shock_input_mode"), NULL, choices = SHOCK_MODE_CHOICES,
                                 selected = "pct", inline = FALSE)
                )
            ),
            
            uiOutput(ns("shock_inputs")),
            
            actionButton(ns("btn_run"), label = tagList(tags$span(class = "mc-btn-icon", "\u25B6"), "Simulate Scenario"),
                         class = "mc-sidebar-btn mc-btn-simulate", width = "100%"),
            downloadButton(ns("btn_download_report"),
                           label = tagList(tags$span(class = "mc-btn-icon", "\u25B6"), "Download Report"),
                           class = "mc-sidebar-btn mc-btn-report", icon = NULL)
        ),
        
        div(class = "mc-content",
            
            div(class = "mc-grid-2-top",
                div(class = "mc-col",
                    div(class = "mc-card",
                        tags$h3(class = "mc-card-title", "Return Shock Composition (Gain/Loss) relative to Last Price"),
                        plotlyOutput(ns("plot_gain_loss"), height = "270px")
                    ),
                    div(class = "mc-card",
                        tags$h3(class = "mc-card-title", "Average Exposure per Sector"),
                        uiOutput(ns("sector_exposure_container"))
                    )
                ),
                div(class = "mc-col",
                    div(class = "mc-card",
                        tags$h3(class = "mc-card-title", "Top 10 Highest Return (Gainer)"),
                        uiOutput(ns("table_top10"))
                    ),
                    div(class = "mc-card",
                        tags$h3(class = "mc-card-title", "Top 10 Lowest Return (Losers)"),
                        uiOutput(ns("table_bottom10"))
                    )
                )
            ),
            
            div(class = "mc-card",
                tags$h3(class = "mc-card-title", "Alert & Notification"),
                uiOutput(ns("alert_preview")),
                div(class = "mc-alert-seeall",
                    actionLink(ns("btn_see_all_alerts"), HTML("See all alerts &amp; notifications &#9642;"))
                )
            )
        )
    )
  )
}

mod_home_server <- function(id, rv) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    var_cfg <- reactive({
      req(rv$macro_vars)
      get_var_display_config(rv$macro_vars)
    })
    
    output$var_checkboxes <- renderUI({
      cfg <- var_cfg()
      req(length(cfg) > 0)
      cfg_by_actual <- stats::setNames(cfg, vapply(cfg, function(v) v$actual_resolved, character(1)))
      
      build_col <- function(var_names) {
        items <- Filter(Negate(is.null), lapply(var_names, function(nm) cfg_by_actual[[nm]]))
        if (length(items) == 0) return(NULL)
        div(class = "mc-varcheck-col",
            lapply(items, function(v) {
              input_id <- ns(var_input_id(v$actual_resolved))
              div(class = "mc-varcheck-item",
                  tags$input(type = "checkbox", id = input_id, class = "mc-varcheck-box"),
                  tags$label(`for` = input_id, class = "mc-varcheck-label", v$checkbox_label)
              )
            })
        )
      }
      
      div(class = "mc-varcheck-grid",
          build_col(LEFT_COLUMN_VARS),
          build_col(RIGHT_COLUMN_VARS)
      )
    })
    
    checked_vars <- reactive({
      cfg <- var_cfg()
      req(length(cfg) > 0)
      sel <- vapply(cfg, function(v) {
        val <- input[[var_input_id(v$actual_resolved)]]
        isTRUE(val)
      }, logical(1))
      if (!any(sel)) character(0) else vapply(cfg[sel], function(v) v$actual_resolved, character(1))
    })
    
    shock_mode <- reactive({
      m <- input$shock_input_mode
      if (is.null(m) || !(m %in% c("pct", "level"))) "pct" else m
    })
    
    raw_levels <- reactive({
      req(rv$root_dir)
      cfg <- var_cfg()
      req(length(cfg) > 0)
      mc_latest_raw_levels(rv$root_dir, vapply(cfg, function(v) v$actual_resolved, character(1)))
    })
    
    last_shock_mode <- new.env(parent = emptyenv())
    last_shock_mode$m <- "pct"
    
    output$shock_inputs <- renderUI({
      cfg <- var_cfg()
      req(length(cfg) > 0)
      active <- checked_vars()
      mode <- shock_mode()
      mode_changed <- !identical(last_shock_mode$m, mode)
      last_shock_mode$m <- mode
      lv <- if (identical(mode, "level")) tryCatch(raw_levels(), error = function(e) NULL) else NULL
      boxes <- lapply(cfg, function(v) {
        is_active <- v$actual_resolved %in% active
        input_id <- ns(shock_input_id(v$actual_resolved))
        prev_val <- if (mode_changed) NULL else input[[shock_input_id(v$actual_resolved)]]
        current_txt <- NULL
        if (identical(mode, "level")) {
          info <- if (is.null(lv)) NULL else lv[[v$actual_resolved]]
          current_txt <- if (!is.null(info) && is.finite(info$level)) {
            paste0("Current: ", fmt_num_id(info$level, if (abs(info$level) >= 100) 2 else 4),
                   if (!is.na(info$date)) paste0(" (", format(info$date, "%d %b %Y"), ")") else "")
          } else {
            "Current: N/A (not available in raw_data)"
          }
        }
        div(class = "mc-shock-input mc-card",
            tags$label(class = if (!is_active) "disabled-label" else NULL, shock_label_for_mode(v, mode)),
            if (!is.null(current_txt)) tags$p(class = "mc-help", current_txt),
            tags$input(
              type = "number", step = if (identical(mode, "level")) "any" else "0.5",
              id = input_id, class = "form-control",
              placeholder = if (identical(mode, "level")) "input (level)" else "input (%)",
              value = if (!is.null(prev_val) && !is.na(prev_val)) prev_val else "",
              disabled = if (!is_active) "disabled" else NULL
            )
        )
      })
      tagList(boxes)
    })
    
    output$plot_gain_loss <- renderPlotly({
      sr <- rv$scenario_result
      if (is.null(sr)) return(empty_state_plotly("Run a scenario to view gain/loss composition"))
      rk <- sr$ranking_table
      n_gain <- sum(rk$ExpectedReturn_pct >= 0, na.rm = TRUE)
      n_loss <- sum(rk$ExpectedReturn_pct < 0, na.rm = TRUE)
      df <- data.frame(Category = c("Gain", "Loss"), Count = c(n_gain, n_loss))
      draw_donut_chart(df, cat_col = "Category", val_col = "Count",
                       colors = c("Gain" = "#1E8449", "Loss" = "#C0392B"))
    })
    
    sector_exposure_agg <- reactive({
      sr <- rv$scenario_result
      if (is.null(sr)) return(NULL)
      rk <- sr$ranking_table
      reg <- rv$issuer_registry
      req(reg)
      merged <- merge(rk, reg[, c("raw_ticker", "sector")], by.x = "Kode_Saham", by.y = "raw_ticker", all.x = TRUE)
      merged$sector[is.na(merged$sector)] <- "Not Available"
      agg <- stats::aggregate(ExpectedReturn_pct ~ sector, data = merged, FUN = mean)
      agg[order(agg$ExpectedReturn_pct), ]
    })
    
    output$sector_exposure_container <- renderUI({
      agg <- sector_exposure_agg()
      n_sector <- if (is.null(agg)) 1 else max(1, nrow(agg))
      chart_h <- min(720, max(260, 34 * n_sector + 90))
      plotlyOutput(ns("plot_sector_exposure"), height = paste0(chart_h, "px"))
    })
    
    output$plot_sector_exposure <- renderPlotly({
      agg <- sector_exposure_agg()
      if (is.null(agg)) return(empty_state_plotly("Run a scenario to view sector exposure"))
      draw_sector_bar_chart(agg)
    })
    
    output$table_top10 <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) return(div(class = "mc-not-available", "Not Available - run a scenario first."))
      rk <- sr$ranking_table
      top10 <- utils::head(rk[order(-rk$ExpectedReturn_pct), ], 10)
      render_ranking_html_table(top10)
    })
    
    output$table_bottom10 <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) return(div(class = "mc-not-available", "Not Available - run a scenario first."))
      rk <- sr$ranking_table
      bot10 <- utils::head(rk[order(rk$ExpectedReturn_pct), ], 10)
      render_ranking_html_table(bot10)
    })
    
    output$alert_preview <- renderUI({
      al <- rv$alerts
      if (is.null(al) || nrow(al) == 0) {
        return(div(class = "mc-not-available", "No alerts - run a scenario to generate risk notifications."))
      }
      top3 <- utils::head(al, 3)
      rows <- lapply(seq_len(nrow(top3)), function(i) render_alert_row(top3[i, ]))
      tagList(rows)
    })
    
    observeEvent(input$btn_see_all_alerts, {
      show_all_alerts_modal(rv$alerts)
    })
    
    observeEvent(input$btn_run, {
      req(rv$loaded)
      active <- checked_vars()
      if (length(active) == 0) {
        showNotification("Select at least one variable to shock before running the scenario.", type = "warning")
        return(invisible(NULL))
      }
      shock_values <- vapply(active, function(v) {
        val <- input[[shock_input_id(v)]]
        if (is.null(val) || is.na(val)) NA_real_ else as.numeric(val)
      }, numeric(1))
      if (anyNA(shock_values)) {
        showNotification(
          if (identical(shock_mode(), "level")) "Please provide a target level for every selected variable."
          else "Please provide a shock value (%) for every selected variable.",
          type = "warning")
        return(invisible(NULL))
      }
      
      n_sim <- input$n_sim
      if (is.null(n_sim) || is.na(n_sim) || n_sim < 100 || n_sim > 200000) {
        showNotification("Number of Monte Carlo scenarios must be a valid number between 100 and 200,000.", type = "warning")
        return(invisible(NULL))
      }
      
      use_sig <- identical(input$use_significant, "yes")
      alpha <- 0.10
      
      shock_input_mode <- "pct"
      shock_input_values <- NULL
      shock_current_levels <- NULL
      if (identical(shock_mode(), "level")) {
        conv <- tryCatch(
          mc_convert_levels_to_pct(active, shock_values, raw_levels()),
          error = function(e) e
        )
        if (inherits(conv, "error")) {
          showNotification(paste("Scenario cancelled:", conditionMessage(conv)), type = "error", duration = 12)
          return(invisible(NULL))
        }
        shock_input_mode <- "level"
        shock_input_values <- shock_values
        shock_current_levels <- conv$current
        shock_values <- conv$pct
      }
      
      run_scenario_with_overlay(session, rv, shock_vars = active, shock_values = shock_values,
                                n_sim = as.integer(n_sim), use_significant = use_sig, alpha = alpha,
                                shock_input_mode = shock_input_mode, shock_input_values = shock_input_values,
                                shock_current_levels = shock_current_levels)
    })
    
    output$btn_download_report <- downloadHandler(
      filename = function() paste0("StressTest_Report_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".pdf"),
      content = function(file) {
        req(rv$scenario_result)
        withProgress(message = "Generating PDF report...", value = 0.3, {
          res <- render_stress_report(rv$scenario_result, rv$alerts, rv$issuer_registry, rv$root_dir, file)
          incProgress(0.7)
          if (!isTRUE(res$ok)) {
            showNotification(paste("Report generation failed:", res$error), type = "error", duration = 10)
          }
        })
      }
    )
  })
}

summary_card <- function(label, value, cls = "") {
  div(class = "mc-summary-card",
      div(class = "mc-sc-label", label),
      div(class = paste("mc-sc-value", cls), value)
  )
}

render_ranking_html_table <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(div(class = "mc-not-available", "Not Available"))
  header <- tags$thead(tags$tr(
    tags$th("Ticker"), tags$th("Expected Return"), tags$th("Standard Deviation"), tags$th("Probability of Loss")
  ))
  rows <- lapply(seq_len(nrow(df)), function(i) {
    r <- df[i, ]
    tags$tr(
      tags$td(clean_ticker(r$Kode_Saham)),
      tags$td(class = pct_class(r$ExpectedReturn_pct), fmt_pct_id(r$ExpectedReturn_pct)),
      tags$td(fmt_pct_id(r$StdDev_pct)),
      tags$td(fmt_pct_id(r$ProbLoss_pct))
    )
  })
  tags$table(class = "mc-table", header, tags$tbody(rows))
}

render_alert_row <- function(alert_row) {
  icon_b64 <- switch(alert_row$severity,
                     "Critical" = ALERT_ICON_CRITICAL_B64,
                     "Warning" = ALERT_ICON_CAUTION_B64,
                     "Caution" = ALERT_ICON_CAUTION_B64,
                     ALERT_ICON_INFO_B64)
  div(class = "mc-alert-row",
      tags$img(class = "mc-alert-icon", src = paste0("data:image/png;base64,", icon_b64)),
      div(
        div(class = "mc-alert-text", alert_row$description),
        div(class = "mc-alert-meta",
            tags$span(class = paste0("mc-severity-badge mc-badge-", tolower(alert_row$severity)), alert_row$severity),
            if (!is.na(alert_row$issuer) && alert_row$issuer != "-") paste0("  \u00b7  ", alert_row$issuer) else "",
            if (!is.na(alert_row$sector) && alert_row$sector != "-") paste0("  \u00b7  ", alert_row$sector) else ""
        )
      )
  )
}

empty_state_plot <- function(msg) {
  ggplot2::ggplot() + ggplot2::annotate("text", x = 0, y = 0, label = msg, size = 4.5, color = "#999999") +
    ggplot2::theme_void()
}

empty_state_plotly <- function(msg) {
  plotly::plot_ly() %>%
    plotly::add_annotations(text = msg, x = 0.5, y = 0.5, showarrow = FALSE,
                            font = list(size = 14, color = "#999999")) %>%
    plotly::layout(xaxis = list(visible = FALSE), yaxis = list(visible = FALSE),
                   margin = list(l = 0, r = 0, t = 0, b = 0),
                   paper_bgcolor = "transparent", plot_bgcolor = "transparent") %>%
    plotly::config(displayModeBar = FALSE)
}

draw_donut_chart <- function(df, cat_col, val_col, colors) {
  plotly::plot_ly(
    df, labels = ~get(cat_col), values = ~get(val_col), type = "pie", hole = 0.6,
    marker = list(colors = unname(colors[df[[cat_col]]]), line = list(color = "#FFFFFF", width = 2)),
    texttemplate = "%{label}<br>%{percent:.3%}", textposition = "outside",
    textfont = list(size = 13, family = "inherit"),
    hoverinfo = "label+percent+value",
    hovertemplate = paste0("<b>%{label}</b><br>%{percent:.3%}<br>%{value} issuer(s)<extra></extra>"),
    sort = FALSE, domain = list(x = c(0, 1), y = c(0, 1))
  ) %>%
    plotly::layout(
      showlegend = TRUE,
      legend = list(orientation = "v", x = 1, y = 0.5, font = list(size = 12)),
      margin = list(l = 20, r = 20, t = 20, b = 20, pad = 0),
      autosize = TRUE,
      paper_bgcolor = "transparent", plot_bgcolor = "transparent"
    ) %>%
    plotly::config(displayModeBar = FALSE)
}

draw_sector_bar_chart <- function(agg) {
  agg$sector <- factor(agg$sector, levels = agg$sector)
  agg$color <- ifelse(agg$ExpectedReturn_pct < 0, "#C0392B", "#1E8449")
  agg$label <- fmt_pct_id(agg$ExpectedReturn_pct)
  
  plotly::plot_ly(
    agg, x = ~ExpectedReturn_pct, y = ~sector, type = "bar", orientation = "h",
    marker = list(color = ~color),
    hoverinfo = "text",
    hovertext = ~paste0("<b>", sector, "</b><br>Average Expected Return: ", label)
  ) %>%
    plotly::layout(
      xaxis = list(title = "Average Expected Return (%)", zeroline = TRUE, zerolinecolor = "#999"),
      yaxis = list(title = "", automargin = TRUE, tickfont = list(size = 11)),
      margin = list(l = 10, r = 20, t = 10, b = 40, pad = 0),
      autosize = TRUE,
      paper_bgcolor = "transparent", plot_bgcolor = "transparent"
    ) %>%
    plotly::config(displayModeBar = FALSE)
}



mod_issuer_details_ui <- function(id) {
  ns <- NS(id)
  
  div(class = "mc-body",
      div(class = "mc-content", style = "width:100%; padding:18px 24px;",
          
          div(class = "mc-card",
              fluidRow(
                column(8, tags$label(class = "mc-label", "Select Issuer:"),
                       uiOutput(ns("issuer_selector"))),
                column(4, div(style = "text-align:right; padding-top:22px;",
                              uiOutput(ns("issuer_download_btn_area"))))
              )
          ),
          
          uiOutput(ns("issuer_meta")),
          
          div(class = "mc-card",
              tags$h3(class = "mc-card-title", "Historical Model Comparison"),
              uiOutput(ns("plot_comparison_area"))
          ),
          
          div(class = "mc-card",
              tags$h3(class = "mc-card-title", "Mean Absolute Error (MAE) Comparison"),
              uiOutput(ns("mae_cards"))
          ),
          
          div(class = "mc-card",
              tags$h3(class = "mc-card-title", "Three-Method Return Comparison Under Current Scenario"),
              uiOutput(ns("scenario_comparison_area"))
          ),
          
          div(class = "mc-card",
              tags$h3(class = "mc-card-title", "Wald Test"),
              uiOutput(ns("wald_table"))
          ),
          
          div(class = "mc-card",
              tags$h3(class = "mc-card-title", "Regime Probability Forecast (t+1 to t+10)"),
              uiOutput(ns("regime_forecast_area"))
          ),
          
          div(class = "mc-grid-2",
              div(class = "mc-card",
                  tags$h3(class = "mc-card-title", "Monte Carlo Return Distribution"),
                  uiOutput(ns("mc_hist_subtitle")),
                  plotOutput(ns("plot_mc_hist"), height = "320px")
              ),
              div(class = "mc-card",
                  tags$h3(class = "mc-card-title", "Stress Test Impact Summary"),
                  uiOutput(ns("stress_summary"))
              )
          )
      )
  )
}

mod_issuer_details_server <- function(id, rv) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    output$issuer_selector <- renderUI({
      req(rv$issuer_registry)
      reg <- rv$issuer_registry
      choices <- stats::setNames(reg$raw_ticker, reg$clean_ticker)
      selectInput(ns("selected_issuer"), NULL, choices = choices, selected = choices[1], width = "100%")
    })
    
    issuer_row <- reactive({
      req(input$selected_issuer, rv$issuer_registry)
      reg <- rv$issuer_registry
      reg[reg$raw_ticker == input$selected_issuer, ][1, ]
    })
    
    markov_model <- reactive({
      req(input$selected_issuer, rv$markov_models)
      rv$markov_models[[input$selected_issuer]]
    })
    
    output$issuer_download_btn_area <- renderUI({
      row <- issuer_row()
      if (is.null(row) || nrow(row) == 0 || is.na(row$workbook_path) || !file.exists(row$workbook_path)) {
        return(NULL)
      }
      downloadButton(ns("btn_download_issuer_excel"), "Download Excel (Issuer)",
                     class = "mc-sidebar-btn mc-btn-simulate", icon = NULL,
                     style = "width:auto; display:inline-block;")
    })
    
    output$btn_download_issuer_excel <- downloadHandler(
      filename = function() {
        row <- issuer_row()
        if (is.null(row) || nrow(row) == 0 || is.na(row$workbook_path)) return("Issuer_Output.xlsx")
        basename(row$workbook_path)
      },
      content = function(file) {
        row <- issuer_row()
        req(row, !is.na(row$workbook_path), file.exists(row$workbook_path))
        file.copy(row$workbook_path, file, overwrite = TRUE)
      }
    )
    
    output$issuer_meta <- renderUI({
      row <- issuer_row()
      mdl <- markov_model()
      req(row, mdl)
      div(class = "mc-card",
          div(class = "mc-issuer-meta-grid",
              meta_item("Ticker", row$clean_ticker),
              meta_item("Sector", row$sector),
              meta_item("Model Type", "MS-AR (Markov Switching Autoregressive)"),
              meta_item("Number of Regimes", safe_val(mdl$best_k, "Not Available")),
              meta_item("Selected Variables (Best Subset)", row$selected_variables),
              meta_item("Mandatory Factor(s)", row$mandatory_variables),
              meta_item("Sample Period", paste(row$sample_start, "-", row$sample_end)),
              meta_item("Frequency / Aggregation", paste0(row$frequency, " (", row$aggregation_method, ")")),
              meta_item("AR Order", safe_val(row$ar_order, "Not Available")),
              meta_item("Transformation Type", detect_transformation_type(mdl))
          )
      )
    })
    
    comparison_bundle <- reactive({
      req(rv$root_dir, issuer_row(), markov_model())
      build_historical_comparison_bundle(rv$root_dir, issuer_row(), markov_model())
    }) %>% bindCache(input$selected_issuer)
    
    output$plot_comparison_area <- renderUI({
      bundle <- comparison_bundle()
      if (!isTRUE(bundle$available)) {
        return(div(class = "mc-not-available", bundle$unavailable_reason))
      }
      period_txt <- if (!is.na(bundle$sample_label)) {
        paste0(bundle$sample_label, " | ", fmt_int_id(bundle$n_obs_common),
               " observations (suspend-pruned sample)")
      } else {
        paste0(fmt_int_id(bundle$n_obs_common), " observations (suspend-pruned sample)")
      }
      tagList(
        div(style = "font-size:15px; font-weight:800; color:var(--mc-text-dark); margin-bottom:2px;",
            paste0("Actual vs Fitted Return - ", issuer_row()$clean_ticker)),
        div(style = "font-size:12px; color:var(--mc-text-muted); margin-bottom:8px;", period_txt),
        div(class = "mc-help", style = "margin-bottom:6px;",
            "Hover for exact values at any date, drag to zoom into a window, use the range slider ",
            "below the chart to scrub through the sample, and double-click to reset the view. ",
            "Click a legend entry to hide or isolate a series."),
        plotly::plotlyOutput(ns("plot_comparison"), height = "440px")
      )
    })
    
    output$plot_comparison <- plotly::renderPlotly({
      bundle <- comparison_bundle()
      req(isTRUE(bundle$available))
      p <- draw_comparison_chart(bundle$combined, issuer_row()$clean_ticker)
      req(p)
      p
    })
    
    output$mae_cards <- renderUI({
      bundle <- comparison_bundle()
      maes <- c(MultipleRegression = bundle$mae_multiple, SimpleRegression = bundle$mae_simple,
                MyModel = bundle$mae_my_model)
      if (all(is.na(maes))) {
        return(div(class = "mc-not-available",
                   "MAE could not be computed: no common set of aligned actual/fitted observations was found ",
                   "across the models for this issuer."))
      }
      best_model <- names(maes)[which.min(maes)]
      tagList(
        div(class = "mc-mae-grid",
            mae_card("XLTP XMUR Bloomberg", maes["MultipleRegression"], best_model == "MultipleRegression", as_percent = TRUE),
            mae_card("HRA Bloomberg", maes["SimpleRegression"], best_model == "SimpleRegression", as_percent = TRUE),
            mae_card("My Model (MS-AR)", maes["MyModel"], best_model == "MyModel", as_percent = TRUE)
        ),
        div(class = "mc-mae-note",
            paste0("Computed in-app from ", fmt_int_id(bundle$n_obs_common), " observations common to every ",
                   "model shown (suspend-pruned sample", 
                   if (!is.na(bundle$sample_label)) paste0(", ", bundle$sample_label) else "",
                   "), so the MAE values are directly comparable."))
      )
    })
    
    scenario_benchmark <- reactive({
      sr <- rv$scenario_result
      req(sr, rv$root_dir, issuer_row(), markov_model())
      build_regression_benchmark(rv$root_dir, issuer_row(), markov_model(), sr$shock_vars, sr$shock_values)
    })
    
    output$scenario_comparison_area <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) {
        return(div(class = "mc-not-available", "Run a scenario on the Home tab to compare methods under the current shock."))
      }
      bench <- scenario_benchmark()
      row_now <- sr$ranking_table[sr$ranking_table$Kode_Saham == issuer_row()$raw_ticker, ]
      mc_pred_pct <- if (nrow(row_now) > 0) row_now$ExpectedReturn_pct[1] else NA_real_
      comp_tbl <- build_comparison_table_row(bench, mc_pred_pct)
      comp_tbl$Predicted_Return_pct <- vapply(comp_tbl$Predicted_Return_pct, function(v) {
        if (is.na(v)) "Not Available" else fmt_pct_id(v)
      }, character(1))
      comp_tbl$N_Obs <- vapply(comp_tbl$N_Obs, function(v) if (is.na(v)) "-" else as.character(v), character(1))
      tags$table(class = "mc-table",
                 tags$thead(tags$tr(tags$th("Method"), tags$th("Predicted Return"), tags$th("N Obs"))),
                 tags$tbody(lapply(seq_len(nrow(comp_tbl)), function(i) {
                   tags$tr(tags$td(comp_tbl$Method[i]), tags$td(comp_tbl$Predicted_Return_pct[i]),
                           tags$td(comp_tbl$N_Obs[i]))
                 }))
      )
    })
    
    output$wald_table <- renderUI({
      row <- issuer_row()
      wald_df <- get_wald_test_table(row$workbook_path)
      if (is.null(wald_df)) {
        return(div(class = "mc-not-available",
                   "Wald Test sheet not found in the issuer workbook. Not Available."))
      }
      se_cols <- names(wald_df)[grepl("se|std", tolower(names(wald_df)))]
      se_missing <- length(se_cols) > 0 &&
        any(is.na(suppressWarnings(as.numeric(unlist(wald_df[se_cols])))))
      
      tagList(
        if (isTRUE(se_missing)) {
          div(class = "mc-wald-invalid",
              "Warning: standard errors / Wald inference are not available for one or more coefficients ",
              "in this model (Hessian not positive definite even after numerical correction). Point ",
              "estimates and log-likelihood remain valid; z-statistic, Wald statistic, p-value, and ",
              "confidence interval may be NA for the affected coefficients.")
        },
        tags$div(style = "overflow-x:auto;", DT::dataTableOutput(ns("wald_dt")))
      )
    })
    
    output$wald_dt <- DT::renderDataTable({
      row <- issuer_row()
      wald_df <- get_wald_test_table(row$workbook_path)
      req(wald_df)
      numeric_cols <- names(wald_df)[vapply(wald_df, is.numeric, logical(1))]
      dt <- DT::datatable(
        wald_df, rownames = FALSE,
        options = list(paging = FALSE, searching = FALSE, info = FALSE,
                       scrollX = TRUE, dom = "t")
      )
      if (length(numeric_cols) > 0) dt <- DT::formatRound(dt, numeric_cols, digits = 3)
      dt
    })
    
    output$regime_forecast_area <- renderUI({
      row <- issuer_row()
      fc <- build_regime_forecast_display(row$workbook_path)
      if (is.null(fc)) {
        return(div(class = "mc-not-available",
                   "Regime Forecast (t+1 to t+10) sheet not found in the issuer workbook. Not Available."))
      }
      labs_txt <- paste(attr(fc, "regime_labels"), collapse = " / ")
      tagList(
        div(class = "mc-help",
            paste0("Regime probabilities projected forward from the last filtered state using the ",
                   "estimated transition matrix. Regimes are identified by their estimated residual ",
                   "standard deviation (", labs_txt, "), not by a directional bull/bear label.")),
        tags$div(style = "overflow-x:auto;", DT::dataTableOutput(ns("regime_forecast_dt")))
      )
    })
    
    output$regime_forecast_dt <- DT::renderDataTable({
      row <- issuer_row()
      fc <- build_regime_forecast_display(row$workbook_path)
      req(fc)
      prob_cols <- names(fc)[vapply(fc, is.numeric, logical(1))]
      dt <- DT::datatable(
        fc, rownames = FALSE,
        options = list(paging = FALSE, searching = FALSE, info = FALSE,
                       ordering = FALSE, scrollX = TRUE, dom = "t")
      )
      if (length(prob_cols) > 0) dt <- DT::formatPercentage(dt, prob_cols, 2)
      dt
    })
    
    output$mc_hist_subtitle <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) {
        return(div(class = "mc-not-available", "Run a scenario on the Home tab to view the simulated return distribution."))
      }
      if (mc_is_level_mode(sr)) {
        div(class = "mc-help", paste0("Scenario: ", paste(mc_shock_level_descriptions(sr), collapse = "; "), " | ",
                                      format(sr$n_sim, big.mark = ","), " simulations"))
      } else {
        div(class = "mc-help", paste0("Scenario: ", paste(sr$shock_vars, collapse = ", "), " = ",
                                      paste(sr$shock_values, collapse = ", "), "% | ",
                                      format(sr$n_sim, big.mark = ","), " simulations"))
      }
    })
    
    output$plot_mc_hist <- renderPlot({
      sr <- rv$scenario_result
      row <- issuer_row()
      if (is.null(sr) || is.null(row)) return(empty_state_plot("No Monte Carlo results available yet."))
      if (!(row$raw_ticker %in% colnames(sr$result_matrix))) {
        return(empty_state_plot("This issuer could not be simulated under the current scenario."))
      }
      res <- mc_plot_stock_distribution(sr, row$raw_ticker, rv$root_dir, save_to_disk = TRUE)
      req(res)
      res$plot
    }, bg = "white")
    
    output$stress_summary <- renderUI({
      sr <- rv$scenario_result
      row <- issuer_row()
      if (is.null(sr) || is.null(row) || !(row$raw_ticker %in% sr$ranking_table$Kode_Saham)) {
        return(div(class = "mc-not-available", "Not Available - run a scenario on the Home tab."))
      }
      rk <- sr$ranking_table[sr$ranking_table$Kode_Saham == row$raw_ticker, ][1, ]
      div(class = "mc-summary-grid", style = "grid-template-columns:repeat(2,1fr);",
          summary_card("Expected Return", fmt_pct_id(rk$ExpectedReturn_pct), pct_class(rk$ExpectedReturn_pct)),
          summary_card("Standard Deviation", fmt_pct_id(rk$StdDev_pct), ""),
          summary_card("VaR 95% (5th pct.)", fmt_pct_id(rk$VaR5_pct), "mc-neg"),
          summary_card("Probability of Loss", fmt_pct_id(rk$ProbLoss_pct), ""),
          summary_card("Shock Variables", paste(sr$shock_vars, collapse = ", "), ""),
          summary_card("Shock Magnitudes",
                       if (mc_is_level_mode(sr)) paste(mc_shock_level_descriptions(sr), collapse = "; ")
                       else paste0(paste(sr$shock_values, collapse = ", "), "%"), ""),
          summary_card("Number of Simulations", format(sr$n_sim, big.mark = ","), ""),
          summary_card("AR Order", safe_val(rk$AR_Order, "Not Available"), "")
      )
    })
  })
}

meta_item <- function(k, v) {
  div(class = "mc-issuer-meta-item",
      div(class = "k", k),
      div(class = "v", if (is.null(v) || is.na(v) || v == "") "Not Available" else v)
  )
}

mae_card <- function(label, value, is_best, as_percent = FALSE) {
  display_val <- if (is.na(value)) {
    "N/A"
  } else if (isTRUE(as_percent)) {
    fmt_pct_id(value * 100, 3)
  } else {
    fmt_num_id(value)
  }
  div(class = paste("mc-mae-card", if (isTRUE(is_best)) "best" else ""),
      div(class = "mm-label", label),
      div(class = "mm-value", display_val)
  )
}

draw_comparison_chart <- function(df, ticker_label) {
  if (is.null(df) || nrow(df) == 0) return(NULL)
  df$Date <- safe_as_date_id(df$Date)
  df <- df[!is.na(df$Date), , drop = FALSE]
  df <- df[order(df$Date), , drop = FALSE]
  if (nrow(df) == 0) return(NULL)
  
  series_map <- list(
    list(col = "Actual",             label = "Actual",              color = "#C0392B", dash = "solid", width = 1.0),
    list(col = "MyModel",            label = "My Model (MS-AR)",    color = "#E8A33D", dash = "solid", width = 1.4),
    list(col = "MultipleRegression", label = "XLTP XMUR Bloomberg", color = "#1E78C8", dash = "dot",   width = 1.3),
    list(col = "SimpleRegression",   label = "HRA Bloomberg",   color = "#1E8449", dash = "dot",   width = 1.3)
  )
  present <- Filter(function(s) {
    s$col %in% names(df) && any(is.finite(suppressWarnings(as.numeric(df[[s$col]]))))
  }, series_map)
  if (length(present) == 0) return(NULL)
  
  p <- NULL
  for (s in present) {
    yv <- suppressWarnings(as.numeric(df[[s$col]]))
    trace_args <- list(
      x = df$Date, y = yv, type = "scatter", mode = "lines", name = s$label,
      line = list(color = s$color, width = s$width, dash = s$dash),
      hovertemplate = paste0("<b>", s$label, "</b>: %{y:.4f}<extra></extra>"),
      connectgaps = FALSE
    )
    p <- if (is.null(p)) {
      do.call(plotly::plot_ly, trace_args)
    } else {
      do.call(plotly::add_trace, c(list(p), trace_args))
    }
  }
  
  plotly::layout(
    p,
    hovermode = "x unified",
    hoverlabel = list(namelength = -1),
    xaxis = list(
      title = "", type = "date", showspikes = TRUE, spikemode = "across",
      spikethickness = 1, spikedash = "dot", spikecolor = "#999999",
      rangeslider = list(visible = TRUE, thickness = 0.10)
    ),
    yaxis = list(title = "Return", zeroline = TRUE, zerolinecolor = "#CCCCCC", tickformat = ".3f"),
    legend = list(orientation = "h", x = 0, xanchor = "left", y = 1.02, yanchor = "bottom",
                  font = list(size = 12), tracegroupgap = 0),
    margin = list(l = 60, r = 20, t = 44, b = 20),
    paper_bgcolor = "transparent", plot_bgcolor = "transparent"
  ) %>%
    plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                   modeBarButtonsToRemove = list("select2d", "lasso2d"),
                   toImageButtonOptions = list(format = "png", scale = 2,
                                               filename = paste0("ModelComparison_", ticker_label)))
}


mod_portfolio_impact_ui <- function(id) {
  ns <- NS(id)
  
  div(class = "mc-body",
      div(class = "mc-content", style = "width:100%; padding:18px 24px;",
          
          div(class = "mc-card",
              fluidRow(
                column(8, tags$h3(class = "mc-card-title", style = "border:none; margin:0;", "Portfolio Impact - Ranking Table")),
                column(4, div(style = "text-align:right;",
                              downloadButton(ns("btn_download_excel"), "Download Excel Workbook", class = "mc-sidebar-btn mc-btn-simulate",
                                             icon = NULL,
                                             style = "width:auto; display:inline-block;")
                ))
              ),
              tags$hr(),
              uiOutput(ns("portfolio_table"))
          ),
          
          div(class = "mc-grid-2",
              div(class = "mc-card",
                  tags$h3(class = "mc-card-title", "Top 5 Worst Issuers"),
                  uiOutput(ns("top5_worst"))
              ),
              div(class = "mc-card",
                  tags$h3(class = "mc-card-title", "Top 5 Best Issuers"),
                  uiOutput(ns("top5_best"))
              )
          ),
          
          uiOutput(ns("failed_stocks_panel"))
      )
  )
}

mod_portfolio_impact_server <- function(id, rv) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    output$portfolio_table <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) {
        return(div(class = "mc-not-available", "Not Available - run a scenario on the Home tab first."))
      }
      DT::dataTableOutput(ns("dt_ranking"))
    })
    
    output$dt_ranking <- DT::renderDataTable({
      sr <- rv$scenario_result
      req(sr)
      rk <- sr$ranking_table
      DT::datatable(
        rk, rownames = FALSE, filter = "top",
        options = list(pageLength = 15, order = list(list(0, "asc")), scrollX = TRUE)
      ) %>%
        DT::formatRound(c("ExpectedReturn_pct", "StdDev_pct", "VaR5_pct", "ProbLoss_pct"), digits = 3) %>%
        DT::formatCurrency("Yesterday_Close_Price", currency = "Rp", interval = 3, mark = ".",
                           before = TRUE, digits = 0) %>%
        DT::formatStyle("ExpectedReturn_pct",
                        color = DT::styleInterval(0, c("#C0392B", "#1E8449")),
                        fontWeight = "bold") %>%
        DT::formatStyle("VaR5_pct",
                        backgroundColor = DT::styleInterval(c(-5, -3), c("#F9D5D3", "#FCEBC9", "white"))) %>%
        DT::formatStyle("ProbLoss_pct",
                        backgroundColor = DT::styleInterval(c(60, 80), c("white", "#FCEBC9", "#F9D5D3")))
    })
    
    output$top5_worst <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) return(div(class = "mc-not-available", "Not Available"))
      rk <- sr$ranking_table
      bot5 <- utils::head(rk[order(rk$ExpectedReturn_pct), ], 5)
      render_ranking_html_table(bot5)
    })
    
    output$top5_best <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr)) return(div(class = "mc-not-available", "Not Available"))
      rk <- sr$ranking_table
      top5 <- utils::head(rk[order(-rk$ExpectedReturn_pct), ], 5)
      render_ranking_html_table(top5)
    })
    
    output$failed_stocks_panel <- renderUI({
      sr <- rv$scenario_result
      if (is.null(sr) || length(sr$failed_stocks) == 0) return(NULL)
      div(class = "mc-card",
          tags$h3(class = "mc-card-title", "Issuers Excluded From This Scenario"),
          tags$p(paste0(length(sr$failed_stocks), " issuer(s) could not be simulated under this scenario:")),
          tags$ul(lapply(sr$failed_stocks, function(s) tags$li(clean_ticker(s))))
      )
    })
    
    output$btn_download_excel <- downloadHandler(
      filename = function() {
        sr <- rv$scenario_result
        if (is.null(sr)) return("no_scenario.xlsx")
        shock_tag <- if (mc_is_level_mode(sr)) {
          paste(mapply(function(v, inp, val) paste0(gsub("[^A-Za-z0-9]", "", v), "_Lvl", inp, "_", round(val, 2), "pct"),
                       sr$shock_vars, mc_shock_input_values(sr), sr$shock_values), collapse = "_")
        } else {
          paste(mapply(function(v, val) paste0(gsub("[^A-Za-z0-9]", "", v), "_", val, "pct"),
                       sr$shock_vars, sr$shock_values), collapse = "_")
        }
        paste0("Shock_", shock_tag, "_", format(Sys.time(), "%Y%m%d_%H%M%S"), "_Results.xlsx")
      },
      content = function(file) {
        req(rv$scenario_result)
        if (is.null(rv$scenario_export_paths)) {
          rv$scenario_export_paths <- mc_export_scenario(rv$scenario_result, rv$root_dir)
        }
        file.copy(rv$scenario_export_paths$xlsx_path, file, overwrite = TRUE)
      }
    )
  })
}


mc_eq <- function(latex, num) {
  div(class = "mc-eq",
      div(class = "mc-eq-body", latex),
      span(class = "mc-eq-num", paste0("(", num, ")"))
  )
}

mod_about_ui <- function(id) {
  ns <- NS(id)
  withMathJax(
    div(class = "mc-body",
        div(class = "mc-sidebar mc-about-toc",
            div(class = "mc-about-toc-title", "On This Page"),
            tags$nav(class = "mc-about-toc-list",
                     tags$a(href = "#mc-about-overview", "Overview"),
                     tags$a(href = "#mc-about-reading", "Reading The Issuer Details Panel"),
                     tags$a(href = "#mc-about-data", "Data & Frequency"),
                     tags$a(href = "#mc-about-methodology", "Methodology"),
                     tags$a(href = "#mc-about-stress", "Stress Testing Framework"),
                     tags$a(href = "#mc-about-risk", "Risk Measure Definitions"),
                     tags$a(href = "#mc-about-benchmark", "Regression Benchmark"),
                     tags$a(href = "#mc-about-references", "References"),
                     tags$a(href = "#mc-about-author", "Author & Disclosures")
            )
        ),
        div(class = "mc-content", style = "width:100%; padding:18px 28px 40px 28px;",
            
            div(class = "mc-about-doc-header",
                div(class = "mc-about-doc-label", "Model Documentation"),
                tags$h2("Methodology and Interpretation Guide"),
                div(class = "mc-about-doc-meta",
                    tags$span("Indonesian Equity Portfolio Stress Testing Framework."),
                    tags$span("MS-AR / DCC-GARCH / Student-t Copula."),
                    tags$span("For internal and professional use."))
            ),
            
            div(id = "mc-about-overview", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "01"),
                tags$h3("Overview"),
                tags$p("This dashboard combines six components to produce a conditional stress scenario for ",
                       "each issuer in the portfolio. Each component below feeds directly into the figures ",
                       "shown on the Issuer Details and Portfolio Impact pages."),
                tags$table(class = "mc-model-table",
                           tags$thead(tags$tr(tags$th("Component"), tags$th("Full Name"), tags$th("Role In This Dashboard"))),
                           tags$tbody(
                             tags$tr(tags$td(class = "mc-model-code", "MS-AR"), tags$td(class = "mc-model-name", "Markov Switching Autoregressive Model"),
                                     tags$td("Models each issuer's return as regime-dependent, and produces the Regime Probability Forecast.")),
                             tags$tr(tags$td(class = "mc-model-code", "DCC-GARCH"), tags$td(class = "mc-model-name", "Dynamic Conditional Correlation GARCH"),
                                     tags$td("Estimates time-varying conditional correlation across the nine macro factors.")),
                             tags$tr(tags$td(class = "mc-model-code", "Student-t Copula"), tags$td(class = "mc-model-name", "Tail Dependence Structure"),
                                     tags$td("Captures joint tail behaviour across factors, used to draw the conditional Monte Carlo scenarios.")),
                             tags$tr(tags$td(class = "mc-model-code", "Best Subset (BIC)"), tags$td(class = "mc-model-name", "Constrained Predictor Selection"),
                                     tags$td("Chooses each issuer's macro regressors under a minimum size, index, and sector constraint.")),
                             tags$tr(tags$td(class = "mc-model-code", "Wald Test"), tags$td(class = "mc-model-name", "Coefficient Significance"),
                                     tags$td("Flags which estimated coefficients are statistically distinguishable from zero.")),
                             tags$tr(tags$td(class = "mc-model-code", "Monte Carlo"), tags$td(class = "mc-model-name", "Conditional Stress Simulation"),
                                     tags$td("Generates the simulated return distribution behind every summary statistic on this dashboard."))
                           ))
            ),
            
            div(id = "mc-about-reading", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "02"),
                tags$h3("Reading The Issuer Details Panel"),
                tags$p("The table below maps every field on the Issuer Details page to its exact location and ",
                       "its correct interpretation, so each number can be read directly against the scenario ",
                       "used to produce it."),
                tags$table(class = "mc-about-table",
                           tags$thead(tags$tr(tags$th("Field"), tags$th("Location"), tags$th("What It Means Here"))),
                           tags$tbody(
                             tags$tr(tags$td(class = "field-col", "Expected Return"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("Probability-weighted average of the simulated one-period return, weighted by each regime's current smoothed probability. This is conditional on the shock set on the Home page, not an unconditional forecast.")),
                             tags$tr(tags$td(class = "field-col", "Standard Deviation"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("Dispersion of the simulated return distribution for this issuer under the shock. Read alongside VaR 95% to judge how wide the range of outcomes is, not just where it is centred.")),
                             tags$tr(tags$td(class = "field-col", "VaR 95% (5th pct.)"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("The loss threshold at the 5th percentile of the simulated distribution. It marks a boundary, not an average: 5% of simulated draws fall below this value and 95% do not.")),
                             tags$tr(tags$td(class = "field-col", "Probability of Loss"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("Share of simulated draws with a negative return. A frequency count only; it carries no information on how large those losses were.")),
                             tags$tr(tags$td(class = "field-col", "Shock Variables / Magnitudes"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("The scenario inputs carried over from the Home page. Every other figure on this panel is conditional on these two fields.")),
                             tags$tr(tags$td(class = "field-col", "Number of Simulations"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("Draw count behind the statistics above. A higher count stabilises tail estimates such as VaR 95% and Probability of Loss.")),
                             tags$tr(tags$td(class = "field-col", "AR Order"), tags$td(class = "loc-col", "Summary card"),
                                     tags$td("Autoregressive lag order fitted for this issuer's MS-AR mean equation.")),
                             tags$tr(tags$td(class = "field-col", "Wald Test table"), tags$td(class = "loc-col", "Wald Test card"),
                                     tags$td("Coefficient, standard error, z-statistic, and p-value for every predictor retained for this issuer. A p-value below 0.10 marks that coefficient as significant at the threshold used in this dashboard. Where the Hessian is not positive definite, the standard error and dependent statistics are left blank for the affected coefficient while its point estimate remains valid.")),
                             tags$tr(tags$td(class = "field-col", "Regime Probability Forecast"), tags$td(class = "loc-col", "Regime Probability card"),
                                     tags$td("Projected probability of each regime from t+1 to t+10, obtained by applying the fitted transition matrix to the last filtered regime state. Regimes are labelled by their estimated residual standard deviation, not by a bull or bear designation."))
                           ))
            ),
            
            div(id = "mc-about-data", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "03"),
                tags$h3("Data & Frequency"),
                tags$p("The model is estimated on daily closing prices for a portfolio of Indonesian equity ",
                       "issuers alongside nine macroeconomic and market factors: JCI Index, USD/IDR, CLA Comdty, ",
                       "XAU Curncy, XW1 Comdty, KO1 Comdty, LMNIDS03 LME Comdty (Nickel), IBPRCPI Index, and ",
                       "GTIDR1Y Govt. No weekly or multi-day aggregation is applied; every series is used at its ",
                       "native daily frequency. Every downstream step, including return calculation, marginal ",
                       "modelling, DCC-GARCH, copula estimation, best subset selection, and Markov Switching ",
                       "estimation, operates directly on this daily series.")
            ),
            
            div(id = "mc-about-methodology", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "04"),
                tags$h3("Methodology"),
                
                tags$h4("Return Transformation"),
                tags$p("Equity-like series use the log return transformation:"),
                mc_eq("$$r_{i,t} = \\ln\\left(\\frac{P_{i,t}}{P_{i,t-1}}\\right)$$", 1),
                tags$p("Rate and yield-type series instead use a first-difference transformation, ",
                       "\\(\\Delta X_t = X_t - X_{t-1}\\), consistent with the source pipeline's series-type detection."),
                
                tags$h4("Marginal Modelling: ARMA-GARCH"),
                tags$p("Each of the nine macro factors is modelled independently via an ARMA mean equation with ",
                       "a GARCH(1,1)-family conditional variance where ARCH effects are significant:"),
                mc_eq("$$\\sigma_{i,t}^2 = \\omega_i + \\alpha_i \\varepsilon_{i,t-1}^2 + \\beta_i \\sigma_{i,t-1}^2$$", 2),
                tags$p("This produces standardised residuals used as input to the joint dependence structure ",
                       "(Bollerslev, 1986)."),
                
                tags$h4("DCC-GARCH & Student-t Copula"),
                tags$p("Time-varying conditional correlation across the nine macro factors is captured by a ",
                       "Dynamic Conditional Correlation GARCH model (Engle, 2002):"),
                mc_eq("$$H_t = D_t R_t D_t, \\qquad D_t=\\text{diag}(\\sigma_{1,t},\\dots,\\sigma_{9,t})$$", 3),
                tags$p("A Student-t Copula is then fitted on the probability-integral-transformed standardised ",
                       "residuals to capture tail dependence beyond linear correlation (Demarta & McNeil, 2005). ",
                       "This joint distribution is estimated on the full nine-factor system regardless of which ",
                       "subset any individual issuer ultimately uses as a regressor."),
                
                tags$h4("Constrained Best Subset Selection"),
                tags$p("For every issuer, predictors are chosen independently from the nine macro factors via an ",
                       "exhaustive constrained search. A valid subset must contain a minimum of four variables, ",
                       "must always include JCI Index, and must include a sector-specific mandatory factor from a ",
                       "deterministic sector mapping (for example, ANTM is mapped to XAU Curncy given its gold ",
                       "exposure). Among subsets satisfying these constraints, the one minimising the Bayesian ",
                       "Information Criterion is selected (Schwarz, 1978):"),
                mc_eq("$$\\text{BIC} = -2\\ln \\hat{L} + k \\ln(n)$$", 4),
                
                tags$h4("Markov Switching Autoregressive Model (MS-AR)"),
                tags$p("Each issuer's return is modelled as a regime-conditional regression on its own selected ",
                       "predictors and autoregressive lags, following Hamilton (1989):"),
                mc_eq("$$R_{i,t} = \\alpha_{i,S_t} + \\boldsymbol{\\beta}_{i,S_t}' \\mathbf{X}_{i,t} + \\varepsilon_{i,t}, \\qquad \\varepsilon_{i,t}\\mid S_t \\sim N(0,\\sigma_{S_t}^2)$$", 5),
                tags$p("where \\(S_t\\) is a latent Markov chain. Estimation uses direct maximum likelihood with ",
                       "the Hamilton filter and Kim smoother, optimised via L-BFGS-B with multi-start ",
                       "initialisation to reduce the risk of local optima."),
                
                tags$h4("Wald Test"),
                tags$p("Coefficient significance is assessed via a Wald test based on the numerical Hessian at ",
                       "the optimum:"),
                mc_eq("$$W = \\frac{\\hat{\\beta}^2}{\\widehat{\\text{Var}}(\\hat{\\beta})} \\sim \\chi^2_{(1)}$$", 6),
                tags$p("Where the Hessian is not positive definite even after numerical correction, standard ",
                       "errors and Wald inference are not available for the affected coefficients. Point ",
                       "estimates and log-likelihood remain valid.")
            ),
            
            div(id = "mc-about-stress", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "05"),
                tags$h3("Stress Testing Framework"),
                tags$p("Given a user-specified shock to one or more macro factors, the shock value is converted ",
                       "to a copula quantile via each factor's fitted marginal distribution. Conditional draws for ",
                       "the remaining factors are then sampled from the fitted Student-t Copula given the shocked ",
                       "factor(s), preserving the full nine-factor dependence structure. These conditional draws ",
                       "are transformed back into macro returns via the inverse marginal CDF, using the ARMA-GARCH ",
                       "one-step-ahead forecast, and each issuer's return is predicted using only its own selected ",
                       "predictors, weighted across regimes by the most recent smoothed regime probability. No ",
                       "model is re-estimated to run a scenario. The dashboard reuses the previously estimated ",
                       "MS-AR, DCC-GARCH, and Student-t Copula objects.")
            ),
            
            div(id = "mc-about-risk", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "06"),
                tags$h3("Risk Measure Definitions"),
                tags$p("For each issuer, over \\(N\\) conditional Monte Carlo draws of simulated one-period ",
                       "return \\(r^{(1)},\\dots,r^{(N)}\\):"),
                mc_eq("$$\\text{Expected Return} = \\sum_{k=1}^{K} w_k \\left(\\bar{r}_k\\right), \\qquad \\text{VaR}_{95\\%} = r_{(0.05)}$$", 7),
                tags$p("where \\(w_k\\) is the smoothed probability of regime \\(k\\) and \\(r_{(0.05)}\\) is the ",
                       "lower 5th percentile of the simulated return distribution, a loss threshold rather than a ",
                       "gain threshold. Probability of Loss is the proportion of simulated draws with \\(r^{(i)} < 0\\)."),
                tags$p("These stress test results represent a conditional scenario analysis, not a forecast of ",
                       "actual future returns. Interpretation should account for the estimation sample, model ",
                       "specification, and the constrained predictor set used per issuer.")
            ),
            
            div(id = "mc-about-benchmark", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "07"),
                tags$h3("Regression Benchmark"),
                tags$p("Two regression benchmarks are computed directly in this dashboard for comparison against ",
                       "the Monte Carlo result and any existing reference calculation:"),
                mc_eq("$$\\text{Simple: } R_{i,t} = \\alpha_i + \\beta_i\\, \\text{JCI}_t + \\varepsilon_{i,t}$$", 8),
                mc_eq("$$\\text{Multiple: } R_{i,t} = \\alpha_i + \\boldsymbol{\\beta}_i' \\mathbf{X}_{i,t} + \\varepsilon_{i,t}$$", 9),
                tags$p("where \\(\\mathbf{X}_{i,t}\\) contains only the issuer's constrained best-subset predictors. ",
                       "Both are ordinary least squares fits on the same daily return series used by the main ",
                       "model, shown alongside the Monte Carlo expected return and any existing Excel reference ",
                       "calculation for the same issuer and scenario. On the dashboard these two benchmarks are ",
                       "labelled using their closest Bloomberg terminal equivalents: the single-variable fit is ",
                       "shown as \"HRA Bloomberg\" and the multi-variable fit as \"XLTP XMUR Bloomberg\".")
            ),
            
            div(id = "mc-about-references", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "08"),
                tags$h3("References"),
                tags$ol(class = "mc-ref-list",
                        tags$li("Hamilton, J. D. (1989). A New Approach to the Economic Analysis of Nonstationary ",
                                "Time Series and the Business Cycle. ", tags$em("Econometrica"), ", 57(2), 357 to 384."),
                        tags$li("Engle, R. F. (2002). Dynamic Conditional Correlation: A Simple Class of Multivariate ",
                                "Generalized Autoregressive Conditional Heteroskedasticity Models. ",
                                tags$em("Journal of Business & Economic Statistics"), ", 20(3), 339 to 350."),
                        tags$li("Bollerslev, T. (1986). Generalized Autoregressive Conditional Heteroskedasticity. ",
                                tags$em("Journal of Econometrics"), ", 31(3), 307 to 327."),
                        tags$li("Demarta, S., & McNeil, A. J. (2005). The t Copula and Related Copulas. ",
                                tags$em("International Statistical Review"), ", 73(1), 111 to 129."),
                        tags$li("Schwarz, G. (1978). Estimating the Dimension of a Model. ",
                                tags$em("The Annals of Statistics"), ", 6(2), 461 to 464."),
                        tags$li("Wald, A. (1943). Tests of Statistical Hypotheses Concerning Several Parameters When ",
                                "the Number of Observations is Large. ",
                                tags$em("Transactions of the American Mathematical Society"), ", 54(3), 426 to 482.")
                )
            ),
            
            div(id = "mc-about-author", class = "mc-about-section",
                tags$span(class = "mc-about-section-num", "09"),
                tags$h3("Author & Disclosures"),
                div(class = "mc-about-author",
                    div(class = "mc-about-author-mark", "RZA"),
                    div(style = "flex:1;",
                        tags$h4(style = "margin:0 0 2px 0; font-size:15px;", "Raihan Zakia Adani"),
                        tags$p(style = "margin:0 0 10px 0; color:#217A5B; font-weight:700; font-size:12.5px;",
                               "Model Developer and Dashboard Author"),
                        tags$p(style = "margin:0 0 10px 0; color:#444; font-size:13px; line-height:1.65;",
                               "Final-year Actuarial Science student at Universitas Padjadjaran, currently an ",
                               "Equities, Fixed Income and Equity Market Intern at BPJS Ketenagakerjaan."),
                        tags$p(style = "margin:0 0 10px 0; color:#444; font-size:13px; line-height:1.65;",
                               "Work covers quantitative financial and actuarial modelling, equity portfolio ",
                               "stress testing, investment risk analysis, and financial market analysis, with a ",
                               "focus on applying actuarial and quantitative methods to investment decision-making."),
                        tags$p(style = "margin:0 0 4px 0; color:#444; font-size:13px; line-height:1.65;",
                               "Areas of focus:"),
                        tags$ul(style = "margin:4px 0 0 0; padding-left:18px; font-size:12.5px; color:#555; line-height:1.7;",
                                tags$li("Quantitative financial and actuarial modelling"),
                                tags$li("Equity stress testing and investment risk"),
                                tags$li("Fixed income and yield curve analysis"),
                                tags$li("Portfolio and financial market analysis")
                        )
                    )
                )
            )
        )
    )
  )
}

mod_about_server <- function(id, rv) {
  moduleServer(id, function(input, output, session) {
    invisible(NULL)
  })
}


show_all_alerts_modal <- function(alerts_df) {
  showModal(modalDialog(
    title = "All Alerts & Notifications",
    size = "l", easyClose = TRUE, fade = TRUE,
    if (is.null(alerts_df) || nrow(alerts_df) == 0) {
      div(class = "mc-not-available", "No alerts available - run a scenario to generate risk notifications.")
    } else {
      tagList(
        fluidRow(
          column(4, selectInput("alert_filter_severity", "Severity",
                                choices = c("All", unique(alerts_df$severity)), selected = "All")),
          column(4, selectInput("alert_filter_issuer", "Issuer",
                                choices = c("All", sort(unique(alerts_df$issuer[alerts_df$issuer != "-"]))),
                                selected = "All")),
          column(4, selectInput("alert_filter_sector", "Sector",
                                choices = c("All", sort(unique(alerts_df$sector[alerts_df$sector != "-"]))),
                                selected = "All"))
        ),
        uiOutput("alert_modal_list")
      )
    },
    footer = modalButton("Close")
  ))
}

mod_alerts_filter_server <- function(input, output, session, rv) {
  output$alert_modal_list <- renderUI({
    al <- rv$alerts
    req(al)
    if (!is.null(input$alert_filter_severity) && input$alert_filter_severity != "All") {
      al <- al[al$severity == input$alert_filter_severity, ]
    }
    if (!is.null(input$alert_filter_issuer) && input$alert_filter_issuer != "All") {
      al <- al[al$issuer == input$alert_filter_issuer, ]
    }
    if (!is.null(input$alert_filter_sector) && input$alert_filter_sector != "All") {
      al <- al[al$sector == input$alert_filter_sector, ]
    }
    if (nrow(al) == 0) return(div(class = "mc-not-available", "No alerts match the selected filters."))
    tagList(lapply(seq_len(nrow(al)), function(i) render_alert_row(al[i, ])))
  })
}


render_setup_error_page <- function(root_dir, load_error) {
  div(style = "max-width:780px; margin:60px auto; padding:0 20px;",
      div(class = "mc-card", style = "border-color:#E8B4B4;",
          tags$h3(class = "mc-card-title", style = "color:#C0392B; border-bottom-color:#E8B4B4;",
                  "Dashboard Setup Incomplete"),
          tags$p(style = "font-size:13.5px; color:#333; line-height:1.6;",
                 "This dashboard automatically looks for pipeline output files in its own application folder ",
                 "- there is no directory picker. Currently looking in:"),
          tags$pre(style = "background:#F9F9F9; border-radius:6px; padding:10px 14px; font-size:12.5px; overflow-x:auto;",
                   root_dir),
          tags$p(style = "font-size:13.5px; color:#7A1F16; white-space:pre-wrap; line-height:1.6;",
                 if (!is.null(load_error)) load_error else "Unknown error."),
          tags$p(style = "font-size:13px; color:#555; margin-top:14px;",
                 "Copy every file/folder produced by the estimation pipeline (All_Markov_Models.rds, ",
                 "JointDistribution_Model.rds, raw_data.xlsx, the ",
                 "Output_MarkovRegimeSwitching_*.xlsx workbooks, and the Plots/ folder) directly into the ",
                 "same folder as this app's .R file, then click Retry."),
          actionButton("btn_retry_load", "Retry", class = "mc-sidebar-btn mc-btn-simulate", style = "width:auto; margin-top:10px;")
      )
  )
}

ui <- fluidPage(
  title = "Monte Carlo Stress Testing Dashboard",
  tags$head(
    tags$meta(charset = "utf-8"),
    tags$style(HTML(CUSTOM_CSS_TEXT)),
    tags$script(HTML(CUSTOM_JS_TEXT))
  ),
  uiOutput("app_header_ui"),
  uiOutput("main_content")
)

server <- function(input, output, session) {
  
  rv <- reactiveValues(
    root_dir = DEFAULT_ROOT_DIR,
    loaded = FALSE,
    load_error = NULL,
    joint_dist = NULL,
    markov_models = NULL,
    issuer_registry = NULL,
    macro_vars = NULL,
    latest_date = NA,
    scenario_result = NULL,
    scenario_export_paths = NULL,
    alerts = NULL,
    current_tab = "home"
  )
  
  attempt_load_root <- function(root_dir) {
    status <- discover_root_structure(root_dir)
    if (!isTRUE(status$valid)) {
      rv$loaded <- FALSE
      rv$load_error <- paste0(
        "The following required file(s) were not found in this app's own folder ('", root_dir, "'): ",
        paste(status$missing, collapse = ", "),
        ". Copy all pipeline output files (All_Markov_Models.rds, JointDistribution_Model.rds, ",
        "raw_data.xlsx, the Output_MarkovRegimeSwitching_*.xlsx workbooks, and the ",
        "Plots/ folder) into the SAME folder as this app, then restart the app."
      )
      return(invisible(FALSE))
    }
    
    core <- tryCatch(load_core_models(root_dir), error = function(e) e)
    if (inherits(core, "error")) {
      rv$loaded <- FALSE
      rv$load_error <- paste0("Failed to read model objects: ", conditionMessage(core))
      return(invisible(FALSE))
    }
    
    integrity <- validate_model_integrity(core$markov_models, core$joint_dist)
    if (!isTRUE(integrity$ok)) {
      rv$loaded <- FALSE
      rv$load_error <- paste0(
        "Model/data integrity validation failed:\n- ", paste(integrity$issues, collapse = "\n- ")
      )
      return(invisible(FALSE))
    }
    
    rv$root_dir <- root_dir
    rv$joint_dist <- core$joint_dist
    rv$markov_models <- core$markov_models
    rv$macro_vars <- get_macro_variable_list(core$joint_dist)
    rv$issuer_registry <- build_issuer_registry(core$markov_models, root_dir)
    rv$latest_date <- get_latest_data_date(root_dir)
    rv$loaded <- TRUE
    rv$load_error <- NULL
    invisible(TRUE)
  }
  
  attempt_load_root(resolve_data_root(DEFAULT_ROOT_DIR))
  
  observeEvent(input$btn_retry_load, {
    attempt_load_root(resolve_data_root(DEFAULT_ROOT_DIR))
  })
  
  observeEvent(input$app_nav_click, {
    rv$current_tab <- input$app_nav_click
  })
  
  output$app_header_ui <- renderUI({
    render_app_header(session, rv$current_tab, rv$latest_date)
  })
  
  output$main_content <- renderUI({
    if (!isTRUE(rv$loaded)) {
      return(render_setup_error_page(rv$root_dir, rv$load_error))
    }
    switch(rv$current_tab,
           "home"      = mod_home_ui("home"),
           "issuer"    = mod_issuer_details_ui("issuer"),
           "portfolio" = mod_portfolio_impact_ui("portfolio"),
           "about"     = mod_about_ui("about"),
           mod_home_ui("home")
    )
  })
  
  mod_home_server("home", rv)
  mod_issuer_details_server("issuer", rv)
  mod_portfolio_impact_server("portfolio", rv)
  mod_about_server("about", rv)
  
  mod_alerts_filter_server(input, output, session, rv)
}

shinyApp(ui = ui, server = server)