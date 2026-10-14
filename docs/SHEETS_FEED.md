# Feed Yahoo lewat Google Sheets (USDIDR + Brent)

Pipeline tidak lagi membaca situs Yahoo. Sebuah Google Sheet yang mengambil data, pipeline hanya membaca CSV terbitannya
(`SRC_YAHOO_SHEET_CSV`). Cara ini memakai infrastruktur Google, sehingga tidak berurusan dengan anti-bot di sisi GitHub.

## Setup (sekali, ±10 menit) - klik demi klik
1. Buka https://sheets.new (membuat Google Sheet kosong). Beri nama `yahoo-feed` (klik judul di kiri atas).
2. Menu **File → Settings** → *Time zone* = **(GMT+07:00) Jakarta** → **Save settings**.
3. Menu **Extensions → Apps Script**. Tab baru terbuka.
4. Di editor, hapus semua kode bawaan (`function myFunction() {}`), lalu **tempel seluruh isi `apps_script/yahoo_feed.gs`**. Klik ikon disket (Save).
5. **Coba tanpa menulis apa pun:** pada dropdown fungsi di toolbar pilih **`previewYahoo`** → **Run**.
   - Pertama kali muncul "Authorization required" → **Review permissions** → pilih akun Anda → bila ada layar "Google hasn't verified this app" klik
     **Advanced → Go to ... (unsafe)** → **Allow** (ini skrip Anda sendiri; izin yang diminta hanya mengakses sheet ini dan koneksi ke layanan luar).
   - Buka **Execution log** (di bawah editor). Harus tampil dua baris, mis. `USDIDR BGN Curncy <- IDR=X : 62 rows, ... newest value ...` dan `CO1 Comdty <- BZ=F : ...`.
   - Jika tampil `FAILED ... HTTP 429` atau lainnya: tunggu 10 menit dan ulangi. Jika terus gagal, kirim teks log itu ke saya.
6. Jika preview baik: pilih fungsi **`refreshYahooFeed`** → **Run**. Kembali ke sheet: muncul tab **`feed`** (kolom `Dates`, `USDIDR BGN Curncy`, `CO1 Comdty`) dan tab **`status`** (`last_error` kosong).
7. Pilih fungsi **`installDailyTrigger`** → **Run** (sekali). Feed akan diperbarui otomatis tiap hari sekitar pukul 13.00 WIB.
8. Kembali ke sheet: **File → Share → Publish to web**. Pada *Link* pilih tab **`feed`** (bukan "Entire document") dan format **Comma-separated values (.csv)** → **Publish** → **OK**. Salin URL
   yang muncul (bentuknya `https://docs.google.com/spreadsheets/d/e/2PACX-.../pub?gid=...&single=true&output=csv`).
   Jangan publikasikan tab `status`. Akun Google Workspace kantor/kampus kadang melarang "Publish to web"; gunakan akun Gmail pribadi bila begitu.
9. Uji URL itu di jendela incognito: harus mengunduh/menampilkan CSV yang diawali `Dates,USDIDR BGN Curncy,CO1 Comdty`.
10. GitHub → repo → *Settings → Secrets and variables → Actions → New repository secret*: Name `SRC_YAHOO_SHEET_CSV`, Value = URL tadi.

Keamanan data: bila Yahoo gagal atau hasilnya terlalu pendek (<20 baris), skrip **tidak menimpa** feed lama dan menulis error di
tab `status` (Apps Script juga mengirim email kegagalan). Pipeline lalu memakai feed lama; bila feed basi lebih dari 2 hari kerja,
pipeline berhenti dengan `FAILED_STALE`, bukan membawa nilai lama terus-menerus.

## Alternatif tanpa skrip: GOOGLEFINANCE (belum diuji)
Hanya untuk kurs. Sumbernya **Google, bukan Yahoo**, jadi seri sedikit berbeda (cek korelasi di Summary run). Ticker futures seperti `BZ=F`
setahu saya **tidak** didukung GOOGLEFINANCE; uji sendiri (jika sel menampilkan `#N/A`, pakai skrip di atas).
- Tab `raw`, sel A1: `=GOOGLEFINANCE("CURRENCY:USDIDR","price",TODAY()-90,TODAY(),"DAILY")`
- Tab `feed`: A1 `Dates`, B1 `USDIDR BGN Curncy`; A2:
  `=ARRAYFORMULA(IF(raw!A2:A="","",TEXT(INT(raw!A2:A),"yyyy-mm-dd")))` ; B2: `=ARRAYFORMULA(IF(raw!B2:B="","",raw!B2:B))`
- Publikasikan tab `feed` seperti langkah 6, dan ubah `config/pipeline.json` agar hanya kolom yang ada yang diambil.

## Masalah umum
| Gejala di Summary pipeline | Penyebab | Perbaikan |
|---|---|---|
| `got an HTML page instead of CSV` | tab salah / belum di-publish sebagai CSV / URL kedaluwarsa | ulangi langkah 6, perbarui secret |
| `non-ISO date in CSV` | kolom tanggal terkonversi jadi tanggal asli | jalankan ulang `refreshYahooFeed` (kolom A harus teks) |
| `value(s) do not match decimal='.'` | locale sheet memakai koma desimal | set `Time zone`/locale ke US atau ubah `decimal` di config menjadi `","` |
| `FAILED_STALE` | feed tidak diperbarui >2 hari kerja | cek tab `status`, jalankan `refreshYahooFeed` manual, cek trigger |
| `FAILED_DIAG` | seri tidak cocok dengan riwayat (korelasi < 0,8) | kirim angka korelasinya ke saya |
| `last_error: HTTP 429` | Yahoo membatasi IP Google | tunggu dan jalankan ulang; jika terus, pakai sumber lain |

## Jika di Summary muncul `SRC_YAHOO_SHEET_CSV is EMPTY`
Artinya GitHub tidak memberikan secret itu ke job (di log, baris `SRC_YAHOO_SHEET_CSV:` kosong). Periksa satu per satu:
1. Buka https://github.com/raihanzakiadani/dcc-garch-copula-monte-carlo-msar/settings/secrets/actions
2. Pastikan Anda berada di tab **Secrets** (bukan **Variables**), bagian **Repository secrets** (bukan *Environment secrets*).
3. Nama harus persis `SRC_YAHOO_SHEET_CSV` (huruf besar, garis bawah, tanpa spasi di akhir).
4. Nilainya URL CSV lengkap yang diawali `https://docs.google.com/spreadsheets/d/e/` dan berakhir `output=csv`.
5. Setelah menyimpan, jalankan ulang workflow. Secret tidak berlaku surut untuk run yang sudah selesai.
Uji URL-nya di jendela incognito: harus mengunduh file **.csv** (bukan .xlsx, bukan halaman web). Jika yang terunduh .xlsx atau terbuka halaman web, ulangi
**File > Share > Publish to web**, pilih tab `feed`, dan format **Comma-separated values (.csv)**.
