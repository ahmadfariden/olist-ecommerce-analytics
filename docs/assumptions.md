# Assumptions & Data Treatment Log

> Dokumen hidup: tiap tahap menambah bagian baru. Saat ini berisi **Tahap 5 (Data Cleaning)**, hasil `sql/04_data_cleaning.sql`.
> Prinsip: **flag, jangan hapus.** Satu-satunya baris yang keluar dari data adalah duplikat murni (geolocation) dan review kembar per order, dan keduanya dicatat di bagian "Ledger baris".

## 1. Layering

```
raw_* (ALL_VARCHAR, tidak diubah) → stg_* (cast + standardisasi, 1 baris per baris raw) → *_clean / dim_* (flag + aturan dedup)
```

Hasil verifikasi: **86 metrik, 79 PASS, 0 CHECK, 7 INFO** (INFO = memang tidak punya angka acuan). Row count `stg_*` = `raw_*` untuk 9 tabel; `NULL` setelah `TRY_CAST` sama persis dengan `NULL` di raw (0 gagal cast).

## 2. Ledger baris (baris yang tidak dibawa ke tabel clean)

| Tabel | Baris keluar | Alasan | Bukti |
|---|---:|---|---|
| geolocation → `geo_dedup` | 261.831 | Duplikat penuh (5 kolom raw identik); tidak membawa informasi baru | 1.000.163 − 261.831 = 738.332 ✔ |
| order_reviews → `order_reviews_clean` | 551 | Order dengan >1 review; dipilih 1 review per order (aturan D3 di bawah) | 99.224 − 551 = 98.673 order ber-review ✔ |
| tabel lain | 0 | Semua baris dipertahankan (flag / NULL, bukan dihapus) | Row count clean = raw ✔ |

## 3. Treatment per tabel

### orders → `orders_clean` (1 baris = 1 order, n = 99.441)

| Masalah | Treatment | Alasan | Verifikasi |
|---|---|---|---|
| 3 kolom timestamp null | **Retain NULL**, tidak diimputasi | Null umumnya struktural (mengikuti status) | 160 / 1.783 / 2.965 null, sama dengan raw |
| Urutan tanggal tidak logis | Flag `flag_carrier_before_purchase`, `flag_carrier_before_approved`, `flag_customer_before_carrier`; tidak dihapus | Order tetap valid untuk revenue; hanya durasi tahap terkait yang di-exclude | 166 / 1.359 / 23 ✔ |
| Delivered tanpa tanggal terima; canceled dengan tanggal terima | Flag `flag_delivered_no_date`, `flag_canceled_has_delivery_date` | Konsistensi dicek di Tahap 6 | 8 / 6 ✔ |

### customers → `dim_customer` (1 baris = 1 `customer_unique_id`, n = 96.096)

| Masalah | Treatment | Alasan | Verifikasi |
|---|---|---|---|
| 1 orang = >1 `customer_id`; lokasi ganda (250/122/39) | Kunci `customer_unique_id`; simpan `state/city_first_order` dan `state/city_latest_order` | Analisis repeat pakai first order; profil pelanggan pakai latest order | `flag_multi_state` = 39 ✔; first ≠ latest state = 39 (semua pelanggan multi-state) |
| Urutan first/latest ambigu (292 pasangan order di detik yang sama) | Urut `ts_purchase`, tie-break `order_id` | Deterministik dan bisa direproduksi | — |
| Definisi repeat | `is_repeat_customer` = ada order ≥24 jam setelah order pertama (D5); `is_repeat_raw` = ≥2 order, hanya metrik Data Quality | Order <24 jam dianggap satu sesi belanja | 2.122 dan 2.997 ✔ |

### order_items → `order_items_clean` (1 baris = 1 unit item, n = 112.650)

| Masalah | Treatment | Alasan | Verifikasi |
|---|---|---|---|
| `freight_value` = 0 | Retain + `flag_zero_freight` | Bisa promo free shipping; tidak diasumsikan salah | 383 ✔ |
| Outlier `price` (7,48% di atas batas IQR, maks 6.735) | **Retain**, tanpa flag | Barang mahal legit; tidak ada indikasi error | — |
| `shipping_limit_date` tahun 2020 | Flag `flag_shipping_limit_invalid` (tahun ≥ 2019); di-exclude hanya dari analisis shipping limit | Order lain di baris itu tetap dipakai | 4 baris ✔ |
| Tidak ada kolom qty | `qty_units` = jumlah baris item per `(order_id, product_id)` | 7.088 pasangan berulang = beli >1 unit | 7.088 ✔ |
| Harga/ongkir tipe VARCHAR | `DECIMAL(12,2)` | Aritmetika uang eksak (lihat bagian 6) | — |

⚠️ `qty_units` nilainya berulang di tiap baris pasangan yang sama. **Jangan di-SUM**; unit terjual = `COUNT(*)` baris item.

### order_payments → `order_payments_clean` (1 baris = 1 pembayaran, n = 103.886)

| Masalah | Treatment | Alasan | Verifikasi |
|---|---|---|---|
| `payment_value` = 0 | Retain + `flag_zero_payment` | Kecil; tidak mempengaruhi tren | 9 ✔ |
| `payment_type = 'not_defined'` | Retain + `flag_payment_not_defined` | Dilaporkan terpisah | 3 ✔ |
| `installments` = 0 | Retain + `flag_zero_installments`; di-exclude dari distribusi cicilan | Nol cicilan tidak bermakna | 2 ✔ |
| Order tanpa `payment_sequential = 1` | Retain + `flag_no_first_payment` (di semua baris payment order itu) | Tetap valid; dicek di Tahap 6 | 80 order ✔ |

### order_reviews → `order_reviews_clean` (1 baris = 1 order ber-review, n = 98.673)

| Masalah | Treatment | Alasan | Verifikasi |
|---|---|---|---|
| 547 order >1 review; 789 `review_id` di >1 order | **Dedup 1 review/order (D3):** ambil `review_answer_ts` terbaru; tie-break `review_creation_ts` terbaru, lalu `review_id` terbesar; simpan `n_reviews_raw` | Aturan tunggal agar skor tidak dobel; `review_id` bukan key yang aman | 547 order n_reviews_raw>1 ✔; Avg Score **4,0864** ✔ |
| Message/title berisi whitespace saja, spasi/newline di tepi | Trim semua whitespace (`^\s+\|\s+$`), string kosong → NULL | `has_comment` akurat | 27 whitespace-only pada message ✔ (lihat bagian 6) |
| Review sebelum purchase | Flag `flag_review_before_purchase`; skor tetap dipakai, timing review di-exclude | Skor tetap informatif | 71 setelah dedup (74 sebelum dedup) |

Order ber-review punya komentar: 40.748 (41,3%).

### products → `products_clean` (1 baris = 1 produk, n = 32.951)

| Masalah | Treatment | Alasan | Verifikasi |
|---|---|---|---|
| 610 kategori NULL | Label `'unknown'` + `flag_category_unknown` | Produk ini tetap punya penjualan; dibuang akan menghilangkan revenue (D7: tampil sebagai kategori sendiri) | 610 ✔ |
| 2 kategori tanpa terjemahan | Mapping manual: `pc_gamer` → `pc_gamer`; `portateis_cozinha_e_preparadores_de_alimentos` → `portable_kitchen_food_preparers` | Menghindari NULL di kategori Inggris | 0 `category_en` NULL ✔ |
| Berat = 0 (4), berat/dimensi NULL (2) | `weight_g` = NULL (`flag_weight_invalid`) | Nol bukan berat fisik valid | 6 `weight_g` NULL ✔ |

### category_translation → `category_translation_clean` (n = 73 = 71 + 2 mapping manual)

Typo diperbaiki di kolom `category_en_clean`; kolom asli `category_en` dipertahankan: `costruction_` → `construction_`, `fashio_` → `fashion_`, `home_confort` → `home_comfort`. Empat kategori terdampak, tidak ada typo tersisa. Dua baris mapping manual bertanda `is_manual_mapping = TRUE`.

### sellers → `sellers_clean` (1 baris = 1 seller, n = 3.095)

Aturan `seller_city_clean`: potong di `/`, `,`, atau ` - ` lalu ambil bagian kiri; email atau angka saja → `'unknown'`; `sbc` → `sao bernardo do campo`; `sp` → `sao paulo`. `seller_state` adalah sumber kebenaran lokasi (D8); kota bukan key analisis seller.

**Hasil:** 28 seller diubah (`flag_city_cleaned`), 2 menjadi `'unknown'` (email dan angka).

**Yang belum ditangani (dicatat sebagai limitation):** diagnostik kosakata menemukan 43 nilai `seller_city_clean` yang tidak ada di kosakata kota geolocation. Rinciannya:
- **6 seller dengan akhiran state / pemisah lain** (`sao paulo sp`, `angra dos reis rj`, `brasilia df`, `aguas claras df`, `andira-pr`, `rio de janeiro \rio de janeiro`). Ditambah 28 seller yang sudah ditangani, jumlahnya **34**, sama dengan angka roadmap. Pola ini belum tercakup aturan; bisa ditambah bila kota mulai dipakai.
- **±37 nilai lain:** salah ketik (`belo horizont`, `floranopolis`, `sao paluo`), nama state/region sebagai kota (`bahia`, `minas gerais`, `santa catarina`, `centro`), spasi ganda (`sao  paulo`), aksen (`são paulo`), atau nama valid yang tidak ada di kosakata geolocation (`ji parana`, `sao miguel d'oeste`, `santa barbara d´oeste`). Tidak diperbaiki.

Dampak analitik nol selama seller dilokasikan lewat `seller_state`. Jika nanti ada analisis per kota seller, wajib pakai tabel mapping eksplisit.

### geolocation → `dim_geo_zip` (1 baris = 1 zip prefix, n = 19.015)

| Aturan | Detail |
|---|---|
| Dedup | Buang duplikat penuh (5 kolom raw identik) → `geo_dedup` 738.332 baris |
| Koordinat valid | Titik di luar kotak kasar Brasil (lat −33,75..5,27; lng −73,99..−34,79) tidak ikut rata-rata; tetap ada di `geo_dedup` dengan `valid_coord = FALSE` |
| Agregasi | `lat`/`lng` = rata-rata titik valid; `city` = modus setelah buang aksen + lower + trim (tie-break alfabet) |
| Zip tanpa titik valid | Tetap ada, `lat`/`lng` NULL: **5 zip** |

**Coverage:** 279 baris customer (278 zip tidak ada di geolocation + 1 zip yang hanya punya koordinat invalid) dan 7 baris seller tanpa koordinat → jarak seller–customer NULL untuk baris tersebut, dilaporkan sebagai coverage. Join customers ke `dim_geo_zip` tidak menambah baris (99.441) ✔.

## 4. Analytical Flags & Populasi (materialized di `orders_clean`)

| Populasi | Flag | n terverifikasi |
|---|---|---:|
| Order Population | — | 99.441 |
| Analysis Window | `in_analysis_window` (2017-01 s.d. 2018-08) | 99.092 |
| Revenue Population | `is_revenue_order` = `has_items` ∧ status ∉ {canceled, unavailable} | 98.199 |
| Delivered Population | `is_delivered_complete` = delivered ∧ tanggal terima ada | 96.470 |
| Review Population | `has_review` (dedup 1/order) | 98.673 |
| Payment Population | order punya payment | 99.440 |
| Cancelled | `is_canceled` | 625 |
| Unavailable | `is_unavailable` | 609 |
| `has_items` | order punya item | 98.666 |
| Single-Seller Population (D10) | Revenue Population ∧ ¬`is_multi_seller` | **96.922** |
| `is_multi_seller` / `is_multi_payment_type` | >1 seller / >1 tipe payment | 1.278 / 2.246 |
| Customer Population | `customer_unique_id` unik (`dim_customer`) | 96.096 |

Late (D1): `is_late` = perbandingan **tanggal** → **6.534** dari 96.470 (Late Rate 6,773%). `is_late_ts_sensitivity` = perbandingan timestamp → 7.826 (8,112%); hanya sensitivity, tidak dipakai sebagai KPI.

Analysis Window: 349 order di luar window (329 di 2016, 20 di 2018-09/10). Status di dalam window: delivered 96.211, shipped 1.097, unavailable 602, canceled 580, processing 299, invoiced 296, created 5, approved 2.

Item Revenue pada Revenue Population = **R$ 13.494.400,74** ✔ (sama dengan angka roadmap, membuktikan cast `DECIMAL` tidak menggeser nilai).

> Flag tidak boleh dipertukarkan: revenue → `is_revenue_order`, delivery → `is_delivered_complete`, kepuasan → `has_review`. Setiap query Tahap 6+ wajib menyebut populasi yang jadi denominator (Aturan Main #5).

## 5. Fan-out guard (diuji di Tahap 5)

- `SUM(price)` setelah join `order_items_clean` → `orders_clean` = `SUM(price)` di items (selisih 0).
- `SUM(payment_value)` setelah join `order_payments_clean` → `orders_clean` = `SUM(payment_value)` di payments (selisih 0).
- Join customers → `dim_geo_zip` tetap 99.441 baris.
- Tabel anak selalu di-pre-aggregate ke grain `order_id` sebelum join ke `orders_clean`.

## 6. Penyimpangan dari roadmap & koreksi evidence

Semua di bawah bersifat **pre-lock** (KPI belum dikunci di Tahap 6), jadi dicatat di sini, bukan di Revision Log.

1. **Uang di-cast ke `DECIMAL(12,2)`** (roadmap hanya menulis `DOUBLE`). Tujuannya rekonsiliasi eksak tanpa artefak floating point.
2. **Rekonsiliasi item+freight vs payment (98.665 order), aritmetika eksak: 98.362 (≤0,01) / 54 (0,01–1) / 249 (>1).** Angka roadmap A4 (98.285 / 131 / 249) tidak terreproduksi. Total 98.416 dan bucket >1 identik, jadi 77 order berpindah bucket. Penyebab yang paling mungkin: selisih tepat 1 sen yang tergeser floating point pada hitungan lama (belum dibuktikan langsung). Angka proyek yang dipakai: **98.362 / 54 / 249 → 99,693% order selisih ≤0,01** (target ≥99,6% tetap lolos). Evidence A4/D9 di roadmap perlu dikoreksi; kesimpulan D9 (selisih tidak dipaksa cocok) tidak berubah.
3. **Trim whitespace review memakai regex**, bukan `TRIM` bawaan DuckDB yang hanya membuang spasi. Terbukti: pola `^\s*$` menemukan **27** pesan whitespace-only (sesuai roadmap), sedangkan `TRIM` hanya menemukan 9.
4. **Kolom tambahan** yang tidak ada di roadmap: `is_late_ts_sensitivity`, `n_items`, `n_sellers`, `n_payment_types`, `n_reviews_raw`, dan atribut customer (`customer_unique_id`, zip, kota, state) di `orders_clean`; `flag_payment_not_defined`, `flag_weight_invalid`, `flag_category_unknown`, `flag_multi_state`, `is_repeat_raw`. Semua bersifat turunan dan tidak mengubah populasi.
5. **`category_translation_clean` berisi 73 baris** (71 + 2 mapping manual), bukan 71.
6. **`answered_before_delivery`** (D4) **belum** dibuat di Tahap 5; dibuat di `fact_reviews` (Tahap 8) sesuai roadmap.

## 7. Limitations

- Seller city belum sepenuhnya bersih (lihat bagian sellers); tidak dipakai sebagai key.
- Order in-flight pada bulan lama kemungkinan berstatus basi (mis. 2017-01: 4,63%); ditangani lewat sensitivity delivered-only (D2) di Tahap 6.
- Rata-rata koordinat per zip adalah perkiraan; jarak seller–customer adalah jarak antar-centroid zip, bukan jarak alamat.
- 5 zip tidak punya koordinat valid; 279 customer dan 7 seller tanpa koordinat.
- Hipotesis penyebab beda 77 order di rekonsiliasi (poin 2, bagian 6) belum diuji dengan query.

## 8. Output

`data/processed/04_*.parquet` (ter-ignore git), jumlah baris: `orders_clean` 99.441 · `order_items_clean` 112.650 · `order_payments_clean` 103.886 · `order_reviews_clean` 98.673 · `products_clean` 32.951 · `category_translation_clean` 73 · `sellers_clean` 3.095 · `dim_customer` 96.096 · `dim_geo_zip` 19.015.
