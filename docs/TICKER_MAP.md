# Pemetaan ticker Bloomberg (kolom `raw_data.xlsx`) -> sumber pengganti

Nama kolom Bloomberg **tidak diubah** dan tidak dikirim ke sumber mana pun. Ia hanya label kolom. Yang diambil dari tiap sumber adalah **ticker sumber itu sendiri**
(kolom kanan). Seri pengganti **bukan seri Bloomberg yang sama persis**; kesesuaiannya diukur terhadap riwayat Anda (korelasi return) dan dicek setiap run.

| Kolom Bloomberg (label, tetap) | Ticker/seri di sumber pengganti | Sumber | Diverifikasi terhadap riwayat |
|---|---|---|---|
| `JCI Index` | `COMPOSITE` | IDX GetIndexSummary | belum (live) |
| `<KODE> IJ EQUITY` (71 saham) | `<KODE>` (4 huruf pertama) | IDX GetStockSummary | belum (live) |
| `USDIDR BGN Curncy` | Yahoo **`IDR=X`** (adj close) | Yahoo lewat Google Sheet (`apps_script/yahoo_feed.gs`) | belum (butuh feed nyata) |
| `CO1 Comdty` | Yahoo **`BZ=F`** (adj close) | Yahoo lewat Google Sheet | belum (butuh feed nyata) |
| `XAU Curncy` | Investing.com ID XAU/USD (`xau-usd-historical-data`) | id.investing.com | ya: korelasi return 0,78 (19 hari), selisih rata-rata 0,35%/hari; level cocok (rasio 1,001) |
| `XW1 Comdty` | Investing.com Newcastle Coal Futures | investing.com | **ya, sangat baik: korelasi 0,996; 17 dari 19 hari nilainya persis sama** -> seri yang sama |
| `KO1 Comdty` | MPOC "Settlement Price RM" | mpoc.org.my | sebagian: 4 nilai identik; tanggal bergeser <=1 hari. **Live OK (13 Okt 2026)** |
| `LMNIDS03 LME Comdty` | Westmetall `LME_Ni_cash` | westmetall.com | ya: 0,70. **Live OK (13 Okt 2026)** |
| `IBPRCPI Index` | PHEI "INDOBeX Government Clean Price" | phei.co.id | ya: perubahan YTD cocok (-5,75% vs -5,80%). **Live OK (13 Okt 2026)** |
| `GTIDR1Y Govt` | Investing.com ID 1Y | id.investing.com | **Live OK (13 Okt 2026): 22 baris, terbaru 6,721** |

Ticker Google Finance (mis. `CURRENCY:USDIDR`) **tidak dipakai** kecuali Anda memilih alternatif GOOGLEFINANCE di `docs/SHEETS_FEED.md`; itu seri Google, bukan Yahoo.

Beda definisi yang perlu Anda ketahui:
- `USDIDR BGN` = fixing Bloomberg BGN; `IDR=X` = kuotasi pasar Yahoo. Sangat berkorelasi, tetapi bukan angka yang sama.
- `CO1 Comdty` = Brent front-month generik Bloomberg; `BZ=F` = futures Brent di Yahoo. Kontrak dan jam penutupan bisa berbeda.

Mengubah ticker sumber: untuk Yahoo, edit `symbol` pada `SERIES` di `apps_script/yahoo_feed.gs`; untuk lainnya, URL ada di `config/pipeline.json`.
Nama pada `col` (skrip) harus sama persis dengan nama kolom Bloomberg (dijaga oleh `tests/test_ticker_map.py`).
