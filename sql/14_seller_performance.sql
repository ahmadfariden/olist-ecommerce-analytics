-- ============================================================
-- Tahap 15 — Seller Performance & Marketplace Concentration
-- File: sql/14_seller_performance.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/14_seller_performance.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (seller / tier / desil seller / state / pasangan state); dinyatakan di tiap blok
-- POPULATION:  Revenue Population untuk revenue dan tier (basis KPI terkunci); Item Population hanya sebagai
--              pembanding addendum roadmap; Single-Seller Population (n = 96.922, D10) untuk Late Rate,
--              skor review, handover, dan cross-state per seller
-- DENOMINATOR: 3.095 seller untuk persentase seller; Item Revenue total Revenue Population untuk % revenue
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * Revenue per seller = SUM(price) per seller_id (atribusi item-level yang nyata); jumlah seluruh seller =
--     Item Revenue total.
--   * Tier berbasis jumlah order (D11): Top >= 100, Mid 30-99, Long-tail < 30 (termasuk seller tanpa revenue order).
--   * Late Rate, skor review, dan handover per seller HANYA untuk seller >= 30 order (D6) dan HANYA dari
--     Single-Seller Population (D10), karena atribusi order multi-seller ambigu.
--   * Handover = purchase -> carrier (exclude flag_carrier_before_purchase); durasi tahap memakai baris tanpa
--     anomali urutan tanggal.
--   * Info deskriptif "seller < 10 order" BUKAN batas segmen.
--   * Hubungan antar variabel = asosiasi, bukan kausal.
-- Output: data/processed/14_seller_summary.parquet, 14_seller_findings.parquet
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helper: agregat item per seller dan metrik Single-Seller per seller
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE sl_agg AS
SELECT s.seller_id, s.seller_state,
       COUNT(DISTINCT i.order_id) FILTER (WHERE i.is_revenue_order)    AS n_orders_rp,
       COUNT(*) FILTER (WHERE i.is_revenue_order)                       AS n_items_rp,
       COALESCE(SUM(i.price) FILTER (WHERE i.is_revenue_order), 0)      AS rev_rp,
       COUNT(DISTINCT i.order_id)                                       AS n_orders_ip,
       COUNT(*)                                                         AS n_items_ip,
       COALESCE(SUM(i.price), 0)                                        AS rev_ip
FROM dim_seller s LEFT JOIN fact_order_items i ON i.seller_id = s.seller_id
GROUP BY s.seller_id, s.seller_state;

CREATE OR REPLACE TEMP TABLE sl_single AS
SELECT f.single_seller_id AS seller_id,
       COUNT(*) AS n_single_orders,
       COUNT(*) FILTER (WHERE f.is_delivered_complete) AS n_single_delivered,
       COUNT(*) FILTER (WHERE f.is_delivered_complete AND f.is_late) AS n_single_late,
       COUNT(f.review_score) AS n_single_reviewed,
       AVG(f.review_score)   AS avg_score,
       quantile_cont(CASE WHEN f.ts_carrier IS NOT NULL AND NOT f.flag_carrier_before_purchase
                          THEN date_diff('second', f.ts_purchase, f.ts_carrier) / 86400.0 END, 0.5) AS handover_p50,
       quantile_cont(f.delivery_days, 0.5) AS delivery_p50,
       AVG(CAST(f.freight_total AS DOUBLE)) AS avg_freight_per_order,
       COUNT(*) FILTER (WHERE f.customer_state <> d.seller_state) AS n_cross_state
FROM fact_orders f JOIN dim_seller d ON d.seller_id = f.single_seller_id
WHERE f.is_single_seller_pop GROUP BY f.single_seller_id;

CREATE OR REPLACE TABLE seller_summary AS
SELECT a.seller_id, a.seller_state,
       a.n_orders_rp, a.n_items_rp, ROUND(CAST(a.rev_rp AS DOUBLE), 2) AS item_revenue_rp,
       a.n_orders_ip, a.n_items_ip, ROUND(CAST(a.rev_ip AS DOUBLE), 2) AS item_revenue_ip,
       CASE WHEN a.n_orders_rp >= 100 THEN '1 top (>= 100 order)'
            WHEN a.n_orders_rp >= 30  THEN '2 mid (30-99 order)'
            ELSE '3 long-tail (< 30 order)' END AS tier,
       CASE WHEN a.n_orders_ip >= 100 THEN '1 top (>= 100 order)'
            WHEN a.n_orders_ip >= 30  THEN '2 mid (30-99 order)'
            ELSE '3 long-tail (< 30 order)' END AS tier_item_pop,
       ROW_NUMBER() OVER (ORDER BY a.rev_rp DESC, a.seller_id) AS rank_revenue_rp,
       ROW_NUMBER() OVER (ORDER BY a.rev_ip DESC, a.seller_id) AS rank_revenue_ip,
       COALESCE(s.n_single_orders, 0) AS n_single_orders,
       COALESCE(s.n_single_delivered, 0) AS n_single_delivered,
       COALESCE(s.n_single_reviewed, 0)  AS n_single_reviewed,
       ROUND(100.0 * s.n_single_late / NULLIF(s.n_single_delivered, 0), 3) AS late_rate_pct,
       ROUND(s.avg_score, 3) AS avg_review_score,
       ROUND(s.handover_p50, 2) AS handover_p50_days,
       ROUND(s.delivery_p50, 2) AS delivery_p50_days,
       ROUND(100.0 * s.n_cross_state / NULLIF(s.n_single_orders, 0), 2) AS pct_cross_state,
       ROUND(s.avg_freight_per_order, 2) AS avg_freight_per_order,
       (COALESCE(s.n_single_delivered, 0) >= 30) AS eligible_rate,
       (COALESCE(s.n_single_reviewed, 0) >= 30)  AS eligible_review
FROM sl_agg a LEFT JOIN sl_single s ON s.seller_id = a.seller_id;

-- ============================================================
-- 1. KONSENTRASI: Pareto, Lorenz (desil), Gini, HHI
-- ============================================================
-- 1.1 Pareto: porsi revenue dari top k% seller (k% terhadap 3.095 seller; k = pembulatan ke atas)
--     Dua basis: Revenue Population (KPI terkunci) dan Item Population (basis addendum roadmap)
CREATE OR REPLACE TEMP TABLE sl_pareto AS
WITH n AS (SELECT COUNT(*) AS n_seller FROM seller_summary),
     tot AS (SELECT SUM(item_revenue_rp) AS t_rp, SUM(item_revenue_ip) AS t_ip FROM seller_summary),
     p(pct) AS (VALUES (1), (5), (10), (20), (50))
SELECT p.pct AS top_pct_seller,
       CAST(CEIL(p.pct / 100.0 * n.n_seller) AS INTEGER) AS n_seller_top,
       ROUND(100.0 * (SELECT SUM(item_revenue_rp) FROM seller_summary WHERE rank_revenue_rp <= CEIL(p.pct / 100.0 * n.n_seller)) / tot.t_rp, 2) AS pct_revenue_rp,
       ROUND(100.0 * (SELECT SUM(item_revenue_ip) FROM seller_summary WHERE rank_revenue_ip <= CEIL(p.pct / 100.0 * n.n_seller)) / tot.t_ip, 2) AS pct_revenue_ip
FROM p, n, tot ORDER BY p.pct;

SELECT * FROM sl_pareto;

-- 1.2 Lorenz per desil seller (urut revenue turun; 3.095 seller; desil 1 = 10% seller terbesar)
SELECT desil, COUNT(*) AS n_seller, ROUND(SUM(item_revenue_rp), 2) AS item_revenue,
       ROUND(100.0 * SUM(item_revenue_rp) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue,
       ROUND(100.0 * SUM(SUM(item_revenue_rp)) OVER (ORDER BY desil) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue_kumulatif
FROM (SELECT item_revenue_rp, NTILE(10) OVER (ORDER BY item_revenue_rp DESC, seller_id) AS desil FROM seller_summary)
GROUP BY desil ORDER BY desil;

-- 1.3 Gini (revenue dan jumlah order; semua 3.095 seller, termasuk tanpa revenue) dan HHI revenue
SELECT ROUND((2.0 * SUM(rn * x)) / (COUNT(*) * SUM(x)) - (COUNT(*) + 1.0) / COUNT(*), 4) AS gini_revenue_rp
FROM (SELECT item_revenue_rp AS x, ROW_NUMBER() OVER (ORDER BY item_revenue_rp, seller_id) AS rn FROM seller_summary);

SELECT ROUND((2.0 * SUM(rn * x)) / (COUNT(*) * SUM(x)) - (COUNT(*) + 1.0) / COUNT(*), 4) AS gini_order_rp
FROM (SELECT CAST(n_orders_rp AS DOUBLE) AS x, ROW_NUMBER() OVER (ORDER BY n_orders_rp, seller_id) AS rn FROM seller_summary);

SELECT ROUND(SUM(POW(100.0 * item_revenue_rp / (SELECT SUM(item_revenue_rp) FROM seller_summary), 2)), 2) AS hhi_revenue_rp
FROM seller_summary;

-- 1.4 Top 10 seller by revenue
SELECT rank_revenue_rp AS ranking, seller_id, seller_state, n_orders_rp, item_revenue_rp,
       ROUND(100.0 * item_revenue_rp / (SELECT SUM(item_revenue_rp) FROM seller_summary), 2) AS pct_revenue,
       ROUND(item_revenue_rp / NULLIF(n_orders_rp, 0), 2) AS revenue_per_order,
       avg_review_score, late_rate_pct
FROM seller_summary WHERE rank_revenue_rp <= 10 ORDER BY rank_revenue_rp;

-- 1.5 Top 10 seller: porsi baris item terhadap Item Population (112.650)
SELECT ROUND(100.0 * SUM(n_items_ip) / (SELECT SUM(n_items_ip) FROM seller_summary), 2) AS top10_pct_item_rows
FROM (SELECT n_items_ip FROM seller_summary ORDER BY n_items_ip DESC, seller_id LIMIT 10);

-- ============================================================
-- 2. SEGMENTASI TIER (D11): Top >= 100, Mid 30-99, Long-tail < 30
-- ============================================================
-- 2.1 Dua basis berdampingan
SELECT tier, COUNT(*) AS n_seller,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_seller,
       SUM(n_orders_rp) AS n_order_rp,
       ROUND(SUM(item_revenue_rp), 2) AS item_revenue_rp,
       ROUND(100.0 * SUM(item_revenue_rp) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue_rp,
       COUNT(*) FILTER (WHERE n_orders_rp = 0) AS n_seller_tanpa_revenue_order
FROM seller_summary GROUP BY tier ORDER BY tier;

SELECT tier_item_pop AS tier, COUNT(*) AS n_seller,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_seller,
       ROUND(SUM(item_revenue_ip), 2) AS item_revenue_ip,
       ROUND(100.0 * SUM(item_revenue_ip) / SUM(SUM(item_revenue_ip)) OVER (), 2) AS pct_revenue_ip
FROM seller_summary GROUP BY tier_item_pop ORDER BY tier_item_pop;

-- 2.2 Top + Mid = seller eligible (>= 30 order): jumlah dan porsi revenue
SELECT COUNT(*) FILTER (WHERE n_orders_rp >= 30) AS n_seller_ge_30,
       ROUND(100.0 * SUM(item_revenue_rp) FILTER (WHERE n_orders_rp >= 30) / SUM(item_revenue_rp), 2) AS pct_revenue_ge_30,
       COUNT(*) FILTER (WHERE n_orders_rp < 10) AS n_seller_lt_10_order_rp,
       COUNT(*) FILTER (WHERE n_orders_ip < 10) AS n_seller_lt_10_order_ip
FROM seller_summary;

-- 2.3 Distribusi seller menurut jumlah order (Revenue Population)
SELECT CASE WHEN n_orders_rp = 0 THEN '0: tanpa revenue order' WHEN n_orders_rp = 1 THEN '1' WHEN n_orders_rp <= 4 THEN '2-4'
            WHEN n_orders_rp <= 9 THEN '5-9' WHEN n_orders_rp <= 29 THEN '10-29' WHEN n_orders_rp <= 99 THEN '30-99'
            WHEN n_orders_rp <= 299 THEN '100-299' ELSE '>= 300' END AS jumlah_order,
       COUNT(*) AS n_seller, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_seller,
       ROUND(100.0 * SUM(item_revenue_rp) / SUM(SUM(item_revenue_rp)) OVER (), 2) AS pct_revenue
FROM seller_summary GROUP BY 1 ORDER BY MIN(n_orders_rp);

-- 2.4 Sebaran tier menurut state seller (state dengan seller terbanyak)
SELECT seller_state AS state, COUNT(*) AS n_seller,
       COUNT(*) FILTER (WHERE tier = '1 top (>= 100 order)') AS n_top,
       COUNT(*) FILTER (WHERE tier = '2 mid (30-99 order)')  AS n_mid,
       COUNT(*) FILTER (WHERE tier = '3 long-tail (< 30 order)') AS n_long_tail,
       ROUND(100.0 * COUNT(*) FILTER (WHERE tier = '1 top (>= 100 order)') / COUNT(*), 2) AS pct_top_di_state,
       ROUND(100.0 * SUM(item_revenue_rp) / (SELECT SUM(item_revenue_rp) FROM seller_summary), 2) AS pct_revenue_nasional
FROM seller_summary GROUP BY seller_state ORDER BY n_seller DESC LIMIT 10;

-- ============================================================
-- 3. SUPPLY-DEMAND per STATE (semua state; share seller vs share customer vs share revenue)
-- ============================================================
CREATE OR REPLACE TABLE seller_state_balance AS
WITH s AS (SELECT seller_state AS state, COUNT(*) AS n_seller, SUM(item_revenue_rp) AS rev_seller_side FROM seller_summary GROUP BY seller_state),
     c AS (SELECT customer_state AS state, COUNT(*) AS n_customer,
                  SUM(item_revenue) FILTER (WHERE is_revenue_order) AS rev_customer_side
           FROM fact_orders GROUP BY customer_state)
SELECT COALESCE(c.state, s.state) AS state,
       COALESCE(s.n_seller, 0) AS n_seller, COALESCE(c.n_customer, 0) AS n_customer,
       ROUND(100.0 * COALESCE(s.n_seller, 0) / SUM(COALESCE(s.n_seller, 0)) OVER (), 2) AS pct_seller,
       ROUND(100.0 * COALESCE(c.n_customer, 0) / SUM(COALESCE(c.n_customer, 0)) OVER (), 2) AS pct_customer,
       ROUND(100.0 * CAST(COALESCE(c.rev_customer_side, 0) AS DOUBLE) / SUM(CAST(COALESCE(c.rev_customer_side, 0) AS DOUBLE)) OVER (), 2) AS pct_revenue_sisi_customer,
       ROUND(100.0 * CAST(COALESCE(s.rev_seller_side, 0) AS DOUBLE) / SUM(CAST(COALESCE(s.rev_seller_side, 0) AS DOUBLE)) OVER (), 2) AS pct_revenue_sisi_seller
FROM c FULL OUTER JOIN s ON s.state = c.state;

SELECT state, n_seller, n_customer, pct_seller, pct_customer, pct_revenue_sisi_customer, pct_revenue_sisi_seller,
       ROUND(pct_revenue_sisi_seller - pct_revenue_sisi_customer, 2) AS selisih_revenue_poin
FROM seller_state_balance ORDER BY ABS(pct_revenue_sisi_seller - pct_revenue_sisi_customer) DESC;

-- State yang punya customer tetapi tanpa seller
SELECT state, n_customer, pct_customer FROM seller_state_balance WHERE n_seller = 0 ORDER BY n_customer DESC;

-- ============================================================
-- 4. KINERJA SELLER (>= 30 order; Single-Seller Population): Late Rate, skor, handover, cross-state
-- ============================================================
-- 4.1 Cakupan seller yang memenuhi syarat
SELECT COUNT(*) FILTER (WHERE n_orders_rp >= 30) AS n_seller_ge_30_order,
       COUNT(*) FILTER (WHERE eligible_rate)     AS n_eligible_late_rate,
       COUNT(*) FILTER (WHERE eligible_review)   AS n_eligible_review,
       COUNT(*) FILTER (WHERE eligible_rate AND n_orders_rp < 30) AS n_eligible_rate_tapi_lt_30_order
FROM seller_summary;

-- 4.2 Perbandingan tier (dipool; hanya Single-Seller Population, seller >= 30 order)
SELECT ss.tier, COUNT(DISTINCT ss.seller_id) AS n_seller,
       SUM(ss.n_single_delivered) AS n_delivered,
       ROUND(100.0 * SUM(s.n_single_late) / NULLIF(SUM(s.n_single_delivered), 0), 3) AS late_rate_pct_pooled,
       SUM(s.n_single_reviewed) AS n_reviewed,
       ROUND(SUM(s.avg_score * s.n_single_reviewed) / NULLIF(SUM(s.n_single_reviewed), 0), 3) AS avg_score_pooled,
       ROUND(quantile_cont(ss.handover_p50_days, 0.5), 2) AS median_handover_p50_antar_seller,
       ROUND(AVG(ss.pct_cross_state), 2) AS rata2_pct_cross_state
FROM seller_summary ss JOIN sl_single s ON s.seller_id = ss.seller_id
WHERE ss.n_orders_rp >= 30 GROUP BY ss.tier ORDER BY ss.tier;

-- 4.3 Sebaran metrik antar seller eligible (persentil antar seller)
SELECT ROUND(quantile_cont(late_rate_pct, 0.1), 2) AS late_p10, ROUND(quantile_cont(late_rate_pct, 0.5), 2) AS late_p50, ROUND(quantile_cont(late_rate_pct, 0.9), 2) AS late_p90,
       ROUND(quantile_cont(avg_review_score, 0.1), 3) AS skor_p10, ROUND(quantile_cont(avg_review_score, 0.5), 3) AS skor_p50, ROUND(quantile_cont(avg_review_score, 0.9), 3) AS skor_p90,
       ROUND(quantile_cont(handover_p50_days, 0.1), 2) AS handover_p10, ROUND(quantile_cont(handover_p50_days, 0.5), 2) AS handover_p50, ROUND(quantile_cont(handover_p50_days, 0.9), 2) AS handover_p90,
       COUNT(*) AS n_seller
FROM seller_summary WHERE eligible_rate;

-- 4.4 Korelasi antar metrik seller (deskriptif; seller eligible)
SELECT ROUND(corr(late_rate_pct, avg_review_score), 3)     AS r_late_vs_skor,
       ROUND(corr(handover_p50_days, late_rate_pct), 3)    AS r_handover_vs_late,
       ROUND(corr(handover_p50_days, avg_review_score), 3) AS r_handover_vs_skor,
       ROUND(corr(pct_cross_state, late_rate_pct), 3)      AS r_crossstate_vs_late,
       ROUND(corr(LN(NULLIF(n_orders_rp, 0)), avg_review_score), 3) AS r_log_order_vs_skor,
       COUNT(*) AS n_seller
FROM seller_summary WHERE eligible_rate AND eligible_review;

-- 4.5 Seller dengan Late Rate tertinggi dan handover terlama (seller eligible)
SELECT 'late rate tertinggi' AS urutan, * FROM (
    SELECT seller_id, seller_state, n_orders_rp, n_single_delivered, late_rate_pct, avg_review_score, handover_p50_days, pct_cross_state
    FROM seller_summary WHERE eligible_rate ORDER BY late_rate_pct DESC, n_single_delivered DESC LIMIT 10)
UNION ALL
SELECT 'handover terlama', * FROM (
    SELECT seller_id, seller_state, n_orders_rp, n_single_delivered, late_rate_pct, avg_review_score, handover_p50_days, pct_cross_state
    FROM seller_summary WHERE eligible_rate ORDER BY handover_p50_days DESC, n_single_delivered DESC LIMIT 10)
ORDER BY urutan DESC;

-- 4.6 Konsentrasi nilai: Top-tier menurut revenue vs skor/late (10 seller revenue terbesar)
SELECT rank_revenue_rp AS ranking, seller_state, n_orders_rp, item_revenue_rp, late_rate_pct, avg_review_score, handover_p50_days, pct_cross_state
FROM seller_summary WHERE rank_revenue_rp <= 10 ORDER BY rank_revenue_rp;

-- ============================================================
-- 5. CROSS-STATE SHIPMENT per STATE SELLER (Single-Seller Population, revenue order)
-- ============================================================
SELECT d.seller_state, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.customer_state = d.seller_state) / COUNT(*), 2) AS pct_intra_state,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.customer_state <> d.seller_state) / COUNT(*), 2) AS pct_cross_state,
       ROUND(AVG(f.delivery_days), 2) AS avg_delivery_days,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_delivered_complete AND f.is_late)
             / NULLIF(COUNT(*) FILTER (WHERE f.is_delivered_complete), 0), 3) AS late_rate_pct,
       ROUND(AVG(CAST(f.freight_total AS DOUBLE)), 2) AS avg_freight_per_order
FROM fact_orders f JOIN dim_seller d ON d.seller_id = f.single_seller_id
WHERE f.is_single_seller_pop GROUP BY d.seller_state ORDER BY n_order DESC;

-- 5.1 Distribusi pct_cross_state antar seller eligible
SELECT ROUND(quantile_cont(pct_cross_state, 0.1), 2) AS p10, ROUND(quantile_cont(pct_cross_state, 0.5), 2) AS p50,
       ROUND(quantile_cont(pct_cross_state, 0.9), 2) AS p90, COUNT(*) AS n_seller,
       COUNT(*) FILTER (WHERE pct_cross_state >= 90) AS n_seller_ge_90pct_cross_state
FROM seller_summary WHERE eligible_rate;

-- ============================================================
-- 6. Reconcile ke KPI terkunci dan angka addendum -> seller_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE sel_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO sel_raw VALUES
 ('reconcile','n seller (dim_seller)',                          (SELECT COUNT(*) FROM seller_summary), 3095, 0),
 ('reconcile','SUM(revenue seller) = Item Revenue Revenue Population (R$)', (SELECT SUM(item_revenue_rp) FROM seller_summary), 13494400.74, 0.02),
 ('reconcile','selisih SUM(revenue seller) vs Item Revenue KPI (R$)',
        (SELECT ABS((SELECT SUM(item_revenue_rp) FROM seller_summary) - (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order))), 0, 0.02),
 ('reconcile','SUM(revenue seller) Item Population (R$)',        (SELECT SUM(item_revenue_ip) FROM seller_summary), 13591643.70, 0.02),
 ('reconcile','SUM(item seller) = Item Population',              (SELECT SUM(n_items_ip) FROM seller_summary), 112650, 0),
 ('reconcile','SUM(item seller) Revenue Population',             (SELECT SUM(n_items_rp) FROM seller_summary), 112101, 0),
 ('reconcile','seller dengan >= 1 item (Item Population)',       (SELECT COUNT(*) FROM seller_summary WHERE n_orders_ip > 0), NULL, 0),
 ('reconcile','seller dengan >= 1 revenue order',                (SELECT COUNT(*) FROM seller_summary WHERE n_orders_rp > 0), 3053, 0),
 ('tier','Top-tier (>= 100 order) n seller',                     (SELECT COUNT(*) FROM seller_summary WHERE tier LIKE '1%'), 210, 0),
 ('tier','Mid-tier (30-99) n seller',                            (SELECT COUNT(*) FROM seller_summary WHERE tier LIKE '2%'), 424, 0),
 ('tier','Long-tail (< 30) n seller (termasuk tanpa revenue order)', (SELECT COUNT(*) FROM seller_summary WHERE tier LIKE '3%'), 2461, 0),
 ('tier','Top-tier % seller',                                    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE tier LIKE '1%') / COUNT(*), 2) FROM seller_summary), 6.79, 0.011),
 ('tier','Long-tail % seller',                                   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE tier LIKE '3%') / COUNT(*), 2) FROM seller_summary), 79.52, 0.011),
 ('tier','Top-tier % revenue (Item Population; addendum 51,48)', (SELECT ROUND(100.0 * SUM(item_revenue_ip) FILTER (WHERE tier_item_pop LIKE '1%') / SUM(item_revenue_ip), 2) FROM seller_summary), 51.48, 0.011),
 ('tier','Mid-tier % revenue (Item Population; addendum 25,32)', (SELECT ROUND(100.0 * SUM(item_revenue_ip) FILTER (WHERE tier_item_pop LIKE '2%') / SUM(item_revenue_ip), 2) FROM seller_summary), 25.32, 0.011),
 ('tier','Long-tail % revenue (Item Population; addendum 23,20)',(SELECT ROUND(100.0 * SUM(item_revenue_ip) FILTER (WHERE tier_item_pop LIKE '3%') / SUM(item_revenue_ip), 2) FROM seller_summary), 23.20, 0.011),
 ('tier','Top-tier % revenue (Revenue Population; EDA 51,68)',   (SELECT ROUND(100.0 * SUM(item_revenue_rp) FILTER (WHERE tier LIKE '1%') / SUM(item_revenue_rp), 2) FROM seller_summary), 51.68, 0.011),
 ('tier','Mid-tier % revenue (Revenue Population)',              (SELECT ROUND(100.0 * SUM(item_revenue_rp) FILTER (WHERE tier LIKE '2%') / SUM(item_revenue_rp), 2) FROM seller_summary), 25.40, 0.011),
 ('tier','Long-tail % revenue (Revenue Population)',             (SELECT ROUND(100.0 * SUM(item_revenue_rp) FILTER (WHERE tier LIKE '3%') / SUM(item_revenue_rp), 2) FROM seller_summary), 22.93, 0.011),
 ('tier','Top + Mid n seller (>= 30 order)',                     (SELECT COUNT(*) FROM seller_summary WHERE n_orders_rp >= 30), 634, 0),
 ('tier','Top + Mid % revenue (Item Population; addendum 76,8)', (SELECT ROUND(100.0 * SUM(item_revenue_ip) FILTER (WHERE n_orders_ip >= 30) / SUM(item_revenue_ip), 1) FROM seller_summary), 76.8, 0.051),
 ('tier','seller < 10 order (Item Population; addendum 1.824)',  (SELECT COUNT(*) FROM seller_summary WHERE n_orders_ip < 10), 1824, 0),
 ('tier','seller < 10 order (Revenue Population)',               (SELECT COUNT(*) FROM seller_summary WHERE n_orders_rp < 10), NULL, 0),
 ('pareto','top 1% seller (31): % revenue Item Population',      (SELECT pct_revenue_ip FROM sl_pareto WHERE top_pct_seller = 1), 26.07, 0.011),
 ('pareto','top 5% seller: % revenue Item Population',           (SELECT pct_revenue_ip FROM sl_pareto WHERE top_pct_seller = 5), 53.30, 0.011),
 ('pareto','top 10% seller: % revenue Item Population',          (SELECT pct_revenue_ip FROM sl_pareto WHERE top_pct_seller = 10), 67.56, 0.011),
 ('pareto','top 20% seller: % revenue Item Population',          (SELECT pct_revenue_ip FROM sl_pareto WHERE top_pct_seller = 20), 82.69, 0.011),
 ('pareto','top 1% seller: % revenue Revenue Population',        (SELECT pct_revenue_rp FROM sl_pareto WHERE top_pct_seller = 1), NULL, 0),
 ('pareto','top 10% seller: % revenue Revenue Population',       (SELECT pct_revenue_rp FROM sl_pareto WHERE top_pct_seller = 10), NULL, 0),
 ('pareto','top 20% seller: % revenue Revenue Population',       (SELECT pct_revenue_rp FROM sl_pareto WHERE top_pct_seller = 20), NULL, 0),
 ('pareto','n seller top 1%',                                    (SELECT n_seller_top FROM sl_pareto WHERE top_pct_seller = 1), 31, 0),
 ('pareto','top 10 seller % baris item (EDA 14,15)',             (SELECT ROUND(100.0 * SUM(n_items_ip) / (SELECT SUM(n_items_ip) FROM seller_summary), 2) FROM (SELECT n_items_ip FROM seller_summary ORDER BY n_items_ip DESC, seller_id LIMIT 10)), 14.15, 0.011),
 ('state','% seller di SP',                                      (SELECT pct_seller FROM seller_state_balance WHERE state = 'SP'), 59.74, 0.011),
 ('state','% customer di SP',                                    (SELECT pct_customer FROM seller_state_balance WHERE state = 'SP'), 41.98, 0.011),
 ('state','state customer tanpa seller (AL, AP, RR, TO)',        (SELECT COUNT(*) FROM seller_state_balance WHERE n_seller = 0), 4, 0),
 ('state','customer di state tanpa seller',                      (SELECT SUM(n_customer) FROM seller_state_balance WHERE n_seller = 0), 807, 0),
 ('eligible','seller eligible skor review (>= 30 single-seller reviewed; Tahap 12: 619)', (SELECT COUNT(*) FROM seller_summary WHERE eligible_review), 619, 0),
 ('eligible','seller eligible Late Rate (>= 30 single-seller delivered)', (SELECT COUNT(*) FROM seller_summary WHERE eligible_rate), NULL, 0),
 ('eligible','korelasi skor vs Late Rate (seller eligible review; Tahap 12: -0,541)', (SELECT ROUND(corr(late_rate_pct, avg_review_score), 3) FROM seller_summary WHERE eligible_review), -0.541, 0.0011);

CREATE OR REPLACE TABLE seller_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM sel_raw;

SELECT status, COUNT(*) AS n_metrik FROM seller_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM seller_findings ORDER BY section, metric;

-- ============================================================
-- 7. Output parquet
-- ============================================================
COPY seller_summary  TO 'data/processed/14_seller_summary.parquet'  (FORMAT PARQUET);
COPY seller_findings TO 'data/processed/14_seller_findings.parquet' (FORMAT PARQUET);
SELECT '14_seller_summary' AS file, COUNT(*) AS n FROM read_parquet('data/processed/14_seller_summary.parquet') UNION ALL
SELECT '14_seller_findings', COUNT(*) FROM read_parquet('data/processed/14_seller_findings.parquet');
