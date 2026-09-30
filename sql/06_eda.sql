-- ============================================================
-- Tahap 7 — Exploratory Data Analysis (EDA)
-- File: sql/06_eda.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/06_eda.sql
-- Prasyarat: sql/04_data_cleaning.sql dan sql/05_data_validation.sql sudah dijalankan (gate PASS).
-- ============================================================
-- GRAIN:       beda per blok (order / item / payment / review / seller / state / bulan);
--              dinyatakan di komentar tiap blok
-- POPULATION:  dinyatakan per blok (Order, Analysis Window, Revenue, Delivered, Review,
--              Payment, Single-Seller n = 96.922, Item Population)
-- DENOMINATOR: dinyatakan per blok (kolom n / share)
-- ============================================================
-- EDA Governance: EDA hanya memahami pola dan menghasilkan hipotesis.
-- EDA TIDAK mengubah definisi KPI / populasi (terkunci di Tahap 6), tidak menghapus data,
-- tidak membuat kesimpulan kausal (semua hubungan = asosiasi), dan tidak memperluas scope.
-- Temuan masalah data baru -> kembali ke Tahap 5 -> re-validasi Tahap 6 -> ulangi EDA.
-- Output ringkasan: data/processed/06_eda_summary.parquet (tabel eda_metrics, format long).
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helper (TEMP): e_order = 1 baris per order; e_item = 1 baris per item
--    Tabel anak di-pre-aggregate ke grain order_id sebelum join (Fan-out Guard).
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE e_order AS
SELECT o.*,
       COALESCE(i.item_revenue, 0)  AS item_revenue,
       COALESCE(i.freight_total, 0) AS freight_total,
       COALESCE(i.n_products, 0)    AS n_products,
       p.payment_total, p.max_installments,
       r.review_score, r.has_comment, r.review_creation_ts, r.review_answer_ts
FROM orders_clean o
LEFT JOIN (SELECT order_id, SUM(price) AS item_revenue, SUM(freight_value) AS freight_total,
                  COUNT(DISTINCT product_id) AS n_products
           FROM order_items_clean GROUP BY order_id) i USING (order_id)
LEFT JOIN (SELECT order_id, SUM(payment_value) AS payment_total, MAX(payment_installments) AS max_installments
           FROM order_payments_clean GROUP BY order_id) p USING (order_id)
LEFT JOIN order_reviews_clean r USING (order_id);

CREATE OR REPLACE TEMP TABLE e_item AS
SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id,
       i.price, CAST(i.price AS DOUBLE) AS price_d,
       i.freight_value, CAST(i.freight_value AS DOUBLE) AS freight_d,
       i.flag_zero_freight,
       o.is_revenue_order, o.in_analysis_window, o.order_status, o.customer_state, o.ts_purchase,
       pc.category_en, s.seller_state
FROM order_items_clean i
JOIN orders_clean   o  ON o.order_id   = i.order_id
JOIN products_clean pc ON pc.product_id = i.product_id
JOIN sellers_clean  s  ON s.seller_id   = i.seller_id;

-- ============================================================
-- 1. REVENUE EXPLORATION  (Revenue Population, n = 98.199 order)
-- ============================================================
-- 1.1 Distribusi price per item (GRAIN: item; POPULATION: item dari Revenue Population)
SELECT COUNT(*) AS n_item,
       ROUND(MIN(price_d), 2) AS min, ROUND(quantile_cont(price_d, 0.05), 2) AS p05,
       ROUND(quantile_cont(price_d, 0.25), 2) AS p25, ROUND(quantile_cont(price_d, 0.5), 2) AS p50,
       ROUND(quantile_cont(price_d, 0.75), 2) AS p75, ROUND(quantile_cont(price_d, 0.9), 2) AS p90,
       ROUND(quantile_cont(price_d, 0.95), 2) AS p95, ROUND(quantile_cont(price_d, 0.99), 2) AS p99,
       ROUND(MAX(price_d), 2) AS max, ROUND(AVG(price_d), 2) AS mean
FROM e_item WHERE is_revenue_order;

-- 1.2 Price band: jumlah item dan porsi revenue (ekor kanan)
SELECT CASE WHEN price_d < 25 THEN '1: < 25' WHEN price_d < 50 THEN '2: 25-49'
            WHEN price_d < 100 THEN '3: 50-99' WHEN price_d < 200 THEN '4: 100-199'
            WHEN price_d < 500 THEN '5: 200-499' WHEN price_d < 1000 THEN '6: 500-999'
            ELSE '7: >= 1000' END AS price_band,
       COUNT(*) AS n_item,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_item,
       ROUND(100.0 * SUM(price_d) / SUM(SUM(price_d)) OVER (), 2) AS pct_item_revenue
FROM e_item WHERE is_revenue_order GROUP BY 1 ORDER BY 1;

-- 1.3 Item Revenue per order (GRAIN: order; POPULATION: Revenue Population)
SELECT COUNT(*) AS n_order,
       ROUND(quantile_cont(CAST(item_revenue AS DOUBLE), 0.5), 2)  AS median,
       ROUND(AVG(CAST(item_revenue AS DOUBLE)), 2)                 AS mean_aov,
       ROUND(quantile_cont(CAST(item_revenue AS DOUBLE), 0.95), 2) AS p95,
       ROUND(quantile_cont(CAST(item_revenue AS DOUBLE), 0.99), 2) AS p99,
       ROUND(MAX(CAST(item_revenue AS DOUBLE)), 2)                 AS max
FROM e_order WHERE is_revenue_order;

-- 1.4 Revenue per bulan (POPULATION: Revenue Population ∩ Analysis Window)
SELECT strftime(date_trunc('month', ts_purchase), '%Y-%m') AS bulan,
       COUNT(*)                                            AS revenue_orders,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2)         AS item_revenue,
       ROUND(CAST(SUM(freight_total) AS DOUBLE), 2)        AS freight_revenue,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2) AS aov,
       ROUND(100.0 * (CAST(SUM(item_revenue) AS DOUBLE)
             / LAG(CAST(SUM(item_revenue) AS DOUBLE)) OVER (ORDER BY date_trunc('month', ts_purchase)) - 1), 2) AS mom_revenue_pct
FROM e_order WHERE is_revenue_order AND in_analysis_window
GROUP BY date_trunc('month', ts_purchase) ORDER BY 1;

-- 1.5 Revenue per kuartal (POPULATION: Revenue Population ∩ Analysis Window)
SELECT strftime(date_trunc('quarter', ts_purchase), '%Y-Q') ||
       CAST(quarter(ts_purchase) AS VARCHAR)                AS kuartal,
       COUNT(*)                                             AS revenue_orders,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2)          AS item_revenue,
       COUNT(DISTINCT strftime(ts_purchase, '%Y-%m'))       AS n_bulan
FROM e_order WHERE is_revenue_order AND in_analysis_window
GROUP BY 1 ORDER BY 1;

-- 1.6 Rasio freight / item revenue per order (POPULATION: Revenue Population, item_revenue > 0)
SELECT COUNT(*) AS n_order,
       ROUND(quantile_cont(CAST(freight_total AS DOUBLE) / CAST(item_revenue AS DOUBLE), 0.25), 4) AS p25,
       ROUND(quantile_cont(CAST(freight_total AS DOUBLE) / CAST(item_revenue AS DOUBLE), 0.5), 4)  AS median,
       ROUND(quantile_cont(CAST(freight_total AS DOUBLE) / CAST(item_revenue AS DOUBLE), 0.75), 4) AS p75,
       ROUND(quantile_cont(CAST(freight_total AS DOUBLE) / CAST(item_revenue AS DOUBLE), 0.95), 4) AS p95,
       COUNT(*) FILTER (WHERE freight_total > item_revenue)                                        AS n_freight_gt_item,
       ROUND(100.0 * COUNT(*) FILTER (WHERE freight_total > item_revenue) / COUNT(*), 2)           AS pct_freight_gt_item
FROM e_order WHERE is_revenue_order AND item_revenue > 0;

-- 1.7 Rasio freight/item per price band (freight cenderung memberatkan barang murah?)
SELECT CASE WHEN price_d < 25 THEN '1: < 25' WHEN price_d < 50 THEN '2: 25-49'
            WHEN price_d < 100 THEN '3: 50-99' WHEN price_d < 200 THEN '4: 100-199'
            WHEN price_d < 500 THEN '5: 200-499' ELSE '6: >= 500' END AS price_band,
       COUNT(*) AS n_item,
       ROUND(100.0 * SUM(freight_d) / SUM(price_d), 2) AS freight_pct_of_item_revenue
FROM e_item WHERE is_revenue_order GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 2. ORDER EXPLORATION
-- ============================================================
-- 2.1 Order per bulan (POPULATION: Order Population; bulan kosong tetap tampil)
SELECT strftime(t.m, '%Y-%m') AS bulan, COUNT(o.order_id) AS n_orders,
       ROUND(100.0 * (COUNT(o.order_id) * 1.0 / NULLIF(LAG(COUNT(o.order_id)) OVER (ORDER BY t.m), 0) - 1), 2) AS mom_pct
FROM generate_series(TIMESTAMP '2016-09-01', TIMESTAMP '2018-10-01', INTERVAL 1 MONTH) AS t(m)
LEFT JOIN orders_clean o ON date_trunc('month', o.ts_purchase) = t.m
GROUP BY t.m ORDER BY t.m;

-- 2.2 Jumlah item per order (POPULATION: Revenue Population)
SELECT CASE WHEN n_items >= 6 THEN '6+' ELSE CAST(n_items AS VARCHAR) END AS n_item,
       COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM e_order WHERE is_revenue_order GROUP BY 1 ORDER BY 1;

-- 2.3 Multi-seller dan multi-produk
--     (a) seluruh order ber-item (98.666), sebagai konteks; (b) Revenue Population (98.199)
SELECT 'order ber-item' AS populasi, COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE is_multi_seller)  AS multi_seller,
       COUNT(*) FILTER (WHERE n_products > 1)   AS multi_produk,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_multi_seller) / COUNT(*), 2) AS pct_multi_seller,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_products > 1) / COUNT(*), 2)  AS pct_multi_produk
FROM e_order WHERE has_items
UNION ALL
SELECT 'Revenue Population', COUNT(*),
       COUNT(*) FILTER (WHERE is_multi_seller), COUNT(*) FILTER (WHERE n_products > 1),
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_multi_seller) / COUNT(*), 2),
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_products > 1) / COUNT(*), 2)
FROM e_order WHERE is_revenue_order;

-- ============================================================
-- 3. STATUS & FULFILLMENT EXPLORATION
-- ============================================================
-- 3.1 Status x ada/tidaknya item (POPULATION: Order Population)
SELECT order_status, COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE has_items)     AS dengan_item,
       COUNT(*) FILTER (WHERE NOT has_items) AS tanpa_item,
       ROUND(100.0 * COUNT(*) FILTER (WHERE NOT has_items) / COUNT(*), 2) AS pct_tanpa_item
FROM orders_clean GROUP BY order_status ORDER BY n_order DESC;

-- 3.2 Durasi antar-tahap dalam hari (POPULATION: Delivered Population; baris dengan flag
--     anomali urutan tanggal untuk tahap terkait di-exclude dari tahap itu saja)
SELECT tahap, COUNT(*) AS n,
       ROUND(quantile_cont(d, 0.5), 2)  AS p50, ROUND(quantile_cont(d, 0.95), 2) AS p95,
       ROUND(MAX(d), 2) AS max, ROUND(AVG(d), 2) AS mean
FROM (
    SELECT '1 purchase -> approved' AS tahap, date_diff('second', ts_purchase, ts_approved) / 86400.0 AS d
    FROM orders_clean WHERE is_delivered_complete AND ts_approved IS NOT NULL
    UNION ALL
    SELECT '2 approved -> carrier', date_diff('second', ts_approved, ts_carrier) / 86400.0
    FROM orders_clean WHERE is_delivered_complete AND ts_approved IS NOT NULL AND ts_carrier IS NOT NULL AND NOT flag_carrier_before_approved
    UNION ALL
    SELECT '3 carrier -> delivered', date_diff('second', ts_carrier, ts_customer) / 86400.0
    FROM orders_clean WHERE is_delivered_complete AND ts_carrier IS NOT NULL AND NOT flag_customer_before_carrier
    UNION ALL
    SELECT '4 purchase -> delivered (total)', delivery_days FROM orders_clean WHERE is_delivered_complete
) GROUP BY tahap ORDER BY tahap;

-- ============================================================
-- 4. DELIVERY EXPLORATION  (Delivered Population, n = 96.470)
-- ============================================================
-- 4.1 Distribusi delivery_days (hari)
SELECT COUNT(*) AS n, ROUND(MIN(delivery_days), 2) AS min,
       ROUND(quantile_cont(delivery_days, 0.5), 2)  AS p50, ROUND(quantile_cont(delivery_days, 0.9), 2) AS p90,
       ROUND(quantile_cont(delivery_days, 0.95), 2) AS p95, ROUND(quantile_cont(delivery_days, 0.99), 2) AS p99,
       ROUND(MAX(delivery_days), 2) AS max, ROUND(AVG(delivery_days), 2) AS mean
FROM orders_clean WHERE is_delivered_complete;

SELECT CASE WHEN delivery_days < 5 THEN '1: < 5' WHEN delivery_days < 10 THEN '2: 5-9'
            WHEN delivery_days < 15 THEN '3: 10-14' WHEN delivery_days < 20 THEN '4: 15-19'
            WHEN delivery_days < 30 THEN '5: 20-29' WHEN delivery_days < 60 THEN '6: 30-59'
            ELSE '7: >= 60' END AS delivery_days_band,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM orders_clean WHERE is_delivered_complete GROUP BY 1 ORDER BY 1;

-- 4.2 Selisih tanggal diterima vs tanggal estimasi (hari; negatif = lebih cepat; positif = telat).
--     Jumlah bucket positif = order telat menurut definisi terkunci D1 (perbandingan tanggal).
SELECT CASE WHEN dd <= -14 THEN '1: >= 14 hari lebih cepat' WHEN dd <= -8 THEN '2: 8-13 hari lebih cepat'
            WHEN dd <= -1 THEN '3: 1-7 hari lebih cepat' WHEN dd = 0 THEN '4: tepat hari estimasi'
            WHEN dd <= 3 THEN '5: telat 1-3 hari' WHEN dd <= 7 THEN '6: telat 4-7 hari'
            WHEN dd <= 14 THEN '7: telat 8-14 hari' ELSE '8: telat > 14 hari' END AS selisih_vs_estimasi,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT date_diff('day', CAST(ts_estimated AS DATE), CAST(ts_customer AS DATE)) AS dd
      FROM orders_clean WHERE is_delivered_complete) GROUP BY 1 ORDER BY 1;

-- 4.3 Keterlambatan menurut tahap: hanya order telat (is_late), jeda tahap yang dominan
SELECT COUNT(*) AS n_late,
       ROUND(quantile_cont(date_diff('second', ts_purchase, ts_carrier) / 86400.0, 0.5), 2)  AS median_purchase_to_carrier,
       ROUND(quantile_cont(date_diff('second', ts_carrier, ts_customer) / 86400.0, 0.5), 2)  AS median_carrier_to_delivered
FROM orders_clean
WHERE is_late AND ts_carrier IS NOT NULL AND NOT flag_carrier_before_purchase AND NOT flag_customer_before_carrier;

-- ============================================================
-- 5. REVIEW EXPLORATION  (Review Population, n = 98.673; dedup 1 review/order)
-- ============================================================
-- 5.1 Distribusi skor dan rasio komentar per skor
SELECT review_score, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) AS pct_has_comment
FROM order_reviews_clean GROUP BY review_score ORDER BY review_score;

-- 5.2 Jeda review_creation -> review_answer (hari)
SELECT COUNT(*) AS n,
       ROUND(quantile_cont(date_diff('second', review_creation_ts, review_answer_ts) / 86400.0, 0.5), 2)  AS p50,
       ROUND(quantile_cont(date_diff('second', review_creation_ts, review_answer_ts) / 86400.0, 0.95), 2) AS p95,
       ROUND(MAX(date_diff('second', review_creation_ts, review_answer_ts) / 86400.0), 2)                 AS max,
       COUNT(*) FILTER (WHERE review_answer_ts < review_creation_ts)                                       AS n_answer_before_creation
FROM order_reviews_clean;

-- 5.3 Skor rata-rata: order telat vs tepat waktu, DISTRATIFIKASI menurut timing jawaban (D4)
--     POPULATION: Delivered Population ∩ Review Population. Asosiasi, bukan kausal.
SELECT is_late, answered_before_delivery, COUNT(*) AS n_order,
       ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_score_1_2
FROM (SELECT o.is_late, (o.review_answer_ts < o.ts_customer) AS answered_before_delivery, o.review_score
      FROM e_order o WHERE o.is_delivered_complete AND o.has_review)
GROUP BY is_late, answered_before_delivery ORDER BY is_late, answered_before_delivery;

-- 5.4 Skor rata-rata per bucket keterlambatan (semua order, lalu hanya yang dijawab setelah terima)
SELECT CASE WHEN dd <= 0 THEN '1: tidak telat' WHEN dd <= 3 THEN '2: telat 1-3 hari'
            WHEN dd <= 7 THEN '3: telat 4-7 hari' WHEN dd <= 14 THEN '4: telat 8-14 hari'
            ELSE '5: telat > 14 hari' END AS telat_bucket,
       COUNT(*) AS n_order_semua, ROUND(AVG(review_score), 3) AS avg_score_semua,
       COUNT(*) FILTER (WHERE NOT ans_before) AS n_pasca_terima,
       ROUND(AVG(review_score) FILTER (WHERE NOT ans_before), 3) AS avg_score_pasca_terima
FROM (SELECT date_diff('day', CAST(ts_estimated AS DATE), CAST(ts_customer AS DATE)) AS dd,
             (review_answer_ts < ts_customer) AS ans_before, review_score
      FROM e_order WHERE is_delivered_complete AND has_review)
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 6. PAYMENT EXPLORATION  (Payment Population, n = 99.440 order)
-- ============================================================
-- 6.1 Tipe pembayaran (GRAIN: baris payment)
SELECT payment_type, COUNT(*) AS n_payment, COUNT(DISTINCT order_id) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_payment,
       ROUND(CAST(SUM(payment_value) AS DOUBLE), 2) AS total_value,
       ROUND(100.0 * CAST(SUM(payment_value) AS DOUBLE) / SUM(CAST(SUM(payment_value) AS DOUBLE)) OVER (), 2) AS pct_value,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_value
FROM order_payments_clean GROUP BY payment_type ORDER BY n_payment DESC;

-- 6.2 Cicilan kartu kredit (exclude flag_zero_installments)
SELECT CASE WHEN payment_installments = 1 THEN '1x' WHEN payment_installments = 2 THEN '2x'
            WHEN payment_installments = 3 THEN '3x' WHEN payment_installments <= 6 THEN '4-6x'
            WHEN payment_installments <= 10 THEN '7-10x' ELSE '11x+' END AS cicilan,
       COUNT(*) AS n_payment,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_value
FROM order_payments_clean
WHERE payment_type = 'credit_card' AND NOT flag_zero_installments
GROUP BY 1 ORDER BY MIN(payment_installments);

-- 6.3 Multi-payment: jumlah tipe per order dan kombinasi terbanyak
SELECT n_payment_types, COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM orders_clean WHERE n_payment_types > 0 GROUP BY 1 ORDER BY 1;

-- 6.3b Kombinasi tipe pada order multi-payment-type (GRAIN: order; dikelompokkan per kombinasi)
SELECT kombinasi_tipe, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT order_id, array_to_string(list_sort(list_distinct(list(payment_type))), ' + ') AS kombinasi_tipe
      FROM order_payments_clean GROUP BY order_id
      HAVING COUNT(DISTINCT payment_type) > 1)
GROUP BY kombinasi_tipe ORDER BY n_order DESC;

-- ============================================================
-- 7. CATEGORY & SELLER EXPLORATION  (GRAIN: item; POPULATION: Revenue Population kecuali disebut)
-- ============================================================
-- 7.1 Top 15 kategori by Item Revenue (n_order >= 100 = memenuhi minimum volume D6)
SELECT category_en, n_order, n_item,
       ROUND(CAST(rev AS DOUBLE), 2) AS item_revenue,
       ROUND(100.0 * CAST(rev AS DOUBLE) / SUM(CAST(rev AS DOUBLE)) OVER (), 2) AS pct_revenue,
       (n_order >= 100) AS memenuhi_min_volume
FROM (SELECT category_en, SUM(price) AS rev, COUNT(DISTINCT order_id) AS n_order, COUNT(*) AS n_item
      FROM e_item WHERE is_revenue_order GROUP BY category_en)
ORDER BY rev DESC LIMIT 15;

-- 7.2 Kategori dengan order terbanyak (top 10)
SELECT category_en, COUNT(DISTINCT order_id) AS n_order,
       ROUND(CAST(SUM(price) AS DOUBLE) / COUNT(DISTINCT order_id), 2) AS revenue_per_order
FROM e_item WHERE is_revenue_order GROUP BY category_en ORDER BY n_order DESC LIMIT 10;

-- 7.3 Konsentrasi seller: top 10 seller
--     (a) porsi baris item terhadap Item Population (112.650); (b) porsi Item Revenue Revenue Population
SELECT seller_id, seller_state, n_item_rows,
       ROUND(100.0 * n_item_rows / (SELECT COUNT(*) FROM order_items_clean), 2) AS pct_item_rows
FROM (SELECT seller_id, ANY_VALUE(seller_state) AS seller_state, COUNT(*) AS n_item_rows
      FROM e_item GROUP BY seller_id ORDER BY n_item_rows DESC LIMIT 10);

-- 7.4 Tier seller (D11): Top >= 100 order, Mid 30-99, Long-tail < 30
--     (n_order = order unik di Revenue Population; % seller terhadap 3.095 seller total)
SELECT tier, COUNT(*) AS n_seller,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sellers_clean), 2) AS pct_of_all_sellers,
       ROUND(CAST(SUM(rev) AS DOUBLE), 2) AS item_revenue,
       ROUND(100.0 * CAST(SUM(rev) AS DOUBLE) / SUM(CAST(SUM(rev) AS DOUBLE)) OVER (), 2) AS pct_revenue
FROM (SELECT seller_id, SUM(price) AS rev, COUNT(DISTINCT order_id) AS n_order,
             CASE WHEN COUNT(DISTINCT order_id) >= 100 THEN '1 top (>= 100 order)'
                  WHEN COUNT(DISTINCT order_id) >= 30  THEN '2 mid (30-99 order)'
                  ELSE '3 long-tail (< 30 order)' END AS tier
      FROM e_item WHERE is_revenue_order GROUP BY seller_id)
GROUP BY tier ORDER BY tier;

-- 7.5 Diagnostik: basis populasi untuk share revenue seller tier >= 100 order
--     EDA (Revenue Population) = 51,68%; roadmap A18/D11 = 51,48%. Jumlah seller (210) dan 6,79% sama.
--     a = Revenue Population (dipakai EDA); b/c = Item Population (semua baris item); d = GMV (item+freight)
WITH s AS (
    SELECT seller_id,
           COUNT(DISTINCT order_id) FILTER (WHERE is_revenue_order) AS n_rev_orders,
           COUNT(DISTINCT order_id)                                 AS n_all_orders,
           SUM(price) FILTER (WHERE is_revenue_order)               AS rev_rev,
           SUM(price)                                               AS rev_all,
           SUM(price + freight_value) FILTER (WHERE is_revenue_order) AS gmv_rev
    FROM e_item GROUP BY seller_id
)
SELECT ROUND(100.0 * CAST(SUM(rev_rev) FILTER (WHERE n_rev_orders >= 100) AS DOUBLE) / CAST(SUM(rev_rev) AS DOUBLE), 2) AS a_revpop_tier_by_rev_orders,
       ROUND(100.0 * CAST(SUM(rev_all) FILTER (WHERE n_all_orders >= 100) AS DOUBLE) / CAST(SUM(rev_all) AS DOUBLE), 2) AS b_itempop_tier_by_all_orders,
       ROUND(100.0 * CAST(SUM(rev_all) FILTER (WHERE n_rev_orders >= 100) AS DOUBLE) / CAST(SUM(rev_all) AS DOUBLE), 2) AS c_itempop_tier_by_rev_orders,
       ROUND(100.0 * CAST(SUM(gmv_rev) FILTER (WHERE n_rev_orders >= 100) AS DOUBLE) / CAST(SUM(gmv_rev) AS DOUBLE), 2) AS d_gmv_revpop,
       COUNT(*) FILTER (WHERE n_rev_orders >= 100) AS n_seller_ge100_rev_orders,
       COUNT(*) FILTER (WHERE n_all_orders >= 100) AS n_seller_ge100_all_orders,
       COUNT(*) FILTER (WHERE n_rev_orders = 0)    AS n_seller_tanpa_revenue_order
FROM s;

-- 7.6 Diagnostik: share kategori 'unknown' menurut basis populasi (EDA 1,323% vs roadmap D7 1,321%)
SELECT ROUND(100.0 * CAST(SUM(price) FILTER (WHERE category_en = 'unknown' AND is_revenue_order) AS DOUBLE)
             / CAST(SUM(price) FILTER (WHERE is_revenue_order) AS DOUBLE), 3) AS unknown_pct_revenue_pop,
       ROUND(100.0 * CAST(SUM(price) FILTER (WHERE category_en = 'unknown') AS DOUBLE)
             / CAST(SUM(price) AS DOUBLE), 3)                                 AS unknown_pct_item_pop
FROM e_item;

-- ============================================================
-- 8. REGIONAL EXPLORATION
-- ============================================================
-- 8.1 Top 10 state customer by order dan revenue
--     (orders_all = Order Population; revenue_orders/item_revenue = Revenue Population)
SELECT customer_state,
       COUNT(*)                                                   AS orders_all,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)         AS pct_orders_all,
       COUNT(*) FILTER (WHERE is_revenue_order)                   AS revenue_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_revenue_order)
             / SUM(COUNT(*) FILTER (WHERE is_revenue_order)) OVER (), 2) AS pct_revenue_orders,
       ROUND(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS item_revenue,
       ROUND(100.0 * CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE)
             / SUM(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE)) OVER (), 2) AS pct_revenue
FROM e_order GROUP BY customer_state ORDER BY orders_all DESC LIMIT 10;

-- 8.2 Ketimpangan customer vs seller per state (semua 27 state; urut selisih terbesar)
--     customer = baris customer (99.441); seller = 3.095 seller
SELECT COALESCE(c.state, s.seller_state) AS state,
       COALESCE(c.n_customer, 0) AS n_customer, COALESCE(s.n_seller, 0) AS n_seller,
       ROUND(100.0 * COALESCE(c.n_customer, 0) / SUM(COALESCE(c.n_customer, 0)) OVER (), 2) AS pct_customer,
       ROUND(100.0 * COALESCE(s.n_seller, 0)   / SUM(COALESCE(s.n_seller, 0))   OVER (), 2) AS pct_seller,
       ROUND(100.0 * COALESCE(s.n_seller, 0) / SUM(COALESCE(s.n_seller, 0)) OVER ()
           - 100.0 * COALESCE(c.n_customer, 0) / SUM(COALESCE(c.n_customer, 0)) OVER (), 2) AS selisih_pct_poin
FROM (SELECT state, COUNT(*) AS n_customer FROM stg_customers GROUP BY state) c
FULL OUTER JOIN (SELECT seller_state, COUNT(*) AS n_seller FROM sellers_clean GROUP BY seller_state) s
       ON s.seller_state = c.state
ORDER BY ABS(selisih_pct_poin) DESC;

-- 8.3 Intra-state vs antar-state (POPULATION: Single-Seller Population, n = 96.922)
--     Delivery days / late rate hanya untuk yang ∈ Delivered Population. Asosiasi, bukan kausal.
SELECT (o.customer_state = one.seller_state) AS same_state,
       COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_order,
       ROUND(AVG(CAST(o.freight_total AS DOUBLE)), 2) AS avg_freight_per_order,
       ROUND(AVG(CAST(o.item_revenue AS DOUBLE)), 2)  AS avg_item_revenue,
       COUNT(*) FILTER (WHERE o.is_delivered_complete) AS n_delivered,
       ROUND(AVG(o.delivery_days), 2) AS avg_delivery_days,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.is_late) / NULLIF(COUNT(*) FILTER (WHERE o.is_delivered_complete), 0), 3) AS late_rate_pct
FROM e_order o
JOIN (SELECT order_id, MIN(seller_state) AS seller_state FROM e_item GROUP BY order_id HAVING COUNT(DISTINCT seller_id) = 1) one
     ON one.order_id = o.order_id
WHERE o.is_revenue_order AND NOT o.is_multi_seller
GROUP BY 1 ORDER BY 1 DESC;

-- ============================================================
-- 9. TIME EXPLORATION
-- ============================================================
-- 9.1 Bulan dengan period_quality (bulan kosong = data hilang, BUKAN nol transaksi)
SELECT strftime(t.m, '%Y-%m') AS bulan,
       CASE WHEN strftime(t.m, '%Y-%m') = '2016-11' THEN 'missing'
            WHEN strftime(t.m, '%Y-%m') IN ('2016-09', '2016-10', '2016-12') THEN 'sparse_rampup'
            WHEN strftime(t.m, '%Y-%m') IN ('2018-09', '2018-10') THEN 'truncated'
            ELSE 'full' END AS period_quality,
       COUNT(o.order_id) AS n_orders,
       COUNT(*) FILTER (WHERE o.is_revenue_order) AS revenue_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.order_status IN ('shipped','invoiced','processing','created','approved'))
             / NULLIF(COUNT(o.order_id), 0), 2) AS pct_in_flight
FROM generate_series(TIMESTAMP '2016-09-01', TIMESTAMP '2018-10-01', INTERVAL 1 MONTH) AS t(m)
LEFT JOIN orders_clean o ON date_trunc('month', o.ts_purchase) = t.m
GROUP BY t.m ORDER BY t.m;

-- 9.2 Verifikasi batas data: tanggal purchase pertama/terakhir per bulan batas
SELECT strftime(date_trunc('month', ts_purchase), '%Y-%m') AS bulan,
       COUNT(*) AS n_orders, MIN(ts_purchase) AS purchase_pertama, MAX(ts_purchase) AS purchase_terakhir,
       COUNT(DISTINCT CAST(ts_purchase AS DATE)) AS n_hari_ada_order
FROM orders_clean
WHERE strftime(date_trunc('month', ts_purchase), '%Y-%m') IN ('2016-09','2016-10','2016-12','2017-01','2018-08','2018-09','2018-10')
GROUP BY 1 ORDER BY 1;

SELECT MIN(ts_purchase) AS purchase_min, MAX(ts_purchase) AS purchase_max,
       MAX(ts_customer) AS delivered_max, MAX(ts_estimated) AS estimated_max
FROM orders_clean;

-- 9.3 Status order di bulan terpotong (2018-09/10): ekor data, bukan permintaan yang hilang
SELECT strftime(date_trunc('month', ts_purchase), '%Y-%m') AS bulan, order_status, COUNT(*) AS n_order
FROM orders_clean WHERE ts_purchase >= TIMESTAMP '2018-09-01'
GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- ============================================================
-- 10. OUTLIER & ANOMALY EXPLORATION
-- ============================================================
-- 10.1 Order dengan delivery_days > P99 (POPULATION: Delivered Population)
CREATE OR REPLACE TEMP TABLE e_p99 AS
SELECT quantile_cont(delivery_days, 0.99) AS p99 FROM orders_clean WHERE is_delivered_complete;

SELECT (SELECT ROUND(p99, 2) FROM e_p99) AS delivery_days_p99,
       COUNT(*) AS n_order_gt_p99,
       ROUND(AVG(delivery_days), 2) AS mean_delivery_days,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 2) AS pct_late
FROM orders_clean WHERE is_delivered_complete AND delivery_days > (SELECT p99 FROM e_p99);

-- state yang over-represented di ekor (lift = porsi di ekor / porsi di Delivered Population)
SELECT customer_state, n_tail, ROUND(100.0 * n_tail / SUM(n_tail) OVER (), 2) AS pct_tail,
       ROUND(100.0 * n_base / SUM(n_base) OVER (), 2) AS pct_base,
       ROUND((1.0 * n_tail / SUM(n_tail) OVER ()) / (1.0 * n_base / SUM(n_base) OVER ()), 2) AS lift
FROM (SELECT customer_state,
             COUNT(*) FILTER (WHERE delivery_days > (SELECT p99 FROM e_p99)) AS n_tail,
             COUNT(*) AS n_base
      FROM orders_clean WHERE is_delivered_complete GROUP BY customer_state)
WHERE n_tail > 0 ORDER BY n_tail DESC LIMIT 8;

-- 10.2 freight_value = 0 (POPULATION: Item Population): sebaran seller, state seller, kategori
SELECT 'seller_state' AS dimensi, seller_state AS nilai, COUNT(*) AS n_item,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM e_item WHERE flag_zero_freight GROUP BY seller_state
UNION ALL
SELECT 'seller_id', seller_id, COUNT(*), ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM e_item WHERE flag_zero_freight), 2)
FROM e_item WHERE flag_zero_freight GROUP BY seller_id
UNION ALL
SELECT 'category', category_en, COUNT(*), ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM e_item WHERE flag_zero_freight), 2)
FROM e_item WHERE flag_zero_freight GROUP BY category_en
ORDER BY dimensi, n_item DESC;

-- 10.3 Harga ekstrem >= P99 (POPULATION: item dari Revenue Population)
CREATE OR REPLACE TEMP TABLE e_price_p99 AS
SELECT quantile_cont(price_d, 0.99) AS p99 FROM e_item WHERE is_revenue_order;

SELECT (SELECT ROUND(p99, 2) FROM e_price_p99) AS price_p99,
       COUNT(*) AS n_item_ge_p99,
       ROUND(100.0 * SUM(price_d) / (SELECT SUM(price_d) FROM e_item WHERE is_revenue_order), 2) AS pct_item_revenue
FROM e_item WHERE is_revenue_order AND price_d >= (SELECT p99 FROM e_price_p99);

SELECT category_en, COUNT(*) AS n_item, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM e_item WHERE is_revenue_order AND price_d >= (SELECT p99 FROM e_price_p99)
GROUP BY category_en ORDER BY n_item DESC LIMIT 8;

-- 10.4 Order dengan anomali urutan timestamp (POPULATION: Order Population)
SELECT order_status,
       COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE flag_carrier_before_purchase) AS carrier_lt_purchase,
       COUNT(*) FILTER (WHERE flag_carrier_before_approved) AS carrier_lt_approved,
       COUNT(*) FILTER (WHERE flag_customer_before_carrier) AS customer_lt_carrier
FROM orders_clean
WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier
GROUP BY order_status ORDER BY n_order DESC;

-- state dan bulan: apakah anomali mengelompok? (lift terhadap Order Population)
SELECT customer_state, n_anom, ROUND(100.0 * n_anom / SUM(n_anom) OVER (), 2) AS pct_anom,
       ROUND(100.0 * n_base / SUM(n_base) OVER (), 2) AS pct_base,
       ROUND((1.0 * n_anom / SUM(n_anom) OVER ()) / (1.0 * n_base / SUM(n_base) OVER ()), 2) AS lift
FROM (SELECT customer_state,
             COUNT(*) FILTER (WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier) AS n_anom,
             COUNT(*) AS n_base
      FROM orders_clean GROUP BY customer_state)
WHERE n_anom > 0 ORDER BY n_anom DESC LIMIT 8;

SELECT strftime(date_trunc('month', ts_purchase), '%Y-%m') AS bulan,
       COUNT(*) FILTER (WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier) AS n_anom,
       COUNT(*) AS n_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier) / COUNT(*), 2) AS pct_anom
FROM orders_clean WHERE in_analysis_window GROUP BY 1 ORDER BY 1;

-- seller: konsentrasi anomali pada order single-seller (Single-Seller Population)
SELECT one.seller_id, COUNT(*) AS n_order_anom,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_anom_orders
FROM e_order o
JOIN (SELECT order_id, MIN(seller_id) AS seller_id FROM e_item GROUP BY order_id HAVING COUNT(DISTINCT seller_id) = 1) one
     ON one.order_id = o.order_id
WHERE o.is_revenue_order AND NOT o.is_multi_seller
  AND (o.flag_carrier_before_purchase OR o.flag_carrier_before_approved OR o.flag_customer_before_carrier)
GROUP BY one.seller_id ORDER BY n_order_anom DESC LIMIT 8;

-- ============================================================
-- 11. eda_metrics: metrik kunci EDA (format long) -> parquet
-- ============================================================
CREATE OR REPLACE TABLE eda_metrics (eda_group VARCHAR, metric VARCHAR, value DOUBLE, unit VARCHAR);

INSERT INTO eda_metrics VALUES
 ('revenue','price_p50',                (SELECT ROUND(quantile_cont(price_d, 0.5), 2)  FROM e_item WHERE is_revenue_order), 'R$'),
 ('revenue','price_p95',                (SELECT ROUND(quantile_cont(price_d, 0.95), 2) FROM e_item WHERE is_revenue_order), 'R$'),
 ('revenue','price_p99',                (SELECT ROUND(quantile_cont(price_d, 0.99), 2) FROM e_item WHERE is_revenue_order), 'R$'),
 ('revenue','price_max',                (SELECT ROUND(MAX(price_d), 2) FROM e_item WHERE is_revenue_order), 'R$'),
 ('revenue','item_revenue_per_order_median', (SELECT ROUND(quantile_cont(CAST(item_revenue AS DOUBLE), 0.5), 2) FROM e_order WHERE is_revenue_order), 'R$'),
 ('revenue','item_revenue_per_order_mean',   (SELECT ROUND(AVG(CAST(item_revenue AS DOUBLE)), 2) FROM e_order WHERE is_revenue_order), 'R$'),
 ('revenue','item_revenue_per_order_p99',    (SELECT ROUND(quantile_cont(CAST(item_revenue AS DOUBLE), 0.99), 2) FROM e_order WHERE is_revenue_order), 'R$'),
 ('revenue','freight_to_item_ratio_median',  (SELECT ROUND(quantile_cont(CAST(freight_total AS DOUBLE) / CAST(item_revenue AS DOUBLE), 0.5), 4) FROM e_order WHERE is_revenue_order AND item_revenue > 0), 'rasio'),
 ('revenue','pct_orders_freight_gt_item_revenue', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE freight_total > item_revenue) / COUNT(*), 2) FROM e_order WHERE is_revenue_order AND item_revenue > 0), '%'),
 ('order','orders_2017_11',             (SELECT COUNT(*) FROM orders_clean WHERE ts_purchase >= TIMESTAMP '2017-11-01' AND ts_purchase < TIMESTAMP '2017-12-01'), 'order'),
 ('order','pct_revenue_orders_1_item',  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n_items = 1) / COUNT(*), 2) FROM e_order WHERE is_revenue_order), '%'),
 ('order','multi_seller_orders_item_pop',(SELECT COUNT(*) FROM e_order WHERE is_multi_seller), 'order'),
 ('order','multi_product_orders_item_pop',(SELECT COUNT(*) FROM e_order WHERE has_items AND n_products > 1), 'order'),
 ('status','pct_unavailable_without_items', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE NOT has_items) / COUNT(*), 2) FROM orders_clean WHERE is_unavailable), '%'),
 ('status','pct_canceled_without_items',    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE NOT has_items) / COUNT(*), 2) FROM orders_clean WHERE is_canceled), '%'),
 ('status','median_days_purchase_to_approved', (SELECT ROUND(quantile_cont(date_diff('second', ts_purchase, ts_approved) / 86400.0, 0.5), 2) FROM orders_clean WHERE is_delivered_complete AND ts_approved IS NOT NULL), 'hari'),
 ('status','median_days_carrier_to_delivered', (SELECT ROUND(quantile_cont(date_diff('second', ts_carrier, ts_customer) / 86400.0, 0.5), 2) FROM orders_clean WHERE is_delivered_complete AND ts_carrier IS NOT NULL AND NOT flag_customer_before_carrier), 'hari'),
 ('delivery','delivery_days_median',    (SELECT ROUND(quantile_cont(delivery_days, 0.5), 2)  FROM orders_clean WHERE is_delivered_complete), 'hari'),
 ('delivery','delivery_days_p95',       (SELECT ROUND(quantile_cont(delivery_days, 0.95), 2) FROM orders_clean WHERE is_delivered_complete), 'hari'),
 ('delivery','delivery_days_max',       (SELECT ROUND(MAX(delivery_days), 2) FROM orders_clean WHERE is_delivered_complete), 'hari'),
 ('delivery','late_rate_pct',           (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM orders_clean WHERE is_delivered_complete), '%'),
 ('delivery','avg_days_earlier_than_estimate_on_time_orders',
        (SELECT ROUND(AVG(date_diff('second', ts_customer, ts_estimated) / 86400.0), 2) FROM orders_clean WHERE is_delivered_complete AND NOT is_late), 'hari'),
 ('review','pct_score_5',               (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 5) / COUNT(*), 2) FROM order_reviews_clean), '%'),
 ('review','pct_has_comment',           (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) FROM order_reviews_clean), '%'),
 ('review','answer_lag_days_median',    (SELECT ROUND(quantile_cont(date_diff('second', review_creation_ts, review_answer_ts) / 86400.0, 0.5), 2) FROM order_reviews_clean), 'hari'),
 ('review','pct_answered_before_delivery',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_answer_ts < ts_customer) / COUNT(*), 2) FROM e_order WHERE is_delivered_complete AND has_review), '%'),
 ('review','avg_score_late_answered_after_delivery',
        (SELECT ROUND(AVG(review_score), 3) FROM e_order WHERE is_delivered_complete AND has_review AND is_late AND review_answer_ts >= ts_customer), 'skor'),
 ('review','avg_score_on_time_answered_after_delivery',
        (SELECT ROUND(AVG(review_score), 3) FROM e_order WHERE is_delivered_complete AND has_review AND NOT is_late AND review_answer_ts >= ts_customer), 'skor'),
 ('payment','credit_card_pct_of_payment_value',
        (SELECT ROUND(100.0 * CAST(SUM(payment_value) FILTER (WHERE payment_type = 'credit_card') AS DOUBLE) / CAST(SUM(payment_value) AS DOUBLE), 2) FROM order_payments_clean), '%'),
 ('payment','credit_card_pct_installments_gt_1',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_installments > 1) / COUNT(*), 2) FROM order_payments_clean WHERE payment_type = 'credit_card' AND NOT flag_zero_installments), '%'),
 ('payment','pct_orders_multi_payment_type',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_multi_payment_type) / COUNT(*), 2) FROM orders_clean WHERE n_payment_types > 0), '%'),
 ('category','top1_category_pct_revenue',
        (SELECT ROUND(MAX(100.0 * CAST(rev AS DOUBLE) / CAST(tot AS DOUBLE)), 2) FROM (SELECT SUM(price) AS rev, SUM(SUM(price)) OVER () AS tot FROM e_item WHERE is_revenue_order GROUP BY category_en)), '%'),
 ('category','top10_categories_pct_revenue',
        (SELECT ROUND(100.0 * SUM(CAST(rev AS DOUBLE)) / MAX(CAST(tot AS DOUBLE)), 2)
         FROM (SELECT rev, tot FROM (SELECT SUM(price) AS rev, SUM(SUM(price)) OVER () AS tot FROM e_item WHERE is_revenue_order GROUP BY category_en) ORDER BY rev DESC LIMIT 10)), '%'),
 ('category','unknown_pct_revenue',
        (SELECT ROUND(100.0 * CAST(SUM(price) FILTER (WHERE category_en = 'unknown') AS DOUBLE) / CAST(SUM(price) AS DOUBLE), 3) FROM e_item WHERE is_revenue_order), '%'),
 ('category','n_categories_ge_100_orders',
        (SELECT COUNT(*) FROM (SELECT category_en FROM e_item WHERE is_revenue_order GROUP BY category_en HAVING COUNT(DISTINCT order_id) >= 100)), 'kategori'),
 ('seller','top10_sellers_pct_item_rows',
        (SELECT ROUND(100.0 * SUM(n) / (SELECT COUNT(*) FROM order_items_clean), 2) FROM (SELECT COUNT(*) AS n FROM e_item GROUP BY seller_id ORDER BY n DESC LIMIT 10)), '%'),
 ('seller','sellers_ge_100_orders',
        (SELECT COUNT(*) FROM (SELECT seller_id FROM e_item WHERE is_revenue_order GROUP BY seller_id HAVING COUNT(DISTINCT order_id) >= 100)), 'seller'),
 ('seller','pct_revenue_sellers_ge_100_orders',
        (SELECT ROUND(100.0 * CAST(SUM(rev) FILTER (WHERE n >= 100) AS DOUBLE) / CAST(SUM(rev) AS DOUBLE), 2)
         FROM (SELECT SUM(price) AS rev, COUNT(DISTINCT order_id) AS n FROM e_item WHERE is_revenue_order GROUP BY seller_id)), '%'),
 ('regional','sp_pct_orders_all',       (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE customer_state = 'SP') / COUNT(*), 2) FROM orders_clean), '%'),
 ('regional','sp_pct_item_revenue',
        (SELECT ROUND(100.0 * CAST(SUM(item_revenue) FILTER (WHERE customer_state = 'SP') AS DOUBLE) / CAST(SUM(item_revenue) AS DOUBLE), 2) FROM e_order WHERE is_revenue_order), '%'),
 ('regional','sp_pct_customers',        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE state = 'SP') / COUNT(*), 2) FROM stg_customers), '%'),
 ('regional','sp_pct_sellers',          (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE seller_state = 'SP') / COUNT(*), 2) FROM sellers_clean), '%'),
 ('regional','pct_single_seller_same_state',
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE o.customer_state = one.seller_state) / COUNT(*), 2)
         FROM e_order o JOIN (SELECT order_id, MIN(seller_state) AS seller_state FROM e_item GROUP BY order_id HAVING COUNT(DISTINCT seller_id) = 1) one ON one.order_id = o.order_id
         WHERE o.is_revenue_order AND NOT o.is_multi_seller), '%'),
 ('time','n_months_missing_or_thin_or_truncated', (SELECT COUNT(*) FROM prof_monthly WHERE n_orders < 400), 'bulan'),
 ('outlier','delivery_days_p99',        (SELECT ROUND(p99, 2) FROM e_p99), 'hari'),
 ('outlier','n_orders_delivery_gt_p99', (SELECT COUNT(*) FROM orders_clean WHERE is_delivered_complete AND delivery_days > (SELECT p99 FROM e_p99)), 'order'),
 ('outlier','n_zero_freight_items',     (SELECT COUNT(*) FROM order_items_clean WHERE flag_zero_freight), 'item'),
 ('outlier','price_ge_p99_pct_item_revenue',
        (SELECT ROUND(100.0 * SUM(price_d) FILTER (WHERE price_d >= (SELECT p99 FROM e_price_p99)) / SUM(price_d), 2) FROM e_item WHERE is_revenue_order), '%'),
 ('outlier','n_orders_any_timestamp_anomaly',
        (SELECT COUNT(*) FROM orders_clean WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier), 'order');

SELECT eda_group, metric, value, unit FROM eda_metrics ORDER BY eda_group, metric;

-- ============================================================
-- 12. Output: data/processed/06_eda_summary.parquet
-- ============================================================
COPY eda_metrics TO 'data/processed/06_eda_summary.parquet' (FORMAT PARQUET);
SELECT eda_group, COUNT(*) AS n_metrik FROM read_parquet('data/processed/06_eda_summary.parquet') GROUP BY eda_group ORDER BY eda_group;
