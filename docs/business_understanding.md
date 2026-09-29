# 03 — Business Understanding

> Tahap ini **dokumen saja** (tanpa file SQL). Angka di Feasibility Check bersumber dari `olist_profiling.md` dan addendum `03b`–`03d` yang sudah dieksekusi; angka tersebut **direproduksi ulang di Tahap 4**, jadi di sini berstatus referensi.

## 1. Data Feasibility Check (Quick Profiling)

### Checklist

- Ketersediaan customer identifier & seberapa banyak yang repeat
- Ketersediaan item-level data (harga, ongkir, produk, seller)
- Ketersediaan timestamp lifecycle order
- Ketersediaan review / rating
- Ketersediaan data lokasi (customer, seller, koordinat)
- Cakupan dan kontinuitas periode waktu
- Ketersediaan data biaya / margin
- Pemeriksaan grain tiap tabel dan kualitas relasi (sudah dikonfirmasi di Tahap 2: 0 duplikat PK, 0 orphan)

### Key Findings

| Status | Aspek | Temuan |
|---|---|---|
| ✅ | Item-level data | `price`, `freight_value`, `product_id`, `seller_id` per item. Revenue per kategori/seller bisa dialokasikan nyata. Tidak ada kolom quantity: qty = jumlah baris item (7.088 pasangan order-produk berulang). |
| ✅ | Customer identifier | `customer_unique_id`: 96.096 pelanggan unik dari 99.441 order. |
| ⚠️ | Repeat sangat jarang | 93.099 (96,88%) hanya order 1 kali. Repeat mentah 2.997 (3,12%); **2.122 (2,21%)** jika jarak order ≥24 jam (D5). Analisis repeat layak **deskriptif**; RFM/CLV tidak bermakna. |
| ⚠️ | `customer_id` ≠ orang | Satu `customer_id` hanya muncul di satu order. Analisis pelanggan selalu pakai `customer_unique_id`. |
| ✅ | Timestamp lifecycle | Purchase, approved, carrier, delivered, estimated. ⚠️ Anomali urutan: carrier < purchase 166; carrier < approved 1.359; customer < carrier 23. |
| ✅ | Review | `review_score` 1–5. ⚠️ 547 order punya >1 review, 789 `review_id` muncul di >1 order, 768 order tanpa review. Komentar Portugis, 58,7% kosong → NLP di luar scope. |
| ✅ | Seller | 3.095 seller; mendukung konsentrasi dan performa seller. |
| ✅ | Lokasi | `customer_state` / `seller_state` bersih (27 / 23 state). Koordinat ada tapi kotor. |
| ⚠️ | Cakupan waktu tidak rata | Data 2016-09 s.d. 2018-10. Tipis: 2016-09 (4 order), 2016-10 (324), **2016-11 (0)**, 2016-12 (1). Terpotong: 2018-09 (16), 2018-10 (4). **Periode analisis penuh: 2017-01 s.d. 2018-08 (20 bulan).** |
| ⚠️ | Pembayaran multi-baris | 1 order bisa punya banyak baris payment (cicilan / campur tipe / voucher). |
| ❌ | Biaya / margin | Tidak ada → tidak ada analisis profit. |
| ❌ | Traffic / marketing / stok | Tidak ada → tidak ada funnel akuisisi, CAC, inventory. |
| ❌ | Diskon eksplisit | Tidak ada; hanya terlihat samar lewat pembayaran `voucher`. |

### Feasibility Conclusion

**Didukung:** Sales & Revenue · Order Status & Fulfillment · Delivery & Logistics · Customer Satisfaction (Review) · Payment · Product Category · Seller Performance · Regional · Customer Repeat Behavior (deskriptif).

**Tidak didukung:** Profitability/Margin · CLV & RFM klasik (Frequency degenerate) · Marketing/Acquisition Funnel & CAC · Inventory · Text Sentiment yang bermakna.

## 2. Analytical Scope

### In Scope

- Sales & Revenue Performance
- Order Status & Fulfillment Behavior
- Delivery & Logistics Performance
- Customer Satisfaction (Review Score) Analysis
- Payment Method Behavior
- Product Category & Pricing Performance
- Seller Performance & Marketplace Concentration
- Regional Performance (state/kota) & Supply–Demand Imbalance
- Customer Repeat Behavior (deskriptif: repeat rate, new vs returning, waktu antar order)

### Out of Scope

- Profit / Margin Analysis
- CLV, RFM klasik, Churn Prediction
- Market Basket / Cross-sell: secara teknis mungkin, tapi hanya 786 dari 3.236 order multi-produk (24,3%) yang lintas ≥2 kategori (A24). Dilaporkan sebagai **negative finding** di Tahap 14, tidak dianalisis lebih jauh.
- NLP / Sentiment Analysis pada teks review
- Forecasting
- Causal Inference
- Machine Learning

Seluruh analisis bersifat **Descriptive** dan **Diagnostic**. Hubungan antar variabel ditulis sebagai asosiasi, bukan kausal.

## 3. Business Questions

Kolom kanan memetakan tiap pertanyaan ke tahap dan file SQL yang menjawabnya.

| Domain | Pertanyaan | Dijawab di |
|---|---|---|
| **Sales & Revenue** | Bagaimana tren order dan revenue bulanan pada periode penuh (2017-01 s.d. 2018-08)? | Tahap 9 · `08_sales_revenue_performance.sql` |
| | Apakah lonjakan order 2017-11 (7.544 order) terkonsentrasi di kategori atau state tertentu? | Tahap 9 |
| | Berapa AOV dan bagaimana rasio ongkir terhadap nilai barang? | Tahap 9 |
| **Order Status & Fulfillment** | Berapa proporsi order per status, dan berapa cancellation/unavailable rate? | Tahap 10 · `09_order_status_fulfillment.sql` |
| | Di tahap mana order berhenti (approved → carrier → delivered) dan berapa lama tiap tahap? | Tahap 10 |
| **Delivery & Logistics** | Berapa median dan P95 waktu pengiriman, dan berapa late delivery rate? | Tahap 11 · `10_delivery_logistics.sql` |
| | State mana yang delivery time paling lama / late rate tertinggi? | Tahap 11 |
| | Apakah pengiriman lintas-state lebih lambat dan lebih mahal dari intra-state? | Tahap 11 |
| **Customer Satisfaction** | Bagaimana distribusi review score? | Tahap 12 · `11_customer_satisfaction.sql` |
| | Apakah order yang terlambat berasosiasi dengan review score lebih rendah? | Tahap 12 (stratifikasi timing jawaban, D4) |
| | Kategori dan seller mana yang review score-nya konsisten rendah (dengan minimum volume)? | Tahap 12 (minimum volume D6) |
| **Payment** | Metode pembayaran apa yang dominan dan bagaimana nilai order per metode? | Tahap 13 · `12_payment_behavior.sql` |
| | Bagaimana distribusi cicilan kartu kredit, dan berapa porsi order multi-payment? | Tahap 13 |
| **Product Category** | Kategori apa yang paling besar berdasarkan revenue dan jumlah order? | Tahap 14 · `13_product_category_pricing.sql` |
| | Bagaimana distribusi harga dan berat per kategori? | Tahap 14 |
| **Seller** | Seberapa terkonsentrasi revenue pada seller teratas (Pareto)? | Tahap 15 · `14_seller_performance.sql` |
| | Bagaimana ketimpangan supply–demand antar state (mis. SP = 59,7% seller vs 42,0% customer)? | Tahap 15–16 |
| **Regional & Repeat** | State/kota mana yang menyumbang order dan revenue terbesar? | Tahap 16 · `15_regional_performance.sql` |
| | Berapa repeat purchase rate dan berapa lama jarak order pertama ke kedua? | Tahap 17 · `16_customer_repeat_behavior.sql` |

## 4. Success Criteria

Proyek dianggap berhasil apabila:

- Dashboard terdiri dari **6 halaman** utama
- Minimal **5 insight actionable** berbasis evidence
- Seluruh KPI dapat direkonsiliasi ke raw data
- Revenue dari `order_items` ter-rekonsiliasi dengan `order_payments` sesuai toleransi yang didefinisikan (Tahap 6)
- Temuan dapat ditelusuri kembali ke source dataset
- KPI utama terdokumentasi dengan jelas

## Definition of Done

- [x] Data Feasibility Check selesai
- [x] Analytical Scope dikunci
- [x] Business Questions terdokumentasi
- [x] Success Criteria terdokumentasi
- [ ] Git checkpoint sudah di-commit *(commit dari sisi kamu)*
