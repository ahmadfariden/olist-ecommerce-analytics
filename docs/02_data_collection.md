# 02 — Data Collection

**File SQL:** `sql/02_data_collection.sql`
**Tahap roadmap:** 2
**Checkpoint:** `feat: add data collection script (DuckDB ingestion, 9 raw tables)`

---

## Input

- 9 file CSV Olist Brazilian E-Commerce di `data/raw/` (read-only, tidak di-commit):
  `olist_customers_dataset.csv`, `olist_geolocation_dataset.csv`, `olist_order_items_dataset.csv`,
  `olist_order_payments_dataset.csv`, `olist_order_reviews_dataset.csv`, `olist_orders_dataset.csv`,
  `olist_products_dataset.csv`, `olist_sellers_dataset.csv`, `product_category_name_translation.csv`.
- Database DuckDB lokal `olist.duckdb` di root proyek (tidak di-commit).

## Proses Analisis

1. Ingestion 1 CSV = 1 tabel `raw_*` dengan `read_csv(..., header = true, ALL_VARCHAR = TRUE)`.
   `raw_order_reviews` tambahan `quote = '"'` dan `escape = '"'`.
2. Inventory tabel yang terbentuk di schema `main`.
3. Verifikasi row count dan jumlah kolom terhadap angka referensi roadmap.
4. Verifikasi total kolom (52) dan tipe kolom (semua `VARCHAR`).
5. Ekstraksi skema kolom dari `information_schema.columns`.
6. Cek duplikasi primary key sesuai Grain Matrix.
7. Orphan check dasar (child → parent) untuk relasi kunci di Join Map.

## Temuan

| Pengecekan | Hasil |
|---|---|
| Jumlah tabel `raw_*` | 9 tabel terbentuk |
| Row count & jumlah kolom vs roadmap | 9/9 tabel **PASS** |
| Total kolom | 52 — **PASS** |
| Kolom non-VARCHAR | 0 — **PASS** |
| Duplikasi PK (8 pengecekan grain) | 0 di semua tabel |
| Orphan (6 relasi kunci) | 0 di semua relasi |

Detail row count:

| Tabel | Baris | Kolom |
|---|---:|---:|
| `raw_category_translation` | 71 | 2 |
| `raw_customers` | 99.441 | 5 |
| `raw_geolocation` | 1.000.163 | 5 |
| `raw_order_items` | 112.650 | 7 |
| `raw_order_payments` | 103.886 | 5 |
| `raw_order_reviews` | 99.224 | 7 |
| `raw_orders` | 99.441 | 8 |
| `raw_products` | 32.951 | 9 |
| `raw_sellers` | 3.095 | 4 |

Catatan tambahan:
- Nama kolom yang tampil di output sesuai `docs/data_dictionary_raw.md`, termasuk ejaan asli `product_name_lenght` dan `product_description_lenght` di `raw_products`.
- Kunci `(review_id, order_id)` di `raw_order_reviews` tidak duplikat. Ini konsisten dengan grain matrix, tetapi tidak bertentangan dengan catatan roadmap bahwa sebagian `review_id` muncul di lebih dari satu order; analisis review yang tidak bersih dilakukan di Tahap 4.
- Baris output skema untuk sebagian kolom (`raw_order_payments`, `raw_order_reviews`, dan `raw_orders.order_id`) terpotong oleh tampilan DuckDB CLI ("40 shown"). Jumlah kolom per tabel sudah tervalidasi lewat check row/column count, jadi ini tidak memengaruhi hasil.

## Output

- `olist.duckdb` berisi 9 tabel `raw_*` (source of truth untuk seluruh tahap berikutnya).
- `sql/02_data_collection.sql` (idempotent, aman dijalankan ulang).
- `docs/data_dictionary_raw.md` (inventori, kolom, Grain Matrix, Join Map).

## Assumptions

- CSV di `data/raw/` adalah salinan asli dari Kaggle dan tidak diubah manual.
- Angka baris/kolom di roadmap dianggap sebagai referensi yang benar; hasil ingestion cocok 100%.
- DuckDB dijalankan dari root proyek sehingga path relatif `data/raw/...` valid.
- Semua kolom dimuat sebagai `VARCHAR`; casting tipe eksplisit dilakukan di Tahap 5.

## Batasan Data

- Pengecekan di tahap ini sengaja dasar: hanya integritas ingestion, duplikasi PK, dan orphan satu arah (child → parent). Pengecekan sebaliknya (mis. order tanpa item, order tanpa payment/review) dan kualitas nilai dikerjakan di Tahap 4 dan 6.
- `raw_geolocation` tidak punya primary key (grain = titik koordinat, bukan zip); deduplikasi ke 1 baris per zip prefix dilakukan di tahap cleaning.
- Tidak ada pengecekan format tanggal, nilai kosong, atau outlier di tahap ini.
- Cek lisensi dataset di halaman Kaggle belum dilakukan; atribusi di README diselesaikan sebelum publish.

## Kesimpulan

Ingestion 9 CSV ke tabel `raw_*` berhasil dan seluruh verifikasi (row count, jumlah kolom, tipe kolom, duplikasi PK, orphan relasi kunci) lolos tanpa temuan. Raw layer siap dipakai sebagai source of truth untuk Tahap 3 (Business Understanding) dan Tahap 4 (Data Profiling).

**Definition of Done Tahap 2:**
- [x] 9 raw CSV masuk ke `data/raw/`
- [x] Ingestion ke DuckDB berhasil (9 tabel `raw_*`), row count cocok dengan inventori
- [x] Grain Matrix & Join Map terdokumentasi di `docs/data_dictionary_raw.md`
- [ ] Git checkpoint sudah di-commit
