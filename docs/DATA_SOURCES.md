# Sumber data per instrumen (status verifikasi per 2026-10-09)

| Kolom model | Sumber | Parser | Definisi vs riwayat tersimpan | Penyambungan |
|---|---|---|---|---|
| JCI Index + 71 saham IJ | IDX `GetIndexSummary`/`GetStockSummary` (mekanisme proyek lama) | dari kode lama, **belum dijalankan live** | JCI sama definisinya → cek anchor eksak | level_exact |
| USDIDR BGN Curncy | Yahoo `IDR=X` adj close **via Google Sheet** (`apps_script/yahoo_feed.gs` → CSV terbit; lihat `docs/SHEETS_FEED.md`) | logika skrip teruji dengan JSON tiruan; **live belum** | belum ada sampel; BGN ≠ Yahoo | chain_return |
| CO1 Comdty | Yahoo `BZ=F` adj close **via Google Sheet** (skrip yang sama) | logika skrip teruji dengan JSON tiruan; **live belum** | belum ada sampel | chain_return |
| XAU Curncy | Stooq `xauusd` | **terverifikasi** pada halaman Anda | korelasi return 0,93 (40 hari), rasio level 1,0003 | chain_return |
| XW1 Comdty | Stooq `lq.f` (ICE Newcastle Coal) | **terverifikasi** | korelasi return **0,57**, rasio level 0,96, volume tipis → **noisy / kemungkinan bukan seri yang sama** | chain_return |
| KO1 Comdty | MPOC daily palm oil (`Settlement Price RM`, tabel 10 hari terakhir) | **terverifikasi** pada halaman Anda | nilai identik dengan KO1 pada 4 dari 10 hari, tetapi tanggal KO1 tersimpan bergeser ≤1 hari terhadap MPOC dan ada nilai basi; korelasi lag-0 −0,03, lag-1 0,64 (n≤9) → **cek definisi dinonaktifkan** (sampel terlalu pendek); titik sambung bisa membawa selisih penanggalan 1 hari | chain_return |
| LMNIDS03 LME Comdty | Westmetall `LME_Ni_cash` | **terverifikasi** | korelasi return **0,70** (195 hari); kolom Cash-Settlement ≈ 3M; bukan persis seri Bloomberg | chain_return |
| IBPRCPI Index | PHEI "INDOBeX Government **Clean Price**" | **terverifikasi** (1 hari saja) | level 114,5 vs 118,6 (skala beda) tetapi perubahan YTD cocok (−5,75% vs −5,80%) → seri keluarga sama, di-chain pada return | chain_return |
| GTIDR1Y Govt | id.investing.com 1Y | **belum diverifikasi** (desimal koma diasumsikan) | belum ada sampel | chain_diff |

**Mengapa chain-link:** level antar-vendor berbeda, menyambung level mentah akan menciptakan lonjakan semu satu hari di titik sambung.
Model memakai return/selisih, sehingga level_t = level_{t-1} × src_t/src_{t-1} (atau + selisih untuk yield) mempertahankan kontinuitas level
sekaligus definisi return sumber baru. **Ini tetap mengubah sifat seri** (mis. XW1 jadi lebih noisy); pipeline menolak sumber yang
korelasi return-nya terhadap riwayat turun di bawah ambang di `config/pipeline.json` (diukur dari data Anda, bukan dari tebakan).

**PHEI hanya menampilkan satu hari.** Karena itu `capture_phei` berjalan lebih dulu di tiap run dan di workflow retry 19.30 WIB, dan
disimpan di rilis `phei-history`. Hari yang terlewat tidak bisa dipulihkan kecuali lewat baris "Previous" pada hari berikutnya.
Jika hari kerja IDX tidak punya data PHEI, run **gagal** (tidak di-carry diam-diam).

**Lisensi/ToS:** Bloomberg (sumber riwayat), Yahoo, Investing.com, dan Cloudflare-protected pages umumnya melarang scraping/redistribusi.
Anda menyatakan sudah punya izin; mohon pastikan juga untuk redistribusi data lewat repo/Release (itu sebabnya repo harus privat).

## Konvensi nilai hilang
Riwayat `raw_data.xlsx` tidak punya satu pun sel kosong: seluruh 33.551 nilai hilang berupa teks literal `NA`. Baris baru memakai
konvensi yang sama: saham yang tidak tersedia/ditangguhkan ditulis `NA` (tidak pernah diisi harga lama atau interpolasi); makro dan JCI
tidak boleh hilang (jika hilang, baris itu tidak dibuat dan run berstatus FAILED/PARTIAL).
