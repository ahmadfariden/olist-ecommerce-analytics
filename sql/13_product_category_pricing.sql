-- ============================================================
-- Tahap 14 — Product Category & Pricing Performance
-- File: sql/13_product_category_pricing.sql
-- Jalankan dari root repo:
--     duckdb data/olist.duckdb
--     .mode markdown
--     .read sql/13_product_category_pricing.sql
-- Prasyarat: sql/07_data_modeling.sql sudah dijalankan (fact_*, dim_*).
-- ============================================================
-- GRAIN:       beda per blok (kategori / produk / pasangan kategori / state x kategori); dinyatakan di tiap blok
-- POPULATION:  Revenue Population (is_revenue_order, n = 98.199) untuk revenue/harga/freight per kategori;
--              Item Population (112.650 item) hanya untuk pembanding addendum roadmap (kategori unknown, basket)
-- DENOMINATOR: Item Revenue total Revenue Population (R$ 13.494.400,74) untuk % revenue; n order per kategori
-- ============================================================
-- Aturan tahap ini (definisi KPI terkunci di Tahap 6, tidak diubah):
--   * Item Revenue per kategori = SUM(price) di fact_order_items -> ALOKASI NYATA (bukan payment_value).
--     Jumlah seluruh kategori = Item Revenue total dan harus reconcile ke KPI terkunci.
--   * Unit terjual = jumlah baris item (COUNT(*)); qty_units berulang per pasangan order-produk, jangan di-SUM.
--   * Kategori 'unknown' dilaporkan sebagai kategori sendiri, tidak disembunyikan.
--   * Rate per kategori hanya untuk kategori >= 100 order (D6).
--   * Atribut listing (foto, panjang nama/deskripsi) vs penjualan: DESKRIPTIF; tidak boleh jadi rekomendasi
--     "tambah foto" (korelasi semu lewat harga).
--   * Basket lintas kategori disajikan sebagai NEGATIVE FINDING (cross-sell lintas kategori kecil).
--   * Hubungan antar variabel = asosiasi, bukan kausal.
-- Output: data/processed/13_category_summary.parquet, 13_category_findings.parquet
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helper (TEMP): item + kategori + atribut order, 1 baris per item (112.650)
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE c_item AS
SELECT i.order_id, i.order_item_id, i.product_id, i.price, i.freight_value, i.qty_units,
       CAST(i.price AS DOUBLE) AS price_d, CAST(i.freight_value AS DOUBLE) AS freight_d,
       p.category_en_clean AS kategori, p.weight_g, p.photos_qty, p.name_length, p.description_length,
       i.is_revenue_order, o.customer_state
FROM fact_order_items i
JOIN dim_product p ON p.product_id = i.product_id
JOIN fact_orders o ON o.order_id = i.order_id;

-- ============================================================
-- 1. KATEGORI: Item Revenue, order, unit, harga, freight, berat (alokasi nyata)
-- ============================================================
CREATE OR REPLACE TABLE category_summary AS
SELECT kategori,
       COUNT(DISTINCT order_id) FILTER (WHERE is_revenue_order)               AS n_orders,
       COUNT(*) FILTER (WHERE is_revenue_order)                               AS n_units,
       COUNT(DISTINCT product_id) FILTER (WHERE is_revenue_order)             AS n_products_sold,
       ROUND(CAST(SUM(price) FILTER (WHERE is_revenue_order) AS DOUBLE), 2)   AS item_revenue,
       ROUND(CAST(SUM(freight_value) FILTER (WHERE is_revenue_order) AS DOUBLE), 2) AS freight_revenue,
       ROUND(AVG(price_d) FILTER (WHERE is_revenue_order), 2)                 AS avg_price,
       ROUND(quantile_cont(price_d, 0.25) FILTER (WHERE is_revenue_order), 2) AS price_p25,
       ROUND(quantile_cont(price_d, 0.5)  FILTER (WHERE is_revenue_order), 2) AS price_p50,
       ROUND(quantile_cont(price_d, 0.75) FILTER (WHERE is_revenue_order), 2) AS price_p75,
       ROUND(quantile_cont(price_d, 0.95) FILTER (WHERE is_revenue_order), 2) AS price_p95,
       ROUND(100.0 * SUM(freight_d) FILTER (WHERE is_revenue_order)
             / NULLIF(SUM(price_d) FILTER (WHERE is_revenue_order), 0), 2)    AS freight_pct_of_item,
       ROUND(quantile_cont(weight_g, 0.5) FILTER (WHERE is_revenue_order), 0) AS weight_g_p50,
       ROUND(AVG(freight_d) FILTER (WHERE is_revenue_order), 2)               AS avg_freight_per_item,
       -- pembanding Item Population (basis addendum roadmap)
       COUNT(DISTINCT order_id)                                               AS n_orders_item_pop,
       COUNT(*)                                                               AS n_items_item_pop,
       ROUND(CAST(SUM(price) AS DOUBLE), 2)                                   AS item_revenue_item_pop
FROM c_item GROUP BY kategori;

CREATE OR REPLACE TEMP TABLE c_cat AS
SELECT *, ROUND(100.0 * item_revenue / SUM(item_revenue) OVER (), 3) AS pct_revenue,
       (n_orders >= 100) AS memenuhi_min_volume,
       RANK() OVER (ORDER BY item_revenue DESC) AS rank_revenue,
       RANK() OVER (ORDER BY n_orders DESC)     AS rank_orders
FROM category_summary;

-- 1.1 Top 15 kategori by Item Revenue
SELECT rank_revenue, rank_orders, kategori, n_orders, n_units, item_revenue, pct_revenue,
       avg_price, price_p50, price_p95, freight_pct_of_item, weight_g_p50, memenuhi_min_volume
FROM c_cat ORDER BY item_revenue DESC LIMIT 15;

-- 1.2 Top 10 kategori by jumlah order (dan selisih peringkat dengan revenue)
SELECT rank_orders, rank_revenue, kategori, n_orders, n_units, item_revenue, pct_revenue,
       ROUND(item_revenue / n_orders, 2) AS revenue_per_order, price_p50
FROM c_cat ORDER BY n_orders DESC LIMIT 10;

-- 1.3 Konsentrasi kategori dan cakupan volume (D6)
SELECT COUNT(*) AS n_kategori,
       COUNT(*) FILTER (WHERE n_orders >= 100) AS n_kategori_ge_100_order,
       COUNT(*) FILTER (WHERE n_orders < 30)   AS n_kategori_lt_30_order,
       ROUND(MAX(pct_revenue), 2) AS top1_pct_revenue,
       ROUND(SUM(pct_revenue) FILTER (WHERE rank_revenue <= 10), 2) AS top10_pct_revenue,
       ROUND(SUM(pct_revenue) FILTER (WHERE rank_revenue <= 20), 2) AS top20_pct_revenue,
       ROUND(SUM(pct_revenue) FILTER (WHERE n_orders >= 100), 2)    AS pct_revenue_kategori_ge_100
FROM c_cat;

-- 1.4 Kategori di bawah minimum volume (< 100 order): daftar dengan n
SELECT kategori, n_orders, n_units, item_revenue, pct_revenue FROM c_cat
WHERE n_orders < 100 ORDER BY n_orders DESC;

-- 1.5 Reconcile: jumlah revenue seluruh kategori = Item Revenue total (Revenue Population)
SELECT ROUND(SUM(item_revenue), 2) AS sum_revenue_kategori,
       (SELECT ROUND(CAST(SUM(item_revenue) AS DOUBLE), 2) FROM fact_orders WHERE is_revenue_order) AS item_revenue_total_kpi,
       SUM(n_units) AS sum_unit, (SELECT COUNT(*) FROM fact_order_items WHERE is_revenue_order) AS item_revenue_population_item
FROM c_cat;

-- ============================================================
-- 2. KATEGORI unknown (610 produk): dilaporkan sebagai kategori sendiri, pada DUA basis
-- ============================================================
SELECT 'Item Population (basis addendum)' AS basis,
       n_items_item_pop AS n_item, n_orders_item_pop AS n_order,
       item_revenue_item_pop AS item_revenue,
       ROUND(100.0 * item_revenue_item_pop / (SELECT SUM(item_revenue_item_pop) FROM category_summary), 3) AS pct_item_revenue
FROM category_summary WHERE kategori = 'unknown'
UNION ALL
SELECT 'Revenue Population (basis KPI terkunci)', n_units, n_orders, item_revenue, pct_revenue
FROM c_cat WHERE kategori = 'unknown';

SELECT (SELECT COUNT(*) FROM dim_product WHERE category_en_clean = 'unknown') AS n_produk_unknown,
       (SELECT ROUND(SUM(item_revenue_item_pop), 2) FROM category_summary) AS item_revenue_item_population_total;

-- ============================================================
-- 3. DISTRIBUSI HARGA per KATEGORI dan MATRIKS harga tinggi vs volume tinggi (kategori >= 100 order)
-- ============================================================
-- 3.1 Distribusi harga: 10 kategori dengan median harga tertinggi dan terendah
SELECT 'tertinggi' AS urutan, * FROM (
    SELECT kategori, n_orders, price_p25, price_p50, price_p75, price_p95, avg_price
    FROM c_cat WHERE memenuhi_min_volume ORDER BY price_p50 DESC LIMIT 10)
UNION ALL
SELECT 'terendah', * FROM (
    SELECT kategori, n_orders, price_p25, price_p50, price_p75, price_p95, avg_price
    FROM c_cat WHERE memenuhi_min_volume ORDER BY price_p50 ASC LIMIT 10)
ORDER BY urutan DESC, price_p50 DESC;

-- 3.2 Matriks: harga (median > median harga item Revenue Population) x volume (n order > median antar kategori >= 100 order)
CREATE OR REPLACE TEMP TABLE c_quad AS
WITH th AS (
    SELECT (SELECT quantile_cont(price_d, 0.5) FROM c_item WHERE is_revenue_order) AS price_th,
           (SELECT quantile_cont(n_orders, 0.5) FROM c_cat WHERE memenuhi_min_volume) AS volume_th
)
SELECT c.kategori, c.n_orders, c.price_p50, c.item_revenue, c.pct_revenue,
       CASE WHEN c.price_p50 > th.price_th AND c.n_orders >  th.volume_th THEN '1 harga tinggi & volume tinggi'
            WHEN c.price_p50 > th.price_th AND c.n_orders <= th.volume_th THEN '2 harga tinggi & volume rendah'
            WHEN c.price_p50 <= th.price_th AND c.n_orders >  th.volume_th THEN '3 harga rendah & volume tinggi'
            ELSE '4 harga rendah & volume rendah' END AS kuadran,
       th.price_th, th.volume_th
FROM c_cat c, th WHERE c.memenuhi_min_volume;

SELECT kuadran, COUNT(*) AS n_kategori, ROUND(SUM(pct_revenue), 2) AS pct_revenue,
       string_agg(kategori, ', ' ORDER BY n_orders DESC) AS kategori_daftar
FROM c_quad GROUP BY kuadran ORDER BY kuadran;

SELECT ROUND(MAX(price_th), 2) AS ambang_median_harga, ROUND(MAX(volume_th), 0) AS ambang_median_order FROM c_quad;

-- ============================================================
-- 4. FREIGHT RATIO dan BERAT per KATEGORI (kategori >= 100 order)
-- ============================================================
SELECT 'freight% tertinggi' AS urutan, * FROM (
    SELECT kategori, n_orders, freight_pct_of_item, weight_g_p50, price_p50, avg_freight_per_item
    FROM c_cat WHERE memenuhi_min_volume ORDER BY freight_pct_of_item DESC LIMIT 8)
UNION ALL
SELECT 'freight% terendah', * FROM (
    SELECT kategori, n_orders, freight_pct_of_item, weight_g_p50, price_p50, avg_freight_per_item
    FROM c_cat WHERE memenuhi_min_volume ORDER BY freight_pct_of_item ASC LIMIT 8)
ORDER BY urutan DESC, freight_pct_of_item DESC;

SELECT 'berat median tertinggi' AS urutan, * FROM (
    SELECT kategori, n_orders, weight_g_p50, avg_freight_per_item, freight_pct_of_item
    FROM c_cat WHERE memenuhi_min_volume AND weight_g_p50 IS NOT NULL ORDER BY weight_g_p50 DESC LIMIT 6)
UNION ALL
SELECT 'berat median terendah', * FROM (
    SELECT kategori, n_orders, weight_g_p50, avg_freight_per_item, freight_pct_of_item
    FROM c_cat WHERE memenuhi_min_volume AND weight_g_p50 IS NOT NULL ORDER BY weight_g_p50 ASC LIMIT 6)
ORDER BY urutan DESC, weight_g_p50 DESC;

SELECT ROUND(corr(weight_g_p50, avg_freight_per_item), 3) AS r_berat_median_vs_ongkir_per_item,
       ROUND(corr(price_p50, freight_pct_of_item), 3)     AS r_harga_median_vs_freight_pct,
       ROUND(corr(weight_g_p50, freight_pct_of_item), 3)  AS r_berat_median_vs_freight_pct
FROM c_cat WHERE memenuhi_min_volume;

-- ============================================================
-- 5. KATEGORI per STATE (Revenue Population; state x kategori >= 100 order)
-- ============================================================
-- 5.1 Porsi 5 kategori teratas nasional di 8 state dengan revenue terbesar
CREATE OR REPLACE TEMP TABLE c_state_cat AS
SELECT customer_state AS state, kategori,
       COUNT(DISTINCT order_id) AS n_orders, SUM(price) AS rev
FROM c_item WHERE is_revenue_order GROUP BY customer_state, kategori;

WITH st AS (SELECT state, SUM(rev) AS rev_state, RANK() OVER (ORDER BY SUM(rev) DESC) AS rk FROM c_state_cat GROUP BY state),
     top5 AS (SELECT kategori FROM c_cat ORDER BY item_revenue DESC LIMIT 5),
     nat AS (SELECT kategori, pct_revenue FROM c_cat)
SELECT s.state, t.kategori, sc.n_orders,
       ROUND(100.0 * CAST(sc.rev AS DOUBLE) / CAST(s.rev_state AS DOUBLE), 2) AS pct_revenue_state,
       n.pct_revenue AS pct_revenue_nasional
FROM st s JOIN c_state_cat sc ON sc.state = s.state
JOIN top5 t ON t.kategori = sc.kategori JOIN nat n ON n.kategori = sc.kategori
WHERE s.rk <= 8 ORDER BY s.rk, pct_revenue_state DESC;

-- 5.2 Spesialisasi regional: pasangan state x kategori (>= 100 order) dengan lift terbesar terhadap porsi nasional
WITH st AS (SELECT state, SUM(rev) AS rev_state FROM c_state_cat GROUP BY state)
SELECT sc.state, sc.kategori, sc.n_orders,
       ROUND(100.0 * CAST(sc.rev AS DOUBLE) / CAST(st.rev_state AS DOUBLE), 2) AS pct_revenue_state,
       n.pct_revenue AS pct_revenue_nasional,
       ROUND((100.0 * CAST(sc.rev AS DOUBLE) / CAST(st.rev_state AS DOUBLE)) / NULLIF(n.pct_revenue, 0), 2) AS lift
FROM c_state_cat sc JOIN st ON st.state = sc.state JOIN c_cat n ON n.kategori = sc.kategori
WHERE sc.n_orders >= 100 ORDER BY lift DESC LIMIT 12;

-- ============================================================
-- 6. ATRIBUT LISTING vs PENJUALAN (DESKRIPTIF; bukan rekomendasi)
--    GRAIN: produk yang terjual >= 1 kali di Revenue Population
-- ============================================================
CREATE OR REPLACE TEMP TABLE c_prod AS
SELECT i.product_id, COUNT(*) AS units, CAST(SUM(i.price) AS DOUBLE) AS revenue, AVG(CAST(i.price AS DOUBLE)) AS avg_price,
       ANY_VALUE(p.photos_qty) AS photos_qty, ANY_VALUE(p.name_length) AS name_length,
       ANY_VALUE(p.description_length) AS description_length
FROM fact_order_items i JOIN dim_product p ON p.product_id = i.product_id
WHERE i.is_revenue_order GROUP BY i.product_id;

-- 6.1 Per jumlah foto
SELECT CASE WHEN photos_qty IS NULL THEN '0: tidak ada data' WHEN photos_qty = 1 THEN '1 foto' WHEN photos_qty = 2 THEN '2 foto'
            WHEN photos_qty = 3 THEN '3 foto' WHEN photos_qty <= 5 THEN '4-5 foto' ELSE '6+ foto' END AS foto,
       COUNT(*) AS n_produk_terjual,
       ROUND(AVG(units), 2) AS avg_unit_per_produk, ROUND(quantile_cont(units, 0.5), 1) AS median_unit,
       ROUND(AVG(revenue), 2) AS avg_revenue_per_produk, ROUND(quantile_cont(revenue, 0.5), 2) AS median_revenue,
       ROUND(AVG(avg_price), 2) AS avg_harga
FROM c_prod GROUP BY 1 ORDER BY 1;

-- 6.2 Pengendalian harga: unit dan revenue per produk menurut foto DI DALAM tiap tertil harga
--     (jika kenaikan revenue seiring foto hilang di dalam tertil, korelasi semu lewat harga)
WITH t AS (SELECT *, NTILE(3) OVER (ORDER BY avg_price) AS tertil_harga FROM c_prod WHERE photos_qty IS NOT NULL)
SELECT tertil_harga,
       CASE WHEN photos_qty = 1 THEN '1 foto' WHEN photos_qty <= 3 THEN '2-3 foto' WHEN photos_qty <= 5 THEN '4-5 foto' ELSE '6+ foto' END AS foto,
       COUNT(*) AS n_produk, ROUND(AVG(units), 2) AS avg_unit, ROUND(AVG(revenue), 2) AS avg_revenue, ROUND(AVG(avg_price), 2) AS avg_harga
FROM t GROUP BY 1, 2 ORDER BY 1, MIN(photos_qty);

-- 6.3 Korelasi Pearson (produk terjual)
SELECT ROUND(corr(photos_qty, units), 3)             AS r_foto_vs_unit,
       ROUND(corr(photos_qty, revenue), 3)           AS r_foto_vs_revenue,
       ROUND(corr(photos_qty, avg_price), 3)         AS r_foto_vs_harga,
       ROUND(corr(avg_price, revenue), 3)            AS r_harga_vs_revenue,
       ROUND(corr(description_length, units), 3)     AS r_deskripsi_vs_unit,
       ROUND(corr(description_length, avg_price), 3) AS r_deskripsi_vs_harga,
       ROUND(corr(name_length, units), 3)            AS r_nama_vs_unit,
       COUNT(*) AS n_produk_terjual, COUNT(photos_qty) AS n_produk_ber_foto
FROM c_prod;

-- 6.4 Panjang deskripsi per kuartil (deskriptif)
SELECT kuartil, COUNT(*) AS n_produk, ROUND(MIN(description_length), 0) AS min_panjang, ROUND(MAX(description_length), 0) AS max_panjang,
       ROUND(AVG(units), 2) AS avg_unit, ROUND(AVG(revenue), 2) AS avg_revenue, ROUND(AVG(avg_price), 2) AS avg_harga
FROM (SELECT *, NTILE(4) OVER (ORDER BY description_length) AS kuartil FROM c_prod WHERE description_length IS NOT NULL)
GROUP BY kuartil ORDER BY kuartil;

-- ============================================================
-- 7. NEGATIVE FINDING — basket lintas kategori (A24)
--    POPULATION: order multi-produk di Item Population (basis addendum) dan Revenue Population
-- ============================================================
CREATE OR REPLACE TEMP TABLE c_ocat AS
SELECT DISTINCT order_id, kategori, is_revenue_order FROM c_item;

CREATE OR REPLACE TEMP TABLE c_ord AS
SELECT i.order_id, COUNT(DISTINCT i.product_id) AS n_products, MAX(CASE WHEN i.is_revenue_order THEN 1 ELSE 0 END) AS is_rp
FROM c_item i GROUP BY i.order_id;

CREATE OR REPLACE TEMP TABLE c_ocn AS
SELECT order_id, COUNT(*) AS n_kategori FROM c_ocat GROUP BY order_id;

-- 7.1 Order multi-produk dan seberapa banyak yang lintas >= 2 kategori
SELECT 'Item Population' AS basis, COUNT(*) AS n_order_multi_produk,
       COUNT(*) FILTER (WHERE c.n_kategori >= 2) AS n_lintas_kategori,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.n_kategori >= 2) / COUNT(*), 2) AS pct_lintas_kategori,
       COUNT(*) FILTER (WHERE c.n_kategori = 1) AS n_satu_kategori
FROM c_ord o JOIN c_ocn c ON c.order_id = o.order_id WHERE o.n_products > 1
UNION ALL
SELECT 'Revenue Population', COUNT(*), COUNT(*) FILTER (WHERE c.n_kategori >= 2),
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.n_kategori >= 2) / COUNT(*), 2), COUNT(*) FILTER (WHERE c.n_kategori = 1)
FROM c_ord o JOIN c_ocn c ON c.order_id = o.order_id WHERE o.n_products > 1 AND o.is_rp = 1;

SELECT n_kategori, COUNT(*) AS n_order FROM c_ord o JOIN c_ocn c ON c.order_id = o.order_id
WHERE o.n_products > 1 GROUP BY n_kategori ORDER BY n_kategori;

-- 7.2 Pasangan kategori terbesar (unordered; order dengan kedua kategori). Item Population.
SELECT a.kategori AS kategori_a, b.kategori AS kategori_b, COUNT(*) AS n_order
FROM c_ocat a JOIN c_ocat b ON a.order_id = b.order_id AND a.kategori < b.kategori
GROUP BY a.kategori, b.kategori ORDER BY n_order DESC LIMIT 10;

-- ============================================================
-- 8. Reconcile ke KPI terkunci dan angka addendum -> category_findings
-- ============================================================
CREATE OR REPLACE TEMP TABLE cat_raw (section VARCHAR, metric VARCHAR, n_actual DOUBLE, n_expected DOUBLE, tol DOUBLE);

INSERT INTO cat_raw VALUES
 ('reconcile','SUM(revenue kategori) = Item Revenue Revenue Population (R$)', (SELECT SUM(item_revenue) FROM c_cat), 13494400.74, 0.02),
 ('reconcile','SUM(unit kategori) = item Revenue Population',      (SELECT SUM(n_units) FROM c_cat), 112101, 0),
 ('reconcile','SUM(item kategori) = Item Population',              (SELECT SUM(n_items_item_pop) FROM category_summary), 112650, 0),
 ('reconcile','selisih SUM(revenue kategori) vs Item Revenue KPI (R$)',
        (SELECT ABS((SELECT SUM(item_revenue) FROM c_cat) - (SELECT CAST(SUM(item_revenue) AS DOUBLE) FROM fact_orders WHERE is_revenue_order))), 0, 0.02),
 ('reconcile','n kategori (73 terjemahan + unknown = 74)',         (SELECT COUNT(*) FROM category_summary), 74, 0),
 ('category','kategori >= 100 order (D6)',                         (SELECT COUNT(*) FROM c_cat WHERE n_orders >= 100), 52, 0),
 ('category','kategori < 30 order (roadmap: 11)',                  (SELECT COUNT(*) FROM c_cat WHERE n_orders < 30), 11, 0),
 ('category','top-1 kategori % revenue',                           (SELECT ROUND(MAX(pct_revenue), 2) FROM c_cat), 9.31, 0.011),
 ('category','top-10 kategori % revenue',                          (SELECT ROUND(SUM(pct_revenue) FILTER (WHERE rank_revenue <= 10), 2) FROM c_cat), 62.37, 0.011),
 ('unknown','produk unknown',                                      (SELECT COUNT(*) FROM dim_product WHERE category_en_clean = 'unknown'), 610, 0),
 ('unknown','item unknown (Item Population)',                      (SELECT n_items_item_pop FROM category_summary WHERE kategori = 'unknown'), 1603, 0),
 ('unknown','order unknown (Item Population)',                     (SELECT n_orders_item_pop FROM category_summary WHERE kategori = 'unknown'), 1451, 0),
 ('unknown','item revenue unknown (Item Population, R$)',          (SELECT item_revenue_item_pop FROM category_summary WHERE kategori = 'unknown'), 179535.28, 0.011),
 ('unknown','% item revenue unknown (Item Population)',            (SELECT ROUND(100.0 * item_revenue_item_pop / (SELECT SUM(item_revenue_item_pop) FROM category_summary), 3) FROM category_summary WHERE kategori = 'unknown'), 1.321, 0.0011),
 ('unknown','% item revenue unknown (Revenue Population; EDA 1,323)', (SELECT pct_revenue FROM c_cat WHERE kategori = 'unknown'), 1.323, 0.0011),
 ('basket','order multi-produk (Item Population)',                 (SELECT COUNT(*) FROM c_ord WHERE n_products > 1), 3236, 0),
 ('basket','order multi-produk lintas >= 2 kategori',              (SELECT COUNT(*) FROM c_ord o JOIN c_ocn c ON c.order_id = o.order_id WHERE o.n_products > 1 AND c.n_kategori >= 2), 786, 0),
 ('basket','% lintas kategori dari multi-produk',                  (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE c.n_kategori >= 2) / COUNT(*), 1) FROM c_ord o JOIN c_ocn c ON c.order_id = o.order_id WHERE o.n_products > 1), 24.3, 0.051),
 ('basket','pasangan terbesar bed_bath_table + furniture_decor (order)',
        (SELECT COUNT(*) FROM c_ocat a JOIN c_ocat b ON a.order_id = b.order_id AND a.kategori = 'bed_bath_table' AND b.kategori = 'furniture_decor'), 70, 0),
 ('listing','korelasi foto vs unit per produk (A25: 0,004)',       (SELECT ROUND(corr(photos_qty, units), 3) FROM c_prod), 0.004, 0.0011),
 ('listing','korelasi foto vs harga per produk',                   (SELECT ROUND(corr(photos_qty, avg_price), 3) FROM c_prod), NULL, 0),
 ('listing','korelasi harga vs revenue per produk',                (SELECT ROUND(corr(avg_price, revenue), 3) FROM c_prod), NULL, 0),
 ('listing','produk terjual',                                      (SELECT COUNT(*) FROM c_prod), NULL, 0);

CREATE OR REPLACE TABLE category_findings AS
SELECT section, metric, n_actual, n_expected, tol,
       CASE WHEN n_expected IS NULL THEN 'INFO'
            WHEN n_actual IS NOT NULL AND ABS(n_actual - n_expected) <= tol THEN 'PASS'
            ELSE 'CHECK' END AS status
FROM cat_raw;

SELECT status, COUNT(*) AS n_metrik FROM category_findings GROUP BY status ORDER BY status;
SELECT section, metric, n_actual, n_expected, status FROM category_findings ORDER BY section, metric;

-- ============================================================
-- 9. Output parquet
-- ============================================================
COPY category_summary  TO 'data/processed/13_category_summary.parquet'  (FORMAT PARQUET);
COPY category_findings TO 'data/processed/13_category_findings.parquet' (FORMAT PARQUET);
SELECT '13_category_summary' AS file, COUNT(*) AS n FROM read_parquet('data/processed/13_category_summary.parquet') UNION ALL
SELECT '13_category_findings', COUNT(*) FROM read_parquet('data/processed/13_category_findings.parquet');
