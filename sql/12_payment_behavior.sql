-- ============================================================
-- Tahap 13 — Payment Behavior Analysis
-- File: sql/12_payment_behavior.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/12_payment_behavior.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (baris payment / order / bulan / state / bucket cicilan); dinyatakan di tiap blok
-- POPULATION:  Payment Population (order yang punya payment, n = 99.440) kecuali disebut;
--              Reconcilable Population (98.665) untuk rekonsiliasi payment vs item+freight
-- DENOMINATOR: n order (atau n baris payment bila disebut "per baris"); selalu ditampilkan
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * payment_value TIDAK dialokasikan ke kategori atau seller (order-level; 1.278 order multi-seller).
--     Revenue per kategori/seller selalu dari price di fact_order_items.
--   * Payment Total hanya untuk rekonsiliasi; bukan Item Revenue dan tidak dibandingkan langsung dengan GMV.
--   * Cicilan: hanya credit_card; baris dengan installments = 0 di-exclude.
--   * Tabel anak di-pre-aggregate ke grain order_id sebelum join (Fan-out Guard).
--   * Metode pembayaran vs Cancellation Rate / Review Score = asosiasi, bukan kausal.
-- Output: data/processed/12_payment_monthly.parquet, 12_payment_findings.parquet
-- ============================================================

-- 0. Helper: 1 baris per order (Payment Population)
CREATE OR REPLACE TEMP TABLE p_mix AS
SELECT order_id,
       array_to_string(list_sort(list_distinct(list(payment_type))), ' + ') AS payment_mix,
       COUNT(DISTINCT payment_type) AS n_types,
       COUNT(*)                     AS n_payments,
       SUM(payment_value)           AS payment_total,
       MAX(payment_installments) FILTER (WHERE payment_type = 'credit_card' AND NOT flag_zero_installments) AS max_inst_cc,
       BOOL_OR(payment_type = 'credit_card') AS any_cc,
       BOOL_OR(payment_type = 'boleto')      AS any_boleto,
       BOOL_OR(payment_type = 'voucher')     AS any_voucher,
       BOOL_OR(payment_type = 'debit_card')  AS any_debit,
       COUNT(*) FILTER (WHERE payment_type = 'voucher')     AS n_voucher_rows,
       SUM(payment_value) FILTER (WHERE payment_type = 'voucher') AS voucher_value
FROM fact_payments GROUP BY order_id;

CREATE OR REPLACE TEMP TABLE p_ord AS
SELECT m.*, f.purchase_date, f.customer_state, f.order_status,
       f.is_canceled, f.is_unavailable, f.has_items, f.is_delivered_complete, f.is_late,
       f.review_score, f.has_review, f.item_revenue, f.freight_total
FROM p_mix m JOIN fact_orders f ON f.order_id = m.order_id;

-- ============================================================
-- 1. SHARE METODE PEMBAYARAN
-- ============================================================
-- 1.1 Per baris payment (GRAIN: baris payment; reconcile 103.886 baris dan R$ 16.008.872,12)
SELECT payment_type, COUNT(*) AS n_payment,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_payment,
       ROUND(CAST(SUM(payment_value) AS DOUBLE), 2) AS total_value,
       ROUND(100.0 * CAST(SUM(payment_value) AS DOUBLE) / SUM(CAST(SUM(payment_value) AS DOUBLE)) OVER (), 2) AS pct_value,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_value,
       ROUND(quantile_cont(CAST(payment_value AS DOUBLE), 0.5), 2) AS median_value,
       ROUND(quantile_cont(CAST(payment_value AS DOUBLE), 0.95), 2) AS p95_value
FROM fact_payments GROUP BY payment_type ORDER BY n_payment DESC;

SELECT COUNT(*) AS n_payment, COUNT(DISTINCT order_id) AS payment_population,
       ROUND(CAST(SUM(payment_value) AS DOUBLE), 2) AS payment_total
FROM fact_payments;

-- 1.2 Per order: order yang memuat tiap tipe (sebuah order bisa masuk lebih dari satu baris; % terhadap 99.440)
SELECT payment_type, COUNT(DISTINCT order_id) AS n_order_memuat_tipe,
       ROUND(100.0 * COUNT(DISTINCT order_id) / (SELECT COUNT(*) FROM p_mix), 2) AS pct_payment_population
FROM fact_payments GROUP BY payment_type ORDER BY n_order_memuat_tipe DESC;

-- 1.3 Per order: kombinasi eksklusif (jumlah order = 99.440)
SELECT payment_mix, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3) AS pct_order,
       ROUND(CAST(SUM(payment_total) AS DOUBLE), 2) AS total_value,
       ROUND(CAST(AVG(payment_total) AS DOUBLE), 2) AS avg_order_payment,
       ROUND(quantile_cont(CAST(payment_total AS DOUBLE), 0.5), 2) AS median_order_payment
FROM p_mix GROUP BY payment_mix ORDER BY n_order DESC;

-- 1.4 Tren bulanan bauran pembayaran (GRAIN: bulan purchase; semua bulan tampil dengan period_quality)
CREATE OR REPLACE TABLE payment_monthly AS
WITH cal AS (SELECT DISTINCT year_month, period_quality FROM dim_date),
o AS (
    SELECT d.year_month, COUNT(*) AS payment_orders,
           COUNT(*) FILTER (WHERE m.any_cc)      AS n_cc,
           COUNT(*) FILTER (WHERE m.any_boleto)  AS n_boleto,
           COUNT(*) FILTER (WHERE m.any_voucher) AS n_voucher,
           COUNT(*) FILTER (WHERE m.any_debit)   AS n_debit,
           COUNT(*) FILTER (WHERE m.n_types > 1) AS n_multi_type
    FROM p_mix m JOIN fact_orders f ON f.order_id = m.order_id
    JOIN dim_date d ON d.date_key = f.purchase_date GROUP BY d.year_month
), c AS (
    SELECT d.year_month, COUNT(*) AS n_cc_rows,
           AVG(p.payment_installments) AS avg_installments,
           COUNT(*) FILTER (WHERE p.payment_installments > 1) AS n_installments_gt1
    FROM fact_payments p JOIN fact_orders f ON f.order_id = p.order_id
    JOIN dim_date d ON d.date_key = f.purchase_date
    WHERE p.payment_type = 'credit_card' AND NOT p.flag_zero_installments GROUP BY d.year_month
), v AS (
    SELECT d.year_month, SUM(p.payment_value) AS total_v,
           SUM(p.payment_value) FILTER (WHERE p.payment_type = 'credit_card') AS cc_v
    FROM fact_payments p JOIN fact_orders f ON f.order_id = p.order_id
    JOIN dim_date d ON d.date_key = f.purchase_date GROUP BY d.year_month
)
SELECT cal.year_month, cal.period_quality, (cal.period_quality = 'full') AS show_in_trend,
       COALESCE(o.payment_orders, 0) AS payment_orders,
       ROUND(100.0 * o.n_cc      / NULLIF(o.payment_orders, 0), 2) AS pct_orders_credit_card,
       ROUND(100.0 * o.n_boleto  / NULLIF(o.payment_orders, 0), 2) AS pct_orders_boleto,
       ROUND(100.0 * o.n_voucher / NULLIF(o.payment_orders, 0), 2) AS pct_orders_voucher,
       ROUND(100.0 * o.n_debit   / NULLIF(o.payment_orders, 0), 2) AS pct_orders_debit,
       ROUND(100.0 * o.n_multi_type / NULLIF(o.payment_orders, 0), 2) AS pct_orders_multi_type,
       ROUND(c.avg_installments, 2) AS avg_installments_cc,
       ROUND(100.0 * c.n_installments_gt1 / NULLIF(c.n_cc_rows, 0), 2) AS pct_cc_installments_gt1,
       ROUND(CAST(v.total_v AS DOUBLE), 2) AS payment_value_total,
       ROUND(100.0 * CAST(v.cc_v AS DOUBLE) / NULLIF(CAST(v.total_v AS DOUBLE), 0), 2) AS pct_value_credit_card
FROM cal LEFT JOIN o USING (year_month) LEFT JOIN c USING (year_month) LEFT JOIN v USING (year_month)
ORDER BY cal.year_month;

SELECT * FROM payment_monthly ORDER BY year_month;

-- ============================================================
-- 2. CICILAN KARTU KREDIT (credit_card saja; installments = 0 di-exclude)
-- ============================================================
-- 2.1 Distribusi per jumlah cicilan (GRAIN: baris payment credit_card)
SELECT payment_installments AS cicilan, COUNT(*) AS n_payment,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_payment_value,
       ROUND(quantile_cont(CAST(payment_value AS DOUBLE), 0.5), 2) AS median_payment_value,
       ROUND(AVG(CAST(payment_value AS DOUBLE) / payment_installments), 2) AS avg_nilai_per_cicilan
FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments
GROUP BY payment_installments ORDER BY payment_installments;

-- 2.2 Bucket cicilan dan hubungannya dengan nilai pembayaran
SELECT CASE WHEN payment_installments = 1 THEN '1x' WHEN payment_installments = 2 THEN '2x'
            WHEN payment_installments = 3 THEN '3x' WHEN payment_installments <= 6 THEN '4-6x'
            WHEN payment_installments <= 10 THEN '7-10x' ELSE '11x+' END AS cicilan,
       COUNT(*) AS n_payment, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
       ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) AS avg_payment_value,
       ROUND(AVG(CAST(payment_value AS DOUBLE) / payment_installments), 2) AS avg_nilai_per_cicilan
FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments
GROUP BY 1 ORDER BY MIN(payment_installments);

SELECT ROUND(corr(payment_installments, CAST(payment_value AS DOUBLE)), 3) AS r_cicilan_nilai_payment,
       COUNT(*) FILTER (WHERE payment_installments > 1) AS n_cicilan_gt1,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_installments > 1) / COUNT(*), 2) AS pct_cicilan_gt1,
       COUNT(*) AS n_payment_cc
FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments;

-- 2.3 Cicilan menurut nilai order (order credit_card-only; GRAIN: order; nilai = payment_total)
SELECT CASE WHEN payment_total < 50 THEN '1: < 50' WHEN payment_total < 100 THEN '2: 50-99'
            WHEN payment_total < 200 THEN '3: 100-199' WHEN payment_total < 500 THEN '4: 200-499'
            ELSE '5: >= 500' END AS nilai_order,
       COUNT(*) AS n_order,
       ROUND(AVG(max_inst_cc), 2) AS avg_cicilan,
       ROUND(100.0 * COUNT(*) FILTER (WHERE max_inst_cc > 1) / COUNT(*), 2) AS pct_cicilan_gt1,
       ROUND(100.0 * COUNT(*) FILTER (WHERE max_inst_cc >= 7) / COUNT(*), 2) AS pct_cicilan_ge7
FROM p_ord WHERE payment_mix = 'credit_card' AND max_inst_cc IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 3. ORDER MULTI-PAYMENT
-- ============================================================
-- 3.1 Kombinasi tipe pada order multi-tipe (2,26% dari Payment Population)
SELECT payment_mix, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM p_mix), 3) AS pct_payment_population
FROM p_mix WHERE n_types > 1 GROUP BY payment_mix ORDER BY n_order DESC;

-- 3.2 Jumlah baris payment per order (semua order) dan baris tambahan
SELECT CASE WHEN n_payments >= 6 THEN '6+' ELSE CAST(n_payments AS VARCHAR) END AS n_baris_payment,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3) AS pct
FROM p_mix GROUP BY 1 ORDER BY 1;

SELECT COUNT(*) AS n_order, SUM(n_payments) AS n_baris_payment,
       SUM(n_payments) - COUNT(*) AS baris_tambahan,
       COUNT(*) FILTER (WHERE n_payments > 1) AS n_order_multi_baris,
       COUNT(*) FILTER (WHERE n_payments > 1 AND n_types = 1) AS n_order_multi_baris_satu_tipe
FROM p_mix;

-- 3.3 Order credit_card + voucher: porsi voucher terhadap nilai order
SELECT COUNT(*) AS n_order,
       ROUND(AVG(100.0 * CAST(voucher_value AS DOUBLE) / NULLIF(CAST(payment_total AS DOUBLE), 0)), 2) AS rata2_porsi_voucher_pct,
       ROUND(quantile_cont(100.0 * CAST(voucher_value AS DOUBLE) / NULLIF(CAST(payment_total AS DOUBLE), 0), 0.5), 2) AS median_porsi_voucher_pct,
       ROUND(AVG(n_voucher_rows), 2) AS rata2_baris_voucher,
       ROUND(CAST(AVG(payment_total) AS DOUBLE), 2) AS avg_order_payment
FROM p_mix WHERE payment_mix = 'credit_card + voucher';

SELECT CASE WHEN 100.0 * CAST(voucher_value AS DOUBLE) / NULLIF(CAST(payment_total AS DOUBLE), 0) < 10 THEN '1: < 10%'
            WHEN 100.0 * CAST(voucher_value AS DOUBLE) / NULLIF(CAST(payment_total AS DOUBLE), 0) < 30 THEN '2: 10-29%'
            WHEN 100.0 * CAST(voucher_value AS DOUBLE) / NULLIF(CAST(payment_total AS DOUBLE), 0) < 60 THEN '3: 30-59%'
            WHEN 100.0 * CAST(voucher_value AS DOUBLE) / NULLIF(CAST(payment_total AS DOUBLE), 0) < 90 THEN '4: 60-89%'
            ELSE '5: >= 90%' END AS porsi_voucher,
       COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM p_mix WHERE payment_mix = 'credit_card + voucher' GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 4. METODE PEMBAYARAN vs CANCELLATION RATE dan vs REVIEW SCORE (korelasional)
--    POPULATION: Payment Population; review pada Review Population; late pada Delivered Population
-- ============================================================
-- 4.1 Per kombinasi pembayaran
SELECT payment_mix, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled)    / COUNT(*), 3) AS cancellation_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_unavailable) / COUNT(*), 3) AS unavailable_rate_pct,
       COUNT(review_score) AS n_ber_review,
       ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(AVG(review_score) FILTER (WHERE is_delivered_complete AND NOT is_late), 3) AS avg_score_order_on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_delivered_complete AND is_late)
             / NULLIF(COUNT(*) FILTER (WHERE is_delivered_complete), 0), 3) AS late_rate_pct
FROM p_ord GROUP BY payment_mix ORDER BY n_order DESC;

-- 4.2 Order credit_card-only menurut bucket cicilan maksimum
SELECT CASE WHEN max_inst_cc = 1 THEN '1x' WHEN max_inst_cc <= 3 THEN '2-3x' WHEN max_inst_cc <= 6 THEN '4-6x'
            WHEN max_inst_cc <= 10 THEN '7-10x' ELSE '11x+' END AS cicilan_maks,
       COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) AS cancellation_rate_pct,
       ROUND(AVG(review_score), 3) AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_delivered_complete AND is_late)
             / NULLIF(COUNT(*) FILTER (WHERE is_delivered_complete), 0), 3) AS late_rate_pct
FROM p_ord WHERE payment_mix = 'credit_card' AND max_inst_cc IS NOT NULL
GROUP BY 1 ORDER BY MIN(max_inst_cc);

-- 4.3 Pendalaman order voucher-saja (Cancellation Rate Tahap 10: 4,688%): status, jumlah baris, nilai
SELECT order_status, COUNT(*) AS n_order, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM p_ord WHERE payment_mix = 'voucher' GROUP BY order_status ORDER BY n_order DESC;

SELECT CASE WHEN n_payments = 1 THEN '1 voucher' WHEN n_payments = 2 THEN '2 voucher' ELSE '3+ voucher' END AS jumlah_voucher,
       COUNT(*) AS n_order, COUNT(*) FILTER (WHERE is_canceled) AS canceled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) AS cancellation_rate_pct,
       ROUND(CAST(AVG(payment_total) AS DOUBLE), 2) AS avg_order_payment
FROM p_ord WHERE payment_mix = 'voucher' GROUP BY 1 ORDER BY 1;

SELECT CASE WHEN payment_total < 25 THEN '1: < 25' WHEN payment_total < 50 THEN '2: 25-49'
            WHEN payment_total < 100 THEN '3: 50-99' WHEN payment_total < 200 THEN '4: 100-199' ELSE '5: >= 200' END AS nilai_order,
       COUNT(*) AS n_order, COUNT(*) FILTER (WHERE is_canceled) AS canceled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) AS cancellation_rate_pct,
       COUNT(*) FILTER (WHERE is_canceled AND has_items) AS canceled_dengan_item
FROM p_ord WHERE payment_mix = 'voucher' GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 5. METODE PEMBAYARAN per STATE (deskriptif; semua 27 state dengan n; tanpa tiering, D12)
-- ============================================================
SELECT customer_state AS state, COUNT(*) AS n_order,
       ROUND(100.0 * COUNT(*) FILTER (WHERE any_cc)      / COUNT(*), 2) AS pct_credit_card,
       ROUND(100.0 * COUNT(*) FILTER (WHERE any_boleto)  / COUNT(*), 2) AS pct_boleto,
       ROUND(100.0 * COUNT(*) FILTER (WHERE any_voucher) / COUNT(*), 2) AS pct_voucher,
       ROUND(100.0 * COUNT(*) FILTER (WHERE any_debit)   / COUNT(*), 2) AS pct_debit,
       ROUND(AVG(max_inst_cc), 2) AS avg_cicilan_cc,
       ROUND(100.0 * COUNT(*) FILTER (WHERE max_inst_cc > 1) / NULLIF(COUNT(*) FILTER (WHERE max_inst_cc IS NOT NULL), 0), 2) AS pct_cc_cicilan_gt1
FROM p_ord GROUP BY customer_state ORDER BY n_order DESC;

-- ============================================================
-- 6. REKONSILIASI payment vs item+freight (data-quality view; detail Tahap 6)
--    POPULATION: Reconcilable Population (order ada di items dan payments), DECIMAL eksak
-- ============================================================
CREATE OR REPLACE TEMP TABLE p_recon AS
SELECT i.order_id, i.t_item, p.t_pay, ABS(i.t_item - p.t_pay) AS diff,
       m.max_inst_cc, m.any_cc, m.n_types
FROM (SELECT order_id, SUM(price + freight_value) AS t_item FROM fact_order_items GROUP BY order_id) i
JOIN (SELECT order_id, SUM(payment_value) AS t_pay FROM fact_payments GROUP BY order_id) p ON p.order_id = i.order_id
JOIN p_mix m ON m.order_id = i.order_id;

-- 6.1 Bucket selisih dan arah
SELECT COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE diff <= 0.01) AS diff_le_001,
       COUNT(*) FILTER (WHERE diff > 0.01 AND diff <= 1) AS diff_001_1,
       COUNT(*) FILTER (WHERE diff > 1) AS diff_gt_1,
       COUNT(*) FILTER (WHERE diff > 1 AND t_pay > t_item) AS payment_gt_item,
       COUNT(*) FILTER (WHERE diff > 1 AND t_pay < t_item) AS payment_lt_item,
       ROUND(CAST(SUM(t_pay - t_item) FILTER (WHERE diff > 1 AND t_pay > t_item) AS DOUBLE), 2) AS excess_total,
       ROUND(100.0 * CAST(SUM(t_pay - t_item) FILTER (WHERE diff > 1 AND t_pay > t_item) AS DOUBLE)
             / (SELECT CAST(SUM(payment_value) AS DOUBLE) FROM fact_payments), 4) AS excess_pct_payment_total
FROM p_recon;

-- 6.2 Proporsi order dengan payment > item+freight (selisih > 1) menurut cicilan maksimum (order dengan kartu kredit)
SELECT CASE WHEN max_inst_cc IS NULL THEN 'kartu kredit tanpa cicilan valid'
            WHEN max_inst_cc = 1 THEN '1x' WHEN max_inst_cc <= 3 THEN '2-3x' WHEN max_inst_cc <= 6 THEN '4-6x'
            WHEN max_inst_cc <= 10 THEN '7-10x' ELSE '11x+' END AS cicilan_maks,
       COUNT(*) AS n_order,
       COUNT(*) FILTER (WHERE diff > 1 AND t_pay > t_item) AS n_payment_gt_item,
       ROUND(100.0 * COUNT(*) FILTER (WHERE diff > 1 AND t_pay > t_item) / COUNT(*), 3) AS pct_payment_gt_item,
       ROUND(quantile_cont(CAST((t_pay - t_item) / t_item AS DOUBLE), 0.5) FILTER (WHERE diff > 1 AND t_pay > t_item) * 100, 2) AS median_excess_pct_dari_item
FROM p_recon WHERE any_cc GROUP BY 1 ORDER BY MIN(COALESCE(max_inst_cc, 0));

-- 6.3 Order tanpa kartu kredit: seharusnya tidak ada payment > item+freight (selisih > 1)
SELECT COUNT(*) AS n_order_tanpa_cc,
       COUNT(*) FILTER (WHERE diff > 1 AND t_pay > t_item) AS n_payment_gt_item,
       COUNT(*) FILTER (WHERE diff > 1 AND t_pay < t_item) AS n_payment_lt_item
FROM p_recon WHERE NOT any_cc;

-- ============================================================
-- 7. Reconcile ke KPI terkunci / referensi -> payment_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE pay_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO pay_raw VALUES
 ('reconcile','Payment Population (order)',                     (SELECT COUNT(*) FROM p_mix), 99440, 0),
 ('reconcile','baris payment',                                  (SELECT COUNT(*) FROM fact_payments), 103886, 0),
 ('reconcile','Payment Total (R$, terkunci Tahap 6)',           (SELECT CAST(SUM(payment_value) AS DOUBLE) FROM fact_payments), 16008872.12, 0.011),
 ('reconcile','SUM(n_order per kombinasi) = Payment Population',(SELECT COUNT(*) FROM p_mix WHERE payment_mix IS NOT NULL), 99440, 0),
 ('reconcile','SUM(payment_orders) bulanan = Payment Population',(SELECT SUM(payment_orders) FROM payment_monthly), 99440, 0),
 ('reconcile','SUM(payment_value_total) bulanan = Payment Total (R$)', (SELECT ABS(SUM(payment_value_total) - 16008872.12) FROM payment_monthly), 0, 0.02),
 ('reconcile','Payment Population = order has_payment di fact_orders', (SELECT COUNT(*) FROM fact_orders WHERE n_payment_types > 0), 99440, 0),
 ('type','credit_card % baris',   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'credit_card') / COUNT(*), 2) FROM fact_payments), 73.92, 0.011),
 ('type','boleto % baris',        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'boleto') / COUNT(*), 2) FROM fact_payments), 19.04, 0.011),
 ('type','voucher % baris',       (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'voucher') / COUNT(*), 2) FROM fact_payments), 5.56, 0.011),
 ('type','debit_card % baris',    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_type = 'debit_card') / COUNT(*), 2) FROM fact_payments), 1.47, 0.011),
 ('type','credit_card % nilai',   (SELECT ROUND(100.0 * CAST(SUM(payment_value) FILTER (WHERE payment_type = 'credit_card') AS DOUBLE) / CAST(SUM(payment_value) AS DOUBLE), 2) FROM fact_payments), 78.34, 0.011),
 ('type','boleto % nilai',        (SELECT ROUND(100.0 * CAST(SUM(payment_value) FILTER (WHERE payment_type = 'boleto') AS DOUBLE) / CAST(SUM(payment_value) AS DOUBLE), 2) FROM fact_payments), 17.92, 0.011),
 ('type','voucher % nilai',       (SELECT ROUND(100.0 * CAST(SUM(payment_value) FILTER (WHERE payment_type = 'voucher') AS DOUBLE) / CAST(SUM(payment_value) AS DOUBLE), 2) FROM fact_payments), 2.37, 0.011),
 ('type','credit_card n order',   (SELECT COUNT(DISTINCT order_id) FILTER (WHERE payment_type = 'credit_card') FROM fact_payments), 76505, 0),
 ('type','voucher n order',       (SELECT COUNT(DISTINCT order_id) FILTER (WHERE payment_type = 'voucher') FROM fact_payments), 3866, 0),
 ('multi','order multi-tipe',     (SELECT COUNT(*) FROM p_mix WHERE n_types > 1), 2246, 0),
 ('multi','order multi-tipe %',   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n_types > 1) / COUNT(*), 2) FROM p_mix), 2.26, 0.011),
 ('multi','credit_card + voucher',(SELECT COUNT(*) FROM p_mix WHERE payment_mix = 'credit_card + voucher'), 2245, 0),
 ('multi','credit_card + debit_card', (SELECT COUNT(*) FROM p_mix WHERE payment_mix = 'credit_card + debit_card'), 1, 0),
 ('multi','order multi-baris payment', (SELECT COUNT(*) FROM p_mix WHERE n_payments > 1), NULL, 0),
 ('multi','baris tambahan payment',    (SELECT SUM(n_payments) - COUNT(*) FROM p_mix), NULL, 0),
 ('installments','n baris credit_card dengan cicilan valid',   (SELECT COUNT(*) FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments), 76793, 0),
 ('installments','% cicilan > 1',  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_installments > 1) / COUNT(*), 2) FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments), 66.85, 0.011),
 ('installments','% cicilan 1x',   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE payment_installments = 1) / COUNT(*), 2) FROM fact_payments WHERE payment_type = 'credit_card' AND NOT flag_zero_installments), 33.15, 0.011),
 ('installments','avg payment 1x (R$)',   (SELECT ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) FROM fact_payments WHERE payment_type = 'credit_card' AND payment_installments = 1), 95.87, 0.011),
 ('installments','avg payment 7-10x (R$)',(SELECT ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) FROM fact_payments WHERE payment_type = 'credit_card' AND payment_installments BETWEEN 7 AND 10), 333.83, 0.011),
 ('installments','avg payment 11x+ (R$)',  (SELECT ROUND(AVG(CAST(payment_value AS DOUBLE)), 2) FROM fact_payments WHERE payment_type = 'credit_card' AND payment_installments >= 11), 358.34, 0.011),
 ('status','cancellation rate % credit_card',    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM p_ord WHERE payment_mix = 'credit_card'), 0.574, 0.0011),
 ('status','cancellation rate % boleto',         (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM p_ord WHERE payment_mix = 'boleto'), 0.480, 0.0011),
 ('status','cancellation rate % voucher saja',   (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM p_ord WHERE payment_mix = 'voucher'), 4.688, 0.0011),
 ('status','cancellation rate % credit_card + voucher', (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_canceled) / COUNT(*), 3) FROM p_ord WHERE payment_mix = 'credit_card + voucher'), 0.802, 0.0011),
 ('status','n voucher-saja',                     (SELECT COUNT(*) FROM p_ord WHERE payment_mix = 'voucher'), 1621, 0),
 ('status','n canceled voucher-saja',            (SELECT COUNT(*) FROM p_ord WHERE payment_mix = 'voucher' AND is_canceled), 76, 0),
 ('recon','Reconcilable Population',             (SELECT COUNT(*) FROM p_recon), 98665, 0),
 ('recon','selisih <= 0,01',                     (SELECT COUNT(*) FROM p_recon WHERE diff <= 0.01), 98362, 0),
 ('recon','selisih 0,01 - 1',                    (SELECT COUNT(*) FROM p_recon WHERE diff > 0.01 AND diff <= 1), 54, 0),
 ('recon','selisih > 1',                         (SELECT COUNT(*) FROM p_recon WHERE diff > 1), 249, 0),
 ('recon','payment > item+freight (selisih > 1)',(SELECT COUNT(*) FROM p_recon WHERE diff > 1 AND t_pay > t_item), 232, 0),
 ('recon','payment < item+freight (selisih > 1)',(SELECT COUNT(*) FROM p_recon WHERE diff > 1 AND t_pay < t_item), 17, 0),
 ('recon','excess total payment > item (R$)',    (SELECT CAST(SUM(t_pay - t_item) AS DOUBLE) FROM p_recon WHERE diff > 1 AND t_pay > t_item), 3064.76, 0.011),
 ('recon','excess % dari Payment Total',         (SELECT ROUND(100.0 * CAST(SUM(t_pay - t_item) FILTER (WHERE diff > 1 AND t_pay > t_item) AS DOUBLE) / (SELECT CAST(SUM(payment_value) AS DOUBLE) FROM fact_payments), 4) FROM p_recon), NULL, 0),
 ('recon','payment > item+freight tanpa kartu kredit (harus 0)', (SELECT COUNT(*) FROM p_recon WHERE NOT any_cc AND diff > 1 AND t_pay > t_item), 0, 0);

CREATE OR REPLACE TABLE payment_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM pay_raw;

SELECT status, COUNT(*) AS n_metrik FROM payment_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM payment_findings ORDER BY section, metric;

-- ============================================================
-- 8. Output parquet
-- ============================================================
COPY payment_monthly  TO 'data/processed/12_payment_monthly.parquet'  (FORMAT PARQUET);
COPY payment_findings TO 'data/processed/12_payment_findings.parquet' (FORMAT PARQUET);
SELECT '12_payment_monthly' AS file, COUNT(*) AS n FROM read_parquet('data/processed/12_payment_monthly.parquet') UNION ALL
SELECT '12_payment_findings', COUNT(*) FROM read_parquet('data/processed/12_payment_findings.parquet');
