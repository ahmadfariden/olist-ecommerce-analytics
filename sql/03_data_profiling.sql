-- ============================================================
-- Tahap 4 — Data Profiling
-- File: sql/03_data_profiling.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/03_data_profiling.sql
-- Prasyarat: sql/02_data_collection.sql sudah dijalankan (tabel raw_* ada).
-- ============================================================
-- GRAIN:       beda per tabel (lihat Grain Matrix di docs/data_dictionary_raw.md)
-- POPULATION:  seluruh baris raw_*, tanpa filter (profiling belum memakai flag analitik)
-- DENOMINATOR: dinyatakan per metrik (kolom n / n_rows)
-- ============================================================
-- Aturan tahap ini:
--   * TIDAK ADA cleaning final. raw_* tidak diubah.
--   * View p_* (TEMP) hanya helper cast tipe untuk profiling; bukan stg_* (itu Tahap 5).
--   * Semua join ke tabel anak dilakukan setelah pre-aggregate ke grain order_id (Fan-out Guard).
--   * Angka "expected" berasal dari roadmap v1.6 (olist_profiling.md + 03b/03c/03d).
--       status PASS  = cocok dengan ekspektasi (dalam toleransi)
--       status CHECK = beda -> jelaskan penyebabnya di docs/profiling_findings.md
--       status INFO  = tidak ada ekspektasi
--     Metrik berlabel (heuristik) bergantung pada aturan deteksi; CHECK di sana bukan otomatis error.
--   * Output ringkasan: data/processed/03_profiling_summary.parquet
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helper views (cast aman dengan TRY_CAST)
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW p_orders AS
SELECT order_id, customer_id, order_status,
       TRY_CAST(order_purchase_timestamp      AS TIMESTAMP) AS ts_purchase,
       TRY_CAST(order_approved_at             AS TIMESTAMP) AS ts_approved,
       TRY_CAST(order_delivered_carrier_date  AS TIMESTAMP) AS ts_carrier,
       TRY_CAST(order_delivered_customer_date AS TIMESTAMP) AS ts_customer,
       TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) AS ts_estimated
FROM raw_orders;

CREATE OR REPLACE TEMP VIEW p_items AS
SELECT order_id, order_item_id, product_id, seller_id,
       TRY_CAST(shipping_limit_date AS TIMESTAMP) AS ts_limit,
       TRY_CAST(price               AS DOUBLE)    AS price,
       TRY_CAST(freight_value       AS DOUBLE)    AS freight
FROM raw_order_items;

CREATE OR REPLACE TEMP VIEW p_pay AS
SELECT order_id, payment_type,
       TRY_CAST(payment_sequential   AS INTEGER) AS seq,
       TRY_CAST(payment_installments AS INTEGER) AS installments,
       TRY_CAST(payment_value        AS DOUBLE)  AS pay_value
FROM raw_order_payments;

CREATE OR REPLACE TEMP VIEW p_rev AS
SELECT review_id, order_id, review_comment_title, review_comment_message,
       TRY_CAST(review_score           AS INTEGER)   AS score,
       TRY_CAST(review_creation_date   AS TIMESTAMP) AS ts_created,
       TRY_CAST(review_answer_timestamp AS TIMESTAMP) AS ts_answer
FROM raw_order_reviews;

CREATE OR REPLACE TEMP VIEW p_prod AS
SELECT product_id, product_category_name,
       TRY_CAST(product_name_lenght        AS INTEGER) AS name_len,
       TRY_CAST(product_description_lenght AS INTEGER) AS desc_len,
       TRY_CAST(product_photos_qty         AS INTEGER) AS photos,
       TRY_CAST(product_weight_g           AS DOUBLE)  AS weight_g,
       TRY_CAST(product_length_cm          AS DOUBLE)  AS length_cm,
       TRY_CAST(product_height_cm          AS DOUBLE)  AS height_cm,
       TRY_CAST(product_width_cm           AS DOUBLE)  AS width_cm
FROM raw_products;

CREATE OR REPLACE TEMP VIEW p_geo AS
SELECT geolocation_zip_code_prefix AS zip, geolocation_city AS city,
       TRY_CAST(geolocation_lat AS DOUBLE) AS lat,
       TRY_CAST(geolocation_lng AS DOUBLE) AS lng
FROM raw_geolocation;

-- ------------------------------------------------------------
-- 1. Null & blank profile: seluruh 52 kolom
--    n_null = NULL sesungguhnya; n_blank = string kosong/whitespace
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE prof_null_summary AS
SELECT tabel, kolom, n_rows, n_null, n_blank,
       ROUND(100.0 * n_null / NULLIF(n_rows, 0), 2) AS pct_null
FROM (
SELECT 'raw_customers' AS tabel, 'customer_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(customer_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(customer_id) = '') AS n_blank FROM raw_customers
UNION ALL
SELECT 'raw_customers' AS tabel, 'customer_unique_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(customer_unique_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(customer_unique_id) = '') AS n_blank FROM raw_customers
UNION ALL
SELECT 'raw_customers' AS tabel, 'customer_zip_code_prefix' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(customer_zip_code_prefix) AS n_null, COUNT(*) FILTER (WHERE TRIM(customer_zip_code_prefix) = '') AS n_blank FROM raw_customers
UNION ALL
SELECT 'raw_customers' AS tabel, 'customer_city' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(customer_city) AS n_null, COUNT(*) FILTER (WHERE TRIM(customer_city) = '') AS n_blank FROM raw_customers
UNION ALL
SELECT 'raw_customers' AS tabel, 'customer_state' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(customer_state) AS n_null, COUNT(*) FILTER (WHERE TRIM(customer_state) = '') AS n_blank FROM raw_customers
UNION ALL
SELECT 'raw_geolocation' AS tabel, 'geolocation_zip_code_prefix' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(geolocation_zip_code_prefix) AS n_null, COUNT(*) FILTER (WHERE TRIM(geolocation_zip_code_prefix) = '') AS n_blank FROM raw_geolocation
UNION ALL
SELECT 'raw_geolocation' AS tabel, 'geolocation_lat' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(geolocation_lat) AS n_null, COUNT(*) FILTER (WHERE TRIM(geolocation_lat) = '') AS n_blank FROM raw_geolocation
UNION ALL
SELECT 'raw_geolocation' AS tabel, 'geolocation_lng' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(geolocation_lng) AS n_null, COUNT(*) FILTER (WHERE TRIM(geolocation_lng) = '') AS n_blank FROM raw_geolocation
UNION ALL
SELECT 'raw_geolocation' AS tabel, 'geolocation_city' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(geolocation_city) AS n_null, COUNT(*) FILTER (WHERE TRIM(geolocation_city) = '') AS n_blank FROM raw_geolocation
UNION ALL
SELECT 'raw_geolocation' AS tabel, 'geolocation_state' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(geolocation_state) AS n_null, COUNT(*) FILTER (WHERE TRIM(geolocation_state) = '') AS n_blank FROM raw_geolocation
UNION ALL
SELECT 'raw_order_items' AS tabel, 'order_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_id) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_items' AS tabel, 'order_item_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_item_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_item_id) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_items' AS tabel, 'product_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_id) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_items' AS tabel, 'seller_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(seller_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(seller_id) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_items' AS tabel, 'shipping_limit_date' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(shipping_limit_date) AS n_null, COUNT(*) FILTER (WHERE TRIM(shipping_limit_date) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_items' AS tabel, 'price' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(price) AS n_null, COUNT(*) FILTER (WHERE TRIM(price) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_items' AS tabel, 'freight_value' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(freight_value) AS n_null, COUNT(*) FILTER (WHERE TRIM(freight_value) = '') AS n_blank FROM raw_order_items
UNION ALL
SELECT 'raw_order_payments' AS tabel, 'order_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_id) = '') AS n_blank FROM raw_order_payments
UNION ALL
SELECT 'raw_order_payments' AS tabel, 'payment_sequential' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(payment_sequential) AS n_null, COUNT(*) FILTER (WHERE TRIM(payment_sequential) = '') AS n_blank FROM raw_order_payments
UNION ALL
SELECT 'raw_order_payments' AS tabel, 'payment_type' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(payment_type) AS n_null, COUNT(*) FILTER (WHERE TRIM(payment_type) = '') AS n_blank FROM raw_order_payments
UNION ALL
SELECT 'raw_order_payments' AS tabel, 'payment_installments' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(payment_installments) AS n_null, COUNT(*) FILTER (WHERE TRIM(payment_installments) = '') AS n_blank FROM raw_order_payments
UNION ALL
SELECT 'raw_order_payments' AS tabel, 'payment_value' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(payment_value) AS n_null, COUNT(*) FILTER (WHERE TRIM(payment_value) = '') AS n_blank FROM raw_order_payments
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'review_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(review_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(review_id) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'order_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_id) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'review_score' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(review_score) AS n_null, COUNT(*) FILTER (WHERE TRIM(review_score) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'review_comment_title' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(review_comment_title) AS n_null, COUNT(*) FILTER (WHERE TRIM(review_comment_title) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'review_comment_message' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(review_comment_message) AS n_null, COUNT(*) FILTER (WHERE TRIM(review_comment_message) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'review_creation_date' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(review_creation_date) AS n_null, COUNT(*) FILTER (WHERE TRIM(review_creation_date) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_order_reviews' AS tabel, 'review_answer_timestamp' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(review_answer_timestamp) AS n_null, COUNT(*) FILTER (WHERE TRIM(review_answer_timestamp) = '') AS n_blank FROM raw_order_reviews
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_id) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'customer_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(customer_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(customer_id) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_status' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_status) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_status) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_purchase_timestamp' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_purchase_timestamp) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_purchase_timestamp) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_approved_at' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_approved_at) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_approved_at) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_delivered_carrier_date' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_delivered_carrier_date) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_delivered_carrier_date) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_delivered_customer_date' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_delivered_customer_date) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_delivered_customer_date) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_orders' AS tabel, 'order_estimated_delivery_date' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(order_estimated_delivery_date) AS n_null, COUNT(*) FILTER (WHERE TRIM(order_estimated_delivery_date) = '') AS n_blank FROM raw_orders
UNION ALL
SELECT 'raw_products' AS tabel, 'product_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_id) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_category_name' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_category_name) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_category_name) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_name_lenght' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_name_lenght) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_name_lenght) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_description_lenght' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_description_lenght) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_description_lenght) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_photos_qty' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_photos_qty) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_photos_qty) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_weight_g' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_weight_g) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_weight_g) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_length_cm' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_length_cm) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_length_cm) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_height_cm' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_height_cm) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_height_cm) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_products' AS tabel, 'product_width_cm' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_width_cm) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_width_cm) = '') AS n_blank FROM raw_products
UNION ALL
SELECT 'raw_sellers' AS tabel, 'seller_id' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(seller_id) AS n_null, COUNT(*) FILTER (WHERE TRIM(seller_id) = '') AS n_blank FROM raw_sellers
UNION ALL
SELECT 'raw_sellers' AS tabel, 'seller_zip_code_prefix' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(seller_zip_code_prefix) AS n_null, COUNT(*) FILTER (WHERE TRIM(seller_zip_code_prefix) = '') AS n_blank FROM raw_sellers
UNION ALL
SELECT 'raw_sellers' AS tabel, 'seller_city' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(seller_city) AS n_null, COUNT(*) FILTER (WHERE TRIM(seller_city) = '') AS n_blank FROM raw_sellers
UNION ALL
SELECT 'raw_sellers' AS tabel, 'seller_state' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(seller_state) AS n_null, COUNT(*) FILTER (WHERE TRIM(seller_state) = '') AS n_blank FROM raw_sellers
UNION ALL
SELECT 'raw_category_translation' AS tabel, 'product_category_name' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_category_name) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_category_name) = '') AS n_blank FROM raw_category_translation
UNION ALL
SELECT 'raw_category_translation' AS tabel, 'product_category_name_english' AS kolom, COUNT(*) AS n_rows, COUNT(*) - COUNT(product_category_name_english) AS n_null, COUNT(*) FILTER (WHERE TRIM(product_category_name_english) = '') AS n_blank FROM raw_category_translation
)
ORDER BY tabel, kolom;

SELECT * FROM prof_null_summary WHERE n_null > 0 OR n_blank > 0 ORDER BY tabel, pct_null DESC;

-- ------------------------------------------------------------
-- 2. ORDERS — status, null struktural, urutan tanggal, cakupan waktu
-- ------------------------------------------------------------
-- 2.1 Distribusi status (roadmap: delivered 96.478 = 97,02%)
SELECT order_status, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw_orders GROUP BY order_status ORDER BY n DESC;

-- 2.2 Null struktural vs status: apakah null mengikuti status?
SELECT order_status,
       COUNT(*)                                            AS n,
       COUNT(*) FILTER (WHERE ts_approved IS NULL)         AS null_approved,
       COUNT(*) FILTER (WHERE ts_carrier  IS NULL)         AS null_carrier,
       COUNT(*) FILTER (WHERE ts_customer IS NULL)         AS null_customer
FROM p_orders GROUP BY order_status ORDER BY n DESC;

-- 2.3 Anomali urutan timestamp (di-flag di Tahap 5, tidak dihapus)
SELECT
  COUNT(*) FILTER (WHERE ts_carrier  < ts_purchase) AS carrier_lt_purchase,
  COUNT(*) FILTER (WHERE ts_carrier  < ts_approved) AS carrier_lt_approved,
  COUNT(*) FILTER (WHERE ts_customer < ts_carrier)  AS customer_lt_carrier,
  COUNT(*) FILTER (WHERE ts_approved < ts_purchase) AS approved_lt_purchase
FROM p_orders;

-- 2.4 Cakupan waktu bulanan (purchase month). Bulan tanpa order tetap tampil (2016-11 = 0).
--     in_flight = shipped/invoiced/processing/created/approved
CREATE OR REPLACE TABLE prof_monthly AS
SELECT strftime(t.m, '%Y-%m') AS bulan,
       COUNT(o.order_id)                                                    AS n_orders,
       COUNT(*) FILTER (WHERE o.order_status = 'delivered')                 AS n_delivered,
       COUNT(*) FILTER (WHERE o.order_status IN
             ('shipped','invoiced','processing','created','approved'))      AS n_in_flight,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.order_status IN
             ('shipped','invoiced','processing','created','approved'))
             / NULLIF(COUNT(o.order_id), 0), 2)                             AS pct_in_flight
FROM generate_series(TIMESTAMP '2016-09-01', TIMESTAMP '2018-10-01', INTERVAL 1 MONTH) AS t(m)
LEFT JOIN p_orders o ON date_trunc('month', o.ts_purchase) = t.m
GROUP BY t.m
ORDER BY t.m;

SELECT * FROM prof_monthly;

-- ------------------------------------------------------------
-- 3. CUSTOMERS — customer_id vs customer_unique_id, konsistensi lokasi
-- ------------------------------------------------------------
-- 3.1 Distribusi jumlah order per orang (customer_unique_id)
SELECT n_order, COUNT(*) AS n_orang,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT customer_unique_id, COUNT(*) AS n_order
      FROM raw_customers GROUP BY customer_unique_id)
GROUP BY n_order ORDER BY n_order;

-- 3.2 Konsistensi lokasi per orang (1 orang bisa >1 zip/kota/state)
SELECT COUNT(*)                            AS n_orang,
       COUNT(*) FILTER (WHERE z  > 1)      AS multi_zip,
       COUNT(*) FILTER (WHERE ci > 1)      AS multi_kota,
       COUNT(*) FILTER (WHERE s  > 1)      AS multi_state
FROM (SELECT customer_unique_id,
             COUNT(DISTINCT customer_zip_code_prefix) AS z,
             COUNT(DISTINCT customer_city)            AS ci,
             COUNT(DISTINCT customer_state)           AS s
      FROM raw_customers GROUP BY customer_unique_id);

-- ------------------------------------------------------------
-- 4. ORDER_ITEMS — fan-out, harga/ongkir, outlier
-- ------------------------------------------------------------
-- 4.1 Distribusi jumlah item per order
SELECT n_item, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT order_id, COUNT(*) AS n_item FROM raw_order_items GROUP BY order_id)
GROUP BY n_item ORDER BY n_item;

-- 4.2 Order tanpa item, menurut status (roadmap: 775 = 603 unavailable + 164 canceled + sisanya)
SELECT o.order_status, COUNT(*) AS n_order_tanpa_item
FROM raw_orders o
WHERE NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)
GROUP BY o.order_status ORDER BY n_order_tanpa_item DESC;

-- 4.3 Ringkasan price & freight
SELECT COUNT(*) AS n_item,
       MIN(price) AS price_min, quantile_cont(price, 0.5) AS price_median,
       quantile_cont(price, 0.95) AS price_p95, MAX(price) AS price_max,
       MIN(freight) AS freight_min, quantile_cont(freight, 0.5) AS freight_median,
       MAX(freight) AS freight_max
FROM p_items;

-- ------------------------------------------------------------
-- 5. ORDER_PAYMENTS — tipe, multi-payment, rekonsiliasi item+freight vs payment
-- ------------------------------------------------------------
-- 5.1 Distribusi tipe pembayaran (baris)
SELECT payment_type, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw_order_payments GROUP BY payment_type ORDER BY n DESC;

-- 5.2 Rekonsiliasi order-level. Fan-out Guard: kedua sisi di-aggregate ke grain order_id dulu.
CREATE OR REPLACE TEMP TABLE p_recon AS
WITH items AS (
    SELECT order_id, SUM(price + freight) AS item_total FROM p_items GROUP BY order_id
), pays AS (
    SELECT order_id, SUM(pay_value) AS pay_total FROM p_pay GROUP BY order_id
)
SELECT i.order_id, i.item_total, p.pay_total,
       ROUND(ABS(i.item_total - p.pay_total), 2) AS diff
FROM items i JOIN pays p USING (order_id);

SELECT COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE diff <= 0.01)              AS diff_le_001,
       COUNT(*) FILTER (WHERE diff > 0.01 AND diff <= 1) AS diff_001_1,
       COUNT(*) FILTER (WHERE diff > 1)                  AS diff_gt_1,
       MAX(diff)                                         AS diff_max
FROM p_recon;

-- 5.3 Selisih > 1: arah selisih (payment lebih besar vs lebih kecil dari item+freight)
SELECT CASE WHEN pay_total > item_total THEN 'payment > item+freight'
            ELSE 'payment < item+freight' END AS arah,
       COUNT(*) AS n_order, ROUND(SUM(ABS(pay_total - item_total)), 2) AS total_selisih
FROM p_recon WHERE diff > 1 GROUP BY 1 ORDER BY 2 DESC;

-- ------------------------------------------------------------
-- 6. ORDER_REVIEWS — duplikasi, skor, komentar
-- ------------------------------------------------------------
-- 6.1 Distribusi skor (baris review, sebelum dedup)
SELECT score, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM p_rev GROUP BY score ORDER BY score;

-- 6.2 Pola review ganda: order dengan >1 review, dan apakah skornya bertentangan
SELECT COUNT(*) AS n_order_multi_review,
       COUNT(*) FILTER (WHERE n_skor > 1) AS n_skor_bertentangan
FROM (SELECT order_id, COUNT(DISTINCT score) AS n_skor
      FROM p_rev GROUP BY order_id HAVING COUNT(*) > 1);

-- ------------------------------------------------------------
-- 7. PRODUCTS & CATEGORY_TRANSLATION
-- ------------------------------------------------------------
-- 7.1 Kategori produk tanpa terjemahan (roadmap: pc_gamer 3, portateis_... 10)
SELECT p.product_category_name, COUNT(*) AS n_produk
FROM raw_products p
LEFT JOIN raw_category_translation t USING (product_category_name)
WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL
GROUP BY p.product_category_name ORDER BY n_produk DESC;

-- 7.2 Typo bawaan di terjemahan (dirapikan di Tahap 5)
SELECT product_category_name, product_category_name_english
FROM raw_category_translation
WHERE product_category_name_english LIKE '%costruction%'
   OR product_category_name_english LIKE '%fashio\_%' ESCAPE '\'
   OR product_category_name_english LIKE '%confort%';

-- ------------------------------------------------------------
-- 8. SELLERS & CUSTOMERS — kebersihan kota, cakupan state
-- ------------------------------------------------------------
-- 8.1 seller_city kotor (heuristik: angka, '@', '/', ',' atau ' - ')
SELECT seller_city, seller_state, COUNT(*) AS n_seller
FROM raw_sellers
WHERE regexp_matches(seller_city, '[0-9@/,]| - ')
GROUP BY seller_city, seller_state ORDER BY seller_city;

-- 8.2 State customer tanpa seller (roadmap: AL, AP, RR, TO)
SELECT customer_state, COUNT(*) AS n_customer
FROM raw_customers
WHERE customer_state NOT IN (SELECT DISTINCT seller_state FROM raw_sellers)
GROUP BY customer_state ORDER BY customer_state;

-- ------------------------------------------------------------
-- 9. GEOLOCATION — duplikasi, ambiguitas zip, ejaan kota
-- ------------------------------------------------------------
-- 9.1 Kota dengan >1 ejaan setelah accent-strip (mis. 'sao paulo' vs 'são paulo')
SELECT strip_accents(city) AS kota_normal, COUNT(DISTINCT city) AS n_ejaan, MIN(city) AS contoh_a, MAX(city) AS contoh_b
FROM p_geo
GROUP BY 1 HAVING COUNT(DISTINCT city) > 1
ORDER BY n_ejaan DESC, kota_normal LIMIT 20;

-- ------------------------------------------------------------
-- 10. Kelengkapan relasi level order (child -> parent sudah dicek di Tahap 2;
--     ini sisi sebaliknya: order tanpa child)
-- ------------------------------------------------------------
SELECT 'order tanpa item'    AS relasi, COUNT(*) AS n FROM raw_orders o
  WHERE NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)
UNION ALL
SELECT 'order tanpa payment', COUNT(*) FROM raw_orders o
  WHERE NOT EXISTS (SELECT 1 FROM raw_order_payments p WHERE p.order_id = o.order_id)
UNION ALL
SELECT 'order tanpa review',  COUNT(*) FROM raw_orders o
  WHERE NOT EXISTS (SELECT 1 FROM raw_order_reviews r WHERE r.order_id = o.order_id);

-- ------------------------------------------------------------
-- 11. Findings terverifikasi: aktual vs ekspektasi roadmap
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE prof_findings_raw (
    section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE
);

-- 11.1 orders
INSERT INTO prof_findings_raw VALUES
 ('orders','n_rows',                    (SELECT COUNT(*) FROM raw_orders), 99441, 0),
 ('orders','n_distinct_order_id',       (SELECT COUNT(DISTINCT order_id) FROM raw_orders), 99441, 0),
 ('orders','n_distinct_status',         (SELECT COUNT(DISTINCT order_status) FROM raw_orders), 8, 0),
 ('orders','status_delivered',          (SELECT COUNT(*) FROM raw_orders WHERE order_status='delivered'), 96478, 0),
 ('orders','status_shipped',            (SELECT COUNT(*) FROM raw_orders WHERE order_status='shipped'), 1107, 0),
 ('orders','status_canceled',           (SELECT COUNT(*) FROM raw_orders WHERE order_status='canceled'), 625, 0),
 ('orders','status_unavailable',        (SELECT COUNT(*) FROM raw_orders WHERE order_status='unavailable'), 609, 0),
 ('orders','status_invoiced',           (SELECT COUNT(*) FROM raw_orders WHERE order_status='invoiced'), 314, 0),
 ('orders','status_processing',         (SELECT COUNT(*) FROM raw_orders WHERE order_status='processing'), 301, 0),
 ('orders','status_created',            (SELECT COUNT(*) FROM raw_orders WHERE order_status='created'), 5, 0),
 ('orders','status_approved',           (SELECT COUNT(*) FROM raw_orders WHERE order_status='approved'), 2, 0),
 ('orders','null_approved_at',          (SELECT COUNT(*) FROM p_orders WHERE ts_approved IS NULL), 160, 0),
 ('orders','null_carrier_date',         (SELECT COUNT(*) FROM p_orders WHERE ts_carrier IS NULL), 1783, 0),
 ('orders','null_customer_date',        (SELECT COUNT(*) FROM p_orders WHERE ts_customer IS NULL), 2965, 0),
 ('orders','delivered_without_customer_date', (SELECT COUNT(*) FROM p_orders WHERE order_status='delivered' AND ts_customer IS NULL), 8, 0),
 ('orders','canceled_with_customer_date',     (SELECT COUNT(*) FROM p_orders WHERE order_status='canceled' AND ts_customer IS NOT NULL), 6, 0),
 ('orders','shipped_with_customer_date',      (SELECT COUNT(*) FROM p_orders WHERE order_status='shipped' AND ts_customer IS NOT NULL), 0, 0),
 ('orders','carrier_lt_purchase',       (SELECT COUNT(*) FROM p_orders WHERE ts_carrier < ts_purchase), 166, 0),
 ('orders','carrier_lt_approved',       (SELECT COUNT(*) FROM p_orders WHERE ts_carrier < ts_approved), 1359, 0),
 ('orders','customer_lt_carrier',       (SELECT COUNT(*) FROM p_orders WHERE ts_customer < ts_carrier), 23, 0),
 ('orders','with_customer_date',        (SELECT COUNT(*) FROM p_orders WHERE ts_customer IS NOT NULL), 96476, 0),
 ('orders','late_by_timestamp_raw',     (SELECT COUNT(*) FROM p_orders WHERE ts_customer > ts_estimated), 7827, 0),
 ('orders','late_by_timestamp_raw_pct', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE ts_customer > ts_estimated) / COUNT(*), 2) FROM p_orders WHERE ts_customer IS NOT NULL), 8.11, 0.011),
 ('orders','estimated_not_midnight',    (SELECT COUNT(*) FROM p_orders WHERE ts_estimated IS NOT NULL AND ts_estimated <> date_trunc('day', ts_estimated)), 0, 0),
 ('orders','delivery_days_median',      (SELECT ROUND(quantile_cont(date_diff('second', ts_purchase, ts_customer) / 86400.0, 0.5), 2) FROM p_orders WHERE ts_customer IS NOT NULL), 10.21, 0.011),
 ('orders','delivery_days_p95',         (SELECT ROUND(quantile_cont(date_diff('second', ts_purchase, ts_customer) / 86400.0, 0.95), 2) FROM p_orders WHERE ts_customer IS NOT NULL), 29.29, 0.011),
 ('orders','delivery_days_max',         (SELECT ROUND(MAX(date_diff('second', ts_purchase, ts_customer) / 86400.0), 2) FROM p_orders WHERE ts_customer IS NOT NULL), 209.63, 0.011),
 ('orders','outside_2016-09_2018-10',   (SELECT COUNT(*) FROM p_orders WHERE ts_purchase IS NULL OR ts_purchase < TIMESTAMP '2016-09-01' OR ts_purchase >= TIMESTAMP '2018-11-01'), 0, 0),
 ('orders','month_2016-09',             (SELECT n_orders FROM prof_monthly WHERE bulan='2016-09'), 4, 0),
 ('orders','month_2016-10',             (SELECT n_orders FROM prof_monthly WHERE bulan='2016-10'), 324, 0),
 ('orders','month_2016-11',             (SELECT n_orders FROM prof_monthly WHERE bulan='2016-11'), 0, 0),
 ('orders','month_2016-12',             (SELECT n_orders FROM prof_monthly WHERE bulan='2016-12'), 1, 0),
 ('orders','month_2017-11',             (SELECT n_orders FROM prof_monthly WHERE bulan='2017-11'), 7544, 0),
 ('orders','month_2018-09',             (SELECT n_orders FROM prof_monthly WHERE bulan='2018-09'), 16, 0),
 ('orders','month_2018-10',             (SELECT n_orders FROM prof_monthly WHERE bulan='2018-10'), 4, 0),
 ('orders','pct_in_flight_2017-01',     (SELECT pct_in_flight FROM prof_monthly WHERE bulan='2017-01'), 4.63, 0.011),
 ('orders','timestamp_cast_failures',   (SELECT COUNT(*) FILTER (WHERE order_purchase_timestamp IS NOT NULL AND TRY_CAST(order_purchase_timestamp AS TIMESTAMP) IS NULL)
                                              + COUNT(*) FILTER (WHERE order_approved_at IS NOT NULL AND TRY_CAST(order_approved_at AS TIMESTAMP) IS NULL)
                                              + COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NOT NULL AND TRY_CAST(order_delivered_carrier_date AS TIMESTAMP) IS NULL)
                                              + COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL AND TRY_CAST(order_delivered_customer_date AS TIMESTAMP) IS NULL)
                                              + COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NOT NULL AND TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) IS NULL)
                                       FROM raw_orders), 0, 0);

-- 11.2 customers
INSERT INTO prof_findings_raw VALUES
 ('customers','n_rows',                   (SELECT COUNT(*) FROM raw_customers), 99441, 0),
 ('customers','n_distinct_customer_id',   (SELECT COUNT(DISTINCT customer_id) FROM raw_customers), 99441, 0),
 ('customers','n_distinct_unique_id',     (SELECT COUNT(DISTINCT customer_unique_id) FROM raw_customers), 96096, 0),
 ('customers','unique_id_multi_customer_id (repeat mentah)',
        (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM raw_customers GROUP BY 1 HAVING COUNT(*) > 1)), 2997, 0),
 ('customers','unique_id_single_order',
        (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM raw_customers GROUP BY 1 HAVING COUNT(*) = 1)), 93099, 0),
 ('customers','unique_id_single_order_pct',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n = 1) / COUNT(*), 2) FROM (SELECT COUNT(*) AS n FROM raw_customers GROUP BY customer_unique_id)), 96.88, 0.011),
 ('customers','unique_id_multi_zip',
        (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM raw_customers GROUP BY 1 HAVING COUNT(DISTINCT customer_zip_code_prefix) > 1)), 250, 0),
 ('customers','unique_id_multi_city',
        (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM raw_customers GROUP BY 1 HAVING COUNT(DISTINCT customer_city) > 1)), 122, 0),
 ('customers','unique_id_multi_state',
        (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM raw_customers GROUP BY 1 HAVING COUNT(DISTINCT customer_state) > 1)), 39, 0),
 ('customers','zip_not_5_chars',          (SELECT COUNT(*) FROM raw_customers WHERE LENGTH(customer_zip_code_prefix) <> 5), 0, 0),
 ('customers','zip_leading_zero_pct',     (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE customer_zip_code_prefix LIKE '0%') / COUNT(*), 2) FROM raw_customers), 24.13, 0.011),
 ('customers','zip_in_multi_city',
        (SELECT COUNT(*) FROM (SELECT customer_zip_code_prefix FROM raw_customers GROUP BY 1 HAVING COUNT(DISTINCT customer_city) > 1)), 39, 0),
 ('customers','n_states',                 (SELECT COUNT(DISTINCT customer_state) FROM raw_customers), 27, 0);

-- 11.3 order_items
INSERT INTO prof_findings_raw VALUES
 ('order_items','n_rows',                 (SELECT COUNT(*) FROM raw_order_items), 112650, 0),
 ('order_items','n_distinct_orders',      (SELECT COUNT(DISTINCT order_id) FROM raw_order_items), 98666, 0),
 ('order_items','orders_without_items',
        (SELECT COUNT(*) FROM raw_orders o WHERE NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)), 775, 0),
 ('order_items','orders_without_items_unavailable',
        (SELECT COUNT(*) FROM raw_orders o WHERE o.order_status = 'unavailable' AND NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)), 603, 0),
 ('order_items','orders_without_items_canceled',
        (SELECT COUNT(*) FROM raw_orders o WHERE o.order_status = 'canceled' AND NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)), 164, 0),
 ('order_items','single_item_orders',
        (SELECT COUNT(*) FROM (SELECT order_id FROM raw_order_items GROUP BY 1 HAVING COUNT(*) = 1)), 88863, 0),
 ('order_items','single_item_orders_pct',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n = 1) / COUNT(*), 2) FROM (SELECT COUNT(*) AS n FROM raw_order_items GROUP BY order_id)), 90.06, 0.011),
 ('order_items','max_items_per_order',
        (SELECT MAX(n) FROM (SELECT COUNT(*) AS n FROM raw_order_items GROUP BY order_id)), 21, 0),
 ('order_items','repeated_order_product_pairs',
        (SELECT COUNT(*) FROM (SELECT order_id, product_id FROM raw_order_items GROUP BY 1, 2 HAVING COUNT(*) > 1)), 7088, 0),
 ('order_items','multi_seller_orders',
        (SELECT COUNT(*) FROM (SELECT order_id FROM raw_order_items GROUP BY 1 HAVING COUNT(DISTINCT seller_id) > 1)), 1278, 0),
 ('order_items','multi_product_orders',
        (SELECT COUNT(*) FROM (SELECT order_id FROM raw_order_items GROUP BY 1 HAVING COUNT(DISTINCT product_id) > 1)), 3236, 0),
 ('order_items','freight_zero_rows',      (SELECT COUNT(*) FROM p_items WHERE freight = 0), 383, 0),
 ('order_items','price_iqr_outliers',
        (SELECT COUNT(*) FROM p_items, (SELECT quantile_cont(price, 0.25) AS q1, quantile_cont(price, 0.75) AS q3 FROM p_items) q
         WHERE price > q3 + 1.5 * (q3 - q1) OR price < q1 - 1.5 * (q3 - q1)), 8427, 0),
 ('order_items','price_iqr_outliers_pct',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE price > q3 + 1.5 * (q3 - q1) OR price < q1 - 1.5 * (q3 - q1)) / COUNT(*), 2)
         FROM p_items, (SELECT quantile_cont(price, 0.25) AS q1, quantile_cont(price, 0.75) AS q3 FROM p_items) q), 7.48, 0.011),
 ('order_items','price_max',              (SELECT ROUND(MAX(price), 2) FROM p_items), 6735, 0.011),
 ('order_items','shipping_limit_year_2020_rows',   (SELECT COUNT(*) FROM p_items WHERE year(ts_limit) = 2020), 4, 0),
 ('order_items','shipping_limit_year_2020_orders', (SELECT COUNT(DISTINCT order_id) FROM p_items WHERE year(ts_limit) = 2020), 3, 0),
 ('order_items','cast_failures (price, freight, shipping_limit)',
        (SELECT COUNT(*) FILTER (WHERE price IS NOT NULL AND TRY_CAST(price AS DOUBLE) IS NULL)
              + COUNT(*) FILTER (WHERE freight_value IS NOT NULL AND TRY_CAST(freight_value AS DOUBLE) IS NULL)
              + COUNT(*) FILTER (WHERE shipping_limit_date IS NOT NULL AND TRY_CAST(shipping_limit_date AS TIMESTAMP) IS NULL)
         FROM raw_order_items), 0, 0);

-- 11.4 order_payments
INSERT INTO prof_findings_raw VALUES
 ('order_payments','n_rows',              (SELECT COUNT(*) FROM raw_order_payments), 103886, 0),
 ('order_payments','n_distinct_orders',   (SELECT COUNT(DISTINCT order_id) FROM raw_order_payments), 99440, 0),
 ('order_payments','orders_without_payment',
        (SELECT COUNT(*) FROM raw_orders o WHERE NOT EXISTS (SELECT 1 FROM raw_order_payments p WHERE p.order_id = o.order_id)), 1, 0),
 ('order_payments','credit_card_pct',     (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'credit_card') / COUNT(*), 2) FROM raw_order_payments), 73.92, 0.011),
 ('order_payments','boleto_pct',          (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'boleto') / COUNT(*), 2) FROM raw_order_payments), 19.04, 0.011),
 ('order_payments','voucher_pct',         (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'voucher') / COUNT(*), 2) FROM raw_order_payments), 5.56, 0.011),
 ('order_payments','debit_card_pct',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'debit_card') / COUNT(*), 2) FROM raw_order_payments), 1.47, 0.011),
 ('order_payments','not_defined_rows',    (SELECT COUNT(*) FROM raw_order_payments WHERE payment_type = 'not_defined'), 3, 0),
 ('order_payments','orders_multi_type',
        (SELECT COUNT(*) FROM (SELECT order_id FROM raw_order_payments GROUP BY 1 HAVING COUNT(DISTINCT payment_type) > 1)), 2246, 0),
 ('order_payments','orders_multi_type_pct',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n_type > 1) / COUNT(*), 2) FROM (SELECT COUNT(DISTINCT payment_type) AS n_type FROM raw_order_payments GROUP BY order_id)), 2.26, 0.011),
 ('order_payments','orders_without_sequential_1',
        (SELECT COUNT(*) FROM (SELECT order_id FROM p_pay GROUP BY 1 HAVING COUNT(*) FILTER (WHERE seq = 1) = 0)), 80, 0),
 ('order_payments','payment_value_zero_rows',  (SELECT COUNT(*) FROM p_pay WHERE pay_value = 0), 9, 0),
 ('order_payments','installments_zero_rows',   (SELECT COUNT(*) FROM p_pay WHERE installments = 0), 2, 0),
 ('order_payments','recon_orders_compared',    (SELECT COUNT(*) FROM p_recon), 98665, 0),
 ('order_payments','recon_diff_le_001',        (SELECT COUNT(*) FROM p_recon WHERE diff <= 0.01), 98285, 0),
 ('order_payments','recon_diff_001_1',         (SELECT COUNT(*) FROM p_recon WHERE diff > 0.01 AND diff <= 1), 131, 0),
 ('order_payments','recon_diff_gt_1',          (SELECT COUNT(*) FROM p_recon WHERE diff > 1), 249, 0),
 ('order_payments','recon_diff_max',           (SELECT MAX(diff) FROM p_recon), 182.81, 0.011),
 ('order_payments','recon_le_001_pct',         (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE diff <= 0.01) / COUNT(*), 3) FROM p_recon), 99.615, 0.0011),
 ('order_payments','recon_fanout_check (SUM item_total agregat - SUM price+freight raw)',
        (SELECT ROUND(ABS((SELECT SUM(item_total) FROM p_recon) - (SELECT SUM(price + freight) FROM p_items WHERE order_id IN (SELECT order_id FROM p_recon))), 2)), 0, 0.011),
 ('order_payments','payment_orders_without_items',
        (SELECT COUNT(DISTINCT p.order_id) FROM raw_order_payments p WHERE NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = p.order_id)), 775, 0),
 ('order_payments','payment_value_orders_without_items',
        (SELECT ROUND(SUM(pay_value), 2) FROM p_pay p WHERE NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = p.order_id)), 162591.95, 0.011),
 ('order_payments','cast_failures (seq, installments, value)',
        (SELECT COUNT(*) FILTER (WHERE payment_sequential IS NOT NULL AND TRY_CAST(payment_sequential AS INTEGER) IS NULL)
              + COUNT(*) FILTER (WHERE payment_installments IS NOT NULL AND TRY_CAST(payment_installments AS INTEGER) IS NULL)
              + COUNT(*) FILTER (WHERE payment_value IS NOT NULL AND TRY_CAST(payment_value AS DOUBLE) IS NULL)
         FROM raw_order_payments), 0, 0);

-- 11.5 order_reviews
INSERT INTO prof_findings_raw VALUES
 ('order_reviews','n_rows',               (SELECT COUNT(*) FROM raw_order_reviews), 99224, 0),
 ('order_reviews','n_distinct_orders',    (SELECT COUNT(DISTINCT order_id) FROM raw_order_reviews), 98673, 0),
 ('order_reviews','orders_multi_review',
        (SELECT COUNT(*) FROM (SELECT order_id FROM raw_order_reviews GROUP BY 1 HAVING COUNT(*) > 1)), 547, 0),
 ('order_reviews','review_id_in_multi_orders',
        (SELECT COUNT(*) FROM (SELECT review_id FROM raw_order_reviews GROUP BY 1 HAVING COUNT(DISTINCT order_id) > 1)), 789, 0),
 ('order_reviews','orders_without_review',
        (SELECT COUNT(*) FROM raw_orders o WHERE NOT EXISTS (SELECT 1 FROM raw_order_reviews r WHERE r.order_id = o.order_id)), 768, 0),
 ('order_reviews','score_avg_raw_rows',   (SELECT ROUND(AVG(score), 3) FROM p_rev), 4.086, 0.0011),
 ('order_reviews','score_5_pct',          (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE score = 5) / COUNT(*), 2) FROM p_rev), 57.78, 0.011),
 ('order_reviews','score_4_pct',          (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE score = 4) / COUNT(*), 2) FROM p_rev), 19.29, 0.011),
 ('order_reviews','score_1_pct',          (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE score = 1) / COUNT(*), 2) FROM p_rev), 11.51, 0.011),
 ('order_reviews','score_invalid_or_uncastable',
        (SELECT COUNT(*) FROM raw_order_reviews WHERE TRY_CAST(review_score AS INTEGER) IS NULL OR TRY_CAST(review_score AS INTEGER) NOT BETWEEN 1 AND 5), 0, 0),
 ('order_reviews','title_null_pct',       (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_comment_title IS NULL) / COUNT(*), 2) FROM raw_order_reviews), 88.34, 0.011),
 ('order_reviews','message_null_pct',     (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_comment_message IS NULL) / COUNT(*), 2) FROM raw_order_reviews), 58.70, 0.011),
 ('order_reviews','message_whitespace_only',
        (SELECT COUNT(*) FROM raw_order_reviews WHERE review_comment_message IS NOT NULL AND TRIM(review_comment_message) = ''), 27, 0),
 ('order_reviews','review_created_before_purchase',
        (SELECT COUNT(*) FROM p_rev r JOIN p_orders o ON o.order_id = r.order_id WHERE r.ts_created < o.ts_purchase), 74, 0),
 ('order_reviews','timestamp_cast_failures',
        (SELECT COUNT(*) FILTER (WHERE review_creation_date IS NOT NULL AND TRY_CAST(review_creation_date AS TIMESTAMP) IS NULL)
              + COUNT(*) FILTER (WHERE review_answer_timestamp IS NOT NULL AND TRY_CAST(review_answer_timestamp AS TIMESTAMP) IS NULL)
         FROM raw_order_reviews), 0, 0);

-- 11.6 products & category_translation
INSERT INTO prof_findings_raw VALUES
 ('products','n_rows',                    (SELECT COUNT(*) FROM raw_products), 32951, 0),
 ('products','null_category',             (SELECT COUNT(*) FROM raw_products WHERE product_category_name IS NULL), 610, 0),
 ('products','null_category_name_desc_photos_all',
        (SELECT COUNT(*) FROM p_prod WHERE product_category_name IS NULL AND name_len IS NULL AND desc_len IS NULL AND photos IS NULL), 610, 0),
 ('products','no_weight_and_dimensions',
        (SELECT COUNT(*) FROM p_prod WHERE weight_g IS NULL AND length_cm IS NULL AND height_cm IS NULL AND width_cm IS NULL), 2, 0),
 ('products','weight_zero',               (SELECT COUNT(*) FROM p_prod WHERE weight_g = 0), 4, 0),
 ('products','categories_without_translation',
        (SELECT COUNT(DISTINCT p.product_category_name) FROM raw_products p LEFT JOIN raw_category_translation t USING (product_category_name)
         WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL), 2, 0),
 ('products','products_in_untranslated_categories',
        (SELECT COUNT(*) FROM raw_products p LEFT JOIN raw_category_translation t USING (product_category_name)
         WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL), 13, 0),
 ('category_translation','n_rows',        (SELECT COUNT(*) FROM raw_category_translation), 71, 0);

-- 11.7 sellers
INSERT INTO prof_findings_raw VALUES
 ('sellers','n_rows',                     (SELECT COUNT(*) FROM raw_sellers), 3095, 0),
 ('sellers','n_distinct_seller_id',       (SELECT COUNT(DISTINCT seller_id) FROM raw_sellers), 3095, 0),
 ('sellers','n_states',                   (SELECT COUNT(DISTINCT seller_state) FROM raw_sellers), 23, 0),
 ('sellers','customer_states_without_seller',
        (SELECT COUNT(DISTINCT customer_state) FROM raw_customers WHERE customer_state NOT IN (SELECT DISTINCT seller_state FROM raw_sellers)), 4, 0),
 ('sellers','dirty_seller_city (heuristik)',
        (SELECT COUNT(*) FROM raw_sellers WHERE regexp_matches(seller_city, '[0-9@/,]| - ')), 34, 0);

-- 11.8 geolocation
INSERT INTO prof_findings_raw VALUES
 ('geolocation','n_rows',                 (SELECT COUNT(*) FROM raw_geolocation), 1000163, 0),
 ('geolocation','full_duplicate_rows',
        (SELECT (SELECT COUNT(*) FROM raw_geolocation) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_geolocation))), 261831, 0),
 ('geolocation','full_duplicate_pct',
        (SELECT ROUND(100.0 * ((SELECT COUNT(*) FROM raw_geolocation) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_geolocation))) / (SELECT COUNT(*) FROM raw_geolocation), 2)), 26.18, 0.011),
 ('geolocation','zip_multi_coordinate_pct',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n > 1) / COUNT(*), 1)
         FROM (SELECT COUNT(DISTINCT (lat, lng)) AS n FROM p_geo GROUP BY zip)), 93.5, 0.06),
 ('geolocation','zip_multi_city_pct',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n > 1) / COUNT(*), 1)
         FROM (SELECT COUNT(DISTINCT city) AS n FROM p_geo GROUP BY zip)), 45.0, 0.06),
 ('geolocation','coordinates_outside_brazil_box (heuristik)',
        (SELECT COUNT(*) FROM p_geo WHERE lat NOT BETWEEN -33.75 AND 5.27 OR lng NOT BETWEEN -73.99 AND -34.79), 42, 0),
 ('geolocation','customer_rows_without_geo_zip',
        (SELECT COUNT(*) FROM raw_customers c WHERE NOT EXISTS (SELECT 1 FROM raw_geolocation g WHERE g.geolocation_zip_code_prefix = c.customer_zip_code_prefix)), 278, 0),
 ('geolocation','customer_zips_without_geo',
        (SELECT COUNT(DISTINCT c.customer_zip_code_prefix) FROM raw_customers c WHERE NOT EXISTS (SELECT 1 FROM raw_geolocation g WHERE g.geolocation_zip_code_prefix = c.customer_zip_code_prefix)), 157, 0),
 ('geolocation','seller_rows_without_geo_zip',
        (SELECT COUNT(*) FROM raw_sellers s WHERE NOT EXISTS (SELECT 1 FROM raw_geolocation g WHERE g.geolocation_zip_code_prefix = s.seller_zip_code_prefix)), 7, 0),
 ('geolocation','coordinate_cast_failures',
        (SELECT COUNT(*) FILTER (WHERE geolocation_lat IS NOT NULL AND TRY_CAST(geolocation_lat AS DOUBLE) IS NULL)
              + COUNT(*) FILTER (WHERE geolocation_lng IS NOT NULL AND TRY_CAST(geolocation_lng AS DOUBLE) IS NULL)
         FROM raw_geolocation), 0, 0);

-- 11.9 Tabel findings final + status
CREATE OR REPLACE TABLE prof_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM prof_findings_raw
ORDER BY section, metric;

-- Ringkasan status
SELECT status, COUNT(*) AS n_metrik FROM prof_findings GROUP BY status ORDER BY status;

-- Semua metrik yang BUKAN PASS (harus dijelaskan di docs/profiling_findings.md)
SELECT * FROM prof_findings WHERE status <> 'PASS' ORDER BY section, metric;

-- Semua metrik (untuk ditempel ke dokumentasi)
SELECT section, metric, n_actual, n_expected, status FROM prof_findings ORDER BY section, metric;

-- ------------------------------------------------------------
-- 12. Distribusi kategori (status, tipe pembayaran, skor) -> prof_category_dist
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE prof_category_dist AS
SELECT 'orders' AS tabel, 'order_status' AS dimensi, order_status AS nilai, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM raw_orders GROUP BY order_status
UNION ALL
SELECT 'order_payments', 'payment_type', payment_type, COUNT(*),
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)
FROM raw_order_payments GROUP BY payment_type
UNION ALL
SELECT 'order_reviews', 'review_score', CAST(score AS VARCHAR), COUNT(*),
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)
FROM p_rev GROUP BY score
UNION ALL
SELECT 'customers', 'customer_state', customer_state, COUNT(*),
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)
FROM raw_customers GROUP BY customer_state
UNION ALL
SELECT 'sellers', 'seller_state', seller_state, COUNT(*),
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)
FROM raw_sellers GROUP BY seller_state;

-- ------------------------------------------------------------
-- 13. Output: data/processed/03_profiling_summary.parquet (format long)
--     section: null_profile | category_dist | monthly | findings
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE prof_summary AS
SELECT 'null_profile' AS section, tabel, kolom AS item,
       CAST(n_null AS DOUBLE) AS n, pct_null AS pct,
       CAST(NULL AS DOUBLE) AS n_expected, CAST(NULL AS VARCHAR) AS status
FROM prof_null_summary
UNION ALL
SELECT 'category_dist', tabel, dimensi || '=' || nilai, CAST(n AS DOUBLE), pct,
       CAST(NULL AS DOUBLE), CAST(NULL AS VARCHAR)
FROM prof_category_dist
UNION ALL
SELECT 'monthly', 'orders', bulan, CAST(n_orders AS DOUBLE), pct_in_flight,
       CAST(NULL AS DOUBLE), CAST(NULL AS VARCHAR)
FROM prof_monthly
UNION ALL
SELECT 'findings', section, metric, n_actual, CAST(NULL AS DOUBLE), n_expected, status
FROM prof_findings;

COPY prof_summary TO 'data/processed/03_profiling_summary.parquet' (FORMAT PARQUET);

-- Verifikasi output
SELECT section, COUNT(*) AS n_baris FROM prof_summary GROUP BY section ORDER BY section;
SELECT COUNT(*) AS n_baris_parquet FROM read_parquet('data/processed/03_profiling_summary.parquet');
