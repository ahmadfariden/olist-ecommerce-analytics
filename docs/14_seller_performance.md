# 14 — Seller Performance & Marketplace Concentration

> Pendamping `sql/14_seller_performance.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah. Revenue per seller adalah atribusi item-level yang nyata; Late Rate, skor review, dan handover per seller **hanya** dari Single-Seller Population (D10) dan seller ≥ 30 order (D6).

## Input
- Model dimensional Tahap 8: `fact_order_items`, `fact_orders`, `dim_seller`
- Populasi: Revenue Population (tier dan revenue, basis KPI terkunci), Item Population (pembanding addendum roadmap), Single-Seller Population (96.922) untuk metrik kinerja

## Proses Analisis
1. `seller_summary` (3.095 seller): revenue, order, tier (D11), peringkat, dan metrik Single-Seller (Late Rate, skor, handover, cross-state).
2. Konsentrasi: Pareto, Lorenz per desil, Gini, HHI, top-10 seller.
3. Segmentasi tier (D11) pada dua basis populasi berdampingan; distribusi seller menurut jumlah order; sebaran tier per state.
4. Supply–demand per state (share seller vs customer vs revenue).
5. Kinerja seller (≥ 30 order): perbandingan tier, sebaran antar seller, korelasi antar metrik, seller dengan Late Rate tertinggi dan handover terlama.
6. Cross-state shipment per state seller.
7. Reconcile (`seller_findings`) dan ekspor parquet.

## Temuan

### Reconcile (DoD)
**39 metrik: 32 PASS, 6 INFO, 1 CHECK** (dijelaskan di bawah). **`SUM(revenue seller)` = R$ 13.494.400,74 = Item Revenue terkunci (selisih 0)**; jumlah item = 112.650 (Item Population) dan 112.101 (Revenue Population); 3.095 seller (seluruhnya punya ≥ 1 item), 3.053 punya ≥ 1 revenue order (42 seller hanya punya item di order canceled/unavailable). **Ambang minimum volume terdokumentasi: seller ≥ 30 order (D6).**

### 1. Konsentrasi
**Pareto (k% terhadap 3.095 seller):**

| Top | n seller | % revenue (Revenue Population) | % revenue (Item Population) |
|---|---:|---:|---:|
| 1% | 31 | **26,18** | 26,07 |
| 5% | 155 | 53,51 | 53,30 |
| 10% | 310 | 67,78 | 67,56 |
| 20% | 619 | 82,84 | 82,69 |
| 50% | 1.548 | 96,89 | 96,79 |

Angka addendum roadmap (26,07 / 53,30 / 67,56 / 82,69) **tereproduksi persis pada basis Item Population**; basis Revenue Population (KPI terkunci) 0,1–0,2 poin lebih tinggi.

**Lorenz per desil seller (urut revenue turun):** desil 1 (310 seller) **67,78%**; desil 2 15,10% (kumulatif 82,88%); desil 3 7,60% (90,47%); desil 4 4,03% (94,51%); desil 5 2,39% (96,90%); desil 6–10 hanya 3,10% (desil 10: R$ 10.751,22 untuk 309 seller). Separuh seller terbawah = **3,1%** revenue.

**Ukuran ketimpangan:** Gini revenue **0,7935**, Gini jumlah order 0,7883; **HHI 35,95** (skala 10.000). Ketimpangan tinggi, tetapi tidak ada seller dominan: seller terbesar hanya **1,70%** revenue.

**Top 10 seller by revenue:** 1,70%, 1,65%, 1,48%, 1,43%, 1,39%, 1,28%, 1,19%, 1,05%, 1,03%, 1,00% (jumlah ≈ **13,2%**); sembilan di SP, satu di BA (peringkat 2: 358 order, R$ 222.776,05, **R$ 622,28 per order**, Late Rate 3,45%, skor 4,132). Top-10 seller memuat **14,15%** baris item. Late Rate seller top-10 berkisar 3,45–10,62% (rata-rata platform 6,77%); lima di antaranya ≥ 9%. Seller peringkat 5 (982 order) memiliki median handover **11,37 hari** dan skor 3,501.

### 2. Segmentasi tier (D11) — dua basis berdampingan

| Tier | n seller | % seller | Revenue Population | % | Item Population | % |
|---|---:|---:|---:|---:|---:|---:|
| **Top (≥ 100 order)** | 210 | 6,79 | R$ 6.973.350,60 | **51,68** | R$ 6.997.547,42 | 51,48 |
| **Mid (30–99)** | 424 | 13,70 | R$ 3.427.137,29 | 25,40 | R$ 3.441.387,08 | 25,32 |
| **Long-tail (< 30)** | 2.461 | 79,52 | R$ 3.093.912,85 | 22,93 | R$ 3.152.709,20 | 23,20 |

Jumlah seller per tier **identik** pada kedua basis (210 / 424 / 2.461). Selisih revenue (51,68% vs 51,48%) yang ditandai pada EDA **terjelaskan oleh basis**: angka roadmap memakai Item Population (termasuk item pada order canceled/unavailable, R$ 97.242,96), KPI terkunci memakai Revenue Population. Dashboard memakai basis Revenue Population. Long-tail mencakup 42 seller tanpa revenue order.

- **Seller eligible untuk analisis rate (≥ 30 order): 634** (Top + Mid) = **77,07%** revenue (Item Population 76,8%).
- **Distribusi seller menurut jumlah order (Revenue Population):** 0 order 42 (1,36%); 1 order 560 (18,09%; 0,99% revenue); 2–4 710 (22,94%; 3,10%); 5–9 522 (16,87%; 5,19%); 10–29 627 (20,26%; 13,64%); 30–99 424 (13,70%; 25,40%); 100–299 154 (4,98%; 21,50%); **≥ 300 56 (1,81%; 30,18%)**.
- Info deskriptif (bukan batas segmen): seller < 10 order **1.834** (Revenue Population) / **1.824** (Item Population, cocok addendum), ≈ 59% seller tetapi hanya ≈ 9,3% revenue.
- **Tier per state seller:** SP 1.849 seller (145 top, 267 mid, 1.437 long-tail) memegang **145 dari 210 seller top-tier (69,0%)**; MG 244 seller (20 top; 8,20% top di state), PR 349 (15 top), SC 190 (11), RJ 171 (8), RS 129 (5), GO 40 (0), DF 30 (2), BA 19 (1), ES 23 (1).

### 3. Supply–demand per state

| State | Seller | Customer | % seller | % customer | % revenue sisi customer | % revenue sisi seller | Selisih (poin) |
|---|---:|---:|---:|---:|---:|---:|---:|
| **SP** | 1.849 | 41.746 | **59,74** | 41,98 | 38,27 | **64,38** | **+26,11** |
| RJ | 171 | 12.852 | 5,53 | 12,92 | 13,43 | 6,21 | −7,22 |
| PR | 349 | 5.045 | 11,28 | 5,07 | 5,02 | 9,31 | +4,29 |
| MG | 244 | 11.635 | 7,88 | 11,70 | 11,66 | 7,42 | −4,24 |
| RS | 129 | 5.466 | 4,17 | 5,50 | 5,50 | 2,80 | −2,70 |
| SC | 190 | 3.637 | 6,14 | 3,66 | 3,84 | 4,62 | +0,78 |
| ES / BA / GO / CE / DF | 23 / 19 / 40 / 13 / 30 | — | — | — | — | — | −1,68 / −1,65 / −1,64 / −1,53 / −1,51 |

- Enam state (SP, PR, MG, RJ, SC, RS) menghasilkan ≈ **94,7%** revenue sisi seller. SP adalah pemasok bersih (+26,1 poin); RJ, MG, RS, ES, BA, GO, CE, DF adalah pengimpor bersih; PR dan SC sedikit pemasok bersih.
- **State tanpa seller:** AL (413 customer), TO (280), AP (68), RR (46) = **807 customer (0,81%)**.
- **State dengan hanya 1–2 seller:** PA (975 customer, 1 seller), MA (747, 1), PI (495, 1), AM (148, 1), AC (81, 1), SE (350, 2), RO (253, 2): pasokan sangat tipis.

### 4. Kinerja seller (Single-Seller Population; seller ≥ 30 order)
- **Cakupan:** 634 seller ≥ 30 order; **615** memenuhi ≥ 30 order single-seller terkirim (analisis Late Rate/handover); **619** memenuhi ≥ 30 order single-seller ber-review (skor, sama dengan Tahap 12); tidak ada seller dengan rate tetapi < 30 order.
- **Perbandingan tier (dipool):** Top: 57.456 order terkirim, Late Rate **6,903%**, skor **4,114** (57.898 review), median handover antar seller 2,11 hari, rata-rata cross-state 64,7%. Mid: 22.262 order terkirim, Late Rate **6,778%**, skor **4,169**, handover 2,06 hari, cross-state 66,2%. **Top-tier tidak lebih baik daripada Mid-tier** (Late Rate serupa, skor sedikit lebih rendah).
- **Sebaran antar 615 seller:** Late Rate P10 1,53% / P50 5,56% / P90 13,03%; skor P10 3,816 / P50 4,186 / P90 4,509; handover (median per seller) P10 1,18 / P50 2,06 / **P90 4,83 hari**.
- **Korelasi antar seller (614):** skor vs Late Rate **−0,541**; handover vs Late Rate **0,329**; handover vs skor **−0,436**; cross-state vs Late Rate −0,101; log(order) vs skor −0,09. Skor seller berasosiasi dengan Late Rate dan handover, hampir tidak dengan volume.
- **Late Rate tertinggi (seller eligible):** `ad781527…` SP **36,36%** (33 order terkirim; skor 3,105; handover 8,26), `ede0c036…` SP 32,56%, `54965bbe…` PR 30,56% (cross-state 94,8%), `2a1348e9…` MG 28,89%, `835f0f78…` SP 27,50%, `beadbee3…` 23,81%, `a49928bc…` SP 22,58% (skor 3,063), `ef990a83…` SC 22,50%, `712e6ed8…` SC 20,78%. Seluruhnya 33–93 order terkirim (estimasi rentan noise).
- **Handover terlama:** `5058e8c1…` SP **15,42 hari** (63 order; skor 3,339), `66e0557e…` 15,18, `cee48807…` 13,34, `6fd52c52…` 13,09, `17f51e71…` 12,43, `7c67e144…` 11,37 (982 order), `a7f13822…` 10,76, `2eb70248…` 9,92 (202 order; skor 2,684), `835f0f78…` 9,21. Hampir seluruhnya seller SP.

### 5. Cross-state shipment per state seller (Single-Seller Population, revenue order)

| State seller | Order | % intra-state | % cross-state | Rata-rata delivery (hari) | Late Rate | Ongkir/order (R$) |
|---|---:|---:|---:|---:|---:|---:|
| SP | 68.712 | 44,79 | 55,21 | 12,41 | 7,412% | 20,86 |
| MG | 7.703 | 19,81 | 80,19 | 12,93 | 4,897% | 26,74 |
| PR | 7.440 | 9,62 | 90,38 | 13,49 | 5,503% | 25,58 |
| RJ | 4.237 | 22,92 | 77,08 | 12,15 | 7,257% | 21,59 |
| SC | 3.553 | 7,23 | 92,77 | 13,82 | 4,990% | 29,09 |
| RS | 1.946 | 14,85 | 85,15 | 11,57 | 3,169% | 28,75 |
| DF / BA / GO / PE | 813 / 562 / 457 / 402 | 3–12 | 87–94 | 12,5–13,9 | 2,9–5,3% | 22–35 |
| **MA** | 391 | 3,58 | 96,42 | **17,77** | **19,072%** | 30,98 |

- Seller di luar SP mengirim hampir seluruhnya lintas state (PR 90,4%, SC 92,8%, DF 94,0%, MA 96,4%). Antar 615 seller eligible, porsi cross-state P10 45,0% / **P50 61,9%** / P90 92,7%, dan **101 seller ≥ 90% cross-state**.
- State seller dengan Late Rate menonjol: **MA 19,07%** (391 order; hanya 1 seller sehingga setara kinerja seller itu), SP 7,41%, RJ 7,26%; terendah GO 2,90%, RS 3,17%, PE 3,75%.
- Porsi cross-state per seller tidak menjelaskan Late Rate (r = −0,10).

### Metrik CHECK (1)
| Metrik | Aktual | Referensi | Penjelasan |
|---|---:|---:|---|
| Korelasi skor vs Late Rate (619 seller) | −0,545 | −0,541 (Tahap 12) | Late Rate di sini dihitung dari seluruh order single-seller terkirim, sedangkan Tahap 12 memakai order single-seller yang ber-review. Selisih 0,004; perbedaan basis, bukan kesalahan. |

## Hipotesis Kandidat (untuk Tahap 16–17 dan 21, belum diuji)
- **H-S1** Revenue timpang (Gini 0,79; top 1% = 26,2%; top 10% = 67,8%; separuh terbawah = 3,1%) tanpa seller dominan (HHI 36; seller terbesar 1,7%). → Tahap 21
- **H-S2** Segmen kecil memikul hampir seluruh revenue: 56 seller ≥ 300 order = 30,2% revenue; 210 seller top-tier = 51,7%; 1.834 seller < 10 order (≈ 59%) hanya ≈ 9,3%. → Tahap 21
- **H-S3** Pasokan terpusat di SP (59,7% seller; 64,4% revenue sisi seller vs 38,3% sisi customer); AL/TO/AP/RR tanpa seller dan PA/MA/PI/AM/AC hanya satu seller. → Tahap 16
- **H-S4** Top-tier tidak lebih baik daripada Mid-tier dalam Late Rate dan skor; skor seller berasosiasi dengan Late Rate (−0,54) dan handover (−0,44) tetapi hampir tidak dengan volume (−0,09). → Tahap 21
- **H-S5** Handover berekor panjang (P90 4,83 vs P50 2,06 hari) dan beberapa seller besar termasuk yang paling lambat (peringkat 5 revenue: 11,4 hari). → Tahap 21
- **H-S6** Seller di luar SP hampir seluruhnya mengirim lintas state (> 77%); keterlambatan lebih bersifat seller/lane-spesifik daripada fungsi cross-state per seller (r = −0,10), mis. seller asal MA (19,07%). → Tahap 16

## Output
- Tabel: `seller_summary` (3.095 seller), `seller_state_balance` (27 state), `seller_findings` (39 metrik)
- `data/processed/14_seller_summary.parquet` (3.095 baris), `14_seller_findings.parquet` (39 baris); ter-ignore git

## Assumptions
- Revenue seller = `SUM(price)` per `seller_id` (item-level); tier berdasarkan jumlah order unik pada Revenue Population (D11), dengan basis Item Population dilaporkan berdampingan hanya sebagai pembanding addendum.
- Order multi-seller dihitung pada setiap seller yang terlibat untuk jumlah order dan revenue (total `n_order_rp` seluruh seller = 99.542 > 98.199 revenue order; kelebihan 1.343 berasal dari 1.277 order multi-seller yang dihitung pada tiap seller yang terlibat); metrik kinerja memakai Single-Seller Population saja.
- Eligible = ≥ 30 order (D6); Late Rate dan handover memakai ≥ 30 order single-seller terkirim; skor memakai ≥ 30 order single-seller ber-review.
- Persentase top k% = k% × 3.095 seller dibulatkan ke atas (31, 155, 310, 619).
- Handover = purchase → carrier (mengecualikan `flag_carrier_before_purchase`).

## Batasan data
- Late Rate, skor, dan handover tidak tersedia untuk order multi-seller (1.277 order) dan untuk seller < 30 order; 19 dari 634 seller ≥ 30 order tidak memenuhi ≥ 30 order single-seller terkirim.
- Seller dengan 30–100 order terkirim memiliki ketidakpastian estimasi yang lebar; daftar "tertinggi/terlama" bukan peringkat final.
- Lokasi seller memakai `seller_state` (D8); kota seller tidak dipakai.
- State dengan 1–2 seller (MA, PA, PI, AM, AC, SE, RO) tidak dapat dibedakan dari kinerja seller itu sendiri.
- Tidak ada kontrol terhadap kategori, jarak, atau harga pada perbandingan antar seller dan antar tier.

## Kesimpulan
Revenue per seller reconcile penuh ke Item Revenue terkunci, tier D11 tereproduksi persis (210 / 424 / 2.461), dan selisih share top-tier terjelaskan oleh basis populasi (51,68% vs 51,48%). Marketplace sangat timpang (Gini 0,79) namun tanpa seller dominan; pasokan terpusat di SP. Kualitas seller tidak naik seiring volume: top-tier tidak lebih baik daripada mid-tier, dan skor seller mengikuti Late Rate dan handover. Cross-state per seller tidak menjelaskan keterlambatan.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** pantau seller besar dengan handover panjang atau Late Rate tinggi; kurangi ketergantungan pasokan pada SP dan tambah seller di state dengan 0–2 seller; gunakan ambang ≥ 30 order untuk laporan kinerja seller.
