# 10 — Delivery & Logistics Performance

> Pendamping `sql/10_delivery_logistics.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah.

## Input
- Model dimensional Tahap 8: `fact_orders`, `fact_order_items`, `dim_seller`, `dim_product`, `dim_geo_zip`, `dim_date`
- Populasi: Delivered Population (96.470), Single-Seller Population (96.922; subset terkirim = 95.195 order), Item Population dari order terkirim
- Snapshot dataset 2018-10-17; horizon observasi minimum 47 hari (2018-08-31 → snapshot)

## Proses Analisis
1. Distribusi `delivery_days` keseluruhan dan per state (27 state, n selalu ditampilkan).
2. Late Rate / On-Time Rate (definisi terkunci) per state, per bulan, per kategori (≥100 order); selisih terhadap estimasi dan lead time estimasi.
3. Tren bulanan (`delivery_monthly`) dengan **empat uji sensitivitas** atas penurunan durasi 2018-04..08: right-censoring, bauran state, anomali timestamp, lead time estimasi.
4. Intra-state vs antar-state dan 15 aliran seller→customer terbesar.
5. Jarak haversine seller–customer (`dim_geo_zip`): cakupan, distribusi, freight per desil, delivery per band jarak, korelasi.
6. Freight vs berat dan vs harga (desil); waktu proses seller vs kurir pada order late.
7. Reconcile ke KPI terkunci dan angka addendum roadmap (`delivery_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**44 metrik: 28 PASS, 5 INFO, 11 CHECK** (seluruh CHECK dijelaskan di bawah). Late Rate **6,773%**, On-Time Rate **93,227%**, Late Rate versi timestamp 8,112% (sensitivity), 96.470 Delivered Orders, 6.534 late orders; jumlah bulanan dan jumlah per state = 96.470.

**Cakupan koordinat (DoD):** item Delivered Population 110.189, ber-jarak **109.652 (99,51%)**; 537 item di-exclude (zip placeholder atau tanpa titik valid). Pembanding addendum (status `delivered`): 110.197 item, 109.660 ber-jarak (99,51%), cocok persis.

### 1. Distribusi `delivery_days` (hari)
Keseluruhan: P50 **10,22**, P75 15,72, P90 23,10, P95 29,27, P99 46,05, mean 12,56, maks 209,63.

Per state (P50 / Late Rate; n terkirim):
- Terdekat dengan seller: **SP 7,21 / 4,49%** (40.494), PR 10,43 / 4,04%, MG 10,31 / 4,57%, DF 11,36 / 5,67%.
- **RJ 12,04 / 12,11%** (12.350; P95 38,3, P99 57,3), RS 13,18 / 6,08%, SC 13,01 / 8,21%, ES 13,64 / 10,73%.
- Jauh/lambat: **BA 16,91 / 12,16%**, **CE 18,21 / 13,76%**, **MA 19,19 / 17,43%**, PA 21,08 / 11,21%, **AL 22,33 / 21,41%** (397; tertinggi), PI 16,29 / 13,87%, SE 18,01 / 15,22%.
- Median panjang tetapi Late Rate rendah: AM 25,88 / 2,76% (145), AP 24,35 / 2,99% (67), RO 17,58 / 2,88% (243), AC 18,36 / 3,75% (80). RR (41 order) memiliki P99 132,9 hari; hitungannya terlalu kecil untuk ditafsirkan.
- RJ ≈ 12,8% dari Delivered Population tetapi ≈ 23% dari order telat (≈ 1.495); SP + RJ ≈ 51% order telat.

### 2. Late Rate, estimasi, dan kategori
- **Estimasi konservatif (A20 tereproduksi, berbasis tanggal):** order on-time/early (89.936) tiba rata-rata **13,51 hari lebih cepat** dari estimasi (median 13; P90 22); order late (6.534) tiba rata-rata **10,62 hari lebih lambat** (median 7; P90 22). Selisih dengan angka EDA (12,81) adalah beda timestamp vs tanggal, bukan masalah data.
- Lead time estimasi median **24 hari** (mean 24,37) vs durasi aktual median 10,22 (mean 12,56): estimasi ≈ 2,3× durasi median aktual.
- **Per kategori (≥100 order, n pasangan order-kategori; satu order multi-kategori dihitung di tiap kategori):** tertinggi audio 11,78% (348), home_comfort 9,44% (392), fashion_underwear_beach 9,40%, books_technical 8,20%, **office_furniture 8,05% (1.254; median 18,86 hari)**, **baby 8,05% (2.809)**, electronics 7,63% (2.517); terendah construction_tools_safety 2,52%, food_drink 3,62%, agro_industry_and_commerce 3,96%, market_place 4,02%. Selisih antar kategori moderat dan tercampur bauran state/seller.

### 3. Tren bulanan dan uji sensitivitas 2018-04..08
Median `delivery_days` per bulan: 9,8–12,8 hari sepanjang 2017; 2017-11 **12,70**, 2017-12 13,14, 2018-01 11,83, **2018-02 14,26**, **2018-03 13,37**, lalu **2018-04 9,31, 2018-05 9,15, 2018-06 7,96, 2018-07 7,50, 2018-08 7,01**.

Late Rate bulanan: 2,8–6,6% pada 2017 (kecuali 2017-11 **12,40%** dan 2017-12 7,46%), 2018-01 5,70%, **2018-02 14,13%**, **2018-03 18,96%** (tertinggi), 2018-04 4,50%, 2018-05 6,56%, **2018-06 1,17%** (terendah), 2018-07 3,38%, 2018-08 6,19%. Dua bulan 2018-02..03 hanya 14% dari Delivered Population tetapi ≈ **34,5% dari seluruh order telat**.

| Uji | Hasil | Kesimpulan |
|---|---|---|
| **Right-censoring** (share terkirim ≤ N hari terhadap *seluruh* Revenue Orders; median untuk order terkirim ≤ 47 hari) | 2018-02..03 → 2018-06..08: share ≤ 10 hari **30,9% → 70,0%**, ≤ 20 hari 69,7% → 94,9%, ≤ 30 hari 87,0% → 98,0%; median ≤ horizon 13,67 → 7,48 (hampir identik dengan median biasa 13,82 → 7,49); porsi Revenue Orders yang terkirim 98–99% di semua bulan | Bukan artefak right-censoring |
| **Bauran state** (Single-Seller, median intra vs antar) | Intra-state 7,21 (2018-03) → 5,14 (2018-08); antar-state 17,69 → 8,36. Porsi intra naik 36,9% → 44,9% | Penurunan terjadi di **kedua** kelompok (antar-state lebih besar); bauran hanya kontributor kecil |
| **Anomali timestamp** (durasi total tidak memakai `ts_carrier`/`ts_approved`) | Median total order beranomali lebih pendek ≈ 0,3–1,4 hari dari yang tidak (mis. 2018-07: 6,49 vs 7,75), tetapi order **tanpa** anomali pun turun: 14,27 (2018-02) → 9,36 (04) → 7,02 (08) | Anomali bukan penyebab utama |
| **Lead time estimasi** (rata-rata bulanan) | 23,5 hari (2018-02..03) → 23,0 → **20,7** (2018-06..08) | Estimasi memendek ≈ 2,8 hari; estimasi lebih pendek seharusnya menaikkan Late Rate, tetapi Late Rate rata-rata justru turun 16,5% → 5,5% → 3,6% |

**Kesimpulan uji:** penurunan durasi 2018-04..08 **tahan terhadap keempat uji** dan dapat dipercaya sebagai pola dalam data. Penyebabnya (perbaikan operasional, perubahan pencatatan, atau perubahan kebijakan estimasi) **tidak dapat dibuktikan dari dataset**. Catatan: Late Rate 2018-08 naik kembali ke 6,19% walaupun median 7,01 hari terendah; Late Rate intra-state Agustus 10,28% (vs antar-state 3,06%), kebalikan pola biasa, dan tidak dapat dijelaskan dari data yang ada.

### 4. Intra-state vs antar-state (Single-Seller Population, terkirim)

| | Intra-state | Antar-state |
|---|---:|---:|
| Order (pct) | 34.234 (35,96%) | 60.961 (64,04%) |
| `delivery_days` P50 / mean / P95 | 6,59 / 7,97 / 18,33 | 12,84 / 15,21 / 33,27 |
| Ongkir rata-rata per order (R$) | 15,19 | 26,55 |
| Item Revenue per order (R$) | 118,23 | 146,06 |
| Late Rate | 4,557% | 8,138% |

**Aliran terbesar:** SP→SP 30.313 (P50 6,59 hari; late 4,70%), **SP→RJ 8.048 (12,88 hari; late 14,25%)**, SP→MG 7.326 (10,81; 5,34%), SP→RS 3.540 (13,94; 6,72%), SP→PR 3.077 (11,12; 4,49%), SP→SC 2.306 (13,88; 9,63%), **SP→BA 2.278 (17,72; 13,04%)**, SP→ES 1.444 (13,65; 12,47%), SP→GO, SP→DF. Aliran balik ke SP lebih baik: PR→SP late 3,13%, MG→SP 3,63%, SC→SP 3,73%; RJ→SP 7,93%. Lane SP→RJ berketerlambatan lebih tinggi daripada SP→MG meski volume serupa.

Pada Feb–Mar 2018 keterlambatan terkonsentrasi di antar-state (late 17,6% dan 25,4%) vs intra-state (7,2% dan 8,5%).

### 5. Jarak seller–customer (km)
- Distribusi (item status `delivered`, ber-jarak 109.660): median **431,8**, P95 **2.085,4**, maks 3.399,3; jarak > 4.500 km: 0 (sanity lolos).
- **Freight sub-linear terhadap jarak (desil jarak):** 16,8 km → R$ 11,27; 72,1 → 12,58; 189,5 → 16,54; 316,2 → 18,27; 383,8 → 19,62; 480,2 → 19,68; 598,2 → 20,62; 786,2 → 21,66; 1.074,5 → 24,49; **2.041,9 km → R$ 34,68**. Jarak naik ≈ 121× sedangkan ongkir naik ≈ 3,1×.
- **Per band jarak (Single-Seller, terkirim):**

| Band | Order | Delivery P50 | P95 | Late Rate | Ongkir rata-rata/order (R$) |
|---|---:|---:|---:|---:|---:|
| < 100 km | 17.696 | 5,10 | 16,01 | 4,498% | 13,26 |
| 100–299 | 13.160 | 8,23 | 22,38 | 5,251% | 18,43 |
| 300–599 | 31.038 | 10,37 | 28,17 | 6,843% | 22,05 |
| 600–999 | 17.649 | 12,62 | 31,04 | 7,185% | 24,45 |
| 1.000–1.999 | 9.613 | 15,41 | 36,15 | 9,612% | 32,70 |
| ≥ 2.000 | 5.568 | 18,29 | 42,72 | 12,087% | 39,52 |

  Naik monoton: median hari ≈ 3,6×, Late Rate ≈ 2,7×, ongkir ≈ 3,0× dari band terdekat ke terjauh.
- **Korelasi Pearson (item Delivered Population):** berat–freight **0,610**, harga–freight 0,413, jarak–freight 0,393, jarak–`delivery_days` 0,394. Berat adalah korelat ongkir terkuat; seluruhnya moderat.

### 6. Freight vs berat dan harga; seller vs kurir
- **Berat (desil):** 121 g → R$ 14,73; 201 → 14,64; 287 → 15,20; 405 → 16,13; 574 → 16,53; 838 → 17,53; 1.245 → 18,21; 1.841 → 19,85; 3.902 → 24,39; **11.485 g → R$ 42,30**. Berat naik ≈ 95×, ongkir ≈ 2,9×; ada lantai ongkir sekitar R$ 14–15 untuk barang ringan.
- **Harga (desil):** harga R$ 16,52 → R$ 488,11 (≈ 29,5×); ongkir R$ 13,75 → R$ 35,53 (≈ 2,6×); freight sebagai % harga **83,2% → 7,3%**.
- **Seller vs kurir pada order late (Delivered Population; baris beranomali dikecualikan per tahap):**

| | Handover (purchase→carrier) mean / P50 | Transit (carrier→customer) mean / P50 |
|---|---:|---:|
| ALL | 3,23 / 2,21 | 9,33 / 7,10 |
| on-time | 3,03 / 2,15 | 7,99 / 6,95 |
| late | 6,06 / 3,50 | 27,89 / 26,20 |

  Pada order late, handover naik ≈ 1,9× dibanding ALL dan transit ≈ 3,5× dibanding on-time. Tambahan durasi order late relatif terhadap on-time: transit +19,9 hari, handover +3,0 hari, sehingga ≈ **87%** dari tambahan itu ada pada tahap transit. Deskriptif, bukan klaim kausal.

### Metrik CHECK (11) dan penjelasannya
| Kelompok | Aktual vs roadmap | Penjelasan |
|---|---|---|
| A23 jarak/ongkir per desil (4 metrik) | desil-1: 16,8 km / R$ 11,27 vs 21,5 / 12,98; desil-10: 2.041,9 km / R$ 34,68 vs 2.315,8 / 39,51 | Cara pembentukan desil pada addendum tidak tertulis; `NTILE(10)` pada item ber-jarak memberi batas berbeda. Kesimpulan tidak berubah: ongkir ≈ 3× saat jarak > 100×. |
| A22 berat/ongkir per desil (4 metrik) | desil-1: 121 g / R$ 14,73 vs 252 / 15,20; desil-10: 11.485 g / R$ 42,30 vs 15.568 / 54,53 | Sama (beda binning). Korelasi Pearson **0,610 cocok persis**, jadi populasi sama. Kesimpulan sub-linear tetap. |
| A21 waktu proses (3 metrik) | handover late 6,06 vs 6,03; transit late 27,89 vs 27,87; transit on-time 7,99 vs 7,93 | Selisih ≤ 0,06 hari (≈ 1,4 jam). Script ini mengecualikan baris anomali urutan tanggal per tahap (166 handover, 24 transit), roadmap kemungkinan tidak; mengecualikan durasi negatif menaikkan rata-rata. Rasio (≈ 1,9× dan ≈ 3,5×) sama. |

## Hipotesis Kandidat (untuk Tahap 12–17 dan 21, belum diuji)
- **H-L1** Estimasi Olist dipadatkan (91,9% lebih cepat, estimasi ≈ 2,3× durasi median), tetapi tidak merata: state Utara berestimasi panjang ber-Late Rate < 4%, sedangkan RJ, MA, AL, CE, BA ber-Late Rate 12–21%. → Tahap 16
- **H-L2** Keterlambatan lebih berasosiasi dengan tahap transit (≈ 87% tambahan durasi) daripada handover seller. → Tahap 15/21
- **H-L3** Jarak berasosiasi monoton dengan durasi, Late Rate, dan ongkir, tetapi ongkir sub-linear (tarif berjenjang dengan lantai). → Tahap 9/16
- **H-L4** Ongkir lebih berasosiasi dengan berat (r = 0,61) daripada harga (0,41) atau jarak (0,39). → Tahap 14
- **H-L5** Keterlambatan sangat terkonsentrasi di Feb–Mar 2018 (≈ 34,5% order telat), pada alur antar-state, dan di Black Friday 2017-11 (12,40%). → Tahap 21
- **H-L6** Lane SP→RJ (8.048 order, late 14,25%) dan RJ secara umum menjadi titik lemah relatif terhadap volume dan jaraknya. → Tahap 16
- **H-L7** Penurunan durasi 2018-04..08 nyata dalam data, namun penyebabnya tidak teridentifikasi; Late Rate kembali naik di Agustus. → Tahap 21 (batasan)

## Output
- Tabel: `delivery_monthly` (26 bulan), `delivery_findings` (44 metrik)
- `data/processed/10_delivery_monthly.parquet` (26 baris), `10_delivery_findings.parquet` (44 baris); ter-ignore git

## Assumptions
- Late Rate = `is_late` (perbandingan tanggal, D1) / Delivered Orders; On-Time Rate = 1 − Late Rate. Versi timestamp hanya sensitivity.
- Selisih terhadap estimasi dihitung berbasis tanggal, konsisten dengan D1.
- Durasi tahap mengecualikan baris berflag anomali urutan tanggal hanya untuk tahap terkait; durasi total tidak memakai `ts_carrier`/`ts_approved`.
- Jarak = haversine antar-centroid zip prefix seller dan customer (rata-rata titik valid per zip); baris tanpa koordinat valid di-exclude.
- Kategori pada Late Rate memakai pasangan order-kategori unik; order multi-kategori masuk ke tiap kategori.
- Tren right-censoring diuji dengan share terkirim terhadap seluruh Revenue Orders (order belum terkirim dihitung belum tiba) dan dengan median pada horizon tetap 47 hari.

## Batasan data
- Dataset tidak memuat penyebab operasional keterlambatan (kurir, cuaca, mogok, kebijakan estimasi); hubungan hanya deskriptif.
- Jarak adalah jarak antar-centroid zip, bukan alamat; 537 item (0,49%) tanpa jarak.
- Rata-rata koordinat per zip dan zip placeholder (162) menurunkan presisi jarak, terutama untuk jarak pendek.
- Desil pada addendum (A22, A23) tidak identik dengan binning di sini; hanya arah dan rasio yang dibandingkan.
- Late Rate per kategori dan per state tercampur bauran seller, jarak, dan musim; tidak ada kontrol variabel perancu.
- State dengan n kecil (RR 41, AP 67, AC 80, AM 145) tidak dapat ditafsirkan stabil.

## Kesimpulan
Late Rate 6,773% dan On-Time Rate 93,227% reconcile ke KPI terkunci, dan cakupan jarak 99,51% terdokumentasi. Estimasi Olist konservatif (rata-rata 13,5 hari lebih cepat pada order on-time), keterlambatan didominasi sisi transit kurir, dan keterlambatan terkonsentrasi di Feb–Mar 2018, Black Friday, serta lane menuju RJ/BA/ES. Jarak berasosiasi monoton dengan durasi, Late Rate, dan ongkir, dengan ongkir sub-linear dan berat sebagai korelat terkuat. Penurunan durasi 2018-04..08 lolos keempat uji sensitivitas, tetapi penyebabnya tidak dapat dibuktikan.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** investigasi lane SP→RJ dan kapasitas transit pada periode puncak; kalibrasi estimasi per state; kebijakan ongkir untuk barang ringan/murah.
