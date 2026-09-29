# Data Dictionary — Raw Tables (Olist)

Sumber: Olist Brazilian E-Commerce Public Dataset (Kaggle). 9 CSV → 9 tabel `raw_*` di DuckDB, 52 kolom.
Semua kolom dimuat sebagai `VARCHAR` (`ALL_VARCHAR = TRUE`); casting eksplisit dilakukan di Tahap 5.

## Inventori

| Tabel raw | File | Baris | Kolom |
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

## Grain Matrix

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

## Join Map

```
customers ──(customer_id 1:1)── orders ──(order_id 1:N)── order_items ──(product_id N:1)── products ──(kategori)── category_translation
                                   │                              └──(seller_id N:1)── sellers
                                   ├──(order_id 1:N)── order_payments
                                   └──(order_id 1:N)── order_reviews

customers.zip_prefix / sellers.zip_prefix ──(zip prefix)── geolocation   (harus dideduplikasi dulu)
```

## Kolom per Tabel

### `raw_customers` (5)
`customer_id`, `customer_unique_id`, `customer_zip_code_prefix`, `customer_city`, `customer_state`

### `raw_geolocation` (5)
`geolocation_zip_code_prefix`, `geolocation_lat`, `geolocation_lng`, `geolocation_city`, `geolocation_state`

### `raw_order_items` (7)
`order_id`, `order_item_id`, `product_id`, `seller_id`, `shipping_limit_date`, `price`, `freight_value`

### `raw_order_payments` (5)
`order_id`, `payment_sequential`, `payment_type`, `payment_installments`, `payment_value`

### `raw_order_reviews` (7)
`review_id`, `order_id`, `review_score`, `review_comment_title`, `review_comment_message`, `review_creation_date`, `review_answer_timestamp`

### `raw_orders` (8)
`order_id`, `customer_id`, `order_status`, `order_purchase_timestamp`, `order_approved_at`, `order_delivered_carrier_date`, `order_delivered_customer_date`, `order_estimated_delivery_date`

### `raw_products` (9)
`product_id`, `product_category_name`, `product_name_lenght`, `product_description_lenght`, `product_photos_qty`, `product_weight_g`, `product_length_cm`, `product_height_cm`, `product_width_cm`

> Ejaan `lenght` memang begitu di file sumber; dipertahankan di raw dan dirapikan di Tahap 5.

### `raw_sellers` (4)
`seller_id`, `seller_zip_code_prefix`, `seller_city`, `seller_state`

### `raw_category_translation` (2)
`product_category_name`, `product_category_name_english`

> Dictionary ini berisi nama kolom dan grain saja. Deskripsi nilai, tipe target, dan anomali diisi di Tahap 4–5 setelah profiling dan cleaning.
