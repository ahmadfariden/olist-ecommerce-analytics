-- ============================================================
-- Tahap 8 — Data Modeling (star schema: 5 dimensi, 4 fakta)
-- File: sql/07_data_modeling.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/07_data_modeling.sql
-- Prasyarat: sql/04_data_cleaning.sql dan sql/05_data_validation.sql sudah dijalankan.
-- ============================================================
-- GRAIN:       dim_customer = 1 customer_unique_id | dim_seller = 1 seller_id |
--              dim_product = 1 product_id | dim_geo_zip = 1 zip prefix | dim_date = 1 hari |
--              fact_order_items = 1 item | fact_orders = 1 order |
--              fact_payments = 1 pembayaran | fact_reviews = 1 review per order (dedup)
-- POPULATION:  Order Population (99.441) dan Item Population (112.650) tidak berubah;
--              model hanya merepresentasikan data yang sudah Profiled -> Cleaned -> Validated -> KPI Locked
-- DENOMINATOR: n/a (tidak ada metrik rate di tahap ini; KPI hanya di-recompute untuk rekonsiliasi)
-- ============================================================
-- Catatan desain:
--   * dim_customer dan dim_geo_zip sudah dibangun di Tahap 5 dengan grain yang sama;
--     di sini keduanya divalidasi dan diekspor sebagai bagian dari model.
--   * Key = natural key (customer_unique_id, seller_id, product_id, zip prefix, date).
--   * dim_geo_zip diberi baris placeholder (is_placeholder = TRUE, lat/lng NULL) untuk zip
--     customer/seller yang tidak ada di geolocation, supaya FK tidak orphan. Cakupan koordinat
--     tidak berubah (baris tersebut tetap tanpa koordinat).
--   * Fakta membawa flag populasi (is_revenue_order, in_analysis_window) agar BI tidak
--     menjumlahkan item dari order canceled/unavailable.
--   * Ukuran uang tetap DECIMAL(12,2). Ukuran yang tidak ada nilainya (mis. payment_total
--     untuk order tanpa payment) = NULL, bukan 0.
--   * Teks komentar review tidak dibawa ke model (NLP di luar scope); has_comment cukup.
-- ============================================================

-- ------------------------------------------------------------
-- 1. dim_geo_zip: tambah placeholder untuk zip yang tidak ada di geolocation
-- ------------------------------------------------------------
ALTER TABLE dim_geo_zip ADD COLUMN IF NOT EXISTS is_placeholder BOOLEAN DEFAULT FALSE;

INSERT INTO dim_geo_zip (zip, lat, lng, city, state, n_points_dedup, n_points_valid, is_placeholder)
SELECT z.zip, NULL, NULL, 'unknown', z.state, 0, 0, TRUE
FROM (SELECT zip, MIN(state) AS state
      FROM (SELECT zip_prefix AS zip, state FROM stg_customers
            UNION ALL
            SELECT zip_prefix AS zip, seller_state FROM stg_sellers)
      GROUP BY zip) z
WHERE z.zip NOT IN (SELECT zip FROM dim_geo_zip);

-- ------------------------------------------------------------
-- 2. dim_seller (1 baris = 1 seller)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE dim_seller AS
SELECT seller_id, seller_state, seller_city_clean, seller_city_raw,
       seller_zip_prefix, flag_city_cleaned
FROM sellers_clean;

-- ------------------------------------------------------------
-- 3. dim_product (1 baris = 1 produk; 610 produk kategori 'unknown')
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE dim_product AS
SELECT product_id,
       category_pt,
       category_en AS category_en_clean,
       weight_g, length_cm, height_cm, width_cm,
       photos_qty, name_length, description_length,
       flag_category_unknown, flag_weight_invalid
FROM products_clean;

-- ------------------------------------------------------------
-- 4. dim_date (1 baris = 1 hari, 2016-09-01 s.d. 2018-10-31)
--    period_quality: missing / sparse_rampup / truncated / full (in_analysis_window = full)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE dim_date AS
SELECT d                                          AS date_key,
       year(d)                                    AS year,
       quarter(d)                                 AS quarter,
       month(d)                                   AS month,
       monthname(d)                               AS month_name,
       strftime(d, '%Y-%m')                       AS year_month,
       strftime(d, '%Y') || '-Q' || CAST(quarter(d) AS VARCHAR) AS year_quarter,
       day(d)                                     AS day_of_month,
       isodow(d)                                  AS day_of_week,
       dayname(d)                                 AS day_name,
       (isodow(d) >= 6)                           AS is_weekend,
       CASE WHEN strftime(d, '%Y-%m') = '2016-11' THEN 'missing'
            WHEN strftime(d, '%Y-%m') IN ('2016-09', '2016-10', '2016-12') THEN 'sparse_rampup'
            WHEN strftime(d, '%Y-%m') IN ('2018-09', '2018-10') THEN 'truncated'
            ELSE 'full' END                       AS period_quality,
       (d >= DATE '2017-01-01' AND d < DATE '2018-09-01') AS in_analysis_window
FROM (SELECT CAST(g AS DATE) AS d
      FROM generate_series(DATE '2016-09-01', DATE '2018-10-31', INTERVAL 1 DAY) AS t(g));

-- ------------------------------------------------------------
-- 5. fact_orders (1 baris = 1 order, n = 99.441)
--    Tabel anak di-pre-aggregate ke grain order_id sebelum join (Fan-out Guard).
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE fact_orders AS
WITH it AS (
    SELECT order_id,
           SUM(price)                  AS item_revenue,
           SUM(freight_value)          AS freight_total,
           COUNT(DISTINCT product_id)  AS n_products,
           CASE WHEN COUNT(DISTINCT seller_id) = 1 THEN MIN(seller_id) END AS single_seller_id
    FROM order_items_clean GROUP BY order_id
), pay AS (
    SELECT order_id, SUM(payment_value) AS payment_total, MAX(payment_installments) AS max_installments
    FROM order_payments_clean GROUP BY order_id
)
SELECT o.order_id, o.customer_id, o.customer_unique_id,
       o.customer_zip_prefix, o.customer_city, o.customer_state,
       o.order_status,
       CAST(o.ts_purchase AS DATE) AS purchase_date,
       o.ts_purchase, o.ts_approved, o.ts_carrier, o.ts_customer, o.ts_estimated,
       -- ringkasan pre-aggregated
       o.n_items, o.n_sellers, COALESCE(it.n_products, 0) AS n_products, it.single_seller_id,
       it.item_revenue, it.freight_total,
       pay.payment_total, o.n_payment_types, pay.max_installments,
       r.review_score, o.n_reviews_raw,
       -- Analytical Flags (Tahap 5/6, tidak berubah)
       o.has_items, o.is_canceled, o.is_unavailable, o.is_revenue_order,
       o.is_delivered_complete, o.in_analysis_window, o.has_review,
       o.is_multi_seller, o.is_multi_payment_type,
       (o.is_revenue_order AND NOT o.is_multi_seller) AS is_single_seller_pop,
       o.delivery_days, o.is_late, o.is_late_ts_sensitivity,
       -- flag anomali timestamp
       o.flag_carrier_before_purchase, o.flag_carrier_before_approved, o.flag_customer_before_carrier,
       o.flag_delivered_no_date, o.flag_canceled_has_delivery_date
FROM orders_clean o
LEFT JOIN it  ON it.order_id  = o.order_id
LEFT JOIN pay ON pay.order_id = o.order_id
LEFT JOIN order_reviews_clean r ON r.order_id = o.order_id;

-- ------------------------------------------------------------
-- 6. fact_order_items (1 baris = 1 item, n = 112.650)
--    qty_units berulang di tiap baris pasangan (order, produk): JANGAN di-SUM; unit = COUNT(*).
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE fact_order_items AS
SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id,
       o.customer_unique_id,
       CAST(o.ts_purchase AS DATE) AS purchase_date,
       o.order_status,
       i.ts_shipping_limit,
       i.price, i.freight_value, i.qty_units,
       i.flag_zero_freight, i.flag_shipping_limit_invalid,
       o.is_revenue_order, o.in_analysis_window
FROM order_items_clean i
JOIN orders_clean o ON o.order_id = i.order_id;

-- ------------------------------------------------------------
-- 7. fact_payments (1 baris = 1 pembayaran, n = 103.886)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE fact_payments AS
SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value,
       flag_zero_payment, flag_payment_not_defined, flag_zero_installments, flag_no_first_payment
FROM order_payments_clean;

-- ------------------------------------------------------------
-- 8. fact_reviews (1 baris = 1 review per order, dedup D3)
--    answered_before_delivery: review dijawab sebelum barang diterima (NULL jika belum ada tanggal terima)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE fact_reviews AS
SELECT r.review_id, r.order_id, r.review_score, r.has_comment,
       r.review_creation_ts, r.review_answer_ts,
       date_diff('second', r.review_creation_ts, r.review_answer_ts) / 86400.0 AS answer_lag_days,
       r.n_reviews_raw,
       (r.review_answer_ts < o.ts_customer) AS answered_before_delivery,
       o.is_delivered_complete, o.is_late,
       r.flag_review_before_purchase
FROM order_reviews_clean r
LEFT JOIN orders_clean o ON o.order_id = r.order_id;

-- ------------------------------------------------------------
-- 9. Validasi model
--    HARD = gate (harus semua PASS); KPI = recompute KPI terkunci dari model; INFO = informasi
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE m_raw (
    category VARCHAR, rule VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE, severity VARCHAR
);

-- 9.1 Row count (Acceptance Criteria)
INSERT INTO m_raw VALUES
 ('rowcount','fact_orders = Order Population',        (SELECT COUNT(*) FROM fact_orders),      99441, 0, 'HARD'),
 ('rowcount','fact_order_items = Item Population',    (SELECT COUNT(*) FROM fact_order_items), 112650, 0, 'HARD'),
 ('rowcount','fact_payments',                         (SELECT COUNT(*) FROM fact_payments),    103886, 0, 'HARD'),
 ('rowcount','fact_reviews = order ber-review',       (SELECT COUNT(*) FROM fact_reviews),     (SELECT COUNT(DISTINCT order_id) FROM raw_order_reviews), 0, 'HARD'),
 ('rowcount','dim_customer = customer_unique_id',     (SELECT COUNT(*) FROM dim_customer),     96096, 0, 'HARD'),
 ('rowcount','dim_seller',                            (SELECT COUNT(*) FROM dim_seller),       3095, 0, 'HARD'),
 ('rowcount','dim_product',                           (SELECT COUNT(*) FROM dim_product),      32951, 0, 'HARD'),
 ('rowcount','dim_geo_zip (non-placeholder)',         (SELECT COUNT(*) FROM dim_geo_zip WHERE NOT is_placeholder), 19015, 0, 'HARD'),
 ('rowcount','dim_date = jumlah hari 2016-09-01..2018-10-31', (SELECT COUNT(*) FROM dim_date), 791, 0, 'HARD'),
 ('rowcount','dim_geo_zip placeholder (zip customer/seller tanpa geolocation)', (SELECT COUNT(*) FROM dim_geo_zip WHERE is_placeholder), NULL, 0, 'INFO');

-- 9.2 Grain: duplikat key = 0
INSERT INTO m_raw VALUES
 ('grain','fact_orders.order_id (dup)',                       (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM fact_orders), 0, 0, 'HARD'),
 ('grain','fact_order_items (order_id, order_item_id) (dup)', (SELECT COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)) FROM fact_order_items), 0, 0, 'HARD'),
 ('grain','fact_payments (order_id, payment_sequential) (dup)', (SELECT COUNT(*) - COUNT(DISTINCT (order_id, payment_sequential)) FROM fact_payments), 0, 0, 'HARD'),
 ('grain','fact_reviews.order_id (dup)',                      (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM fact_reviews), 0, 0, 'HARD'),
 ('grain','dim_customer.customer_unique_id (dup)',            (SELECT COUNT(*) - COUNT(DISTINCT customer_unique_id) FROM dim_customer), 0, 0, 'HARD'),
 ('grain','dim_seller.seller_id (dup)',                       (SELECT COUNT(*) - COUNT(DISTINCT seller_id) FROM dim_seller), 0, 0, 'HARD'),
 ('grain','dim_product.product_id (dup)',                     (SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM dim_product), 0, 0, 'HARD'),
 ('grain','dim_geo_zip.zip (dup)',                            (SELECT COUNT(*) - COUNT(DISTINCT zip) FROM dim_geo_zip), 0, 0, 'HARD'),
 ('grain','dim_date.date_key (dup)',                          (SELECT COUNT(*) - COUNT(DISTINCT date_key) FROM dim_date), 0, 0, 'HARD');

-- 9.3 Key integrity: FK tanpa pasangan di dimensi (orphan) = 0
INSERT INTO m_raw VALUES
 ('fk','fact_orders.customer_unique_id -> dim_customer',  (SELECT COUNT(*) FROM fact_orders f LEFT JOIN dim_customer d USING (customer_unique_id) WHERE d.customer_unique_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_orders.purchase_date -> dim_date',           (SELECT COUNT(*) FROM fact_orders f LEFT JOIN dim_date d ON d.date_key = f.purchase_date WHERE d.date_key IS NULL), 0, 0, 'HARD'),
 ('fk','fact_orders.customer_zip_prefix -> dim_geo_zip',  (SELECT COUNT(*) FROM fact_orders f LEFT JOIN dim_geo_zip d ON d.zip = f.customer_zip_prefix WHERE d.zip IS NULL), 0, 0, 'HARD'),
 ('fk','fact_orders.single_seller_id -> dim_seller',      (SELECT COUNT(*) FROM fact_orders f LEFT JOIN dim_seller d ON d.seller_id = f.single_seller_id WHERE f.single_seller_id IS NOT NULL AND d.seller_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_order_items.order_id -> fact_orders',        (SELECT COUNT(*) FROM fact_order_items f LEFT JOIN fact_orders d USING (order_id) WHERE d.order_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_order_items.product_id -> dim_product',      (SELECT COUNT(*) FROM fact_order_items f LEFT JOIN dim_product d USING (product_id) WHERE d.product_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_order_items.seller_id -> dim_seller',        (SELECT COUNT(*) FROM fact_order_items f LEFT JOIN dim_seller d USING (seller_id) WHERE d.seller_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_order_items.customer_unique_id -> dim_customer', (SELECT COUNT(*) FROM fact_order_items f LEFT JOIN dim_customer d USING (customer_unique_id) WHERE d.customer_unique_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_order_items.purchase_date -> dim_date',      (SELECT COUNT(*) FROM fact_order_items f LEFT JOIN dim_date d ON d.date_key = f.purchase_date WHERE d.date_key IS NULL), 0, 0, 'HARD'),
 ('fk','fact_payments.order_id -> fact_orders',           (SELECT COUNT(*) FROM fact_payments f LEFT JOIN fact_orders d USING (order_id) WHERE d.order_id IS NULL), 0, 0, 'HARD'),
 ('fk','fact_reviews.order_id -> fact_orders',            (SELECT COUNT(*) FROM fact_reviews f LEFT JOIN fact_orders d USING (order_id) WHERE d.order_id IS NULL), 0, 0, 'HARD'),
 ('fk','dim_seller.seller_zip_prefix -> dim_geo_zip',     (SELECT COUNT(*) FROM dim_seller s LEFT JOIN dim_geo_zip d ON d.zip = s.seller_zip_prefix WHERE d.zip IS NULL), 0, 0, 'HARD'),
 ('fk','dim_customer.zip_latest_order -> dim_geo_zip',    (SELECT COUNT(*) FROM dim_customer c LEFT JOIN dim_geo_zip d ON d.zip = c.zip_latest_order WHERE d.zip IS NULL), 0, 0, 'HARD'),
 ('fk','produk kategori unknown ada di dim_product',      (SELECT COUNT(*) FROM dim_product WHERE category_en_clean = 'unknown'), 610, 0, 'HARD'),
 ('fk','dim_product.category_en_clean NULL',              (SELECT COUNT(*) FROM dim_product WHERE category_en_clean IS NULL), 0, 0, 'HARD');

-- 9.4 Fan-out test (Acceptance Criteria)
INSERT INTO m_raw VALUES
 ('fanout','SUM(price) fact_order_items - SUM(price) stg',           (SELECT CAST(ABS((SELECT SUM(price) FROM fact_order_items) - (SELECT SUM(price) FROM stg_order_items)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','SUM(freight_value) fact_order_items - SUM(freight) stg', (SELECT CAST(ABS((SELECT SUM(freight_value) FROM fact_order_items) - (SELECT SUM(freight_value) FROM stg_order_items)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','SUM(item_revenue) fact_orders - SUM(price) fact_order_items', (SELECT CAST(ABS((SELECT SUM(item_revenue) FROM fact_orders) - (SELECT SUM(price) FROM fact_order_items)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','SUM(freight_total) fact_orders - SUM(freight) fact_order_items', (SELECT CAST(ABS((SELECT SUM(freight_total) FROM fact_orders) - (SELECT SUM(freight_value) FROM fact_order_items)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','SUM(payment_total) fact_orders - SUM(payment_value) fact_payments', (SELECT CAST(ABS((SELECT SUM(payment_total) FROM fact_orders) - (SELECT SUM(payment_value) FROM fact_payments)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','SUM(n_items) fact_orders - COUNT(*) fact_order_items',    (SELECT ABS((SELECT SUM(n_items) FROM fact_orders) - (SELECT COUNT(*) FROM fact_order_items))), 0, 0, 'HARD'),
 ('fanout','order dengan review_score di fact_orders = jumlah fact_reviews', (SELECT COUNT(review_score) FROM fact_orders), (SELECT COUNT(*) FROM fact_reviews), 0, 'HARD'),
 ('fanout','jumlah baris fact_orders setelah join fact_order_items agregat (tetap)', (SELECT COUNT(*) FROM fact_orders o LEFT JOIN (SELECT order_id, SUM(price) AS p FROM fact_order_items GROUP BY order_id) i USING (order_id)), 99441, 0, 'HARD');

-- 9.5 Populasi dan KPI terkunci di-recompute dari model
INSERT INTO m_raw VALUES
 ('population','Revenue Orders (fact_orders.is_revenue_order)',  (SELECT COUNT(*) FROM fact_orders WHERE is_revenue_order), 98199, 0, 'KPI'),
 ('population','Delivered Population (is_delivered_complete)',   (SELECT COUNT(*) FROM fact_orders WHERE is_delivered_complete), 96470, 0, 'KPI'),
 ('population','Review Population (has_review)',                 (SELECT COUNT(*) FROM fact_orders WHERE has_review), 98673, 0, 'KPI'),
 ('population','Single-Seller Population (is_single_seller_pop)',(SELECT COUNT(*) FROM fact_orders WHERE is_single_seller_pop), 96922, 0, 'KPI'),
 ('population','Analysis Window Population',                     (SELECT COUNT(*) FROM fact_orders WHERE in_analysis_window), 99092, 0, 'KPI'),
 ('population','order tanpa item (n_items = 0)',                 (SELECT COUNT(*) FROM fact_orders WHERE n_items = 0), 775, 0, 'KPI'),
 ('kpi','Item Revenue - Revenue Population (R$) dari fact_order_items', (SELECT CAST(SUM(price) AS DOUBLE) FROM fact_order_items WHERE is_revenue_order), 13494400.74, 0.011, 'KPI'),
 ('kpi','Item Revenue - Revenue Population (R$) dari fact_orders',      (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 13494400.74, 0.011, 'KPI'),
 ('kpi','AOV (R$) = Item Revenue / Revenue Orders',            (SELECT ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2) FROM fact_orders WHERE is_revenue_order), 137.42, 0.011, 'KPI'),
 ('kpi','Freight Revenue - Revenue Population (R$)',           (SELECT CAST(SUM(freight_total) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 2241126.29, 0.011, 'KPI'),
 ('kpi','Late Rate % (Delivered Population)',                  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM fact_orders WHERE is_delivered_complete), 6.773, 0.0011, 'KPI'),
 ('kpi','Avg Review Score dari fact_reviews',                  (SELECT ROUND(AVG(review_score), 4) FROM fact_reviews), 4.0864, 0.00011, 'KPI'),
 ('kpi','Avg Review Score dari fact_orders',                   (SELECT ROUND(AVG(review_score), 4) FROM fact_orders), 4.0864, 0.00011, 'KPI'),
 ('kpi','Repeat Rate % dari dim_customer (>= 24 jam)',         (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) FROM dim_customer), 2.208, 0.0011, 'KPI'),
 ('kpi','Cancellation Rate % (Total Orders)',                  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM fact_orders), 0.629, 0.0011, 'KPI'),
 ('kpi','Payment Total (R$) fact_payments',                    (SELECT CAST(SUM(payment_value) AS DOUBLE) FROM fact_payments), 16008872.12, 0.011, 'KPI'),
 ('kpi','answered_before_delivery = TRUE (Delivered x Review)',(SELECT COUNT(*) FROM fact_reviews WHERE answered_before_delivery), 4653, 0, 'KPI');

-- 9.6 dim_date: period_quality
INSERT INTO m_raw VALUES
 ('dim_date','bulan missing (2016-11)',          (SELECT COUNT(DISTINCT year_month) FROM dim_date WHERE period_quality = 'missing'), 1, 0, 'HARD'),
 ('dim_date','bulan sparse_rampup',              (SELECT COUNT(DISTINCT year_month) FROM dim_date WHERE period_quality = 'sparse_rampup'), 3, 0, 'HARD'),
 ('dim_date','bulan truncated',                  (SELECT COUNT(DISTINCT year_month) FROM dim_date WHERE period_quality = 'truncated'), 2, 0, 'HARD'),
 ('dim_date','bulan full (Analysis Window)',     (SELECT COUNT(DISTINCT year_month) FROM dim_date WHERE period_quality = 'full'), 20, 0, 'HARD'),
 ('dim_date','period_quality full konsisten dengan in_analysis_window (baris beda)',
        (SELECT COUNT(*) FROM dim_date WHERE (period_quality = 'full') <> in_analysis_window), 0, 0, 'HARD'),
 ('dim_date','order di bulan missing (2016-11)',
        (SELECT COUNT(*) FROM fact_orders f JOIN dim_date d ON d.date_key = f.purchase_date WHERE d.period_quality = 'missing'), 0, 0, 'HARD');

CREATE OR REPLACE TABLE model_validation AS
SELECT category, rule, n_actual, n_expected, tol, severity,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE CASE WHEN severity = 'HARD' THEN 'FAIL' ELSE 'CHECK' END END AS status
FROM m_raw;

SELECT severity, status, COUNT(*) AS n_rule FROM model_validation GROUP BY severity, status ORDER BY severity, status;

SELECT CASE WHEN COUNT(*) FILTER (WHERE severity = 'HARD' AND status <> 'PASS') = 0
            THEN 'GATE PASS: semua rule HARD lolos' ELSE 'GATE FAIL: perbaiki model' END AS gate,
       COUNT(*) FILTER (WHERE severity = 'HARD')                     AS n_hard,
       COUNT(*) FILTER (WHERE severity = 'HARD' AND status = 'PASS') AS n_hard_pass,
       COUNT(*) FILTER (WHERE severity = 'KPI')                      AS n_kpi,
       COUNT(*) FILTER (WHERE severity = 'KPI' AND status = 'PASS')  AS n_kpi_pass
FROM model_validation;

SELECT category, rule, n_actual, n_expected, severity, status
FROM model_validation WHERE status <> 'PASS' ORDER BY status, category, rule;

SELECT category, rule, n_actual, n_expected, severity, status FROM model_validation ORDER BY category, rule;

-- ------------------------------------------------------------
-- 10. Ringkasan model (jumlah baris dan kolom per tabel)
-- ------------------------------------------------------------
SELECT t.tabel, t.n_baris, c.n_kolom
FROM (SELECT 'dim_customer' AS tabel, COUNT(*) AS n_baris FROM dim_customer UNION ALL
      SELECT 'dim_seller', COUNT(*) FROM dim_seller UNION ALL
      SELECT 'dim_product', COUNT(*) FROM dim_product UNION ALL
      SELECT 'dim_geo_zip', COUNT(*) FROM dim_geo_zip UNION ALL
      SELECT 'dim_date', COUNT(*) FROM dim_date UNION ALL
      SELECT 'fact_order_items', COUNT(*) FROM fact_order_items UNION ALL
      SELECT 'fact_orders', COUNT(*) FROM fact_orders UNION ALL
      SELECT 'fact_payments', COUNT(*) FROM fact_payments UNION ALL
      SELECT 'fact_reviews', COUNT(*) FROM fact_reviews) t
JOIN (SELECT table_name, COUNT(*) AS n_kolom FROM duckdb_columns()
      WHERE table_name IN ('dim_customer','dim_seller','dim_product','dim_geo_zip','dim_date',
                           'fact_order_items','fact_orders','fact_payments','fact_reviews')
      GROUP BY table_name) c ON c.table_name = t.tabel
ORDER BY t.tabel;

-- ------------------------------------------------------------
-- 11. Output parquet (model) -> data/processed/07_*.parquet
-- ------------------------------------------------------------
COPY dim_customer     TO 'data/processed/07_dim_customer.parquet'     (FORMAT PARQUET);
COPY dim_seller       TO 'data/processed/07_dim_seller.parquet'       (FORMAT PARQUET);
COPY dim_product      TO 'data/processed/07_dim_product.parquet'      (FORMAT PARQUET);
COPY dim_geo_zip      TO 'data/processed/07_dim_geo_zip.parquet'      (FORMAT PARQUET);
COPY dim_date         TO 'data/processed/07_dim_date.parquet'         (FORMAT PARQUET);
COPY fact_order_items TO 'data/processed/07_fact_order_items.parquet' (FORMAT PARQUET);
COPY fact_orders      TO 'data/processed/07_fact_orders.parquet'      (FORMAT PARQUET);
COPY fact_payments    TO 'data/processed/07_fact_payments.parquet'    (FORMAT PARQUET);
COPY fact_reviews     TO 'data/processed/07_fact_reviews.parquet'     (FORMAT PARQUET);

SELECT '07_dim_customer' AS file, COUNT(*) AS n FROM read_parquet('data/processed/07_dim_customer.parquet') UNION ALL
SELECT '07_dim_seller',       COUNT(*) FROM read_parquet('data/processed/07_dim_seller.parquet') UNION ALL
SELECT '07_dim_product',      COUNT(*) FROM read_parquet('data/processed/07_dim_product.parquet') UNION ALL
SELECT '07_dim_geo_zip',      COUNT(*) FROM read_parquet('data/processed/07_dim_geo_zip.parquet') UNION ALL
SELECT '07_dim_date',         COUNT(*) FROM read_parquet('data/processed/07_dim_date.parquet') UNION ALL
SELECT '07_fact_order_items', COUNT(*) FROM read_parquet('data/processed/07_fact_order_items.parquet') UNION ALL
SELECT '07_fact_orders',      COUNT(*) FROM read_parquet('data/processed/07_fact_orders.parquet') UNION ALL
SELECT '07_fact_payments',    COUNT(*) FROM read_parquet('data/processed/07_fact_payments.parquet') UNION ALL
SELECT '07_fact_reviews',     COUNT(*) FROM read_parquet('data/processed/07_fact_reviews.parquet');
