-- ============================================================
-- Tahap 10 — Order Status & Fulfillment Analysis
-- File: sql/09_order_status_fulfillment.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/09_order_status_fulfillment.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (status / tahap / bulan / state / metode bayar / order); dinyatakan di tiap blok
-- POPULATION:  Order Population (n = 99.441) kecuali disebut; Delivered Population (96.470) untuk durasi tahap;
--              Cancelled Population (625) untuk profil pembatalan
-- DENOMINATOR: Total Orders untuk Cancellation Rate dan Unavailable Rate (dua metrik terpisah, terkunci Tahap 6)
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * Cancellation Rate = is_canceled / Total Orders; Unavailable Rate = is_unavailable / Total Orders. JANGAN digabung.
--   * Durasi antar tahap: baris dengan flag anomali urutan tanggal / timestamp kosong di-exclude PER TAHAP
--     dan jumlahnya dilaporkan (n_used, n_missing, n_anomaly).
--   * "Stuck order candidates" bersifat deskriptif (status in-flight yang sudah lewat tanggal estimasi);
--     status di bulan lama kemungkinan basi, bukan bukti order benar-benar macet.
--   * Tren bulanan: bulan non-full tampil sebagai anotasi (period_quality), bukan garis turun.
--   * Hubungan antar variabel (mis. metode bayar vs pembatalan) = asosiasi, bukan kausal.
-- Output: data/processed/09_status_monthly.parquet, 09_status_findings.parquet
-- ============================================================

-- Tanggal snapshot data = tanggal purchase terakhir di dataset (bukan tanggal hari ini)
CREATE OR REPLACE TEMP TABLE st_snap AS
SELECT CAST(MAX(ts_purchase) AS DATE) AS snapshot_date FROM fact_orders;
SELECT snapshot_date FROM st_snap;

-- ============================================================
-- 1. STATUS & FUNNEL (Order Population)
-- ============================================================
-- 1.1 Breakdown status (GRAIN: order). Reconcile: total = 99.441
SELECT order_status, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3) AS pct_order,
       COUNT(*) FILTER (WHERE has_items)     AS dengan_item,
       COUNT(*) FILTER (WHERE NOT has_items) AS tanpa_item,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2) AS item_revenue,
       ROUND(CAST(SUM(payment_total) AS DOUBLE), 2) AS payment_total
FROM fact_orders GROUP BY order_status ORDER BY n_order DESC;

SELECT COUNT(*) AS total_orders FROM fact_orders;

-- 1.2 Funnel kumulatif berdasarkan timestamp tahap yang tercatat
--     (status adalah snapshot akhir; funnel ini menunjukkan berapa order yang punya jejak tiap tahap)
SELECT ord, tahap, n_order,
       ROUND(100.0 * n_order / FIRST_VALUE(n_order) OVER (ORDER BY ord), 3) AS pct_dari_purchase,
       ROUND(100.0 * n_order / LAG(n_order) OVER (ORDER BY ord), 3)          AS pct_dari_tahap_sebelumnya
FROM (SELECT 1 AS ord, '1 purchase' AS tahap, COUNT(*) AS n_order FROM fact_orders
      UNION ALL SELECT 2, '2 approved (ts_approved ada)', COUNT(*) FILTER (WHERE ts_approved IS NOT NULL) FROM fact_orders
      UNION ALL SELECT 3, '3 diserahkan ke carrier (ts_carrier ada)', COUNT(*) FILTER (WHERE ts_carrier IS NOT NULL) FROM fact_orders
      UNION ALL SELECT 4, '4 diterima pelanggan (ts_customer ada)', COUNT(*) FILTER (WHERE ts_customer IS NOT NULL) FROM fact_orders)
ORDER BY ord;

-- 1.3 Order yang TIDAK punya jejak tiap tahap, menurut status akhir
--     (menjelaskan siapa yang gugur di tiap tahap; angka total = jumlah null timestamp di profiling)
SELECT '1 tanpa ts_approved' AS tidak_punya_jejak, order_status, COUNT(*) AS n_order
FROM fact_orders WHERE ts_approved IS NULL GROUP BY order_status
UNION ALL
SELECT '2 tanpa ts_carrier', order_status, COUNT(*) FROM fact_orders WHERE ts_carrier IS NULL GROUP BY order_status
UNION ALL
SELECT '3 tanpa ts_customer', order_status, COUNT(*) FROM fact_orders WHERE ts_customer IS NULL GROUP BY order_status
ORDER BY 1, 3 DESC;

-- ============================================================
-- 2. CANCELLATION RATE & UNAVAILABLE RATE (dua metrik terpisah; denominator Total Orders)
-- ============================================================
-- 2.1 Keseluruhan
SELECT COUNT(*) AS total_orders,
       COUNT(*) FILTER (WHERE is_canceled)    AS canceled,
       COUNT(*) FILTER (WHERE is_unavailable) AS unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled)    / COUNT(*), 3) AS cancellation_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_unavailable) / COUNT(*), 3) AS unavailable_rate_pct
FROM fact_orders;

-- 2.2 Tren bulanan (GRAIN: bulan purchase; semua bulan tampil dengan period_quality)
CREATE OR REPLACE TABLE status_monthly AS
WITH cal AS (SELECT DISTINCT year_month, period_quality FROM dim_date),
agg AS (
    SELECT d.year_month,
           COUNT(*)                                                              AS total_orders,
           COUNT(*) FILTER (WHERE f.is_canceled)                                 AS canceled,
           COUNT(*) FILTER (WHERE f.is_unavailable)                              AS unavailable,
           COUNT(*) FILTER (WHERE f.order_status = 'delivered')                  AS delivered,
           COUNT(*) FILTER (WHERE f.order_status IN ('shipped','invoiced','processing','created','approved')) AS in_flight,
           COUNT(*) FILTER (WHERE f.order_status IN ('shipped','invoiced','processing')
                              AND CAST(f.ts_estimated AS DATE) < (SELECT snapshot_date FROM st_snap)) AS stuck_candidates
    FROM fact_orders f JOIN dim_date d ON d.date_key = f.purchase_date
    GROUP BY d.year_month
)
SELECT c.year_month, c.period_quality, (c.period_quality = 'full') AS show_in_trend,
       COALESCE(a.total_orders, 0) AS total_orders,
       COALESCE(a.canceled, 0)     AS canceled,
       COALESCE(a.unavailable, 0)  AS unavailable,
       ROUND(100.0 * a.canceled    / NULLIF(a.total_orders, 0), 3) AS cancellation_rate_pct,
       ROUND(100.0 * a.unavailable / NULLIF(a.total_orders, 0), 3) AS unavailable_rate_pct,
       COALESCE(a.delivered, 0)    AS delivered,
       COALESCE(a.in_flight, 0)    AS in_flight,
       ROUND(100.0 * a.in_flight / NULLIF(a.total_orders, 0), 3) AS pct_in_flight,
       COALESCE(a.stuck_candidates, 0) AS stuck_candidates
FROM cal c LEFT JOIN agg a USING (year_month)
ORDER BY c.year_month;

SELECT year_month, period_quality, total_orders, canceled, unavailable,
       cancellation_rate_pct, unavailable_rate_pct, in_flight, pct_in_flight, stuck_candidates
FROM status_monthly ORDER BY year_month;

-- 2.3 Ringkasan tren pada Analysis Window (hanya bulan full)
SELECT ROUND(MIN(cancellation_rate_pct), 3) AS cancel_min, ROUND(MAX(cancellation_rate_pct), 3) AS cancel_maks,
       ROUND(100.0 * SUM(canceled) / SUM(total_orders), 3) AS cancel_gabungan,
       ROUND(MIN(unavailable_rate_pct), 3) AS unavail_min, ROUND(MAX(unavailable_rate_pct), 3) AS unavail_maks,
       ROUND(100.0 * SUM(unavailable) / SUM(total_orders), 3) AS unavail_gabungan,
       SUM(total_orders) AS orders_window
FROM status_monthly WHERE show_in_trend;

-- ============================================================
-- 3. PROFIL ORDER unavailable DAN canceled
-- ============================================================
-- 3.1 Unavailable (609): dengan vs tanpa item. item_revenue dibandingkan Item Revenue Revenue Population.
SELECT has_items, COUNT(*) AS n_order,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2)  AS item_revenue,
       ROUND(100.0 * CAST(SUM(item_revenue) AS DOUBLE)
             / (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 4) AS pct_item_revenue_rp,
       ROUND(CAST(SUM(payment_total) AS DOUBLE), 2) AS payment_tercatat
FROM fact_orders WHERE is_unavailable GROUP BY has_items ORDER BY has_items;

-- 3.2 Canceled (625): dengan vs tanpa item (item pada order canceled dikeluarkan dari Revenue Population)
SELECT has_items, COUNT(*) AS n_order,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2)  AS item_revenue_dikeluarkan,
       ROUND(CAST(SUM(payment_total) AS DOUBLE), 2) AS payment_tercatat
FROM fact_orders WHERE is_canceled GROUP BY has_items ORDER BY has_items;

-- 3.3 Canceled: sampai tahap mana jejak terakhirnya (Cancelled Population)
SELECT CASE WHEN ts_customer IS NOT NULL THEN '4 tanggal terima tercatat (anomali)'
            WHEN ts_carrier  IS NOT NULL THEN '3 sudah diserahkan ke carrier'
            WHEN ts_approved IS NOT NULL THEN '2 disetujui, belum ke carrier'
            ELSE '1 dibatalkan sebelum approval' END AS jejak_terakhir,
       COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       COUNT(*) FILTER (WHERE has_items) AS dengan_item
FROM fact_orders WHERE is_canceled GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 4. DURASI ANTAR TAHAP (Delivered Population, n = 96.470)
--    Dikecualikan per tahap: timestamp kosong (n_missing) dan anomali urutan tanggal (n_anomaly).
-- ============================================================
CREATE OR REPLACE TEMP TABLE st_stage AS
SELECT order_id, purchase_date,
       flag_carrier_before_approved, flag_customer_before_carrier,
       CASE WHEN ts_approved IS NOT NULL
            THEN date_diff('second', ts_purchase, ts_approved) / 86400.0 END AS d_approve,
       CASE WHEN ts_approved IS NOT NULL AND ts_carrier IS NOT NULL AND NOT flag_carrier_before_approved
            THEN date_diff('second', ts_approved, ts_carrier) / 86400.0 END AS d_handover,
       CASE WHEN ts_carrier IS NOT NULL AND NOT flag_customer_before_carrier
            THEN date_diff('second', ts_carrier, ts_customer) / 86400.0 END AS d_transit,
       delivery_days AS d_total
FROM fact_orders WHERE is_delivered_complete;

SELECT '1 purchase -> approved' AS tahap,
       COUNT(d_approve) AS n_used,
       COUNT(*) FILTER (WHERE d_approve IS NULL) AS n_dikecualikan,
       ROUND(quantile_cont(d_approve, 0.5), 2) AS p50, ROUND(quantile_cont(d_approve, 0.9), 2) AS p90,
       ROUND(quantile_cont(d_approve, 0.95), 2) AS p95, ROUND(quantile_cont(d_approve, 0.99), 2) AS p99,
       ROUND(AVG(d_approve), 2) AS mean, ROUND(MAX(d_approve), 2) AS max
FROM st_stage
UNION ALL
SELECT '2 approved -> carrier (handover seller)', COUNT(d_handover), COUNT(*) FILTER (WHERE d_handover IS NULL),
       ROUND(quantile_cont(d_handover, 0.5), 2), ROUND(quantile_cont(d_handover, 0.9), 2),
       ROUND(quantile_cont(d_handover, 0.95), 2), ROUND(quantile_cont(d_handover, 0.99), 2),
       ROUND(AVG(d_handover), 2), ROUND(MAX(d_handover), 2) FROM st_stage
UNION ALL
SELECT '3 carrier -> delivered (transit)', COUNT(d_transit), COUNT(*) FILTER (WHERE d_transit IS NULL),
       ROUND(quantile_cont(d_transit, 0.5), 2), ROUND(quantile_cont(d_transit, 0.9), 2),
       ROUND(quantile_cont(d_transit, 0.95), 2), ROUND(quantile_cont(d_transit, 0.99), 2),
       ROUND(AVG(d_transit), 2), ROUND(MAX(d_transit), 2) FROM st_stage
UNION ALL
SELECT '4 purchase -> delivered (total)', COUNT(d_total), COUNT(*) FILTER (WHERE d_total IS NULL),
       ROUND(quantile_cont(d_total, 0.5), 2), ROUND(quantile_cont(d_total, 0.9), 2),
       ROUND(quantile_cont(d_total, 0.95), 2), ROUND(quantile_cont(d_total, 0.99), 2),
       ROUND(AVG(d_total), 2), ROUND(MAX(d_total), 2) FROM st_stage
ORDER BY tahap;

-- 4.1 Rincian pengecualian per tahap: timestamp kosong vs anomali urutan
SELECT '1 purchase -> approved' AS tahap,
       COUNT(*) FILTER (WHERE d_approve IS NULL) AS n_missing_timestamp, 0 AS n_anomaly_urutan FROM st_stage
UNION ALL
SELECT '2 approved -> carrier',
       COUNT(*) FILTER (WHERE d_handover IS NULL AND NOT flag_carrier_before_approved),
       COUNT(*) FILTER (WHERE flag_carrier_before_approved) FROM st_stage
UNION ALL
SELECT '3 carrier -> delivered',
       COUNT(*) FILTER (WHERE d_transit IS NULL AND NOT flag_customer_before_carrier),
       COUNT(*) FILTER (WHERE flag_customer_before_carrier) FROM st_stage
ORDER BY 1;

-- 4.2 Tren bulanan durasi tahap pada Analysis Window (median; n_used; anomali handover per bulan)
SELECT strftime(date_trunc('month', purchase_date), '%Y-%m') AS bulan,
       COUNT(*) AS delivered_pop,
       ROUND(quantile_cont(d_handover, 0.5), 2) AS handover_p50,
       ROUND(quantile_cont(d_handover, 0.9), 2) AS handover_p90,
       ROUND(quantile_cont(d_transit, 0.5), 2)  AS transit_p50,
       ROUND(quantile_cont(d_transit, 0.9), 2)  AS transit_p90,
       COUNT(*) FILTER (WHERE flag_carrier_before_approved) AS n_handover_anomali,
       ROUND(100.0 * COUNT(*) FILTER (WHERE flag_carrier_before_approved) / COUNT(*), 2) AS pct_handover_anomali
FROM st_stage
WHERE purchase_date >= DATE '2017-01-01' AND purchase_date < DATE '2018-09-01'
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 5. CANCELLATION / UNAVAILABLE per STATE dan per METODE PEMBAYARAN (korelasional)
-- ============================================================
-- 5.1 Per state pelanggan (semua 27 state ditampilkan dengan n; tanpa tiering, D12)
SELECT customer_state AS state, COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE is_canceled)    AS canceled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled)    / COUNT(*), 3) AS cancellation_rate_pct,
       COUNT(*) FILTER (WHERE is_unavailable) AS unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_unavailable) / COUNT(*), 3) AS unavailable_rate_pct
FROM fact_orders GROUP BY customer_state ORDER BY n_order DESC;

-- 5.2 Per kombinasi metode pembayaran (POPULATION: Payment Population = order yang punya payment)
CREATE OR REPLACE TEMP TABLE st_paymix AS
SELECT order_id, array_to_string(list_sort(list_distinct(list(payment_type))), ' + ') AS payment_mix
FROM fact_payments GROUP BY order_id;

SELECT m.payment_mix, COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE f.is_canceled)    AS canceled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_canceled)    / COUNT(*), 3) AS cancellation_rate_pct,
       COUNT(*) FILTER (WHERE f.is_unavailable) AS unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_unavailable) / COUNT(*), 3) AS unavailable_rate_pct
FROM fact_orders f JOIN st_paymix m ON m.order_id = f.order_id
GROUP BY m.payment_mix ORDER BY n_order DESC;

-- 5.3 Cancellation per rentang nilai order (Revenue + canceled dengan item) - apakah order bernilai besar
--     lebih sering dibatalkan? (POPULATION: order ber-item, canceled/unavailable ikut sebagai pembilang)
SELECT CASE WHEN item_revenue < 50 THEN '1: < 50' WHEN item_revenue < 100 THEN '2: 50-99'
            WHEN item_revenue < 200 THEN '3: 100-199' WHEN item_revenue < 500 THEN '4: 200-499'
            ELSE '5: >= 500' END AS nilai_order,
       COUNT(*) AS n_order_ber_item,
       COUNT(*) FILTER (WHERE is_canceled) AS canceled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) AS cancel_rate_dari_order_ber_item_pct
FROM fact_orders WHERE has_items GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 6. STUCK ORDER CANDIDATES (deskriptif)
--    Status in-flight yang tanggal estimasinya sudah lewat terhadap tanggal snapshot dataset.
-- ============================================================
-- 6.1 Per status in-flight
SELECT f.order_status,
       COUNT(*) AS n_inflight,
       COUNT(*) FILTER (WHERE CAST(f.ts_estimated AS DATE) < s.snapshot_date) AS stuck_candidates,
       ROUND(100.0 * COUNT(*) FILTER (WHERE CAST(f.ts_estimated AS DATE) < s.snapshot_date) / COUNT(*), 2) AS pct_stuck,
       ROUND(quantile_cont(date_diff('day', CAST(f.ts_estimated AS DATE), s.snapshot_date), 0.5)
             FILTER (WHERE CAST(f.ts_estimated AS DATE) < s.snapshot_date), 0) AS median_hari_lewat_estimasi,
       ROUND(CAST(SUM(f.item_revenue) FILTER (WHERE CAST(f.ts_estimated AS DATE) < s.snapshot_date) AS DOUBLE), 2) AS item_revenue_stuck
FROM fact_orders f, st_snap s
WHERE f.order_status IN ('shipped','invoiced','processing','created','approved')
GROUP BY f.order_status ORDER BY n_inflight DESC;

-- 6.2 Berapa lama lewat estimasi (hari) pada kandidat shipped/invoiced/processing
SELECT CASE WHEN dd <= 30 THEN '1: 1-30 hari' WHEN dd <= 90 THEN '2: 31-90 hari'
            WHEN dd <= 180 THEN '3: 91-180 hari' ELSE '4: > 180 hari' END AS lewat_estimasi,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (SELECT date_diff('day', CAST(f.ts_estimated AS DATE), s.snapshot_date) AS dd
      FROM fact_orders f, st_snap s
      WHERE f.order_status IN ('shipped','invoiced','processing')
        AND CAST(f.ts_estimated AS DATE) < s.snapshot_date)
GROUP BY 1 ORDER BY 1;

-- 6.3 Kandidat macet menurut bulan purchase (Analysis Window): status basi di bulan lama?
SELECT year_month, total_orders, in_flight, pct_in_flight, stuck_candidates,
       ROUND(100.0 * stuck_candidates / NULLIF(in_flight, 0), 2) AS pct_inflight_yang_stuck
FROM status_monthly WHERE show_in_trend ORDER BY year_month;

-- ============================================================
-- 7. Reconcile ke KPI terkunci -> status_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE st_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO st_raw VALUES
 ('reconcile','SUM(order per status) = Total Orders',               (SELECT COUNT(*) FROM fact_orders WHERE order_status IN ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved')), 99441, 0),
 ('reconcile','status delivered',      (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'delivered'),   96478, 0),
 ('reconcile','status shipped',        (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'shipped'),     1107, 0),
 ('reconcile','status canceled',       (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'canceled'),    625, 0),
 ('reconcile','status unavailable',    (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'unavailable'), 609, 0),
 ('reconcile','status invoiced',       (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'invoiced'),    314, 0),
 ('reconcile','status processing',     (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'processing'),  301, 0),
 ('reconcile','status created',        (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'created'),     5, 0),
 ('reconcile','status approved',       (SELECT COUNT(*) FROM fact_orders WHERE order_status = 'approved'),    2, 0),
 ('reconcile','Cancellation Rate % (terkunci Tahap 6)', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM fact_orders), 0.629, 0.0011),
 ('reconcile','Unavailable Rate % (terkunci Tahap 6)',  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_unavailable) / COUNT(*), 3) FROM fact_orders), 0.612, 0.0011),
 ('reconcile','SUM(total_orders) bulanan = Order Population',  (SELECT SUM(total_orders) FROM status_monthly), 99441, 0),
 ('reconcile','SUM(canceled) bulanan = 625',                   (SELECT SUM(canceled) FROM status_monthly), 625, 0),
 ('reconcile','SUM(unavailable) bulanan = 609',                (SELECT SUM(unavailable) FROM status_monthly), 609, 0),
 ('funnel','order dengan ts_approved',      (SELECT COUNT(*) FROM fact_orders WHERE ts_approved IS NOT NULL), 99281, 0),
 ('funnel','order dengan ts_carrier',       (SELECT COUNT(*) FROM fact_orders WHERE ts_carrier IS NOT NULL),  97658, 0),
 ('funnel','order dengan ts_customer',      (SELECT COUNT(*) FROM fact_orders WHERE ts_customer IS NOT NULL), 96476, 0),
 ('unavailable','unavailable tanpa item',   (SELECT COUNT(*) FROM fact_orders WHERE is_unavailable AND NOT has_items), 603, 0),
 ('unavailable','unavailable dengan item',  (SELECT COUNT(*) FROM fact_orders WHERE is_unavailable AND has_items), 6, 0),
 ('unavailable','item revenue unavailable dengan item (R$)', (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_unavailable AND has_items), 2007.69, 0.011),
 ('unavailable','% dari Item Revenue Revenue Population',
        (SELECT ROUND(100.0 * CAST(SUM(item_revenue) FILTER (WHERE is_unavailable AND has_items) AS DOUBLE)
                / (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 3) FROM fact_orders), 0.015, 0.0011),
 ('unavailable','payment tercatat unavailable tanpa item (R$)', (SELECT CAST(SUM(payment_total) AS DOUBLE) FROM fact_orders WHERE is_unavailable AND NOT has_items), 124339.02, 0.011),
 ('canceled','canceled dengan item',       (SELECT COUNT(*) FROM fact_orders WHERE is_canceled AND has_items), 461, 0),
 ('canceled','canceled tanpa item',        (SELECT COUNT(*) FROM fact_orders WHERE is_canceled AND NOT has_items), 164, 0),
 ('canceled','canceled dengan tanggal terima (anomali, di-flag)', (SELECT COUNT(*) FROM fact_orders WHERE is_canceled AND ts_customer IS NOT NULL), 6, 0),
 ('stage','median purchase -> approved (hari)', (SELECT ROUND(quantile_cont(d_approve, 0.5), 2) FROM st_stage), 0.01, 0.011),
 ('stage','median approved -> carrier (hari)',  (SELECT ROUND(quantile_cont(d_handover, 0.5), 2) FROM st_stage), 1.85, 0.011),
 ('stage','median carrier -> delivered (hari)', (SELECT ROUND(quantile_cont(d_transit, 0.5), 2) FROM st_stage), 7.10, 0.011),
 ('stage','median purchase -> delivered (hari)',(SELECT ROUND(quantile_cont(d_total, 0.5), 2) FROM st_stage), 10.22, 0.011),
 ('stage','n dipakai purchase -> approved',     (SELECT COUNT(d_approve) FROM st_stage), 96456, 0),
 ('stage','n dipakai approved -> carrier',      (SELECT COUNT(d_handover) FROM st_stage), 95105, 0),
 ('stage','n dipakai carrier -> delivered',     (SELECT COUNT(d_transit) FROM st_stage), 96446, 0),
 ('stuck','kandidat macet shipped/invoiced/processing (descriptif)',
        (SELECT COUNT(*) FROM fact_orders f, st_snap s WHERE f.order_status IN ('shipped','invoiced','processing') AND CAST(f.ts_estimated AS DATE) < s.snapshot_date), NULL, 0),
 ('stuck','in-flight lainnya (created/approved) lewat estimasi',
        (SELECT COUNT(*) FROM fact_orders f, st_snap s WHERE f.order_status IN ('created','approved') AND CAST(f.ts_estimated AS DATE) < s.snapshot_date), NULL, 0),
 ('stuck','pct_in_flight 2017-01 (%)',   (SELECT pct_in_flight FROM status_monthly WHERE year_month = '2017-01'), 4.63, 0.011);

CREATE OR REPLACE TABLE status_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM st_raw;

SELECT status, COUNT(*) AS n_metrik FROM status_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM status_findings ORDER BY section, metric;

-- ============================================================
-- 8. Output parquet
-- ============================================================
COPY status_monthly  TO 'data/processed/09_status_monthly.parquet'  (FORMAT PARQUET);
COPY status_findings TO 'data/processed/09_status_findings.parquet' (FORMAT PARQUET);
SELECT '09_status_monthly' AS file, COUNT(*) AS n FROM read_parquet('data/processed/09_status_monthly.parquet') UNION ALL
SELECT '09_status_findings', COUNT(*) FROM read_parquet('data/processed/09_status_findings.parquet');
