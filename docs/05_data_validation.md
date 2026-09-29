# 05 — Data Validation & KPI Lock

> Pendamping `sql/05_data_validation.sql`. Hasil dijalankan di DuckDB lokal. Definisi KPI lengkap ada di `docs/methodology.md`.

## Input
- Tabel hasil Tahap 5: `stg_*`, `orders_clean`, `order_items_clean`, `order_payments_clean`, `order_reviews_clean`, `products_clean`, `dim_customer`, `dim_geo_zip`
- Tabel `raw_*` (sebagai pembanding)

## Proses Analisis
1. Structural: row count `stg_*` = raw, grain (PK unik), NULL setelah cast = NULL raw.
2. Referential: orphan key, 1:1 order–customer, terjemahan kategori, order tanpa item vs Revenue Population, coverage koordinat.
3. Fan-out: `SUM(price)`, `SUM(freight_value)`, `SUM(payment_value)` dan jumlah order setelah join; tabel anak di-pre-aggregate ke grain `order_id`.
4. Business: status vs null, flag anomali vs profiling, `SUM(is_canceled)`/`SUM(is_unavailable)`, konsistensi `is_revenue_order` dihitung ulang dari sumber.
5. Revenue: rekonsiliasi item+freight vs payment pada Reconcilable Population (DECIMAL eksak).
6. KPI: Order, AOV, Delivery, Review, Customer/Repeat, dibandingkan dengan angka roadmap.
7. Gate (semua rule HARD harus PASS) dan tabel `kpi_lock`; ekspor `05_validation_summary.parquet`.

Severity: **HARD** = gate, **KPI** = nilai KPI vs roadmap, **INFO** = informasi tanpa PASS/FAIL.

## Temuan

### Ringkasan

| Severity | Status | n rule |
|---|---|---:|
| HARD | PASS | 61 |
| KPI | PASS | 25 |
| INFO | PASS | 2 |
| INFO | INFO | 8 |

**`GATE PASS`: 61 dari 61 rule HARD lolos; 25 dari 25 rule KPI cocok dengan roadmap.** Total 96 rule.

### Structural, referential, fan-out, business (semua PASS)
- Row count 9 tabel `stg_*` = raw; `geo_dedup` 738.332; `order_reviews_clean` 98.673.
- Grain: 0 duplikat pada `order_id`, `(order_id, order_item_id)`, `(order_id, payment_sequential)`, `customer_unique_id`, `product_id`, `zip`.
- NULL setelah cast = NULL raw: orders 4.908, products 1.838, items/payments/reviews 0.
- Orphan 0 pada semua relasi; tidak ada order tanpa customer maupun customer tanpa order; 0 produk tanpa terjemahan setelah mapping manual.
- 775 order tanpa item terkonfirmasi, 0 di antaranya masuk Revenue Population.
- Fan-out: selisih `SUM(price)`, `SUM(freight_value)`, `SUM(payment_value)` = 0; jumlah baris dan `COUNT(DISTINCT order_id)` tetap 99.441 setelah join payments + reviews; 0 order dengan >1 baris review.
- Business: 0 `shipped` dengan tanggal terima; 8 `delivered` tanpa tanggal terima (terdokumentasi); flag timestamp 166 / 1.359 / 23; `is_canceled` 625; `is_unavailable` 609; `is_revenue_order` konsisten dengan sumber (0 baris beda); 0 status di luar 8 nilai.
- Coverage koordinat (INFO): 279 baris customer dan 7 baris seller tanpa koordinat, sesuai dokumentasi.

### Rekonsiliasi revenue (Reconcilable Population, n = 98.665)

| Selisih |item+freight − payment| | n order |
|---|---:|
| ≤ 0,01 | 98.362 |
| 0,01 – 1 | 54 |
| > 1 | 249 |

- **99,693%** order selisih ≤ 0,01, lolos toleransi ≥ 99,6%. Selisih maksimum R$ 182,81.
- 249 order selisih > 1: **232** payment > item+freight (total excess R$ 3.064,76; **semuanya melibatkan credit_card**) dan **17** payment < item+freight (total shortfall R$ 197,57).
- Excess R$ 3.064,76 ≈ 0,02% dari Payment Total (R$ 16.008.872,12).
- Dicatat sebagai limitation (D9), tidak dipaksa cocok. Pola ke arah cicilan konsisten dengan biaya/bunga tetapi datanya tidak memuat bunga, jadi tetap hipotesis.

### Sensitivity in-flight (D2)
Item Revenue order berstatus bukan `delivered` di Revenue Population: R$ 272.902,63 = **2,02%**; sensitivity delivered-only = **97,98%**.

### Nilai KPI terkunci

| KPI | Nilai | Populasi / denominator |
|---|---:|---|
| Item Revenue | R$ 13.494.400,74 | Revenue Population |
| Freight Revenue | R$ 2.241.126,29 | Revenue Population |
| GMV incl. Freight | R$ 15.735.527,03 | Revenue Population |
| Payment Total | R$ 16.008.872,12 | Payment Population (hanya rekonsiliasi) |
| Total Orders | 99.441 | Order Population |
| Revenue Orders | 98.199 | Revenue Population |
| AOV | R$ 137,42 | Item Revenue / Revenue Orders |
| AOV incl. Freight | R$ 160,24 | (Item + Freight) / Revenue Orders |
| Cancellation Rate | 0,629% | 625 / 99.441 |
| Unavailable Rate | 0,612% | 609 / 99.441 |
| Late Rate (tanggal, D1) | 6,773% | 6.534 / 96.470 Delivered Orders |
| On-Time Rate | 93,227% | Delivered Orders |
| Late Rate versi timestamp (sensitivity) | 8,112% | 7.826 / 96.470 |
| Avg Review Score (dedup, D3) | 4,0864 | Review Population (98.673) |
| Repeat Rate (≥24 jam, D5) | 2,208% | 2.122 / 96.096 Customer Population |
| 90-day Repeat Rate | 1,302% | 1.009 / 77.482 (cohort first order 2017-01..2018-05) |
| Repeat mentah (≥2 order) | 3,119% | hanya Data Quality |
| Single-Seller Population (D10) | 96.922 | Revenue Population, non multi-seller |
| Analysis Window Population | 99.092 | 349 order di luar window |

Definisi 90-day Repeat Rate yang dipakai (repeat 24 jam sampai 90 hari setelah order pertama; cohort 2017-01..2018-05) menghasilkan 1,302%, sama dengan roadmap.

### Angka yang baru muncul (INFO)
Freight Revenue, GMV, Payment Total, AOV (kedua varian), Cancellation Rate, Unavailable Rate. Freight ≈ 16,6% dari Item Revenue. Payment Total tidak boleh dibandingkan langsung dengan GMV: populasinya berbeda (99.440 order ber-payment vs 98.199 Revenue Orders), dan payment dari 775 order tanpa item saja sudah R$ 162.591,95.

## Output
- Tabel: `validation_results`, `kpi_lock`
- `data/processed/05_validation_summary.parquet` (96 baris; ter-ignore git)

## Assumptions
- Ekspektasi berasal dari roadmap v1.6 dan hasil Tahap 4–5.
- Rekonsiliasi memakai `DECIMAL(12,2)`, sehingga bucket 98.362 / 54 / 249 eksak (koreksi atas A4 lama dijelaskan di `docs/methodology.md`).
- 90-day Repeat Rate: repeat = ada order ≥24 jam dan ≤90 hari setelah order pertama.
- Rule HARD gagal berarti treatment Tahap 5 dianggap gagal; tidak ada yang gagal.

## Batasan data
- Selisih 249 order pada rekonsiliasi dicatat sebagai limitation, bukan dikoreksi.
- Hubungan cicilan-selisih hanya hipotesis (tidak ada data bunga).
- Order in-flight di bulan lama kemungkinan berstatus basi; ditangani lewat sensitivity delivered-only (D2).
- Beberapa KPI (mis. AOV, Cancellation Rate) baru pertama kali dihitung, jadi belum punya angka acuan independen.

## Kesimpulan
Dataset hasil cleaning valid: struktur, relasi, fan-out, konsistensi flag, dan rekonsiliasi revenue lolos, dan 16 KPI dikunci dengan definisi, populasi, dan denominator eksplisit. Tidak ada open issue, sehingga Definition of Ready Part 3 (EDA) terpenuhi.
