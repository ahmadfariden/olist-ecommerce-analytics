# 06 — Exploratory Data Analysis (EDA)

> Pendamping `sql/06_eda.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**.
> EDA tidak mengubah definisi KPI maupun populasi (terkunci di Tahap 6).

## Input
- `orders_clean`, `order_items_clean`, `order_payments_clean`, `order_reviews_clean`, `products_clean`, `sellers_clean`, `dim_customer`, `dim_geo_zip` (Tahap 5)
- Definisi dan populasi terkunci dari `docs/methodology.md`; `prof_monthly` (Tahap 4)

## Proses Analisis
10 kelompok exploration: Revenue, Order, Status & Fulfillment, Delivery, Review, Payment, Category & Seller, Regional, Time, Outlier & Anomaly. Populasi disebut di tiap blok SQL. Tabel anak di-pre-aggregate ke grain `order_id` sebelum join. Ringkasan 51 metrik kunci disimpan di `eda_metrics` → `data/processed/06_eda_summary.parquet`.

**Konsistensi dengan KPI terkunci:** EDA mereproduksi AOV R$ 137,42, Late Rate 6,773%, 90,06% order satu item, 98.199 Revenue Orders, dan 1.278 / 3.236 order multi-seller / multi-produk. Tidak ada perubahan definisi atau populasi.

## Temuan dan Hipotesis Kandidat

Hipotesis (H) adalah **kandidat** untuk Tahap 9–17, belum diuji.

### 1. Revenue (Revenue Population)

**Temuan**
- Distribusi harga miring ke kanan: median R$ 74,9, mean R$ 120,4, P99 R$ 889, maks R$ 6.735. Per order: median R$ 86,9, mean (AOV) R$ 137,42, P99 R$ 995, maks R$ 13.440.
- Item ≥ R$ 500 hanya 2,86% item tetapi **21,9%** Item Revenue; item < R$ 50 adalah 34,7% item tetapi 9,0% revenue.
- Beban ongkir regresif: freight = **77,4%** dari harga pada item < R$ 25, turun ke 5,2% pada item ≥ R$ 500. Median freight/item per order 0,224; 3,2% order (3.147) punya ongkir lebih besar dari nilai barang.
- Tren bulanan: R$ 120 ribu (2017-01) → R$ 1,00 juta (2017-11) → plateau R$ 0,85–0,99 juta per bulan sepanjang 2018. Kuartal: 2017-Q4 +43% vs Q3, 2018-Q1 +14,9%, 2018-Q2 +3,1%. Jan–Agu 2018 ≈ 2,4× Jan–Agu 2017 (R$ 7,34 juta vs 3,08 juta).

**Hipotesis**
- **H-R1** Revenue peka terhadap segelintir item mahal; laporan wajib menampilkan median di samping mean/AOV. → Tahap 9
- **H-R2** Ongkir yang tinggi relatif terhadap harga terkait dengan barang murah; perlu dilihat bersama state tujuan. → Tahap 9, 14

### 2. Order

**Temuan**
- Lonjakan 2017-11: 7.544 order (+62,9% MoM), sementara AOV turun (R$ 145,19 → 135,27). Desember turun 24,8%.
- Order 2018 mendatar di 6,1–7,3 ribu per bulan; MoM Maret–Agustus antara −10% dan +7%.
- 90,06% order hanya 1 item; 6+ item hanya 0,26%. Multi-seller 1,30% (1.278) dan multi-produk 3,28% (3.236) dari order ber-item.

**Hipotesis**
- **H-O1** Lonjakan 2017-11 dan penurunan AOV bulan itu konsisten dengan volume yang didorong promo; cek konsentrasi kategori/state. → Tahap 9
- **H-O2** Pertumbuhan order melambat/mendatar di 2018 setelah lonjakan 2017. → Tahap 9

### 3. Status & Fulfillment (Order Population)

**Temuan**
- `unavailable` 99,01% tanpa item (603 dari 609); `canceled` 26,24% tanpa item (164 dari 625); `created` 100% tanpa item. Order `delivered` dan `processing` semuanya punya item.
- Median durasi tahap (Delivered Population): purchase → approved 0,01 hari (P95 2,01); approved → carrier 1,85 hari (P95 8,15); carrier → delivered 7,10 hari (P95 24,21).

**Hipotesis**
- **H-S1** Pembatalan terutama terjadi sebelum ada item terkirim, sehingga Cancellation dan Unavailable Rate perlu dibaca terpisah (sudah terkunci). → Tahap 10
- **H-S2** Persetujuan hampir instan; variasi waktu ada di serah-terima seller (P95/P50 ≈ 4,4×) dan transit (≈ 3,4×). → Tahap 10, 11

### 4. Delivery (Delivered Population, n = 96.470)

**Temuan**
- `delivery_days`: median 10,22, P95 29,27, P99 46,05, maks 209,63. 72,7% tiba < 15 hari; 4,7% ≥ 30 hari.
- Estimasi Olist konservatif: **91,9%** tiba lebih cepat dari tanggal estimasi, **73,9%** tiba ≥ 8 hari lebih cepat, 43,6% ≥ 14 hari lebih cepat; 1,34% tepat di hari estimasi; 6,77% telat (1–3 hari 1,94%, 4–7 hari 1,87%, 8–14 hari 1,53%, > 14 hari 1,43%).
- Pada order telat, median purchase → carrier 3,5 hari (vs 1,85 keseluruhan, ≈ 1,9×) dan carrier → delivered 26,2 hari (vs 7,1, ≈ 3,7×).
- Rata-rata selisih order on-time terhadap estimasi = 12,81 hari (selisih timestamp). Angka 13,51 di roadmap (A20) selisihnya ≈ 0,7 hari, sama dengan rata-rata jam kedatangan dalam sehari; kemungkinan A20 memakai selisih tanggal. Perbedaan definisi, bukan masalah data.

**Hipotesis**
- **H-D1** Estimasi pengiriman cenderung dipadatkan (buffer besar), sehingga On-Time Rate tinggi tidak sama dengan pengiriman cepat. → Tahap 11
- **H-D2** Keterlambatan berasosiasi paling kuat dengan tahap transit (≈ 3,7× median), lebih kecil pada serah-terima seller (≈ 1,9×). → Tahap 11
- **H-D3** Pengiriman antar-state lebih lambat dan lebih mahal dari intra-state (lihat Regional). → Tahap 11, 16

### 5. Review (Review Population, n = 98.673)

**Temuan**
- Skor 5 = 57,77%; skor 1–2 = 14,69%. Komentar berbentuk U: 76,6% pada skor 1, 68,1% pada skor 2, 43,5% pada skor 3, 31,2% pada skor 4, 35,8% pada skor 5 (rata-rata 41,3%).
- Jeda jawab review: median 1,68 hari, P95 6,98, maks 518,7; 0 review dijawab sebelum dibuat.
- Skor rata-rata menurut telat × timing jawaban (D4): tidak telat dan dijawab setelah terima 4,291 (n = 89.263); tidak telat, dijawab sebelum terima 3,956 (n = 180); telat dijawab setelah terima 3,72 (n = 1.908); **telat dijawab sebelum terima 1,652 (n = 4.473)**. Sebanyak 70,1% order telat ber-review dijawab sebelum barang tiba; hanya 4,86% dari seluruh Delivered ∩ Review.
- Setelah terima, skor turun ringan seiring keterlambatan: 4,29 → 3,75 (1–3 hari) → 3,69 (4–7) → 3,53 (8–14) → 2,90 (> 14, n = 19).

**Hipotesis**
- **H-V1** Sebagian besar selisih skor telat vs tepat waktu berasal dari review yang dijawab sebelum barang tiba (timing), bukan hanya dari keterlambatan; laporan wajib dua lapis angka (D4). → Tahap 12
- **H-V2** Pada review yang dijawab setelah terima, skor tetap sedikit lebih rendah untuk order telat; sampel di ekor panjang kecil. → Tahap 12
- **H-V3** Review rendah lebih sering berkomentar, tetapi NLP di luar scope; hanya keberadaan komentar yang dipakai. → Tahap 12

### 6. Payment (Payment Population, n = 99.440)

**Temuan**
- Kartu kredit 73,92% baris dan **78,34% nilai** pembayaran; boleto 19,04% / 17,92%; voucher 5,56% / 2,37% (rata-rata R$ 65,7); debit 1,47% / 1,36%; `not_defined` 3 baris bernilai 0.
- 66,85% pembayaran kartu kredit memakai cicilan > 1x. Rata-rata nilai naik seiring cicilan: R$ 95,9 (1x) → 127,2 (2x) → 142,5 (3x) → 181,3 (4–6x) → 333,8 (7–10x); 11x+ hanya 0,44%.
- 97,74% order satu tipe pembayaran, 2,26% (2.246) dua tipe.
- Kombinasi tipe pada 2.246 order multi-payment-type: **`credit_card + voucher` 2.245 order (99,96%)** dan `credit_card + debit_card` 1 order (0,04%). (Run pertama blok ini salah kelompok per order; hasil di atas dari query blok 6.3b yang sudah diperbaiki.)

**Hipotesis**
- **H-P1** Pembayaran didominasi kartu kredit; nilai order lebih besar berasosiasi dengan cicilan lebih panjang. → Tahap 13
- **H-P2** Voucher berfungsi sebagai pendamping kartu kredit, bukan metode berdiri sendiri: praktis semua order multi-tipe (99,96%) adalah kartu kredit + voucher. → Tahap 13

### 7. Category & Seller (Revenue Population)

**Temuan**
- Top kategori by revenue: health_beauty 9,31%, watches_gifts 8,88%, bed_bath_table 7,68%, sports_leisure 7,26%, computers_accessories 6,70%; top 10 = 62,37%. 52 kategori memenuhi minimum ≥ 100 order.
- Peringkat revenue ≠ peringkat order: bed_bath_table punya order terbanyak (9.399) dengan revenue/order R$ 110; watches_gifts revenue ke-2 dengan revenue/order R$ 213,8 (order ke-7); telephony R$ 77.
- Kategori `unknown` = 1,323% revenue.
- Top 10 seller = 14,15% baris item (semuanya di SP; terbesar 1,80%).
- Tier seller (D11): **210 seller (6,79%) = 51,68% revenue**; mid 424 seller (13,70%) = 25,40%; long-tail 2.419 seller (78,16%) = 22,93%.

**Hipotesis**
- **H-C1** Kategori bervolume tinggi dan kategori bernilai tinggi berbeda; analisis kategori butuh revenue dan order berdampingan. → Tahap 14
- **H-SE1** Marketplace terkonsentrasi pada segelintir seller besar di SP, sementara long-tail besar dalam jumlah tetapi kecil dalam revenue. → Tahap 15

### 8. Regional

**Temuan**
- SP: 41,98% order (Order Population), 41,88% Revenue Orders, **38,27%** revenue; RJ 12,9%, MG 11,7%, RS 5,5%, PR 5,1%.
- Supply–demand: SP punya 59,74% seller vs 41,98% customer (+17,8 poin); RJ 5,53% vs 12,92% (−7,4); PR 11,28% vs 5,07% (+6,2); MG −3,8; BA −2,8. AL, TO, AP, RR punya 807 customer tanpa seller.
- AOV per state: SP ≈ R$ 125,6 (di bawah rata-rata 137,4), MG ≈ 136,9, RJ ≈ 142,7, BA ≈ 151,6.
- Single-Seller Population (n = 96.922): **35,87% intra-state**, 64,13% antar-state. Intra-state: ongkir rata-rata R$ 15,19, waktu kirim 7,97 hari, Late Rate 4,557%; antar-state: R$ 26,60, 15,21 hari, 8,138%.

**Hipotesis**
- **H-G1** Ketimpangan supply (terpusat di SP) berasosiasi dengan porsi antar-state yang besar, ongkir lebih mahal, dan waktu kirim lebih lama. → Tahap 15, 16
- **H-G2** Order di luar SP bernilai lebih besar per order (AOV SP paling rendah di antara state besar). → Tahap 16

### 9. Time

**Temuan**
- `period_quality`: 2016-11 = `missing`; 2016-09/10/12 = `sparse_rampup`; 2017-01–2018-08 = `full` (20 bulan); 2018-09/10 = `truncated`.
- Batas data: purchase pertama 2016-09-04 dan terakhir 2018-10-17; delivered terakhir 2018-10-17; estimasi terakhir 2018-11-12. Order 2016-10 hanya di 10 hari (2016-10-02 s.d. 2016-10-22); 2016-12 hanya 1 order (2016-12-23); 2017-01 baru mulai 2017-01-05 (27 hari berorder).
- Ekor 2018-09/10: **19 dari 20 order berstatus canceled** (15 + 4), 1 shipped. Bulan-bulan ini bukan permintaan yang mendekati nol.
- `pct_in_flight` menurun dari 4,63% (2017-01) ke ≤ 2% pada mayoritas bulan setelahnya (status basi di bulan lama).

**Hipotesis**
- **H-T1** Gap 2016-11 dan ekor 2018-09/10 adalah artefak cakupan ekstraksi, bukan pola permintaan; tren/growth hanya memakai `full`. → Tahap 8, 9
- **H-T2** Lonjakan MoM Februari 2017 (+104% revenue) sebagian dilebihkan karena 2017-01 baru mulai 5 Januari. → Tahap 9

### 10. Outlier & Anomaly

**Temuan**
- Delivery > P99 (46,05 hari): 965 order, rata-rata 62,6 hari, **95,85% telat**. State over-represented: PA (lift 5,39), CE (4,38), PE (2,76), RJ (2,63; 33,7% dari ekor vs 12,8% basis), BA (1,90); SP hanya 0,29.
- `freight_value = 0` (383 item): 100% seller SP; 96,3% dari 4 seller (158, 99, 56, 56 item); kategori watches_gifts 55,9%, furniture_decor 25,6%, garden_tools 14,6%.
- Harga ≥ P99 (R$ 889): 1.122 item = 11,78% Item Revenue; kategori teratas watches_gifts 12,9%, computers 9,5%, health_beauty 9,4%.
- Anomali urutan timestamp: **1.382 order** (1.373 delivered, 9 shipped); 1.350 di antaranya `carrier < approved`. Tidak mengelompok per state (lift 0,78–1,31), tetapi sangat mengelompok per bulan: **2018-07 9,0% (566)** dan **2018-04 5,66% (393)**, keduanya ≈ 70% dari anomali di Analysis Window; 2018-06 1,99%, 2018-08 1,32%, bulan lain umumnya < 1%. Konsentrasi per seller tidak tajam (terbesar 3,83%, dan seller itu memang seller terbesar).

**Hipotesis**
- **H-X1** Ongkir nol adalah kebijakan gratis-ongkir pada segelintir seller SP, bukan error data (mendukung keputusan retain di Tahap 5). → Tahap 11, 15
- **H-X2** Anomali urutan timestamp berasosiasi dengan periode pencatatan tertentu (2018-04, 2018-07), bukan dengan state atau seller tertentu; durasi tahap approved → carrier di periode itu perlu ditafsirkan hati-hati. → Tahap 11
- **H-X3** Ekor pengiriman sangat lama terkonsentrasi di state jauh dari pusat seller. → Tahap 11, 16
- **H-X4** Harga ekstrem terkonsentrasi di beberapa kategori bernilai tinggi. → Tahap 14

## Area kandidat Business Analysis (ringkas)

| Tahap | Fokus yang diusulkan EDA |
|---|---|
| 9 Sales & Revenue | Median vs mean, dekomposisi lonjakan 2017-11, plateau 2018, freight/harga per band |
| 10 Order Status & Fulfillment | Funnel status, tahap dengan variasi terbesar (handover vs transit) |
| 11 Delivery & Logistics | Estimasi konservatif, tahap transit, intra vs antar-state, ekor > P99, dampak anomali timestamp |
| 12 Customer Satisfaction | Stratifikasi timing jawaban (D4), skor per bucket keterlambatan |
| 13 Payment | Kartu kredit dan cicilan vs nilai order, kombinasi multi-payment |
| 14 Product Category | Revenue vs order per kategori, harga ekstrem, `unknown` |
| 15 Seller Performance | Konsentrasi (210 seller), tier D11, gratis-ongkir per seller |
| 16 Regional | Ketimpangan supply–demand, AOV per state, ekor pengiriman per state |
| 17 Customer Repeat | Deskriptif saja (repeat ≥24 jam 2,208%; 90-day 1,302%) |

## Output
- Tabel `eda_metrics` (51 metrik, 11 kelompok)
- `data/processed/06_eda_summary.parquet` (ter-ignore git)

## Assumptions
- Populasi tiap blok mengikuti definisi terkunci; blok yang memakai Order Population, Item Population, atau Single-Seller Population menyebutnya eksplisit.
- Durasi tahap mengecualikan baris berflag anomali urutan tanggal hanya untuk tahap terkait.
- Batas P99 dihitung pada populasi masing-masing blok (delivery pada Delivered Population, harga pada item Revenue Population).
- "Lebih cepat dari estimasi" pada tabel selisih memakai perbandingan tanggal (konsisten dengan D1).

## Batasan data
- Semua temuan adalah asosiasi. Tidak ada uji signifikansi atau pengendalian variabel perancu.
- Beda kecil terhadap angka roadmap yang perlu dicek basis populasinya di tahap analisis, dan **bukan** perubahan definisi:
  - Share revenue tier Top seller: 51,68% (Revenue Population) vs 51,48% di roadmap (A18/D11); jumlah seller (210) dan ambang (≥100 order) sama. Kemungkinan beda basis (Item Population vs Revenue Population); dicek di Tahap 15.
  - Share kategori `unknown`: 1,323% vs 1,321% di roadmap (D7); dicek di Tahap 14.
  - Rata-rata percepatan on-time: 12,81 vs 13,51 hari (A20), dijelaskan oleh beda timestamp vs tanggal.
- Order 2017-01 tidak memiliki hari 1–4 Januari.

## Kesimpulan
Kesepuluh kelompok exploration memiliki temuan berangka dan hipotesis kandidat. Tidak ditemukan masalah data baru yang mengharuskan kembali ke Tahap 5 atau 6: anomali timestamp sudah di-flag dan hanya perlu dibaca sebagai kluster per periode. Pola paling penting untuk analisis berikutnya: revenue terkonsentrasi pada item mahal dan seller besar di SP, waktu kirim dan ongkir berbeda tajam antara intra dan antar-state, dan skor review sangat dipengaruhi timing jawaban.
