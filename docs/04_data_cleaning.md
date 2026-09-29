# 04 — Data Cleaning & Data Treatment

> Pendamping `sql/04_data_cleaning.sql`. Hasil dijalankan di DuckDB lokal. Log keputusan lengkap per tabel ada di `docs/assumptions.md`.

## Input
- Tabel `raw_*` di `data/olist.duckdb` (Tahap 2, tidak diubah)
- Temuan masalah data dari `docs/profiling_findings.md` (Tahap 4)

## Proses Analisis
1. **Staging (`stg_*`)**: cast tipe dengan `TRY_CAST` + standardisasi, 1 baris per baris raw. Uang → `DECIMAL(12,2)`; zip tetap VARCHAR; ejaan `lenght` dirapikan; whitespace review di-trim lalu string kosong → NULL.
2. **Geolocation**: buang duplikat penuh → `geo_dedup`; koordinat di luar kotak Brasil dikeluarkan dari rata-rata → `dim_geo_zip` (1 baris per zip).
3. **Tabel clean**: `category_translation_clean` (typo + 2 mapping manual), `products_clean`, `sellers_clean`, `order_items_clean`, `order_payments_clean`, `order_reviews_clean` (dedup 1 review/order), `dim_customer`.
4. **`orders_clean`**: flag anomali timestamp + Analytical Flags, tabel anak di-pre-aggregate ke grain `order_id` dulu (Fan-out Guard).
5. **Verifikasi**: 86 metrik ke tabel `clean_findings` (PASS / CHECK / INFO).
6. **Ekspor**: 9 file `data/processed/04_*.parquet`.

## Temuan

### Ringkasan verifikasi

**86 metrik: 79 PASS, 0 CHECK, 7 INFO** (INFO = tidak punya angka acuan).

### Row count & grain

| Tabel | Baris | Catatan |
|---|---:|---|
| `stg_*` (9 tabel) | = raw | 99.441 / 99.441 / 112.650 / 103.886 / 99.224 / 32.951 / 3.095 / 71 / 1.000.163 |
| `geo_dedup` | 738.332 | 1.000.163 − 261.831 duplikat penuh |
| `order_reviews_clean` | 98.673 | 99.224 − 551 review kembar |
| `orders_clean` / `order_items_clean` / `order_payments_clean` | 99.441 / 112.650 / 103.886 | = raw |
| `products_clean` / `sellers_clean` | 32.951 / 3.095 | = raw |
| `dim_customer` | 96.096 | 1 baris per `customer_unique_id` |
| `dim_geo_zip` | 19.015 | 1 baris per zip prefix |
| `category_translation_clean` | 73 | 71 + 2 mapping manual |

Duplikat kunci = 0 di seluruh tabel clean (`order_id`, `(order_id, order_item_id)`, `(order_id, payment_sequential)`, `zip`, `product_id`, `category_pt`). NULL setelah `TRY_CAST` sama dengan NULL di raw untuk orders (4.908), products (1.838), items, payments, dan reviews (0 gagal cast).

### Flag anomali & populasi analitik

| Flag / populasi | n | Acuan |
|---|---:|---|
| `flag_carrier_before_purchase` | 166 | ✔ profiling |
| `flag_carrier_before_approved` | 1.359 | ✔ |
| `flag_customer_before_carrier` | 23 | ✔ |
| `flag_delivered_no_date` | 8 | ✔ |
| `flag_canceled_has_delivery_date` | 6 | ✔ |
| `is_canceled` / `is_unavailable` | 625 / 609 | ✔ |
| `has_items` | 98.666 | ✔ |
| Revenue Population (`is_revenue_order`) | 98.199 | ✔ |
| Delivered Population (`is_delivered_complete`) | 96.470 | ✔ |
| `is_late` (tanggal, D1) | 6.534 | ✔ (6,773%) |
| `is_late_ts_sensitivity` (timestamp) | 7.826 | ✔ (8,112%) |
| Review Population (`has_review`) | 98.673 | ✔ |
| `is_multi_seller` / `is_multi_payment_type` | 1.278 / 2.246 | ✔ |
| Single-Seller Population (D10) | 96.922 | ✔ |
| Payment Population | 99.440 | ✔ |
| `in_analysis_window` | 99.092 | INFO (349 di luar window) |

Analysis Window × status: delivered 96.211, shipped 1.097, unavailable 602, canceled 580, processing 299, invoiced 296, created 5, approved 2. Di luar window (349): delivered 267, canceled 45, invoiced 18, shipped 10, unavailable 7, processing 2.

### Treatment per tabel (ringkas)

| Tabel | Hasil |
|---|---|
| `order_items` | `flag_zero_freight` 383; `flag_shipping_limit_invalid` 4; 7.088 pasangan order-produk `qty_units` > 1 |
| `order_payments` | `flag_zero_payment` 9; `flag_payment_not_defined` 3; `flag_zero_installments` 2; 80 order `flag_no_first_payment` |
| `order_reviews` | 547 order `n_reviews_raw` > 1 dedup ke 1; Avg Score **4,0864**; 27 message whitespace-only → NULL; `flag_review_before_purchase` 71 (74 sebelum dedup); `has_comment` 40.748 |
| `products` | 610 kategori `unknown`; 0 `category_en` NULL setelah mapping; `weight_g` NULL 6 (4 nol + 2 null) |
| `category_translation` | Typo terdampak 4 kategori (`home_comfort`, `construction_tools_tools`, `construction_tools_garden`, `fashion_female_clothing`); 2 mapping manual |
| `dim_customer` | `is_repeat_customer` (≥24 jam) **2.122**; `is_repeat_raw` 2.997; `flag_multi_state` 39; first ≠ latest state 39 |
| `dim_geo_zip` | 5 zip tanpa koordinat valid; customer tanpa koordinat **279**, seller **7** |

### Fan-out & revenue

- `SUM(price)` setelah join items → `orders_clean` = `SUM(price)` items (selisih 0).
- `SUM(payment_value)` setelah join payments → `orders_clean` = `SUM(payment_value)` payments (selisih 0).
- Join customers → `dim_geo_zip` tetap 99.441 baris.
- Item Revenue pada Revenue Population = **R$ 13.494.400,74** (sama dengan roadmap).
- Rekonsiliasi item+freight vs payment (DECIMAL eksak, 98.665 order): **98.362 (≤0,01) / 54 (0,01–1) / 249 (>1)** → 99,693% selisih ≤0,01.

### Seller city (diagnostik)

28 seller dibersihkan aturan (2 menjadi `unknown`). 43 nilai kota lain tidak ada di kosakata geolocation: 6 berpola akhiran state/backslash (28 + 6 = 34, sama dengan angka roadmap) dan ±37 salah ketik, nama state sebagai kota, spasi ganda, aksen, atau nama valid di luar kosakata. Belum ditangani.

## Output
- Tabel: `stg_*` (9), `geo_dedup`, `dim_geo_zip`, `dim_customer`, `category_translation_clean`, `products_clean`, `sellers_clean`, `order_items_clean`, `order_payments_clean`, `order_reviews_clean`, `orders_clean`, `clean_findings`
- `data/processed/04_*.parquet` (9 file, ter-ignore git): `orders_clean` 99.441 · `order_items_clean` 112.650 · `order_payments_clean` 103.886 · `order_reviews_clean` 98.673 · `products_clean` 32.951 · `category_translation_clean` 73 · `sellers_clean` 3.095 · `dim_customer` 96.096 · `dim_geo_zip` 19.015

## Assumptions
- Flag, jangan hapus: baris yang keluar hanya duplikat penuh geolocation (261.831) dan review kembar (551).
- Null timestamp di orders dipertahankan (struktural), tidak diimputasi.
- Order in-flight tetap masuk Revenue Population (D2); sensitivity delivered-only dilaporkan di Tahap 6.
- Dedup review (D3): `review_answer_ts` terbaru → `review_creation_ts` terbaru → `review_id` terbesar.
- `seller_state` adalah sumber kebenaran lokasi seller (D8); kota bukan key analisis.
- Uang memakai `DECIMAL(12,2)`, sehingga angka rekonsiliasi eksak (koreksi atas A4 di roadmap dijelaskan di `docs/assumptions.md`).

## Batasan data
- Seller city belum sepenuhnya bersih (lihat diagnostik di atas).
- `qty_units` berulang di tiap baris pasangan order-produk; jangan di-SUM (unit = `COUNT(*)`).
- Jarak seller–customer nanti berupa jarak antar-centroid zip; 279 customer dan 7 seller tanpa koordinat.
- Order in-flight di bulan lama kemungkinan berstatus basi (mis. 2017-01: 4,63%).
- Hipotesis penyebab beda 77 order di rekonsiliasi (roadmap vs DECIMAL) belum diuji langsung.

## Kesimpulan
Cleaning selesai tanpa membuang baris selain dua kelompok yang tercatat. Seluruh flag dan populasi analitik cocok dengan angka profiling dan roadmap, fan-out guard lolos, dan output parquet tersimpan. Data siap masuk Tahap 6 (Data Validation & KPI Lock).
