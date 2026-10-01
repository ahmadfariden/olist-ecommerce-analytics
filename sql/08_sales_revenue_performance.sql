-- ============================================================
-- Tahap 9 — Sales & Revenue Performance
-- File: sql/08_sales_revenue_performance.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/08_sales_revenue_performance.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (bulan / kuartal / kategori / state / hari); dinyatakan di tiap blok
-- POPULATION:  Revenue Population (is_revenue_order, n = 98.199) kecuali disebut;
--              tren memakai Analysis Window (period_quality = 'full', 2017-01..2018-08)
-- DENOMINATOR: Revenue Orders untuk AOV; Item Revenue untuk rasio freight; dinyatakan per blok
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah di sini):
--   * Item Revenue = SUM(price); Freight Revenue dipisah; GMV = Item + Freight; AOV tanpa ongkir.
--   * Bulan sparse/truncated/missing tampil sebagai anotasi (period_quality), bukan garis turun:
--     MoM hanya dihitung bila kedua bulan period_quality = 'full'.
--   * YoY hanya untuk bulan yang sama (Jan-Agu 2017 vs Jan-Agu 2018).
--   * Sensitivity wajib: revenue delivered-only vs Revenue Population penuh (D2).
--   * Revenue per kategori selalu dari price di fact_order_items (bukan payment_value).
--   * Hubungan antar variabel = asosiasi, bukan kausal.
-- Output: data/processed/08_sales_monthly.parquet, 08_sales_findings.parquet
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tren bulanan (GRAIN: bulan; POPULATION: Revenue Population; semua bulan ditampilkan
--    dengan period_quality; total_orders = Order Population pada bulan itu)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE sales_monthly AS
WITH cal AS (
    SELECT DISTINCT year_month, period_quality FROM dim_date
), agg AS (
    SELECT d.year_month,
           COUNT(*)                                                              AS total_orders,
           COUNT(*) FILTER (WHERE f.is_revenue_order)                            AS revenue_orders,
           SUM(f.item_revenue)  FILTER (WHERE f.is_revenue_order)                AS item_revenue,
           SUM(f.freight_total) FILTER (WHERE f.is_revenue_order)                AS freight_revenue,
           COUNT(*) FILTER (WHERE f.is_revenue_order AND f.order_status = 'delivered')            AS revenue_orders_delivered,
           SUM(f.item_revenue)  FILTER (WHERE f.is_revenue_order AND f.order_status = 'delivered') AS item_revenue_delivered
    FROM fact_orders f JOIN dim_date d ON d.date_key = f.purchase_date
    GROUP BY d.year_month
), m AS (
    SELECT c.year_month, c.period_quality,
           COALESCE(a.total_orders, 0)          AS total_orders,
           COALESCE(a.revenue_orders, 0)        AS revenue_orders,
           ROUND(CAST(COALESCE(a.item_revenue, 0) AS DOUBLE), 2)     AS item_revenue,
           ROUND(CAST(COALESCE(a.freight_revenue, 0) AS DOUBLE), 2)  AS freight_revenue,
           ROUND(CAST(COALESCE(a.item_revenue, 0) + COALESCE(a.freight_revenue, 0) AS DOUBLE), 2) AS gmv,
           ROUND(CAST(a.item_revenue AS DOUBLE) / NULLIF(a.revenue_orders, 0), 2)                 AS aov,
           ROUND(CAST(a.item_revenue + a.freight_revenue AS DOUBLE) / NULLIF(a.revenue_orders, 0), 2) AS aov_incl_freight,
           ROUND(100.0 * CAST(a.freight_revenue AS DOUBLE) / NULLIF(CAST(a.item_revenue AS DOUBLE), 0), 2) AS freight_pct_of_item,
           COALESCE(a.revenue_orders_delivered, 0) AS revenue_orders_delivered,
           ROUND(CAST(COALESCE(a.item_revenue_delivered, 0) AS DOUBLE), 2) AS item_revenue_delivered
    FROM cal c LEFT JOIN agg a USING (year_month)
)
SELECT m.*,
       (m.period_quality = 'full') AS show_in_trend,
       CASE WHEN m.period_quality = 'full' AND LAG(m.period_quality) OVER w = 'full'
            THEN ROUND(100.0 * (m.item_revenue / NULLIF(LAG(m.item_revenue) OVER w, 0) - 1), 2) END AS mom_item_revenue_pct,
       CASE WHEN m.period_quality = 'full' AND LAG(m.period_quality) OVER w = 'full'
            THEN ROUND(100.0 * (m.revenue_orders * 1.0 / NULLIF(LAG(m.revenue_orders) OVER w, 0) - 1), 2) END AS mom_revenue_orders_pct,
       CASE WHEN m.period_quality = 'full' AND LAG(m.period_quality) OVER w = 'full'
            THEN ROUND(100.0 * (m.item_revenue_delivered / NULLIF(LAG(m.item_revenue_delivered) OVER w, 0) - 1), 2) END AS mom_item_revenue_delivered_pct,
       ROUND(100.0 * (m.item_revenue - m.item_revenue_delivered) / NULLIF(m.item_revenue, 0), 2) AS pct_in_flight_revenue
FROM m
WINDOW w AS (ORDER BY m.year_month)
ORDER BY m.year_month;

SELECT year_month, period_quality, total_orders, revenue_orders, item_revenue, freight_revenue, gmv,
       aov, aov_incl_freight, freight_pct_of_item, mom_item_revenue_pct, mom_revenue_orders_pct
FROM sales_monthly ORDER BY year_month;

-- ------------------------------------------------------------
-- 2. Tren kuartalan (GRAIN: kuartal; hanya bulan period_quality = 'full';
--    kuartal dengan < 3 bulan 'full' ditandai tidak lengkap)
-- ------------------------------------------------------------
SELECT strftime(CAST(year_month || '-01' AS DATE), '%Y') || '-Q' ||
       CAST(quarter(CAST(year_month || '-01' AS DATE)) AS VARCHAR) AS kuartal,
       COUNT(*)                                  AS n_bulan_full,
       (COUNT(*) = 3)                            AS kuartal_lengkap,
       SUM(revenue_orders)                       AS revenue_orders,
       ROUND(SUM(item_revenue), 2)               AS item_revenue,
       ROUND(SUM(item_revenue) / SUM(revenue_orders), 2) AS aov
FROM sales_monthly WHERE show_in_trend
GROUP BY 1 ORDER BY 1;

-- ------------------------------------------------------------
-- 3. YoY bulan yang sama (Jan-Agu 2017 vs Jan-Agu 2018; POPULATION: Revenue Population)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE sales_yoy AS
SELECT substr(a.year_month, 6, 2)                 AS bulan,
       a.revenue_orders                           AS orders_2017, b.revenue_orders AS orders_2018,
       ROUND(100.0 * (b.revenue_orders * 1.0 / a.revenue_orders - 1), 2) AS yoy_orders_pct,
       a.item_revenue                             AS item_revenue_2017, b.item_revenue AS item_revenue_2018,
       ROUND(100.0 * (b.item_revenue / a.item_revenue - 1), 2)           AS yoy_item_revenue_pct,
       a.aov                                      AS aov_2017, b.aov AS aov_2018
FROM sales_monthly a
JOIN sales_monthly b ON substr(b.year_month, 6, 2) = substr(a.year_month, 6, 2)
WHERE substr(a.year_month, 1, 4) = '2017' AND substr(b.year_month, 1, 4) = '2018'
  AND a.period_quality = 'full' AND b.period_quality = 'full'
ORDER BY bulan;

SELECT * FROM sales_yoy;

SELECT 'Jan-Agu' AS periode,
       SUM(orders_2017) AS orders_2017, SUM(orders_2018) AS orders_2018,
       ROUND(100.0 * (SUM(orders_2018) * 1.0 / SUM(orders_2017) - 1), 2) AS yoy_orders_pct,
       ROUND(SUM(item_revenue_2017), 2) AS item_revenue_2017, ROUND(SUM(item_revenue_2018), 2) AS item_revenue_2018,
       ROUND(100.0 * (SUM(item_revenue_2018) / SUM(item_revenue_2017) - 1), 2) AS yoy_item_revenue_pct,
       ROUND(SUM(item_revenue_2018) / SUM(item_revenue_2017), 3) AS kali_lipat
FROM sales_yoy;

-- ------------------------------------------------------------
-- 4. Dekomposisi lonjakan 2017-11 vs 2017-10 (POPULATION: Revenue Population)
-- 4.1 Efek volume vs efek nilai per order: delta = volume + nilai (identitas eksak)
-- ------------------------------------------------------------
SELECT o.revenue_orders AS orders_okt, n.revenue_orders AS orders_nov,
       o.aov AS aov_okt, n.aov AS aov_nov,
       ROUND(n.item_revenue - o.item_revenue, 2) AS delta_item_revenue,
       ROUND((n.revenue_orders - o.revenue_orders) * (o.item_revenue / o.revenue_orders), 2) AS efek_volume_order,
       ROUND(n.revenue_orders * (n.item_revenue / n.revenue_orders - o.item_revenue / o.revenue_orders), 2) AS efek_nilai_per_order,
       ROUND(100.0 * (n.revenue_orders - o.revenue_orders) * (o.item_revenue / o.revenue_orders)
             / (n.item_revenue - o.item_revenue), 2) AS pct_delta_dari_volume
FROM (SELECT * FROM sales_monthly WHERE year_month = '2017-10') o,
     (SELECT * FROM sales_monthly WHERE year_month = '2017-11') n;

-- 4.2 Kontribusi per kategori terhadap kenaikan (top 10 by delta; kategori = category_en_clean)
CREATE OR REPLACE TEMP TABLE s_nov_cat AS
SELECT p.category_en_clean AS kategori,
       SUM(i.price) FILTER (WHERE i.purchase_date >= DATE '2017-10-01' AND i.purchase_date < DATE '2017-11-01') AS rev_okt,
       SUM(i.price) FILTER (WHERE i.purchase_date >= DATE '2017-11-01' AND i.purchase_date < DATE '2017-12-01') AS rev_nov,
       COUNT(DISTINCT i.order_id) FILTER (WHERE i.purchase_date >= DATE '2017-10-01' AND i.purchase_date < DATE '2017-11-01') AS orders_okt,
       COUNT(DISTINCT i.order_id) FILTER (WHERE i.purchase_date >= DATE '2017-11-01' AND i.purchase_date < DATE '2017-12-01') AS orders_nov
FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id
WHERE i.is_revenue_order AND i.purchase_date >= DATE '2017-10-01' AND i.purchase_date < DATE '2017-12-01'
GROUP BY p.category_en_clean;

SELECT kategori, ROUND(CAST(rev_okt AS DOUBLE), 2) AS rev_okt, ROUND(CAST(rev_nov AS DOUBLE), 2) AS rev_nov,
       ROUND(CAST(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0) AS DOUBLE), 2) AS delta,
       ROUND(100.0 * CAST(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0) AS DOUBLE)
             / SUM(CAST(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0) AS DOUBLE)) OVER (), 2) AS pct_dari_total_delta,
       ROUND(100.0 * CAST(rev_okt AS DOUBLE) / SUM(CAST(rev_okt AS DOUBLE)) OVER (), 2) AS share_okt,
       ROUND(100.0 * CAST(rev_nov AS DOUBLE) / SUM(CAST(rev_nov AS DOUBLE)) OVER (), 2) AS share_nov,
       orders_okt, orders_nov
FROM s_nov_cat ORDER BY delta DESC LIMIT 10;

-- 4.3 Kontribusi per state pelanggan (top 10 by delta)
CREATE OR REPLACE TEMP TABLE s_nov_state AS
SELECT customer_state AS state,
       SUM(item_revenue) FILTER (WHERE purchase_date >= DATE '2017-10-01' AND purchase_date < DATE '2017-11-01') AS rev_okt,
       SUM(item_revenue) FILTER (WHERE purchase_date >= DATE '2017-11-01' AND purchase_date < DATE '2017-12-01') AS rev_nov,
       COUNT(*) FILTER (WHERE purchase_date >= DATE '2017-10-01' AND purchase_date < DATE '2017-11-01') AS orders_okt,
       COUNT(*) FILTER (WHERE purchase_date >= DATE '2017-11-01' AND purchase_date < DATE '2017-12-01') AS orders_nov
FROM fact_orders
WHERE is_revenue_order AND purchase_date >= DATE '2017-10-01' AND purchase_date < DATE '2017-12-01'
GROUP BY customer_state;

SELECT state, ROUND(CAST(rev_okt AS DOUBLE), 2) AS rev_okt, ROUND(CAST(rev_nov AS DOUBLE), 2) AS rev_nov,
       ROUND(CAST(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0) AS DOUBLE), 2) AS delta,
       ROUND(100.0 * CAST(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0) AS DOUBLE)
             / SUM(CAST(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0) AS DOUBLE)) OVER (), 2) AS pct_dari_total_delta,
       ROUND(100.0 * CAST(rev_okt AS DOUBLE) / SUM(CAST(rev_okt AS DOUBLE)) OVER (), 2) AS share_okt,
       ROUND(100.0 * CAST(rev_nov AS DOUBLE) / SUM(CAST(rev_nov AS DOUBLE)) OVER (), 2) AS share_nov,
       orders_okt, orders_nov
FROM s_nov_state ORDER BY delta DESC LIMIT 10;

-- 4.4 Konsentrasi harian di Nov 2017 (GRAIN: hari; apakah lonjakan terpusat pada hari tertentu?)
WITH dly AS (
    SELECT purchase_date, COUNT(*) AS revenue_orders, SUM(item_revenue) AS item_revenue
    FROM fact_orders
    WHERE is_revenue_order AND purchase_date >= DATE '2017-11-01' AND purchase_date < DATE '2017-12-01'
    GROUP BY purchase_date
)
SELECT purchase_date, dayname(purchase_date) AS hari, revenue_orders,
       ROUND(CAST(item_revenue AS DOUBLE), 2) AS item_revenue,
       ROUND(100.0 * revenue_orders / SUM(revenue_orders) OVER (), 2) AS pct_orders_bulan,
       ROUND(revenue_orders * 1.0 / MEDIAN(revenue_orders) OVER (), 2) AS x_median_harian
FROM dly ORDER BY revenue_orders DESC LIMIT 7;

-- ------------------------------------------------------------
-- 5. Rasio freight terhadap harga (POPULATION: Revenue Population)
-- 5.1 Per kategori (hanya >= 100 revenue order, D6): tertinggi dan terendah
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE s_freight_cat AS
SELECT p.category_en_clean AS kategori,
       COUNT(DISTINCT i.order_id) AS revenue_orders,
       ROUND(CAST(SUM(i.price) AS DOUBLE), 2)         AS item_revenue,
       ROUND(CAST(SUM(i.freight_value) AS DOUBLE), 2) AS freight_revenue,
       ROUND(100.0 * CAST(SUM(i.freight_value) AS DOUBLE) / CAST(SUM(i.price) AS DOUBLE), 2) AS freight_pct_of_item
FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id
WHERE i.is_revenue_order GROUP BY p.category_en_clean HAVING COUNT(DISTINCT i.order_id) >= 100;

SELECT 'tertinggi' AS urutan, * FROM (SELECT * FROM s_freight_cat ORDER BY freight_pct_of_item DESC LIMIT 8)
UNION ALL
SELECT 'terendah', * FROM (SELECT * FROM s_freight_cat ORDER BY freight_pct_of_item ASC LIMIT 8)
ORDER BY urutan DESC, freight_pct_of_item DESC;

-- 5.2 Per state pelanggan (semua 27 state ditampilkan dengan n; tanpa tiering, D12)
SELECT customer_state AS state, COUNT(*) AS revenue_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_revenue_orders,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2) AS item_revenue,
       ROUND(CAST(SUM(freight_total) AS DOUBLE), 2) AS freight_revenue,
       ROUND(100.0 * CAST(SUM(freight_total) AS DOUBLE) / CAST(SUM(item_revenue) AS DOUBLE), 2) AS freight_pct_of_item,
       ROUND(CAST(AVG(freight_total) AS DOUBLE), 2) AS avg_freight_per_order,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2) AS aov
FROM fact_orders WHERE is_revenue_order
GROUP BY customer_state ORDER BY freight_pct_of_item DESC;

-- ------------------------------------------------------------
-- 6. Sensitivity delivered-only vs Revenue Population penuh (D2)
-- 6.1 Total
-- ------------------------------------------------------------
SELECT 'Revenue Population (penuh)' AS basis, COUNT(*) AS orders,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2) AS item_revenue,
       ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2) AS aov,
       100.00 AS pct_of_full
FROM fact_orders WHERE is_revenue_order
UNION ALL
SELECT 'delivered-only', COUNT(*), ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2),
       ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2),
       ROUND(100.0 * CAST(SUM(item_revenue) AS DOUBLE)
             / (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 2)
FROM fact_orders WHERE is_revenue_order AND order_status = 'delivered'
UNION ALL
SELECT 'in-flight (status <> delivered)', COUNT(*), ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2),
       ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2),
       ROUND(100.0 * CAST(SUM(item_revenue) AS DOUBLE)
             / (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 2)
FROM fact_orders WHERE is_revenue_order AND order_status <> 'delivered';

-- 6.2 In-flight per status
SELECT order_status, COUNT(*) AS orders, ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2) AS item_revenue,
       ROUND(100.0 * CAST(SUM(item_revenue) AS DOUBLE)
             / (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 3) AS pct_of_full
FROM fact_orders WHERE is_revenue_order AND order_status <> 'delivered'
GROUP BY order_status ORDER BY item_revenue DESC;

-- 6.3 Per bulan Analysis Window: apakah kesimpulan tren berubah jika delivered-only?
SELECT year_month, item_revenue, item_revenue_delivered, pct_in_flight_revenue,
       mom_item_revenue_pct, mom_item_revenue_delivered_pct,
       CASE WHEN mom_item_revenue_pct IS NULL THEN NULL
            WHEN SIGN(mom_item_revenue_pct) = SIGN(mom_item_revenue_delivered_pct) THEN 'sama' ELSE 'BEDA' END AS arah_mom
FROM sales_monthly WHERE show_in_trend ORDER BY year_month;

SELECT COUNT(*) FILTER (WHERE mom_item_revenue_pct IS NOT NULL) AS n_bulan_mom,
       COUNT(*) FILTER (WHERE mom_item_revenue_pct IS NOT NULL
                          AND SIGN(mom_item_revenue_pct) <> SIGN(mom_item_revenue_delivered_pct)) AS n_arah_beda,
       ROUND(MAX(pct_in_flight_revenue) FILTER (WHERE show_in_trend), 2) AS pct_in_flight_maks,
       ROUND(AVG(pct_in_flight_revenue) FILTER (WHERE show_in_trend), 2) AS pct_in_flight_rata2
FROM sales_monthly;

-- ------------------------------------------------------------
-- 7. Reconcile ke KPI terkunci (Tahap 6) dan identitas dekomposisi -> sales_findings
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE s_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO s_raw VALUES
 ('reconcile','Item Revenue Revenue Population (R$)',       (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 13494400.74, 0.011),
 ('reconcile','Freight Revenue Revenue Population (R$)',    (SELECT CAST(SUM(freight_total) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 2241126.29, 0.011),
 ('reconcile','GMV incl. Freight (R$)',                     (SELECT CAST(SUM(item_revenue + freight_total) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 15735527.03, 0.011),
 ('reconcile','Revenue Orders',                             (SELECT COUNT(*) FROM fact_orders WHERE is_revenue_order), 98199, 0),
 ('reconcile','AOV (R$)',                                   (SELECT ROUND(CAST(SUM(item_revenue) AS DOUBLE) / COUNT(*), 2) FROM fact_orders WHERE is_revenue_order), 137.42, 0.011),
 ('reconcile','SUM(item_revenue) semua bulan di sales_monthly - Item Revenue total (R$)',
        (SELECT ABS((SELECT SUM(item_revenue) FROM sales_monthly) - (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order))), 0, 0.02),
 ('reconcile','SUM(revenue_orders) semua bulan di sales_monthly - Revenue Orders', (SELECT ABS((SELECT SUM(revenue_orders) FROM sales_monthly) - 98199)), 0, 0),
 ('reconcile','SUM(total_orders) semua bulan di sales_monthly = Order Population', (SELECT SUM(total_orders) FROM sales_monthly), 99441, 0),
 ('reconcile','Item Revenue di dalam Analysis Window + di luar = total (selisih)',
        (SELECT ABS((SELECT SUM(item_revenue) FILTER (WHERE show_in_trend) FROM sales_monthly)
                  + (SELECT SUM(item_revenue) FILTER (WHERE NOT show_in_trend) FROM sales_monthly)
                  - (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order))), 0, 0.02),
 ('reconcile','Revenue per kategori (fact_order_items) = Item Revenue total (selisih)',
        (SELECT ABS((SELECT CAST(SUM(price) AS DOUBLE) FROM fact_order_items i JOIN dim_product p USING (product_id) WHERE i.is_revenue_order)
                  - (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order))), 0, 0.011),
 ('sensitivity','delivered-only % dari Item Revenue',       (SELECT ROUND(100.0 * CAST(SUM(item_revenue) AS DOUBLE) / (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order), 2) FROM fact_orders WHERE is_revenue_order AND order_status = 'delivered'), 97.98, 0.011),
 ('sensitivity','in-flight Item Revenue (R$)',              (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order AND order_status <> 'delivered'), 272902.63, 0.011),
 ('sensitivity','n bulan MoM yang arahnya BEDA (delivered-only vs penuh)',
        (SELECT COUNT(*) FROM sales_monthly WHERE mom_item_revenue_pct IS NOT NULL AND SIGN(mom_item_revenue_pct) <> SIGN(mom_item_revenue_delivered_pct)), NULL, 0),
 ('decomposition','efek volume + efek nilai - delta total (selisih)',
        (SELECT ABS(ROUND((n.revenue_orders - o.revenue_orders) * (o.item_revenue / o.revenue_orders), 6)
                  + ROUND(n.revenue_orders * (n.item_revenue / n.revenue_orders - o.item_revenue / o.revenue_orders), 6)
                  - (n.item_revenue - o.item_revenue))
         FROM (SELECT * FROM sales_monthly WHERE year_month = '2017-10') o, (SELECT * FROM sales_monthly WHERE year_month = '2017-11') n), 0, 0.001),
 ('decomposition','SUM(delta kategori) - delta total Item Revenue Nov-Okt (selisih)',
        (SELECT ABS((SELECT CAST(SUM(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0)) AS DOUBLE) FROM s_nov_cat)
                  - (SELECT n.item_revenue - o.item_revenue FROM (SELECT * FROM sales_monthly WHERE year_month = '2017-10') o, (SELECT * FROM sales_monthly WHERE year_month = '2017-11') n))), 0, 0.02),
 ('decomposition','SUM(delta state) - delta total Item Revenue Nov-Okt (selisih)',
        (SELECT ABS((SELECT CAST(SUM(COALESCE(rev_nov, 0) - COALESCE(rev_okt, 0)) AS DOUBLE) FROM s_nov_state)
                  - (SELECT n.item_revenue - o.item_revenue FROM (SELECT * FROM sales_monthly WHERE year_month = '2017-10') o, (SELECT * FROM sales_monthly WHERE year_month = '2017-11') n))), 0, 0.02),
 ('info','Item Revenue 2017-11 (R$)',                       (SELECT item_revenue FROM sales_monthly WHERE year_month = '2017-11'), 1003862.14, 0.011),
 ('info','Item Revenue 2017-10 (R$)',                       (SELECT item_revenue FROM sales_monthly WHERE year_month = '2017-10'), 660179.62, 0.011),
 ('info','YoY Jan-Agu: kali lipat Item Revenue',            (SELECT ROUND(SUM(item_revenue_2018) / SUM(item_revenue_2017), 3) FROM sales_yoy), NULL, 0),
 ('info','YoY Jan-Agu: pertumbuhan order (%)',              (SELECT ROUND(100.0 * (SUM(orders_2018) * 1.0 / SUM(orders_2017) - 1), 2) FROM sales_yoy), NULL, 0),
 ('info','n bulan full di tren',                            (SELECT COUNT(*) FROM sales_monthly WHERE show_in_trend), 20, 0);

CREATE OR REPLACE TABLE sales_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM s_raw;

SELECT status, COUNT(*) AS n_metrik FROM sales_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM sales_findings ORDER BY section, metric;

-- ------------------------------------------------------------
-- 8. Output parquet
-- ------------------------------------------------------------
COPY sales_monthly  TO 'data/processed/08_sales_monthly.parquet'  (FORMAT PARQUET);
COPY sales_findings TO 'data/processed/08_sales_findings.parquet' (FORMAT PARQUET);
SELECT '08_sales_monthly' AS file, COUNT(*) AS n FROM read_parquet('data/processed/08_sales_monthly.parquet') UNION ALL
SELECT '08_sales_findings', COUNT(*) FROM read_parquet('data/processed/08_sales_findings.parquet');
