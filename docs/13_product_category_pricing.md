# 13 — Product Category & Pricing Performance

> Pendamping `sql/13_product_category_pricing.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah. Item Revenue per kategori adalah **alokasi nyata** dari `price` (bukan `payment_value`).

## Input
- Model dimensional Tahap 8: `fact_order_items`, `fact_orders`, `dim_product`
- Populasi: Revenue Population (98.199 order; 112.101 item) untuk revenue/harga/freight; Item Population (112.650 item) hanya sebagai pembanding addendum roadmap (kategori `unknown`, basket)

## Proses Analisis
1. Ringkasan kategori (`category_summary`, 74 kategori): Item Revenue, order, unit, harga (P25–P95), freight, berat; peringkat revenue vs order; minimum volume ≥100 order (D6).
2. Kategori `unknown` pada dua basis (Item Population vs Revenue Population).
3. Distribusi harga per kategori dan matriks harga tinggi vs volume tinggi.
4. Freight ratio dan berat per kategori, termasuk korelasi lintas-kategori.
5. Kategori per state: porsi 5 kategori teratas di 8 state terbesar dan pasangan state × kategori dengan lift terbesar.
6. Atribut listing (foto, panjang nama/deskripsi) vs penjualan per produk, dengan kontrol tertil harga.
7. Negative finding: basket lintas kategori.
8. Reconcile ke KPI terkunci dan addendum roadmap (`category_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**23 metrik: 20 PASS, 3 INFO, 0 CHECK.** **`SUM(revenue per kategori)` = R$ 13.494.400,74 = Item Revenue total terkunci (selisih 0)**; jumlah unit seluruh kategori = 112.101 (Revenue Population) dan jumlah item = 112.650 (Item Population); 74 kategori (73 terjemahan + `unknown`).

### 1. Kategori: revenue, order, harga
**Top 15 by Item Revenue** (peringkat revenue / peringkat order):

| # revenue | # order | Kategori | Order | Item Revenue (R$) | % revenue | Median harga (R$) | P95 harga (R$) | Freight % | Berat median (g) |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 2 | health_beauty | 8.800 | 1.255.695,13 | 9,31 | 79,90 | 414,62 | 14,49 | 400 |
| 2 | 7 | watches_gifts | 5.604 | 1.198.185,21 | 8,88 | 129,00 | 689,00 | 8,35 | 348 |
| 3 | 1 | bed_bath_table | 9.399 | 1.035.964,06 | 7,68 | 79,90 | 205,00 | 19,73 | 1.290 |
| 4 | 3 | sports_leisure | 7.673 | 979.740,92 | 7,26 | 78,00 | 289,90 | 17,10 | 700 |
| 5 | 4 | computers_accessories | 6.654 | 904.322,02 | 6,70 | 81,99 | 275,00 | 16,21 | 300 |
| 6 | 5 | furniture_decor | 6.425 | 727.465,05 | 5,39 | 65,49 | 249,90 | 23,67 | 1.300 |
| 7 | 6 | housewares | 5.847 | 626.825,80 | 4,65 | 59,80 | 260,00 | 23,17 | 1.205 |
| 8 | 11 | cool_stuff | 3.616 | 620.770,49 | 4,60 | 129,99 | 539,99 | 13,42 | 1.450 |
| 9 | 9 | auto | 3.872 | 586.585,73 | 4,35 | 84,90 | 429,90 | 15,69 | 900 |
| 10 | 12 | garden_tools | 3.505 | 481.009,94 | 3,56 | — | 329,90 | 20,48 | 1.650 |
| 11 | 10 | toys | 3.855 | 479.808,54 | 3,56 | 79,90 | 329,90 | 16,04 | 800 |
| 12 | 14 | baby | 2.868 | 410.312,20 | 3,04 | — | 394,41 | 16,57 | 700 |
| 13 | 13 | perfumery | 3.146 | 396.599,31 | 2,94 | — | 339,90 | 13,61 | 400 |
| 14 | 8 | telephony | 4.183 | 322.342,64 | 2,39 | 29,99 | 274,99 | 22,01 | 225 |
| 15 | 20 | office_furniture | 1.272 | 273.580,70 | 2,03 | 144,99 | 308,79 | 25,04 | 10.975 |

(— = kolom tidak tampil pada output run.)

- **Konsentrasi:** top-1 **9,31%**, top-10 **62,37%**, top-20 **84,04%**. 74 kategori; **52 kategori ≥ 100 order** memuat **98,95%** revenue; 22 kategori < 100 order hanya ≈ 1,05%, dan **11 kategori < 30 order** (flowers 29, fashion_sport 27, diapers_and_hygiene 26, home_comfort_2 24, arts_and_craftmanship 23, portable_kitchen_food_preparers 13, la_cuisine 13, cds_dvds_musicals 12, fashion_childrens_clothes 8, pc_gamer 7, security_and_services 2). Dua kategori hasil mapping manual (`portable_kitchen_food_preparers`, `pc_gamer`) sangat kecil.
- **Volume ≠ nilai:** `bed_bath_table` terbanyak order (9.399; revenue/order R$ 110,22) tetapi ke-3 revenue; `watches_gifts` ke-7 order tetapi **ke-2 revenue** (R$ 213,81 per order); `telephony` ke-8 order tetapi ke-14 revenue (median harga R$ 29,99; R$ 77,06 per order); `office_furniture` ke-20 order tetapi ke-15 revenue (R$ 215,08 per order).

### 2. Kategori `unknown` (610 produk) — dua basis

| Basis | Item | Order | Item Revenue (R$) | % item revenue |
|---|---:|---:|---:|---:|
| Item Population (basis addendum) | 1.603 | 1.451 | 179.535,28 | **1,321** |
| Revenue Population (basis KPI terkunci) | 1.589 | 1.437 | 178.572,55 | **1,323** |

Selisih kecil yang ditandai pada EDA (1,323% vs 1,321%) **terjelaskan oleh basis populasi**, bukan masalah data: Item Population total R$ 13.591.643,70, Revenue Population R$ 13.494.400,74; selisih R$ 97.242,96 = item pada order canceled (R$ 95.235,27) + unavailable (R$ 2.007,69), persis sama dengan Tahap 10. Untuk dashboard memakai basis Revenue Population (1,323%, R$ 178.572,55; 1.437 order). Kategori `unknown` dilaporkan sebagai kategori sendiri dan berada di kuadran harga rendah & volume tinggi.

### 3. Distribusi harga dan matriks harga vs volume (kategori ≥ 100 order)
- **Median harga tertinggi:** computers **R$ 1.100** (181 order; P75 1.340; P95 1.599,99), agro_industry_and_commerce 258,65, home_appliances_2 227,99 (P95 2.020,99), office_furniture 144,99, air_conditioning 139,99, cool_stuff 129,99, watches_gifts 129,00. **Terendah:** electronics **R$ 21,89**, telephony 29,99, food_drink 38,99, books_general_interest 44,93, christmas_supplies 45,35, drinks 47,49, home_appliances 47,59, food 48,89, fashion_bags_accessories 49,00.
- **Matriks** (ambang harga = median harga item R$ 74,90; ambang volume = median 563 order antar kategori ≥ 100 order):

| Kuadran | Kategori | % revenue | Contoh |
|---|---:|---:|---|
| Harga tinggi & volume tinggi | 17 | **68,51** | bed_bath_table, health_beauty, sports_leisure, computers_accessories, watches_gifts, auto, toys, cool_stuff, perfumery, baby, office_furniture |
| Harga tinggi & volume rendah | 15 | 7,08 | home_construction, furniture_living_room, audio, air_conditioning, computers, home_appliances_2, fashion_shoes |
| Harga rendah & volume tinggi | 9 | 21,34 | furniture_decor, housewares, telephony, garden_tools, electronics, fashion_bags_accessories, unknown, consoles_games, home_appliances |
| Harga rendah & volume rendah | 11 | 2,02 | books_general_interest, food, drinks, market_place, books_technical, food_drink, fixed_telephony, christmas_supplies |

  Banyak kategori "harga tinggi" hanya sedikit di atas ambang (mis. bed_bath_table dan health_beauty median R$ 79,90); batas ini adalah median keseluruhan, bukan klasifikasi mutlak.

### 4. Freight ratio dan berat per kategori
- **Freight % tertinggi:** christmas_supplies **36,66%** (127 order; median harga 45,35), signaling_and_security 30,26%, food_drink 29,69%, **electronics 29,50%** (2.543 order; berat median 200 g; ongkir R$ 16,82/item), furniture_living_room 26,11%, kitchen_dining_laundry_garden_furniture 25,69%, drinks 25,57%, office_furniture 25,04%.
- **Freight % terendah:** **computers 4,41%** (median harga R$ 1.100; berat 2.800 g; ongkir R$ 48,45/item), fixed_telephony 7,94%, agro_industry 8,06%, watches_gifts 8,35%, small_appliances 8,42%, home_appliances_2 9,40% (7.500 g; ongkir R$ 44,28/item), construction_tools_safety 9,68%, musical_instruments 9,71%.
- **Berat median:** terberat office_furniture **10.975 g** (ongkir R$ 40,53/item), furniture_living_room 7.500, home_appliances_2 7.500, kitchen_dining 6.450, industry_commerce_and_business 6.100; teringan electronics 200 g, fashion_bags_accessories 200, telephony 225, consoles_games 250, computers_accessories 300.
- **Korelasi lintas 52 kategori:** berat median vs ongkir per item **r = 0,78**; harga median vs freight % **r = −0,42**; berat median vs freight % **r = 0,07**. Ongkir per item ditentukan terutama oleh berat, sedangkan freight sebagai persentase harga ditentukan oleh harga: barang ringan-murah (electronics, telephony, christmas_supplies) menanggung rasio tertinggi; barang berat-mahal (computers, home_appliances_2) rasio rendah.

### 5. Kategori per state
- **Porsi 5 kategori nasional teratas di 8 state terbesar (persen revenue state; nasional dalam kurung):**
  - SP: bed_bath_table **9,25** (7,68), health_beauty 8,92 (9,31), watches_gifts 8,35 (8,88), sports_leisure 7,40, computers_accessories 6,72.
  - RJ: watches_gifts **10,15** teratas, bed_bath_table 8,16, health_beauty 8,00. MG: health_beauty 10,01. RS: bed_bath_table 8,12; health_beauty 6,91 dan watches_gifts 6,48 di bawah nasional. PR: watches_gifts 8,84, sports_leisure 8,64. SC: sports_leisure 8,38, bed_bath_table 6,01.
  - BA: health_beauty 10,10, watches_gifts 9,63, **bed_bath_table hanya 5,07**. DF: watches_gifts **10,88**, health_beauty 9,92, bed_bath_table 5,45.
- **Spesialisasi (state × kategori ≥ 100 order, lift terhadap porsi nasional):** BA telephony 4,17% vs 2,39% (**lift 1,75**; 229 order), PE health_beauty 15,90% (1,71), PE telephony 1,70, CE health_beauty 14,33% (1,54), CE watches_gifts 12,94% (1,46), ES telephony 1,43, PA health_beauty 13,28% (1,43), RS furniture_decor 7,38% (1,37; 444 order). Variasi regional moderat (lift maksimum 1,75); state Timur Laut (BA, PE, CE) over-index pada telephony, health_beauty, watches_gifts.

### 6. Atribut listing vs penjualan (deskriptif; 32.729 produk terjual)
| Foto | Produk terjual | Rata-rata unit/produk | Rata-rata revenue/produk (R$) | Median revenue (R$) | Rata-rata harga (R$) |
|---|---:|---:|---:|---:|---:|
| tidak ada data | 600 | 2,65 | 297,62 | 78,94 | 116,26 |
| 1 foto | 16.385 | 3,40 | 385,74 | 127,80 | 131,15 |
| 2 foto | 6.212 | 3,52 | 391,64 | 135,80 | 142,51 |
| 3 foto | 3.839 | 3,22 | 436,00 | 150,90 | 169,72 |
| 4–5 foto | 3.890 | 3,53 | 499,97 | 159,90 | 172,80 |
| 6+ foto | 1.803 | 3,79 | 523,49 | 168,00 | 175,71 |

- Revenue per produk naik ≈ 36% dari 1 ke 6+ foto (385,74 → 523,49), sedangkan **harga rata-rata naik ≈ 34%** (131,15 → 175,71) dan unit per produk hampir datar (3,40 → 3,79). Korelasi Pearson: foto vs unit **0,004**; foto vs revenue 0,027; foto vs harga 0,059; harga vs revenue 0,306.
- **Kontrol tertil harga:**
  - Tertil menengah (harga ≈ R$ 81–82, nyaris sama di semua kelompok foto): unit 3,89 / 4,21 / 3,52 / 4,24 dan revenue 325 / 328 / 284 / 350, tanpa pola menurut foto.
  - Tertil mahal: unit 3,12 / 2,64 / 3,04 / 2,93 (tanpa pola); revenue naik 784,62 → 969,39 (+23,5%) bersamaan dengan harga rata-rata 299,68 → 374,42 (+25%).
  - **Tertil murah** (harga ≈ R$ 29–32): unit naik 3,19 → 3,42 → 4,26 → 4,33 dan revenue 92,07 → 147,57 (+60%) dengan kenaikan harga hanya ≈ 10%. Ini satu-satunya segmen yang menunjukkan unit naik seiring foto.
  - Kenaikan revenue seiring foto pada tertil menengah dan mahal sejalan dengan harga (atau tidak ada); pada tertil murah ada asosiasi foto–unit, tetapi tetap dapat dibaur oleh jenis produk dan seller.
- **Panjang deskripsi (kuartil; ≈ 8.032 produk per kuartil):** unit rata-rata 3,21 / 3,56 / 3,47 / 3,52; harga rata-rata R$ 105 / 123 / 142 / **212**; revenue per produk R$ 297 / 354 / 404 / **603**. Unit hampir datar dari kuartil 2 ke 4 sementara harga dan revenue naik ≈ 2×; korelasi nama vs unit 0,009.

### 7. Negative finding — basket lintas kategori
| Basis | Order multi-produk | Lintas ≥ 2 kategori | % | Satu kategori |
|---|---:|---:|---:|---:|
| Item Population | **3.236** | **786** | **24,29** | 2.450 |
| Revenue Population | 3.231 | 785 | 24,30 | 2.446 |

- Menurut jumlah kategori pada order multi-produk: 1 kategori 2.450, 2 kategori 768, 3 kategori 18.
- Order lintas kategori hanya **0,80%** dari seluruh order ber-item (786 dari 98.666).
- **Pasangan terbesar:** bed_bath_table + furniture_decor **70 order**, bed_bath_table + home_comfort 43, furniture_decor + housewares 24, bed_bath_table + housewares 20, baby + cool_stuff 20, baby + toys 19, furniture_decor + garden_tools 17, baby + bed_bath_table 17, health_beauty + sports_leisure 14, housewares + unknown 14. Sepuluh pasangan teratas hanya 258 order (32,8% dari order lintas kategori); pasangan terbesar 8,9%. Pasangan didominasi kelompok rumah tangga/dekorasi dan kelompok bayi.
- Kesimpulan: **cross-sell lintas kategori kecil**; temuan ini disajikan sebagai negative finding, bukan narasi basket/cross-sell.

## Hipotesis Kandidat (untuk Tahap 15–17 dan 21, belum diuji)
- **H-C1** Revenue sangat terkonsentrasi pada segelintir kategori (top-10 = 62,4%; 52 kategori ≥ 100 order = 99,0%); 22 kategori < 100 order tidak layak dianalisis per rate. → Tahap 21
- **H-C2** Peringkat volume berbeda dari peringkat nilai: bed_bath_table (order #1, revenue #3), watches_gifts (order #7, revenue #2), telephony (order #8, revenue #14). Kuadran harga tinggi & volume tinggi memuat 17 kategori dan 68,5% revenue. → Tahap 21
- **H-C3** Ongkir per item mengikuti berat (r = 0,78) sedangkan freight % mengikuti harga (r = −0,42): barang ringan-murah menanggung rasio ongkir tertinggi. → Tahap 21
- **H-C4** Selera regional moderat: Timur Laut over-index pada telephony/health_beauty/watches_gifts; bed_bath_table terkonsentrasi di SP (9,25% vs 5,07% di BA). → Tahap 16
- **H-C5** Kenaikan revenue per produk seiring foto/deskripsi sebagian besar sejalan dengan harga; unit hampir tidak berubah (r = 0,004), kecuali pada tertil harga murah. **Tidak boleh menjadi rekomendasi "tambah foto".** → Tahap 21 (batasan)
- **H-C6** Cross-sell lintas kategori kecil (0,8% order; pasangan terbesar 70 order). → Tahap 21 (negative finding)

## Output
- Tabel: `category_summary` (74 kategori), `category_findings` (23 metrik)
- `data/processed/13_category_summary.parquet` (74 baris), `13_category_findings.parquet` (23 baris); ter-ignore git

## Assumptions
- Item Revenue per kategori = `SUM(price)` pada Revenue Population (alokasi nyata); unit = jumlah baris item (bukan `qty_units`).
- Analisis rate per kategori hanya untuk kategori ≥ 100 order (D6); `unknown` dilaporkan sebagai kategori sendiri.
- Ambang matriks: median harga item Revenue Population (R$ 74,90) dan median order antar kategori ≥ 100 order (563).
- Analisis listing memakai produk yang terjual ≥ 1 kali di Revenue Population; `photos_qty` NULL dipisahkan sebagai "tidak ada data"; tertil harga berdasarkan harga rata-rata per produk.
- Basket: pasangan kategori dihitung dari pasangan order-kategori unik pada Item Population (basis addendum).

## Batasan data
- Kategori dengan < 100 order (22) tidak dianalisis per rate; beberapa kolom pada tabel ringkas (mis. median harga untuk garden_tools, baby, perfumery) tidak tampil pada output run dan tidak diklaim.
- Atribut listing tidak dikontrol terhadap kategori, seller, atau musim; semua tetap asosiasi.
- Berat dan dimensi produk tidak tersedia untuk sebagian kecil produk (berat NULL untuk 6 produk).
- Pasangan kategori hanya mencakup order multi-produk (3,3% order), sehingga tidak mewakili perilaku belanja secara umum.
- Perbandingan Item Population vs Revenue Population hanya relevan untuk kategori `unknown` dan basket; seluruh KPI memakai Revenue Population.

## Kesimpulan
Revenue per kategori reconcile penuh ke Item Revenue terkunci (R$ 13.494.400,74), dan selisih kategori `unknown` terjelaskan oleh basis populasi (1,323% vs 1,321%). Penjualan terkonsentrasi pada segelintir kategori bervolume dan bernilai besar, dengan peringkat volume yang berbeda dari peringkat nilai. Ongkir mengikuti berat, rasio ongkir mengikuti harga, selera regional bervariasi moderat, dan atribut listing berasosiasi dengan penjualan terutama lewat harga sehingga tidak boleh dijadikan rekomendasi. Basket lintas kategori sangat kecil (negative finding).

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** fokus manajemen kategori pada 17 kategori kuadran harga/volume tinggi; ongkir untuk barang ringan-murah (electronics, telephony) menjadi hambatan relatif; larangan tafsir "tambah foto" sebagai rekomendasi; cross-sell lintas kategori bukan prioritas.
