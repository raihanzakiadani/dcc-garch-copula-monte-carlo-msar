/**
 * Yahoo Finance -> Google Sheet feed (ADJUSTED close). Paste into Extensions > Apps Script of the feed spreadsheet.
 * Writes tab "feed":  Dates | USDIDR BGN Curncy | CO1 Comdty   (ISO dates as TEXT, plain numbers)
 * then publish ONLY the tab "feed" (File > Share > Publish to web > that tab > CSV) and put the URL into the GitHub
 * secret SRC_YAHOO_SHEET_CSV.  Safety: if either symbol fails or looks truncated, the previous feed is KEPT and the
 * error is written to tab "status" (and thrown, so Apps Script emails you) - a bad fetch never overwrites good data.
 * NOT verified against live Yahoo from the authoring sandbox (no internet): Yahoo may rate-limit Google IPs (HTTP 429).
 */
var SERIES = [
  {col: 'USDIDR BGN Curncy', symbol: 'IDR=X'},
  {col: 'CO1 Comdty',        symbol: 'BZ=F'}
];
var RANGE = '3mo';          // enough overlap for the definition check (>= 15 days) even after holidays
var MIN_ROWS = 20;          // refuse to publish a suspiciously short history

function parseYahooChart_(text, field) {
  var j = JSON.parse(text);
  var res = j.chart && j.chart.result && j.chart.result[0];
  if (!res || !res.timestamp) throw new Error('unexpected Yahoo JSON');
  var off = (res.meta && res.meta.gmtoffset) || 0;
  var adj = (field !== 'close' && res.indicators.adjclose && res.indicators.adjclose[0] && res.indicators.adjclose[0].adjclose) ||
            res.indicators.quote[0].close;
  var out = {};
  for (var i = 0; i < res.timestamp.length; i++) {
    if (adj[i] === null || adj[i] === undefined) continue;
    var iso = new Date((res.timestamp[i] + off) * 1000).toISOString().slice(0, 10);   // exchange-local calendar date
    out[iso] = adj[i];
  }
  return out;
}

function mergeSeries_(seriesByCol, cols) {
  var dates = {};
  cols.forEach(function (c) { Object.keys(seriesByCol[c]).forEach(function (d) { dates[d] = true; }); });
  return Object.keys(dates).sort().map(function (d) {
    return [d].concat(cols.map(function (c) { var v = seriesByCol[c][d]; return (v === undefined) ? '' : v; }));
  });
}

function fetchSeries_(symbol) {
  var path = '/v8/finance/chart/' + encodeURIComponent(symbol) + '?range=' + RANGE + '&interval=1d&events=history';
  var hosts = ['https://query1.finance.yahoo.com', 'https://query2.finance.yahoo.com'];
  var lastCode = 'no response';
  for (var attempt = 0; attempt < 2; attempt++) {
    for (var h = 0; h < hosts.length; h++) {
      var r = UrlFetchApp.fetch(hosts[h] + path, {muteHttpExceptions: true, headers: {'User-Agent': 'Mozilla/5.0'}});
      lastCode = r.getResponseCode();
      if (lastCode === 200) return parseYahooChart_(r.getContentText());
    }
    Utilities.sleep(2000);                                   // Yahoo sometimes answers 429 for a moment
  }
  throw new Error(symbol + ': HTTP ' + lastCode + ' (after retries on query1 and query2)');
}

/** TRY THIS FIRST: fetches both series and shows the result in View > Logs. Writes NOTHING to the sheet. */
function previewYahoo() {
  SERIES.forEach(function (s) {
    try {
      var d = fetchSeries_(s.symbol), k = Object.keys(d).sort();
      Logger.log('%s <- %s : %s rows, %s .. %s, newest value %s', s.col, s.symbol, k.length, k[0], k[k.length - 1], d[k[k.length - 1]]);
    } catch (e) { Logger.log('%s <- %s : FAILED %s', s.col, s.symbol, e.message); }
  });
}

function refreshYahooFeed() {
  var ss = SpreadsheetApp.getActive();
  var status = ss.getSheetByName('status') || ss.insertSheet('status');
  try {
    var by = {};
    SERIES.forEach(function (s) {
      by[s.col] = fetchSeries_(s.symbol);
      if (Object.keys(by[s.col]).length < MIN_ROWS) throw new Error(s.symbol + ': only ' + Object.keys(by[s.col]).length + ' rows');
    });
    var cols = SERIES.map(function (s) { return s.col; });
    var rows = mergeSeries_(by, cols);
    var sh = ss.getSheetByName('feed') || ss.insertSheet('feed');
    sh.clearContents();
    sh.getRange(1, 1, 1, cols.length + 1).setValues([['Dates'].concat(cols)]);
    sh.getRange(2, 1, rows.length, 1).setNumberFormat('@');                       // keep ISO dates as text
    sh.getRange(2, 2, rows.length, cols.length).setNumberFormat('0.0000');        // no thousand separators in the CSV
    sh.getRange(2, 1, rows.length, cols.length + 1).setValues(rows);
    status.getRange('A1:B1').setValues([['last_ok_utc', new Date().toISOString()]]);
    status.getRange('A2:B2').setValues([['last_error', '']]);
  } catch (e) {
    status.getRange('A2:B2').setValues([['last_error', new Date().toISOString() + ' ' + e.message]]);
    throw e;                                                                      // previous feed stays untouched
  }
}

/** Run once manually, then it refreshes itself every day ~13:00-14:00 (sheet's time zone). */
function installDailyTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'refreshYahooFeed') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('refreshYahooFeed').timeBased().everyDays(1).atHour(13).create();
}

if (typeof module !== 'undefined') { module.exports = {parseYahooChart_: parseYahooChart_, mergeSeries_: mergeSeries_}; }
