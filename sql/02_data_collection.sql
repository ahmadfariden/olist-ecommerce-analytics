-- ============================================================
-- 02_data_collection.sql  |  Tahap 2 — Data Collection
-- ============================================================
-- GRAIN:       Berbeda per tabel (lihat Grain Matrix di docs/data_dictionary_raw.md)
-- POPULATION:  Seluruh baris CSV, tanpa filter apa pun (raw = source of truth)
-- DENOMINATOR: N/A (belum ada metrik rate di tahap ini)
-- ============================================================
-- Cara jalankan (dari ROOT proyek, tempat olist.duckdb berada):
--
--   cd "C:\Users\ahmad farid\Downloads\olist-ecommerce-analytics\olist-ecommerce-analytics"
--   duckdb olist.duckdb
--   .read sql/02_data_collection.sql
--
-- Path CSV bersifat relatif terhadap root proyek (data/raw/...), jadi DuckDB
-- HARUS dijalankan dari root, bukan dari dalam folder sql/.
--
-- Pendamping wajib: docs/02_data_collection.md
--   (Input · Proses Analisis · Temuan · Output · Assumptions · Batasan data · Kesimpulan)
--
-- Aturan raw data:
--   * Semua kolom dimuat ALL_VARCHAR = TRUE (tanpa tebakan tipe otomatis,
--     mis. zip code berawalan 0). Casting eksplisit dilakukan di Tahap 5.
--   * raw_order_reviews wajib quote='"' + escape='"' (komentar berisi kutip & newline).
--   * Tabel raw_* tidak boleh di-UPDATE / DELETE setelah dimuat.
--   * Script ini idempotent: DROP TABLE IF EXISTS lalu CREATE ulang.
-- ============================================================


-- ============================================================
-- 1. INGESTION: 1 CSV = 1 tabel raw_*
-- ============================================================

DROP TABLE IF EXISTS raw_customers;
CREATE TABLE raw_customers AS
SELECT * FROM read_csv('data/raw/olist_customers_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_geolocation;
CREATE TABLE raw_geolocation AS
SELECT * FROM read_csv('data/raw/olist_geolocation_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_order_items;
CREATE TABLE raw_order_items AS
SELECT * FROM read_csv('data/raw/olist_order_items_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_order_payments;
CREATE TABLE raw_order_payments AS
SELECT * FROM read_csv('data/raw/olist_order_payments_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_order_reviews;
CREATE TABLE raw_order_reviews AS
SELECT * FROM read_csv('data/raw/olist_order_reviews_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE,
                       quote = '"', escape = '"');

DROP TABLE IF EXISTS raw_orders;
CREATE TABLE raw_orders AS
SELECT * FROM read_csv('data/raw/olist_orders_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_products;
CREATE TABLE raw_products AS
SELECT * FROM read_csv('data/raw/olist_products_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_sellers;
CREATE TABLE raw_sellers AS
SELECT * FROM read_csv('data/raw/olist_sellers_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE);

DROP TABLE IF EXISTS raw_category_translation;
CREATE TABLE raw_category_translation AS
SELECT * FROM read_csv('data/raw/product_category_name_translation.csv',
                       header = true, ALL_VARCHAR = TRUE);


-- ============================================================
-- 2. INVENTORY: daftar tabel raw_* yang berhasil dibuat
-- ============================================================

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'main' AND table_name LIKE 'raw\_%' ESCAPE '\'
ORDER BY table_name;
-- Ekspektasi: 9 baris


-- ============================================================
-- 3. VERIFIKASI ROW COUNT & JUMLAH KOLOM vs roadmap (Tahap 2)
-- ============================================================

WITH expected(tbl, exp_rows, exp_cols) AS (
    VALUES
    ('raw_customers',            99441,   5),
    ('raw_geolocation',          1000163, 5),
    ('raw_order_items',          112650,  7),
    ('raw_order_payments',       103886,  5),
    ('raw_order_reviews',        99224,   7),
    ('raw_orders',               99441,   8),
    ('raw_products',             32951,   9),
    ('raw_sellers',              3095,    4),
    ('raw_category_translation', 71,      2)
),
actual_rows AS (
    SELECT 'raw_customers' AS tbl, COUNT(*) AS n FROM raw_customers            UNION ALL
    SELECT 'raw_geolocation',      COUNT(*)       FROM raw_geolocation         UNION ALL
    SELECT 'raw_order_items',      COUNT(*)       FROM raw_order_items         UNION ALL
    SELECT 'raw_order_payments',   COUNT(*)       FROM raw_order_payments      UNION ALL
    SELECT 'raw_order_reviews',    COUNT(*)       FROM raw_order_reviews       UNION ALL
    SELECT 'raw_orders',           COUNT(*)       FROM raw_orders              UNION ALL
    SELECT 'raw_products',         COUNT(*)       FROM raw_products            UNION ALL
    SELECT 'raw_sellers',          COUNT(*)       FROM raw_sellers             UNION ALL
    SELECT 'raw_category_translation', COUNT(*)   FROM raw_category_translation
),
actual_cols AS (
    SELECT table_name AS tbl, COUNT(*) AS n
    FROM information_schema.columns
    WHERE table_schema = 'main' AND table_name LIKE 'raw\_%' ESCAPE '\'
    GROUP BY table_name
)
SELECT e.tbl,
       e.exp_rows,
       r.n AS actual_rows,
       e.exp_cols,
       c.n AS actual_cols,
       CASE WHEN r.n = e.exp_rows AND c.n = e.exp_cols THEN 'PASS' ELSE 'FAIL' END AS status
FROM expected e
JOIN actual_rows r USING (tbl)
JOIN actual_cols c USING (tbl)
ORDER BY e.tbl;
-- Ekspektasi: 9 baris, semuanya PASS

-- Total kolom seluruh tabel (roadmap: 52)
SELECT COUNT(*) AS total_columns,
       CASE WHEN COUNT(*) = 52 THEN 'PASS' ELSE 'FAIL' END AS status
FROM information_schema.columns
WHERE table_schema = 'main' AND table_name LIKE 'raw\_%' ESCAPE '\';

-- Semua kolom harus VARCHAR (ALL_VARCHAR = TRUE)
SELECT COUNT(*) AS non_varchar_columns,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM information_schema.columns
WHERE table_schema = 'main'
  AND table_name LIKE 'raw\_%' ESCAPE '\'
  AND data_type <> 'VARCHAR';


-- ============================================================
-- 4. SKEMA: nama kolom apa adanya dari CSV (untuk data dictionary)
-- ============================================================

SELECT table_name, ordinal_position, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'main' AND table_name LIKE 'raw\_%' ESCAPE '\'
ORDER BY table_name, ordinal_position;


-- ============================================================
-- 5. CEK GRAIN: duplikasi pada primary key (sesuai Grain Matrix)
--    Hanya melaporkan, TIDAK membersihkan (cleaning = Tahap 5).
--    Ekspektasi dup_rows = 0 untuk semua baris; jika tidak 0, catat
--    sebagai temuan di docs/02_data_collection.md.
-- ============================================================

SELECT 'raw_orders (order_id)' AS grain_check,
       COUNT(*) - COUNT(DISTINCT order_id) AS dup_rows
FROM raw_orders
UNION ALL
SELECT 'raw_customers (customer_id)',
       COUNT(*) - COUNT(DISTINCT customer_id)
FROM raw_customers
UNION ALL
SELECT 'raw_order_items (order_id, order_item_id)',
       COUNT(*) - COUNT(DISTINCT (order_id, order_item_id))
FROM raw_order_items
UNION ALL
SELECT 'raw_order_payments (order_id, payment_sequential)',
       COUNT(*) - COUNT(DISTINCT (order_id, payment_sequential))
FROM raw_order_payments
UNION ALL
SELECT 'raw_order_reviews (review_id, order_id)',
       COUNT(*) - COUNT(DISTINCT (review_id, order_id))
FROM raw_order_reviews
UNION ALL
SELECT 'raw_products (product_id)',
       COUNT(*) - COUNT(DISTINCT product_id)
FROM raw_products
UNION ALL
SELECT 'raw_sellers (seller_id)',
       COUNT(*) - COUNT(DISTINCT seller_id)
FROM raw_sellers
UNION ALL
SELECT 'raw_category_translation (product_category_name)',
       COUNT(*) - COUNT(DISTINCT product_category_name)
FROM raw_category_translation;


-- ============================================================
-- 6. CEK RELASI KUNCI (Join Map): orphan check dasar
--    Hanya melaporkan; analisis mendalam di Tahap 4 & 6.
-- ============================================================

SELECT 'orders.customer_id tanpa pasangan di customers' AS relation_check,
       COUNT(*) AS orphan_rows
FROM raw_orders o
LEFT JOIN raw_customers c USING (customer_id)
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'order_items.order_id tanpa pasangan di orders',
       COUNT(*)
FROM raw_order_items i
LEFT JOIN raw_orders o USING (order_id)
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_items.product_id tanpa pasangan di products',
       COUNT(*)
FROM raw_order_items i
LEFT JOIN raw_products p USING (product_id)
WHERE p.product_id IS NULL
UNION ALL
SELECT 'order_items.seller_id tanpa pasangan di sellers',
       COUNT(*)
FROM raw_order_items i
LEFT JOIN raw_sellers s USING (seller_id)
WHERE s.seller_id IS NULL
UNION ALL
SELECT 'order_payments.order_id tanpa pasangan di orders',
       COUNT(*)
FROM raw_order_payments p
LEFT JOIN raw_orders o USING (order_id)
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_reviews.order_id tanpa pasangan di orders',
       COUNT(*)
FROM raw_order_reviews r
LEFT JOIN raw_orders o USING (order_id)
WHERE o.order_id IS NULL;
