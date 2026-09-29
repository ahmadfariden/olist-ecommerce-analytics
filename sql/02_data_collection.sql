-- ============================================================
-- Tahap 2 — Data Collection
-- File: sql/02_data_collection.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/02_data_collection.sql
-- (data/olist.duckdb otomatis ter-ignore lewat *.duckdb)
-- ============================================================
-- GRAIN:       beda per tabel (lihat Grain Matrix di docs/data_dictionary_raw.md)
-- POPULATION:  seluruh baris CSV, tanpa filter (raw preserved)
-- DENOMINATOR: n/a (tahap ingestion, belum ada metrik rate)
-- ============================================================
-- Governance:
--   * 1 CSV = 1 tabel raw_*; semua kolom VARCHAR (ALL_VARCHAR = TRUE)
--     supaya zip code berawalan 0 tidak rusak. Casting di Tahap 5.
--   * raw_order_reviews wajib quote='"' + escape='"' (komentar berisi kutip & newline).
--   * Tabel raw_* TIDAK BOLEH diubah setelah ini.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Ingestion (9 tabel raw_*)
-- ------------------------------------------------------------
DROP TABLE IF EXISTS raw_customers;
DROP TABLE IF EXISTS raw_geolocation;
DROP TABLE IF EXISTS raw_order_items;
DROP TABLE IF EXISTS raw_order_payments;
DROP TABLE IF EXISTS raw_order_reviews;
DROP TABLE IF EXISTS raw_orders;
DROP TABLE IF EXISTS raw_products;
DROP TABLE IF EXISTS raw_sellers;
DROP TABLE IF EXISTS raw_category_translation;

CREATE TABLE raw_customers AS
SELECT * FROM read_csv('data/raw/olist_customers_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_geolocation AS
SELECT * FROM read_csv('data/raw/olist_geolocation_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_order_items AS
SELECT * FROM read_csv('data/raw/olist_order_items_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_order_payments AS
SELECT * FROM read_csv('data/raw/olist_order_payments_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_order_reviews AS
SELECT * FROM read_csv('data/raw/olist_order_reviews_dataset.csv',
                       header = true, ALL_VARCHAR = TRUE, quote = '"', escape = '"');

CREATE TABLE raw_orders AS
SELECT * FROM read_csv('data/raw/olist_orders_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_products AS
SELECT * FROM read_csv('data/raw/olist_products_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_sellers AS
SELECT * FROM read_csv('data/raw/olist_sellers_dataset.csv', header = true, ALL_VARCHAR = TRUE);

CREATE TABLE raw_category_translation AS
SELECT * FROM read_csv('data/raw/product_category_name_translation.csv', header = true, ALL_VARCHAR = TRUE);

-- ------------------------------------------------------------
-- 2. Initial inventory: row count vs ekspektasi roadmap (Tahap 2)
-- ------------------------------------------------------------
WITH actual AS (
    SELECT 'raw_customers' AS tabel, COUNT(*) AS n FROM raw_customers UNION ALL
    SELECT 'raw_geolocation',        COUNT(*) FROM raw_geolocation UNION ALL
    SELECT 'raw_order_items',        COUNT(*) FROM raw_order_items UNION ALL
    SELECT 'raw_order_payments',     COUNT(*) FROM raw_order_payments UNION ALL
    SELECT 'raw_order_reviews',      COUNT(*) FROM raw_order_reviews UNION ALL
    SELECT 'raw_orders',             COUNT(*) FROM raw_orders UNION ALL
    SELECT 'raw_products',           COUNT(*) FROM raw_products UNION ALL
    SELECT 'raw_sellers',            COUNT(*) FROM raw_sellers UNION ALL
    SELECT 'raw_category_translation', COUNT(*) FROM raw_category_translation
),
expected(tabel, n_expected) AS (
    VALUES ('raw_customers', 99441), ('raw_geolocation', 1000163),
           ('raw_order_items', 112650), ('raw_order_payments', 103886),
           ('raw_order_reviews', 99224), ('raw_orders', 99441),
           ('raw_products', 32951), ('raw_sellers', 3095),
           ('raw_category_translation', 71)
)
SELECT a.tabel,
       a.n            AS row_count,
       e.n_expected,
       CASE WHEN a.n = e.n_expected THEN 'PASS' ELSE 'FAIL' END AS status
FROM actual a JOIN expected e USING (tabel)
ORDER BY a.tabel;

-- ------------------------------------------------------------
-- 3. Inventory kolom: jumlah kolom per tabel (ekspektasi total 52)
-- ------------------------------------------------------------
SELECT table_name AS tabel,
       COUNT(*)   AS n_kolom,
       CASE table_name
            WHEN 'raw_customers' THEN 5  WHEN 'raw_geolocation' THEN 5
            WHEN 'raw_order_items' THEN 7 WHEN 'raw_order_payments' THEN 5
            WHEN 'raw_order_reviews' THEN 7 WHEN 'raw_orders' THEN 8
            WHEN 'raw_products' THEN 9   WHEN 'raw_sellers' THEN 4
            WHEN 'raw_category_translation' THEN 2
       END AS n_kolom_expected
FROM duckdb_columns()
WHERE table_name LIKE 'raw\_%' ESCAPE '\'
GROUP BY table_name
ORDER BY table_name;

SELECT SUM(n) AS total_kolom, 52 AS total_expected
FROM (SELECT COUNT(*) AS n FROM duckdb_columns()
      WHERE table_name LIKE 'raw\_%' ESCAPE '\' GROUP BY table_name);

-- ------------------------------------------------------------
-- 4. Verifikasi Grain Matrix: duplikat primary key per tabel
--    (dup_rows = 0 berarti grain sesuai Grain Matrix)
-- ------------------------------------------------------------
SELECT 'orders (order_id)' AS grain_check,
       COUNT(*) - COUNT(DISTINCT order_id) AS dup_rows FROM raw_orders
UNION ALL
SELECT 'customers (customer_id)',
       COUNT(*) - COUNT(DISTINCT customer_id) FROM raw_customers
UNION ALL
SELECT 'order_items (order_id, order_item_id)',
       COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)) FROM raw_order_items
UNION ALL
SELECT 'order_payments (order_id, payment_sequential)',
       COUNT(*) - COUNT(DISTINCT (order_id, payment_sequential)) FROM raw_order_payments
UNION ALL
SELECT 'order_reviews (review_id, order_id)',
       COUNT(*) - COUNT(DISTINCT (review_id, order_id)) FROM raw_order_reviews
UNION ALL
SELECT 'products (product_id)',
       COUNT(*) - COUNT(DISTINCT product_id) FROM raw_products
UNION ALL
SELECT 'sellers (seller_id)',
       COUNT(*) - COUNT(DISTINCT seller_id) FROM raw_sellers
UNION ALL
SELECT 'category_translation (product_category_name)',
       COUNT(*) - COUNT(DISTINCT product_category_name) FROM raw_category_translation;

-- ------------------------------------------------------------
-- 5. Verifikasi Join Map: orphan key (child tanpa parent)
--    orphan = 0 berarti relasi bersih. Ini pengecekan cepat saja;
--    profiling relasi menyeluruh ada di Tahap 4.
-- ------------------------------------------------------------
SELECT 'orders.customer_id -> customers' AS relasi, COUNT(*) AS orphan
FROM raw_orders o LEFT JOIN raw_customers c USING (customer_id)
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'order_items.order_id -> orders', COUNT(*)
FROM raw_order_items i LEFT JOIN raw_orders o USING (order_id)
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_items.product_id -> products', COUNT(*)
FROM raw_order_items i LEFT JOIN raw_products p USING (product_id)
WHERE p.product_id IS NULL
UNION ALL
SELECT 'order_items.seller_id -> sellers', COUNT(*)
FROM raw_order_items i LEFT JOIN raw_sellers s USING (seller_id)
WHERE s.seller_id IS NULL
UNION ALL
SELECT 'order_payments.order_id -> orders', COUNT(*)
FROM raw_order_payments p LEFT JOIN raw_orders o USING (order_id)
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_reviews.order_id -> orders', COUNT(*)
FROM raw_order_reviews r LEFT JOIN raw_orders o USING (order_id)
WHERE o.order_id IS NULL;

-- ------------------------------------------------------------
-- 6. Contoh baris (sanity check parsing; zip prefix harus tetap berawalan 0,
--    review comment multi-baris harus utuh)
-- ------------------------------------------------------------
SELECT * FROM raw_customers LIMIT 3;
SELECT * FROM raw_orders LIMIT 3;
SELECT * FROM raw_order_items LIMIT 3;
SELECT review_id, order_id, review_score, review_comment_message
FROM raw_order_reviews
WHERE review_comment_message IS NOT NULL
LIMIT 3;
SELECT customer_zip_code_prefix FROM raw_customers
WHERE customer_zip_code_prefix LIKE '0%' LIMIT 3;
