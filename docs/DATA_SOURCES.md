# Sumber data per instrumen (status verifikasi per 2026-10-09)

| Kolom model | Sumber | Parser | Definisi vs riwayat tersimpan | Penyambungan |
|---|---|---|---|---|
| JCI Index + 71 saham IJ | IDX `GetIndexSummary`/`GetStockSummary` (mekanisme proyek lama) | dari kode lama, **belum dijalankan live** | JCI sama definisinya → cek anchor eksak | level_exact |
| USDIDR BGN Curncy | Yahoo `IDR=X` adj close **via Google Sheet** (`apps_script/yahoo_feed.gs` → CSV terbit; lihat `docs/SHEETS_FEED.md`) | logika skrip teruji dengan JSON tiruan; **live belum** | belum ada sampel; BGN ≠ Yahoo | chain_return |
| CO1 Comdty | Yahoo `BZ=F` adj close **via Google Sheet** (skrip yang sama) | logika skrip teruji dengan JSON tiruan; **live belum** | belum ada sampel | chain_return |
| XAU Curncy | Investing.com ID XAU/USD (pengganti Stooq yang diblokir dari GitHub) | **terverifikasi** pada halaman Anda; format `13/10/2026`, `4.156,04` | korelasi return 0,78 (19 hari), rasio level 1,001 | chain_return |
| XW1 Comdty | Investing.com Newcastle Coal Futures | **terverifikasi** | korelasi 0,996; 17/19 hari persis sama dengan Bloomberg | chain_return |
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

## Konvensi nilai hilang (teks `NA`) dan pengisian gap
Riwayat `raw_data.xlsx` tidak punya satu pun sel kosong: nilai hilang berupa teks literal `NA`. Baris baru mengikuti itu.

Pengisian gap: ingestion membuat satu baris untuk **setiap hari kerja** dari hari setelah tanggal data terakhir sampai hari kerja terakhir yang sudah final
(sumber AS/London final ±08.00 WIB esok hari). Batas satu kali jalan: `dataset.max_catchup_days` (45 hari); batas nyata tiap sumber adalah panjang riwayat
yang ditampilkannya (Investing ±22 hari bursa, MPOC ±10, Westmetall ratusan, feed Yahoo-Sheet 3 bulan, PHEI 2 hari).
Jika riwayat sumber tidak mencapai tanggal data terakhir Anda, sambungan ditolak (tidak ditebak) dan sel menjadi `NA`.

| Situasi | Yang ditulis |
|---|---|
| Saham IDX tidak dikembalikan IDX / masih suspensi (kosong) | `NA` |
| Pasar libur (sumber hidup, tidak ada harga hari itu) | nilai terakhir dibawa (konvensi riwayat Anda) |
| Instrumen wajib tidak punya nilai yang bisa dipakai (sumber mati/diblokir, seri tidak cocok, lonjakan tak wajar, feed basi) | `NA` bila `ingest.on_required_failure="na"` (bawaan); status **PARTIAL_SUCCESS**, tidak pernah SUCCESS; berhenti setelah `max_consecutive_na` (5) hari berturut-turut |
| Sama, tetapi `on_required_failure="block"` | tidak ada baris sama sekali; gap terisi otomatis setelah sumber pulih |
| JCI / IDX tidak tersedia | tidak pernah diisi `NA`: run berhenti (tanpa IDX libur tidak bisa dibedakan dari gangguan) |

Konsekuensi `NA` pada variabel model: kode R Anda membuang baris yang punya `NA` pada variabel model, jadi hari itu tidak menambah observasi. Hari `NA` tidak
diisi ulang otomatis; bila perlu, isi manual. Setelah hari `NA`, sambungan dilanjutkan dari nilai valid terakhir (satu return multi-hari, tanpa lonjakan palsu).
Pengaman: basis sambungan harus menggambarkan keadaan yang sama dengan baris terakhir; bila nilai sumber terbaru lebih tua dari tanggal data terakhir
dan level tersimpan sudah bergerak, sambungan ditolak agar pergerakan itu tidak terhitung dua kali.
