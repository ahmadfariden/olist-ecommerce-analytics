# 09 — Order Status & Fulfillment Analysis

> Pendamping `sql/09_order_status_fulfillment.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah.

## Input
- Model dimensional Tahap 8: `fact_orders`, `fact_payments`, `dim_date`
- Populasi: Order Population (99.441), Delivered Population (96.470), Cancelled Population (625)
- Tanggal snapshot dataset: **2018-10-17** (tanggal purchase terakhir)

## Proses Analisis
1. Status breakdown dan funnel kumulatif berdasarkan jejak timestamp tahap (approved → carrier → diterima).
2. Cancellation Rate dan Unavailable Rate sebagai **dua metrik terpisah** (denominator Total Orders), keseluruhan dan bulanan (`status_monthly`).
3. Profil order `unavailable` dan `canceled`; jejak terakhir order canceled.
4. Durasi antar tahap pada Delivered Population dengan pengecualian per tahap (timestamp kosong dan anomali urutan tanggal) beserta jumlahnya; tren bulanan.
5. Cancellation per state (27 state, tanpa tiering), per kombinasi metode pembayaran, dan per rentang nilai order (korelasional).
6. "Stuck order candidates" (in-flight yang tanggal estimasinya sudah lewat), deskriptif.
7. Reconcile ke KPI terkunci (`status_findings`) dan ekspor parquet.

## Temuan

### Reconcile (DoD)
**35 metrik: 33 PASS, 2 INFO, 0 CHECK.** Breakdown status reconcile ke Total Orders **99.441**; Cancellation Rate 0,629% dan Unavailable Rate 0,612% sama dengan nilai terkunci; jumlah bulanan = 99.441 / 625 / 609.

### 1. Status dan funnel

| Status | Order | % | Dengan item | Tanpa item | Item Revenue (R$) | Payment tercatat (R$) |
|---|---:|---:|---:|---:|---:|---:|
| delivered | 96.478 | 97,020 | 96.478 | 0 | 13.221.498,11 | 15.422.461,77 |
| shipped | 1.107 | 1,113 | 1.106 | 1 | 150.727,44 | 177.213,96 |
| canceled | 625 | 0,629 | 461 | 164 | 95.235,27 | 143.255,60 |
| unavailable | 609 | 0,612 | 6 | 603 | 2.007,69 | 126.479,51 |
| invoiced | 314 | 0,316 | 312 | 2 | 61.526,37 | 69.137,99 |
| processing | 301 | 0,303 | 301 | 0 | 60.439,22 | 69.394,11 |
| created | 5 | 0,005 | 0 | 5 | — | 688,10 |
| approved | 2 | 0,002 | 2 | 0 | 209,60 | 241,08 |

**Funnel kumulatif (jejak timestamp):** purchase 99.441 → approved **99.281 (99,84%)** → diserahkan ke carrier **97.658 (98,37% dari tahap sebelumnya)** → diterima **96.476 (98,79%)**; 97,02% order punya jejak sampai tanggal terima.

**Order tanpa jejak tahap, menurut status akhir:**
- Tanpa `ts_approved` (160): canceled 141, delivered 14 (anomali), created 5.
- Tanpa `ts_carrier` (1.783): unavailable 609, canceled 550, invoiced 314, processing 301, created 5, approved 2, delivered 2 (anomali).
- Tanpa `ts_customer` (2.965): shipped 1.107, canceled 619, unavailable 609, invoiced 314, processing 301, delivered 8 (anomali), created 5, approved 2.

### 2. Cancellation Rate dan Unavailable Rate (dua metrik, tidak digabung)
- Keseluruhan: **0,629%** (625) dan **0,612%** (609).
- Analysis Window (20 bulan `full`, 99.092 order): cancellation 0,194–1,290% (gabungan 0,585%); unavailable 0,065–2,528% (gabungan 0,608%).
- Cancellation tertinggi: 2018-08 **1,290%** (84), 2017-03 1,230% (33), 2018-02 1,085% (73); terendah 2017-12 0,194% (11).
- Unavailable tertinggi: 2017-02 **2,528%** (45); 2017 umumnya 0,37–1,29%, lalu **turun tajam sejak 2018-03 ke 0,065–0,286%** (2018-04: 5 order, 0,072%; 2018-06: 4 order, 0,065%).
- Bulan non-`full` hanya anotasi: 2018-09 (93,75%, 15 dari 16) dan 2018-10 (100%, 4 dari 4) adalah ekor data yang hanya berisi order canceled, bukan lonjakan pembatalan; 2016-09 (50%, 2 dari 4) dan 2016-10 (7,41%, 24 dari 324) sparse.

### 3. Profil unavailable dan canceled
- **Unavailable (609):** 603 tanpa item dengan payment tercatat **R$ 124.339,02**; hanya 6 punya item (**R$ 2.007,69 = 0,0149% Item Revenue Revenue Population**, payment R$ 2.140,49). Praktis tidak berpengaruh ke revenue. Karena 99% tidak punya item, order unavailable tidak bisa dihubungkan ke seller maupun kategori.
- **Canceled (625):** 461 dengan item (Item Revenue **R$ 95.235,27** dikeluarkan dari Revenue Population, ≈ 0,71% darinya; payment R$ 105.917,73) dan 164 tanpa item (payment R$ 37.337,87). Total payment tercatat pada order canceled R$ 143.255,60. Dataset tidak memuat data refund, sehingga status pengembalian dana tidak diketahui.
- **Jejak terakhir order canceled:** sebelum approval **141 (22,56%)**, disetujui tetapi belum ke carrier **409 (65,44%)**, sudah diserahkan ke carrier **69 (11,04%)**, tanggal terima tercatat 6 (0,96%; anomali yang sudah di-flag). Sebanyak 75 order (12,0%) sudah sampai carrier atau punya tanggal terima sebelum dibatalkan.

### 4. Durasi antar tahap (Delivered Population, hari)

| Tahap | n dipakai | Dikecualikan | P50 | P90 | P95 | P99 | Mean | Maks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| purchase → approved | 96.456 | 14 | 0,01 | 1,44 | 2,01 | 3,74 | 0,43 | 30,89 |
| approved → carrier (handover seller) | 95.105 | 1.365 | 1,85 | 6,02 | 8,15 | 17,15 | 2,85 | 125,76 |
| carrier → delivered (transit) | 96.446 | 24 | 7,10 | 18,90 | 24,21 | 40,99 | 9,33 | 205,19 |
| purchase → delivered (total) | 96.470 | 0 | 10,22 | 23,10 | 29,27 | 46,05 | 12,56 | 209,63 |

Rincian pengecualian: tahap 1 = 14 timestamp kosong; tahap 2 = 15 timestamp kosong + **1.350 anomali** (`carrier < approved`); tahap 3 = 1 timestamp kosong + 23 anomali (`customer < carrier`).

- **Transit adalah tahap terpanjang**: median 7,1 hari (≈ 69% dari median total), mean 9,33 hari (≈ 74% dari mean total). Handover seller median 1,85 hari tetapi berekor panjang (P99 17,15 hari).
- **Tren bulanan (Analysis Window):** median handover 1,6–2,0 hari pada 2017, naik ke **2,74 hari di 2017-11** (bulan Black Friday), 2,1–2,2 hari Des–Mar, lalu turun ke 1,2–1,5 hari pada 2018-04..08. Median transit 7,0–7,4 hari pada paruh pertama 2017, **11,02 (2018-02) dan 9,88 (2018-03)**, lalu turun ke 4,95–6,91 hari pada 2018-04..08 (P90 transit dari 20–28 hari ke 9,2–18,3 hari).
- **Anomali handover mengelompok per bulan**: 2018-04 **5,72% (389)** dan 2018-07 **9,15% (563)** dari Delivered Population bulan itu, 2018-06 2,02%, 2018-08 1,35%, bulan lain umumnya < 1%. Penurunan durasi pada 2018-04..08 terjadi bersamaan dengan periode anomali timestamp dan kedekatan ke akhir data, sehingga belum dapat dibaca sebagai perbaikan operasional (lihat Batasan).

### 5. Cancellation per state, metode pembayaran, dan nilai order
- **Per state (27 state, n selalu ditampilkan):** state besar berkisar 0,44–0,78%: SP **0,783%** (327 dari 41.746), RJ 0,669%, MG 0,550%, RS 0,457%, PR 0,436%. Angka tinggi pada state kecil bersandar pada hitungan sangat kecil: RR 2,174% (1 dari 46), RO 1,186% (3 dari 253), PI 0,808% (4 dari 495). Unavailable tertinggi SE 1,143% (4 order), RO 1,581% (4), MA 0,937% (7); AC dan AP tidak punya canceled maupun unavailable. Tidak ada pola state yang kuat.
- **Per kombinasi metode pembayaran (Payment Population, 99.440 order):**

| Kombinasi | Order | Canceled | Cancellation Rate | Unavailable Rate |
|---|---:|---:|---:|---:|
| credit_card | 74.259 | 426 | 0,574% | 0,574% |
| boleto | 19.784 | 95 | 0,480% | 0,758% |
| credit_card + voucher | 2.245 | 18 | 0,802% | 0,757% |
| **voucher saja** | **1.621** | **76** | **4,688%** | 0,617% |
| debit_card | 1.527 | 7 | 0,458% | 0,393% |
| not_defined | 3 | 3 | 100% | 0% |
| credit_card + debit_card | 1 | 0 | 0% | 0% |

  Order **voucher saja** hanya 1,63% dari order tetapi **12,2% dari seluruh pembatalan** (76 dari 625), dengan Cancellation Rate ≈ 7,5× rata-rata keseluruhan. Ketiga order `not_defined` semuanya canceled.
- **Per nilai order (order ber-item, canceled sebagai pembilang):** Cancellation Rate 0,446% (< R$ 50), 0,427% (50–99), **0,387% (100–199)**, 0,628% (200–499), **1,016% (≥ R$ 500; 37 dari 3.641)**. Order bernilai besar lebih sering dibatalkan.

### 6. Stuck order candidates (deskriptif)
Terhadap tanggal snapshot 2018-10-17, **seluruh order in-flight sudah melewati tanggal estimasi**: shipped 1.107 (100%), invoiced 314, processing 301, created 5, approved 2. Kandidat shipped/invoiced/processing = **1.722**. Median hari melewati estimasi: shipped 254, invoiced 316, processing 366. Sebaran: 1–30 hari hanya 1 order; 31–90 hari 164 (9,52%); 91–180 hari 253 (14,69%); **> 180 hari 1.304 (75,73%)**. Item Revenue in-flight: R$ 272.902,63 (= 2,02%, sama dengan sensitivity D2).

Pada tingkat bulan, 98–100% order in-flight di setiap bulan Analysis Window sudah melewati estimasi, termasuk bulan yang baru (2018-08: 70 order in-flight, semuanya lewat estimasi). Porsi in-flight turun dari 4,625% (2017-01) menjadi 0,75–1,2% pada pertengahan 2018, tetapi tidak berubah sifatnya.

## Hipotesis Kandidat (untuk Tahap 11–17, belum diuji)
- **H-F1** Pembatalan terjadi dini: 88% order canceled berhenti sebelum diserahkan ke carrier; sisanya 12% sudah di tangan carrier atau punya tanggal terima. → Tahap 10 (lanjutan), 13
- **H-F2** Unavailable hampir seluruhnya merupakan peristiwa pra-item (99%), dan tingkatnya turun tajam sejak 2018-03; karena tidak punya item, penyebabnya tidak dapat ditelusuri ke seller/kategori. → Tahap 15 (sebagai batasan)
- **H-F3** Order dengan pembayaran voucher saja berasosiasi dengan pembatalan jauh lebih tinggi (4,69%). → Tahap 13
- **H-F4** Order bernilai ≥ R$ 500 lebih sering dibatalkan (1,02% vs 0,39–0,45% pada nilai < R$ 200). → Tahap 9/13
- **H-F5** Transit mendominasi total durasi; handover seller berekor panjang, terutama pada periode ramai (2017-11). → Tahap 11
- **H-F6** Status in-flight pada dataset ini lebih mirip status basi yang tidak pernah diperbarui daripada order yang masih berjalan. → Tahap 21 (batasan)

## Output
- Tabel: `status_monthly` (26 bulan), `status_findings` (35 metrik)
- `data/processed/09_status_monthly.parquet` (26 baris), `09_status_findings.parquet` (35 baris); ter-ignore git

## Assumptions
- Cancellation Rate dan Unavailable Rate dilaporkan terpisah; denominator Total Orders (bulanan: Total Orders bulan purchase).
- Funnel memakai jejak timestamp, bukan status akhir (status adalah snapshot, bukan tahapan kumulatif).
- Durasi tahap mengecualikan per tahap: timestamp kosong dan anomali urutan; jumlah dilaporkan. Tahap total tidak mengecualikan apa pun.
- Stuck candidate = status shipped/invoiced/processing dengan tanggal estimasi < 2018-10-17 (snapshot = tanggal purchase terakhir).
- Metode pembayaran per order = kombinasi tipe (diurutkan); order tanpa payment (1 order) tidak ikut tabel metode pembayaran.
- Pembatalan per rentang nilai order memakai order ber-item sebagai denominator, sehingga unavailable tanpa item tidak ikut.

## Batasan data
- Dataset tidak memuat alasan pembatalan maupun data refund; status pengembalian dana pada payment yang tercatat tidak diketahui.
- Order unavailable (99% tanpa item) tidak bisa dihubungkan ke seller atau kategori.
- Konsep "stuck" tidak membedakan: semua in-flight sudah lewat estimasi pada tanggal snapshot, sehingga metrik ini tidak dapat memisahkan order yang benar-benar macet dari status yang tidak pernah diperbarui.
- Tren durasi 2018-04..08 berimpit dengan kluster anomali timestamp (2018-04, 2018-07) dan kedekatan ke akhir data (2018-10-17); pengecualian anomali memangkas sebagian distribusi handover. Tren ini harus diuji sensitivitasnya di Tahap 11 sebelum diinterpretasikan.
- Pola state dengan hitungan sangat kecil (RR, AC, AP, RO, SE, MA) tidak dapat ditafsirkan.
- Pola metode pembayaran, nilai order, dan state adalah asosiasi; tidak ada kontrol terhadap variabel perancu.

## Kesimpulan
Status breakdown reconcile penuh ke Order Population dan KPI terkunci. Pembatalan jarang (0,629%) dan dini (88% sebelum diserahkan ke carrier), dengan dua kantong yang berasosiasi lebih tinggi: pembayaran voucher saja (4,69%) dan order bernilai ≥ R$ 500 (1,02%). Unavailable (0,612%) hampir seluruhnya pra-item dan turun tajam sejak 2018-03. Transit adalah tahap terpanjang pada fulfillment (median 7,1 dari 10,22 hari), sementara tren durasi 2018-04..08 perlu diuji ulang karena bertepatan dengan kluster anomali timestamp. Seluruh order in-flight tampak sebagai status basi pada tanggal snapshot.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** pemantauan pembatalan dini pada order voucher-only dan bernilai besar; keterbatasan atribusi unavailable ke seller; penanganan status in-flight yang basi di laporan.
