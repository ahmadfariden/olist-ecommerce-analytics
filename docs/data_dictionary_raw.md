# Data Dictionary — Raw Layer (Olist)

> Dokumen ini mendeskripsikan 9 tabel `raw_*` **apa adanya** dari CSV (semua kolom `VARCHAR`).
> Tipe data sebenarnya ditetapkan lewat casting eksplisit di Tahap 5 (`sql/04_data_cleaning.sql`).
> Sumber angka baris/kolom: `sql/02_data_collection.sql` (section 3).

## 1. Raw Data Governance

- CSV disimpan di `data/raw/`, **read-only** dan **tidak di-commit** (lihat `.gitignore`).
- Seluruh proses berikutnya membaca dari tabel `raw_*` di DuckDB (`olist.duckdb`), bukan dari CSV.
- Semua kolom dimuat `ALL_VARCHAR = TRUE`.
- `raw_order_reviews` dimuat dengan `quote='"'` dan `escape='"'`.
- Tabel `raw_*` tidak pernah di-UPDATE / DELETE.

## 2. Inventori Tabel

| Tabel raw | File CSV | Baris | Kolom |
|---|---|---:|---:|
| `raw_customers` | olist_customers_dataset.csv | 99.441 | 5 |
| `raw_geolocation` | olist_geolocation_dataset.csv | 1.000.163 | 5 |
| `raw_order_items` | olist_order_items_dataset.csv | 112.650 | 7 |
| `raw_order_payments` | olist_order_payments_dataset.csv | 103.886 | 5 |
| `raw_order_reviews` | olist_order_reviews_dataset.csv | 99.224 | 7 |
| `raw_orders` | olist_orders_dataset.csv | 99.441 | 8 |
| `raw_products` | olist_products_dataset.csv | 32.951 | 9 |
| `raw_sellers` | olist_sellers_dataset.csv | 3.095 | 4 |
| `raw_category_translation` | product_category_name_translation.csv | 71 | 2 |

Total: 52 kolom di 9 tabel.

> ✅ Verifikasi: hasil section 3 di `02_data_collection.sql` harus PASS untuk seluruh tabel sebelum tahap ini dicentang.

## 3. Kolom per Tabel

> Nama kolom ditulis persis seperti di CSV Olist (termasuk ejaan `lenght` di `raw_products`).
> Setelah menjalankan section 4 di SQL, cocokkan daftar ini dengan hasil `information_schema.columns`.

**`raw_customers`** — `customer_id`, `customer_unique_id`, `customer_zip_code_prefix`, `customer_city`, `customer_state`

**`raw_geolocation`** — `geolocation_zip_code_prefix`, `geolocation_lat`, `geolocation_lng`, `geolocation_city`, `geolocation_state`

**`raw_order_items`** — `order_id`, `order_item_id`, `product_id`, `seller_id`, `shipping_limit_date`, `price`, `freight_value`

**`raw_order_payments`** — `order_id`, `payment_sequential`, `payment_type`, `payment_installments`, `payment_value`

**`raw_order_reviews`** — `review_id`, `order_id`, `review_score`, `review_comment_title`, `review_comment_message`, `review_creation_date`, `review_answer_timestamp`

**`raw_orders`** — `order_id`, `customer_id`, `order_status`, `order_purchase_timestamp`, `order_approved_at`, `order_delivered_carrier_date`, `order_delivered_customer_date`, `order_estimated_delivery_date`

**`raw_products`** — `product_id`, `product_category_name`, `product_name_lenght`, `product_description_lenght`, `product_photos_qty`, `product_weight_g`, `product_length_cm`, `product_height_cm`, `product_width_cm`

**`raw_sellers`** — `seller_id`, `seller_zip_code_prefix`, `seller_city`, `seller_state`

**`raw_category_translation`** — `product_category_name`, `product_category_name_english`

## 4. Grain Matrix

| Tabel | Grain (1 baris = ...) | Primary key | Relasi ke `orders` | Risiko fan-out |
|---|---|---|---|---|
| `orders` | 1 order | `order_id` | — | — |
| `customers` | 1 `customer_id` (= 1 order) | `customer_id` | 1:1 | `customer_unique_id` = orang; 1 orang bisa punya >1 `customer_id` |
| `order_items` | 1 unit item dalam order | `(order_id, order_item_id)` | 1:N | **Tinggi** — 1 order bisa 21 baris |
| `order_payments` | 1 pembayaran (cicilan/tipe) | `(order_id, payment_sequential)` | 1:N | **Sedang** — 2,26% order pakai >1 tipe |
| `order_reviews` | 1 review per order | `(review_id, order_id)` | 1:N (tidak bersih) | **Sedang** — 547 order punya >1 review |
| `products` | 1 produk | `product_id` | via `order_items` | Rendah |
| `sellers` | 1 seller | `seller_id` | via `order_items` | Rendah |
| `geolocation` | 1 titik koordinat (bukan 1 zip) | tidak ada | via zip prefix | **Tinggi** — 1 zip = banyak baris |
| `category_translation` | 1 kategori PT | `product_category_name` | via `products` | Rendah |

## 5. Join Map

```
customers ──(customer_id 1:1)── orders ──(order_id 1:N)── order_items ──(product_id N:1)── products ──(kategori)── category_translation
                                   │                              └──(seller_id N:1)── sellers
                                   ├──(order_id 1:N)── order_payments
                                   └──(order_id 1:N)── order_reviews

customers.zip_prefix / sellers.zip_prefix ──(zip prefix)── geolocation   (harus dideduplikasi dulu)
```

**Aturan join (Fan-out Guard):**
- `order_items`, `order_payments`, `order_reviews` **tidak boleh** di-join langsung satu sama lain di level detail.
- Pre-aggregate tiap tabel anak ke grain `order_id` (CTE), baru join ke `orders`.
- Setiap hasil join wajib disertai reconciliation check (mis. `SUM(price)` setelah join = `SUM(price)` di `order_items`).
- `geolocation` wajib dideduplikasi ke 1 baris per zip prefix sebelum di-join.

## 6. Catatan Penting

- `customer_id` ≠ orang. Untuk analisis pelanggan selalu pakai `customer_unique_id`.
- Tidak ada kolom quantity; qty = jumlah baris item.
- Tidak ada data biaya/margin, traffic/marketing, atau diskon eksplisit.
- Cek lisensi dataset di halaman Kaggle sebelum publish, lalu cantumkan atribusi di README.
