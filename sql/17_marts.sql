-- ============================================================
-- Tahap 18 — Data Mart Design (6 mart untuk 6 halaman dashboard)
-- File: sql/17_marts.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/17_marts.sql
-- Prasyarat: Tahap 4-17 sudah dijalankan (tabel hasil analysis: sales_monthly, status_monthly, delivery_monthly,
--            sat_monthly, payment_monthly, category_summary, seller_summary, seller_state_balance,
--            regional_state/city/relative, repeat_monthly/cohort/state, kpi_lock, *_findings, dll.).
-- ============================================================
-- GRAIN:       dinyatakan per tabel mart di bawah (kolom "grain" pada tabel mart_catalog)
-- POPULATION:  mengikuti populasi terkunci Tahap 6; mart TIDAK membuat definisi populasi baru
-- DENOMINATOR: dinyatakan per tabel; n selalu ada
-- ============================================================
-- Mart = subject-oriented, dipetakan ke 6 halaman dashboard:
--   mart_overview               -> Halaman 1 (Overview)
--   mart_fulfillment_delivery   -> Halaman 2 (Fulfillment & Delivery)
--   mart_customer_satisfaction  -> Halaman 3 (Customer Satisfaction)
--   mart_product_payment        -> Halaman 4 (Product & Payment)
--   mart_seller_regional        -> Halaman 5 (Seller, Regional & Repeat)
--   mart_data_quality_summary   -> Halaman 6 (Data Quality & Methodology)
-- Setiap mart = beberapa tabel dengan prefix yang sama (mart_<singkatan>_<subjek>).
--
-- Dashboard Methodology Decisions (LOCKED, diterapkan di sini):
--   1. Tren bulanan/MoM/YoY hanya period_quality = 'full'; bulan non-full tetap ada dengan show_in_trend = FALSE
--      (gap/anotasi, bukan nol). KPI total diberi label rentang periodenya.
--   2. Item Revenue = SUM(price) Revenue Population; freight terpisah; GMV = Item + Freight. payment_value HANYA di
--      mart_pp_payment_* (label "bukan revenue") dan mart_data_quality_summary (rekonsiliasi).
--   3. Late Rate / On-Time Rate dari Delivered Population (definisi tanggal); anomali timestamp = count di DQ mart.
--   4. Avg Review Score dari Review Population (dedup); per kategori/seller = "Associated Review Score" dengan filter
--      minimum volume; late vs on-time dipisah menurut answered_before_delivery (D4).
--   5. Cancellation Rate dan Unavailable Rate dua metrik terpisah (denominator Total Orders).
--   6. Kategori 'unknown' tampil sebagai kategori sendiri.
--   7. mart_data_quality_summary hanya metrik kuantitatif.
--   8. Repeat: headline = Repeat Rate >= 24 jam dan 90-day Repeat Rate; repeat mentah hanya di DQ mart; cohort hanya window tetap.
--   9. State tidak ditier (D12); kategori/seller/kota hanya melewati minimum volume (D6) untuk rate dan peringkat.
-- Bila sebuah angka belum tersimpan sebagai tabel hasil analysis, mart menghitungnya dari fact_*/dim_* dengan flag
-- terkunci yang sama (tanpa definisi populasi baru).
-- Acceptance: tabel mart_checks (row-count & sum-check terhadap sumber) harus GATE PASS sebelum mart dipakai dashboard.
-- ============================================================

-- ============================================================
-- MART 1: mart_overview (Halaman 1)
-- ============================================================
-- mart_overview_kpi: 1 baris per KPI terkunci. value_all_period = seluruh data; value_analysis_window = 2017-01..2018-08
CREATE OR REPLACE TABLE mart_overview_kpi AS
WITH w AS (
    SELECT
      (SELECT SUM(item_revenue)    FROM sales_monthly WHERE show_in_trend) AS rev_w,
      (SELECT SUM(freight_revenue) FROM sales_monthly WHERE show_in_trend) AS fr_w,
      (SELECT SUM(gmv)             FROM sales_monthly WHERE show_in_trend) AS gmv_w,
      (SELECT SUM(total_orders)    FROM sales_monthly WHERE show_in_trend) AS ord_w,
      (SELECT SUM(revenue_orders)  FROM sales_monthly WHERE show_in_trend) AS rord_w,
      (SELECT 100.0 * SUM(canceled)    / SUM(total_orders) FROM status_monthly WHERE show_in_trend) AS canc_w,
      (SELECT 100.0 * SUM(unavailable) / SUM(total_orders) FROM status_monthly WHERE show_in_trend) AS unav_w,
      (SELECT 100.0 * SUM(late_orders) / SUM(delivered_pop) FROM delivery_monthly WHERE show_in_trend) AS late_w,
      (SELECT AVG(review_score) FROM fact_orders WHERE in_analysis_window) AS score_w
)
SELECT k.kpi, k.definition, k.population, k.denominator,
       ROUND(k.value, 4) AS value_all_period,
       ROUND(CASE k.kpi
            WHEN 'Item Revenue'       THEN w.rev_w
            WHEN 'Freight Revenue'    THEN w.fr_w
            WHEN 'GMV incl. Freight'  THEN w.gmv_w
            WHEN 'Total Orders'       THEN w.ord_w
            WHEN 'Revenue Orders'     THEN w.rord_w
            WHEN 'AOV'                THEN w.rev_w / w.rord_w
            WHEN 'AOV incl. Freight'  THEN w.gmv_w / w.rord_w
            WHEN 'Cancellation Rate'  THEN w.canc_w
            WHEN 'Unavailable Rate'   THEN w.unav_w
            WHEN 'Late Rate'          THEN w.late_w
            WHEN 'On-Time Rate'       THEN 100.0 - w.late_w
            WHEN 'Avg Review Score'   THEN w.score_w
            END, 4) AS value_analysis_window,
       k.unit,
       'Seluruh data (2016-09 s.d. 2018-10)' AS label_all_period,
       'Analysis Window (2017-01 s.d. 2018-08)' AS label_analysis_window,
       'kpi_lock (Tahap 6)' AS sumber
FROM kpi_lock k, w
WHERE k.kpi NOT IN ('Payment Total', 'Single-Seller Population');

-- mart_overview_monthly: 1 baris per bulan (26); tren memakai show_in_trend
CREATE OR REPLACE TABLE mart_overview_monthly AS
SELECT year_month, period_quality, show_in_trend, total_orders, revenue_orders,
       item_revenue, freight_revenue, gmv, aov, aov_incl_freight, freight_pct_of_item,
       mom_item_revenue_pct, mom_revenue_orders_pct, item_revenue_delivered, pct_in_flight_revenue
FROM sales_monthly;

-- mart_overview_yoy: Jan-Agu 2018 vs Jan-Agu 2017 (bulan yang sama; 8 baris)
CREATE OR REPLACE TABLE mart_overview_yoy AS SELECT * FROM sales_yoy;

-- mart_overview_category_top: 10 kategori teratas + "Lainnya"; persentase terhadap Item Revenue Revenue Population
CREATE OR REPLACE TABLE mart_overview_category_top AS
WITH r AS (SELECT kategori, n_orders, item_revenue, ROW_NUMBER() OVER (ORDER BY item_revenue DESC, kategori) AS rk FROM category_summary),
     t AS (SELECT SUM(item_revenue) AS tot FROM category_summary)
SELECT CAST(r.rk AS INTEGER) AS peringkat, r.kategori, CAST(r.n_orders AS BIGINT) AS n_orders, r.item_revenue,
       ROUND(100.0 * r.item_revenue / t.tot, 2) AS pct_revenue
FROM r, t WHERE r.rk <= 10
UNION ALL
SELECT 11, 'Lainnya (' || CAST(COUNT(*) AS VARCHAR) || ' kategori)', CAST(NULL AS BIGINT), ROUND(SUM(r.item_revenue), 2),
       ROUND(100.0 * SUM(r.item_revenue) / MAX(t.tot), 2)
FROM r, t WHERE r.rk > 10;

-- mart_overview_state: 27 state (tanpa tiering, D12)
CREATE OR REPLACE TABLE mart_overview_state AS
SELECT state, n_orders,
       ROUND(100.0 * n_orders / SUM(n_orders) OVER (), 2) AS pct_orders,
       n_revenue_orders, item_revenue,
       ROUND(100.0 * item_revenue / SUM(item_revenue) OVER (), 2) AS pct_revenue,
       aov,
       (n_orders < 0.01 * SUM(n_orders) OVER ()) AS low_n_flag
FROM regional_state;

-- ============================================================
-- MART 2: mart_fulfillment_delivery (Halaman 2)
-- ============================================================
-- mart_fd_status: breakdown status (8 baris)
CREATE OR REPLACE TABLE mart_fd_status AS
SELECT order_status, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3) AS pct_order,
       COUNT(*) FILTER (WHERE has_items)     AS dengan_item,
       COUNT(*) FILTER (WHERE NOT has_items) AS tanpa_item,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2) AS item_revenue
FROM fact_orders GROUP BY order_status;

-- mart_fd_funnel: funnel kumulatif menurut jejak timestamp (4 baris)
CREATE OR REPLACE TABLE mart_fd_funnel AS
SELECT ord, tahap, n_order,
       ROUND(100.0 * n_order / FIRST_VALUE(n_order) OVER (ORDER BY ord), 3) AS pct_dari_purchase,
       ROUND(100.0 * n_order / LAG(n_order) OVER (ORDER BY ord), 3)          AS pct_dari_tahap_sebelumnya
FROM (SELECT 1 AS ord, '1 purchase' AS tahap, COUNT(*) AS n_order FROM fact_orders
      UNION ALL SELECT 2, '2 approved', COUNT(*) FILTER (WHERE ts_approved IS NOT NULL) FROM fact_orders
      UNION ALL SELECT 3, '3 diserahkan ke carrier', COUNT(*) FILTER (WHERE ts_carrier IS NOT NULL) FROM fact_orders
      UNION ALL SELECT 4, '4 diterima pelanggan', COUNT(*) FILTER (WHERE ts_customer IS NOT NULL) FROM fact_orders);

-- mart_fd_cancel_trace: jejak terakhir order canceled (Cancelled Population; 4 baris)
CREATE OR REPLACE TABLE mart_fd_cancel_trace AS
SELECT CASE WHEN ts_customer IS NOT NULL THEN '4 tanggal terima tercatat (anomali)'
            WHEN ts_carrier  IS NOT NULL THEN '3 sudah diserahkan ke carrier'
            WHEN ts_approved IS NOT NULL THEN '2 disetujui, belum ke carrier'
            ELSE '1 dibatalkan sebelum approval' END AS jejak_terakhir,
       COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       COUNT(*) FILTER (WHERE has_items) AS dengan_item
FROM fact_orders WHERE is_canceled GROUP BY 1;

-- mart_fd_monthly: status + delivery per bulan (26 baris)
CREATE OR REPLACE TABLE mart_fd_monthly AS
SELECT s.year_month, s.period_quality, s.show_in_trend,
       s.total_orders, s.canceled, s.unavailable, s.cancellation_rate_pct, s.unavailable_rate_pct,
       s.in_flight, s.pct_in_flight,
       d.delivered_pop, d.late_orders, d.late_rate_pct, d.on_time_rate_pct,
       d.delivery_days_p50, d.delivery_days_p75, d.delivery_days_p95, d.delivery_days_mean,
       d.share_delivered_le10d_pct, d.share_delivered_le20d_pct, d.share_delivered_le30d_pct,
       d.estimasi_lead_p50
FROM status_monthly s JOIN delivery_monthly d USING (year_month);

-- mart_fd_stage: durasi antar tahap, Delivered Population (4 baris); pengecualian per tahap dilaporkan
CREATE OR REPLACE TABLE mart_fd_stage AS
WITH st AS (
    SELECT CASE WHEN ts_approved IS NOT NULL THEN date_diff('second', ts_purchase, ts_approved) / 86400.0 END AS d_approve,
           CASE WHEN ts_approved IS NOT NULL AND ts_carrier IS NOT NULL AND NOT flag_carrier_before_approved
                THEN date_diff('second', ts_approved, ts_carrier) / 86400.0 END AS d_handover,
           CASE WHEN ts_carrier IS NOT NULL AND NOT flag_customer_before_carrier
                THEN date_diff('second', ts_carrier, ts_customer) / 86400.0 END AS d_transit,
           delivery_days AS d_total
    FROM fact_orders WHERE is_delivered_complete)
SELECT '1 purchase -> approved' AS tahap, COUNT(d_approve) AS n_used, COUNT(*) - COUNT(d_approve) AS n_dikecualikan,
       ROUND(quantile_cont(d_approve, 0.5), 2) AS p50, ROUND(quantile_cont(d_approve, 0.9), 2) AS p90,
       ROUND(quantile_cont(d_approve, 0.95), 2) AS p95, ROUND(quantile_cont(d_approve, 0.99), 2) AS p99, ROUND(AVG(d_approve), 2) AS mean_hari
FROM st
UNION ALL SELECT '2 approved -> carrier (handover seller)', COUNT(d_handover), COUNT(*) - COUNT(d_handover),
       ROUND(quantile_cont(d_handover, 0.5), 2), ROUND(quantile_cont(d_handover, 0.9), 2), ROUND(quantile_cont(d_handover, 0.95), 2),
       ROUND(quantile_cont(d_handover, 0.99), 2), ROUND(AVG(d_handover), 2) FROM st
UNION ALL SELECT '3 carrier -> delivered (transit)', COUNT(d_transit), COUNT(*) - COUNT(d_transit),
       ROUND(quantile_cont(d_transit, 0.5), 2), ROUND(quantile_cont(d_transit, 0.9), 2), ROUND(quantile_cont(d_transit, 0.95), 2),
       ROUND(quantile_cont(d_transit, 0.99), 2), ROUND(AVG(d_transit), 2) FROM st
UNION ALL SELECT '4 purchase -> delivered (total)', COUNT(d_total), COUNT(*) - COUNT(d_total),
       ROUND(quantile_cont(d_total, 0.5), 2), ROUND(quantile_cont(d_total, 0.9), 2), ROUND(quantile_cont(d_total, 0.95), 2),
       ROUND(quantile_cont(d_total, 0.99), 2), ROUND(AVG(d_total), 2) FROM st;

-- mart_fd_estimate_gap: selisih tanggal terima vs estimasi (8 bucket; Delivered Population; positif = telat)
CREATE OR REPLACE TABLE mart_fd_estimate_gap AS
SELECT CASE WHEN dd <= -14 THEN '1: >= 14 hari lebih cepat' WHEN dd <= -8 THEN '2: 8-13 hari lebih cepat'
            WHEN dd <= -1 THEN '3: 1-7 hari lebih cepat' WHEN dd = 0 THEN '4: tepat hari estimasi'
            WHEN dd <= 3 THEN '5: telat 1-3 hari' WHEN dd <= 7 THEN '6: telat 4-7 hari'
            WHEN dd <= 14 THEN '7: telat 8-14 hari' ELSE '8: telat > 14 hari' END AS selisih_vs_estimasi,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT date_diff('day', CAST(ts_estimated AS DATE), CAST(ts_customer AS DATE)) AS dd
      FROM fact_orders WHERE is_delivered_complete)
GROUP BY 1;

-- mart_fd_state: kinerja pengiriman per state (27 baris; tanpa tiering) + standardisasi jarak
CREATE OR REPLACE TABLE mart_fd_state AS
SELECT r.state, r.n_orders, r.n_delivered, r.delivery_days_p50, r.delivery_days_mean, r.delivery_days_p95,
       r.late_rate_pct, ROUND(100.0 - r.late_rate_pct, 3) AS on_time_rate_pct,
       r.avg_freight_per_order,
       g.n_orders_ber_jarak, g.avg_jarak_km, g.rasio_delivery_obs_vs_eks, g.late_rate_ekspektasi, g.late_rate_selisih_poin,
       (r.n_orders < 0.01 * SUM(r.n_orders) OVER ()) AS low_n_flag
FROM regional_state r LEFT JOIN regional_relative g ON g.state = r.state;

-- mart_fd_intra_inter: intra vs antar-state (Single-Seller Population, terkirim; 2 baris)
CREATE OR REPLACE TABLE mart_fd_intra_inter AS
SELECT (f.customer_state = d.seller_state) AS same_state, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_order,
       ROUND(quantile_cont(f.delivery_days, 0.5), 2)  AS delivery_p50,
       ROUND(AVG(f.delivery_days), 2)                 AS delivery_mean,
       ROUND(quantile_cont(f.delivery_days, 0.95), 2) AS delivery_p95,
       ROUND(AVG(CAST(f.freight_total AS DOUBLE)), 2) AS avg_freight_per_order,
       ROUND(AVG(CAST(f.item_revenue AS DOUBLE)), 2)  AS avg_item_revenue,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_late) / COUNT(*), 3) AS late_rate_pct
FROM fact_orders f JOIN dim_seller d ON d.seller_id = f.single_seller_id
WHERE f.is_single_seller_pop AND f.is_delivered_complete GROUP BY 1;

-- mart_fd_distance_band: delivery menurut band jarak seller-customer (Single-Seller, terkirim, koordinat valid; 6 baris)
CREATE OR REPLACE TABLE mart_fd_distance_band AS
WITH o AS (
    SELECT f.order_id, f.delivery_days, f.is_late, f.freight_total,
           2 * 6371.0 * asin(sqrt(pow(sin(radians(gc.lat - gs.lat) / 2), 2)
               + cos(radians(gs.lat)) * cos(radians(gc.lat)) * pow(sin(radians(gc.lng - gs.lng) / 2), 2))) AS km
    FROM fact_orders f
    JOIN dim_seller s ON s.seller_id = f.single_seller_id
    JOIN dim_geo_zip gs ON gs.zip = s.seller_zip_prefix
    JOIN dim_geo_zip gc ON gc.zip = f.customer_zip_prefix
    WHERE f.is_single_seller_pop AND f.is_delivered_complete AND gs.lat IS NOT NULL AND gc.lat IS NOT NULL)
SELECT CASE WHEN km < 100 THEN '1: < 100 km' WHEN km < 300 THEN '2: 100-299 km' WHEN km < 600 THEN '3: 300-599 km'
            WHEN km < 1000 THEN '4: 600-999 km' WHEN km < 2000 THEN '5: 1000-1999 km' ELSE '6: >= 2000 km' END AS band_jarak,
       COUNT(*) AS n_order,
       ROUND(quantile_cont(delivery_days, 0.5), 2)  AS delivery_p50,
       ROUND(quantile_cont(delivery_days, 0.95), 2) AS delivery_p95,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) AS late_rate_pct,
       ROUND(AVG(CAST(freight_total AS DOUBLE)), 2) AS avg_freight_per_order
FROM o GROUP BY 1;

-- ============================================================
-- MART 3: mart_customer_satisfaction (Halaman 3)
-- ============================================================
-- mart_cs_distribution: distribusi skor + rasio komentar (5 baris; Review Population)
CREATE OR REPLACE TABLE mart_cs_distribution AS
SELECT review_score, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       COUNT(*) FILTER (WHERE has_comment) AS n_ber_komentar,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) AS pct_ber_komentar
FROM fact_reviews GROUP BY review_score;

-- mart_cs_monthly: skor per bulan (26 baris)
CREATE OR REPLACE TABLE mart_cs_monthly AS
SELECT year_month, period_quality, show_in_trend, total_orders, n_reviews, pct_ber_review, avg_score,
       pct_skor_5, pct_skor_1_2, n_late_ber_review, avg_score_order_on_time
FROM sat_monthly;

-- mart_cs_d4_layers: late vs on-time DUA LAPIS (D4); Delivered Population ∩ Review Population (n = 95.824)
CREATE OR REPLACE TABLE mart_cs_d4_layers AS
SELECT 'lapis 1: semua order' AS lapis, is_late, CAST(NULL AS BOOLEAN) AS answered_before_delivery,
       COUNT(*) AS n_order, ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2
FROM fact_reviews WHERE is_delivered_complete GROUP BY is_late
UNION ALL
SELECT 'lapis 2: menurut timing jawaban', is_late, answered_before_delivery,
       COUNT(*), ROUND(AVG(review_score), 3),
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2)
FROM fact_reviews WHERE is_delivered_complete GROUP BY is_late, answered_before_delivery;

-- mart_cs_d4_bucket: bucket keterlambatan x timing jawaban (4 baris)
CREATE OR REPLACE TABLE mart_cs_d4_bucket AS
SELECT CASE WHEN hari_telat <= 0 THEN '0: on-time/early' WHEN hari_telat <= 3 THEN '1: telat 1-3 hari'
            WHEN hari_telat <= 7 THEN '2: telat 4-7 hari' ELSE '3: telat > 7 hari' END AS bucket,
       COUNT(*) AS n_semua, ROUND(AVG(review_score), 3) AS avg_semua,
       COUNT(*) FILTER (WHERE NOT answered_before_delivery) AS n_sesudah,
       ROUND(AVG(review_score) FILTER (WHERE NOT answered_before_delivery), 3) AS avg_sesudah,
       COUNT(*) FILTER (WHERE answered_before_delivery) AS n_sebelum,
       ROUND(AVG(review_score) FILTER (WHERE answered_before_delivery), 3) AS avg_sebelum
FROM (SELECT r.review_score, r.answered_before_delivery,
             date_diff('day', CAST(o.ts_estimated AS DATE), CAST(o.ts_customer AS DATE)) AS hari_telat
      FROM fact_reviews r JOIN fact_orders o ON o.order_id = r.order_id WHERE r.is_delivered_complete)
GROUP BY 1;

-- mart_cs_category: "Associated Review Score" per kategori (Revenue ∩ Review; hanya >= 100 order, D6)
CREATE OR REPLACE TABLE mart_cs_category AS
WITH pr AS (
    SELECT DISTINCT i.order_id, p.category_en_clean AS kategori
    FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id
), nc AS (SELECT order_id, COUNT(*) AS n_kategori FROM pr GROUP BY order_id)
SELECT pr.kategori, COUNT(*) AS n_order,
       ROUND(AVG(r.review_score), 3) AS associated_avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2,
       COUNT(*) FILTER (WHERE nc.n_kategori = 1) AS n_order_satu_kategori,
       ROUND(AVG(r.review_score) FILTER (WHERE nc.n_kategori = 1), 3) AS avg_satu_kategori,
       ROUND(AVG(r.review_score) FILTER (WHERE r.is_delivered_complete AND NOT r.is_late), 3) AS avg_order_on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.is_delivered_complete AND r.is_late)
             / NULLIF(COUNT(*) FILTER (WHERE r.is_delivered_complete), 0), 3) AS late_rate_pct,
       'Associated Review Score (order-level; order multi-kategori dihitung di tiap kategori)' AS catatan
FROM pr JOIN nc ON nc.order_id = pr.order_id
JOIN fact_reviews r ON r.order_id = pr.order_id
JOIN fact_orders o ON o.order_id = pr.order_id
WHERE o.is_revenue_order GROUP BY pr.kategori HAVING COUNT(*) >= 100;

-- mart_cs_state: skor per state (27 baris; tanpa tiering)
CREATE OR REPLACE TABLE mart_cs_state AS
SELECT s.state, s.n_reviews, s.avg_review_score, s.pct_skor_1_2, s.late_rate_pct,
       ROUND(AVG(f.review_score) FILTER (WHERE f.is_delivered_complete AND NOT f.is_late), 3) AS avg_score_order_on_time,
       (s.n_orders < 0.01 * SUM(s.n_orders) OVER ()) AS low_n_flag
FROM regional_state s JOIN fact_orders f ON f.customer_state = s.state
GROUP BY s.state, s.n_reviews, s.avg_review_score, s.pct_skor_1_2, s.late_rate_pct, s.n_orders;

-- mart_cs_survey_timing: tanggal survei dikirim (review_creation) relatif terhadap tanggal barang sampai (Delivered ∩ Review)
CREATE OR REPLACE TABLE mart_cs_survey_timing AS
SELECT CASE WHEN dd < 0 THEN '1: sebelum tanggal sampai' WHEN dd = 0 THEN '2: hari sampai'
            WHEN dd = 1 THEN '3: +1 hari' WHEN dd = 2 THEN '4: +2 hari'
            WHEN dd <= 7 THEN '5: +3..7 hari' ELSE '6: > 7 hari' END AS survei_vs_tanggal_sampai,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT date_diff('day', CAST(o.ts_customer AS DATE), CAST(r.review_creation_ts AS DATE)) AS dd
      FROM fact_reviews r JOIN fact_orders o ON o.order_id = r.order_id WHERE r.is_delivered_complete)
GROUP BY 1;

-- ============================================================
-- MART 4: mart_product_payment (Halaman 4)
-- ============================================================
-- mart_pp_category: 74 kategori (termasuk 'unknown'); metrik per kategori; filter min volume lewat memenuhi_min_volume
CREATE OR REPLACE TABLE mart_pp_category AS
SELECT kategori, n_orders, n_units, n_products_sold, item_revenue,
       ROUND(100.0 * item_revenue / SUM(item_revenue) OVER (), 3) AS pct_revenue,
       freight_revenue, avg_price, price_p25, price_p50, price_p75, price_p95,
       freight_pct_of_item, weight_g_p50, avg_freight_per_item,
       (n_orders >= 100) AS memenuhi_min_volume,
       RANK() OVER (ORDER BY item_revenue DESC) AS rank_revenue,
       RANK() OVER (ORDER BY n_orders DESC)     AS rank_orders,
       (kategori = 'unknown') AS is_unknown
FROM category_summary;

-- mart_pp_category_quadrant: kuadran harga x volume (kategori >= 100 order)
CREATE OR REPLACE TABLE mart_pp_category_quadrant AS
WITH th AS (
    SELECT (SELECT quantile_cont(CAST(price AS DOUBLE), 0.5) FROM fact_order_items WHERE is_revenue_order) AS price_th,
           (SELECT quantile_cont(n_orders, 0.5) FROM category_summary WHERE n_orders >= 100) AS volume_th)
SELECT c.kategori, c.n_orders, c.price_p50, c.item_revenue,
       ROUND(100.0 * c.item_revenue / (SELECT SUM(item_revenue) FROM category_summary), 3) AS pct_revenue,
       CASE WHEN c.price_p50 > th.price_th AND c.n_orders >  th.volume_th THEN '1 harga tinggi & volume tinggi'
            WHEN c.price_p50 > th.price_th AND c.n_orders <= th.volume_th THEN '2 harga tinggi & volume rendah'
            WHEN c.price_p50 <= th.price_th AND c.n_orders >  th.volume_th THEN '3 harga rendah & volume tinggi'
            ELSE '4 harga rendah & volume rendah' END AS kuadran,
       ROUND(th.price_th, 2) AS ambang_median_harga, ROUND(th.volume_th, 0) AS ambang_median_order
FROM category_summary c, th WHERE c.n_orders >= 100;

-- mart_pp_price_band: pita harga item (Revenue Population; 7 baris)
CREATE OR REPLACE TABLE mart_pp_price_band AS
SELECT CASE WHEN price < 25 THEN '1: < 25' WHEN price < 50 THEN '2: 25-49' WHEN price < 100 THEN '3: 50-99'
            WHEN price < 200 THEN '4: 100-199' WHEN price < 500 THEN '5: 200-499' WHEN price < 1000 THEN '6: 500-999'
            ELSE '7: >= 1000' END AS price_band,
       COUNT(*) AS n_item,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_item,
       ROUND(CAST(SUM(price) AS DOUBLE), 2) AS item_revenue,
       ROUND(100.0 * CAST(SUM(price) AS DOUBLE) / SUM(CAST(SUM(price) AS DOUBLE)) OVER (), 2) AS pct_item_revenue,
       ROUND(100.0 * CAST(SUM(freight_value) AS DOUBLE) / CAST(SUM(price) AS DOUBLE), 2) AS freight_pct_of_item
FROM fact_order_items WHERE is_revenue_order GROUP BY 1;

-- mart_pp_basket_summary (negative finding): order multi-produk dan lintas kategori (2 basis)
CREATE OR REPLACE TABLE mart_pp_basket_summary AS
WITH oc AS (
    SELECT i.order_id, MAX(CASE WHEN i.is_revenue_order THEN 1 ELSE 0 END) AS is_rp,
           COUNT(DISTINCT i.product_id) AS n_products, COUNT(DISTINCT p.category_en_clean) AS n_kategori
    FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id GROUP BY i.order_id)
SELECT 'Item Population' AS basis, COUNT(*) FILTER (WHERE n_products > 1) AS n_order_multi_produk,
       COUNT(*) FILTER (WHERE n_products > 1 AND n_kategori >= 2) AS n_lintas_kategori,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_products > 1 AND n_kategori >= 2) / NULLIF(COUNT(*) FILTER (WHERE n_products > 1), 0), 2) AS pct_lintas_kategori,
       COUNT(*) AS n_order_ber_item,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_products > 1 AND n_kategori >= 2) / COUNT(*), 3) AS pct_lintas_dari_order_ber_item
FROM oc
UNION ALL
SELECT 'Revenue Population', COUNT(*) FILTER (WHERE n_products > 1), COUNT(*) FILTER (WHERE n_products > 1 AND n_kategori >= 2),
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_products > 1 AND n_kategori >= 2) / NULLIF(COUNT(*) FILTER (WHERE n_products > 1), 0), 2),
       COUNT(*), ROUND(100.0 * COUNT(*) FILTER (WHERE n_products > 1 AND n_kategori >= 2) / COUNT(*), 3)
FROM oc WHERE is_rp = 1;

-- mart_pp_basket_pairs: 10 pasangan kategori terbesar (Item Population)
CREATE OR REPLACE TABLE mart_pp_basket_pairs AS
WITH oc AS (SELECT DISTINCT i.order_id, p.category_en_clean AS kategori
            FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id)
SELECT a.kategori AS kategori_a, b.kategori AS kategori_b, COUNT(*) AS n_order
FROM oc a JOIN oc b ON a.order_id = b.order_id AND a.kategori < b.kategori
GROUP BY a.kategori, b.kategori ORDER BY n_order DESC, kategori_a, kategori_b LIMIT 10;

-- mart_pp_payment_type: per tipe pembayaran (5 baris). payment_value = BUKAN revenue.
CREATE OR REPLACE TABLE mart_pp_payment_type AS
SELECT payment_type, COUNT(*) AS n_payment,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_payment,
       ROUND(CAST(SUM(payment_value) AS DOUBLE), 2) AS total_value,
       ROUND(100.0 * CAST(SUM(payment_value) AS DOUBLE) / SUM(CAST(SUM(payment_value) AS DOUBLE)) OVER (), 2) AS pct_value,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_value,
       COUNT(DISTINCT order_id) AS n_order_memuat_tipe,
       'payment_value bukan revenue' AS catatan
FROM fact_payments GROUP BY payment_type;

-- mart_pp_payment_mix: kombinasi tipe per order (Payment Population; 7 baris)
CREATE OR REPLACE TABLE mart_pp_payment_mix AS
WITH m AS (SELECT order_id, array_to_string(list_sort(list_distinct(list(payment_type))), ' + ') AS payment_mix,
                  SUM(payment_value) AS payment_total
           FROM fact_payments GROUP BY order_id)
SELECT m.payment_mix, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3) AS pct_order,
       ROUND(CAST(SUM(m.payment_total) AS DOUBLE), 2) AS total_value,
       ROUND(CAST(AVG(m.payment_total) AS DOUBLE), 2) AS avg_order_payment,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_canceled) / COUNT(*), 3) AS cancellation_rate_pct,
       ROUND(AVG(f.review_score), 3) AS avg_review_score
FROM m JOIN fact_orders f ON f.order_id = m.order_id GROUP BY m.payment_mix;

-- mart_pp_installments: cicilan kartu kredit (installments = 0 di-exclude)
CREATE OR REPLACE TABLE mart_pp_installments AS
SELECT payment_installments AS cicilan, COUNT(*) AS n_payment,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_payment_value,
       ROUND(AVG(CAST(payment_value AS DOUBLE) / payment_installments), 2) AS avg_nilai_per_cicilan
FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments
GROUP BY payment_installments;

-- mart_pp_installments_by_value: cicilan menurut nilai order (order credit_card-saja)
CREATE OR REPLACE TABLE mart_pp_installments_by_value AS
WITH m AS (SELECT order_id, SUM(payment_value) AS payment_total,
                  MAX(payment_installments) FILTER (WHERE payment_type = 'credit_card' AND NOT flag_zero_installments) AS max_inst,
                  array_to_string(list_sort(list_distinct(list(payment_type))), ' + ') AS mix
           FROM fact_payments GROUP BY order_id)
SELECT CASE WHEN payment_total < 50 THEN '1: < 50' WHEN payment_total < 100 THEN '2: 50-99' WHEN payment_total < 200 THEN '3: 100-199'
            WHEN payment_total < 500 THEN '4: 200-499' ELSE '5: >= 500' END AS nilai_order,
       COUNT(*) AS n_order, ROUND(AVG(max_inst), 2) AS avg_cicilan,
       ROUND(100.0 * COUNT(*) FILTER (WHERE max_inst > 1) / COUNT(*), 2) AS pct_cicilan_gt1,
       ROUND(100.0 * COUNT(*) FILTER (WHERE max_inst >= 7) / COUNT(*), 2) AS pct_cicilan_ge7
FROM m WHERE mix = 'credit_card' AND max_inst IS NOT NULL GROUP BY 1;

-- mart_pp_payment_monthly: bauran pembayaran per bulan (26 baris)
CREATE OR REPLACE TABLE mart_pp_payment_monthly AS SELECT * FROM payment_monthly;

-- ============================================================
-- MART 5: mart_seller_regional (Halaman 5: Seller, Regional & Repeat)
-- ============================================================
-- mart_sr_seller: 3.095 seller; metrik rate/skor hanya terisi bila seller memenuhi minimum volume (D6)
CREATE OR REPLACE TABLE mart_sr_seller AS
SELECT seller_id, seller_state, tier, n_orders_rp, item_revenue_rp, rank_revenue_rp,
       n_single_orders, n_single_delivered, n_single_reviewed,
       CASE WHEN eligible_rate   THEN late_rate_pct END      AS late_rate_pct,
       CASE WHEN eligible_review THEN avg_review_score END   AS avg_review_score,
       CASE WHEN eligible_rate   THEN handover_p50_days END  AS handover_p50_days,
       CASE WHEN eligible_rate   THEN pct_cross_state END    AS pct_cross_state,
       eligible_rate, eligible_review
FROM seller_summary;

-- mart_sr_seller_tier: 3 tier (D11), basis Revenue Population + metrik dipool (seller eligible)
CREATE OR REPLACE TABLE mart_sr_seller_tier AS
SELECT tier, COUNT(*) AS n_seller, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_seller,
       SUM(n_orders_rp) AS n_order_rp, ROUND(SUM(item_revenue_rp), 2) AS item_revenue,
       ROUND(100.0 * SUM(item_revenue_rp) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue,
       ROUND(100.0 * SUM(late_rate_pct / 100.0 * n_single_delivered) FILTER (WHERE eligible_rate)
             / NULLIF(SUM(n_single_delivered) FILTER (WHERE eligible_rate), 0), 3) AS late_rate_pct_pooled,
       ROUND(SUM(avg_review_score * n_single_reviewed) FILTER (WHERE eligible_review)
             / NULLIF(SUM(n_single_reviewed) FILTER (WHERE eligible_review), 0), 3) AS avg_score_pooled
FROM seller_summary GROUP BY tier;

-- mart_sr_pareto: top k% seller (Revenue Population)
CREATE OR REPLACE TABLE mart_sr_pareto AS
WITH n AS (SELECT COUNT(*) AS n_seller, SUM(item_revenue_rp) AS tot FROM seller_summary), p(pct) AS (VALUES (1), (5), (10), (20), (50))
SELECT p.pct AS top_pct_seller, CAST(CEIL(p.pct / 100.0 * n.n_seller) AS INTEGER) AS n_seller_top,
       ROUND(100.0 * (SELECT SUM(item_revenue_rp) FROM seller_summary WHERE rank_revenue_rp <= CEIL(p.pct / 100.0 * n.n_seller)) / n.tot, 2) AS pct_revenue
FROM p, n;

-- mart_sr_lorenz: desil seller (10 baris)
CREATE OR REPLACE TABLE mart_sr_lorenz AS
SELECT desil, COUNT(*) AS n_seller, ROUND(SUM(item_revenue_rp), 2) AS item_revenue,
       ROUND(100.0 * SUM(item_revenue_rp) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue,
       ROUND(100.0 * SUM(SUM(item_revenue_rp)) OVER (ORDER BY desil) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue_kumulatif
FROM (SELECT item_revenue_rp, NTILE(10) OVER (ORDER BY item_revenue_rp DESC, seller_id) AS desil FROM seller_summary)
GROUP BY desil;

-- mart_sr_concentration: Gini dan HHI (1 baris)
CREATE OR REPLACE TABLE mart_sr_concentration AS
SELECT ROUND((2.0 * SUM(rn * x)) / (COUNT(*) * SUM(x)) - (COUNT(*) + 1.0) / COUNT(*), 4) AS gini_revenue,
       (SELECT ROUND(SUM(POW(100.0 * item_revenue_rp / (SELECT SUM(item_revenue_rp) FROM seller_summary), 2)), 2) FROM seller_summary) AS hhi_revenue
FROM (SELECT item_revenue_rp AS x, ROW_NUMBER() OVER (ORDER BY item_revenue_rp, seller_id) AS rn FROM seller_summary);

-- mart_sr_state: 27 state (TANPA tiering, D12): demand, supply, kinerja relatif jarak, dan repeat
CREATE OR REPLACE TABLE mart_sr_state AS
SELECT r.state, r.n_orders,
       ROUND(100.0 * r.n_orders / SUM(r.n_orders) OVER (), 2) AS pct_orders,
       r.item_revenue, ROUND(100.0 * r.item_revenue / SUM(r.item_revenue) OVER (), 2) AS pct_revenue,
       r.aov, r.avg_freight_per_order, r.freight_pct_of_item,
       r.delivery_days_p50, r.late_rate_pct, r.avg_review_score, r.n_reviews,
       b.n_seller, b.pct_seller, b.pct_customer, b.pct_revenue_sisi_customer, b.pct_revenue_sisi_seller,
       ROUND(b.pct_revenue_sisi_seller - b.pct_revenue_sisi_customer, 2) AS selisih_revenue_seller_vs_customer_poin,
       g.avg_jarak_km, g.rasio_delivery_obs_vs_eks, g.late_rate_ekspektasi, g.late_rate_selisih_poin,
       p.n_pelanggan AS n_pelanggan_order_pertama, p.n_repeat, p.repeat_rate_pct,
       (r.n_orders < 0.01 * SUM(r.n_orders) OVER ()) AS low_n_flag
FROM regional_state r
LEFT JOIN seller_state_balance b ON b.state = r.state
LEFT JOIN regional_relative g ON g.state = r.state
LEFT JOIN repeat_state p ON p.state = r.state;

-- mart_sr_city: kota >= 30 order; memenuhi_min_volume = >= 100 order (D6)
CREATE OR REPLACE TABLE mart_sr_city AS
SELECT state, kota, n_orders, n_revenue_orders, item_revenue, aov, avg_freight_per_order,
       n_delivered, delivery_days_p50, late_rate_pct, n_reviews, avg_review_score, memenuhi_min_volume
FROM regional_city;

-- mart_sr_repeat_monthly dan mart_sr_repeat_cohort (cohort hanya window tetap 30/90/180 hari)
CREATE OR REPLACE TABLE mart_sr_repeat_monthly AS
SELECT year_month, period_quality, show_in_trend, n_orders, n_new, n_returning, n_sesi_sama,
       pct_order_returning, n_pelanggan_aktif, n_pelanggan_returning, pct_pelanggan_returning
FROM repeat_monthly;

CREATE OR REPLACE TABLE mart_sr_repeat_cohort AS
SELECT cohort, period_quality, n_pelanggan, elig_30 AS n_eligible_30d, rep_30 AS n_repeat_30d, repeat_30d_pct,
       elig_90 AS n_eligible_90d, rep_90 AS n_repeat_90d, repeat_90d_pct,
       elig_180 AS n_eligible_180d, rep_180 AS n_repeat_180d, repeat_180d_pct, cohort_kecil
FROM repeat_cohort;

-- mart_sr_repeat_headline: KPI repeat headline (D5); repeat mentah TIDAK di sini (hanya di DQ mart)
CREATE OR REPLACE TABLE mart_sr_repeat_headline AS
SELECT 'Repeat Rate (>= 24 jam)' AS kpi, COUNT(*) FILTER (WHERE is_repeat_customer) AS n_repeat, COUNT(*) AS n_populasi,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) AS nilai_pct, 'Customer Population' AS populasi
FROM dim_customer
UNION ALL
SELECT '90-day Repeat Rate (cohort 2017-01..2018-05)',
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM fact_orders o WHERE o.customer_unique_id = d.customer_unique_id
                                        AND o.ts_purchase >= d.first_order_ts + INTERVAL 24 HOUR
                                        AND o.ts_purchase <= d.first_order_ts + INTERVAL 90 DAY)),
       COUNT(*),
       ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM fact_orders o WHERE o.customer_unique_id = d.customer_unique_id
                                        AND o.ts_purchase >= d.first_order_ts + INTERVAL 24 HOUR
                                        AND o.ts_purchase <= d.first_order_ts + INTERVAL 90 DAY)) / COUNT(*), 3),
       'Cohort order pertama 2017-01..2018-05'
FROM dim_customer d WHERE d.first_order_ts >= TIMESTAMP '2017-01-01' AND d.first_order_ts < TIMESTAMP '2018-06-01';

-- ============================================================
-- MART 6: mart_data_quality_summary (Halaman 6) — hanya metrik kuantitatif
-- ============================================================
CREATE OR REPLACE TABLE mart_data_quality_summary AS
-- 6.1 Row count tabel raw (9 baris)
SELECT 'raw_rowcount' AS dq_section, 'raw_customers' AS dq_metric, CAST(COUNT(*) AS DOUBLE) AS dq_value, 'baris' AS dq_unit, CAST(NULL AS DOUBLE) AS dq_denominator, CAST(NULL AS DOUBLE) AS dq_pct, 'INFO' AS dq_status, 'raw_*' AS dq_source FROM raw_customers
UNION ALL SELECT 'raw_rowcount', 'raw_geolocation', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_geolocation
UNION ALL SELECT 'raw_rowcount', 'raw_order_items', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_order_items
UNION ALL SELECT 'raw_rowcount', 'raw_order_payments', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_order_payments
UNION ALL SELECT 'raw_rowcount', 'raw_order_reviews', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_order_reviews
UNION ALL SELECT 'raw_rowcount', 'raw_orders', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_orders
UNION ALL SELECT 'raw_rowcount', 'raw_products', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_products
UNION ALL SELECT 'raw_rowcount', 'raw_sellers', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_sellers
UNION ALL SELECT 'raw_rowcount', 'raw_category_translation', CAST(COUNT(*) AS DOUBLE), 'baris', NULL, NULL, 'INFO', 'raw_*' FROM raw_category_translation
-- 6.2 % null (kolom dengan null)
UNION ALL SELECT 'null_profile', tabel || '.' || kolom, CAST(n_null AS DOUBLE), 'baris null', CAST(n_rows AS DOUBLE), pct_null, 'INFO', 'prof_null_summary (Tahap 4)'
          FROM prof_null_summary WHERE n_null > 0
-- 6.3 Populasi analitik
UNION ALL SELECT 'populasi', 'Order Population', CAST(COUNT(*) AS DOUBLE), 'order', NULL, NULL, 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Revenue Population', CAST(COUNT(*) FILTER (WHERE is_revenue_order) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE is_revenue_order) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Delivered Population', CAST(COUNT(*) FILTER (WHERE is_delivered_complete) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE is_delivered_complete) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Review Population', CAST(COUNT(*) FILTER (WHERE has_review) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE has_review) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Single-Seller Population', CAST(COUNT(*) FILTER (WHERE is_single_seller_pop) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE is_single_seller_pop) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Payment Population', CAST(COUNT(*) FILTER (WHERE n_payment_types > 0) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE n_payment_types > 0) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Analysis Window (2017-01..2018-08)', CAST(COUNT(*) FILTER (WHERE in_analysis_window) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE in_analysis_window) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'populasi', 'Customer Population (customer_unique_id)', CAST(COUNT(*) AS DOUBLE), 'pelanggan', NULL, NULL, 'INFO', 'dim_customer' FROM dim_customer
-- 6.4 % flagged: anomali timestamp (dilaporkan sebagai count; tidak dihapus)
UNION ALL SELECT 'flag_anomali', 'carrier sebelum purchase', CAST(COUNT(*) FILTER (WHERE flag_carrier_before_purchase) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_carrier_before_purchase) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'flag_anomali', 'carrier sebelum approved', CAST(COUNT(*) FILTER (WHERE flag_carrier_before_approved) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_carrier_before_approved) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'flag_anomali', 'diterima sebelum carrier', CAST(COUNT(*) FILTER (WHERE flag_customer_before_carrier) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_customer_before_carrier) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'flag_anomali', 'delivered tanpa tanggal terima', CAST(COUNT(*) FILTER (WHERE flag_delivered_no_date) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_delivered_no_date) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'flag_anomali', 'canceled dengan tanggal terima', CAST(COUNT(*) FILTER (WHERE flag_canceled_has_delivery_date) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_canceled_has_delivery_date) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'flag_anomali', 'order dengan >= 1 anomali urutan tanggal', CAST(COUNT(*) FILTER (WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
-- 6.5 Ledger cleaning (baris yang keluar / di-flag)
UNION ALL SELECT 'cleaning_ledger', 'duplikat penuh geolocation dibuang', CAST((SELECT COUNT(*) FROM raw_geolocation) - (SELECT COUNT(*) FROM geo_dedup) AS DOUBLE), 'baris', CAST((SELECT COUNT(*) FROM raw_geolocation) AS DOUBLE), ROUND(100.0 * ((SELECT COUNT(*) FROM raw_geolocation) - (SELECT COUNT(*) FROM geo_dedup)) / (SELECT COUNT(*) FROM raw_geolocation), 2), 'INFO', 'geo_dedup (Tahap 5)'
UNION ALL SELECT 'cleaning_ledger', 'review kembar di-dedup (1 review/order)', CAST((SELECT COUNT(*) FROM raw_order_reviews) - (SELECT COUNT(*) FROM fact_reviews) AS DOUBLE), 'baris', CAST((SELECT COUNT(*) FROM raw_order_reviews) AS DOUBLE), ROUND(100.0 * ((SELECT COUNT(*) FROM raw_order_reviews) - (SELECT COUNT(*) FROM fact_reviews)) / (SELECT COUNT(*) FROM raw_order_reviews), 2), 'INFO', 'fact_reviews (Tahap 5)'
UNION ALL SELECT 'cleaning_ledger', 'order tanpa item', CAST(COUNT(*) FILTER (WHERE NOT has_items) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE NOT has_items) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
UNION ALL SELECT 'cleaning_ledger', 'produk kategori unknown', CAST(COUNT(*) FILTER (WHERE flag_category_unknown) AS DOUBLE), 'produk', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_category_unknown) / COUNT(*), 3), 'INFO', 'dim_product' FROM dim_product
UNION ALL SELECT 'cleaning_ledger', 'item freight = 0', CAST(COUNT(*) FILTER (WHERE flag_zero_freight) AS DOUBLE), 'item', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_zero_freight) / COUNT(*), 3), 'INFO', 'fact_order_items' FROM fact_order_items
UNION ALL SELECT 'cleaning_ledger', 'item shipping_limit_date tidak valid (>= 2019)', CAST(COUNT(*) FILTER (WHERE flag_shipping_limit_invalid) AS DOUBLE), 'item', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_shipping_limit_invalid) / COUNT(*), 3), 'INFO', 'fact_order_items' FROM fact_order_items
UNION ALL SELECT 'cleaning_ledger', 'payment_value = 0', CAST(COUNT(*) FILTER (WHERE flag_zero_payment) AS DOUBLE), 'baris', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_zero_payment) / COUNT(*), 4), 'INFO', 'fact_payments' FROM fact_payments
UNION ALL SELECT 'cleaning_ledger', 'payment_type not_defined', CAST(COUNT(*) FILTER (WHERE flag_payment_not_defined) AS DOUBLE), 'baris', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_payment_not_defined) / COUNT(*), 4), 'INFO', 'fact_payments' FROM fact_payments
UNION ALL SELECT 'cleaning_ledger', 'order tanpa payment_sequential = 1', CAST(COUNT(DISTINCT order_id) FILTER (WHERE flag_no_first_payment) AS DOUBLE), 'order', CAST(COUNT(DISTINCT order_id) AS DOUBLE), ROUND(100.0 * COUNT(DISTINCT order_id) FILTER (WHERE flag_no_first_payment) / COUNT(DISTINCT order_id), 3), 'INFO', 'fact_payments' FROM fact_payments
UNION ALL SELECT 'cleaning_ledger', 'review sebelum purchase (setelah dedup)', CAST(COUNT(*) FILTER (WHERE flag_review_before_purchase) AS DOUBLE), 'review', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_review_before_purchase) / COUNT(*), 3), 'INFO', 'fact_reviews' FROM fact_reviews
UNION ALL SELECT 'cleaning_ledger', 'status in-flight (shipped/invoiced/processing/created/approved)', CAST(COUNT(*) FILTER (WHERE order_status IN ('shipped','invoiced','processing','created','approved')) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE order_status IN ('shipped','invoiced','processing','created','approved')) / COUNT(*), 3), 'INFO', 'fact_orders' FROM fact_orders
-- 6.6 Cakupan koordinat
UNION ALL SELECT 'coverage_koordinat', 'baris customer tanpa koordinat', CAST(COUNT(*) FILTER (WHERE z.lat IS NULL) AS DOUBLE), 'baris', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE z.lat IS NULL) / COUNT(*), 3), 'INFO', 'dim_geo_zip' FROM stg_customers c LEFT JOIN dim_geo_zip z ON z.zip = c.zip_prefix
UNION ALL SELECT 'coverage_koordinat', 'baris seller tanpa koordinat', CAST(COUNT(*) FILTER (WHERE z.lat IS NULL) AS DOUBLE), 'baris', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE z.lat IS NULL) / COUNT(*), 3), 'INFO', 'dim_geo_zip' FROM stg_sellers s LEFT JOIN dim_geo_zip z ON z.zip = s.zip_prefix
UNION ALL SELECT 'coverage_koordinat', 'zip placeholder di dim_geo_zip', CAST(COUNT(*) FILTER (WHERE is_placeholder) AS DOUBLE), 'zip', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE is_placeholder) / COUNT(*), 3), 'INFO', 'dim_geo_zip' FROM dim_geo_zip
UNION ALL SELECT 'coverage_koordinat', 'item order terkirim ber-jarak (status delivered)',
       CAST(COUNT(*) FILTER (WHERE gs.lat IS NOT NULL AND gc.lat IS NOT NULL) AS DOUBLE), 'item', CAST(COUNT(*) AS DOUBLE),
       ROUND(100.0 * COUNT(*) FILTER (WHERE gs.lat IS NOT NULL AND gc.lat IS NOT NULL) / COUNT(*), 2), 'INFO', 'fact_order_items'
  FROM fact_order_items i JOIN fact_orders o ON o.order_id = i.order_id
  JOIN dim_seller s ON s.seller_id = i.seller_id
  LEFT JOIN dim_geo_zip gs ON gs.zip = s.seller_zip_prefix LEFT JOIN dim_geo_zip gc ON gc.zip = o.customer_zip_prefix
  WHERE o.order_status = 'delivered'
-- 6.7 Rekonsiliasi payment vs item+freight (data-quality view; Reconcilable Population)
UNION ALL SELECT 'rekonsiliasi_payment', 'Reconcilable Population', CAST(COUNT(*) AS DOUBLE), 'order', NULL, NULL, 'INFO', 'fact_order_items + fact_payments'
  FROM (SELECT i.order_id FROM (SELECT order_id FROM fact_order_items GROUP BY order_id) i JOIN (SELECT order_id FROM fact_payments GROUP BY order_id) p ON p.order_id = i.order_id)
UNION ALL SELECT 'rekonsiliasi_payment', 'selisih <= 0,01', CAST(COUNT(*) FILTER (WHERE d <= 0.01) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE d <= 0.01) / COUNT(*), 3), 'INFO', 'fact_order_items + fact_payments'
  FROM (SELECT ABS(i.t - p.t) AS d FROM (SELECT order_id, SUM(price + freight_value) AS t FROM fact_order_items GROUP BY order_id) i JOIN (SELECT order_id, SUM(payment_value) AS t FROM fact_payments GROUP BY order_id) p ON p.order_id = i.order_id)
UNION ALL SELECT 'rekonsiliasi_payment', 'selisih 0,01 - 1', CAST(COUNT(*) FILTER (WHERE d > 0.01 AND d <= 1) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE d > 0.01 AND d <= 1) / COUNT(*), 3), 'INFO', 'fact_order_items + fact_payments'
  FROM (SELECT ABS(i.t - p.t) AS d FROM (SELECT order_id, SUM(price + freight_value) AS t FROM fact_order_items GROUP BY order_id) i JOIN (SELECT order_id, SUM(payment_value) AS t FROM fact_payments GROUP BY order_id) p ON p.order_id = i.order_id)
UNION ALL SELECT 'rekonsiliasi_payment', 'selisih > 1 (limitation D9)', CAST(COUNT(*) FILTER (WHERE d > 1) AS DOUBLE), 'order', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE d > 1) / COUNT(*), 3), 'INFO', 'fact_order_items + fact_payments'
  FROM (SELECT ABS(i.t - p.t) AS d FROM (SELECT order_id, SUM(price + freight_value) AS t FROM fact_order_items GROUP BY order_id) i JOIN (SELECT order_id, SUM(payment_value) AS t FROM fact_payments GROUP BY order_id) p ON p.order_id = i.order_id)
UNION ALL SELECT 'rekonsiliasi_payment', 'Payment Total (R$; bukan revenue)', CAST(SUM(payment_value) AS DOUBLE), 'R$', NULL, NULL, 'INFO', 'fact_payments' FROM fact_payments
UNION ALL SELECT 'rekonsiliasi_payment', 'GMV incl. Freight Revenue Population (R$)', CAST(SUM(item_revenue + freight_total) AS DOUBLE), 'R$', NULL, NULL, 'INFO', 'fact_orders' FROM fact_orders WHERE is_revenue_order
-- 6.8 Repeat: repeat mentah hanya di sini (headline di mart_sr_repeat_headline)
UNION ALL SELECT 'repeat_dq', 'repeat mentah (>= 2 order)', CAST(COUNT(*) FILTER (WHERE is_repeat_raw) AS DOUBLE), 'pelanggan', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw) / COUNT(*), 3), 'INFO', 'dim_customer' FROM dim_customer
UNION ALL SELECT 'repeat_dq', 'pelanggan hanya order < 24 jam (sesi sama)', CAST(COUNT(*) FILTER (WHERE is_repeat_raw AND NOT is_repeat_customer) AS DOUBLE), 'pelanggan', CAST(COUNT(*) FILTER (WHERE is_repeat_raw) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw AND NOT is_repeat_customer) / COUNT(*) FILTER (WHERE is_repeat_raw), 2), 'INFO', 'dim_customer' FROM dim_customer
UNION ALL SELECT 'repeat_dq', 'pelanggan multi-state', CAST(COUNT(*) FILTER (WHERE flag_multi_state) AS DOUBLE), 'pelanggan', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE flag_multi_state) / COUNT(*), 3), 'INFO', 'dim_customer' FROM dim_customer
-- 6.9 Period quality
UNION ALL SELECT 'period_quality', 'bulan ' || period_quality, CAST(COUNT(DISTINCT year_month) AS DOUBLE), 'bulan', NULL, NULL, 'INFO', 'dim_date' FROM dim_date GROUP BY period_quality
-- 6.10 Hasil validasi/gate tiap tahap
UNION ALL SELECT 'gate_validasi', 'Tahap 6: rule HARD (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'rule', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status <> 'PASS') = 0 THEN 'PASS' ELSE 'FAIL' END, 'validation_results' FROM validation_results WHERE severity = 'HARD'
UNION ALL SELECT 'gate_validasi', 'Tahap 6: rule KPI (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'rule', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status <> 'PASS') = 0 THEN 'PASS' ELSE 'CHECK' END, 'validation_results' FROM validation_results WHERE severity = 'KPI'
UNION ALL SELECT 'gate_validasi', 'Tahap 8: rule HARD model (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'rule', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status <> 'PASS') = 0 THEN 'PASS' ELSE 'FAIL' END, 'model_validation' FROM model_validation WHERE severity = 'HARD'
UNION ALL SELECT 'gate_validasi', 'Tahap 8: rule KPI model (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'rule', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status <> 'PASS') = 0 THEN 'PASS' ELSE 'CHECK' END, 'model_validation' FROM model_validation WHERE severity = 'KPI'
UNION ALL SELECT 'gate_validasi', 'Tahap 5: cleaning (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'clean_findings' FROM clean_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 9 Sales & Revenue (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'sales_findings' FROM sales_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 10 Status & Fulfillment (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'status_findings' FROM status_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 11 Delivery & Logistics (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'delivery_findings' FROM delivery_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 12 Customer Satisfaction (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'sat_findings' FROM sat_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 13 Payment Behavior (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'payment_findings' FROM payment_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 14 Product Category & Pricing (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'category_findings' FROM category_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 15 Seller Performance (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'seller_findings' FROM seller_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 16 Regional Performance (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'regional_findings' FROM regional_findings
UNION ALL SELECT 'gate_analisis', 'Tahap 17 Customer Repeat (PASS)', CAST(COUNT(*) FILTER (WHERE status = 'PASS') AS DOUBLE), 'metrik', CAST(COUNT(*) AS DOUBLE), ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'PASS') / COUNT(*), 2), CASE WHEN COUNT(*) FILTER (WHERE status = 'CHECK') = 0 THEN 'PASS' ELSE 'CHECK' END, 'repeat_findings' FROM repeat_findings;

-- ============================================================
-- Acceptance Criteria: mart_checks = row-count & sum-check setiap mart terhadap sumbernya (hasil Part 5)
-- ============================================================
CREATE OR REPLACE TEMP TABLE chk_raw (mart VARCHAR, tabel VARCHAR, cek VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO chk_raw VALUES
 -- mart_overview
 ('mart_overview','mart_overview_kpi','row count = 14 KPI dashboard',      (SELECT COUNT(*) FROM mart_overview_kpi), 14, 0),
 ('mart_overview','mart_overview_kpi','nilai semua KPI = kpi_lock (selisih maks)',
        (SELECT COALESCE(MAX(ABS(m.value_all_period - ROUND(k.value, 4))), 0) FROM mart_overview_kpi m JOIN kpi_lock k USING (kpi)), 0, 0.00001),
 ('mart_overview','mart_overview_kpi','Item Revenue = R$ 13.494.400,74', (SELECT value_all_period FROM mart_overview_kpi WHERE kpi = 'Item Revenue'), 13494400.74, 0.011),
 ('mart_overview','mart_overview_kpi','Late Rate = 6,773%',               (SELECT ROUND(value_all_period, 3) FROM mart_overview_kpi WHERE kpi = 'Late Rate'), 6.773, 0.0011),
 ('mart_overview','mart_overview_monthly','row count = sales_monthly',     (SELECT COUNT(*) FROM mart_overview_monthly), (SELECT COUNT(*) FROM sales_monthly), 0),
 ('mart_overview','mart_overview_monthly','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_overview_monthly), 13494400.74, 0.02),
 ('mart_overview','mart_overview_monthly','SUM(revenue_orders) = 98.199',  (SELECT SUM(revenue_orders) FROM mart_overview_monthly), 98199, 0),
 ('mart_overview','mart_overview_monthly','SUM(total_orders) = 99.441',    (SELECT SUM(total_orders) FROM mart_overview_monthly), 99441, 0),
 ('mart_overview','mart_overview_yoy','row count = 8 bulan',              (SELECT COUNT(*) FROM mart_overview_yoy), 8, 0),
 ('mart_overview','mart_overview_category_top','row count = 11 (10 + Lainnya)', (SELECT COUNT(*) FROM mart_overview_category_top), 11, 0),
 ('mart_overview','mart_overview_category_top','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_overview_category_top), 13494400.74, 0.02),
 ('mart_overview','mart_overview_state','row count = 27 state',           (SELECT COUNT(*) FROM mart_overview_state), 27, 0),
 ('mart_overview','mart_overview_state','SUM(n_orders) = 99.441',         (SELECT SUM(n_orders) FROM mart_overview_state), 99441, 0),
 ('mart_overview','mart_overview_state','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_overview_state), 13494400.74, 0.02),
 -- mart_fulfillment_delivery
 ('mart_fulfillment_delivery','mart_fd_status','row count = 8 status',     (SELECT COUNT(*) FROM mart_fd_status), 8, 0),
 ('mart_fulfillment_delivery','mart_fd_status','SUM(n_order) = 99.441',    (SELECT SUM(n_order) FROM mart_fd_status), 99441, 0),
 ('mart_fulfillment_delivery','mart_fd_funnel','row count = 4 tahap',      (SELECT COUNT(*) FROM mart_fd_funnel), 4, 0),
 ('mart_fulfillment_delivery','mart_fd_cancel_trace','SUM(n_order) = 625', (SELECT SUM(n_order) FROM mart_fd_cancel_trace), 625, 0),
 ('mart_fulfillment_delivery','mart_fd_monthly','row count = status_monthly', (SELECT COUNT(*) FROM mart_fd_monthly), (SELECT COUNT(*) FROM status_monthly), 0),
 ('mart_fulfillment_delivery','mart_fd_monthly','SUM(total_orders) = 99.441', (SELECT SUM(total_orders) FROM mart_fd_monthly), 99441, 0),
 ('mart_fulfillment_delivery','mart_fd_monthly','SUM(canceled) = 625',    (SELECT SUM(canceled) FROM mart_fd_monthly), 625, 0),
 ('mart_fulfillment_delivery','mart_fd_monthly','SUM(unavailable) = 609', (SELECT SUM(unavailable) FROM mart_fd_monthly), 609, 0),
 ('mart_fulfillment_delivery','mart_fd_monthly','SUM(delivered_pop) = 96.470', (SELECT SUM(delivered_pop) FROM mart_fd_monthly), 96470, 0),
 ('mart_fulfillment_delivery','mart_fd_monthly','SUM(late_orders) = 6.534', (SELECT SUM(late_orders) FROM mart_fd_monthly), 6534, 0),
 ('mart_fulfillment_delivery','mart_fd_stage','row count = 4 tahap',      (SELECT COUNT(*) FROM mart_fd_stage), 4, 0),
 ('mart_fulfillment_delivery','mart_fd_stage','n tahap total = Delivered Population', (SELECT n_used FROM mart_fd_stage WHERE tahap LIKE '4%'), 96470, 0),
 ('mart_fulfillment_delivery','mart_fd_estimate_gap','SUM(n_order) = 96.470', (SELECT SUM(n_order) FROM mart_fd_estimate_gap), 96470, 0),
 ('mart_fulfillment_delivery','mart_fd_estimate_gap','SUM(n telat) = 6.534 (D1)', (SELECT SUM(n_order) FROM mart_fd_estimate_gap WHERE selisih_vs_estimasi LIKE '5%' OR selisih_vs_estimasi LIKE '6%' OR selisih_vs_estimasi LIKE '7%' OR selisih_vs_estimasi LIKE '8%'), 6534, 0),
 ('mart_fulfillment_delivery','mart_fd_state','row count = 27 state',     (SELECT COUNT(*) FROM mart_fd_state), 27, 0),
 ('mart_fulfillment_delivery','mart_fd_state','SUM(n_delivered) = 96.470', (SELECT SUM(n_delivered) FROM mart_fd_state), 96470, 0),
 ('mart_fulfillment_delivery','mart_fd_intra_inter','row count = 2',      (SELECT COUNT(*) FROM mart_fd_intra_inter), 2, 0),
 ('mart_fulfillment_delivery','mart_fd_intra_inter','SUM(n_order) = Single-Seller terkirim', (SELECT SUM(n_order) FROM mart_fd_intra_inter), (SELECT COUNT(*) FROM fact_orders WHERE is_single_seller_pop AND is_delivered_complete), 0),
 ('mart_fulfillment_delivery','mart_fd_distance_band','row count = 6 band', (SELECT COUNT(*) FROM mart_fd_distance_band), 6, 0),
 ('mart_fulfillment_delivery','mart_fd_distance_band','SUM(n_order) = SUM ber-jarak regional_relative', (SELECT SUM(n_order) FROM mart_fd_distance_band), (SELECT SUM(n_orders_ber_jarak) FROM regional_relative), 0),
 -- mart_customer_satisfaction
 ('mart_customer_satisfaction','mart_cs_distribution','row count = 5 skor', (SELECT COUNT(*) FROM mart_cs_distribution), 5, 0),
 ('mart_customer_satisfaction','mart_cs_distribution','SUM(n_order) = Review Population 98.673', (SELECT SUM(n_order) FROM mart_cs_distribution), 98673, 0),
 ('mart_customer_satisfaction','mart_cs_distribution','Avg Review Score = 4,0864', (SELECT ROUND(SUM(review_score * n_order) / SUM(n_order), 4) FROM mart_cs_distribution), 4.0864, 0.00011),
 ('mart_customer_satisfaction','mart_cs_monthly','row count = sat_monthly', (SELECT COUNT(*) FROM mart_cs_monthly), (SELECT COUNT(*) FROM sat_monthly), 0),
 ('mart_customer_satisfaction','mart_cs_monthly','SUM(n_reviews) = 98.673', (SELECT SUM(n_reviews) FROM mart_cs_monthly), 98673, 0),
 ('mart_customer_satisfaction','mart_cs_d4_layers','lapis 1 SUM(n) = Delivered x Review 95.824', (SELECT SUM(n_order) FROM mart_cs_d4_layers WHERE lapis LIKE 'lapis 1%'), 95824, 0),
 ('mart_customer_satisfaction','mart_cs_d4_layers','lapis 2 SUM(n) = Delivered x Review 95.824', (SELECT SUM(n_order) FROM mart_cs_d4_layers WHERE lapis LIKE 'lapis 2%'), 95824, 0),
 ('mart_customer_satisfaction','mart_cs_d4_layers','late & dijawab sebelum: n = 4.473', (SELECT n_order FROM mart_cs_d4_layers WHERE lapis LIKE 'lapis 2%' AND is_late AND answered_before_delivery), 4473, 0),
 ('mart_customer_satisfaction','mart_cs_d4_bucket','SUM(n_semua) = 95.824', (SELECT SUM(n_semua) FROM mart_cs_d4_bucket), 95824, 0),
 ('mart_customer_satisfaction','mart_cs_category','row count = 52 kategori >= 100 order', (SELECT COUNT(*) FROM mart_cs_category), 52, 0),
 ('mart_customer_satisfaction','mart_cs_state','row count = 27 state',     (SELECT COUNT(*) FROM mart_cs_state), 27, 0),
 ('mart_customer_satisfaction','mart_cs_state','SUM(n_reviews) = 98.673', (SELECT SUM(n_reviews) FROM mart_cs_state), 98673, 0),
 ('mart_customer_satisfaction','mart_cs_survey_timing','SUM(n_order) = 95.824', (SELECT SUM(n_order) FROM mart_cs_survey_timing), 95824, 0),
 -- mart_product_payment
 ('mart_product_payment','mart_pp_category','row count = 74 kategori',    (SELECT COUNT(*) FROM mart_pp_category), 74, 0),
 ('mart_product_payment','mart_pp_category','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_pp_category), 13494400.74, 0.02),
 ('mart_product_payment','mart_pp_category','SUM(n_units) = 112.101',     (SELECT SUM(n_units) FROM mart_pp_category), 112101, 0),
 ('mart_product_payment','mart_pp_category','kategori unknown tetap ada',  (SELECT COUNT(*) FROM mart_pp_category WHERE is_unknown), 1, 0),
 ('mart_product_payment','mart_pp_category_quadrant','row count = 52 kategori >= 100 order', (SELECT COUNT(*) FROM mart_pp_category_quadrant), 52, 0),
 ('mart_product_payment','mart_pp_price_band','row count = 7 pita',      (SELECT COUNT(*) FROM mart_pp_price_band), 7, 0),
 ('mart_product_payment','mart_pp_price_band','SUM(n_item) = 112.101',   (SELECT SUM(n_item) FROM mart_pp_price_band), 112101, 0),
 ('mart_product_payment','mart_pp_price_band','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_pp_price_band), 13494400.74, 0.02),
 ('mart_product_payment','mart_pp_basket_summary','multi-produk Item Population = 3.236', (SELECT n_order_multi_produk FROM mart_pp_basket_summary WHERE basis = 'Item Population'), 3236, 0),
 ('mart_product_payment','mart_pp_basket_summary','lintas kategori Item Population = 786', (SELECT n_lintas_kategori FROM mart_pp_basket_summary WHERE basis = 'Item Population'), 786, 0),
 ('mart_product_payment','mart_pp_basket_pairs','row count = 10',         (SELECT COUNT(*) FROM mart_pp_basket_pairs), 10, 0),
 ('mart_product_payment','mart_pp_payment_type','SUM(n_payment) = 103.886', (SELECT SUM(n_payment) FROM mart_pp_payment_type), 103886, 0),
 ('mart_product_payment','mart_pp_payment_type','SUM(total_value) = Payment Total (R$)', (SELECT SUM(total_value) FROM mart_pp_payment_type), 16008872.12, 0.02),
 ('mart_product_payment','mart_pp_payment_mix','SUM(n_order) = Payment Population 99.440', (SELECT SUM(n_order) FROM mart_pp_payment_mix), 99440, 0),
 ('mart_product_payment','mart_pp_installments','SUM(n_payment) = 76.793', (SELECT SUM(n_payment) FROM mart_pp_installments), 76793, 0),
 ('mart_product_payment','mart_pp_payment_monthly','row count = payment_monthly', (SELECT COUNT(*) FROM mart_pp_payment_monthly), (SELECT COUNT(*) FROM payment_monthly), 0),
 ('mart_product_payment','mart_pp_payment_monthly','SUM(payment_orders) = 99.440', (SELECT SUM(payment_orders) FROM mart_pp_payment_monthly), 99440, 0),
 -- mart_seller_regional
 ('mart_seller_regional','mart_sr_seller','row count = 3.095 seller',    (SELECT COUNT(*) FROM mart_sr_seller), 3095, 0),
 ('mart_seller_regional','mart_sr_seller','SUM(item_revenue_rp) = Item Revenue total (R$)', (SELECT SUM(item_revenue_rp) FROM mart_sr_seller), 13494400.74, 0.02),
 ('mart_seller_regional','mart_sr_seller','metrik rate hanya untuk seller >= 30 order (baris rate dengan eligible = FALSE)',
        (SELECT COUNT(*) FROM mart_sr_seller WHERE NOT eligible_rate AND late_rate_pct IS NOT NULL), 0, 0),
 ('mart_seller_regional','mart_sr_seller_tier','row count = 3 tier',      (SELECT COUNT(*) FROM mart_sr_seller_tier), 3, 0),
 ('mart_seller_regional','mart_sr_seller_tier','n seller 210 / 424 / 2.461 (jumlah = 3.095)', (SELECT SUM(n_seller) FROM mart_sr_seller_tier), 3095, 0),
 ('mart_seller_regional','mart_sr_seller_tier','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_sr_seller_tier), 13494400.74, 0.02),
 ('mart_seller_regional','mart_sr_pareto','top 1% = 31 seller',          (SELECT n_seller_top FROM mart_sr_pareto WHERE top_pct_seller = 1), 31, 0),
 ('mart_seller_regional','mart_sr_lorenz','SUM(n_seller) = 3.095',       (SELECT SUM(n_seller) FROM mart_sr_lorenz), 3095, 0),
 ('mart_seller_regional','mart_sr_lorenz','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_sr_lorenz), 13494400.74, 0.02),
 ('mart_seller_regional','mart_sr_state','row count = 27 state',          (SELECT COUNT(*) FROM mart_sr_state), 27, 0),
 ('mart_seller_regional','mart_sr_state','SUM(n_orders) = 99.441',       (SELECT SUM(n_orders) FROM mart_sr_state), 99441, 0),
 ('mart_seller_regional','mart_sr_state','SUM(item_revenue) = Item Revenue total (R$)', (SELECT SUM(item_revenue) FROM mart_sr_state), 13494400.74, 0.02),
 ('mart_seller_regional','mart_sr_state','SUM(n_pelanggan_order_pertama) = 96.096', (SELECT SUM(n_pelanggan_order_pertama) FROM mart_sr_state), 96096, 0),
 ('mart_seller_regional','mart_sr_state','SUM(n_seller) = 3.095',        (SELECT SUM(n_seller) FROM mart_sr_state), 3095, 0),
 ('mart_seller_regional','mart_sr_state','tidak ada kolom tier (D12)',
        (SELECT COUNT(*) FROM duckdb_columns() WHERE table_name = 'mart_sr_state' AND lower(column_name) LIKE '%tier%'), 0, 0),
 ('mart_seller_regional','mart_sr_city','row count = regional_city',     (SELECT COUNT(*) FROM mart_sr_city), (SELECT COUNT(*) FROM regional_city), 0),
 ('mart_seller_regional','mart_sr_city','kota >= 100 order = 141',       (SELECT COUNT(*) FROM mart_sr_city WHERE memenuhi_min_volume), 141, 0),
 ('mart_seller_regional','mart_sr_repeat_monthly','SUM(n_orders) = 99.441', (SELECT SUM(n_orders) FROM mart_sr_repeat_monthly), 99441, 0),
 ('mart_seller_regional','mart_sr_repeat_cohort','SUM(n_pelanggan) = 96.096', (SELECT SUM(n_pelanggan) FROM mart_sr_repeat_cohort), 96096, 0),
 ('mart_seller_regional','mart_sr_repeat_headline','Repeat Rate = 2,208%', (SELECT nilai_pct FROM mart_sr_repeat_headline WHERE kpi LIKE 'Repeat Rate%'), 2.208, 0.0011),
 ('mart_seller_regional','mart_sr_repeat_headline','90-day Repeat Rate = 1,302%', (SELECT nilai_pct FROM mart_sr_repeat_headline WHERE kpi LIKE '90-day%'), 1.302, 0.0011),
 -- mart_data_quality_summary
 ('mart_data_quality_summary','mart_data_quality_summary','semua metrik kuantitatif (dq_value tidak NULL)', (SELECT COUNT(*) FROM mart_data_quality_summary WHERE dq_value IS NULL), 0, 0),
 ('mart_data_quality_summary','mart_data_quality_summary','row count raw = 9 tabel', (SELECT COUNT(*) FROM mart_data_quality_summary WHERE dq_section = 'raw_rowcount'), 9, 0),
 ('mart_data_quality_summary','mart_data_quality_summary','SUM row count raw = 1.000.163 + ... (jumlah 9 tabel)',
        (SELECT SUM(dq_value) FROM mart_data_quality_summary WHERE dq_section = 'raw_rowcount'),
        (SELECT (SELECT COUNT(*) FROM raw_customers) + (SELECT COUNT(*) FROM raw_geolocation) + (SELECT COUNT(*) FROM raw_order_items) + (SELECT COUNT(*) FROM raw_order_payments)
              + (SELECT COUNT(*) FROM raw_order_reviews) + (SELECT COUNT(*) FROM raw_orders) + (SELECT COUNT(*) FROM raw_products) + (SELECT COUNT(*) FROM raw_sellers) + (SELECT COUNT(*) FROM raw_category_translation)), 0),
 ('mart_data_quality_summary','mart_data_quality_summary','rekonsiliasi payment: bucket <= 0,01 = 98.362',
        (SELECT dq_value FROM mart_data_quality_summary WHERE dq_section = 'rekonsiliasi_payment' AND dq_metric = 'selisih <= 0,01'), 98362, 0),
 ('mart_data_quality_summary','mart_data_quality_summary','anomali urutan tanggal: order terdampak = 1.382',
        (SELECT dq_value FROM mart_data_quality_summary WHERE dq_section = 'flag_anomali' AND dq_metric LIKE 'order dengan >= 1 anomali%'), 1382, 0),
 ('mart_data_quality_summary','mart_data_quality_summary','gate Tahap 6: HARD semua PASS',
        (SELECT dq_pct FROM mart_data_quality_summary WHERE dq_section = 'gate_validasi' AND dq_metric LIKE 'Tahap 6: rule HARD%'), 100, 0),
 ('mart_data_quality_summary','mart_data_quality_summary','gate Tahap 8: HARD semua PASS',
        (SELECT dq_pct FROM mart_data_quality_summary WHERE dq_section = 'gate_validasi' AND dq_metric LIKE 'Tahap 8: rule HARD%'), 100, 0);

CREATE OR REPLACE TABLE mart_checks AS
SELECT mart, tabel, cek, n_actual, n_expected, tol,
       CASE WHEN n_actual IS NOT NULL AND n_expected IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS' ELSE 'FAIL' END AS status
FROM chk_raw;

SELECT mart, COUNT(*) AS n_cek, COUNT(*) FILTER (WHERE status = 'PASS') AS n_pass, COUNT(*) FILTER (WHERE status = 'FAIL') AS n_fail
FROM mart_checks GROUP BY mart ORDER BY mart;

SELECT CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'GATE PASS: semua mart lolos row-count & sum-check'
            ELSE 'GATE FAIL: perbaiki mart sebelum dipakai dashboard' END AS gate,
       COUNT(*) AS n_cek, COUNT(*) FILTER (WHERE status = 'PASS') AS n_pass
FROM mart_checks;

SELECT mart, tabel, cek, n_actual, n_expected, status FROM mart_checks WHERE status = 'FAIL' ORDER BY mart, tabel;

-- Semua cek (untuk didokumentasikan)
SELECT mart, tabel, cek, n_actual, n_expected, status FROM mart_checks ORDER BY mart, tabel, cek;

-- ============================================================
-- Katalog mart: tabel, grain, jumlah baris, halaman dashboard
-- ============================================================
CREATE OR REPLACE TABLE mart_catalog AS
SELECT * FROM (
 SELECT 'mart_overview' AS mart, 1 AS halaman, 'mart_overview_kpi' AS tabel, '1 baris = 1 KPI terkunci' AS grain, (SELECT COUNT(*) FROM mart_overview_kpi) AS n_baris
 UNION ALL SELECT 'mart_overview', 1, 'mart_overview_monthly', '1 baris = 1 bulan', (SELECT COUNT(*) FROM mart_overview_monthly)
 UNION ALL SELECT 'mart_overview', 1, 'mart_overview_yoy', '1 baris = 1 bulan (YoY Jan-Agu)', (SELECT COUNT(*) FROM mart_overview_yoy)
 UNION ALL SELECT 'mart_overview', 1, 'mart_overview_category_top', '1 baris = 1 kategori top-10 / Lainnya', (SELECT COUNT(*) FROM mart_overview_category_top)
 UNION ALL SELECT 'mart_overview', 1, 'mart_overview_state', '1 baris = 1 state', (SELECT COUNT(*) FROM mart_overview_state)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_status', '1 baris = 1 status order', (SELECT COUNT(*) FROM mart_fd_status)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_funnel', '1 baris = 1 tahap funnel', (SELECT COUNT(*) FROM mart_fd_funnel)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_cancel_trace', '1 baris = 1 jejak terakhir canceled', (SELECT COUNT(*) FROM mart_fd_cancel_trace)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_monthly', '1 baris = 1 bulan', (SELECT COUNT(*) FROM mart_fd_monthly)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_stage', '1 baris = 1 tahap durasi', (SELECT COUNT(*) FROM mart_fd_stage)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_estimate_gap', '1 baris = 1 bucket selisih vs estimasi', (SELECT COUNT(*) FROM mart_fd_estimate_gap)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_state', '1 baris = 1 state', (SELECT COUNT(*) FROM mart_fd_state)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_intra_inter', '1 baris = intra / antar-state', (SELECT COUNT(*) FROM mart_fd_intra_inter)
 UNION ALL SELECT 'mart_fulfillment_delivery', 2, 'mart_fd_distance_band', '1 baris = 1 band jarak', (SELECT COUNT(*) FROM mart_fd_distance_band)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_distribution', '1 baris = 1 skor', (SELECT COUNT(*) FROM mart_cs_distribution)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_monthly', '1 baris = 1 bulan', (SELECT COUNT(*) FROM mart_cs_monthly)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_d4_layers', '1 baris = 1 sel (lapis 1 / lapis 2)', (SELECT COUNT(*) FROM mart_cs_d4_layers)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_d4_bucket', '1 baris = 1 bucket keterlambatan', (SELECT COUNT(*) FROM mart_cs_d4_bucket)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_category', '1 baris = 1 kategori >= 100 order', (SELECT COUNT(*) FROM mart_cs_category)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_state', '1 baris = 1 state', (SELECT COUNT(*) FROM mart_cs_state)
 UNION ALL SELECT 'mart_customer_satisfaction', 3, 'mart_cs_survey_timing', '1 baris = 1 bucket waktu survei', (SELECT COUNT(*) FROM mart_cs_survey_timing)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_category', '1 baris = 1 kategori (74)', (SELECT COUNT(*) FROM mart_pp_category)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_category_quadrant', '1 baris = 1 kategori >= 100 order', (SELECT COUNT(*) FROM mart_pp_category_quadrant)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_price_band', '1 baris = 1 pita harga', (SELECT COUNT(*) FROM mart_pp_price_band)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_basket_summary', '1 baris = 1 basis populasi', (SELECT COUNT(*) FROM mart_pp_basket_summary)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_basket_pairs', '1 baris = 1 pasangan kategori', (SELECT COUNT(*) FROM mart_pp_basket_pairs)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_payment_type', '1 baris = 1 tipe pembayaran', (SELECT COUNT(*) FROM mart_pp_payment_type)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_payment_mix', '1 baris = 1 kombinasi tipe', (SELECT COUNT(*) FROM mart_pp_payment_mix)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_installments', '1 baris = 1 jumlah cicilan', (SELECT COUNT(*) FROM mart_pp_installments)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_installments_by_value', '1 baris = 1 rentang nilai order', (SELECT COUNT(*) FROM mart_pp_installments_by_value)
 UNION ALL SELECT 'mart_product_payment', 4, 'mart_pp_payment_monthly', '1 baris = 1 bulan', (SELECT COUNT(*) FROM mart_pp_payment_monthly)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_seller', '1 baris = 1 seller', (SELECT COUNT(*) FROM mart_sr_seller)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_seller_tier', '1 baris = 1 tier', (SELECT COUNT(*) FROM mart_sr_seller_tier)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_pareto', '1 baris = 1 top k%', (SELECT COUNT(*) FROM mart_sr_pareto)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_lorenz', '1 baris = 1 desil seller', (SELECT COUNT(*) FROM mart_sr_lorenz)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_concentration', '1 baris = Gini dan HHI', (SELECT COUNT(*) FROM mart_sr_concentration)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_state', '1 baris = 1 state (tanpa tier)', (SELECT COUNT(*) FROM mart_sr_state)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_city', '1 baris = 1 kota (>= 30 order)', (SELECT COUNT(*) FROM mart_sr_city)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_repeat_monthly', '1 baris = 1 bulan', (SELECT COUNT(*) FROM mart_sr_repeat_monthly)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_repeat_cohort', '1 baris = 1 cohort bulan', (SELECT COUNT(*) FROM mart_sr_repeat_cohort)
 UNION ALL SELECT 'mart_seller_regional', 5, 'mart_sr_repeat_headline', '1 baris = 1 KPI repeat headline', (SELECT COUNT(*) FROM mart_sr_repeat_headline)
 UNION ALL SELECT 'mart_data_quality_summary', 6, 'mart_data_quality_summary', '1 baris = 1 metrik kuantitatif', (SELECT COUNT(*) FROM mart_data_quality_summary)
) ORDER BY halaman, tabel;

SELECT mart, halaman, COUNT(*) AS n_tabel, SUM(n_baris) AS total_baris FROM mart_catalog GROUP BY mart, halaman ORDER BY halaman;
SELECT * FROM mart_catalog ORDER BY halaman, tabel;