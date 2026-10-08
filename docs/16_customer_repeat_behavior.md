# 16 — Customer Repeat Behavior (Deskriptif)

> Pendamping `sql/16_customer_repeat_behavior.sql`. Hasil dijalankan di DuckDB lokal. Analisis **deskriptif**: tidak ada klaim CLV, churn, prediksi, maupun segmentasi RFM klasik (96,88% pelanggan hanya satu order). Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah.

## Input
- Model dimensional Tahap 8: `fact_orders`, `fact_order_items`, `dim_product`, `dim_customer`
- Populasi: Customer Population (`customer_unique_id`, 96.096); cohort 2017-01..2018-05 untuk 90-day Repeat Rate; snapshot dataset 2018-10-17

## Proses Analisis
1. Distribusi order per pelanggan, Repeat Rate (≥ 24 jam, D5), repeat mentah, dan sesi belanja yang sama (< 24 jam).
2. Pasangan order berurutan < 1 jam (seller-set sama/beda) dan jeda antar order.
3. 90-day Repeat Rate (cohort 2017-01..2018-05) dan window tetap 30/90/180 hari per cohort bulanan (hanya pelanggan dengan observasi penuh).
4. New vs returning per bulan (`repeat_monthly`).
5. Kategori dan pengalaman order pertama pada pelanggan repeat vs non-repeat (deskriptif).
6. Repeat rate per state (state pada **order pertama**).
7. Reconcile ke KPI terkunci dan angka referensi (`repeat_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**32 metrik: 27 PASS, 2 INFO, 3 CHECK** (dijelaskan di bawah). Customer Population **96.096**; jumlah per state = 96.096, jumlah cohort = 96.096, jumlah order bulanan = 99.441; `n_new` = 96.096 (satu order pertama per pelanggan). **Repeat Rate 2,208% (2.122), repeat mentah 3,119% (2.997), 90-day Repeat Rate 1,302% (1.009 dari 77.482)** tereproduksi persis.

### 1. Distribusi order per pelanggan dan Repeat Rate
| Jumlah order | Pelanggan | % |
|---|---:|---:|
| 1 | 93.099 | **96,881** |
| 2 | 2.745 | 2,857 |
| 3 | 203 | 0,211 |
| 4 | 30 | 0,031 |
| 5 | 8 | 0,008 |
| 6 | 6 | 0,006 |
| 7 | 3 | 0,003 |
| 9 | 1 | 0,001 |
| 17 | 1 | 0,001 |

- **Repeat Rate (≥ 24 jam): 2,208%** (2.122 dari 96.096), headline D5. **Repeat mentah (≥ 2 order): 3,119%** (2.997), hanya metrik Data Quality.
- **875 pelanggan (29,2% dari repeat mentah) hanya punya order dalam < 24 jam** dari order pertama: sesi belanja yang sama, dilaporkan terpisah.
- Tingkat order: dari 99.441 order, **96.096 order pertama**, **2.381 order returning** (≥ 24 jam setelah order pertama; 2,394% dari order) dan **964 order sesi-sama** (order berikutnya dalam < 24 jam).

### 2. Sesi belanja yang sama dan jeda antar order
- **Pasangan order berurutan < 1 jam: 920** (292 di detik yang sama). Rincian menurut jeda pasangan < 24 jam (999 pasangan): detik yang sama 292, < 1 menit 492, 1–59 menit 136, 1–5,9 jam 28, 6–23,9 jam 51. **Seller-set beda 570, sama 327, salah satu order tanpa item 23** (jumlah 920): sebagian besar adalah order terpisah yang dipecah per seller, bukan pembelian ulang.
- **Jeda antar order berurutan (3.345 pasangan):** median **28,33 hari** (P25 0,01; P75 119,81; P90 241,71; mean 78,23), tercemar pasangan sesi-sama. **Pasangan ≥ 24 jam (2.346):** median **68,52 hari** (P25 22,94; P75 170,45; P90 281,23; mean 111,52).
- **Waktu dari order pertama ke order kembali pertama (≥ 24 jam; 2.122 pelanggan repeat):** median **73,8 hari** (P25 23,3; P75 176,8; P90 288,6; mean 115,3; maks 609,0). Distribusi: 1–6 hari 8,39% (178), 7–29 hari 20,92% (444), 30–89 hari 25,68% (545), 90–179 hari 20,50% (435), 180–364 hari 20,26% (430), ≥ 365 hari 4,24% (90). Kumulatif: ≈ 29,3% dalam 30 hari, ≈ 55,0% dalam 90 hari, ≈ 75,5% dalam 180 hari. Karena observasi terpotong di 2018-10-17, jeda panjang pada cohort akhir tidak terlihat sehingga median ini bias ke bawah.

### 3. 90-day Repeat Rate dan window tetap per cohort
- **90-day Repeat Rate (cohort first-order 2017-01..2018-05): 77.482 pelanggan, 1.009 repeat = 1,302%.**
- **Window tetap pada cohort 2017-01..2018-08 (hanya pelanggan dengan observasi penuh):** 30 hari **0,648%** (621 dari 95.764), 90 hari **1,264%** (1.095 dari 86.598), 180 hari **1,911%** (1.311 dari 68.614).
- **Per cohort bulanan** (ukuran cohort 764 pada 2017-01 hingga 7.304 pada 2017-11; seluruh cohort `full` ≥ 764 pelanggan): rate 90 hari berkisar 0,91–1,79%: 0,916 (2017-01), 0,913, 1,328, 1,276, 1,613, 1,434, 1,284, 1,458, **1,792 (2017-09, tertinggi)**, 1,208, 1,328, 1,039 (2017-12), 1,238, 1,209, 1,134, 1,326, 1,389 (2018-05), 0,926 (2018-06), 0,976 (2018-07); 2018-08 belum teramati 90 hari. Rate 180 hari 1,57–2,52% (puncak 2017-09 2,518%; 2018-03 1,565%); rate 30 hari 0,40% (2017-12) – 0,92% (2018-07). Tidak ada tren menurun/naik yang jelas; cohort 2018-06/07 hanya sebagian pelanggannya yang teramati penuh (noisy).
- **Repeat mentah per cohort (kapan pun)** turun dari **7,59% (2017-01)** ke **0,81% (2018-08)** (tereproduksi persis) karena right-censoring, **bukan** karena perubahan perilaku; perbandingan antar cohort hanya sah pada window tetap.
- Cohort 2016-09/10/12 dan 2018-09/10 sangat kecil (1–321 pelanggan) dan hanya anotasi.

### 4. New vs returning per bulan (jumlah pelanggan aktif)
- Pelanggan returning (≥ 24 jam setelah order pertama) di bulan itu: 3 dari 765 (**0,39%**, 2017-01), 27 dari 2.372 (1,14%, 2017-04), 68 dari 3.947 (1,72%, 2017-07), 102 dari 4.212 (**2,42%**, 2017-09), 151 dari 7.430 (2,03%, 2017-11), 172 dari 7.115 (2,42%, 2018-03), 224 dari 6.814 (**3,29%**, 2018-05), 204 dari 6.128 (3,33%, 2018-06), 179 dari 6.230 (2,87%, 2018-07), 218 dari 6.460 (**3,38%**, 2018-08).
- Kenaikan porsi returning dari ≈ 0,4% ke ≈ 3% mencerminkan **basis pelanggan yang menumpuk** (lebih banyak pelanggan lama yang dapat kembali), bukan bukti loyalitas yang membaik. 2018-09/10 (14 dan 4 pelanggan aktif) hanya anotasi.

### 5. Kategori dan pengalaman order pertama (deskriptif; bukan prediktor)
Pelanggan dengan order pertama ber-item: 95.388 (2.100 repeat; 93.288 non-repeat); 708 pelanggan tanpa item pada order pertama dikeluarkan.

- **Repeat rate menurut kategori order pertama (≥ 100 pelanggan; order multi-kategori dihitung di tiap kategori):** tertinggi fashion_male_clothing **4,67%** (≈ 5 repeat dari 107), fashion_underwear_beach 4,24% (≈ 5 dari 118), fashion_bags_accessories **3,97%**, drinks 3,93%, furniture_living_room 3,47%, fashion_shoes 3,43%, fixed_telephony 3,30%, construction_tools_garden 3,21%, christmas_supplies 3,20%, home_comfort 3,13%. Terendah **computers 0%**, books_technical 0,39%, construction_tools_lights 0,85%, home_appliances_2 0,89%, agro_industry_and_commerce 1,12%, kitchen_dining_laundry_garden_furniture 1,25%, industry_commerce_and_business 1,30%, food_drink 1,38%, office_furniture 1,45%, small_appliances 1,46%. Banyak kategori ekstrem punya hitungan repeat yang sangat kecil (sekitar 5 pelanggan).
- **Komposisi order pertama (porsi di repeat vs non-repeat):** bed_bath_table 12,24% vs 9,32% (rasio 1,31), sports_leisure 9,86% vs 7,71% (1,28), furniture_decor 8,48% vs 6,39% (1,33), garden_tools 4,24% vs 3,58% (1,18), housewares 6,05% vs 5,96% (1,02), telephony 4,29% vs 4,31% (1,00); health_beauty 8,19% vs 9,00% (0,91), toys 3,62% vs 3,97% (0,91), watches_gifts 4,76% vs 5,74% (0,83), computers_accessories 5,48% vs 6,81% (0,80). Pelanggan repeat over-index pada barang rumah tangga/olahraga dan under-index pada computers_accessories dan watches_gifts.
- **Skor review order pertama:** repeat rate 1,94% (skor 1; 10.997 pelanggan), 1,91% (skor 2; 3.031), 2,00% (skor 3; 7.862), 2,02% (skor 4; 18.490), **2,37% (skor 5; 54.980)**, 2,45% (tanpa review; 736). Selisih kecil: skor 5 hanya ≈ 1,2× skor 1.
- **Order pertama telat:** terkirim telat **1,62%** (6.344 pelanggan) vs terkirim tepat waktu **2,24%** (86.904) vs belum/tidak terkirim 2,63% (2.848).
- **Status order pertama:** delivered 2,195% (93.256), shipped 2,69% (1.078), unavailable 2,72% (589), **canceled 3,37% (564; 19 repeat)**, invoiced 1,62%, processing 1,70%, created 20% (1 dari 5), approved 0% (0 dari 2).
- **Nilai order pertama (Item Revenue):** < 50 2,26% (28.360), 50–99 2,20% (27.352), 100–199 2,20% (25.030), 200–499 2,24% (11.090), **≥ 500 1,66% (3.556)**.
- Tidak satu pun atribut order pertama memisahkan pelanggan repeat secara tajam (rentang 1,6–2,4%).

### 6. Repeat rate per state (state pada order pertama; semua 27 state dengan n)
- Rate nasional 2,208%. Tertinggi: **RJ 2,456%** (304 dari 12.379), GO 2,409%, MT 2,400% (21 dari 875), **SP 2,340%** (943 dari 40.291), PB 2,312% (12 dari 519). Terendah (n ≥ 500): **MA 1,105%** (8 dari 724), **CE 1,144%** (15 dari 1.311), PA 1,370%, PE 1,494%, MS 1,585%. Lainnya: MG 2,132%, RS 2,161%, PR 2,049%, SC 2,040%, BA 2,014%, DF 1,832%, ES 2,191%.
- Sepuluh state dengan n < 500 pelanggan (PI, RN, AL, SE, TO, RO, AM, AC, AP, RR) ditandai `n_kecil`; mis. AC 3,90% (3 dari 77), RO 2,93% (7 dari 239), AP 1,49% (1 dari 67), RR 2,22% (1 dari 45) tidak dapat ditafsirkan.
- **Sensitivitas lokasi:** hanya **39 pelanggan** (0,04%) yang state order pertama ≠ order terakhir (33 di antaranya repeat); pilihan "state order pertama" praktis tidak mengubah angka.
- Keterkaitan dengan Late Rate state tidak bersih: state lambat (MA, CE, PA, PE) memang punya repeat rate rendah, tetapi RJ (Late Rate 12,1%) memiliki repeat rate tertinggi.

### Metrik CHECK (3)
| Metrik | Aktual | Roadmap | Penjelasan |
|---|---:|---:|---|
| Pasangan berurutan < 1 jam | 920 | 919 | Selisih 1 pasangan (0,1%). |
| Seller-set beda | 570 | 571 | Selisih 1 pasangan. |
| Seller-set sama | 327 | 325 | Selisih 2 pasangan. |

Dalam kedua hitungan jumlah pecahan konsisten (570 + 327 + 23 = 920; 571 + 325 + 23 = 919); detik yang sama (292) dan tanpa item (23) cocok persis. Selisih ≤ 2 pasangan kemungkinan berasal dari tie-break atau definisi pasangan pada hitungan roadmap; penyebab pastinya tidak teridentifikasi dan tidak mengubah kesimpulan.

## Hipotesis Kandidat (untuk Tahap 21, belum diuji)
- **H-U1** Repeat purchase jarang dan tidak membaik secara berarti: Repeat Rate 2,208%; 90-day Repeat Rate per cohort stabil ≈ 0,9–1,8%. Kenaikan porsi pelanggan returning bulanan (0,4% → 3,3%) mencerminkan basis pelanggan yang menumpuk. → Tahap 21
- **H-U2** Pelanggan yang kembali melakukannya lambat (median 73,8 hari; ≈ 29% dalam 30 hari, ≈ 55% dalam 90 hari, ≈ 24,5% setelah 180 hari). → Tahap 21
- **H-U3** Sebagian besar "repeat mentah" tambahan adalah sesi belanja yang sama (875 pelanggan; 920 pasangan < 1 jam, 570 di antaranya seller-set beda) dan bukan loyalitas; harus dilaporkan terpisah. → Tahap 21 (Data Quality)
- **H-U4** Pengalaman order pertama berasosiasi lemah dengan repeat: skor 5 (2,37%) vs skor 1–4 (1,9–2,0%); order pertama telat 1,62% vs tepat waktu 2,24%; order ≥ R$ 500 1,66%. → Tahap 21
- **H-U5** Order pertama pelanggan repeat over-index pada barang rumah tangga/olahraga (bed_bath_table, furniture_decor, sports_leisure, garden_tools) dan under-index pada computers_accessories dan watches_gifts; kategori fashion memiliki repeat rate tertinggi (hitungan kecil). → Tahap 21
- **H-U6** Pelanggan yang order pertamanya canceled (3,37%) atau unavailable (2,72%) lebih sering muncul sebagai repeat, kemungkinan karena memesan ulang barang yang sama, bukan loyalitas. → Tahap 21 (batasan)
- **H-U7** Perbedaan antar state kecil dan banyak state berhitungan kecil; state lambat (MA, CE, PA, PE) memiliki repeat rate rendah, tetapi hubungan ini tidak konsisten (RJ tertinggi). → Tahap 21

## Output
- Tabel: `repeat_monthly` (26 bulan), `repeat_cohort` (26 cohort), `repeat_state` (27 state), `repeat_findings` (32 metrik)
- `data/processed/16_repeat_monthly.parquet` (26), `16_repeat_cohort.parquet` (26), `16_repeat_findings.parquet` (32); ter-ignore git

## Assumptions
- Repeat Rate (headline) = pelanggan dengan order ≥ 24 jam setelah order pertama (D5); order berikutnya dalam < 24 jam = sesi belanja yang sama.
- Urutan order per pelanggan: `ts_purchase`, tie-break `order_id`.
- Window tetap 30/90/180 hari hanya untuk pelanggan dengan `first_ts + window ≤` snapshot (2018-10-17 17:30); 90-day Repeat Rate headline memakai cohort bulan 2017-01..2018-05 sesuai D5.
- Lokasi pelanggan = state pada order pertama (aturan tertulis; 39 pelanggan multi-state).
- Kategori order pertama memakai pasangan pelanggan–kategori unik; hanya pelanggan yang order pertamanya ber-item.

## Batasan data
- Tidak ada data demografi, perangkat, atau kanal akuisisi; tidak ada klaim CLV, churn, prediksi, atau RFM.
- Observasi berakhir 2018-10-17: cohort 2018 terpotong (right-censoring); jeda ke order kembali dan repeat mentah per cohort tidak sebanding antar cohort kecuali pada window tetap.
- `customer_unique_id` dapat berasal dari data yang tidak sepenuhnya merepresentasikan satu orang; 39 pelanggan punya lokasi berbeda antar order.
- Hitungan repeat per kategori dan per state kecil pada banyak segmen; tidak ada kontrol terhadap variabel perancu.
- Beberapa kolom pada tabel ringkas (jumlah order new/returning per bulan, persentase repeat mentah per cohort, jumlah pelanggan per kategori) tidak tampil pada output run dan tidak diklaim di sini.

## Kesimpulan
Repeat Rate (2,208%), repeat mentah (3,119%), dan 90-day Repeat Rate (1,302%) reconcile penuh ke nilai terkunci, dan seluruh angka roadmap tereproduksi kecuali selisih ≤ 2 pasangan pada hitungan sesi belanja. Repeat purchase jarang dan lambat (median 73,8 hari), stabil lintas cohort pada window tetap, dan hampir tidak dibedakan oleh atribut order pertama; sebagian besar kenaikan "repeat" bulanan adalah akumulasi basis pelanggan, dan sebagian repeat mentah adalah sesi belanja yang sama.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** laporkan Repeat Rate headline (≥ 24 jam) dengan window tetap dan cohort, bukan repeat mentah; pisahkan sesi belanja yang sama dari repeat; jangan membandingkan cohort 2018 pada waktu observasi berbeda; hindari klaim loyalitas atau CLV.
