# 12 — Payment Behavior Analysis

> Pendamping `sql/12_payment_behavior.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah. `payment_value` **tidak** dialokasikan ke kategori atau seller (order-level; revenue per kategori/seller selalu dari `price`).

## Input
- Model dimensional Tahap 8: `fact_payments`, `fact_orders`, `fact_order_items`, `dim_date`
- Populasi: Payment Population (99.440 order); Reconcilable Population (98.665) untuk rekonsiliasi

## Proses Analisis
1. Share metode pembayaran per baris, per order (memuat tipe), dan per kombinasi eksklusif; tren bulanan bauran (`payment_monthly`).
2. Cicilan kartu kredit (`installments = 0` di-exclude): distribusi, nilai pembayaran dan nilai per cicilan, hubungan dengan nilai order.
3. Order multi-payment: kombinasi, jumlah baris per order, porsi voucher.
4. Metode pembayaran vs Cancellation Rate dan Review Score (korelasional); pendalaman order voucher-saja.
5. Metode pembayaran per state (27 state dengan n, tanpa tiering).
6. Rekonsiliasi payment vs item+freight sebagai data-quality view, termasuk hubungannya dengan cicilan.
7. Reconcile ke KPI terkunci (`payment_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**43 metrik: 40 PASS, 3 INFO, 0 CHECK.** Payment Population **99.440** order dan **103.886** baris reconcile ke jumlah per tipe, per kombinasi, dan per bulan; Payment Total **R$ 16.008.872,12** sama dengan nilai terkunci Tahap 6; rekonsiliasi item+freight tereproduksi (98.362 / 54 / 249).

### 1. Share metode pembayaran

| Tipe | Baris | % baris | Nilai (R$) | % nilai | Rata-rata | Median | P95 | Order memuat tipe (% dari 99.440) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| credit_card | 76.795 | 73,92 | 12.542.084,19 | **78,34** | 163,32 | 106,87 | 467,12 | 76.505 (76,94%) |
| boleto | 19.784 | 19,04 | 2.869.361,27 | 17,92 | 145,03 | 93,89 | 399,19 | 19.784 (19,90%) |
| voucher | 5.775 | 5,56 | 379.436,87 | 2,37 | 65,70 | 39,28 | 200,00 | 3.866 (3,89%) |
| debit_card | 1.529 | 1,47 | 217.989,79 | 1,36 | 142,57 | 89,30 | 363,49 | 1.528 (1,54%) |
| not_defined | 3 | 0,00 | 0,00 | 0,00 | 0 | 0 | 0 | 3 |

**Kombinasi eksklusif per order (jumlah = 99.440):** credit_card 74.259 (74,68%; rata-rata R$ 166,95, median 109,35), boleto 19.784 (19,90%; 145,03 / 93,89), credit_card + voucher 2.245 (2,26%; 150,88 / 102,42), voucher saja 1.621 (1,63%; 114,39 / 71,63), debit_card 1.527 (1,54%; 142,72 / 89,30), not_defined 3, credit_card + debit_card 1 (R$ 152,82). Rata-rata per order voucher-saja (R$ 114,39) lebih besar daripada rata-rata per baris voucher (R$ 65,70) karena order voucher sering memuat beberapa baris.

**Tren bauran bulanan (20 bulan `full`):**
- Kartu kredit memuat 72,75–79,66% order (terendah 2017-01, tertinggi 2018-05); porsi nilai kartu kredit 75,06–80,52%.
- **Boleto menurun** dari 24,63% (2017-01) dan ≈ 20–22% sepanjang 2017 menjadi **17,49% (2018-08)**.
- **Debit melonjak pada 2018-06..08**: 2,93%, 3,85%, 4,25% dari order, dibanding 0,5–1,5% sebelumnya (0,74% pada 2018-05); porsi nilai kartu kredit tertekan menjadi 75,35% pada 2018-07.
- Voucher turun dari 4–5% (2017) ke 2,95–3,77% (2018); order multi-tipe turun dari ≈ 2,6–2,9% (pertengahan 2017) ke 1,55% (2018-08).
- Pemakaian cicilan: rata-rata cicilan kartu kredit 3,12–4,09 (puncak 2017-05, terendah 2018-02); porsi pembayaran kartu kredit bercicilan > 1: puncak **75,73% (2017-07)** turun ke 61,96% (2018-02) dan 63–65% pada pertengahan 2018.
- Bulan non-`full` hanya anotasi: 2018-09/10 hampir seluruhnya order dengan voucher (15 dari 16 dan 4 dari 4), tanpa kartu kredit/boleto/debit.

### 2. Cicilan kartu kredit (76.793 baris valid; 2 baris `installments = 0` di-exclude)
- **66,85%** pembayaran memakai cicilan > 1x (51.338). Distribusi: 1x 33,15% (25.455; rata-rata R$ 95,87, median 67,87), 2x 16,16%, 3x 13,62%, 4x 9,24%, 5x 6,82%, 6x 5,10%, **7x 2,12%**, **8x 5,56%**, 9x 0,84%, **10x 6,94%**, 11x+ 0,44% (341; maks 24x). Cicilan menumpuk di 8x dan 10x (rata-rata R$ 307,74 dan R$ 415,09) dibanding 7x (R$ 187,67) dan 9x (R$ 203,44).
- Bucket: 4–6x rata-rata R$ 181,32 (21,17%); 7–10x R$ 333,83 (15,45%); 11x+ R$ 358,34. Korelasi Pearson cicilan vs nilai pembayaran **0,376** (moderat).
- Nilai per cicilan rata-rata menurun: R$ 95,87 (1x) → 63,61 (2x) → 47,51 (3x) → 40,99 (4x) → 36,69 (5x) → 34,97 (6x); 8x R$ 38,47 dan 10x R$ 41,51; 11x+ sekitar R$ 10–30.
- **Cicilan menurut nilai order (order credit_card-saja):**

| Nilai order | n | Cicilan rata-rata | % cicilan > 1 | % cicilan ≥ 7 |
|---|---:|---:|---:|---:|
| < 50 | 11.645 | 1,75 | 39,65% | 0,02% |
| 50–99 | 22.125 | 2,72 | 57,13% | 7,30% |
| 100–199 | 24.378 | 3,81 | 77,90% | 17,18% |
| 200–499 | 12.649 | 5,17 | 87,10% | 32,38% |
| ≥ 500 | 3.460 | 7,18 | **92,11%** | **61,16%** |

### 3. Order multi-payment
- **2.246 order (2,26%) multi-tipe**: credit_card + voucher **2.245 (99,96%)** dan credit_card + debit_card 1.
- Baris payment per order: 1 baris 97,02% (96.479), 2 baris 2,40% (2.382), 3 baris 0,30% (301), 4 baris 0,11% (108), 5 baris 0,05% (52), 6+ baris 0,12% (118). Ada **2.961 order multi-baris** (4.446 baris tambahan), dan 715 di antaranya hanya satu tipe (mis. beberapa voucher atau beberapa pembayaran kartu).
- **Pada order credit_card + voucher, voucher biasanya menutup bagian terbesar**: porsi voucher rata-rata **64,57%** (median 71,0%) dari nilai order, rata-rata 1,40 baris voucher; distribusi porsi voucher: < 10% 3,61%, 10–29% 11,94%, 30–59% 23,16%, 60–89% 38,35%, ≥ 90% 22,94% (61,3% order memiliki porsi voucher ≥ 60%).

### 4. Metode pembayaran vs Cancellation Rate dan Review Score (korelasional)

| Kombinasi | Order | Cancel | Unavailable | Avg skor | Skor order on-time | Late Rate |
|---|---:|---:|---:|---:|---:|---:|
| credit_card | 74.259 | 0,574% | 0,574% | 4,088 | 4,294 | 6,696% |
| boleto | 19.784 | 0,480% | 0,758% | 4,087 | 4,282 | 7,321% |
| credit_card + voucher | 2.245 | 0,802% | 0,757% | 4,070 | 4,260 | 6,098% |
| **voucher saja** | 1.621 | **4,688%** | 0,617% | 3,948 | 4,235 | 5,808% |
| debit_card | 1.527 | 0,458% | 0,393% | 4,169 | 4,341 | 5,327% |
| not_defined | 3 | 100% | 0% | 1,667 | — | — |

- Skor rata-rata dan Late Rate hampir sama antar metode (skor 4,07–4,17; Late Rate 5,3–7,3%); satu-satunya penyimpangan nyata adalah Cancellation Rate voucher-saja.
- **Cicilan (order credit_card-saja, per cicilan maksimum):** skor turun dan Late Rate naik seiring cicilan: 1x 4,155 / 5,98% (23.805 order), 2–3x 4,086 / 6,84%, 4–6x 4,059 / 6,96%, 7–10x 4,002 / 7,48%, 11x+ 3,861 / 8,52% (329 order). Cancellation Rate hampir datar (0,54–0,65%).
- **Pendalaman voucher-saja (1.621 order; 76 canceled):**
  - Status: delivered 92,41% (1.498), canceled 4,69%, shipped 1,73%, unavailable 0,62%.
  - Menurut jumlah voucher: **1 voucher 6,281%** (75 canceled dari 1.194), 2 voucher 0% (0 dari 224), 3+ voucher 0,493% (1 dari 203). Hampir seluruh pembatalan ada pada order satu voucher.
  - Menurut nilai order: < 25 → 0%; 25–49 → 1,222%; 50–99 → 4,738%; 100–199 → 5,291%; **≥ 200 → 14,198%** (23 dari 162).
  - **Dari 76 order voucher-saja yang canceled, hanya 5 yang punya item** (71 tidak; 93,4%): pembatalan terjadi sebelum item dialokasikan.
  - Ekor data 2018-09/10 (19 dari 20 order, canceled) terdiri dari order voucher-saja, sehingga 19 dari 76 pembatalan voucher-saja (25%) ada di ekor itu.

### 5. Metode pembayaran per state (27 state, n selalu ditampilkan)
- **Cicilan:** rata-rata cicilan kartu kredit tertinggi PB **4,67**, SE 4,59, AC 4,52, RO 4,45, AL 4,42, RN 4,38, PI 4,29; terendah **SP 3,20**, DF 3,23, AP 3,40, RR 3,42. Porsi pembayaran kartu kredit bercicilan > 1: tertinggi AC 85,25%, AL 80,77%, AP 80,85% (n = 68), PB 80,52%, RN 80,26%; terendah SP **62,1%**, DF 62,5%, AM 65,3%.
- **Boleto:** tertinggi AP 29,41% (68), RR 28,26% (46), **MA 27,18%**, TO 27,14%, MT 26,24%, RO 25,30%, RS 24,86%, MS 24,48%; terendah AM 14,19%, CE 15,34%, AL 16,46%, RN 16,49%, PE 16,77%, RJ 16,83%.
- **Kartu kredit:** tertinggi AM 83,78% (148), AL 81,84%, CE 81,06%, RN 80,41%, PE 80,27%, RJ 79,78%; terendah AP 69,12% (68), TO 70,0%, MA 71,49%, RR 71,74%, MS 72,17%, MT 72,44%.
- **Voucher:** tertinggi PI 5,45%, BA 5,21%, AC 4,94%; terendah RR 0% (46), AL 2,42%, MA 2,54%, AM 2,70%, RO/MT ≈ 2,8%. **Debit:** tertinggi AC 2,47%, PB 2,43%, PI 2,22%, SP 1,82%.
- State bervolume besar (SP, RJ, MG, RS, PR, SC) menunjukkan variasi lebih kecil; state dengan n < 150 (AM, AC, AP, RR) tidak stabil.

### 6. Rekonsiliasi payment vs item+freight (data-quality view; Reconcilable Population 98.665)
- Selisih ≤ 0,01: **98.362**; 0,01–1: **54**; > 1: **249** (payment > item+freight **232**; payment < item+freight **17**). Total excess **R$ 3.064,76 = 0,0191%** dari Payment Total.
- Seluruh 232 order payment > item+freight melibatkan kartu kredit; **order tanpa kartu kredit (22.674) memiliki 0** order payment > item+freight.
- **Excess naik seiring cicilan (order dengan kartu kredit):**

| Cicilan maks | Order | Order payment > item+freight | % | Median excess (% dari item+freight) |
|---|---:|---:|---:|---:|
| 1x | 25.149 | 3 | 0,012% | 3,23% |
| 2–3x | 22.662 | 40 | 0,177% | 4,63% |
| 4–6x | 16.097 | 91 | 0,565% | 8,17% |
| 7–10x | 11.744 | 74 | 0,630% | 13,03% |
| 11x+ | 337 | 24 | **7,122%** | **15,50%** |

  Baik frekuensi maupun besar excess meningkat monoton, konsisten dengan biaya pembiayaan (bunga/biaya) yang dibebankan ke payment; dataset tidak memuat data bunga sehingga ini tetap hipotesis.

## Hipotesis Kandidat (untuk Tahap 14–17 dan 21, belum diuji)
- **H-P1** Kartu kredit mendominasi nilai (78,3%), boleto menyusut perlahan (24,6% → 17,5%), dan debit melonjak pada Juni–Agustus 2018 (0,7% → 2,9–4,3%). → Tahap 21
- **H-P2** Pemakaian cicilan sangat bergantung pada nilai order (39,7% bercicilan pada order < R$ 50 vs 92,1% pada ≥ R$ 500; cicilan ≥ 7x 0,02% vs 61,2%), menumpuk di 8x/10x, dan porsi bercicilan turun dari ≈ 75% (pertengahan 2017) ke ≈ 64% (2018). → Tahap 21
- **H-P3** Voucher berfungsi sebagai instrumen pembayaran parsial yang berpasangan dengan kartu kredit dan biasanya menutup mayoritas nilai order (median 71%). → Tahap 21
- **H-P4** Pembatalan tinggi pada voucher-saja terkonsentrasi pada order satu voucher, order bernilai besar (14,2% pada ≥ R$ 200), dan sebelum item dialokasikan (93% tanpa item). → Tahap 21 (batasan/monitoring)
- **H-P5** Metode pembayaran hampir tidak membedakan skor atau Late Rate; skor lebih rendah dan Late Rate lebih tinggi pada order bercicilan panjang, tetapi tercampur nilai order dan state. → Tahap 16
- **H-P6** State jauh/Utara–Timur Laut memakai cicilan lebih banyak (PB, SE, AC, RO, AL) dibanding SP; boleto lebih sering di MA, MT, RS, dan beberapa state Utara. → Tahap 16
- **H-P7** Excess payment hanya muncul pada order kartu kredit dan membesar seiring cicilan (konsisten dengan biaya pembiayaan). → Tahap 21 (batasan data)

## Output
- Tabel: `payment_monthly` (26 bulan), `payment_findings` (43 metrik)
- `data/processed/12_payment_monthly.parquet` (26 baris), `12_payment_findings.parquet` (43 baris); ter-ignore git

## Assumptions
- Payment Population = order yang punya ≥ 1 baris payment (99.440); 1 order tanpa payment tidak ikut.
- Cicilan hanya credit_card; baris `installments = 0` (2 baris) di-exclude; "cicilan maksimum" per order = cicilan terbesar dari pembayaran kartu kredit valid.
- Kombinasi pembayaran = tipe unik per order, diurutkan; Cancellation/Unavailable Rate dihitung per kombinasi dengan denominator order pada kombinasi itu.
- Review Score dari Review Population; Late Rate dari Delivered Population.
- Rekonsiliasi memakai `DECIMAL(12,2)` dan agregat per order sebelum join.
- `payment_value` tidak dialokasikan ke kategori maupun seller.

## Batasan data
- Dataset tidak memuat suku bunga, biaya cicilan, kupon/diskon, atau alasan pembayaran; pola excess dan peran voucher hanya hipotesis.
- Nilai per cicilan adalah rata-rata; jadwal cicilan sebenarnya tidak diketahui.
- Penyebab lonjakan debit (2018-06..08) dan penurunan boleto tidak dapat diidentifikasi dari data (bisa perubahan fitur pembayaran atau bauran pelanggan).
- Perbandingan antar metode, cicilan, dan state tidak mengontrol variabel perancu (nilai order, state, kategori).
- State dengan n kecil (AP 68, RR 46, AC 81, AM 148) tidak dapat ditafsirkan stabil.
- Bulan non-`full` (2016-09/10/12, 2018-09/10) hanya anotasi.

## Kesimpulan
Payment Population dan Payment Total reconcile penuh ke nilai terkunci. Pembayaran didominasi kartu kredit (78,3% nilai) dengan cicilan yang sangat terkait nilai order; voucher berperan sebagai pembayaran parsial pendamping kartu kredit. Metode pembayaran hampir tidak membedakan kepuasan atau keterlambatan, tetapi order voucher-saja menonjol pada pembatalan (4,69%), terutama order satu voucher bernilai besar dan sebelum item dialokasikan, dan menjelaskan seluruh ekor data 2018-09/10. Selisih payment > item+freight hanya muncul pada order kartu kredit dan membesar seiring cicilan, konsisten dengan biaya pembiayaan namun tidak dapat dibuktikan.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** pantau validasi order voucher-saja bernilai besar; pelajari pergeseran bauran pembayaran pada 2018 (boleto turun, debit naik); jelaskan bahwa Payment Total tidak sebanding dengan GMV dan excess ≈ 0,02% adalah data-quality note.
