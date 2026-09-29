-- ============================================================
-- Tahap 5 — Data Cleaning & Data Treatment
-- File: sql/04_data_cleaning.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/04_data_cleaning.sql
-- Prasyarat: sql/02_data_collection.sql sudah dijalankan (raw_* ada).
-- ============================================================
-- GRAIN:       beda per tabel (dinyatakan di tiap blok CREATE TABLE di bawah)
-- POPULATION:  seluruh baris raw_* (cleaning tidak membuang baris, kecuali
--              dedup review -> 1 review/order dan dedup geolocation -> 1 baris/zip)
-- DENOMINATOR: n/a (tahap ini membangun flag; metrik rate dihitung di Tahap 9+)
-- ============================================================
-- Layering:  raw_* (tidak diubah)  ->  stg_* (cast + standardisasi, 1 baris per baris raw)
--            ->  *_clean / dim_* (flag + aturan dedup)
-- Prinsip:   FLAG, JANGAN HAPUS. Nilai uang di-cast ke DECIMAL(12,2) supaya
--            rekonsiliasi eksak (tanpa artefak floating point).
-- Output:    data/processed/04_*.parquet (9 file, ter-ignore git)
-- ============================================================

-- ------------------------------------------------------------
-- 1. STAGING — cast tipe + standardisasi (row count harus = raw)
--    TRY_CAST: baris invalid jadi NULL, query tidak gagal.
--    Zip prefix tetap VARCHAR (24% diawali 0).
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE stg_orders AS
SELECT order_id,
       customer_id,
       order_status,
       TRY_CAST(order_purchase_timestamp      AS TIMESTAMP) AS ts_purchase,
       TRY_CAST(order_approved_at             AS TIMESTAMP) AS ts_approved,
       TRY_CAST(order_delivered_carrier_date  AS TIMESTAMP) AS ts_carrier,
       TRY_CAST(order_delivered_customer_date AS TIMESTAMP) AS ts_customer,
       TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) AS ts_estimated
FROM raw_orders;

CREATE OR REPLACE TABLE stg_customers AS
SELECT customer_id,
       customer_unique_id,
       customer_zip_code_prefix          AS zip_prefix,
       lower(trim(customer_city))        AS city,
       upper(trim(customer_state))       AS state
FROM raw_customers;

CREATE OR REPLACE TABLE stg_order_items AS
SELECT order_id,
       TRY_CAST(order_item_id AS INTEGER)       AS order_item_id,
       product_id,
       seller_id,
       TRY_CAST(shipping_limit_date AS TIMESTAMP) AS ts_shipping_limit,
       TRY_CAST(price         AS DECIMAL(12,2)) AS price,
       TRY_CAST(freight_value AS DECIMAL(12,2)) AS freight_value
FROM raw_order_items;

CREATE OR REPLACE TABLE stg_order_payments AS
SELECT order_id,
       TRY_CAST(payment_sequential   AS INTEGER)       AS payment_sequential,
       payment_type,
       TRY_CAST(payment_installments AS INTEGER)       AS payment_installments,
       TRY_CAST(payment_value        AS DECIMAL(12,2)) AS payment_value
FROM raw_order_payments;

-- Komentar: trim SEMUA whitespace (termasuk newline/tab) lalu string kosong -> NULL
-- (setara TRIM + regex ^\s*$ -> NULL). TRIM bawaan DuckDB hanya membuang spasi.
CREATE OR REPLACE TABLE stg_order_reviews AS
SELECT review_id,
       order_id,
       TRY_CAST(review_score AS INTEGER) AS review_score,
       NULLIF(regexp_replace(review_comment_title,   '^\s+|\s+$', '', 'g'), '') AS review_comment_title,
       NULLIF(regexp_replace(review_comment_message, '^\s+|\s+$', '', 'g'), '') AS review_comment_message,
       TRY_CAST(review_creation_date    AS TIMESTAMP) AS review_creation_ts,
       TRY_CAST(review_answer_timestamp AS TIMESTAMP) AS review_answer_ts
FROM raw_order_reviews;

-- Ejaan kolom bawaan (lenght) dirapikan di sini.
CREATE OR REPLACE TABLE stg_products AS
SELECT product_id,
       product_category_name                         AS category_pt,
       TRY_CAST(product_name_lenght        AS INTEGER) AS name_length,
       TRY_CAST(product_description_lenght AS INTEGER) AS description_length,
       TRY_CAST(product_photos_qty         AS INTEGER) AS photos_qty,
       TRY_CAST(product_weight_g           AS DOUBLE)  AS weight_g,
       TRY_CAST(product_length_cm          AS DOUBLE)  AS length_cm,
       TRY_CAST(product_height_cm          AS DOUBLE)  AS height_cm,
       TRY_CAST(product_width_cm           AS DOUBLE)  AS width_cm
FROM raw_products;

CREATE OR REPLACE TABLE stg_sellers AS
SELECT seller_id,
       seller_zip_code_prefix        AS zip_prefix,
       lower(trim(seller_city))      AS seller_city,
       upper(trim(seller_state))     AS seller_state
FROM raw_sellers;

CREATE OR REPLACE TABLE stg_category_translation AS
SELECT trim(product_category_name)         AS category_pt,
       trim(product_category_name_english) AS category_en
FROM raw_category_translation;

CREATE OR REPLACE TABLE stg_geolocation AS
SELECT geolocation_zip_code_prefix             AS zip,
       TRY_CAST(geolocation_lat AS DOUBLE)     AS lat,
       TRY_CAST(geolocation_lng AS DOUBLE)     AS lng,
       lower(trim(geolocation_city))           AS city,
       upper(trim(geolocation_state))          AS state
FROM raw_geolocation;

-- ------------------------------------------------------------
-- 2. GEOLOCATION -> dim_geo_zip
--    Aturan: (a) buang duplikat penuh (5 kolom raw identik);
--    (b) koordinat di luar kotak kasar Brasil dikeluarkan dari rata-rata
--        (lat -33.75..5.27, lng -73.99..-34.79);
--    (c) 1 baris per zip prefix: lat/lng = rata-rata titik valid;
--        kota = modus setelah buang aksen + lower + trim (tie-break alfabet).
--    Zip yang semua titiknya invalid tetap ada, lat/lng = NULL.
-- ------------------------------------------------------------
-- GRAIN: geo_dedup = 1 baris = 1 titik koordinat unik ; dim_geo_zip = 1 baris = 1 zip prefix
CREATE OR REPLACE TABLE geo_dedup AS
SELECT geolocation_zip_code_prefix                                  AS zip,
       TRY_CAST(geolocation_lat AS DOUBLE)                          AS lat,
       TRY_CAST(geolocation_lng AS DOUBLE)                          AS lng,
       strip_accents(lower(trim(geolocation_city)))                 AS city_norm,
       upper(trim(geolocation_state))                               AS state,
       COALESCE(TRY_CAST(geolocation_lat AS DOUBLE) BETWEEN -33.75 AND 5.27
            AND TRY_CAST(geolocation_lng AS DOUBLE) BETWEEN -73.99 AND -34.79, FALSE) AS valid_coord
FROM (SELECT DISTINCT * FROM raw_geolocation);

CREATE OR REPLACE TABLE dim_geo_zip AS
WITH coords AS (
    SELECT zip,
           AVG(lat) FILTER (WHERE valid_coord) AS lat,
           AVG(lng) FILTER (WHERE valid_coord) AS lng,
           COUNT(*)                            AS n_points_dedup,
           COUNT(*) FILTER (WHERE valid_coord) AS n_points_valid
    FROM geo_dedup GROUP BY zip
), city_rank AS (
    SELECT zip, city_norm, state,
           ROW_NUMBER() OVER (PARTITION BY zip ORDER BY COUNT(*) DESC, city_norm) AS rn
    FROM geo_dedup GROUP BY zip, city_norm, state
)
SELECT c.zip, c.lat, c.lng, r.city_norm AS city, r.state,
       c.n_points_dedup, c.n_points_valid
FROM coords c JOIN city_rank r ON r.zip = c.zip AND r.rn = 1;

-- ------------------------------------------------------------
-- 3. category_translation_clean & products_clean
--    Typo diperbaiki di category_en_clean (kolom asli category_en dipertahankan);
--    2 kategori tanpa terjemahan dimapping manual (is_manual_mapping = TRUE).
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 kategori PT (71 raw + 2 mapping manual = 73)
CREATE OR REPLACE TABLE category_translation_clean AS
SELECT category_pt,
       category_en,
       replace(replace(replace(category_en,
               'costruction_', 'construction_'),
               'fashio_',      'fashion_'),
               'home_confort', 'home_comfort') AS category_en_clean,
       FALSE AS is_manual_mapping
FROM stg_category_translation
UNION ALL
SELECT * FROM (VALUES
    ('pc_gamer',                                     CAST(NULL AS VARCHAR), 'pc_gamer',                       TRUE),
    ('portateis_cozinha_e_preparadores_de_alimentos', CAST(NULL AS VARCHAR), 'portable_kitchen_food_preparers', TRUE)
) AS m(category_pt, category_en, category_en_clean, is_manual_mapping);

-- GRAIN: 1 baris = 1 produk. 610 kategori NULL -> label 'unknown' (tidak dibuang).
-- Berat = 0 dan berat NULL -> weight_g NULL (nilai 0 bukan berat fisik valid).
CREATE OR REPLACE TABLE products_clean AS
SELECT p.product_id,
       COALESCE(p.category_pt, 'unknown') AS category_pt,
       CASE WHEN p.category_pt IS NULL THEN 'unknown' ELSE t.category_en_clean END AS category_en,
       p.name_length, p.description_length, p.photos_qty,
       NULLIF(p.weight_g, 0) AS weight_g,
       p.length_cm, p.height_cm, p.width_cm,
       (p.category_pt IS NULL)                       AS flag_category_unknown,
       COALESCE(p.weight_g, 0) = 0                   AS flag_weight_invalid
FROM stg_products p
LEFT JOIN category_translation_clean t ON t.category_pt = p.category_pt;

-- ------------------------------------------------------------
-- 4. sellers_clean
--    seller_city_clean: potong di '/', ',' atau ' - ' (ambil bagian kiri);
--    email / angka saja -> 'unknown'; 2 singkatan dimapping manual.
--    seller_state tetap sumber kebenaran lokasi (D8); kota bukan key analisis.
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 seller
CREATE OR REPLACE TABLE sellers_clean AS
WITH base AS (
    SELECT seller_id, zip_prefix, seller_city, seller_state,
           trim(regexp_replace(seller_city, '\s*(/|,| - ).*$', '')) AS city_cut
    FROM stg_sellers
), c AS (
    SELECT seller_id, zip_prefix, seller_city, seller_state,
           CASE WHEN seller_city LIKE '%@%' OR city_cut = '' OR regexp_matches(city_cut, '^[0-9]+$') THEN 'unknown'
                WHEN city_cut = 'sbc' THEN 'sao bernardo do campo'
                WHEN city_cut = 'sp'  THEN 'sao paulo'
                ELSE city_cut END AS seller_city_clean
    FROM base
)
SELECT seller_id,
       zip_prefix   AS seller_zip_prefix,
       seller_city  AS seller_city_raw,
       seller_city_clean,
       seller_state,
       (seller_city_clean <> seller_city) AS flag_city_cleaned
FROM c;

-- ------------------------------------------------------------
-- 5. order_items_clean
--    Retain semua baris. Flag: freight 0 (bisa promo free shipping),
--    shipping_limit_date tahun >= 2019 (order dibeli 2016-2018).
--    qty_units = jumlah baris item per (order_id, product_id). Nilainya berulang
--    di tiap baris pasangan itu: JANGAN di-SUM; unit = COUNT(*) baris item.
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 unit item dalam order (PK: order_id, order_item_id)
CREATE OR REPLACE TABLE order_items_clean AS
SELECT i.*,
       COALESCE(i.freight_value = 0, FALSE)                                     AS flag_zero_freight,
       COALESCE(i.ts_shipping_limit >= TIMESTAMP '2019-01-01', FALSE)           AS flag_shipping_limit_invalid,
       COUNT(*) OVER (PARTITION BY i.order_id, i.product_id)                    AS qty_units
FROM stg_order_items i;

-- ------------------------------------------------------------
-- 6. order_payments_clean
--    Retain semua baris; flag dilaporkan terpisah dan tidak mengubah nilai.
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 pembayaran (PK: order_id, payment_sequential)
CREATE OR REPLACE TABLE order_payments_clean AS
SELECT p.*,
       COALESCE(p.payment_value = 0, FALSE)                 AS flag_zero_payment,
       (p.payment_type = 'not_defined')                     AS flag_payment_not_defined,
       COALESCE(p.payment_installments = 0, FALSE)          AS flag_zero_installments,
       (COUNT(*) FILTER (WHERE p.payment_sequential = 1)
            OVER (PARTITION BY p.order_id) = 0)             AS flag_no_first_payment
FROM stg_order_payments p;

-- ------------------------------------------------------------
-- 7. order_reviews_clean — DEDUP ke 1 review per order (D3)
--    Aturan: ambil review_answer_ts terbaru; tie-break review_creation_ts terbaru,
--    lalu review_id terbesar (agar deterministik). n_reviews_raw menyimpan jumlah
--    review mentah per order. Skor tidak dibuang, hanya dipilih 1 per order.
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 order ber-review (Review Population)
CREATE OR REPLACE TABLE order_reviews_clean AS
WITH r AS (
    SELECT *,
           COUNT(*) OVER (PARTITION BY order_id) AS n_reviews_raw,
           ROW_NUMBER() OVER (
               PARTITION BY order_id
               ORDER BY review_answer_ts DESC NULLS LAST,
                        review_creation_ts DESC NULLS LAST,
                        review_id DESC) AS rn
    FROM stg_order_reviews
)
SELECT r.review_id, r.order_id, r.review_score,
       r.review_comment_title, r.review_comment_message,
       r.review_creation_ts, r.review_answer_ts,
       r.n_reviews_raw,
       (r.review_comment_message IS NOT NULL)                             AS has_comment,
       COALESCE(r.review_creation_ts < o.ts_purchase, FALSE)              AS flag_review_before_purchase
FROM r
LEFT JOIN stg_orders o ON o.order_id = r.order_id
WHERE r.rn = 1;

-- ------------------------------------------------------------
-- 8. dim_customer — kunci customer_unique_id (1 orang)
--    state/kota/zip first-order dan latest-order disimpan (aturan untuk 250/122/39
--    kasus lokasi ganda): analisis repeat pakai first order, profil pelanggan pakai latest.
--    Urutan first/latest: ts_purchase, tie-break order_id (292 pasangan order
--    di detik yang sama, jadi tie-break perlu).
--    is_repeat_customer (D5): ada order >= 24 jam setelah order pertama.
--    is_repeat_raw = >= 2 order (metrik Data Quality saja).
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 customer_unique_id (Customer Population)
CREATE OR REPLACE TABLE dim_customer AS
WITH o AS (
    SELECT c.customer_unique_id, o.order_id, o.ts_purchase,
           c.state, c.city, c.zip_prefix,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY o.ts_purchase ASC,  o.order_id ASC)  AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY o.ts_purchase DESC, o.order_id DESC) AS rn_latest
    FROM stg_orders o
    JOIN stg_customers c USING (customer_id)
)
SELECT customer_unique_id,
       COUNT(*)                                             AS n_orders_raw,
       MIN(ts_purchase)                                     AS first_order_ts,
       MAX(ts_purchase)                                     AS latest_order_ts,
       MAX(order_id) FILTER (WHERE rn_first  = 1)           AS first_order_id,
       MAX(state)    FILTER (WHERE rn_first  = 1)           AS state_first_order,
       MAX(state)    FILTER (WHERE rn_latest = 1)           AS state_latest_order,
       MAX(city)     FILTER (WHERE rn_first  = 1)           AS city_first_order,
       MAX(city)     FILTER (WHERE rn_latest = 1)           AS city_latest_order,
       MAX(zip_prefix) FILTER (WHERE rn_latest = 1)         AS zip_latest_order,
       (COUNT(DISTINCT state) > 1)                          AS flag_multi_state,
       (MAX(ts_purchase) >= MIN(ts_purchase) + INTERVAL 24 HOUR) AS is_repeat_customer,
       (COUNT(*) > 1)                                       AS is_repeat_raw
FROM o
GROUP BY customer_unique_id;

-- ------------------------------------------------------------
-- 9. orders_clean — materialisasi flag anomali + Analytical Flags
--    Tabel anak di-pre-aggregate ke grain order_id dulu (Fan-out Guard).
--    is_late = perbandingan TANGGAL (D1); is_late_ts_sensitivity = versi timestamp
--    (hanya sensitivity, jangan dipakai sebagai KPI).
--    Flag tidak boleh dipertukarkan: revenue -> is_revenue_order,
--    delivery -> is_delivered_complete, kepuasan -> has_review.
-- ------------------------------------------------------------
-- GRAIN: 1 baris = 1 order (Order Population, n = 99.441)
CREATE OR REPLACE TABLE orders_clean AS
WITH it AS (
    SELECT order_id, COUNT(*) AS n_items, COUNT(DISTINCT seller_id) AS n_sellers
    FROM stg_order_items GROUP BY order_id
), pay AS (
    SELECT order_id, COUNT(DISTINCT payment_type) AS n_payment_types
    FROM stg_order_payments GROUP BY order_id
), rev AS (
    SELECT order_id, COUNT(*) AS n_reviews_raw
    FROM stg_order_reviews GROUP BY order_id
), base AS (
    SELECT o.order_id, o.customer_id,
           c.customer_unique_id,
           c.zip_prefix AS customer_zip_prefix,
           c.city       AS customer_city,
           c.state      AS customer_state,
           o.order_status,
           o.ts_purchase, o.ts_approved, o.ts_carrier, o.ts_customer, o.ts_estimated,
           COALESCE(it.n_items, 0)          AS n_items,
           COALESCE(it.n_sellers, 0)        AS n_sellers,
           COALESCE(pay.n_payment_types, 0) AS n_payment_types,
           COALESCE(rev.n_reviews_raw, 0)   AS n_reviews_raw
    FROM stg_orders o
    LEFT JOIN stg_customers c ON c.customer_id = o.customer_id
    LEFT JOIN it  ON it.order_id  = o.order_id
    LEFT JOIN pay ON pay.order_id = o.order_id
    LEFT JOIN rev ON rev.order_id = o.order_id
), f AS (
    SELECT b.*,
           -- flag anomali timestamp (flag, tidak dihapus)
           COALESCE(ts_carrier  < ts_purchase, FALSE) AS flag_carrier_before_purchase,
           COALESCE(ts_carrier  < ts_approved, FALSE) AS flag_carrier_before_approved,
           COALESCE(ts_customer < ts_carrier,  FALSE) AS flag_customer_before_carrier,
           (order_status = 'delivered' AND ts_customer IS NULL)     AS flag_delivered_no_date,
           (order_status = 'canceled'  AND ts_customer IS NOT NULL) AS flag_canceled_has_delivery_date,
           -- Analytical Flags
           (n_items > 0)                                            AS has_items,
           (order_status = 'canceled')                              AS is_canceled,
           (order_status = 'unavailable')                           AS is_unavailable,
           (n_items > 0 AND order_status NOT IN ('canceled', 'unavailable')) AS is_revenue_order,
           (order_status = 'delivered' AND ts_customer IS NOT NULL) AS is_delivered_complete,
           (ts_purchase >= TIMESTAMP '2017-01-01' AND ts_purchase < TIMESTAMP '2018-09-01') AS in_analysis_window,
           (n_reviews_raw > 0)                                      AS has_review,
           (n_sellers > 1)                                          AS is_multi_seller,
           (n_payment_types > 1)                                    AS is_multi_payment_type
    FROM base b
)
SELECT f.*,
       CASE WHEN is_delivered_complete
            THEN date_diff('second', ts_purchase, ts_customer) / 86400.0 END AS delivery_days,
       (is_delivered_complete AND CAST(ts_customer AS DATE) > CAST(ts_estimated AS DATE)) AS is_late,
       (is_delivered_complete AND ts_customer > ts_estimated)                             AS is_late_ts_sensitivity
FROM f;

-- ------------------------------------------------------------
-- 10. Verifikasi (Acceptance Criteria)
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE clean_findings_raw (
    section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE
);

-- 10.1 Row count stg_* = raw_* (kecuali reviews & geolocation dijelaskan di bawah)
INSERT INTO clean_findings_raw VALUES
 ('stg_rowcount','stg_orders = raw_orders',                   (SELECT COUNT(*) FROM stg_orders),               (SELECT COUNT(*) FROM raw_orders), 0),
 ('stg_rowcount','stg_customers = raw_customers',             (SELECT COUNT(*) FROM stg_customers),            (SELECT COUNT(*) FROM raw_customers), 0),
 ('stg_rowcount','stg_order_items = raw_order_items',         (SELECT COUNT(*) FROM stg_order_items),          (SELECT COUNT(*) FROM raw_order_items), 0),
 ('stg_rowcount','stg_order_payments = raw_order_payments',   (SELECT COUNT(*) FROM stg_order_payments),       (SELECT COUNT(*) FROM raw_order_payments), 0),
 ('stg_rowcount','stg_order_reviews = raw_order_reviews',     (SELECT COUNT(*) FROM stg_order_reviews),        (SELECT COUNT(*) FROM raw_order_reviews), 0),
 ('stg_rowcount','stg_products = raw_products',               (SELECT COUNT(*) FROM stg_products),             (SELECT COUNT(*) FROM raw_products), 0),
 ('stg_rowcount','stg_sellers = raw_sellers',                 (SELECT COUNT(*) FROM stg_sellers),              (SELECT COUNT(*) FROM raw_sellers), 0),
 ('stg_rowcount','stg_category_translation = raw',            (SELECT COUNT(*) FROM stg_category_translation), (SELECT COUNT(*) FROM raw_category_translation), 0),
 ('stg_rowcount','stg_geolocation = raw_geolocation',         (SELECT COUNT(*) FROM stg_geolocation),          (SELECT COUNT(*) FROM raw_geolocation), 0),
 ('stg_rowcount','geo_dedup (1.000.163 - 261.831 duplikat penuh)', (SELECT COUNT(*) FROM geo_dedup),           738332, 0),
 ('stg_rowcount','order_reviews_clean = order ber-review',    (SELECT COUNT(*) FROM order_reviews_clean),      98673, 0),
 ('stg_rowcount','orders_clean = raw_orders',                 (SELECT COUNT(*) FROM orders_clean),             (SELECT COUNT(*) FROM raw_orders), 0),
 ('stg_rowcount','order_items_clean = raw_order_items',       (SELECT COUNT(*) FROM order_items_clean),        (SELECT COUNT(*) FROM raw_order_items), 0),
 ('stg_rowcount','order_payments_clean = raw_order_payments', (SELECT COUNT(*) FROM order_payments_clean),     (SELECT COUNT(*) FROM raw_order_payments), 0),
 ('stg_rowcount','products_clean = raw_products',             (SELECT COUNT(*) FROM products_clean),           (SELECT COUNT(*) FROM raw_products), 0),
 ('stg_rowcount','sellers_clean = raw_sellers',               (SELECT COUNT(*) FROM sellers_clean),            (SELECT COUNT(*) FROM raw_sellers), 0),
 ('stg_rowcount','dim_customer = customer_unique_id unik',    (SELECT COUNT(*) FROM dim_customer),             96096, 0),
 ('stg_rowcount','category_translation_clean = 71 + 2 manual',(SELECT COUNT(*) FROM category_translation_clean), 73, 0);

-- 10.2 Grain setelah dedup/cleaning
INSERT INTO clean_findings_raw VALUES
 ('grain','orders_clean.order_id unik (dup rows)',            (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM orders_clean), 0, 0),
 ('grain','order_reviews_clean.order_id unik (dup rows)',     (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM order_reviews_clean), 0, 0),
 ('grain','order_items_clean (order_id, order_item_id) dup',  (SELECT COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)) FROM order_items_clean), 0, 0),
 ('grain','order_payments_clean (order_id, seq) dup',         (SELECT COUNT(*) - COUNT(DISTINCT (order_id, payment_sequential)) FROM order_payments_clean), 0, 0),
 ('grain','dim_geo_zip.zip unik (dup rows)',                  (SELECT COUNT(*) - COUNT(DISTINCT zip) FROM dim_geo_zip), 0, 0),
 ('grain','products_clean.product_id unik (dup rows)',        (SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM products_clean), 0, 0),
 ('grain','category_translation_clean.category_pt unik (dup)', (SELECT COUNT(*) - COUNT(DISTINCT category_pt) FROM category_translation_clean), 0, 0);

-- 10.3 Cast: NULL setelah TRY_CAST harus = NULL raw (tidak ada gagal cast tak terduga)
INSERT INTO clean_findings_raw VALUES
 ('cast','orders: null ts_purchase/approved/carrier/customer/estimated vs raw',
        (SELECT COUNT(*) FILTER (WHERE ts_purchase IS NULL) + COUNT(*) FILTER (WHERE ts_approved IS NULL) + COUNT(*) FILTER (WHERE ts_carrier IS NULL)
              + COUNT(*) FILTER (WHERE ts_customer IS NULL) + COUNT(*) FILTER (WHERE ts_estimated IS NULL) FROM stg_orders),
        (SELECT COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL) + COUNT(*) FILTER (WHERE order_approved_at IS NULL) + COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL)
              + COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) + COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL) FROM raw_orders), 0),
 ('cast','order_items: null price/freight/limit vs raw',
        (SELECT COUNT(*) FILTER (WHERE price IS NULL) + COUNT(*) FILTER (WHERE freight_value IS NULL) + COUNT(*) FILTER (WHERE ts_shipping_limit IS NULL) FROM stg_order_items),
        (SELECT COUNT(*) FILTER (WHERE price IS NULL) + COUNT(*) FILTER (WHERE freight_value IS NULL) + COUNT(*) FILTER (WHERE shipping_limit_date IS NULL) FROM raw_order_items), 0),
 ('cast','order_payments: null seq/installments/value vs raw',
        (SELECT COUNT(*) FILTER (WHERE payment_sequential IS NULL) + COUNT(*) FILTER (WHERE payment_installments IS NULL) + COUNT(*) FILTER (WHERE payment_value IS NULL) FROM stg_order_payments),
        (SELECT COUNT(*) FILTER (WHERE payment_sequential IS NULL) + COUNT(*) FILTER (WHERE payment_installments IS NULL) + COUNT(*) FILTER (WHERE payment_value IS NULL) FROM raw_order_payments), 0),
 ('cast','products: null numeric vs raw',
        (SELECT COUNT(*) FILTER (WHERE name_length IS NULL) + COUNT(*) FILTER (WHERE description_length IS NULL) + COUNT(*) FILTER (WHERE photos_qty IS NULL)
              + COUNT(*) FILTER (WHERE weight_g IS NULL) + COUNT(*) FILTER (WHERE length_cm IS NULL) + COUNT(*) FILTER (WHERE height_cm IS NULL) + COUNT(*) FILTER (WHERE width_cm IS NULL) FROM stg_products),
        (SELECT COUNT(*) FILTER (WHERE product_name_lenght IS NULL) + COUNT(*) FILTER (WHERE product_description_lenght IS NULL) + COUNT(*) FILTER (WHERE product_photos_qty IS NULL)
              + COUNT(*) FILTER (WHERE product_weight_g IS NULL) + COUNT(*) FILTER (WHERE product_length_cm IS NULL) + COUNT(*) FILTER (WHERE product_height_cm IS NULL) + COUNT(*) FILTER (WHERE product_width_cm IS NULL) FROM raw_products), 0),
 ('cast','reviews: null score/creation/answer vs raw',
        (SELECT COUNT(*) FILTER (WHERE review_score IS NULL) + COUNT(*) FILTER (WHERE review_creation_ts IS NULL) + COUNT(*) FILTER (WHERE review_answer_ts IS NULL) FROM stg_order_reviews),
        (SELECT COUNT(*) FILTER (WHERE review_score IS NULL) + COUNT(*) FILTER (WHERE review_creation_date IS NULL) + COUNT(*) FILTER (WHERE review_answer_timestamp IS NULL) FROM raw_order_reviews), 0);

-- 10.4 orders_clean: flag anomali & populasi analitik (angka dari profiling / roadmap)
INSERT INTO clean_findings_raw VALUES
 ('orders_flags','flag_carrier_before_purchase',      (SELECT COUNT(*) FROM orders_clean WHERE flag_carrier_before_purchase), 166, 0),
 ('orders_flags','flag_carrier_before_approved',      (SELECT COUNT(*) FROM orders_clean WHERE flag_carrier_before_approved), 1359, 0),
 ('orders_flags','flag_customer_before_carrier',      (SELECT COUNT(*) FROM orders_clean WHERE flag_customer_before_carrier), 23, 0),
 ('orders_flags','flag_delivered_no_date',            (SELECT COUNT(*) FROM orders_clean WHERE flag_delivered_no_date), 8, 0),
 ('orders_flags','flag_canceled_has_delivery_date',   (SELECT COUNT(*) FROM orders_clean WHERE flag_canceled_has_delivery_date), 6, 0),
 ('population','is_canceled',                         (SELECT COUNT(*) FROM orders_clean WHERE is_canceled), 625, 0),
 ('population','is_unavailable',                      (SELECT COUNT(*) FROM orders_clean WHERE is_unavailable), 609, 0),
 ('population','has_items',                           (SELECT COUNT(*) FROM orders_clean WHERE has_items), 98666, 0),
 ('population','Revenue Population (is_revenue_order)', (SELECT COUNT(*) FROM orders_clean WHERE is_revenue_order), 98199, 0),
 ('population','Delivered Population (is_delivered_complete)', (SELECT COUNT(*) FROM orders_clean WHERE is_delivered_complete), 96470, 0),
 ('population','is_late (perbandingan tanggal, D1)',  (SELECT COUNT(*) FROM orders_clean WHERE is_late), 6534, 0),
 ('population','is_late_ts_sensitivity (timestamp)',  (SELECT COUNT(*) FROM orders_clean WHERE is_late_ts_sensitivity), 7826, 0),
 ('population','Review Population (has_review)',      (SELECT COUNT(*) FROM orders_clean WHERE has_review), 98673, 0),
 ('population','is_multi_seller',                     (SELECT COUNT(*) FROM orders_clean WHERE is_multi_seller), 1278, 0),
 ('population','is_multi_payment_type',               (SELECT COUNT(*) FROM orders_clean WHERE is_multi_payment_type), 2246, 0),
 ('population','Single-Seller Population (D10)',      (SELECT COUNT(*) FROM orders_clean WHERE is_revenue_order AND NOT is_multi_seller), 96922, 0),
 ('population','Payment Population (order punya payment)', (SELECT COUNT(*) FROM orders_clean WHERE n_payment_types > 0), 99440, 0),
 ('population','in_analysis_window (2017-01 s.d. 2018-08)', (SELECT COUNT(*) FROM orders_clean WHERE in_analysis_window), NULL, 0),
 ('population','sum status = Order Population',
        (SELECT COUNT(*) FROM orders_clean WHERE order_status IN ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved')), 99441, 0),
 ('population','delivery_days terisi hanya di Delivered Population',
        (SELECT COUNT(*) FROM orders_clean WHERE delivery_days IS NOT NULL AND NOT is_delivered_complete), 0, 0),
 ('population','orders_clean tanpa customer_unique_id',  (SELECT COUNT(*) FROM orders_clean WHERE customer_unique_id IS NULL), 0, 0);

-- 10.5 Fan-out & revenue (decimal eksak)
INSERT INTO clean_findings_raw VALUES
 ('fanout','SUM(price) join items->orders_clean - SUM(price) items',
        (SELECT CAST(ABS((SELECT SUM(i.price) FROM order_items_clean i JOIN orders_clean o USING (order_id)) - (SELECT SUM(price) FROM stg_order_items)) AS DOUBLE)), 0, 0.001),
 ('fanout','SUM(payment_value) join payments->orders_clean - SUM(payment_value) payments',
        (SELECT CAST(ABS((SELECT SUM(p.payment_value) FROM order_payments_clean p JOIN orders_clean o USING (order_id)) - (SELECT SUM(payment_value) FROM stg_order_payments)) AS DOUBLE)), 0, 0.001),
 ('fanout','customers join dim_geo_zip tidak menambah baris (n baris)',
        (SELECT COUNT(*) FROM stg_customers c LEFT JOIN dim_geo_zip z ON z.zip = c.zip_prefix), 99441, 0),
 ('revenue','Item Revenue Revenue Population (R$)',
        (SELECT CAST(SUM(i.price) AS DOUBLE) FROM order_items_clean i JOIN orders_clean o USING (order_id) WHERE o.is_revenue_order), 13494400.74, 0.011),
 ('revenue','recon (DECIMAL): diff <= 0,01',
        (SELECT COUNT(*) FROM (SELECT ABS(i.t - p.t) AS d
             FROM (SELECT order_id, SUM(price + freight_value) AS t FROM order_items_clean GROUP BY order_id) i
             JOIN (SELECT order_id, SUM(payment_value) AS t FROM order_payments_clean GROUP BY order_id) p USING (order_id)) WHERE d <= 0.01), 98362, 0),
 ('revenue','recon (DECIMAL): 0,01 < diff <= 1',
        (SELECT COUNT(*) FROM (SELECT ABS(i.t - p.t) AS d
             FROM (SELECT order_id, SUM(price + freight_value) AS t FROM order_items_clean GROUP BY order_id) i
             JOIN (SELECT order_id, SUM(payment_value) AS t FROM order_payments_clean GROUP BY order_id) p USING (order_id)) WHERE d > 0.01 AND d <= 1), 54, 0),
 ('revenue','recon (DECIMAL): diff > 1',
        (SELECT COUNT(*) FROM (SELECT ABS(i.t - p.t) AS d
             FROM (SELECT order_id, SUM(price + freight_value) AS t FROM order_items_clean GROUP BY order_id) i
             JOIN (SELECT order_id, SUM(payment_value) AS t FROM order_payments_clean GROUP BY order_id) p USING (order_id)) WHERE d > 1), 249, 0);

-- 10.6 order_items / order_payments / order_reviews
INSERT INTO clean_findings_raw VALUES
 ('order_items','flag_zero_freight',                  (SELECT COUNT(*) FROM order_items_clean WHERE flag_zero_freight), 383, 0),
 ('order_items','flag_shipping_limit_invalid',        (SELECT COUNT(*) FROM order_items_clean WHERE flag_shipping_limit_invalid), 4, 0),
 ('order_items','pasangan order-produk qty_units > 1',
        (SELECT COUNT(*) FROM (SELECT order_id, product_id FROM order_items_clean WHERE qty_units > 1 GROUP BY 1, 2)), 7088, 0),
 ('order_payments','flag_zero_payment',               (SELECT COUNT(*) FROM order_payments_clean WHERE flag_zero_payment), 9, 0),
 ('order_payments','flag_payment_not_defined',        (SELECT COUNT(*) FROM order_payments_clean WHERE flag_payment_not_defined), 3, 0),
 ('order_payments','flag_zero_installments',          (SELECT COUNT(*) FROM order_payments_clean WHERE flag_zero_installments), 2, 0),
 ('order_payments','order dengan flag_no_first_payment',
        (SELECT COUNT(DISTINCT order_id) FROM order_payments_clean WHERE flag_no_first_payment), 80, 0),
 ('order_reviews','order dengan n_reviews_raw > 1',   (SELECT COUNT(*) FROM order_reviews_clean WHERE n_reviews_raw > 1), 547, 0),
 ('order_reviews','Avg Review Score (dedup, D3)',     (SELECT ROUND(AVG(review_score), 4) FROM order_reviews_clean), 4.0864, 0.00011),
 ('order_reviews','message whitespace-only -> NULL (roadmap: 27)',
        (SELECT COUNT(*) FROM raw_order_reviews WHERE review_comment_message IS NOT NULL AND regexp_matches(review_comment_message, '^\s*$')), 27, 0),
 ('order_reviews','message whitespace-only tersisa di stg (harus 0)',
        (SELECT COUNT(*) FROM stg_order_reviews WHERE review_comment_message IS NOT NULL AND regexp_matches(review_comment_message, '^\s*$')), 0, 0),
 ('order_reviews','has_comment = TRUE (order_reviews_clean)', (SELECT COUNT(*) FROM order_reviews_clean WHERE has_comment), NULL, 0),
 ('order_reviews','flag_review_before_purchase (setelah dedup)', (SELECT COUNT(*) FROM order_reviews_clean WHERE flag_review_before_purchase), NULL, 0);

-- 10.7 products, kategori, sellers, customers, geolocation
INSERT INTO clean_findings_raw VALUES
 ('products','category_pt = unknown',                 (SELECT COUNT(*) FROM products_clean WHERE flag_category_unknown), 610, 0),
 ('products','category_en NULL setelah mapping (harus 0)', (SELECT COUNT(*) FROM products_clean WHERE category_en IS NULL), 0, 0),
 ('products','weight_g NULL (4 nol + 2 null)',        (SELECT COUNT(*) FROM products_clean WHERE weight_g IS NULL), 6, 0),
 ('products','typo tersisa di category_en_clean (harus 0)',
        (SELECT COUNT(*) FROM category_translation_clean WHERE category_en_clean LIKE '%costruction%' OR category_en_clean LIKE '%fashio\_%' ESCAPE '\' OR category_en_clean LIKE '%confort%'), 0, 0),
 ('products','kategori mapping manual',               (SELECT COUNT(*) FROM category_translation_clean WHERE is_manual_mapping), 2, 0),
 ('sellers','seller_city_clean = unknown',            (SELECT COUNT(*) FROM sellers_clean WHERE seller_city_clean = 'unknown'), 2, 0),
 ('sellers','flag_city_cleaned',                      (SELECT COUNT(*) FROM sellers_clean WHERE flag_city_cleaned), NULL, 0),
 ('customers','is_repeat_customer (>=24 jam, D5)',    (SELECT COUNT(*) FROM dim_customer WHERE is_repeat_customer), 2122, 0),
 ('customers','is_repeat_raw (>=2 order, Data Quality)', (SELECT COUNT(*) FROM dim_customer WHERE is_repeat_raw), 2997, 0),
 ('customers','flag_multi_state',                     (SELECT COUNT(*) FROM dim_customer WHERE flag_multi_state), 39, 0),
 ('customers','state_first_order <> state_latest_order', (SELECT COUNT(*) FROM dim_customer WHERE state_first_order <> state_latest_order), NULL, 0),
 ('geolocation','dim_geo_zip: jumlah zip',            (SELECT COUNT(*) FROM dim_geo_zip), NULL, 0),
 ('geolocation','dim_geo_zip: zip tanpa koordinat valid', (SELECT COUNT(*) FROM dim_geo_zip WHERE lat IS NULL), NULL, 0),
 ('geolocation','baris customer tanpa koordinat',
        (SELECT COUNT(*) FROM stg_customers c LEFT JOIN dim_geo_zip z ON z.zip = c.zip_prefix WHERE z.lat IS NULL), 279, 0),
 ('geolocation','baris seller tanpa koordinat',
        (SELECT COUNT(*) FROM stg_sellers s LEFT JOIN dim_geo_zip z ON z.zip = s.zip_prefix WHERE z.lat IS NULL), 7, 0);

CREATE OR REPLACE TABLE clean_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM clean_findings_raw;

-- Ringkasan status
SELECT status, COUNT(*) AS n_metrik FROM clean_findings GROUP BY status ORDER BY status;

-- Metrik yang BUKAN PASS (INFO = tidak ada ekspektasi; CHECK harus dijelaskan)
SELECT section, metric, n_actual, n_expected, status
FROM clean_findings WHERE status <> 'PASS' ORDER BY status DESC, section, metric;

-- Semua metrik (untuk ditempel ke docs/assumptions.md)
SELECT section, metric, n_actual, n_expected, status FROM clean_findings ORDER BY section, metric;

-- ------------------------------------------------------------
-- 11. Diagnostik tambahan (informasi, bukan PASS/CHECK)
-- ------------------------------------------------------------
-- 11.1 seller_city_clean sebelum -> sesudah (semua yang berubah)
SELECT seller_city_raw, seller_city_clean, seller_state
FROM sellers_clean WHERE flag_city_cleaned ORDER BY seller_city_raw;

-- 11.2 Kandidat kota seller kotor yang belum tertangkap aturan:
--      kota bersih yang TIDAK ada di kosakata kota geolocation (mencari 11 sisa dari angka 34 di roadmap)
SELECT seller_city_clean, seller_state, COUNT(*) AS n_seller
FROM sellers_clean
WHERE seller_city_clean <> 'unknown'
  AND seller_city_clean NOT IN (SELECT DISTINCT city_norm FROM geo_dedup)
GROUP BY seller_city_clean, seller_state
ORDER BY n_seller DESC, seller_city_clean;

-- 11.3 Distribusi Analysis Window x status
SELECT in_analysis_window, order_status, COUNT(*) AS n_order
FROM orders_clean GROUP BY in_analysis_window, order_status ORDER BY in_analysis_window DESC, n_order DESC;

-- 11.4 Kategori tanpa terjemahan asli yang dipetakan manual
SELECT category_pt, category_en, category_en_clean, is_manual_mapping
FROM category_translation_clean
WHERE is_manual_mapping OR category_en <> category_en_clean ORDER BY category_pt;

-- ------------------------------------------------------------
-- 12. Output parquet (1 file per tabel clean) -> data/processed/
-- ------------------------------------------------------------
COPY orders_clean                TO 'data/processed/04_orders_clean.parquet'                (FORMAT PARQUET);
COPY order_items_clean           TO 'data/processed/04_order_items_clean.parquet'           (FORMAT PARQUET);
COPY order_payments_clean        TO 'data/processed/04_order_payments_clean.parquet'        (FORMAT PARQUET);
COPY order_reviews_clean         TO 'data/processed/04_order_reviews_clean.parquet'         (FORMAT PARQUET);
COPY products_clean              TO 'data/processed/04_products_clean.parquet'              (FORMAT PARQUET);
COPY category_translation_clean  TO 'data/processed/04_category_translation_clean.parquet'  (FORMAT PARQUET);
COPY sellers_clean               TO 'data/processed/04_sellers_clean.parquet'               (FORMAT PARQUET);
COPY dim_customer                TO 'data/processed/04_dim_customer.parquet'                (FORMAT PARQUET);
COPY dim_geo_zip                 TO 'data/processed/04_dim_geo_zip.parquet'                 (FORMAT PARQUET);

-- Verifikasi output: row count tiap parquet
SELECT '04_orders_clean' AS file, COUNT(*) AS n FROM read_parquet('data/processed/04_orders_clean.parquet') UNION ALL
SELECT '04_order_items_clean',    COUNT(*) FROM read_parquet('data/processed/04_order_items_clean.parquet') UNION ALL
SELECT '04_order_payments_clean', COUNT(*) FROM read_parquet('data/processed/04_order_payments_clean.parquet') UNION ALL
SELECT '04_order_reviews_clean',  COUNT(*) FROM read_parquet('data/processed/04_order_reviews_clean.parquet') UNION ALL
SELECT '04_products_clean',       COUNT(*) FROM read_parquet('data/processed/04_products_clean.parquet') UNION ALL
SELECT '04_category_translation_clean', COUNT(*) FROM read_parquet('data/processed/04_category_translation_clean.parquet') UNION ALL
SELECT '04_sellers_clean',        COUNT(*) FROM read_parquet('data/processed/04_sellers_clean.parquet') UNION ALL
SELECT '04_dim_customer',         COUNT(*) FROM read_parquet('data/processed/04_dim_customer.parquet') UNION ALL
SELECT '04_dim_geo_zip',          COUNT(*) FROM read_parquet('data/processed/04_dim_geo_zip.parquet');
