-- ============================================================
-- Tahap 16 — Regional Performance Analysis
-- File: sql/15_regional_performance.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/15_regional_performance.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       state (27) / kota = kombinasi state-kota / pasangan state x band jarak; dinyatakan di tiap blok
-- POPULATION:  Order Population (99.441) untuk jumlah order dan kepuasan; Revenue Population (98.199) untuk revenue,
--              AOV, freight; Delivered Population (96.470) untuk delivery_days dan Late Rate;
--              Single-Seller Population untuk standardisasi jarak (absolute vs relative)
-- DENOMINATOR: n order per wilayah (selalu ditampilkan); % order terhadap total 99.441
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * STATE TIDAK DITIER (D12): semua 27 state ditampilkan dengan n dan share; tidak ada kolom/segmen Top/Mid/Long-tail
--     untuk state. Konsentrasi (SP, RJ, MG) dijelaskan sebagai konsentrasi, bukan tier. Kolom low_n_flag hanya
--     penanda keandalan (n kecil), bukan segmentasi.
--   * Kota = kombinasi (customer_state, customer_city); hanya kota dengan >= 100 order (D6) untuk rate/ranking;
--     kota 30-99 order hanya muncul di tabel kota dengan penanda n.
--   * Rate pada state/kota kecil rentan menyesatkan: selalu baca bersama n.
--   * Korelasi antar state adalah korelasi agregat (ekologis), bukan efek pada individu.
--   * Hubungan antar variabel = asosiasi, bukan kausal.
-- Output: data/processed/15_regional_state.parquet, 15_regional_city.parquet, 15_regional_findings.parquet
-- ============================================================

-- ============================================================
-- 1. TABEL SILANG PER STATE (27 state; tanpa tiering)
-- ============================================================
CREATE OR REPLACE TABLE regional_state AS
SELECT customer_state AS state,
       COUNT(*)                                                   AS n_orders,
       COUNT(*) FILTER (WHERE is_revenue_order)                   AS n_revenue_orders,
       ROUND(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS item_revenue,
       ROUND(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE)
             / NULLIF(COUNT(*) FILTER (WHERE is_revenue_order), 0), 2) AS aov,
       ROUND(CAST(SUM(freight_total) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS freight_revenue,
       ROUND(100.0 * CAST(SUM(freight_total) FILTER (WHERE is_revenue_order) AS DOUBLE)
             / NULLIF(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE), 0), 2) AS freight_pct_of_item,
       ROUND(CAST(AVG(freight_total) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS avg_freight_per_order,
       COUNT(*) FILTER (WHERE is_delivered_complete)              AS n_delivered,
       ROUND(quantile_cont(delivery_days, 0.5), 2)                AS delivery_days_p50,
       ROUND(AVG(delivery_days), 2)                               AS delivery_days_mean,
       ROUND(quantile_cont(delivery_days, 0.95), 2)               AS delivery_days_p95,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*) FILTER (WHERE is_delivered_complete), 0), 3) AS late_rate_pct,
       COUNT(review_score)                                        AS n_reviews,
       ROUND(AVG(review_score), 3)                                AS avg_review_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / NULLIF(COUNT(review_score), 0), 2) AS pct_skor_1_2,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) AS cancellation_rate_pct
FROM fact_orders GROUP BY customer_state;

CREATE OR REPLACE TEMP TABLE r_state AS
SELECT *,
       ROUND(100.0 * n_orders / SUM(n_orders) OVER (), 2)               AS pct_orders,
       ROUND(100.0 * n_revenue_orders / SUM(n_revenue_orders) OVER (), 2) AS pct_revenue_orders,
       ROUND(100.0 * item_revenue / SUM(item_revenue) OVER (), 2)       AS pct_revenue,
       (n_orders < 0.01 * SUM(n_orders) OVER ())                        AS low_n_flag
FROM regional_state;

-- 1.1 Tabel silang lengkap, urut jumlah order (semua 27 state)
SELECT state, n_orders, pct_orders, pct_revenue_orders, pct_revenue, aov,
       avg_freight_per_order, freight_pct_of_item,
       delivery_days_p50, late_rate_pct, avg_review_score, pct_skor_1_2, n_reviews, low_n_flag
FROM r_state ORDER BY n_orders DESC;

-- 1.2 Konsentrasi (dijelaskan sebagai konsentrasi, bukan tier)
SELECT ROUND(SUM(pct_orders) FILTER (WHERE state IN ('SP')), 2)             AS sp_pct_orders,
       ROUND(SUM(pct_orders) FILTER (WHERE state IN ('SP','RJ','MG')), 2)   AS sp_rj_mg_pct_orders,
       ROUND(SUM(pct_revenue) FILTER (WHERE state IN ('SP','RJ','MG')), 2)  AS sp_rj_mg_pct_revenue,
       ROUND(SUM(pct_revenue) FILTER (WHERE state = 'SP'), 2)               AS sp_pct_revenue,
       COUNT(*) FILTER (WHERE pct_orders < 1)         AS n_state_lt_1pct_orders,
       COUNT(*) FILTER (WHERE pct_revenue_orders < 1) AS n_state_lt_1pct_revenue_orders,
       COUNT(*) FILTER (WHERE pct_revenue < 1)        AS n_state_lt_1pct_revenue,
       ROUND(MIN(aov), 2) AS aov_min, ROUND(MAX(aov), 2) AS aov_max,
       ROUND(SUM(POW(pct_orders, 2)), 1) AS hhi_order_state
FROM r_state;

SELECT state AS state_aov_terendah, aov, n_revenue_orders FROM r_state ORDER BY aov ASC LIMIT 3;
SELECT state AS state_aov_tertinggi, aov, n_revenue_orders FROM r_state ORDER BY aov DESC LIMIT 5;

-- 1.3 Korelasi antar state (ekologis; 27 titik)
SELECT ROUND(corr(late_rate_pct, avg_review_score), 3) AS r_late_vs_skor,
       ROUND(corr(delivery_days_mean, late_rate_pct), 3) AS r_delivery_vs_late,
       ROUND(corr(avg_freight_per_order, delivery_days_mean), 3) AS r_freight_vs_delivery,
       ROUND(corr(aov, freight_pct_of_item), 3) AS r_aov_vs_freight_pct,
       ROUND(corr(LN(n_orders), late_rate_pct), 3) AS r_log_order_vs_late
FROM r_state;

-- ============================================================
-- 2. ABSOLUTE vs RELATIVE: kinerja terhadap ekspektasi menurut jarak seller-customer
--    Single-Seller Population x Delivered Population dengan koordinat valid.
--    Ekspektasi = rata-rata nasional per band jarak, dibobot bauran jarak state itu (standardisasi tidak langsung).
-- ============================================================
CREATE OR REPLACE TEMP TABLE r_dist AS
SELECT f.order_id, f.customer_state AS state, f.delivery_days, f.is_late,
       2 * 6371.0 * asin(sqrt(pow(sin(radians(gc.lat - gs.lat) / 2), 2)
           + cos(radians(gs.lat)) * cos(radians(gc.lat)) * pow(sin(radians(gc.lng - gs.lng) / 2), 2))) AS distance_km
FROM fact_orders f
JOIN dim_seller s ON s.seller_id = f.single_seller_id
JOIN dim_geo_zip gs ON gs.zip = s.seller_zip_prefix
JOIN dim_geo_zip gc ON gc.zip = f.customer_zip_prefix
WHERE f.is_single_seller_pop AND f.is_delivered_complete AND gs.lat IS NOT NULL AND gc.lat IS NOT NULL;

CREATE OR REPLACE TEMP TABLE r_band AS
SELECT order_id, state, delivery_days, is_late, distance_km,
       CASE WHEN distance_km < 100 THEN 1 WHEN distance_km < 300 THEN 2 WHEN distance_km < 600 THEN 3
            WHEN distance_km < 1000 THEN 4 WHEN distance_km < 2000 THEN 5 ELSE 6 END AS band
FROM r_dist;

CREATE OR REPLACE TEMP TABLE r_nat AS
SELECT band, AVG(delivery_days) AS nat_mean_days, AVG(CASE WHEN is_late THEN 1.0 ELSE 0.0 END) AS nat_late
FROM r_band GROUP BY band;

CREATE OR REPLACE TABLE regional_relative AS
SELECT b.state, COUNT(*) AS n_orders_ber_jarak,
       ROUND(AVG(b.distance_km), 1) AS avg_jarak_km,
       ROUND(AVG(b.delivery_days), 2) AS delivery_mean_observasi,
       ROUND(AVG(n.nat_mean_days), 2) AS delivery_mean_ekspektasi,
       ROUND(AVG(b.delivery_days) / AVG(n.nat_mean_days), 3) AS rasio_delivery_obs_vs_eks,
       ROUND(100.0 * AVG(CASE WHEN b.is_late THEN 1.0 ELSE 0.0 END), 3) AS late_rate_observasi,
       ROUND(100.0 * AVG(n.nat_late), 3) AS late_rate_ekspektasi,
       ROUND(100.0 * (AVG(CASE WHEN b.is_late THEN 1.0 ELSE 0.0 END) - AVG(n.nat_late)), 3) AS late_rate_selisih_poin
FROM r_band b JOIN r_nat n ON n.band = b.band GROUP BY b.state;

-- 2.1 Semua state: observasi vs ekspektasi (urut rasio delivery; > 1 = lebih lambat dari ekspektasi bauran jaraknya)
SELECT * FROM regional_relative ORDER BY rasio_delivery_obs_vs_eks DESC;

-- 2.2 Absolute vs relative per state: peringkat absolut dan peringkat relatif (hanya state dengan >= 300 order ber-jarak)
SELECT r.state, r.n_orders_ber_jarak,
       a.late_rate_pct AS late_rate_absolut_semua_order, r.late_rate_observasi, r.late_rate_ekspektasi, r.late_rate_selisih_poin,
       RANK() OVER (ORDER BY a.late_rate_pct DESC)            AS rank_absolut_late,
       RANK() OVER (ORDER BY r.late_rate_selisih_poin DESC)   AS rank_relatif_late,
       r.rasio_delivery_obs_vs_eks
FROM regional_relative r JOIN r_state a ON a.state = r.state
WHERE r.n_orders_ber_jarak >= 300 ORDER BY r.late_rate_selisih_poin DESC;

-- 2.3 Skor review relatif terhadap rata-rata nasional (Review Population) dan hanya pada order on-time
SELECT customer_state AS state, COUNT(review_score) AS n_reviews,
       ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(AVG(review_score) - (SELECT AVG(review_score) FROM fact_orders), 3) AS selisih_vs_nasional,
       ROUND(AVG(review_score) FILTER (WHERE is_delivered_complete AND NOT is_late), 3) AS avg_score_order_on_time,
       ROUND(AVG(review_score) FILTER (WHERE is_delivered_complete AND NOT is_late)
             - (SELECT AVG(review_score) FROM fact_orders WHERE is_delivered_complete AND NOT is_late), 3) AS selisih_on_time_vs_nasional
FROM fact_orders GROUP BY customer_state ORDER BY selisih_vs_nasional;

-- ============================================================
-- 3. KOTA (kombinasi state-kota; hanya >= 100 order untuk rate/ranking, D6)
-- ============================================================
CREATE OR REPLACE TABLE regional_city AS
SELECT customer_state AS state, customer_city AS kota,
       COUNT(*)                                                   AS n_orders,
       COUNT(*) FILTER (WHERE is_revenue_order)                   AS n_revenue_orders,
       ROUND(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS item_revenue,
       ROUND(CAST(SUM(item_revenue) FILTER (WHERE is_revenue_order) AS DOUBLE)
             / NULLIF(COUNT(*) FILTER (WHERE is_revenue_order), 0), 2) AS aov,
       ROUND(CAST(AVG(freight_total) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS avg_freight_per_order,
       COUNT(*) FILTER (WHERE is_delivered_complete)              AS n_delivered,
       ROUND(quantile_cont(delivery_days, 0.5), 2)                AS delivery_days_p50,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*) FILTER (WHERE is_delivered_complete), 0), 3) AS late_rate_pct,
       COUNT(review_score)                                        AS n_reviews,
       ROUND(AVG(review_score), 3)                                AS avg_review_score,
       (COUNT(*) >= 100)                                          AS memenuhi_min_volume
FROM fact_orders GROUP BY customer_state, customer_city HAVING COUNT(*) >= 30;

-- 3.1 Cakupan: kombinasi state-kota dan ambang volume (D6)
SELECT (SELECT COUNT(*) FROM (SELECT customer_state, customer_city FROM fact_orders GROUP BY 1, 2)) AS n_kombinasi_state_kota,
       COUNT(*) FILTER (WHERE n_orders >= 100) AS n_kota_ge_100_order,
       COUNT(*) AS n_kota_ge_30_order,
       SUM(n_orders) FILTER (WHERE n_orders >= 100) AS n_order_kota_ge_100,
       ROUND(100.0 * SUM(n_orders) FILTER (WHERE n_orders >= 100) / (SELECT COUNT(*) FROM fact_orders), 2) AS pct_order_kota_ge_100,
       ROUND(100.0 * SUM(n_orders) / (SELECT COUNT(*) FROM fact_orders), 2) AS pct_order_kota_ge_30
FROM regional_city;

-- 3.2 Top 20 kota by order
SELECT state, kota, n_orders, ROUND(100.0 * n_orders / (SELECT COUNT(*) FROM fact_orders), 2) AS pct_order,
       item_revenue, aov, avg_freight_per_order, delivery_days_p50, late_rate_pct, avg_review_score
FROM regional_city WHERE memenuhi_min_volume ORDER BY n_orders DESC LIMIT 20;

-- 3.3 Konsentrasi kota
SELECT ROUND(100.0 * SUM(n_orders) FILTER (WHERE rk <= 1)  / (SELECT COUNT(*) FROM fact_orders), 2) AS top1_kota_pct_order,
       ROUND(100.0 * SUM(n_orders) FILTER (WHERE rk <= 5)  / (SELECT COUNT(*) FROM fact_orders), 2) AS top5_kota_pct_order,
       ROUND(100.0 * SUM(n_orders) FILTER (WHERE rk <= 10) / (SELECT COUNT(*) FROM fact_orders), 2) AS top10_kota_pct_order,
       ROUND(100.0 * SUM(n_orders) FILTER (WHERE rk <= 20) / (SELECT COUNT(*) FROM fact_orders), 2) AS top20_kota_pct_order
FROM (SELECT n_orders, ROW_NUMBER() OVER (ORDER BY n_orders DESC) AS rk FROM regional_city);

-- 3.4 Top 10 kota by Item Revenue dan AOV tertinggi/terendah (>= 100 order)
SELECT 'revenue terbesar' AS urutan, * FROM (
    SELECT state, kota, n_revenue_orders, item_revenue, aov FROM regional_city WHERE memenuhi_min_volume ORDER BY item_revenue DESC LIMIT 10)
UNION ALL
SELECT 'AOV tertinggi', * FROM (
    SELECT state, kota, n_revenue_orders, item_revenue, aov FROM regional_city WHERE memenuhi_min_volume ORDER BY aov DESC LIMIT 8)
UNION ALL
SELECT 'AOV terendah', * FROM (
    SELECT state, kota, n_revenue_orders, item_revenue, aov FROM regional_city WHERE memenuhi_min_volume ORDER BY aov ASC LIMIT 8)
ORDER BY urutan, item_revenue DESC;

-- 3.5 Late Rate dan skor review: kota terburuk dan terbaik (>= 100 order; n selalu ditampilkan)
SELECT 'late rate tertinggi' AS urutan, * FROM (
    SELECT state, kota, n_orders, n_delivered, late_rate_pct, delivery_days_p50, avg_review_score
    FROM regional_city WHERE memenuhi_min_volume ORDER BY late_rate_pct DESC LIMIT 10)
UNION ALL
SELECT 'late rate terendah', * FROM (
    SELECT state, kota, n_orders, n_delivered, late_rate_pct, delivery_days_p50, avg_review_score
    FROM regional_city WHERE memenuhi_min_volume ORDER BY late_rate_pct ASC LIMIT 8)
UNION ALL
SELECT 'skor terendah', * FROM (
    SELECT state, kota, n_orders, n_delivered, late_rate_pct, delivery_days_p50, avg_review_score
    FROM regional_city WHERE memenuhi_min_volume ORDER BY avg_review_score ASC LIMIT 8)
UNION ALL
SELECT 'skor tertinggi', * FROM (
    SELECT state, kota, n_orders, n_delivered, late_rate_pct, delivery_days_p50, avg_review_score
    FROM regional_city WHERE memenuhi_min_volume ORDER BY avg_review_score DESC LIMIT 8)
ORDER BY urutan, late_rate_pct DESC;

-- 3.6 Relatif: 15 kota terbesar dibandingkan state-nya (selisih Late Rate dan skor terhadap state)
SELECT c.state, c.kota, c.n_orders, c.late_rate_pct, s.late_rate_pct AS late_rate_state,
       ROUND(c.late_rate_pct - s.late_rate_pct, 3) AS selisih_late_vs_state,
       c.avg_review_score, s.avg_review_score AS skor_state,
       ROUND(c.avg_review_score - s.avg_review_score, 3) AS selisih_skor_vs_state
FROM regional_city c JOIN r_state s ON s.state = c.state
WHERE c.memenuhi_min_volume ORDER BY c.n_orders DESC LIMIT 15;

-- 3.7 Variasi kota di dalam state (state dengan >= 5 kota >= 100 order): rentang Late Rate antar kota
SELECT state, COUNT(*) AS n_kota_ge_100, ROUND(MIN(late_rate_pct), 2) AS late_min, ROUND(MAX(late_rate_pct), 2) AS late_maks,
       ROUND(MAX(late_rate_pct) - MIN(late_rate_pct), 2) AS rentang_poin
FROM regional_city WHERE memenuhi_min_volume GROUP BY state HAVING COUNT(*) >= 5 ORDER BY n_kota_ge_100 DESC;

-- ============================================================
-- 4. Reconcile ke KPI terkunci dan D12 -> regional_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE reg_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO reg_raw VALUES
 ('reconcile','jumlah state',                                       (SELECT COUNT(*) FROM regional_state), 27, 0),
 ('reconcile','SUM(n_orders) per state = Order Population',          (SELECT SUM(n_orders) FROM regional_state), 99441, 0),
 ('reconcile','SUM(n_revenue_orders) per state = Revenue Population',(SELECT SUM(n_revenue_orders) FROM regional_state), 98199, 0),
 ('reconcile','SUM(item_revenue) per state = Item Revenue (R$)',     (SELECT SUM(item_revenue) FROM regional_state), 13494400.74, 0.02),
 ('reconcile','SUM(n_delivered) per state = Delivered Population',   (SELECT SUM(n_delivered) FROM regional_state), 96470, 0),
 ('reconcile','SUM(n_reviews) per state = Review Population',        (SELECT SUM(n_reviews) FROM regional_state), 98673, 0),
 ('reconcile','AOV nasional = SUM(revenue)/SUM(revenue order) (R$)', (SELECT ROUND(SUM(item_revenue) / SUM(n_revenue_orders), 2) FROM regional_state), 137.42, 0.011),
 ('reconcile','Late Rate nasional dari state (terkunci 6,773)',     (SELECT ROUND(100.0 * (SELECT COUNT(*) FROM fact_orders WHERE is_late) / SUM(n_delivered), 3) FROM regional_state), 6.773, 0.0011),
 ('d12','kolom bernama *tier* di regional_state (harus 0)',          (SELECT COUNT(*) FROM duckdb_columns() WHERE table_name = 'regional_state' AND lower(column_name) LIKE '%tier%'), 0, 0),
 ('d12','kolom bernama *tier* di regional_city (harus 0)',           (SELECT COUNT(*) FROM duckdb_columns() WHERE table_name = 'regional_city' AND lower(column_name) LIKE '%tier%'), 0, 0),
 ('d12','kolom bernama *tier* di regional_relative (harus 0)',       (SELECT COUNT(*) FROM duckdb_columns() WHERE table_name = 'regional_relative' AND lower(column_name) LIKE '%tier%'), 0, 0),
 ('concentration','SP % order (Order Population)',                  (SELECT pct_orders FROM r_state WHERE state = 'SP'), 41.98, 0.011),
 ('concentration','SP % revenue order (roadmap 41,88)',             (SELECT pct_revenue_orders FROM r_state WHERE state = 'SP'), 41.88, 0.011),
 ('concentration','SP % revenue (roadmap 38,27)',                   (SELECT pct_revenue FROM r_state WHERE state = 'SP'), 38.27, 0.011),
 ('concentration','RJ % revenue order (roadmap 12,93)',             (SELECT pct_revenue_orders FROM r_state WHERE state = 'RJ'), 12.93, 0.011),
 ('concentration','MG % revenue order (roadmap 11,71)',             (SELECT pct_revenue_orders FROM r_state WHERE state = 'MG'), 11.71, 0.011),
 ('concentration','AOV terendah (SP; roadmap 125,57)',              (SELECT MIN(aov) FROM r_state), 125.57, 0.011),
 ('concentration','AOV tertinggi (PB; roadmap 216,34)',             (SELECT MAX(aov) FROM r_state), 216.34, 0.011),
 ('concentration','state < 1% revenue order (roadmap: 17 state < 1% order)', (SELECT COUNT(*) FROM r_state WHERE pct_revenue_orders < 1), 17, 0),
 ('concentration','state < 1% order (Order Population)',            (SELECT COUNT(*) FROM r_state WHERE pct_orders < 1), NULL, 0),
 ('correlation','r late vs skor antar state (Tahap 12: -0,821)',    (SELECT ROUND(corr(late_rate_pct, avg_review_score), 3) FROM r_state), -0.821, 0.02),
 ('city','kombinasi state-kota (roadmap 4.310)',                    (SELECT COUNT(*) FROM (SELECT customer_state, customer_city FROM fact_orders GROUP BY 1, 2)), 4310, 0),
 ('city','kota >= 100 order (roadmap 141)',                         (SELECT COUNT(*) FROM regional_city WHERE n_orders >= 100), 141, 0),
 ('city','kota >= 30 order (roadmap 407)',                          (SELECT COUNT(*) FROM regional_city), 407, 0),
 ('city','% order pada kota >= 100 order (roadmap 67,3)',           (SELECT ROUND(100.0 * SUM(n_orders) FILTER (WHERE n_orders >= 100) / (SELECT COUNT(*) FROM fact_orders), 1) FROM regional_city), 67.3, 0.051),
 ('relative','n order Single-Seller Delivered ber-jarak',            (SELECT COUNT(*) FROM r_dist), NULL, 0),
 ('relative','SUM(n_orders_ber_jarak) per state',                    (SELECT SUM(n_orders_ber_jarak) FROM regional_relative), (SELECT COUNT(*) FROM r_dist), 0);

CREATE OR REPLACE TABLE regional_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM reg_raw;

SELECT status, COUNT(*) AS n_metrik FROM regional_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM regional_findings ORDER BY section, metric;

-- ============================================================
-- 5. Output parquet
-- ============================================================
COPY regional_state    TO 'data/processed/15_regional_state.parquet'    (FORMAT PARQUET);
COPY regional_city     TO 'data/processed/15_regional_city.parquet'     (FORMAT PARQUET);
COPY regional_findings TO 'data/processed/15_regional_findings.parquet' (FORMAT PARQUET);
SELECT '15_regional_state' AS file, COUNT(*) AS n FROM read_parquet('data/processed/15_regional_state.parquet') UNION ALL
SELECT '15_regional_city', COUNT(*) FROM read_parquet('data/processed/15_regional_city.parquet') UNION ALL
SELECT '15_regional_findings', COUNT(*) FROM read_parquet('data/processed/15_regional_findings.parquet');
