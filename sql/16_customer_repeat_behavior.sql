-- ============================================================
-- Tahap 17 — Customer Repeat Behavior (Deskriptif)
-- File: sql/16_customer_repeat_behavior.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/16_customer_repeat_behavior.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (pelanggan / order / pasangan order berurutan / cohort bulan / state); dinyatakan di tiap blok
-- POPULATION:  Customer Population (customer_unique_id, n = 96.096); cohort 2017-01..2018-05 untuk 90-day Repeat Rate
-- DENOMINATOR: Customer Population untuk Repeat Rate; jumlah pelanggan cohort untuk rate cohort; n selalu ditampilkan
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * Repeat Rate (headline, D5) = pelanggan dengan order >= 24 jam setelah order pertama / Customer Population.
--   * Repeat mentah (>= 2 order) hanya metrik Data Quality; order < 24 jam dari order pertama adalah SESI BELANJA
--     YANG SAMA dan dilaporkan terpisah (bukan repeat).
--   * Perbandingan antar cohort hanya pada window tetap (30/90/180 hari) dan hanya untuk pelanggan yang punya
--     observasi penuh (first_order + window <= tanggal snapshot); cohort 2018 terpotong (right-censoring).
--   * Lokasi pelanggan = state pada ORDER PERTAMA (aturan tertulis; 39 pelanggan multi-state).
--   * TIDAK ADA klaim CLV, churn, prediksi, atau segmentasi RFM klasik. Hubungan antar variabel = asosiasi.
-- Output: data/processed/16_repeat_monthly.parquet, 16_repeat_cohort.parquet, 16_repeat_findings.parquet
-- ============================================================

-- 0. Helper: urutan order per pelanggan, tanggal snapshot, dan order kembali pertama (>= 24 jam)
CREATE OR REPLACE TEMP TABLE rp_snap AS SELECT MAX(ts_purchase) AS snap_ts FROM fact_orders;

CREATE OR REPLACE TEMP TABLE rp_seq AS
SELECT customer_unique_id, order_id, ts_purchase, order_status, purchase_date,
       ROW_NUMBER() OVER w AS rn,
       MIN(ts_purchase) OVER (PARTITION BY customer_unique_id) AS first_ts,
       LAG(ts_purchase) OVER w AS prev_ts,
       LAG(order_id)    OVER w AS prev_order
FROM fact_orders
WINDOW w AS (PARTITION BY customer_unique_id ORDER BY ts_purchase, order_id);

CREATE OR REPLACE TEMP TABLE rp_cust AS
SELECT d.customer_unique_id, d.n_orders_raw, d.first_order_ts AS first_ts, d.first_order_id,
       d.state_first_order, d.state_latest_order, d.flag_multi_state,
       d.is_repeat_customer, d.is_repeat_raw,
       (SELECT MIN(s.ts_purchase) FROM rp_seq s
        WHERE s.customer_unique_id = d.customer_unique_id AND s.ts_purchase >= d.first_order_ts + INTERVAL 24 HOUR) AS return_ts
FROM dim_customer d;

-- ============================================================
-- 1. DISTRIBUSI JUMLAH ORDER per PELANGGAN dan REPEAT RATE (D5)
-- ============================================================
-- 1.1 Distribusi n order per customer_unique_id (Customer Population)
SELECT n_orders_raw AS n_order, COUNT(*) AS n_pelanggan,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3) AS pct
FROM rp_cust GROUP BY n_orders_raw ORDER BY n_orders_raw;

-- 1.2 Repeat Rate (>= 24 jam), repeat mentah, dan sesi yang sama (< 24 jam)
SELECT COUNT(*)                                          AS customer_population,
       COUNT(*) FILTER (WHERE is_repeat_customer)        AS repeat_ge_24_jam,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct,
       COUNT(*) FILTER (WHERE is_repeat_raw)             AS repeat_mentah,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw) / COUNT(*), 3) AS repeat_mentah_pct,
       COUNT(*) FILTER (WHERE is_repeat_raw AND NOT is_repeat_customer) AS hanya_order_lt_24_jam,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw AND NOT is_repeat_customer)
             / NULLIF(COUNT(*) FILTER (WHERE is_repeat_raw), 0), 1) AS pct_dari_repeat_mentah
FROM rp_cust;

-- 1.3 Pelanggan yang hanya punya order dalam < 24 jam: sesi belanja yang sama (pasangan order berurutan < 1 jam)
SELECT COUNT(*) AS n_pasangan_lt_1_jam,
       COUNT(*) FILTER (WHERE gap_detik = 0) AS n_detik_yang_sama
FROM (SELECT date_diff('second', prev_ts, ts_purchase) AS gap_detik FROM rp_seq WHERE rn >= 2)
WHERE gap_detik < 3600;

CREATE OR REPLACE TEMP TABLE rp_sellers AS
SELECT order_id, list_sort(list_distinct(list(seller_id))) AS sellers FROM fact_order_items GROUP BY order_id;

SELECT CASE WHEN b.sellers IS NULL OR a.sellers IS NULL THEN 'salah satu order tanpa item'
            WHEN a.sellers = b.sellers THEN 'seller-set sama' ELSE 'seller-set beda' END AS jenis_pasangan,
       COUNT(*) AS n_pasangan
FROM (SELECT s.order_id, s.prev_order FROM rp_seq s
      WHERE s.rn >= 2 AND date_diff('second', s.prev_ts, s.ts_purchase) < 3600) p
LEFT JOIN rp_sellers a ON a.order_id = p.order_id
LEFT JOIN rp_sellers b ON b.order_id = p.prev_order
GROUP BY 1 ORDER BY n_pasangan DESC;

-- 1.4 Sebaran jeda pasangan berurutan < 24 jam
SELECT CASE WHEN gap_detik = 0 THEN '1: detik yang sama' WHEN gap_detik < 60 THEN '2: < 1 menit'
            WHEN gap_detik < 3600 THEN '3: 1-59 menit' WHEN gap_detik < 21600 THEN '4: 1-5,9 jam'
            ELSE '5: 6-23,9 jam' END AS jeda,
       COUNT(*) AS n_pasangan
FROM (SELECT date_diff('second', prev_ts, ts_purchase) AS gap_detik FROM rp_seq WHERE rn >= 2)
WHERE gap_detik < 86400 GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 2. JEDA ANTAR ORDER
-- ============================================================
-- 2.1 Jeda antar order BERURUTAN (semua pasangan dan setelah mengeluarkan pasangan < 24 jam), dalam hari
SELECT 'semua pasangan berurutan' AS kelompok, COUNT(*) AS n_pasangan,
       ROUND(quantile_cont(gap_hari, 0.5), 2) AS median, ROUND(quantile_cont(gap_hari, 0.25), 2) AS p25,
       ROUND(quantile_cont(gap_hari, 0.75), 2) AS p75, ROUND(quantile_cont(gap_hari, 0.9), 2) AS p90, ROUND(AVG(gap_hari), 2) AS mean
FROM (SELECT date_diff('second', prev_ts, ts_purchase) / 86400.0 AS gap_hari FROM rp_seq WHERE rn >= 2)
UNION ALL
SELECT 'pasangan >= 24 jam', COUNT(*), ROUND(quantile_cont(gap_hari, 0.5), 2), ROUND(quantile_cont(gap_hari, 0.25), 2),
       ROUND(quantile_cont(gap_hari, 0.75), 2), ROUND(quantile_cont(gap_hari, 0.9), 2), ROUND(AVG(gap_hari), 2)
FROM (SELECT date_diff('second', prev_ts, ts_purchase) / 86400.0 AS gap_hari FROM rp_seq WHERE rn >= 2)
WHERE gap_hari >= 1;

-- 2.2 Waktu dari order pertama ke order kembali pertama (>= 24 jam), pelanggan repeat (D5), dalam hari
SELECT COUNT(*) AS n_pelanggan_repeat,
       ROUND(quantile_cont(h, 0.5), 1) AS median, ROUND(quantile_cont(h, 0.25), 1) AS p25, ROUND(quantile_cont(h, 0.75), 1) AS p75,
       ROUND(quantile_cont(h, 0.9), 1) AS p90, ROUND(AVG(h), 1) AS mean, ROUND(MAX(h), 1) AS maks
FROM (SELECT date_diff('second', first_ts, return_ts) / 86400.0 AS h FROM rp_cust WHERE return_ts IS NOT NULL);

SELECT CASE WHEN h < 7 THEN '1: 1-6 hari' WHEN h < 30 THEN '2: 7-29 hari' WHEN h < 90 THEN '3: 30-89 hari'
            WHEN h < 180 THEN '4: 90-179 hari' WHEN h < 365 THEN '5: 180-364 hari' ELSE '6: >= 365 hari' END AS waktu_ke_order_kembali,
       COUNT(*) AS n_pelanggan, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT date_diff('second', first_ts, return_ts) / 86400.0 AS h FROM rp_cust WHERE return_ts IS NOT NULL)
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 3. 90-DAY REPEAT RATE (D5; cohort order pertama 2017-01..2018-05) dan WINDOW TETAP lain
-- ============================================================
-- 3.1 Headline 90-day Repeat Rate: repeat 24 jam..90 hari; cohort bulan order pertama 2017-01..2018-05
SELECT COUNT(*) AS n_cohort,
       COUNT(*) FILTER (WHERE return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 90 DAY) AS n_repeat_90d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 90 DAY) / COUNT(*), 3) AS repeat_90d_pct
FROM rp_cust WHERE first_ts >= TIMESTAMP '2017-01-01' AND first_ts < TIMESTAMP '2018-06-01';

-- 3.2 Cohort bulanan: ukuran cohort, repeat mentah (waktu apa pun), repeat >= 24 jam, dan window tetap 30/90/180 hari
--     (rate window tetap hanya pada pelanggan dengan observasi penuh: first_ts + window <= snapshot)
CREATE OR REPLACE TABLE repeat_cohort AS
WITH c AS (
    SELECT strftime(first_ts, '%Y-%m') AS cohort,
           COUNT(*) AS n_pelanggan,
           COUNT(*) FILTER (WHERE is_repeat_raw)       AS n_repeat_mentah_kapan_pun,
           COUNT(*) FILTER (WHERE is_repeat_customer)  AS n_repeat_ge_24h_kapan_pun,
           COUNT(*) FILTER (WHERE first_ts + INTERVAL 30 DAY <= (SELECT snap_ts FROM rp_snap)) AS elig_30,
           COUNT(*) FILTER (WHERE first_ts + INTERVAL 30 DAY <= (SELECT snap_ts FROM rp_snap)
                              AND return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 30 DAY) AS rep_30,
           COUNT(*) FILTER (WHERE first_ts + INTERVAL 90 DAY <= (SELECT snap_ts FROM rp_snap)) AS elig_90,
           COUNT(*) FILTER (WHERE first_ts + INTERVAL 90 DAY <= (SELECT snap_ts FROM rp_snap)
                              AND return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 90 DAY) AS rep_90,
           COUNT(*) FILTER (WHERE first_ts + INTERVAL 180 DAY <= (SELECT snap_ts FROM rp_snap)) AS elig_180,
           COUNT(*) FILTER (WHERE first_ts + INTERVAL 180 DAY <= (SELECT snap_ts FROM rp_snap)
                              AND return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 180 DAY) AS rep_180
    FROM rp_cust GROUP BY 1
), cal AS (SELECT DISTINCT year_month, period_quality FROM dim_date)
SELECT cal.year_month AS cohort, cal.period_quality,
       COALESCE(c.n_pelanggan, 0) AS n_pelanggan,
       ROUND(100.0 * c.n_repeat_mentah_kapan_pun / NULLIF(c.n_pelanggan, 0), 2) AS pct_repeat_mentah_kapan_pun,
       ROUND(100.0 * c.n_repeat_ge_24h_kapan_pun / NULLIF(c.n_pelanggan, 0), 3) AS pct_repeat_ge_24h_kapan_pun,
       c.elig_30, c.rep_30, ROUND(100.0 * c.rep_30 / NULLIF(c.elig_30, 0), 3) AS repeat_30d_pct,
       c.elig_90, c.rep_90, ROUND(100.0 * c.rep_90 / NULLIF(c.elig_90, 0), 3) AS repeat_90d_pct,
       c.elig_180, c.rep_180, ROUND(100.0 * c.rep_180 / NULLIF(c.elig_180, 0), 3) AS repeat_180d_pct,
       (c.n_pelanggan < 500) AS cohort_kecil
FROM cal LEFT JOIN c ON c.cohort = cal.year_month ORDER BY cal.year_month;

SELECT cohort, period_quality, n_pelanggan, pct_repeat_mentah_kapan_pun, pct_repeat_ge_24h_kapan_pun,
       repeat_30d_pct, repeat_90d_pct, repeat_180d_pct, cohort_kecil
FROM repeat_cohort ORDER BY cohort;

-- 3.3 Ringkasan window tetap pada cohort Analysis Window (pelanggan dengan observasi penuh)
SELECT 30 AS window_hari, SUM(elig_30) AS n_eligible, SUM(rep_30) AS n_repeat, ROUND(100.0 * SUM(rep_30) / SUM(elig_30), 3) AS repeat_pct
FROM repeat_cohort WHERE cohort >= '2017-01' AND cohort <= '2018-08'
UNION ALL
SELECT 90, SUM(elig_90), SUM(rep_90), ROUND(100.0 * SUM(rep_90) / SUM(elig_90), 3) FROM repeat_cohort WHERE cohort >= '2017-01' AND cohort <= '2018-08'
UNION ALL
SELECT 180, SUM(elig_180), SUM(rep_180), ROUND(100.0 * SUM(rep_180) / SUM(elig_180), 3) FROM repeat_cohort WHERE cohort >= '2017-01' AND cohort <= '2018-08';

-- ============================================================
-- 4. NEW vs RETURNING per BULAN (Analysis Window; tabel `repeat_monthly`)
--    new = order pertama pelanggan; returning = order >= 24 jam setelah order pertama;
--    sesi sama = order berikutnya dalam < 24 jam dari order pertama.
-- ============================================================
CREATE OR REPLACE TABLE repeat_monthly AS
WITH o AS (
    SELECT d.year_month, s.customer_unique_id,
           CASE WHEN s.rn = 1 THEN 'new'
                WHEN s.ts_purchase >= s.first_ts + INTERVAL 24 HOUR THEN 'returning'
                ELSE 'sesi_sama' END AS jenis
    FROM rp_seq s JOIN dim_date d ON d.date_key = s.purchase_date
), agg AS (
    SELECT year_month, COUNT(*) AS n_orders,
           COUNT(*) FILTER (WHERE jenis = 'new') AS n_new,
           COUNT(*) FILTER (WHERE jenis = 'returning') AS n_returning,
           COUNT(*) FILTER (WHERE jenis = 'sesi_sama') AS n_sesi_sama,
           COUNT(DISTINCT customer_unique_id) AS n_pelanggan_aktif,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE jenis = 'returning') AS n_pelanggan_returning
    FROM o GROUP BY year_month
), cal AS (SELECT DISTINCT year_month, period_quality FROM dim_date)
SELECT cal.year_month, cal.period_quality, (cal.period_quality = 'full') AS show_in_trend,
       COALESCE(a.n_orders, 0) AS n_orders, COALESCE(a.n_new, 0) AS n_new,
       COALESCE(a.n_returning, 0) AS n_returning, COALESCE(a.n_sesi_sama, 0) AS n_sesi_sama,
       ROUND(100.0 * a.n_returning / NULLIF(a.n_orders, 0), 3) AS pct_order_returning,
       COALESCE(a.n_pelanggan_aktif, 0) AS n_pelanggan_aktif, COALESCE(a.n_pelanggan_returning, 0) AS n_pelanggan_returning,
       ROUND(100.0 * a.n_pelanggan_returning / NULLIF(a.n_pelanggan_aktif, 0), 3) AS pct_pelanggan_returning
FROM cal LEFT JOIN agg a USING (year_month) ORDER BY cal.year_month;

SELECT * FROM repeat_monthly ORDER BY year_month;

SELECT SUM(n_orders) AS n_orders, SUM(n_new) AS n_new, SUM(n_returning) AS n_returning, SUM(n_sesi_sama) AS n_sesi_sama,
       ROUND(100.0 * SUM(n_returning) / SUM(n_orders), 3) AS pct_order_returning
FROM repeat_monthly;

-- ============================================================
-- 5. KATEGORI & PENGALAMAN ORDER PERTAMA: repeat vs non-repeat (deskriptif; bukan prediktor)
-- ============================================================
-- 5.1 Kategori pada order pertama: porsi di pelanggan repeat vs non-repeat dan repeat rate per kategori (>= 100 pelanggan)
CREATE OR REPLACE TEMP TABLE rp_fo_cat AS
SELECT DISTINCT c.customer_unique_id, c.is_repeat_customer, p.category_en_clean AS kategori
FROM rp_cust c
JOIN fact_order_items i ON i.order_id = c.first_order_id
JOIN dim_product p ON p.product_id = i.product_id;

CREATE OR REPLACE TEMP TABLE rp_fo_n AS
SELECT COUNT(DISTINCT customer_unique_id) AS n_all,
       COUNT(DISTINCT customer_unique_id) FILTER (WHERE is_repeat_customer) AS n_rep,
       COUNT(DISTINCT customer_unique_id) FILTER (WHERE NOT is_repeat_customer) AS n_non
FROM rp_fo_cat;

SELECT * FROM rp_fo_n;

CREATE OR REPLACE TEMP TABLE rp_cat_rate AS
SELECT kategori, COUNT(*) AS n_pelanggan,
       COUNT(*) FILTER (WHERE is_repeat_customer) AS n_repeat,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / (SELECT n_rep FROM rp_fo_n), 2) AS pct_dari_semua_repeat,
       ROUND(100.0 * COUNT(*) FILTER (WHERE NOT is_repeat_customer) / (SELECT n_non FROM rp_fo_n), 2) AS pct_dari_semua_nonrepeat
FROM rp_fo_cat GROUP BY kategori HAVING COUNT(*) >= 100;

SELECT 'repeat rate tertinggi' AS urutan, * FROM (SELECT * FROM rp_cat_rate ORDER BY repeat_rate_pct DESC LIMIT 10)
UNION ALL
SELECT 'repeat rate terendah', * FROM (SELECT * FROM rp_cat_rate ORDER BY repeat_rate_pct ASC LIMIT 10)
ORDER BY urutan DESC, repeat_rate_pct DESC;

SELECT 'porsi terbesar di pelanggan repeat' AS urutan, kategori, n_pelanggan, n_repeat, pct_dari_semua_repeat, pct_dari_semua_nonrepeat,
       ROUND(pct_dari_semua_repeat / NULLIF(pct_dari_semua_nonrepeat, 0), 2) AS rasio_repeat_vs_non
FROM (SELECT * FROM rp_cat_rate ORDER BY pct_dari_semua_repeat DESC LIMIT 10)
ORDER BY pct_dari_semua_repeat DESC;

-- 5.2 Pengalaman order pertama: skor review, keterlambatan, status (repeat rate menurut kondisi order pertama)
SELECT COALESCE(CAST(f.review_score AS VARCHAR), 'tanpa review') AS skor_order_pertama,
       COUNT(*) AS n_pelanggan, COUNT(*) FILTER (WHERE c.is_repeat_customer) AS n_repeat,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct
FROM rp_cust c JOIN fact_orders f ON f.order_id = c.first_order_id
GROUP BY 1 ORDER BY 1;

SELECT CASE WHEN f.is_delivered_complete AND f.is_late THEN 'terkirim, telat'
            WHEN f.is_delivered_complete THEN 'terkirim, tepat waktu' ELSE 'belum/tidak terkirim' END AS order_pertama,
       COUNT(*) AS n_pelanggan, COUNT(*) FILTER (WHERE c.is_repeat_customer) AS n_repeat,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct
FROM rp_cust c JOIN fact_orders f ON f.order_id = c.first_order_id GROUP BY 1 ORDER BY 1;

SELECT f.order_status AS status_order_pertama, COUNT(*) AS n_pelanggan, COUNT(*) FILTER (WHERE c.is_repeat_customer) AS n_repeat,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct
FROM rp_cust c JOIN fact_orders f ON f.order_id = c.first_order_id GROUP BY 1 ORDER BY n_pelanggan DESC;

-- 5.3 Nilai order pertama (Item Revenue) dan repeat rate (order pertama ber-item)
SELECT CASE WHEN f.item_revenue < 50 THEN '1: < 50' WHEN f.item_revenue < 100 THEN '2: 50-99' WHEN f.item_revenue < 200 THEN '3: 100-199'
            WHEN f.item_revenue < 500 THEN '4: 200-499' ELSE '5: >= 500' END AS nilai_order_pertama,
       COUNT(*) AS n_pelanggan, ROUND(100.0 * COUNT(*) FILTER (WHERE c.is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct
FROM rp_cust c JOIN fact_orders f ON f.order_id = c.first_order_id WHERE f.has_items GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 6. REPEAT RATE per STATE (state pada ORDER PERTAMA; semua 27 state dengan n)
-- ============================================================
CREATE OR REPLACE TABLE repeat_state AS
SELECT state_first_order AS state, COUNT(*) AS n_pelanggan,
       COUNT(*) FILTER (WHERE is_repeat_customer) AS n_repeat,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) AS repeat_rate_pct,
       COUNT(*) FILTER (WHERE is_repeat_raw) AS n_repeat_mentah,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw) / COUNT(*), 3) AS repeat_mentah_pct,
       (COUNT(*) < 500) AS n_kecil
FROM rp_cust GROUP BY state_first_order;

SELECT state, n_pelanggan, n_repeat, repeat_rate_pct, repeat_mentah_pct, n_kecil
FROM repeat_state ORDER BY n_pelanggan DESC;

-- 6.1 Sensitivitas: state order pertama vs state order terakhir (hanya berbeda untuk pelanggan multi-state)
SELECT COUNT(*) FILTER (WHERE state_first_order <> state_latest_order) AS n_pelanggan_state_berbeda,
       COUNT(*) FILTER (WHERE flag_multi_state) AS n_flag_multi_state,
       COUNT(*) FILTER (WHERE state_first_order <> state_latest_order AND is_repeat_customer) AS n_repeat_di_antaranya
FROM rp_cust;

-- ============================================================
-- 7. Reconcile ke KPI terkunci dan angka referensi -> repeat_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE rep_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO rep_raw VALUES
 ('reconcile','Customer Population',                              (SELECT COUNT(*) FROM rp_cust), 96096, 0),
 ('reconcile','SUM(pelanggan per state order pertama)',           (SELECT SUM(n_pelanggan) FROM repeat_state), 96096, 0),
 ('reconcile','SUM(order) pada rp_seq = Order Population',        (SELECT COUNT(*) FROM rp_seq), 99441, 0),
 ('reconcile','SUM(n_orders) bulanan = Order Population',         (SELECT SUM(n_orders) FROM repeat_monthly), 99441, 0),
 ('reconcile','SUM(n_pelanggan) cohort = Customer Population',    (SELECT SUM(n_pelanggan) FROM repeat_cohort), 96096, 0),
 ('reconcile','n_new + n_returning + n_sesi_sama = Order Population', (SELECT SUM(n_new + n_returning + n_sesi_sama) FROM repeat_monthly), 99441, 0),
 ('reconcile','n_new = Customer Population (1 order pertama per pelanggan)', (SELECT SUM(n_new) FROM repeat_monthly), 96096, 0),
 ('distribution','pelanggan 1 order',                            (SELECT COUNT(*) FROM rp_cust WHERE n_orders_raw = 1), 93099, 0),
 ('distribution','pelanggan 2 order',                            (SELECT COUNT(*) FROM rp_cust WHERE n_orders_raw = 2), 2745, 0),
 ('distribution','pelanggan 3 order',                            (SELECT COUNT(*) FROM rp_cust WHERE n_orders_raw = 3), 203, 0),
 ('distribution','n order maksimum per pelanggan',               (SELECT MAX(n_orders_raw) FROM rp_cust), 17, 0),
 ('distribution','% pelanggan 1 order',                          (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n_orders_raw = 1) / COUNT(*), 2) FROM rp_cust), 96.88, 0.011),
 ('kpi','Repeat Rate % (>= 24 jam; terkunci Tahap 6)',           (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_customer) / COUNT(*), 3) FROM rp_cust), 2.208, 0.0011),
 ('kpi','n repeat >= 24 jam',                                    (SELECT COUNT(*) FILTER (WHERE is_repeat_customer) FROM rp_cust), 2122, 0),
 ('kpi','repeat mentah % (Data Quality)',                        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw) / COUNT(*), 3) FROM rp_cust), 3.119, 0.0011),
 ('kpi','n repeat mentah',                                       (SELECT COUNT(*) FILTER (WHERE is_repeat_raw) FROM rp_cust), 2997, 0),
 ('kpi','pelanggan hanya order < 24 jam (sesi sama)',            (SELECT COUNT(*) FILTER (WHERE is_repeat_raw AND NOT is_repeat_customer) FROM rp_cust), 875, 0),
 ('kpi','% sesi sama dari repeat mentah',                        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_repeat_raw AND NOT is_repeat_customer) / COUNT(*) FILTER (WHERE is_repeat_raw), 1) FROM rp_cust), 29.2, 0.051),
 ('kpi','cohort 90-day (2017-01..2018-05) n',                    (SELECT COUNT(*) FROM rp_cust WHERE first_ts >= TIMESTAMP '2017-01-01' AND first_ts < TIMESTAMP '2018-06-01'), 77482, 0),
 ('kpi','cohort 90-day repeat n',                                (SELECT COUNT(*) FILTER (WHERE return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 90 DAY) FROM rp_cust WHERE first_ts >= TIMESTAMP '2017-01-01' AND first_ts < TIMESTAMP '2018-06-01'), 1009, 0),
 ('kpi','90-day Repeat Rate % (terkunci Tahap 6)',               (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE return_ts IS NOT NULL AND return_ts <= first_ts + INTERVAL 90 DAY) / COUNT(*), 3) FROM rp_cust WHERE first_ts >= TIMESTAMP '2017-01-01' AND first_ts < TIMESTAMP '2018-06-01'), 1.302, 0.0011),
 ('session','pasangan berurutan < 1 jam (roadmap 919)',          (SELECT COUNT(*) FROM rp_seq WHERE rn >= 2 AND date_diff('second', prev_ts, ts_purchase) < 3600), 919, 0),
 ('session','pasangan di detik yang sama (roadmap 292)',          (SELECT COUNT(*) FROM rp_seq WHERE rn >= 2 AND date_diff('second', prev_ts, ts_purchase) = 0), 292, 0),
 ('session','pasangan < 1 jam seller-set beda (roadmap 571)',
        (SELECT COUNT(*) FROM (SELECT s.order_id, s.prev_order FROM rp_seq s WHERE s.rn >= 2 AND date_diff('second', s.prev_ts, s.ts_purchase) < 3600) p
         JOIN rp_sellers a ON a.order_id = p.order_id JOIN rp_sellers b ON b.order_id = p.prev_order WHERE a.sellers <> b.sellers), 571, 0),
 ('session','pasangan < 1 jam seller-set sama (roadmap 325)',
        (SELECT COUNT(*) FROM (SELECT s.order_id, s.prev_order FROM rp_seq s WHERE s.rn >= 2 AND date_diff('second', s.prev_ts, s.ts_purchase) < 3600) p
         JOIN rp_sellers a ON a.order_id = p.order_id JOIN rp_sellers b ON b.order_id = p.prev_order WHERE a.sellers = b.sellers), 325, 0),
 ('session','pasangan < 1 jam salah satu tanpa item (roadmap 23)',
        (SELECT COUNT(*) FROM (SELECT s.order_id, s.prev_order FROM rp_seq s WHERE s.rn >= 2 AND date_diff('second', s.prev_ts, s.ts_purchase) < 3600) p
         LEFT JOIN rp_sellers a ON a.order_id = p.order_id LEFT JOIN rp_sellers b ON b.order_id = p.prev_order WHERE a.order_id IS NULL OR b.order_id IS NULL), 23, 0),
 ('gap','median jeda antar order berurutan, semua pasangan (hari; roadmap 28,33)',
        (SELECT ROUND(quantile_cont(date_diff('second', prev_ts, ts_purchase) / 86400.0, 0.5), 2) FROM rp_seq WHERE rn >= 2), 28.33, 0.011),
 ('gap','median jeda pasangan >= 24 jam (hari)',
        (SELECT ROUND(quantile_cont(g, 0.5), 2) FROM (SELECT date_diff('second', prev_ts, ts_purchase) / 86400.0 AS g FROM rp_seq WHERE rn >= 2) WHERE g >= 1), NULL, 0),
 ('gap','median waktu ke order kembali pertama (hari)',
        (SELECT ROUND(quantile_cont(date_diff('second', first_ts, return_ts) / 86400.0, 0.5), 2) FROM rp_cust WHERE return_ts IS NOT NULL), NULL, 0),
 ('cohort','repeat mentah kapan pun, cohort 2017-01 % (roadmap 7,59)', (SELECT pct_repeat_mentah_kapan_pun FROM repeat_cohort WHERE cohort = '2017-01'), 7.59, 0.011),
 ('cohort','repeat mentah kapan pun, cohort 2018-08 % (roadmap 0,81)', (SELECT pct_repeat_mentah_kapan_pun FROM repeat_cohort WHERE cohort = '2018-08'), 0.81, 0.011),
 ('cohort','pelanggan multi-state',                              (SELECT COUNT(*) FILTER (WHERE flag_multi_state) FROM rp_cust), 39, 0);

CREATE OR REPLACE TABLE repeat_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM rep_raw;

SELECT status, COUNT(*) AS n_metrik FROM repeat_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM repeat_findings ORDER BY section, metric;

-- ============================================================
-- 8. Output parquet
-- ============================================================
COPY repeat_monthly  TO 'data/processed/16_repeat_monthly.parquet'  (FORMAT PARQUET);
COPY repeat_cohort   TO 'data/processed/16_repeat_cohort.parquet'   (FORMAT PARQUET);
COPY repeat_findings TO 'data/processed/16_repeat_findings.parquet' (FORMAT PARQUET);
SELECT '16_repeat_monthly' AS file, COUNT(*) AS n FROM read_parquet('data/processed/16_repeat_monthly.parquet') UNION ALL
SELECT '16_repeat_cohort', COUNT(*) FROM read_parquet('data/processed/16_repeat_cohort.parquet') UNION ALL
SELECT '16_repeat_findings', COUNT(*) FROM read_parquet('data/processed/16_repeat_findings.parquet');
