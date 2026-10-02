-- ============================================================
-- Tahap 12 — Customer Satisfaction (Review) Analysis
-- File: sql/11_customer_satisfaction.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/11_customer_satisfaction.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (review per order / bulan / kategori / state / seller); dinyatakan di tiap blok
-- POPULATION:  Review Population (dedup 1 review/order, n = 98.673) kecuali disebut;
--              Delivered Population ∩ Review Population (n = 95.824) untuk perbandingan late vs on-time;
--              Revenue Population ∩ Review untuk kategori; Single-Seller Population ∩ Review untuk seller
-- DENOMINATOR: n order ber-review per kelompok (selalu ditampilkan); Order Population untuk rasio order ber-review
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * Avg Review Score = AVG(review_score) pada Review Population (dedup D3).
--   * Late vs on-time WAJIB dua lapis (D4): (1) semua order; (2) distratifikasi menurut answered_before_delivery.
--     Kedua lapis tidak boleh dilebur menjadi satu angka. Bucket keterlambatan dihitung di kedua strata.
--   * Review bersifat ORDER-LEVEL. Skor per kategori disebut "Associated Review Score": skor yang sama menempel
--     ke semua kategori di order itu. Skor per seller hanya dari Single-Seller Population (seller >= 30 order, D6).
--   * Kategori hanya >= 100 order (D6); state ditampilkan semua dengan n (D12, tanpa tiering).
--   * Hubungan antar variabel = asosiasi, bukan kausal; teks komentar tidak dianalisis (NLP di luar scope).
-- Output: data/processed/11_sat_monthly.parquet, 11_sat_findings.parquet
-- ============================================================

CREATE OR REPLACE TEMP TABLE s_rev AS
SELECT o.order_id, o.purchase_date, o.order_status, o.customer_state,
       r.review_score, r.has_comment, r.review_creation_ts, r.review_answer_ts, r.answer_lag_days,
       r.answered_before_delivery,
       o.is_delivered_complete, o.is_late, o.is_revenue_order, o.has_items,
       o.is_multi_seller, o.is_single_seller_pop, o.single_seller_id,
       o.ts_customer, o.ts_estimated,
       CASE WHEN o.is_delivered_complete
            THEN date_diff('day', CAST(o.ts_estimated AS DATE), CAST(o.ts_customer AS DATE)) END AS hari_telat
FROM fact_reviews r JOIN fact_orders o ON o.order_id = r.order_id;

-- ============================================================
-- 1. DISTRIBUSI SKOR, RASIO ORDER BER-REVIEW, TREN BULANAN
-- ============================================================
-- 1.1 Distribusi skor (Review Population)
SELECT review_score, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) AS pct_has_comment
FROM s_rev GROUP BY review_score ORDER BY review_score;

SELECT COUNT(*) AS n_review_population, ROUND(AVG(review_score), 4) AS avg_review_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) AS pct_has_comment
FROM s_rev;

-- 1.2 Rasio order ber-review terhadap Order Population, menurut status
SELECT f.order_status, COUNT(*) AS n_order, COUNT(*) FILTER (WHERE f.has_review) AS n_ber_review,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.has_review) / COUNT(*), 2) AS pct_ber_review
FROM fact_orders f GROUP BY f.order_status ORDER BY n_order DESC;

SELECT COUNT(*) AS order_population, COUNT(*) FILTER (WHERE has_review) AS review_population,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_review) / COUNT(*), 3) AS pct_ber_review
FROM fact_orders;

-- 1.3 Tren bulanan menurut bulan purchase (GRAIN: bulan; semua bulan tampil dengan period_quality)
CREATE OR REPLACE TABLE sat_monthly AS
WITH cal AS (SELECT DISTINCT year_month, period_quality FROM dim_date),
agg AS (
    SELECT d.year_month,
           COUNT(*)                                        AS total_orders,
           COUNT(*) FILTER (WHERE f.has_review)            AS n_reviews,
           AVG(f.review_score)                             AS avg_score,
           COUNT(*) FILTER (WHERE f.review_score = 5)      AS n_5,
           COUNT(*) FILTER (WHERE f.review_score <= 2)     AS n_1_2,
           COUNT(*) FILTER (WHERE f.has_review AND f.is_delivered_complete AND f.is_late) AS n_late_reviewed,
           AVG(f.review_score) FILTER (WHERE f.is_delivered_complete AND NOT f.is_late)   AS avg_score_on_time
    FROM fact_orders f JOIN dim_date d ON d.date_key = f.purchase_date
    GROUP BY d.year_month
)
SELECT c.year_month, c.period_quality, (c.period_quality = 'full') AS show_in_trend,
       COALESCE(a.total_orders, 0) AS total_orders, COALESCE(a.n_reviews, 0) AS n_reviews,
       ROUND(100.0 * a.n_reviews / NULLIF(a.total_orders, 0), 2) AS pct_ber_review,
       ROUND(a.avg_score, 3) AS avg_score,
       ROUND(100.0 * a.n_5   / NULLIF(a.n_reviews, 0), 2) AS pct_skor_5,
       ROUND(100.0 * a.n_1_2 / NULLIF(a.n_reviews, 0), 2) AS pct_skor_1_2,
       COALESCE(a.n_late_reviewed, 0) AS n_late_ber_review,
       ROUND(a.avg_score_on_time, 3)  AS avg_score_order_on_time
FROM cal c LEFT JOIN agg a USING (year_month) ORDER BY c.year_month;

SELECT * FROM sat_monthly ORDER BY year_month;

-- ============================================================
-- 2. REVIEW SCORE vs KETERLAMBATAN — WAJIB DUA LAPIS (D4)
--    POPULATION: Delivered Population ∩ Review Population (n = 95.824). Asosiasi, bukan kausal.
-- ============================================================
-- 2.1 LAPIS 1 — semua order: on-time vs late (tanpa stratifikasi)
SELECT CASE WHEN is_late THEN 'late' ELSE 'on-time' END AS kelompok,
       COUNT(*) AS n_order, ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2
FROM s_rev WHERE is_delivered_complete GROUP BY is_late ORDER BY is_late;

-- 2.2 LAPIS 2 — stratifikasi menurut answered_before_delivery
SELECT is_late, answered_before_delivery, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_dari_delivered_review,
       ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2
FROM s_rev WHERE is_delivered_complete
GROUP BY is_late, answered_before_delivery ORDER BY is_late, answered_before_delivery;

-- 2.3 Efek keterlambatan pasca-terima (hanya review dijawab SETELAH barang tercatat sampai)
SELECT ROUND(AVG(review_score) FILTER (WHERE is_late), 3)     AS avg_late_dijawab_sesudah,
       ROUND(AVG(review_score) FILTER (WHERE NOT is_late), 3) AS avg_ontime_dijawab_sesudah,
       ROUND(AVG(review_score) FILTER (WHERE is_late) - AVG(review_score) FILTER (WHERE NOT is_late), 3) AS selisih_poin
FROM s_rev WHERE is_delivered_complete AND NOT answered_before_delivery;

-- 2.4 Bucket keterlambatan (hari; 1-3, 4-7, >7) di KEDUA strata (dijawab sebelum / sesudah barang sampai)
SELECT CASE WHEN hari_telat <= 0 THEN '0: on-time/early' WHEN hari_telat <= 3 THEN '1: telat 1-3 hari'
            WHEN hari_telat <= 7 THEN '2: telat 4-7 hari' ELSE '3: telat > 7 hari' END AS bucket,
       COUNT(*) AS n_semua, ROUND(AVG(review_score), 3) AS avg_semua,
       COUNT(*) FILTER (WHERE NOT answered_before_delivery) AS n_sesudah,
       ROUND(AVG(review_score) FILTER (WHERE NOT answered_before_delivery), 3) AS avg_sesudah,
       ROUND(100.0 * COUNT(*) FILTER (WHERE NOT answered_before_delivery AND review_score <= 2)
             / NULLIF(COUNT(*) FILTER (WHERE NOT answered_before_delivery), 0), 2) AS pct_1_2_sesudah,
       COUNT(*) FILTER (WHERE answered_before_delivery) AS n_sebelum,
       ROUND(AVG(review_score) FILTER (WHERE answered_before_delivery), 3) AS avg_sebelum,
       ROUND(100.0 * COUNT(*) FILTER (WHERE answered_before_delivery AND review_score <= 2)
             / NULLIF(COUNT(*) FILTER (WHERE answered_before_delivery), 0), 2) AS pct_1_2_sebelum
FROM s_rev WHERE is_delivered_complete GROUP BY 1 ORDER BY 1;

-- 2.5 Rekonsiliasi populasi: jumlah semua sel = Delivered ∩ Review
SELECT COUNT(*) AS delivered_x_review,
       COUNT(*) FILTER (WHERE answered_before_delivery)     AS dijawab_sebelum,
       ROUND(100.0 * COUNT(*) FILTER (WHERE answered_before_delivery) / COUNT(*), 2) AS pct_dijawab_sebelum
FROM s_rev WHERE is_delivered_complete;

-- 2.6 Tren bulanan dua lapis (Analysis Window): avg skor late vs on-time, hanya yang dijawab sesudah barang sampai
SELECT strftime(date_trunc('month', purchase_date), '%Y-%m') AS bulan,
       COUNT(*) FILTER (WHERE is_late) AS n_late, COUNT(*) FILTER (WHERE is_late AND answered_before_delivery) AS n_late_dijawab_sebelum,
       ROUND(AVG(review_score) FILTER (WHERE is_late), 3)                                  AS avg_late_semua,
       ROUND(AVG(review_score) FILTER (WHERE is_late AND NOT answered_before_delivery), 3) AS avg_late_sesudah,
       ROUND(AVG(review_score) FILTER (WHERE NOT is_late), 3)                              AS avg_ontime
FROM s_rev
WHERE is_delivered_complete AND purchase_date >= DATE '2017-01-01' AND purchase_date < DATE '2018-09-01'
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 3. ASSOCIATED REVIEW SCORE per KATEGORI (>= 100 order, D6)
--    Review order-level: order multi-kategori dihitung di tiap kategorinya, jadi skor hanya "terasosiasi".
--    POPULATION: Revenue Population ∩ Review Population (order-kategori unik).
-- ============================================================
CREATE OR REPLACE TEMP TABLE s_cat AS
WITH pr AS (
    SELECT DISTINCT i.order_id, p.category_en_clean AS kategori
    FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id
), nc AS (
    SELECT order_id, COUNT(*) AS n_kategori FROM pr GROUP BY order_id
)
SELECT pr.kategori, COUNT(*) AS n_order,
       ROUND(AVG(s.review_score), 3) AS associated_avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2,
       COUNT(*) FILTER (WHERE nc.n_kategori = 1) AS n_order_satu_kategori,
       ROUND(AVG(s.review_score) FILTER (WHERE nc.n_kategori = 1), 3) AS avg_satu_kategori,
       ROUND(AVG(s.review_score) FILTER (WHERE s.is_delivered_complete AND NOT s.is_late), 3) AS avg_order_on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.is_delivered_complete AND s.is_late)
             / NULLIF(COUNT(*) FILTER (WHERE s.is_delivered_complete), 0), 3) AS late_rate_pct
FROM pr JOIN nc ON nc.order_id = pr.order_id
JOIN s_rev s ON s.order_id = pr.order_id
WHERE s.is_revenue_order
GROUP BY pr.kategori HAVING COUNT(*) >= 100;

SELECT 'terendah' AS urutan, * FROM (SELECT * FROM s_cat ORDER BY associated_avg_score ASC LIMIT 10)
UNION ALL
SELECT 'tertinggi', * FROM (SELECT * FROM s_cat ORDER BY associated_avg_score DESC LIMIT 10)
ORDER BY urutan DESC, associated_avg_score;

SELECT COUNT(*) AS n_kategori_ge_100, ROUND(MIN(associated_avg_score), 3) AS min_avg, ROUND(MAX(associated_avg_score), 3) AS max_avg,
       ROUND(quantile_cont(associated_avg_score, 0.5), 3) AS median_avg,
       ROUND(corr(associated_avg_score, late_rate_pct), 3) AS r_skor_vs_late_rate
FROM s_cat;

-- 3.1 Pengaruh bauran multi-kategori terhadap skor kategori (order satu kategori vs semua order)
SELECT ROUND(AVG(ABS(associated_avg_score - avg_satu_kategori)), 3) AS rata2_selisih_mutlak,
       ROUND(MAX(ABS(associated_avg_score - avg_satu_kategori)), 3) AS selisih_maks
FROM s_cat WHERE avg_satu_kategori IS NOT NULL;

-- ============================================================
-- 4. REVIEW SCORE per STATE (semua 27 state, n selalu ditampilkan; tanpa tiering, D12)
--    POPULATION: Review Population (order-level; tidak butuh item)
-- ============================================================
SELECT customer_state AS state, COUNT(*) AS n_order_ber_review,
       ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2,
       ROUND(AVG(review_score) FILTER (WHERE is_delivered_complete AND NOT is_late), 3) AS avg_order_on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_delivered_complete AND is_late)
             / NULLIF(COUNT(*) FILTER (WHERE is_delivered_complete), 0), 3) AS late_rate_pct
FROM s_rev GROUP BY customer_state ORDER BY n_order_ber_review DESC;

SELECT ROUND(corr(avg_score, late_rate_pct), 3) AS r_state_skor_vs_late_rate
FROM (SELECT AVG(review_score) AS avg_score,
             100.0 * COUNT(*) FILTER (WHERE is_delivered_complete AND is_late)
             / NULLIF(COUNT(*) FILTER (WHERE is_delivered_complete), 0) AS late_rate_pct
      FROM s_rev GROUP BY customer_state);

-- ============================================================
-- 5. REVIEW SCORE per SELLER (Single-Seller Population ∩ Review; seller >= 30 order, D6)
--    Atribusi seller tanpa ambigu hanya untuk order satu seller.
-- ============================================================
CREATE OR REPLACE TEMP TABLE s_seller AS
SELECT s.single_seller_id AS seller_id, ANY_VALUE(d.seller_state) AS seller_state,
       COUNT(*) AS n_order_ber_review,
       ROUND(AVG(s.review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2,
       COUNT(*) FILTER (WHERE s.is_delivered_complete) AS n_delivered,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.is_delivered_complete AND s.is_late)
             / NULLIF(COUNT(*) FILTER (WHERE s.is_delivered_complete), 0), 3) AS late_rate_pct
FROM s_rev s JOIN dim_seller d ON d.seller_id = s.single_seller_id
WHERE s.is_single_seller_pop
GROUP BY s.single_seller_id HAVING COUNT(*) >= 30;

SELECT COUNT(*) AS n_seller_ge_30, SUM(n_order_ber_review) AS n_order_tercakup,
       ROUND(100.0 * SUM(n_order_ber_review) / (SELECT COUNT(*) FROM s_rev WHERE is_single_seller_pop), 2) AS pct_single_seller_review_tercakup,
       ROUND(quantile_cont(avg_score, 0.1), 3) AS p10_avg, ROUND(quantile_cont(avg_score, 0.5), 3) AS p50_avg,
       ROUND(quantile_cont(avg_score, 0.9), 3) AS p90_avg,
       ROUND(corr(avg_score, late_rate_pct), 3) AS r_seller_skor_vs_late_rate
FROM s_seller;

SELECT 'terendah' AS urutan, * FROM (SELECT * FROM s_seller ORDER BY avg_score ASC, n_order_ber_review DESC LIMIT 15)
UNION ALL
SELECT 'tertinggi', * FROM (SELECT * FROM s_seller ORDER BY avg_score DESC, n_order_ber_review DESC LIMIT 10)
ORDER BY urutan DESC, avg_score;

-- ============================================================
-- 6. BUKTI CAVEAT ORDER-LEVEL: skor order multi-seller vs single-seller (order ber-item)
-- ============================================================
SELECT CASE WHEN is_multi_seller THEN 'multi-seller' ELSE 'single-seller' END AS jenis_order,
       COUNT(*) AS n_order_ber_review, ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS pct_skor_1_2
FROM s_rev WHERE has_items GROUP BY is_multi_seller ORDER BY is_multi_seller;

-- ============================================================
-- 7. RASIO KOMENTAR dan WAKTU SURVEI
-- ============================================================
-- 7.1 Rasio komentar per skor (has_comment) dan skor menurut ada/tidaknya komentar
SELECT review_score, COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE has_comment) AS n_ber_komentar,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) AS pct_ber_komentar
FROM s_rev GROUP BY review_score ORDER BY review_score;

SELECT has_comment, COUNT(*) AS n_order, ROUND(AVG(review_score), 3) AS avg_score
FROM s_rev GROUP BY has_comment ORDER BY has_comment;

-- 7.2 Jeda review_creation -> review_answer (hari)
SELECT COUNT(*) AS n,
       ROUND(quantile_cont(answer_lag_days, 0.5), 2)  AS p50, ROUND(quantile_cont(answer_lag_days, 0.75), 2) AS p75,
       ROUND(quantile_cont(answer_lag_days, 0.95), 2) AS p95, ROUND(MAX(answer_lag_days), 1) AS max,
       COUNT(*) FILTER (WHERE answer_lag_days < 1) AS n_dijawab_kurang_1_hari
FROM s_rev;

SELECT CASE WHEN answer_lag_days < 1 THEN '1: < 1 hari' WHEN answer_lag_days < 2 THEN '2: 1-2 hari'
            WHEN answer_lag_days < 7 THEN '3: 2-7 hari' WHEN answer_lag_days < 30 THEN '4: 7-30 hari'
            ELSE '5: >= 30 hari' END AS jeda_jawab,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(AVG(review_score), 3) AS avg_score
FROM s_rev GROUP BY 1 ORDER BY 1;

-- 7.3 Makna review_creation_date: tanggal survei relatif terhadap tanggal barang tercatat sampai (hari)
--     Delivered Population ∩ Review. Jika kolom = tanggal survei dikirim, mayoritas jatuh 0-2 hari setelah sampai
--     (untuk order yang terlambat, survei dapat terkirim sebelum barang sampai).
SELECT CASE WHEN dd < 0 THEN '1: sebelum tanggal sampai' WHEN dd = 0 THEN '2: hari sampai'
            WHEN dd = 1 THEN '3: +1 hari' WHEN dd = 2 THEN '4: +2 hari'
            WHEN dd <= 7 THEN '5: +3..7 hari' ELSE '6: > 7 hari' END AS survei_vs_tanggal_sampai,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT date_diff('day', CAST(ts_customer AS DATE), CAST(review_creation_ts AS DATE)) AS dd
      FROM s_rev WHERE is_delivered_complete)
GROUP BY 1 ORDER BY 1;

SELECT ROUND(quantile_cont(date_diff('day', CAST(ts_customer AS DATE), CAST(review_creation_ts AS DATE)), 0.5), 1) AS median_hari_survei_setelah_sampai,
       ROUND(quantile_cont(date_diff('day', CAST(ts_customer AS DATE), CAST(review_creation_ts AS DATE)), 0.25), 1) AS p25,
       ROUND(quantile_cont(date_diff('day', CAST(ts_customer AS DATE), CAST(review_creation_ts AS DATE)), 0.75), 1) AS p75
FROM s_rev WHERE is_delivered_complete;

-- 7.4 Untuk review yang dijawab SEBELUM barang sampai: survei dikirim relatif terhadap tanggal ESTIMASI (hari)
SELECT COUNT(*) AS n,
       ROUND(quantile_cont(date_diff('day', CAST(ts_estimated AS DATE), CAST(review_creation_ts AS DATE)), 0.5), 1) AS median_hari_survei_vs_estimasi,
       ROUND(quantile_cont(date_diff('day', CAST(ts_estimated AS DATE), CAST(review_creation_ts AS DATE)), 0.25), 1) AS p25,
       ROUND(quantile_cont(date_diff('day', CAST(ts_estimated AS DATE), CAST(review_creation_ts AS DATE)), 0.75), 1) AS p75,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_creation_ts >= ts_estimated) / COUNT(*), 2) AS pct_survei_pada_atau_setelah_estimasi
FROM s_rev WHERE is_delivered_complete AND answered_before_delivery;

-- ============================================================
-- 8. Reconcile ke KPI terkunci / referensi roadmap -> sat_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE sat_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO sat_raw VALUES
 ('reconcile','Review Population (order ber-review)',          (SELECT COUNT(*) FROM s_rev), 98673, 0),
 ('reconcile','Review Population = order has_review di fact_orders', (SELECT COUNT(*) FROM fact_orders WHERE has_review), 98673, 0),
 ('reconcile','SUM(n_reviews) bulanan = Review Population',    (SELECT SUM(n_reviews) FROM sat_monthly), 98673, 0),
 ('reconcile','SUM(n per skor) = Review Population',           (SELECT COUNT(*) FROM s_rev WHERE review_score BETWEEN 1 AND 5), 98673, 0),
 ('reconcile','Avg Review Score (terkunci Tahap 6)',           (SELECT ROUND(AVG(review_score), 4) FROM s_rev), 4.0864, 0.00011),
 ('reconcile','% order ber-review terhadap Order Population',  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE has_review) / COUNT(*), 3) FROM fact_orders), 99.228, 0.0011),
 ('reconcile','order tanpa review',                            (SELECT COUNT(*) FROM fact_orders WHERE NOT has_review), 768, 0),
 ('dist','% skor 1',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 1) / COUNT(*), 2) FROM s_rev), 11.52, 0.011),
 ('dist','% skor 2',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 2) / COUNT(*), 2) FROM s_rev), 3.17, 0.011),
 ('dist','% skor 3',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 3) / COUNT(*), 2) FROM s_rev), 8.24, 0.011),
 ('dist','% skor 4',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 4) / COUNT(*), 2) FROM s_rev), 19.29, 0.011),
 ('dist','% skor 5',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 5) / COUNT(*), 2) FROM s_rev), 57.77, 0.011),
 ('d4','Delivered x Review (n)',                               (SELECT COUNT(*) FROM s_rev WHERE is_delivered_complete), 95824, 0),
 ('d4','LAPIS 1: on-time avg skor (semua)',                    (SELECT ROUND(AVG(review_score), 2) FROM s_rev WHERE is_delivered_complete AND NOT is_late), 4.29, 0.011),
 ('d4','LAPIS 1: late avg skor (semua)',                       (SELECT ROUND(AVG(review_score), 2) FROM s_rev WHERE is_delivered_complete AND is_late), 2.27, 0.011),
 ('d4','LAPIS 2: late & dijawab sebelum - n',                  (SELECT COUNT(*) FROM s_rev WHERE is_delivered_complete AND is_late AND answered_before_delivery), 4473, 0),
 ('d4','LAPIS 2: late & dijawab sebelum - avg',                (SELECT ROUND(AVG(review_score), 3) FROM s_rev WHERE is_delivered_complete AND is_late AND answered_before_delivery), 1.652, 0.0011),
 ('d4','LAPIS 2: late & dijawab sebelum - % skor 1-2',         (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) FROM s_rev WHERE is_delivered_complete AND is_late AND answered_before_delivery), 80.75, 0.011),
 ('d4','LAPIS 2: late & dijawab sesudah - n',                  (SELECT COUNT(*) FROM s_rev WHERE is_delivered_complete AND is_late AND NOT answered_before_delivery), 1908, 0),
 ('d4','LAPIS 2: late & dijawab sesudah - avg',                (SELECT ROUND(AVG(review_score), 3) FROM s_rev WHERE is_delivered_complete AND is_late AND NOT answered_before_delivery), 3.72, 0.0011),
 ('d4','LAPIS 2: late & dijawab sesudah - % skor 1-2',         (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) FROM s_rev WHERE is_delivered_complete AND is_late AND NOT answered_before_delivery), 19.44, 0.011),
 ('d4','LAPIS 2: on-time & dijawab sesudah - n',               (SELECT COUNT(*) FROM s_rev WHERE is_delivered_complete AND NOT is_late AND NOT answered_before_delivery), 89263, 0),
 ('d4','LAPIS 2: on-time & dijawab sesudah - avg',             (SELECT ROUND(AVG(review_score), 3) FROM s_rev WHERE is_delivered_complete AND NOT is_late AND NOT answered_before_delivery), 4.291, 0.0011),
 ('d4','LAPIS 2: on-time & dijawab sesudah - % skor 1-2',      (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) FROM s_rev WHERE is_delivered_complete AND NOT is_late AND NOT answered_before_delivery), 9.25, 0.011),
 ('d4','LAPIS 2: on-time & dijawab sebelum - n',               (SELECT COUNT(*) FROM s_rev WHERE is_delivered_complete AND NOT is_late AND answered_before_delivery), 180, 0),
 ('d4','efek keterlambatan pasca-terima (poin)',               (SELECT ROUND(AVG(review_score) FILTER (WHERE is_late) - AVG(review_score) FILTER (WHERE NOT is_late), 2) FROM s_rev WHERE is_delivered_complete AND NOT answered_before_delivery), -0.57, 0.011),
 ('d4','% dijawab sebelum barang sampai (Delivered x Review)', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE answered_before_delivery) / COUNT(*), 2) FROM s_rev WHERE is_delivered_complete), 4.86, 0.011),
 ('d4','jumlah bucket keterlambatan = Delivered x Review',     (SELECT COUNT(*) FROM s_rev WHERE is_delivered_complete AND hari_telat IS NOT NULL), 95824, 0),
 ('comment','% skor 1 ber-komentar (dedup; roadmap 76,55 = referensi baris mentah)', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment AND review_score = 1) / COUNT(*) FILTER (WHERE review_score = 1), 2) FROM s_rev), 76.61, 0.011),
 ('comment','% seluruh review ber-komentar',                   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE has_comment) / COUNT(*), 2) FROM s_rev), 41.30, 0.011),
 ('survey','jeda jawab median (hari)',                         (SELECT ROUND(quantile_cont(answer_lag_days, 0.5), 2) FROM s_rev), 1.68, 0.011),
 ('survey','jeda jawab P95 (hari)',                            (SELECT ROUND(quantile_cont(answer_lag_days, 0.95), 2) FROM s_rev), 6.98, 0.011),
 ('survey','median survei dikirim setelah tanggal sampai (hari; roadmap: 1)',
        (SELECT quantile_cont(date_diff('day', CAST(ts_customer AS DATE), CAST(review_creation_ts AS DATE)), 0.5) FROM s_rev WHERE is_delivered_complete), 1, 0.51),
 ('category','n kategori >= 100 order (Review x Revenue)',     (SELECT COUNT(*) FROM s_cat), NULL, 0),
 ('seller','n seller >= 30 order (Single-Seller x Review)',    (SELECT COUNT(*) FROM s_seller), NULL, 0),
 ('caveat','avg skor multi-seller (order ber-item)',           (SELECT ROUND(AVG(review_score), 3) FROM s_rev WHERE has_items AND is_multi_seller), NULL, 0),
 ('caveat','avg skor single-seller (order ber-item)',          (SELECT ROUND(AVG(review_score), 3) FROM s_rev WHERE has_items AND NOT is_multi_seller), NULL, 0);

CREATE OR REPLACE TABLE sat_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM sat_raw;

SELECT status, COUNT(*) AS n_metrik FROM sat_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM sat_findings ORDER BY section, metric;

-- ============================================================
-- 9. Output parquet
-- ============================================================
COPY sat_monthly  TO 'data/processed/11_sat_monthly.parquet'  (FORMAT PARQUET);
COPY sat_findings TO 'data/processed/11_sat_findings.parquet' (FORMAT PARQUET);
SELECT '11_sat_monthly' AS file, COUNT(*) AS n FROM read_parquet('data/processed/11_sat_monthly.parquet') UNION ALL
SELECT '11_sat_findings', COUNT(*) FROM read_parquet('data/processed/11_sat_findings.parquet');
