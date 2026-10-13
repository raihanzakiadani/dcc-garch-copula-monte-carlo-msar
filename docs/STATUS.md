# STATUS - apa yang sudah terbukti, apa yang belum

## 1. Audit (bukti di docs/*.diff dan temuan di bawah)
- ZIP lama: hanya IDX/Google Finance/KSEI; jalur IDX butuh `curl_cffi` + FlareSolverr (Docker) dan `runs-on: self-hosted`. Tidak ada obligasi/makro.
- `raw_data.xlsx`: 81 kolom (ticker Bloomberg), seluruh hari kerja ada sejak 2023 (0 hilang), libur bursa = nilai carry-forward. Ada blok duplikat
  18 Agu-17 Sep 2026 (23 baris) → dibersihkan, baris terakhir dipertahankan (17 Sep: JCI 6.462,431).
- Pipeline: `aggregate_to_5day_blocks` tidak pernah dipanggil (model harian); `mc_run_interactive()` tanpa guard (berisiko menggantung di CI) → di-guard.
- Hybrid: menyimpan RDS walau sebagian saham gagal (set campuran) dan menulis ulang saat tidak ada data baru → diperbaiki (strict-atomic, skip-save).
  `JointDistribution_Model.rds` tidak diperbarui oleh DAILY (desain asli) → manifest mencatat `joint_distribution_last_full_run`.
- `detect_transformation_type` mencocokkan teks "IBPA"; kolom bernama `IBPRCPI Index` sehingga diperlakukan log-return, bukan selisih. **Tidak diubah.**
- File yang dirujuk tapi tidak ada di unggahan: `All_Markov_Models.rds`, `JointDistribution_Model.rds`, `Output_*.xlsx`, `Plots/`. Referensi `01092026.R` → `15092026.R`.

## 2. Teruji LOKAL (benar-benar dijalankan)
- 35 tes pytest: parser pada 4 halaman asli Anda; ingestion (chain-link, carry-forward libur, idempotensi, timing finalisasi, sumber mati → FAILED & file
  identik, anchor/definisi salah, feed basi, PHEI hari hilang, revisi, saham absen tetap kosong); orkestrator; bundle; publish; fetch; rollback;
  kegagalan publikasi (pointer tetap); bundel korup → pulih ke versi sebelumnya; retrieval Shiny mengikuti pointer, menolak bundel korup, bertahan saat server mati; planner mode WIB.
- 20 cek R pada kode hybrid asli dengan model sintetis berparameter tetap: DAILY dengan data baru, UP_TO_DATE, revisi historis, RDS hilang/rusak, FULL benar-benar meluncurkan `15092026.R`.
- `ci_run.sh` end-to-end dengan sumber tak terjangkau: exit 1, tidak ada yang terbit.

- Data asli Anda: 81 kolom terpetakan 100% (9 makro/JCI + 71 saham `<KODE> IJ EQUITY`, tanpa duplikat/spasi aneh); hasil ingestion dibaca `readxl` identik dengan file asli (nama/urutan kolom, seluruh riwayat), dan return baris baru dihitung fungsi pipeline asli (finite, wajar). Saham kosong (WSKT) tidak dihidupkan kembali dari harga basi.

## 3. SIMULASI / BELUM TERUJI (jujur)
- **FULL sampai selesai**: `rugarch`, `rmgarch`, `copula`, `moments`, `doRNG`, `shiny` tidak bisa dipasang di sandbox (tanpa akses CRAN). Hanya terbukti FULL meluncurkan pipeline dan gagal bersih. **Durasi FULL menurut Anda ±24 jam, melebihi batas 6 jam per job GitHub-hosted**: FULL dipecah per saham (`FULL_SHARDS`) atau jalan di runner self-hosted; eksekusi nyata tahap joint/stocks/merge pada model Anda belum teruji dan jumlah shard harus dikalibrasi (`docs/RUNTIME.md`).
- **Pengambilan langsung dari IDX, Investing, MPOC, PHEI, dan Yahoo-via-Sheets (apakah Yahoo mengizinkan Apps Script Google: belum diketahui, bisa HTTP 429)**: tidak ada akses jaringan; parser Yahoo/Investing/MPOC tidak punya sampel halaman. Parser MPOC kini terverifikasi pada halaman yang Anda kirim (live belum); tanggal KO1 tersimpan tidak konsisten ≤1 hari terhadap MPOC.
- Apakah IP GitHub-hosted + FlareSolverr service lolos Cloudflare: **tidak diketahui** sampai run nyata. Jika diblokir → runner self-hosted (seperti proyek lama) atau `PROXY_URL`.
- GitHub Actions asli, rilis GitHub asli (saya memakai tiruan lokal `tests/fake_gh.py`), download aset repo privat via API, deploy Shiny: **belum**. `r_snapshot.txt` (2026-09-15) belum diverifikasi ada di PPM; `renv.lock` belum dibuat (jalankan `scripts/make_renv_lock.R` setelah instal pertama sukses).
- Validasi rekonstruksi terhadap model asli Anda belum bisa diuji (RDS tidak ada).

## 4. Mengapa GitHub Releases
Ukuran RDS belum diketahui; commit harian file biner membengkakkan git dan memicu risiko loop. Releases: aset sampai 2 GiB, versi immutable,
pointer kecil yang dipindah terakhir (promosi atomik), URL stabil, privat bersama repo, gratis. Pages ditolak (publik). Object storage berbayar
tidak diperlukan. Batas: aplikasi harus membawa token baca-saja (server-side) bila repo privat.

## 5. Tindakan yang masih perlu dari Anda
1. Buat Google Sheet feed Yahoo (`docs/SHEETS_FEED.md`) dan isi secret `SRC_YAHOO_SHEET_CSV`. Kirim hasil "simpan halaman" Investing 1Y untuk memverifikasi parsernya (MPOC sudah dipasang).
2. Putuskan penerimaan kualitas sumber: LQ.F (korelasi 0,57) dan Westmetall Ni (0,70) lebih noisy daripada Bloomberg; ambang di `config/pipeline.json`.
3. Jalankan run pertama (`FULL`, dry_run) dan kirim log bila gagal.
4. Setting repo/variabel/PAT/Shiny sesuai README.
