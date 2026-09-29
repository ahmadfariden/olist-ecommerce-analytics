# 03 — Business Understanding

**Tahap roadmap:** 3 (tidak punya file SQL)
**Checkpoint:** `chore: define business objectives, feasibility check, scope, KPI, and success criteria`

> ⚠️ **Sumber angka:** seluruh angka di dokumen ini berasal dari hasil profiling awal (`olist_profiling.md`) dan addendum `03b`–`03d` yang tercatat di roadmap v1.6. Angka-angka ini adalah **referensi**; verifikasi ulang lewat SQL dilakukan di Tahap 4 (`sql/03_data_profiling.sql`). Profiling di tahap ini hanya untuk memahami kemampuan dan batasan dataset, bukan profiling lengkap.

---

## 1. Konteks & Tujuan Proyek

Proyek analytics end-to-end pada **Olist Brazilian E-Commerce Public Dataset** (9 tabel relasional, 52 kolom). Tujuannya memahami performa marketplace dari sisi penjualan, pemenuhan order, pengiriman, kepuasan pelanggan, pembayaran, produk, seller, wilayah, dan perilaku repeat pelanggan, dengan pendekatan **descriptive** dan **diagnostic analytics**.

---

## 2. Data Feasibility Check (Quick Profiling)

### 2.1 Checklist

| # | Pertanyaan kelayakan | Jawaban |
|---|---|---|
| 1 | Ada customer identifier & seberapa banyak yang repeat? | ✅ Ada (`customer_unique_id`), tapi 96,88% hanya 1 order |
| 2 | Ada item-level data (harga, ongkir, produk, seller)? | ✅ Ada |
| 3 | Ada timestamp lifecycle order? | ✅ Ada, dengan anomali urutan |
| 4 | Ada review / rating? | ✅ Ada, tapi tidak bersih |
| 5 | Ada data lokasi? | ✅ State bersih; koordinat kotor |
| 6 | Cakupan waktu kontinu? | ⚠️ Tidak rata |
| 7 | Ada data biaya / margin? | ❌ Tidak ada |
| 8 | Grain & relasi antar tabel bersih? | ⚠️ Beda grain per tabel; risiko fan-out |

### 2.2 Key Findings

**✅ Item-level data tersedia**
- `price` dan `freight_value` per item; `product_id` dan `seller_id` per item.
- Revenue per kategori/seller **bisa dialokasikan nyata** (bukan sekadar "associated").
- Tidak ada kolom quantity; qty = jumlah baris item (7.088 pasangan order-produk berulang = beli >1 unit).

**✅ Customer identifier (`customer_unique_id`)**
- 96.096 pelanggan unik dari 99.441 order.
- ⚠️ 93.099 (96,88%) hanya order 1 kali; 2.997 (3,12%) repeat mentah, atau **2.122 (2,21%)** jika hanya menghitung order ≥24 jam setelah order pertama (D5, Tahap 6).
- Analisis repeat/cohort layak dibuat **deskriptif**; RFM klasik dan CLV tidak bermakna (Frequency hampir konstan).
- ⚠️ `customer_id` ≠ orang: satu `customer_id` hanya muncul di satu order. Analisis pelanggan selalu memakai `customer_unique_id`.

**✅ Timestamp lifecycle** (purchase, approved, carrier, delivered, estimated)
- Mendukung delivery time, late delivery, dan approval time.
- ⚠️ Anomali urutan tanggal: carrier < purchase 166; carrier < approved 1.359; customer < carrier 23.

**✅ Review** (`review_score` 1–5, komentar opsional)
- ⚠️ 547 order punya >1 review; 789 `review_id` muncul di >1 order; 768 order tanpa review.
- Komentar berbahasa Portugis, 58,7% kosong → analisis teks (NLP) di luar scope.

**✅ Seller** — 3.095 seller; mendukung analisis konsentrasi dan performa seller.

**✅ Lokasi** — `customer_state` (27) dan `seller_state` (23) bersih. Koordinat ada tapi kotor (ditangani Tahap 4–5).

**⚠️ Cakupan waktu tidak rata**
- Data 2016-09 s.d. 2018-10. Bulan tipis: 2016-09 (4 order), 2016-10 (324), **2016-11 (0)**, 2016-12 (1). Bulan terpotong: 2018-09 (16), 2018-10 (4).
- **Periode analisis penuh: 2017-01 s.d. 2018-08 (20 bulan).**

**⚠️ Pembayaran multi-baris** — 1 order bisa punya banyak baris payment (cicilan / campur tipe / voucher).

**❌ Tidak ada data biaya / margin** → tidak ada analisis profit.
**❌ Tidak ada data traffic / marketing / stok** → tidak ada funnel akuisisi, CAC, atau inventory analysis.
**❌ Tidak ada kolom diskon eksplisit** → diskon hanya terlihat samar lewat pembayaran `voucher`.

### 2.3 Feasibility Conclusion

**Dataset mendukung:**
- Sales & Revenue Analytics
- Order Status & Fulfillment Analytics
- Delivery & Logistics Analytics
- Customer Satisfaction (Review) Analytics
- Payment Analytics
- Product Category Analytics
- Seller Performance Analytics
- Regional Analytics
- Customer Repeat Behavior (deskriptif)

**Dataset tidak mendukung:**
- Profitability / Margin Analysis
- CLV & RFM klasik (Frequency degenerate)
- Marketing / Acquisition Funnel & CAC
- Inventory Analysis
- Text Sentiment Analysis yang bermakna (di luar scope)

---

## 3. Analytical Scope

### 3.1 In Scope

- Sales & Revenue Performance
- Order Status & Fulfillment Behavior
- Delivery & Logistics Performance
- Customer Satisfaction (Review Score) Analysis
- Payment Method Behavior
- Product Category & Pricing Performance
- Seller Performance & Marketplace Concentration
- Regional Performance (state/kota) & Supply–Demand Imbalance
- Customer Repeat Behavior (deskriptif: repeat rate, new vs returning, waktu antar order)

### 3.2 Out of Scope

- Profit / Margin Analysis
- CLV, RFM klasik, Churn Prediction
- Market Basket / Cross-sell — secara teknis mungkin (ada item-level), tetapi hanya 3.236 order (±3,3% dari order ber-item) yang berisi >1 produk berbeda, terlalu tipis untuk analisis utama. Angka pasti (A24): hanya 786 dari 3.236 order (24,3%) lintas ≥2 kategori. Dilaporkan sebagai **negative finding** di Tahap 14, tidak dianalisis lebih jauh.
- NLP / Sentiment Analysis pada teks review
- Forecasting
- Causal Inference
- Machine Learning

Seluruh analisis bersifat **Descriptive Analytics** dan **Diagnostic Analytics**.

### 3.3 Catatan Interpretasi

Hubungan antar variabel (mis. keterlambatan vs review score, jumlah foto vs penjualan) diperlakukan sebagai **asosiasi observasional**, bukan sebab-akibat. Batas interpretasi detail dikunci di bagian *Causal Interpretation Boundaries* pada roadmap.

---

## 4. Business Questions

**Sales & Revenue**
- Bagaimana tren order dan revenue bulanan pada periode analisis penuh (2017-01 s.d. 2018-08)?
- Apakah lonjakan order di 2017-11 (7.544 order) terkonsentrasi di kategori atau state tertentu?
- Berapa AOV dan bagaimana rasio ongkir terhadap nilai barang?

**Order Status & Fulfillment**
- Berapa proporsi order per status dan berapa cancellation/unavailable rate?
- Di tahap mana order berhenti (approved → carrier → delivered) dan berapa lama tiap tahap?

**Delivery & Logistics**
- Berapa median dan P95 waktu pengiriman, dan berapa late delivery rate?
- State mana yang punya delivery time paling lama / late rate tertinggi?
- Apakah pengiriman lintas-state lebih lambat dan lebih mahal dari intra-state?

**Customer Satisfaction**
- Bagaimana distribusi review score?
- Apakah order yang terlambat berasosiasi dengan review score lebih rendah?
- Kategori dan seller mana yang review score-nya konsisten rendah (dengan minimum volume)?

**Payment**
- Metode pembayaran apa yang dominan dan bagaimana nilai order per metode?
- Bagaimana distribusi cicilan pada kartu kredit, dan berapa porsi order multi-payment?

**Product Category**
- Kategori apa yang paling besar berdasarkan revenue dan jumlah order?
- Bagaimana distribusi harga dan berat per kategori?

**Seller**
- Seberapa terkonsentrasi revenue pada seller teratas (Pareto)?
- Bagaimana ketimpangan supply–demand antar state (mis. SP = 59,7% seller vs 42,0% customer)?

**Regional & Customer Repeat**
- State/kota mana yang menyumbang order dan revenue terbesar?
- Berapa repeat purchase rate dan berapa lama jarak antara order pertama dan kedua?

---

## 5. KPI Utama (referensi)

> Definisi, populasi, dan denominator **dikunci di Tahap 6 (KPI Lock)**. Bagian ini hanya menyebut KPI yang akan dikunci; tidak mendefinisikan ulang.

| KPI | Dikunci di | Diverifikasi di |
|---|---|---|
| Item Revenue | Tahap 6 | Tahap 19 (gate PASS/FAIL) |
| Revenue Orders | Tahap 6 | Tahap 19 |
| AOV | Tahap 6 | Tahap 19 |
| Late Rate | Tahap 6 (D1) | Tahap 19 |
| Avg Review Score | Tahap 6 (D3) | Tahap 19 |
| Repeat Rate ≥24 jam | Tahap 6 (D5) | Tahap 19 |

---

## 6. Success Criteria

Proyek dianggap berhasil apabila:

- [ ] Dashboard terdiri dari **6 halaman utama**
- [ ] Minimal **5 insight actionable** berbasis evidence
- [ ] Seluruh KPI dapat **direkonsiliasi ke raw data**
- [ ] Revenue dari `order_items` ter-rekonsiliasi dengan `order_payments` sesuai toleransi yang didefinisikan (Tahap 6)
- [ ] Temuan dapat **ditelusuri kembali** ke source dataset
- [ ] KPI utama **terdokumentasi dengan jelas**

*(Kotak dicentang saat proyek selesai, bukan di tahap ini.)*

---

## 7. Batasan yang Sudah Diketahui

- Tidak ada data biaya/margin, traffic/marketing, stok, dan diskon eksplisit.
- Tidak ada kolom quantity (qty = jumlah baris item).
- Periode 2016 dan 2018-09/10 tipis atau terpotong; analisis penuh hanya 2017-01 s.d. 2018-08.
- 96,88% pelanggan hanya 1 order, sehingga analisis repeat hanya deskriptif.
- Review tidak bersih (multi-review per order, `review_id` berulang, 768 order tanpa review).
- Koordinat geolocation kotor dan perlu dedup sebelum dipakai.
- Semua hubungan antar variabel bersifat observasional.

---

## Definition of Done

- [ ] Data Feasibility Check selesai
- [ ] Analytical Scope dikunci
- [ ] Business Questions terdokumentasi
- [ ] Success Criteria terdokumentasi
- [ ] Git checkpoint sudah di-commit
