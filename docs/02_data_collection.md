# 02 — Data Collection

> File pendamping `sql/02_data_collection.sql`. Hasil dijalankan manual di DuckDB lokal.

## Input
- 9 CSV Olist di `data/raw/` (read-only, tidak di-commit)
- Database: `data/olist.duckdb`

## Proses Analisis
1. Ingestion 1 CSV = 1 tabel `raw_*` dengan `ALL_VARCHAR = TRUE`; `raw_order_reviews` memakai `quote='"'` dan `escape='"'`.
2. Row count dibandingkan dengan inventori roadmap.
3. Jumlah kolom per tabel (ekspektasi total 52).
4. Cek duplikat primary key sesuai Grain Matrix.
5. Cek orphan key sesuai Join Map.
6. Sanity check parsing (zip berawalan 0, komentar review multi-baris).

## Temuan

**Row count — 9/9 PASS**

| Tabel | Row count | Expected | Status |
|---|---:|---:|---|
| raw_category_translation | 71 | 71 | PASS |
| raw_customers | 99.441 | 99.441 | PASS |
| raw_geolocation | 1.000.163 | 1.000.163 | PASS |
| raw_order_items | 112.650 | 112.650 | PASS |
| raw_order_payments | 103.886 | 103.886 | PASS |
| raw_order_reviews | 99.224 | 99.224 | PASS |
| raw_orders | 99.441 | 99.441 | PASS |
| raw_products | 32.951 | 32.951 | PASS |
| raw_sellers | 3.095 | 3.095 | PASS |

**Jumlah kolom:** seluruh tabel sesuai ekspektasi; total 52 dari 52.

**Duplikat primary key:** 0 di seluruh 8 tabel yang punya PK (`geolocation` tidak punya PK). Grain Matrix terkonfirmasi, termasuk `order_reviews (review_id, order_id)`.

**Orphan key:** 0 di seluruh 6 relasi Join Map (`orders→customers`, `order_items→orders/products/sellers`, `order_payments→orders`, `order_reviews→orders`).

**Sanity check parsing:**
- Zip prefix berawalan 0 utuh (mis. `09790`, `01151`, `08775`) — `ALL_VARCHAR` bekerja.
- Komentar review berbahasa Portugis (aksen `é`, `ê`) terbaca benar dan komentar panjang tidak terpotong — `quote`/`escape` bekerja.
- Timestamp dan angka (`price`, `freight_value`) masih VARCHAR seperti dirancang.

## Output
- 9 tabel `raw_*` di `data/olist.duckdb`
- `docs/data_dictionary_raw.md` (Grain Matrix, Join Map, kolom per tabel)

## Assumptions
- File CSV tidak dimodifikasi setelah diunduh dari Kaggle.
- Ekspektasi row count berasal dari inventori roadmap Tahap 2.

## Batasan data
- Semua kolom masih VARCHAR; belum ada validasi tipe/nilai (Tahap 4–5).
- Cek orphan/duplikat di sini hanya cepat; profiling menyeluruh ada di Tahap 4.
- Orphan = 0 hanya berlaku dari sisi child → parent. Order tanpa item, order tanpa payment, dan order tanpa review belum dicek di tahap ini.
- Lisensi dataset (CC BY-NC-SA 4.0) perlu diverifikasi ulang di Kaggle sebelum publish.

## Kesimpulan
Ingestion berhasil dan raw data utuh: 9 tabel, 52 kolom, row count cocok, grain dan relasi sesuai dokumentasi. Data siap masuk profiling (Tahap 4). Tahap 2 memenuhi seluruh Definition of Done.
