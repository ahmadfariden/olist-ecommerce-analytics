# Methodology — Definisi KPI, Populasi, dan Keputusan

> 🔒 **LOCKED setelah Tahap 6** (`sql/05_data_validation.sql`, gate lolos 61/61 HARD dan 25/25 KPI). Tahap berikutnya tidak boleh mengubah definisi tanpa entri di Revision Log (bagian 5).

## 1. Populasi analitik

Populasi berikut adalah denominator yang berbeda dan **tidak boleh dipertukarkan**. Setiap query Tahap 7–19 wajib menyebut populasi dan `n` di header `GRAIN / POPULATION / DENOMINATOR` (Aturan Main #5).

| Populasi | Cakupan | Flag | n | Dipakai untuk |
|---|---|---|---:|---|
| Order Population | seluruh `orders` | — | 99.441 | Total Orders, status funnel, denominator Cancellation Rate |
| Analysis Window | Order Population, `in_analysis_window` (2017-01-01 ≤ purchase < 2018-09-01) | `in_analysis_window` | 99.092 | Tren bulanan, MoM/YoY |
| Item Population | seluruh `order_items` | — | 112.650 baris | Revenue per kategori/seller/produk, freight |
| Revenue Population | `is_revenue_order` = punya item ∧ status ∉ {canceled, unavailable} | `is_revenue_order` | **98.199** | Revenue, AOV, kategori, seller |
| Delivered Population | `is_delivered_complete` = delivered ∧ tanggal terima ada | `is_delivered_complete` | **96.470** | Delivery days, Late Rate |
| Review Population | order ber-review, dedup 1 review/order | `has_review` | 98.673 | Review score |
| Payment Population | order yang punya payment | — | 99.440 | Payment share, cicilan, multi-payment |
| Reconcilable Population | order yang ada di items **dan** payments | — | 98.665 | Rekonsiliasi item+freight vs payment |
| Cancelled | `is_canceled` | `is_canceled` | 625 | Analisis pembatalan |
| 🔒 Single-Seller Population | Revenue Population ∧ ¬`is_multi_seller` | `is_multi_seller` | **96.922** | Atribusi review/ongkir ke seller tanpa ambigu (D10) |
| Customer Population | `customer_unique_id` unik | — | 96.096 | Repeat rate, cohort |

> ⚠️ 97.388 (single-seller dari seluruh order ber-item, termasuk non-revenue) hanya angka konteks. **Tidak pernah** dipakai sebagai denominator; satu-satunya angka sah untuk Single-Seller Population adalah **96.922** (D10).

**Flag tidak boleh dipertukarkan:** revenue → `is_revenue_order`; delivery → `is_delivered_complete`; kepuasan → `has_review`.

## 2. KPI Definition Lock

| KPI | Definisi | Populasi | Denominator | Nilai terkunci |
|---|---|---|---|---:|
| Item Revenue | `SUM(price)` dari `order_items_clean` | Revenue Population | — | R$ 13.494.400,74 |
| Freight Revenue | `SUM(freight_value)`; dipisah dari Item Revenue | Revenue Population | — | R$ 2.241.126,29 |
| GMV incl. Freight | Item Revenue + Freight Revenue | Revenue Population | — | R$ 15.735.527,03 |
| Payment Total | `SUM(payment_value)`; **hanya untuk rekonsiliasi** | Payment Population | — | R$ 16.008.872,12 |
| Total Orders | `COUNT(order_id)` | Order Population | — | 99.441 |
| Revenue Orders | `COUNT(order_id)` WHERE `is_revenue_order` | Revenue Population | — | 98.199 |
| AOV | Item Revenue / Revenue Orders (tanpa ongkir) | Revenue Population | Revenue Orders | R$ 137,42 |
| AOV incl. Freight | (Item + Freight Revenue) / Revenue Orders; **wajib berlabel** | Revenue Population | Revenue Orders | R$ 160,24 |
| Cancellation Rate | `is_canceled` / Total Orders | Order Population | Total Orders | 0,629% |
| Unavailable Rate | `is_unavailable` / Total Orders; dilaporkan terpisah | Order Population | Total Orders | 0,612% |
| Late Rate | `is_late` (perbandingan **tanggal**, D1) / Delivered Orders | Delivered Population | Delivered Orders (96.470) | **6,773%** |
| On-Time Rate | 1 − Late Rate | Delivered Population | Delivered Orders | 93,227% |
| Avg Review Score | `AVG(review_score)`, dedup 1 review/order (D3) | Review Population | 98.673 | 4,0864 |
| Repeat Rate | pelanggan dengan order ≥24 jam setelah order pertama / Customer Population (D5) | Customer Population | 96.096 | **2,208%** |
| 90-day Repeat Rate | repeat 24 jam..90 hari setelah order pertama; cohort order pertama 2017-01..2018-05 (D5) | Cohort | 77.482 | **1,302%** |
| Single-Seller Population | Revenue Population ∧ ¬`is_multi_seller` (D10) | Revenue Population | — | 96.922 |

**Sensitivity yang wajib dilaporkan bersama KPI terkait:**
- Late Rate versi timestamp = 8,112% (7.826). 1.292 order tiba di hari estimasi dan hanya terhitung telat karena estimasi selalu 00:00:00. Label jelas sebagai sensitivity.
- Revenue delivered-only = 97,98% dari Item Revenue; order in-flight = R$ 272.902,63 (2,02%) (D2).
- Repeat mentah (≥2 order) = 3,119%, hanya metrik Data Quality.

## 3. Aturan analisis

1. **Fan-out guard:** tabel anak (items, payments, reviews) di-pre-aggregate ke grain `order_id` sebelum join ke `orders_clean`.
2. **Freight vs payment:** `freight_value` tidak dijumlahkan bersama `payment_value`. Rekonsiliasi membandingkan (item+freight) dengan payment setelah masing-masing di-aggregate ke grain order.
3. **Empat besaran revenue berbeda** (Item Revenue, Freight Revenue, GMV, Payment Total): jangan tertukar. Payment Total tidak dibandingkan langsung dengan GMV karena populasinya beda (99.440 vs 98.199 order); payment dari 775 order tanpa item saja R$ 162.591,95.
4. **Late vs on-time pada review score (D4):** wajib distratifikasi menurut `answered_before_delivery`; dua lapis angka (semua order dan pasca-terima), tidak boleh dilebur.
5. **Minimum volume (D6):** seller ≥30 order, kota ≥100 order, kategori ≥100 order; state ditampilkan semua dengan n.
6. **Bahasa:** hubungan antar variabel ditulis sebagai asosiasi, bukan kausal.
7. **`qty_units`** berulang di tiap baris pasangan order-produk: jangan di-SUM; unit = `COUNT(*)` baris item.

## 4. Decision Log (pre-lock)

Keputusan yang lahir dari profiling addendum, dibuat sebelum KPI dikunci (bukan revisi).

| ID | Keputusan | Evidence | Dampak |
|---|---|---|---|
| D1 | `is_late` memakai perbandingan tanggal | A1 | Late Rate 6,773% (bukan 8,112%); versi timestamp = sensitivity |
| D2 | `is_revenue_order` tetap menghitung order in-flight; sensitivity delivered-only wajib | A3 | Selisih 2,02% dari Item Revenue |
| D3 | Dedup review: `review_answer_ts` terbaru (tie-break `review_creation_ts`, lalu `review_id`) | A8 | Avg score 4,0864 |
| D4 | Late vs on-time pada review score distratifikasi `answered_before_delivery` | A9, A10 | Dua lapis angka |
| D5 | Repeat headline = Repeat Rate ≥24 jam + 90-day Repeat Rate; repeat mentah hanya Data Quality | A12–A14 | 2,208% dan 1,302% |
| D6 | Minimum volume seller ≥30, kota ≥100, kategori ≥100; state semua dengan n | A15 | Ambang konkret |
| D7 | Kategori `unknown` tampil sebagai kategori sendiri | A16 | 1,321% revenue |
| D8 | Lokasi seller = `seller_state`; jarak dari `dim_geo_zip` | A17 | Seller mismatch state diabaikan dari geolocation |
| D9 | Selisih payment vs item+freight tidak dipaksa cocok; dicatat sebagai limitation | A4–A6 | Toleransi lolos (99,693%) |
| D10 | Single-Seller Population dikunci = 96.922; 97.388 hanya konteks | A2 | Cegah dua angka tertukar |
| D11 | Top-tier seller ≥100 order (Mid 30–99, Long-tail <30) | A18 | 210 seller bawa 51,48% revenue |
| D12 | State tidak ditier Top/Mid/Long-tail; 27 state ditampilkan dengan n | A19 | Konsentrasi SP terlalu dominan |

### Koreksi evidence pre-lock (Tahap 5–6)

Bukan revisi definisi, hanya koreksi angka evidence sebelum lock:

- **A4 / D9:** bucket rekonsiliasi di roadmap (98.285 / 131 / 249) tidak terreproduksi dengan aritmetika `DECIMAL(12,2)`. Angka terkunci: **98.362 / 54 / 249** (99,693% ≤ 0,01). Total 98.416 dan bucket >1 identik, jadi 77 order berpindah bucket; penyebab paling mungkin selisih tepat 1 sen yang tergeser floating point pada hitungan lama (belum dibuktikan langsung). Kesimpulan D9 tidak berubah.
- **Whitespace review:** `TRIM` DuckDB hanya membuang spasi; regex `^\s*$` menemukan 27 pesan whitespace-only (sesuai roadmap), `TRIM` hanya 9.

## 5. Revision Log

Diisi bila definisi KPI atau populasi berubah **setelah** lock.

| Tanggal | Definisi yang berubah | Alasan | Ditemukan di tahap mana |
|---|---|---|---|
| — | — | — | — |

> Belum ada revisi pasca-lock.

## 6. Jalur perubahan definisi

`Finding → kembali ke Tahap 5/6 → dicatat di Revision Log → re-validate → lanjut dari titik yang terdampak.`
