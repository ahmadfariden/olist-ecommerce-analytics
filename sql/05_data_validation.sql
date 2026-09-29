-- ============================================================
-- Tahap 6 — Data Validation & KPI Lock
-- File: sql/05_data_validation.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/05_data_validation.sql
-- Prasyarat: sql/04_data_cleaning.sql sudah dijalankan (stg_*, *_clean, dim_* ada).
-- ============================================================
-- GRAIN:       beda per rule (lihat kolom rule); KPI dihitung pada grain order / item / orang
-- POPULATION:  dinyatakan per KPI di tabel kpi_lock (Order, Revenue, Delivered, Review,
--              Payment, Reconcilable n = 98.665, Single-Seller n = 96.922, Customer)
-- DENOMINATOR: dinyatakan per KPI di tabel kpi_lock (kolom denominator)
-- ============================================================
-- Kolom severity:
--   HARD = gate tahap ini (row count, grain, referensial, fan-out, konsistensi flag,
--          toleransi rekonsiliasi). Semua HARD harus PASS; kalau ada FAIL,
--          treatment Tahap 5 dianggap gagal dan harus direvisi.
--   KPI  = nilai KPI yang dikunci; dibandingkan dengan angka roadmap (PASS / CHECK).
--   INFO = informasi / coverage, tanpa PASS/FAIL.
-- op: '=' (aktual harus sama dengan ekspektasi dalam toleransi) atau '>=' (batas minimum).
-- Output: data/processed/05_validation_summary.parquet
-- ============================================================

CREATE OR REPLACE TEMP TABLE v_raw (
    category VARCHAR, rule VARCHAR, op VARCHAR,
    n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE, severity VARCHAR
);

-- Rekonsiliasi order-level (Reconcilable Population), DECIMAL eksak, pre-aggregate ke grain order_id
CREATE OR REPLACE TEMP TABLE v_recon AS
SELECT i.order_id, i.t_item, p.t_pay, ABS(i.t_item - p.t_pay) AS diff
FROM (SELECT order_id, SUM(price + freight_value) AS t_item FROM order_items_clean    GROUP BY order_id) i
JOIN (SELECT order_id, SUM(payment_value)          AS t_pay  FROM order_payments_clean GROUP BY order_id) p USING (order_id);

-- ------------------------------------------------------------
-- 1. Structural Validation
-- ------------------------------------------------------------
INSERT INTO v_raw VALUES
 ('structural','row count stg_orders = raw',              '=', (SELECT COUNT(*) FROM stg_orders),               (SELECT COUNT(*) FROM raw_orders), 0, 'HARD'),
 ('structural','row count stg_customers = raw',           '=', (SELECT COUNT(*) FROM stg_customers),            (SELECT COUNT(*) FROM raw_customers), 0, 'HARD'),
 ('structural','row count stg_order_items = raw',         '=', (SELECT COUNT(*) FROM stg_order_items),          (SELECT COUNT(*) FROM raw_order_items), 0, 'HARD'),
 ('structural','row count stg_order_payments = raw',      '=', (SELECT COUNT(*) FROM stg_order_payments),       (SELECT COUNT(*) FROM raw_order_payments), 0, 'HARD'),
 ('structural','row count stg_order_reviews = raw',       '=', (SELECT COUNT(*) FROM stg_order_reviews),        (SELECT COUNT(*) FROM raw_order_reviews), 0, 'HARD'),
 ('structural','row count stg_products = raw',            '=', (SELECT COUNT(*) FROM stg_products),             (SELECT COUNT(*) FROM raw_products), 0, 'HARD'),
 ('structural','row count stg_sellers = raw',             '=', (SELECT COUNT(*) FROM stg_sellers),              (SELECT COUNT(*) FROM raw_sellers), 0, 'HARD'),
 ('structural','row count stg_category_translation = raw','=', (SELECT COUNT(*) FROM stg_category_translation), (SELECT COUNT(*) FROM raw_category_translation), 0, 'HARD'),
 ('structural','row count stg_geolocation = raw',         '=', (SELECT COUNT(*) FROM stg_geolocation),          (SELECT COUNT(*) FROM raw_geolocation), 0, 'HARD'),
 ('structural','row count geo_dedup (1.000.163 - 261.831)','=',(SELECT COUNT(*) FROM geo_dedup),                738332, 0, 'HARD'),
 ('structural','row count order_reviews_clean = order ber-review', '=', (SELECT COUNT(*) FROM order_reviews_clean), (SELECT COUNT(DISTINCT order_id) FROM raw_order_reviews), 0, 'HARD'),
 ('structural','grain raw_orders.order_id unik (dup)',    '=', (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM raw_orders), 0, 0, 'HARD'),
 ('structural','grain order_items (order_id, order_item_id) unik (dup)', '=', (SELECT COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)) FROM order_items_clean), 0, 0, 'HARD'),
 ('structural','grain order_payments (order_id, payment_sequential) unik (dup)', '=', (SELECT COUNT(*) - COUNT(DISTINCT (order_id, payment_sequential)) FROM order_payments_clean), 0, 0, 'HARD'),
 ('structural','grain orders_clean.order_id unik (dup)',  '=', (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM orders_clean), 0, 0, 'HARD'),
 ('structural','grain order_reviews_clean.order_id unik (dup)', '=', (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM order_reviews_clean), 0, 0, 'HARD'),
 ('structural','grain dim_customer.customer_unique_id unik (dup)', '=', (SELECT COUNT(*) - COUNT(DISTINCT customer_unique_id) FROM dim_customer), 0, 0, 'HARD'),
 ('structural','grain products_clean.product_id unik (dup)', '=', (SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM products_clean), 0, 0, 'HARD'),
 ('structural','grain dim_geo_zip.zip unik (dup)',        '=', (SELECT COUNT(*) - COUNT(DISTINCT zip) FROM dim_geo_zip), 0, 0, 'HARD'),
 ('structural','tipe: null orders setelah cast = null raw', '=',
        (SELECT COUNT(*) FILTER (WHERE ts_purchase IS NULL) + COUNT(*) FILTER (WHERE ts_approved IS NULL) + COUNT(*) FILTER (WHERE ts_carrier IS NULL)
              + COUNT(*) FILTER (WHERE ts_customer IS NULL) + COUNT(*) FILTER (WHERE ts_estimated IS NULL) FROM stg_orders),
        (SELECT COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL) + COUNT(*) FILTER (WHERE order_approved_at IS NULL) + COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL)
              + COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) + COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL) FROM raw_orders), 0, 'HARD'),
 ('structural','tipe: null order_items setelah cast = null raw', '=',
        (SELECT COUNT(*) FILTER (WHERE price IS NULL) + COUNT(*) FILTER (WHERE freight_value IS NULL) + COUNT(*) FILTER (WHERE ts_shipping_limit IS NULL) FROM stg_order_items),
        (SELECT COUNT(*) FILTER (WHERE price IS NULL) + COUNT(*) FILTER (WHERE freight_value IS NULL) + COUNT(*) FILTER (WHERE shipping_limit_date IS NULL) FROM raw_order_items), 0, 'HARD'),
 ('structural','tipe: null order_payments setelah cast = null raw', '=',
        (SELECT COUNT(*) FILTER (WHERE payment_sequential IS NULL) + COUNT(*) FILTER (WHERE payment_installments IS NULL) + COUNT(*) FILTER (WHERE payment_value IS NULL) FROM stg_order_payments),
        (SELECT COUNT(*) FILTER (WHERE payment_sequential IS NULL) + COUNT(*) FILTER (WHERE payment_installments IS NULL) + COUNT(*) FILTER (WHERE payment_value IS NULL) FROM raw_order_payments), 0, 'HARD'),
 ('structural','tipe: null reviews setelah cast = null raw', '=',
        (SELECT COUNT(*) FILTER (WHERE review_score IS NULL) + COUNT(*) FILTER (WHERE review_creation_ts IS NULL) + COUNT(*) FILTER (WHERE review_answer_ts IS NULL) FROM stg_order_reviews),
        (SELECT COUNT(*) FILTER (WHERE review_score IS NULL) + COUNT(*) FILTER (WHERE review_creation_date IS NULL) + COUNT(*) FILTER (WHERE review_answer_timestamp IS NULL) FROM raw_order_reviews), 0, 'HARD'),
 ('structural','tipe: null products setelah cast = null raw', '=',
        (SELECT COUNT(*) FILTER (WHERE name_length IS NULL) + COUNT(*) FILTER (WHERE description_length IS NULL) + COUNT(*) FILTER (WHERE photos_qty IS NULL)
              + COUNT(*) FILTER (WHERE weight_g IS NULL) + COUNT(*) FILTER (WHERE length_cm IS NULL) + COUNT(*) FILTER (WHERE height_cm IS NULL) + COUNT(*) FILTER (WHERE width_cm IS NULL) FROM stg_products),
        (SELECT COUNT(*) FILTER (WHERE product_name_lenght IS NULL) + COUNT(*) FILTER (WHERE product_description_lenght IS NULL) + COUNT(*) FILTER (WHERE product_photos_qty IS NULL)
              + COUNT(*) FILTER (WHERE product_weight_g IS NULL) + COUNT(*) FILTER (WHERE product_length_cm IS NULL) + COUNT(*) FILTER (WHERE product_height_cm IS NULL) + COUNT(*) FILTER (WHERE product_width_cm IS NULL) FROM raw_products), 0, 'HARD');

-- ------------------------------------------------------------
-- 2. Referential Validation
-- ------------------------------------------------------------
INSERT INTO v_raw VALUES
 ('referential','orders tanpa customer',                  '=', (SELECT COUNT(*) FROM stg_orders o LEFT JOIN stg_customers c USING (customer_id) WHERE c.customer_id IS NULL), 0, 0, 'HARD'),
 ('referential','customer_id unik (1:1 dengan order) (dup)', '=', (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM stg_customers), 0, 0, 'HARD'),
 ('referential','customer tanpa order',                   '=', (SELECT COUNT(*) FROM stg_customers c LEFT JOIN stg_orders o USING (customer_id) WHERE o.order_id IS NULL), 0, 0, 'HARD'),
 ('referential','order_items -> orders (orphan)',         '=', (SELECT COUNT(*) FROM stg_order_items i LEFT JOIN stg_orders o USING (order_id) WHERE o.order_id IS NULL), 0, 0, 'HARD'),
 ('referential','order_items -> products (orphan)',       '=', (SELECT COUNT(*) FROM stg_order_items i LEFT JOIN stg_products p USING (product_id) WHERE p.product_id IS NULL), 0, 0, 'HARD'),
 ('referential','order_items -> sellers (orphan)',        '=', (SELECT COUNT(*) FROM stg_order_items i LEFT JOIN stg_sellers s USING (seller_id) WHERE s.seller_id IS NULL), 0, 0, 'HARD'),
 ('referential','order_payments -> orders (orphan)',      '=', (SELECT COUNT(*) FROM stg_order_payments p LEFT JOIN stg_orders o USING (order_id) WHERE o.order_id IS NULL), 0, 0, 'HARD'),
 ('referential','order_reviews -> orders (orphan)',       '=', (SELECT COUNT(*) FROM stg_order_reviews r LEFT JOIN stg_orders o USING (order_id) WHERE o.order_id IS NULL), 0, 0, 'HARD'),
 ('referential','produk tanpa terjemahan setelah mapping manual', '=', (SELECT COUNT(*) FROM products_clean WHERE category_en IS NULL), 0, 0, 'HARD'),
 ('referential','order tanpa item terkonfirmasi',         '=', (SELECT COUNT(*) FROM orders_clean WHERE NOT has_items), 775, 0, 'HARD'),
 ('referential','order tanpa item yang masuk Revenue Population', '=', (SELECT COUNT(*) FROM orders_clean WHERE NOT has_items AND is_revenue_order), 0, 0, 'HARD'),
 ('referential','coverage: baris customer tanpa koordinat', '=',
        (SELECT COUNT(*) FROM stg_customers c LEFT JOIN dim_geo_zip z ON z.zip = c.zip_prefix WHERE z.lat IS NULL), 279, 0, 'INFO'),
 ('referential','coverage: baris seller tanpa koordinat', '=',
        (SELECT COUNT(*) FROM stg_sellers s LEFT JOIN dim_geo_zip z ON z.zip = s.zip_prefix WHERE z.lat IS NULL), 7, 0, 'INFO');

-- ------------------------------------------------------------
-- 3. Fan-out Validation (tabel anak di-pre-aggregate ke grain order_id dulu)
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE v_join AS
SELECT o.order_id, o.is_revenue_order, p.pay_value, r.review_score
FROM orders_clean o
LEFT JOIN (SELECT order_id, SUM(payment_value) AS pay_value FROM order_payments_clean GROUP BY order_id) p USING (order_id)
LEFT JOIN order_reviews_clean r USING (order_id);

INSERT INTO v_raw VALUES
 ('fanout','SUM(price) join items->orders_clean - SUM(price) items', '=',
        (SELECT CAST(ABS((SELECT SUM(i.price) FROM order_items_clean i JOIN orders_clean o USING (order_id)) - (SELECT SUM(price) FROM stg_order_items)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','SUM(freight_value) join items->orders_clean - SUM(freight) items', '=',
        (SELECT CAST(ABS((SELECT SUM(i.freight_value) FROM order_items_clean i JOIN orders_clean o USING (order_id)) - (SELECT SUM(freight_value) FROM stg_order_items)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','jumlah baris orders_clean setelah join payments+reviews (pre-agg)', '=', (SELECT COUNT(*) FROM v_join), 99441, 0, 'HARD'),
 ('fanout','COUNT(DISTINCT order_id) setelah join payments+reviews', '=', (SELECT COUNT(DISTINCT order_id) FROM v_join), 99441, 0, 'HARD'),
 ('fanout','SUM(payment_value) setelah join - SUM(payment_value) payments', '=',
        (SELECT CAST(ABS((SELECT SUM(pay_value) FROM v_join) - (SELECT SUM(payment_value) FROM stg_order_payments)) AS DOUBLE)), 0, 0.001, 'HARD'),
 ('fanout','order dengan >1 baris review di order_reviews_clean', '=', (SELECT COUNT(*) FROM (SELECT order_id FROM order_reviews_clean GROUP BY 1 HAVING COUNT(*) > 1)), 0, 0, 'HARD'),
 ('fanout','join customers -> dim_geo_zip tidak menambah baris', '=',
        (SELECT COUNT(*) FROM stg_customers c LEFT JOIN dim_geo_zip z ON z.zip = c.zip_prefix), 99441, 0, 'HARD');

-- ------------------------------------------------------------
-- 4. Business Validation (konsistensi status vs null, flag vs sumber)
-- ------------------------------------------------------------
INSERT INTO v_raw VALUES
 ('business','shipped dengan tanggal terima (harus 0)',   '=', (SELECT COUNT(*) FROM orders_clean WHERE order_status = 'shipped' AND ts_customer IS NOT NULL), 0, 0, 'HARD'),
 ('business','delivered tanpa tanggal terima (terdokumentasi)', '=', (SELECT COUNT(*) FROM orders_clean WHERE order_status = 'delivered' AND ts_customer IS NULL), 8, 0, 'HARD'),
 ('business','flag_carrier_before_purchase',              '=', (SELECT COUNT(*) FROM orders_clean WHERE flag_carrier_before_purchase), 166, 0, 'HARD'),
 ('business','flag_carrier_before_approved',              '=', (SELECT COUNT(*) FROM orders_clean WHERE flag_carrier_before_approved), 1359, 0, 'HARD'),
 ('business','flag_customer_before_carrier',              '=', (SELECT COUNT(*) FROM orders_clean WHERE flag_customer_before_carrier), 23, 0, 'HARD'),
 ('business','SUM(is_canceled) = COUNT(status canceled) - selisih', '=',
        (SELECT ABS((SELECT COUNT(*) FROM orders_clean WHERE is_canceled) - (SELECT COUNT(*) FROM raw_orders WHERE order_status = 'canceled'))), 0, 0, 'HARD'),
 ('business','SUM(is_canceled)',                          '=', (SELECT COUNT(*) FROM orders_clean WHERE is_canceled), 625, 0, 'HARD'),
 ('business','SUM(is_unavailable) = COUNT(status unavailable) - selisih', '=',
        (SELECT ABS((SELECT COUNT(*) FROM orders_clean WHERE is_unavailable) - (SELECT COUNT(*) FROM raw_orders WHERE order_status = 'unavailable'))), 0, 0, 'HARD'),
 ('business','SUM(is_unavailable)',                       '=', (SELECT COUNT(*) FROM orders_clean WHERE is_unavailable), 609, 0, 'HARD'),
 ('business','is_revenue_order konsisten dengan status & item (baris beda)', '=',
        (SELECT COUNT(*) FROM orders_clean o
         WHERE o.is_revenue_order <> (EXISTS (SELECT 1 FROM stg_order_items i WHERE i.order_id = o.order_id)
                                      AND o.order_status NOT IN ('canceled', 'unavailable'))), 0, 0, 'HARD'),
 ('business','Revenue Population berstatus canceled/unavailable', '=', (SELECT COUNT(*) FROM orders_clean WHERE is_revenue_order AND order_status IN ('canceled','unavailable')), 0, 0, 'HARD'),
 ('business','order dengan status di luar 8 nilai yang dikenal', '=',
        (SELECT COUNT(*) FROM orders_clean WHERE order_status NOT IN ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved')), 0, 0, 'HARD'),
 ('business','SUM(order per status) = Order Population',   '=', (SELECT COUNT(*) FROM orders_clean), 99441, 0, 'HARD'),
 ('business','dedup review: COUNT(*) review clean = order ber-review', '=', (SELECT COUNT(*) FROM order_reviews_clean), 98673, 0, 'HARD');

-- ------------------------------------------------------------
-- 5. Revenue Validation & Rekonsiliasi (Reconcilable Population)
--    Toleransi: >= 99,6% order selisih <= 0,01; selisih > 1 dilaporkan sebagai limitation (D9).
-- ------------------------------------------------------------
INSERT INTO v_raw VALUES
 ('revenue','Reconcilable Population (n)',                '=', (SELECT COUNT(*) FROM v_recon), 98665, 0, 'HARD'),
 ('revenue','recon: order selisih <= 0,01',               '=', (SELECT COUNT(*) FROM v_recon WHERE diff <= 0.01), 98362, 0, 'HARD'),
 ('revenue','recon: order selisih 0,01 - 1',              '=', (SELECT COUNT(*) FROM v_recon WHERE diff > 0.01 AND diff <= 1), 54, 0, 'HARD'),
 ('revenue','recon: order selisih > 1 (limitation, D9)',  '=', (SELECT COUNT(*) FROM v_recon WHERE diff > 1), 249, 0, 'HARD'),
 ('revenue','recon: % order selisih <= 0,01 (target >= 99,6)', '>=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE diff <= 0.01) / COUNT(*), 3) FROM v_recon), 99.6, 0, 'HARD'),
 ('revenue','recon: selisih maksimum (R$)',               '=', (SELECT CAST(MAX(diff) AS DOUBLE) FROM v_recon), 182.81, 0.011, 'KPI'),
 ('revenue','recon selisih > 1: payment > item+freight (order)', '=', (SELECT COUNT(*) FROM v_recon WHERE diff > 1 AND t_pay > t_item), 232, 0, 'KPI'),
 ('revenue','recon selisih > 1: payment < item+freight (order)', '=', (SELECT COUNT(*) FROM v_recon WHERE diff > 1 AND t_pay < t_item), 17, 0, 'KPI'),
 ('revenue','recon selisih > 1: total excess payment > item (R$)', '=',
        (SELECT CAST(SUM(t_pay - t_item) AS DOUBLE) FROM v_recon WHERE diff > 1 AND t_pay > t_item), 3064.76, 0.011, 'KPI'),
 ('revenue','recon selisih > 1: total shortfall payment < item (R$)', '=',
        (SELECT CAST(SUM(t_item - t_pay) AS DOUBLE) FROM v_recon WHERE diff > 1 AND t_pay < t_item), 197.57, 0.011, 'KPI'),
 ('revenue','recon: 232 order payment > item melibatkan credit_card', '=',
        (SELECT COUNT(*) FROM v_recon v WHERE v.diff > 1 AND v.t_pay > v.t_item
           AND EXISTS (SELECT 1 FROM order_payments_clean p WHERE p.order_id = v.order_id AND p.payment_type = 'credit_card')), 232, 0, 'KPI'),
 ('revenue','Item Revenue - Revenue Population (R$)',     '=',
        (SELECT CAST(SUM(i.price) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 13494400.74, 0.011, 'KPI'),
 ('revenue','D2: Item Revenue order in-flight (status <> delivered) (R$)', '=',
        (SELECT CAST(SUM(i.price) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order AND o.order_status <> 'delivered'), 272902.63, 0.011, 'KPI'),
 ('revenue','D2: % in-flight dari Item Revenue',          '=',
        (SELECT ROUND(100.0 * SUM(i.price) FILTER (WHERE o.order_status <> 'delivered') / SUM(i.price), 2)
         FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 2.02, 0.011, 'KPI'),
 ('revenue','D2: sensitivity delivered-only % dari Item Revenue', '=',
        (SELECT ROUND(100.0 * SUM(i.price) FILTER (WHERE o.order_status = 'delivered') / SUM(i.price), 2)
         FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 97.98, 0.011, 'KPI'),
 ('revenue','Freight Revenue - Revenue Population (R$)',  '=',
        (SELECT CAST(SUM(i.freight_value) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), NULL, 0, 'INFO'),
 ('revenue','Payment Total - seluruh payment (R$, hanya rekonsiliasi)', '=',
        (SELECT CAST(SUM(payment_value) AS DOUBLE) FROM order_payments_clean), NULL, 0, 'INFO');

-- ------------------------------------------------------------
-- 6. Order, AOV, Delivery, Review, Customer metric validation
-- ------------------------------------------------------------
INSERT INTO v_raw VALUES
 ('order','Total Orders (Order Population)',              '=', (SELECT COUNT(*) FROM orders_clean), 99441, 0, 'KPI'),
 ('order','Revenue Orders (is_revenue_order)',            '=', (SELECT COUNT(*) FROM orders_clean WHERE is_revenue_order), 98199, 0, 'KPI'),
 ('order','Single-Seller Population (D10)',               '=', (SELECT COUNT(*) FROM orders_clean WHERE is_revenue_order AND NOT is_multi_seller), 96922, 0, 'KPI'),
 ('order','Analysis Window Population',                   '=', (SELECT COUNT(*) FROM orders_clean WHERE in_analysis_window), 99092, 0, 'KPI'),
 ('aov','AOV = Item Revenue / Revenue Orders (R$)',       '=',
        (SELECT ROUND(CAST(SUM(i.price) AS DOUBLE) / COUNT(DISTINCT o.order_id), 2)
         FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), NULL, 0, 'INFO'),
 ('aov','AOV incl. freight (R$, varian berlabel)',        '=',
        (SELECT ROUND(CAST(SUM(i.price + i.freight_value) AS DOUBLE) / COUNT(DISTINCT o.order_id), 2)
         FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), NULL, 0, 'INFO'),
 ('order','Cancellation Rate % (is_canceled / Total Orders)', '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM orders_clean), NULL, 0, 'INFO'),
 ('order','Unavailable Rate % (is_unavailable / Total Orders)', '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_unavailable) / COUNT(*), 3) FROM orders_clean), NULL, 0, 'INFO'),
 ('delivery','Delivered Orders (is_delivered_complete)',  '=', (SELECT COUNT(*) FROM orders_clean WHERE is_delivered_complete), 96470, 0, 'KPI'),
 ('delivery','Late orders (tanggal, D1)',                 '=', (SELECT COUNT(*) FROM orders_clean WHERE is_late), 6534, 0, 'KPI'),
 ('delivery','Late Rate % (tanggal, D1)',                 '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM orders_clean WHERE is_delivered_complete), 6.773, 0.0011, 'KPI'),
 ('delivery','On-Time Rate % (1 - Late Rate)',            '=',
        (SELECT ROUND(100.0 - 100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM orders_clean WHERE is_delivered_complete), 93.227, 0.0011, 'KPI'),
 ('delivery','Late Rate % versi timestamp (sensitivity)', '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late_ts_sensitivity) / COUNT(*), 3) FROM orders_clean WHERE is_delivered_complete), 8.112, 0.0011, 'KPI'),
 ('delivery','order tiba di hari estimasi tapi telat versi timestamp', '=',
        (SELECT COUNT(*) FROM orders_clean WHERE is_late_ts_sensitivity AND NOT is_late), 1292, 0, 'KPI'),
 ('review','Avg Review Score (Review Population, dedup)', '=', (SELECT ROUND(AVG(review_score), 4) FROM order_reviews_clean), 4.0864, 0.00011, 'KPI'),
 ('customer','Customer Population (customer_unique_id)',  '=', (SELECT COUNT(*) FROM dim_customer), 96096, 0, 'KPI'),
 ('customer','Repeat Rate % (>= 24 jam, D5)',             '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) FROM dim_customer), 2.208, 0.0011, 'KPI'),
 ('customer','Repeat mentah % (>= 2 order, hanya Data Quality)', '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw) / COUNT(*), 3) FROM dim_customer), 3.119, 0.0011, 'KPI');

-- 90-day Repeat Rate: cohort = first order 2017-01 s.d. 2018-05 (semua punya >= 90 hari observasi);
-- repeat = ada order >= 24 jam dan <= 90 hari setelah order pertama.
CREATE OR REPLACE TEMP TABLE v_repeat90 AS
WITH cohort AS (
    SELECT customer_unique_id, first_order_ts FROM dim_customer
    WHERE first_order_ts >= TIMESTAMP '2017-01-01' AND first_order_ts < TIMESTAMP '2018-06-01'
)
SELECT c.customer_unique_id,
       COALESCE(BOOL_OR(o.ts_purchase >= c.first_order_ts + INTERVAL 24 HOUR
                    AND o.ts_purchase <= c.first_order_ts + INTERVAL 90 DAY), FALSE) AS rep90
FROM cohort c
JOIN orders_clean o ON o.customer_unique_id = c.customer_unique_id
GROUP BY c.customer_unique_id;

INSERT INTO v_raw VALUES
 ('customer','90-day Repeat Rate % (cohort 2017-01..2018-05)', '=',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE rep90) / COUNT(*), 3) FROM v_repeat90), 1.302, 0.0011, 'KPI'),
 ('customer','cohort 90-day: jumlah pelanggan',           '=', (SELECT COUNT(*) FROM v_repeat90), NULL, 0, 'INFO'),
 ('customer','cohort 90-day: pelanggan repeat',           '=', (SELECT COUNT(*) FILTER (WHERE rep90) FROM v_repeat90), NULL, 0, 'INFO');

-- ------------------------------------------------------------
-- 7. Tabel hasil + gate
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE validation_results AS
SELECT category, rule, op, n_actual, n_expected, tol, severity,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NULL    THEN CASE WHEN severity = 'HARD' THEN 'FAIL' ELSE 'CHECK' END
            WHEN op = '>=' AND n_actual >= n_expected THEN 'PASS'
            WHEN op = '='  AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE CASE WHEN severity = 'HARD' THEN 'FAIL' ELSE 'CHECK' END END AS status
FROM v_raw;

-- Ringkasan
SELECT severity, status, COUNT(*) AS n_rule FROM validation_results GROUP BY severity, status ORDER BY severity, status;

-- GATE: semua rule HARD harus PASS
SELECT CASE WHEN COUNT(*) FILTER (WHERE severity = 'HARD' AND status <> 'PASS') = 0
            THEN 'GATE PASS: semua rule HARD lolos' ELSE 'GATE FAIL: revisi treatment Tahap 5' END AS gate,
       COUNT(*) FILTER (WHERE severity = 'HARD')                        AS n_hard,
       COUNT(*) FILTER (WHERE severity = 'HARD' AND status = 'PASS')    AS n_hard_pass,
       COUNT(*) FILTER (WHERE severity = 'KPI')                         AS n_kpi,
       COUNT(*) FILTER (WHERE severity = 'KPI' AND status = 'PASS')     AS n_kpi_pass
FROM validation_results;

-- Rule yang BUKAN PASS (FAIL/CHECK harus dijelaskan; INFO = tanpa ekspektasi)
SELECT category, rule, n_actual, n_expected, severity, status
FROM validation_results WHERE status <> 'PASS' ORDER BY status, category, rule;

-- Semua rule (untuk ditempel ke docs/methodology.md)
SELECT category, rule, n_actual, n_expected, severity, status FROM validation_results ORDER BY category, rule;

-- ------------------------------------------------------------
-- 8. KPI Definition Lock — tabel definisi resmi (nilai dihitung dari data)
--    Setelah tahap ini definisi TERKUNCI; perubahan hanya lewat Revision Log.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE kpi_lock AS
SELECT * FROM (VALUES
 ('Item Revenue',        'SUM(price) dari order_items_clean',                          'Revenue Population (is_revenue_order)', 'n/a',            (SELECT CAST(SUM(i.price) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 'R$'),
 ('Freight Revenue',     'SUM(freight_value); dipisah dari Item Revenue',              'Revenue Population',                    'n/a',            (SELECT CAST(SUM(i.freight_value) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 'R$'),
 ('GMV incl. Freight',   'Item Revenue + Freight Revenue',                             'Revenue Population',                    'n/a',            (SELECT CAST(SUM(i.price + i.freight_value) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 'R$'),
 ('Payment Total',       'SUM(payment_value); HANYA untuk rekonsiliasi',               'Payment Population',                    'n/a',            (SELECT CAST(SUM(payment_value) AS DOUBLE) FROM order_payments_clean), 'R$'),
 ('Total Orders',        'COUNT(order_id)',                                            'Order Population',                      'n/a',            (SELECT CAST(COUNT(*) AS DOUBLE) FROM orders_clean), 'order'),
 ('Revenue Orders',      'COUNT(order_id) WHERE is_revenue_order',                     'Revenue Population',                    'n/a',            (SELECT CAST(COUNT(*) AS DOUBLE) FROM orders_clean WHERE is_revenue_order), 'order'),
 ('AOV',                 'Item Revenue / Revenue Orders (tanpa ongkir)',               'Revenue Population',                    'Revenue Orders', (SELECT CAST(SUM(i.price) AS DOUBLE) / COUNT(DISTINCT o.order_id) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 'R$'),
 ('AOV incl. Freight',   '(Item + Freight Revenue) / Revenue Orders; wajib berlabel',  'Revenue Population',                    'Revenue Orders', (SELECT CAST(SUM(i.price + i.freight_value) AS DOUBLE) / COUNT(DISTINCT o.order_id) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 'R$'),
 ('Cancellation Rate',   'is_canceled / Total Orders',                                 'Order Population',                      'Total Orders',   (SELECT 100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*) FROM orders_clean), '%'),
 ('Unavailable Rate',    'is_unavailable / Total Orders (dilaporkan terpisah)',        'Order Population',                      'Total Orders',   (SELECT 100.0 * COUNT(*) FILTER (WHERE is_unavailable) / COUNT(*) FROM orders_clean), '%'),
 ('Late Rate',           'is_late (perbandingan TANGGAL, D1) / Delivered Orders',      'Delivered Population',                  'Delivered Orders', (SELECT 100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*) FROM orders_clean WHERE is_delivered_complete), '%'),
 ('On-Time Rate',        '1 - Late Rate',                                              'Delivered Population',                  'Delivered Orders', (SELECT 100.0 - 100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*) FROM orders_clean WHERE is_delivered_complete), '%'),
 ('Avg Review Score',    'AVG(review_score), dedup 1 review/order (D3)',               'Review Population',                     'Review Population', (SELECT AVG(review_score) FROM order_reviews_clean), 'skor 1-5'),
 ('Repeat Rate',         'pelanggan dgn order >= 24 jam setelah order pertama (D5) / Customer Population', 'Customer Population', 'Customer Population', (SELECT 100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*) FROM dim_customer), '%'),
 ('90-day Repeat Rate',  'repeat dalam 24 jam..90 hari; cohort order pertama 2017-01..2018-05 (D5)', 'Cohort 2017-01..2018-05',  'Cohort',         (SELECT 100.0 * COUNT(*) FILTER (WHERE rep90) / COUNT(*) FROM v_repeat90), '%'),
 ('Single-Seller Population', 'Revenue Population AND NOT is_multi_seller (D10)',      'Revenue Population',                    'n/a',            (SELECT CAST(COUNT(*) AS DOUBLE) FROM orders_clean WHERE is_revenue_order AND NOT is_multi_seller), 'order')
) AS t(kpi, definition, population, denominator, value, unit);

SELECT kpi, definition, population, denominator, ROUND(value, 4) AS value, unit FROM kpi_lock;

-- ------------------------------------------------------------
-- 9. Output: data/processed/05_validation_summary.parquet (pass/fail tiap rule)
-- ------------------------------------------------------------
COPY validation_results TO 'data/processed/05_validation_summary.parquet' (FORMAT PARQUET);
SELECT COUNT(*) AS n_baris_parquet FROM read_parquet('data/processed/05_validation_summary.parquet');
