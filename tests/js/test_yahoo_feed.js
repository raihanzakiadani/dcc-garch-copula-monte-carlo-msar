// Logic test of the Apps Script parsing/merging with a MOCK of Yahoo's chart JSON (structure from public knowledge; not live).
const assert = require('assert');
const {parseYahooChart_, mergeSeries_} = require('../../apps_script/yahoo_feed.gs');
const mk = (ts, adj, close) => JSON.stringify({chart: {result: [{meta: {gmtoffset: 25200}, timestamp: ts,
  indicators: {quote: [{close: close}], adjclose: adj ? [{adjclose: adj}] : undefined}}]}});
const t0 = Date.UTC(2026, 9, 8, 17, 0, 0) / 1000;               // 08 Oct 17:00 UTC -> 09 Oct 00:00 in UTC+7
const a = parseYahooChart_(mk([t0, t0 + 86400, t0 + 2 * 86400], [16500.5, null, 16520], [1, 2, 3]));
assert.deepStrictEqual(a, {'2026-10-09': 16500.5, '2026-10-11': 16520});          // null skipped, exchange-local date, adjclose preferred
const c = parseYahooChart_(mk([t0], null, [77.7]));
assert.deepStrictEqual(c, {'2026-10-09': 77.7});                                    // falls back to close when adjclose absent
assert.throws(() => parseYahooChart_('{"chart":{"result":null}}'));
const rows = mergeSeries_({X: {'2026-10-09': 1, '2026-10-12': 2}, Y: {'2026-10-12': 5}}, ['X', 'Y']);
assert.deepStrictEqual(rows, [['2026-10-09', 1, ''], ['2026-10-12', 2, 5]]);        // gaps stay blank, never filled
console.log('apps script logic OK');
