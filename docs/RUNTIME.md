# FULL ±24 jam di GitHub: pemecahan per saham (sharding)

**Fakta (dokumentasi GitHub):** batas 6 jam berlaku **per job** di runner hosted (jam mulai dari nol untuk setiap job); self-hosted 5 hari;
matrix maks. 256 job per run; repo privat paket Free mendapat 2.000 menit/bulan runner hosted.

## Cara kerja FULL terpecah (`FULL_SHARDS`)
```
plan -> prepare (state + PHEI + ingest) -> joint (data prep + ARMA-GARCH makro + DCC/Copula)
     -> shards[1..N]  (tiap job hanya menaksir sebagian dari 71 saham, paralel)
     -> merge (rakit semua shard, validasi, bundel, terbitkan)
```
- Metodologi tidak diubah: fungsi, argumen, dan model sama. Tiap saham tetap memakai **aliran seed asalnya** (daftar 71 saham tetap utuh di
  setiap shard; saham milik shard lain hanya dilewati), terbukti identik pada tes `future.apply` (sequential dan multisession).
- Pembagian saham: round-robin deterministik (saham ke-i masuk shard ((i-1) mod N)+1).
- `merge` menolak: shard hilang/ganda, `shard_count` berbeda, shard yang dihitung dari `raw_data.xlsx` berbeda, atau partisi tidak sesuai.
- Tidak ada yang terbit sebelum `merge` lolos validasi; jika satu shard gagal, `merge` tidak berjalan dan produksi tidak berubah.
  Gunakan **Re-run failed jobs** di halaman run: shard yang sudah selesai tidak dihitung ulang.
- Saham yang gagal sendiri (NULL) diperlakukan seperti pipeline asli; `merge` gagal bila >10% saham sebelumnya hilang.

## Mengaktifkan
Repo → Settings → Secrets and variables → Actions → **Variables**: `FULL_SHARDS` = jumlah shard (2–100). Opsional `FULL_MAX_PARALLEL`
(default 20) untuk membatasi job paralel sesuai batas concurrency akun Anda.

## Kalibrasi (WAJIB sebelum dijadwalkan)
Waktu per saham belum pernah saya ukur. Lakukan:
1. `FULL_SHARDS=20`, jalankan manual `mode=FULL`, `dry_run=true`.
2. Buka Summary job `merge`: tabel **Shard timings** menunjukkan menit per shard dan total jam komputasi.
3. Syarat: shard terlama + ±30 menit setup **jauh di bawah 6 jam** (target <4,5 jam sebagai bantalan). Jika tidak, naikkan `FULL_SHARDS`.
4. Waktu `joint` (makro + DCC/Copula) **tidak bisa dipecah**: harus <6 jam sendiri. Lihat durasi job `joint`.

## Biaya dan batas yang tetap berlaku
- Menit dihitung per job; total ≈ (waktu joint) + (jumlah shard × waktu shard + setup) + merge. Pemecahan **tidak mengurangi total kerja**.
  Perkiraan: total jam-shard dari tabel × 60 menit per FULL × ±4 kali per bulan. Repo privat Free hanya 2.000 menit/bulan; selebihnya ditagih
  (cek halaman billing). Repo publik gratis, tetapi data turunan Bloomberg tidak sebaiknya publik.
- Artifact antar-job (`work-in`, `joint-out`, `shard-*`) berisi model dan plot; retensi 2 hari. Ukurannya belum diketahui dan masuk kuota
  penyimpanan akun: periksa setelah run pertama.
- Spesifikasi core/RAM runner hosted untuk akun Anda belum saya verifikasi (pipeline memakai semua core; memori naik per core).
- Selama satu run FULL berjalan (jam-jam), workflow lain (DAILY esok hari, rollback) menunggu antrean karena grup `pipeline-prod`.
- **DAILY tidak pernah memulai FULL sendiri** di runner hosted: jika model tidak ada/rusak atau validasi historis gagal, ia berstatus FAILED
  dengan pesan "FULL REQUIRED"; jalankan workflow manual `mode=FULL` (atau tunggu Jumat).

## Alternatif
| Pilihan | Catatan |
|---|---|
| `FULL_RUNNER_LABEL` (self-hosted) | FULL satu job, tanpa kuota menit, batas 5 hari; butuh mesin Ubuntu 24.04 + Docker + sudo tanpa password. |
| `ALLOW_FULL_ON_HOSTED=true` | Hanya jika terbukti selesai <6 jam di satu job. |
| Tanpa ketiganya | Jumat menjalankan DAILY dan Summary menulis "FULL SKIPPED". |

## Belum terbukti
Eksekusi nyata tahap `joint`/`stocks`/`merge` pada model Anda tidak bisa saya jalankan (paket `rugarch`, `rmgarch`, `copula` tidak terpasang
di sandbox). Yang teruji: kode helper shard (18 cek), kesetaraan seed, struktur pipeline (tidak ada baris asli yang dihapus; kode setelah loop tidak
memakai variabel yang hanya dibuat di dalam loop), konsistensi workflow (actionlint bersih), dan seluruh orkestrasi di sekitarnya. **Bandingkan hasil FULL
terpecah pertama dengan hasil laptop Anda untuk beberapa saham** sebelum mengandalkannya.
