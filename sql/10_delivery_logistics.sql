-- ============================================================
-- Tahap 11 — Delivery & Logistics Performance
-- File: sql/10_delivery_logistics.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/10_delivery_logistics.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (order / item / bulan / state / kategori / pasangan state); dinyatakan di tiap blok
-- POPULATION:  Delivered Population (is_delivered_complete, n = 96.470) kecuali disebut;
--              Single-Seller Population (96.922) untuk intra vs antar-state dan jarak;
--              Item Population (item dari order delivered) untuk freight vs jarak/berat/harga
-- DENOMINATOR: Delivered Orders untuk Late Rate dan On-Time Rate (terkunci Tahap 6); n per blok
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * Late Rate = is_late (perbandingan TANGGAL, D1) / Delivered Orders; On-Time Rate = 1 - Late Rate.
--   * Durasi tahap mengecualikan baris berflag anomali urutan tanggal hanya untuk tahap terkait.
--   * Baris tanpa koordinat valid (zip placeholder / tanpa titik valid) di-exclude dari analisis jarak;
--     cakupan dilaporkan.
--   * Uji sensitivitas tren 2018-04..08 (right-censoring, bauran state, anomali timestamp, estimasi)
--     adalah bagian wajib tahap ini (lihat blok 3).
--   * State ditampilkan semua dengan n (tanpa tiering, D12); kategori hanya >= 100 order (D6).
--   * Hubungan antar variabel = asosiasi, bukan kausal.
-- Output: data/processed/10_delivery_monthly.parquet, 10_delivery_findings.parquet
-- ============================================================

-- Snapshot data dan horizon observasi minimum:
-- horizon = hari antara akhir bulan penuh terakhir (2018-08-31) dan snapshot; semua bulan Analysis Window
-- punya >= horizon hari untuk dikirim, sehingga metrik "delivered dalam <= horizon hari" bebas right-censoring.
CREATE OR REPLACE TEMP TABLE dl_snap AS
SELECT CAST(MAX(ts_purchase) AS DATE) AS snapshot_date,
       date_diff('day', DATE '2018-08-31', CAST(MAX(ts_purchase) AS DATE)) AS horizon_days
FROM fact_orders;
SELECT snapshot_date, horizon_days FROM dl_snap;

-- ============================================================
-- 1. DISTRIBUSI delivery_days (Delivered Population)
-- ============================================================
-- 1.1 Keseluruhan
SELECT COUNT(*) AS n,
       ROUND(quantile_cont(delivery_days, 0.5), 2)  AS p50, ROUND(quantile_cont(delivery_days, 0.75), 2) AS p75,
       ROUND(quantile_cont(delivery_days, 0.9), 2)  AS p90, ROUND(quantile_cont(delivery_days, 0.95), 2) AS p95,
       ROUND(quantile_cont(delivery_days, 0.99), 2) AS p99, ROUND(AVG(delivery_days), 2) AS mean,
       ROUND(MAX(delivery_days), 2) AS max
FROM fact_orders WHERE is_delivered_complete;

-- 1.2 Per state customer (semua 27 state dengan n; tanpa tiering, D12), urut volume
SELECT customer_state AS state, COUNT(*) AS n_delivered,
       ROUND(quantile_cont(delivery_days, 0.5), 2)  AS p50, ROUND(quantile_cont(delivery_days, 0.75), 2) AS p75,
       ROUND(quantile_cont(delivery_days, 0.95), 2) AS p95, ROUND(quantile_cont(delivery_days, 0.99), 2) AS p99,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3)      AS late_rate_pct,
       ROUND(100.0 - 100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) AS on_time_rate_pct
FROM fact_orders WHERE is_delivered_complete
GROUP BY customer_state ORDER BY n_delivered DESC;

-- ============================================================
-- 2. LATE RATE & ON-TIME RATE (definisi terkunci Tahap 6)
-- ============================================================
-- 2.1 Keseluruhan
SELECT COUNT(*) AS delivered_orders,
       COUNT(*) FILTER (WHERE is_late) AS late_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3)          AS late_rate_pct,
       ROUND(100.0 - 100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) AS on_time_rate_pct,
       COUNT(*) FILTER (WHERE is_late_ts_sensitivity) AS late_orders_versi_timestamp,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late_ts_sensitivity) / COUNT(*), 3) AS late_rate_timestamp_pct
FROM fact_orders WHERE is_delivered_complete;

-- 2.2 Per kategori (order-kategori unik pada Delivered Population; order multi-kategori dihitung di tiap kategori;
--     hanya kategori >= 100 order, D6): 8 tertinggi dan 8 terendah
CREATE OR REPLACE TEMP TABLE dl_cat AS
SELECT pr.kategori, COUNT(*) AS n_delivered,
       COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.is_late) / COUNT(*), 3) AS late_rate_pct,
       ROUND(quantile_cont(o.delivery_days, 0.5), 2) AS delivery_days_p50
FROM (SELECT DISTINCT i.order_id, p.category_en_clean AS kategori
      FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id) pr
JOIN fact_orders o ON o.order_id = pr.order_id
WHERE o.is_delivered_complete
GROUP BY pr.kategori HAVING COUNT(*) >= 100;

SELECT 'tertinggi' AS urutan, * FROM (SELECT * FROM dl_cat ORDER BY late_rate_pct DESC LIMIT 8)
UNION ALL
SELECT 'terendah', * FROM (SELECT * FROM dl_cat ORDER BY late_rate_pct ASC LIMIT 8)
ORDER BY urutan DESC, late_rate_pct DESC;

-- 2.3 Estimasi konservatif? Selisih tanggal terima vs tanggal estimasi (hari; berbasis tanggal, konsisten D1)
--     On-time/early: hari LEBIH CEPAT dari estimasi; Late: hari LEBIH LAMBAT dari estimasi.
SELECT CASE WHEN is_late THEN 'late (hari lebih lambat dari estimasi)'
            ELSE 'on-time/early (hari lebih cepat dari estimasi)' END AS kelompok,
       COUNT(*) AS n_order,
       ROUND(AVG(selisih_hari), 2) AS rata2_hari,
       ROUND(quantile_cont(selisih_hari, 0.5), 1) AS median_hari,
       ROUND(quantile_cont(selisih_hari, 0.9), 1) AS p90_hari
FROM (SELECT is_late,
             CASE WHEN is_late THEN date_diff('day', CAST(ts_estimated AS DATE), CAST(ts_customer AS DATE))
                  ELSE date_diff('day', CAST(ts_customer AS DATE), CAST(ts_estimated AS DATE)) END AS selisih_hari
      FROM fact_orders WHERE is_delivered_complete)
GROUP BY is_late ORDER BY is_late;

-- 2.4 Lead time estimasi (purchase -> tanggal estimasi) vs durasi aktual (Delivered Population)
SELECT ROUND(quantile_cont(date_diff('day', purchase_date, CAST(ts_estimated AS DATE)), 0.5), 1) AS estimasi_median_hari,
       ROUND(quantile_cont(delivery_days, 0.5), 2) AS aktual_median_hari,
       ROUND(AVG(date_diff('day', purchase_date, CAST(ts_estimated AS DATE))), 2) AS estimasi_mean_hari,
       ROUND(AVG(delivery_days), 2) AS aktual_mean_hari
FROM fact_orders WHERE is_delivered_complete;

-- ============================================================
-- 3. TREN BULANAN + UJI SENSITIVITAS tren 2018-04..08
-- ============================================================
-- 3.1 delivery_monthly (GRAIN: bulan purchase). Semua bulan tampil dengan period_quality.
--     share_<=N_hari = delivered dalam <= N hari / Revenue Orders (order yang belum terkirim dihitung
--     sebagai belum tiba, sehingga bebas survivorship). median_<=horizon = median hanya untuk order yang
--     terkirim dalam <= horizon hari (jendela observasi sama untuk semua bulan).
CREATE OR REPLACE TABLE delivery_monthly AS
WITH cal AS (SELECT DISTINCT year_month, period_quality FROM dim_date),
agg AS (
    SELECT d.year_month,
           COUNT(*) FILTER (WHERE f.is_revenue_order)            AS revenue_orders,
           COUNT(*) FILTER (WHERE f.is_delivered_complete)       AS delivered_pop,
           COUNT(*) FILTER (WHERE f.is_late)                     AS late_orders,
           quantile_cont(f.delivery_days, 0.5)  AS p50,
           quantile_cont(f.delivery_days, 0.75) AS p75,
           quantile_cont(f.delivery_days, 0.95) AS p95,
           AVG(f.delivery_days)                 AS mean_days,
           COUNT(*) FILTER (WHERE f.is_delivered_complete AND f.delivery_days <= 10) AS n_le10,
           COUNT(*) FILTER (WHERE f.is_delivered_complete AND f.delivery_days <= 20) AS n_le20,
           COUNT(*) FILTER (WHERE f.is_delivered_complete AND f.delivery_days <= 30) AS n_le30,
           quantile_cont(f.delivery_days, 0.5) FILTER (WHERE f.delivery_days <= (SELECT horizon_days FROM dl_snap)) AS p50_le_horizon,
           COUNT(*) FILTER (WHERE f.is_delivered_complete AND f.delivery_days > (SELECT horizon_days FROM dl_snap)) AS n_gt_horizon,
           quantile_cont(date_diff('day', f.purchase_date, CAST(f.ts_estimated AS DATE)), 0.5) FILTER (WHERE f.is_revenue_order) AS estimasi_lead_p50
    FROM fact_orders f JOIN dim_date d ON d.date_key = f.purchase_date
    GROUP BY d.year_month
)
SELECT c.year_month, c.period_quality, (c.period_quality = 'full') AS show_in_trend,
       COALESCE(a.revenue_orders, 0) AS revenue_orders,
       COALESCE(a.delivered_pop, 0)  AS delivered_pop,
       ROUND(100.0 * a.delivered_pop / NULLIF(a.revenue_orders, 0), 2) AS pct_revenue_delivered,
       COALESCE(a.late_orders, 0)    AS late_orders,
       ROUND(100.0 * a.late_orders / NULLIF(a.delivered_pop, 0), 3)        AS late_rate_pct,
       ROUND(100.0 - 100.0 * a.late_orders / NULLIF(a.delivered_pop, 0), 3) AS on_time_rate_pct,
       ROUND(a.p50, 2) AS delivery_days_p50, ROUND(a.p75, 2) AS delivery_days_p75,
       ROUND(a.p95, 2) AS delivery_days_p95, ROUND(a.mean_days, 2) AS delivery_days_mean,
       ROUND(100.0 * a.n_le10 / NULLIF(a.revenue_orders, 0), 2) AS share_delivered_le10d_pct,
       ROUND(100.0 * a.n_le20 / NULLIF(a.revenue_orders, 0), 2) AS share_delivered_le20d_pct,
       ROUND(100.0 * a.n_le30 / NULLIF(a.revenue_orders, 0), 2) AS share_delivered_le30d_pct,
       ROUND(a.p50_le_horizon, 2) AS p50_le_horizon,
       a.n_gt_horizon, a.estimasi_lead_p50
FROM cal c LEFT JOIN agg a USING (year_month)
ORDER BY c.year_month;

SELECT year_month, period_quality, delivered_pop, late_rate_pct, on_time_rate_pct,
       delivery_days_p50, delivery_days_p75, delivery_days_p95, delivery_days_mean
FROM delivery_monthly ORDER BY year_month;

-- 3.2 Uji right-censoring: bila penurunan 2018-04..08 hanya artefak, share terkirim dan median-<=horizon
--     akan berubah mengikuti kedekatan ke akhir data.
SELECT year_month, revenue_orders, pct_revenue_delivered,
       share_delivered_le10d_pct, share_delivered_le20d_pct, share_delivered_le30d_pct,
       delivery_days_p50 AS p50_semua_terkirim, p50_le_horizon, n_gt_horizon
FROM delivery_monthly WHERE show_in_trend ORDER BY year_month;

-- 3.3 Uji bauran state: median per bulan untuk order intra-state vs antar-state (Single-Seller Population, Delivered)
--     Jika penurunan terjadi pada KEDUA kelompok, bauran state bukan penyebab utamanya.
CREATE OR REPLACE TEMP TABLE dl_ss AS
SELECT f.order_id, f.purchase_date, f.customer_state, s.seller_state,
       (f.customer_state = s.seller_state) AS same_state,
       f.delivery_days, f.is_late, f.freight_total, f.item_revenue,
       (f.flag_carrier_before_purchase OR f.flag_carrier_before_approved OR f.flag_customer_before_carrier) AS has_anomaly
FROM fact_orders f JOIN dim_seller s ON s.seller_id = f.single_seller_id
WHERE f.is_single_seller_pop AND f.is_delivered_complete;

SELECT strftime(date_trunc('month', purchase_date), '%Y-%m') AS bulan,
       COUNT(*) AS n_single_seller_delivered,
       ROUND(100.0 * COUNT(*) FILTER (WHERE same_state) / COUNT(*), 2) AS pct_intra_state,
       ROUND(quantile_cont(delivery_days, 0.5), 2) AS p50_semua,
       ROUND(quantile_cont(delivery_days, 0.5) FILTER (WHERE same_state), 2)     AS p50_intra,
       ROUND(quantile_cont(delivery_days, 0.5) FILTER (WHERE NOT same_state), 2) AS p50_antar,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late AND same_state) / NULLIF(COUNT(*) FILTER (WHERE same_state), 0), 3)         AS late_rate_intra,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late AND NOT same_state) / NULLIF(COUNT(*) FILTER (WHERE NOT same_state), 0), 3) AS late_rate_antar
FROM dl_ss
WHERE purchase_date >= DATE '2017-01-01' AND purchase_date < DATE '2018-09-01'
GROUP BY 1 ORDER BY 1;

-- 3.4 Uji anomali timestamp: durasi total (purchase -> delivered) tidak memakai ts_carrier/ts_approved,
--     jadi tidak terpengaruh pengecualian. Bandingkan order beranomali vs tidak pada bulan kluster anomali.
SELECT strftime(date_trunc('month', purchase_date), '%Y-%m') AS bulan,
       (f_any) AS has_anomaly, COUNT(*) AS n_order,
       ROUND(quantile_cont(delivery_days, 0.5), 2) AS p50_total,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) AS late_rate_pct
FROM (SELECT purchase_date, delivery_days, is_late,
             (flag_carrier_before_purchase OR flag_carrier_before_approved OR flag_customer_before_carrier) AS f_any
      FROM fact_orders WHERE is_delivered_complete
        AND purchase_date >= DATE '2018-01-01' AND purchase_date < DATE '2018-09-01')
GROUP BY 1, 2 ORDER BY 1, 2;

-- 3.5 Ringkasan sensitivitas: perbandingan 2018-02..03 vs 2018-06..08 pada tiap ukuran
SELECT CASE WHEN year_month IN ('2018-02', '2018-03') THEN 'a: 2018-02..03'
            WHEN year_month IN ('2018-04', '2018-05') THEN 'b: 2018-04..05'
            ELSE 'c: 2018-06..08' END AS periode,
       SUM(delivered_pop) AS delivered_pop,
       ROUND(AVG(delivery_days_p50), 2)     AS rata2_p50_bulanan,
       ROUND(AVG(p50_le_horizon), 2)        AS rata2_p50_le_horizon,
       ROUND(AVG(share_delivered_le10d_pct), 2) AS rata2_share_le10d,
       ROUND(AVG(share_delivered_le20d_pct), 2) AS rata2_share_le20d,
       ROUND(AVG(share_delivered_le30d_pct), 2) AS rata2_share_le30d,
       ROUND(AVG(estimasi_lead_p50), 1)     AS rata2_estimasi_lead,
       ROUND(AVG(late_rate_pct), 3)         AS rata2_late_rate
FROM delivery_monthly
WHERE year_month IN ('2018-02','2018-03','2018-04','2018-05','2018-06','2018-07','2018-08')
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 4. INTRA-STATE vs ANTAR-STATE (Single-Seller Population, Delivered Population)
-- ============================================================
SELECT same_state, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_order,
       ROUND(quantile_cont(delivery_days, 0.5), 2)  AS delivery_p50,
       ROUND(AVG(delivery_days), 2)                 AS delivery_mean,
       ROUND(quantile_cont(delivery_days, 0.95), 2) AS delivery_p95,
       ROUND(AVG(CAST(freight_total AS DOUBLE)), 2) AS avg_freight_per_order,
       ROUND(AVG(CAST(item_revenue AS DOUBLE)), 2)  AS avg_item_revenue,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) AS late_rate_pct
FROM dl_ss GROUP BY same_state ORDER BY same_state DESC;

-- 4.1 Aliran seller_state -> customer_state terbesar (n >= 300 order terkirim)
SELECT seller_state || ' -> ' || customer_state AS aliran, COUNT(*) AS n_order,
       ROUND(quantile_cont(delivery_days, 0.5), 2) AS delivery_p50,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) AS late_rate_pct,
       ROUND(AVG(CAST(freight_total AS DOUBLE)), 2) AS avg_freight_per_order
FROM dl_ss GROUP BY seller_state, customer_state HAVING COUNT(*) >= 300
ORDER BY n_order DESC LIMIT 15;

-- ============================================================
-- 5. JARAK SELLER-CUSTOMER (haversine dari dim_geo_zip) vs delivery_days dan freight
-- ============================================================
CREATE OR REPLACE TEMP TABLE dl_item AS
SELECT i.order_id, i.order_item_id, i.seller_id,
       o.order_status, o.is_delivered_complete, o.is_late, o.delivery_days,
       CAST(i.freight_value AS DOUBLE) AS freight_d, CAST(i.price AS DOUBLE) AS price_d,
       p.weight_g,
       CASE WHEN gs.lat IS NOT NULL AND gc.lat IS NOT NULL THEN
            2 * 6371.0 * asin(sqrt(pow(sin(radians(gc.lat - gs.lat) / 2), 2)
                + cos(radians(gs.lat)) * cos(radians(gc.lat)) * pow(sin(radians(gc.lng - gs.lng) / 2), 2)))
       END AS distance_km
FROM fact_order_items i
JOIN fact_orders o   ON o.order_id = i.order_id
JOIN dim_seller s    ON s.seller_id = i.seller_id
JOIN dim_product p   ON p.product_id = i.product_id
LEFT JOIN dim_geo_zip gs ON gs.zip = s.seller_zip_prefix
LEFT JOIN dim_geo_zip gc ON gc.zip = o.customer_zip_prefix;

-- 5.1 Cakupan koordinat (item dari Delivered Population dan dari status = 'delivered')
SELECT 'Delivered Population (is_delivered_complete)' AS populasi_item,
       COUNT(*) AS n_item, COUNT(distance_km) AS n_item_ber_jarak,
       ROUND(100.0 * COUNT(distance_km) / COUNT(*), 2) AS cakupan_pct
FROM dl_item WHERE is_delivered_complete
UNION ALL
SELECT 'status = delivered (pembanding addendum)', COUNT(*), COUNT(distance_km),
       ROUND(100.0 * COUNT(distance_km) / COUNT(*), 2)
FROM dl_item WHERE order_status = 'delivered';

-- 5.2 Distribusi jarak (km) dan jarak > 4.500 km (sanity)
SELECT COUNT(distance_km) AS n,
       ROUND(quantile_cont(distance_km, 0.5), 1)  AS median_km, ROUND(quantile_cont(distance_km, 0.95), 1) AS p95_km,
       ROUND(MAX(distance_km), 1) AS max_km, COUNT(*) FILTER (WHERE distance_km > 4500) AS n_gt_4500km
FROM dl_item WHERE order_status = 'delivered';

-- 5.3 Freight vs jarak per desil jarak (item-level; baris tanpa jarak di-exclude)
SELECT desil, COUNT(*) AS n_item, ROUND(AVG(distance_km), 1) AS avg_km, ROUND(AVG(freight_d), 2) AS avg_freight
FROM (SELECT distance_km, freight_d, NTILE(10) OVER (ORDER BY distance_km) AS desil
      FROM dl_item WHERE is_delivered_complete AND distance_km IS NOT NULL)
GROUP BY desil ORDER BY desil;

-- 5.4 Delivery days dan Late Rate per band jarak (order-level; Single-Seller Population, jarak dari satu seller)
CREATE OR REPLACE TEMP TABLE dl_ord_dist AS
SELECT order_id, MIN(distance_km) AS distance_km
FROM dl_item WHERE distance_km IS NOT NULL GROUP BY order_id;

SELECT CASE WHEN d.distance_km < 100 THEN '1: < 100 km' WHEN d.distance_km < 300 THEN '2: 100-299 km'
            WHEN d.distance_km < 600 THEN '3: 300-599 km' WHEN d.distance_km < 1000 THEN '4: 600-999 km'
            WHEN d.distance_km < 2000 THEN '5: 1000-1999 km' ELSE '6: >= 2000 km' END AS band_jarak,
       COUNT(*) AS n_order,
       ROUND(quantile_cont(o.delivery_days, 0.5), 2) AS delivery_p50,
       ROUND(quantile_cont(o.delivery_days, 0.95), 2) AS delivery_p95,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.is_late) / COUNT(*), 3) AS late_rate_pct,
       ROUND(AVG(CAST(o.freight_total AS DOUBLE)), 2) AS avg_freight_per_order
FROM fact_orders o JOIN dl_ord_dist d ON d.order_id = o.order_id
WHERE o.is_single_seller_pop AND o.is_delivered_complete
GROUP BY 1 ORDER BY 1;

-- 5.5 Korelasi Pearson (deskriptif)
SELECT ROUND(corr(distance_km, freight_d), 3) AS r_jarak_freight,
       ROUND(corr(distance_km, delivery_days), 3) AS r_jarak_delivery_days,
       ROUND(corr(price_d, freight_d), 3) AS r_harga_freight,
       ROUND(corr(weight_g, freight_d), 3) AS r_berat_freight
FROM dl_item WHERE is_delivered_complete;

-- ============================================================
-- 6. FREIGHT vs BERAT PRODUK dan vs HARGA (item-level, deskriptif; Delivered Population)
-- ============================================================
SELECT desil, COUNT(*) AS n_item, ROUND(AVG(weight_g), 0) AS avg_berat_g, ROUND(AVG(freight_d), 2) AS avg_freight
FROM (SELECT weight_g, freight_d, NTILE(10) OVER (ORDER BY weight_g) AS desil
      FROM dl_item WHERE is_delivered_complete AND weight_g IS NOT NULL)
GROUP BY desil ORDER BY desil;

SELECT desil, COUNT(*) AS n_item, ROUND(AVG(price_d), 2) AS avg_harga, ROUND(AVG(freight_d), 2) AS avg_freight,
       ROUND(100.0 * SUM(freight_d) / SUM(price_d), 2) AS freight_pct_dari_harga
FROM (SELECT price_d, freight_d, NTILE(10) OVER (ORDER BY price_d) AS desil
      FROM dl_item WHERE is_delivered_complete)
GROUP BY desil ORDER BY desil;

-- ============================================================
-- 7. WAKTU PROSES SELLER vs KURIR pada order Late (Delivered Population; deskriptif, bukan kausal)
--    handover = purchase -> carrier (exclude flag_carrier_before_purchase)
--    transit  = carrier -> customer (exclude flag_customer_before_carrier)
-- ============================================================
CREATE OR REPLACE TEMP TABLE dl_phase AS
SELECT is_late,
       CASE WHEN ts_carrier IS NOT NULL AND NOT flag_carrier_before_purchase
            THEN date_diff('second', ts_purchase, ts_carrier) / 86400.0 END AS d_handover,
       CASE WHEN ts_carrier IS NOT NULL AND NOT flag_customer_before_carrier
            THEN date_diff('second', ts_carrier, ts_customer) / 86400.0 END AS d_transit
FROM fact_orders WHERE is_delivered_complete;

SELECT CASE WHEN is_late THEN 'late' ELSE 'on-time' END AS kelompok,
       COUNT(d_handover) AS n_handover, ROUND(AVG(d_handover), 2) AS handover_mean, ROUND(quantile_cont(d_handover, 0.5), 2) AS handover_p50,
       COUNT(d_transit)  AS n_transit,  ROUND(AVG(d_transit), 2)  AS transit_mean,  ROUND(quantile_cont(d_transit, 0.5), 2)  AS transit_p50
FROM dl_phase GROUP BY is_late
UNION ALL
SELECT 'ALL', COUNT(d_handover), ROUND(AVG(d_handover), 2), ROUND(quantile_cont(d_handover, 0.5), 2),
       COUNT(d_transit), ROUND(AVG(d_transit), 2), ROUND(quantile_cont(d_transit, 0.5), 2)
FROM dl_phase
ORDER BY 1;

-- ============================================================
-- 8. Reconcile ke KPI terkunci dan angka addendum -> delivery_findings
--    PASS = cocok; CHECK = beda (jelaskan di docs); INFO = tanpa ekspektasi
-- ============================================================
CREATE OR REPLACE TEMP TABLE dl_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO dl_raw VALUES
 ('reconcile','Delivered Orders (Delivered Population)',        (SELECT COUNT(*) FROM fact_orders WHERE is_delivered_complete), 96470, 0),
 ('reconcile','Late orders (tanggal, D1)',                       (SELECT COUNT(*) FROM fact_orders WHERE is_late), 6534, 0),
 ('reconcile','Late Rate % (terkunci Tahap 6)',                  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM fact_orders WHERE is_delivered_complete), 6.773, 0.0011),
 ('reconcile','On-Time Rate % (terkunci Tahap 6)',               (SELECT ROUND(100.0 - 100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM fact_orders WHERE is_delivered_complete), 93.227, 0.0011),
 ('reconcile','Late Rate % versi timestamp (sensitivity)',       (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late_ts_sensitivity) / COUNT(*), 3) FROM fact_orders WHERE is_delivered_complete), 8.112, 0.0011),
 ('reconcile','SUM(delivered_pop) bulanan = Delivered Population', (SELECT SUM(delivered_pop) FROM delivery_monthly), 96470, 0),
 ('reconcile','SUM(late_orders) bulanan = 6.534',                (SELECT SUM(late_orders) FROM delivery_monthly), 6534, 0),
 ('reconcile','SUM(n_delivered) per state = Delivered Population', (SELECT COUNT(*) FROM fact_orders WHERE is_delivered_complete AND customer_state IS NOT NULL), 96470, 0),
 ('coverage','item Delivered Population',                       (SELECT COUNT(*) FROM dl_item WHERE is_delivered_complete), NULL, 0),
 ('coverage','item Delivered Population ber-jarak',              (SELECT COUNT(distance_km) FROM dl_item WHERE is_delivered_complete), NULL, 0),
 ('coverage','item status delivered (addendum: 110.197)',        (SELECT COUNT(*) FROM dl_item WHERE order_status = 'delivered'), 110197, 0),
 ('coverage','item status delivered ber-jarak (addendum: 109.660)', (SELECT COUNT(distance_km) FROM dl_item WHERE order_status = 'delivered'), 109660, 0),
 ('coverage','cakupan jarak % (addendum: 99,51)',                (SELECT ROUND(100.0 * COUNT(distance_km) / COUNT(*), 2) FROM dl_item WHERE order_status = 'delivered'), 99.51, 0.011),
 ('distance','median jarak km (addendum)',                       (SELECT ROUND(quantile_cont(distance_km, 0.5), 1) FROM dl_item WHERE order_status = 'delivered'), 431.8, 0.11),
 ('distance','P95 jarak km (addendum)',                          (SELECT ROUND(quantile_cont(distance_km, 0.95), 1) FROM dl_item WHERE order_status = 'delivered'), 2085.4, 0.11),
 ('distance','maks jarak km (addendum)',                         (SELECT ROUND(MAX(distance_km), 1) FROM dl_item WHERE order_status = 'delivered'), 3399.2, 0.11),
 ('distance','jarak > 4.500 km',                                 (SELECT COUNT(*) FROM dl_item WHERE order_status = 'delivered' AND distance_km > 4500), 0, 0),
 ('freight','A23 desil-1: freight rata-rata (R$)',               (SELECT ROUND(AVG(freight_d), 2) FROM (SELECT freight_d, NTILE(10) OVER (ORDER BY distance_km) AS d FROM dl_item WHERE order_status = 'delivered' AND distance_km IS NOT NULL) WHERE d = 1), 12.98, 0.011),
 ('freight','A23 desil-10: freight rata-rata (R$)',              (SELECT ROUND(AVG(freight_d), 2) FROM (SELECT freight_d, NTILE(10) OVER (ORDER BY distance_km) AS d FROM dl_item WHERE order_status = 'delivered' AND distance_km IS NOT NULL) WHERE d = 10), 39.51, 0.011),
 ('freight','A23 desil-1: jarak rata-rata (km)',                 (SELECT ROUND(AVG(distance_km), 1) FROM (SELECT distance_km, NTILE(10) OVER (ORDER BY distance_km) AS d FROM dl_item WHERE order_status = 'delivered' AND distance_km IS NOT NULL) WHERE d = 1), 21.5, 0.11),
 ('freight','A23 desil-10: jarak rata-rata (km)',                (SELECT ROUND(AVG(distance_km), 1) FROM (SELECT distance_km, NTILE(10) OVER (ORDER BY distance_km) AS d FROM dl_item WHERE order_status = 'delivered' AND distance_km IS NOT NULL) WHERE d = 10), 2315.8, 0.11),
 ('freight','A22 desil-1: freight rata-rata vs berat (R$)',      (SELECT ROUND(AVG(freight_d), 2) FROM (SELECT freight_d, NTILE(10) OVER (ORDER BY weight_g) AS d FROM dl_item WHERE order_status = 'delivered' AND weight_g IS NOT NULL) WHERE d = 1), 15.20, 0.011),
 ('freight','A22 desil-10: freight rata-rata vs berat (R$)',     (SELECT ROUND(AVG(freight_d), 2) FROM (SELECT freight_d, NTILE(10) OVER (ORDER BY weight_g) AS d FROM dl_item WHERE order_status = 'delivered' AND weight_g IS NOT NULL) WHERE d = 10), 54.53, 0.011),
 ('freight','A22 desil-1: berat rata-rata (g)',                  (SELECT ROUND(AVG(weight_g), 0) FROM (SELECT weight_g, NTILE(10) OVER (ORDER BY weight_g) AS d FROM dl_item WHERE order_status = 'delivered' AND weight_g IS NOT NULL) WHERE d = 1), 252, 0.5),
 ('freight','A22 desil-10: berat rata-rata (g)',                 (SELECT ROUND(AVG(weight_g), 0) FROM (SELECT weight_g, NTILE(10) OVER (ORDER BY weight_g) AS d FROM dl_item WHERE order_status = 'delivered' AND weight_g IS NOT NULL) WHERE d = 10), 15568, 0.5),
 ('freight','A22 korelasi Pearson berat vs freight',             (SELECT ROUND(corr(weight_g, freight_d), 3) FROM dl_item WHERE order_status = 'delivered'), 0.610, 0.0011),
 ('estimate','A20 on-time/early rata-rata hari lebih cepat (tanggal)', (SELECT ROUND(AVG(date_diff('day', CAST(ts_customer AS DATE), CAST(ts_estimated AS DATE))), 2) FROM fact_orders WHERE is_delivered_complete AND NOT is_late), 13.51, 0.011),
 ('estimate','A20 on-time/early median hari lebih cepat',        (SELECT quantile_cont(date_diff('day', CAST(ts_customer AS DATE), CAST(ts_estimated AS DATE)), 0.5) FROM fact_orders WHERE is_delivered_complete AND NOT is_late), 13, 0.51),
 ('estimate','A20 late rata-rata hari lebih lambat',             (SELECT ROUND(AVG(date_diff('day', CAST(ts_estimated AS DATE), CAST(ts_customer AS DATE))), 2) FROM fact_orders WHERE is_delivered_complete AND is_late), 10.62, 0.011),
 ('estimate','A20 late median hari lebih lambat',                (SELECT quantile_cont(date_diff('day', CAST(ts_estimated AS DATE), CAST(ts_customer AS DATE)), 0.5) FROM fact_orders WHERE is_delivered_complete AND is_late), 7, 0.51),
 ('phase','A21 handover purchase->carrier rata-rata ALL (hari)', (SELECT ROUND(AVG(d_handover), 2) FROM dl_phase), 3.22, 0.011),
 ('phase','A21 handover rata-rata order Late (hari)',            (SELECT ROUND(AVG(d_handover), 2) FROM dl_phase WHERE is_late), 6.03, 0.011),
 ('phase','A21 transit rata-rata order on-time (hari)',          (SELECT ROUND(AVG(d_transit), 2) FROM dl_phase WHERE NOT is_late), 7.93, 0.011),
 ('phase','A21 transit rata-rata order Late (hari)',             (SELECT ROUND(AVG(d_transit), 2) FROM dl_phase WHERE is_late), 27.87, 0.011),
 ('trend','A-trend median delivery_days 2018-06',                (SELECT delivery_days_p50 FROM delivery_monthly WHERE year_month = '2018-06'), 7.96, 0.011),
 ('trend','A-trend median delivery_days 2018-07',                (SELECT delivery_days_p50 FROM delivery_monthly WHERE year_month = '2018-07'), 7.50, 0.011),
 ('trend','A-trend median delivery_days 2018-08',                (SELECT delivery_days_p50 FROM delivery_monthly WHERE year_month = '2018-08'), 7.00, 0.011),
 ('trend','median delivery_days 2018-02 (roadmap: 13,38-14,25 untuk 2018-02..03)', (SELECT delivery_days_p50 FROM delivery_monthly WHERE year_month = '2018-02'), NULL, 0),
 ('trend','median delivery_days 2018-03',                        (SELECT delivery_days_p50 FROM delivery_monthly WHERE year_month = '2018-03'), NULL, 0),
 ('intra','Single-Seller Delivered: % intra-state',              (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE same_state) / COUNT(*), 2) FROM dl_ss), NULL, 0),
 ('intra','intra-state rata-rata delivery_days',                 (SELECT ROUND(AVG(delivery_days), 2) FROM dl_ss WHERE same_state), 7.97, 0.011),
 ('intra','antar-state rata-rata delivery_days',                 (SELECT ROUND(AVG(delivery_days), 2) FROM dl_ss WHERE NOT same_state), 15.21, 0.011),
 ('intra','intra-state Late Rate %',                             (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM dl_ss WHERE same_state), 4.557, 0.0011),
 ('intra','antar-state Late Rate %',                             (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 3) FROM dl_ss WHERE NOT same_state), 8.138, 0.0011);

CREATE OR REPLACE TABLE delivery_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM dl_raw;

SELECT status, COUNT(*) AS n_metrik FROM delivery_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM delivery_findings ORDER BY section, metric;

-- ============================================================
-- 9. Output parquet
-- ============================================================
COPY delivery_monthly  TO 'data/processed/10_delivery_monthly.parquet'  (FORMAT PARQUET);
COPY delivery_findings TO 'data/processed/10_delivery_findings.parquet' (FORMAT PARQUET);
SELECT '10_delivery_monthly' AS file, COUNT(*) AS n FROM read_parquet('data/processed/10_delivery_monthly.parquet') UNION ALL
SELECT '10_delivery_findings', COUNT(*) FROM read_parquet('data/processed/10_delivery_findings.parquet');
