# 11 — Customer Satisfaction (Review) Analysis

> Pendamping `sql/11_customer_satisfaction.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah. Teks komentar tidak dianalisis (NLP di luar scope).

## Input
- Model dimensional Tahap 8: `fact_reviews` (dedup 1 review/order, D3), `fact_orders`, `fact_order_items`, `dim_product`, `dim_seller`
- Populasi: Review Population (98.673); Delivered ∩ Review (95.824) untuk late vs on-time; Revenue ∩ Review untuk kategori; Single-Seller ∩ Review untuk seller

## Proses Analisis
1. Distribusi skor, rasio order ber-review, tren bulanan (`sat_monthly`).
2. **Late vs on-time dua lapis (D4):** lapis 1 semua order; lapis 2 distratifikasi `answered_before_delivery`; bucket keterlambatan (1–3, 4–7, >7 hari) di kedua strata; tren bulanan dua lapis.
3. Associated Review Score per kategori (≥100 order, D6), per state (27 state dengan n), per seller (Single-Seller Population, ≥30 order).
4. Bukti caveat order-level: multi-seller vs single-seller; pengaruh bauran multi-kategori.
5. Rasio komentar per skor, jeda jawab, dan verifikasi makna `review_creation_date`.
6. Reconcile ke KPI terkunci dan angka D4 roadmap (`sat_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**37 metrik: 33 PASS, 4 INFO, 0 CHECK.** Review Population **98.673** reconcile ke `fact_orders.has_review`, ke jumlah per skor, dan ke jumlah bulanan; Avg Review Score **4,0864** sama dengan nilai terkunci; seluruh angka D4 roadmap (n, rata-rata, % skor ≤2) tereproduksi persis.

### 1. Distribusi, cakupan, tren
- **Distribusi (Review Population):** skor 5 = **57,77%** (57.008), 4 = 19,29%, 3 = 8,24%, 2 = 3,17%, 1 = **11,52%** (11.363); skor 1–2 = 14,69%. Bentuk J/U: skor 1 lebih besar daripada skor 2 dan 3.
- **Rasio order ber-review: 99,228%** (98.673 dari 99.441; 768 tanpa review). Per status: delivered 99,33%, shipped 93,22%, canceled 96,80% (605), unavailable 97,70% (595), invoiced 98,41%, processing 98,01%, created 60,0% (3 dari 5), approved 100%. Order canceled dan unavailable pun punya review (total 1.200).
- **Tren bulanan (20 bulan `full`):** rata-rata 3,75–4,28. Tertinggi 2018-06 **4,277**, 2018-07 4,263, 2018-08 4,256, 2017-08 4,239. Terendah **2018-03 3,753** (22,79% skor ≤2), 2018-02 3,826 (20,89%), 2017-11 3,911 (18,77%). Pola ini searah dengan Late Rate bulanan Tahap 11 (puncak Feb–Mar 2018 dan Black Friday, terendah Juni 2018).
- Rata-rata skor order **on-time** relatif stabil 4,20–4,40, tetapi lebih rendah pada bulan padat (2017-11..2018-03: 4,20–4,25) dibanding 2018-04..08 (4,30–4,40).
- Bulan non-`full` hanya anotasi: 2018-09 (15 review, rata-rata 1,80) dan 2018-10 (4 review, 2,25) hampir seluruhnya order canceled; 2016-09 (4 review).

### 2. Late vs on-time — dua lapis (D4)

**Lapis 1 — semua order (Delivered ∩ Review, n = 95.824):**

| Kelompok | n | Rata-rata | % skor ≤ 2 |
|---|---:|---:|---:|
| on-time | 89.443 | **4,29** | 9,27% |
| late | 6.381 | **2,27** | 62,42% |

**Lapis 2 — distratifikasi menurut `answered_before_delivery`:**

| | Dijawab sesudah barang sampai | Dijawab sebelum barang sampai |
|---|---|---|
| **on-time** | n 89.263 · **4,291** · 9,25% ≤2 | n 180 · 3,956 · 17,22% ≤2 |
| **late** | n 1.908 · **3,720** · 19,44% ≤2 | n 4.473 · **1,652** · **80,75%** ≤2 |

- **Efek keterlambatan pasca-terima = −0,571 poin** (3,720 vs 4,291).
- **70,1%** order late ber-review dijawab sebelum barang tercatat sampai (4.473 dari 6.381); hanya 4,86% (4.653) dari seluruh Delivered ∩ Review.
- Selisih lapis 1 (−2,02 poin): bila seluruh order late berskor seperti late yang dijawab sesudah (3,72), selisihnya hanya −0,57; sisa ≈ 72% selisih berasosiasi dengan kelompok yang menjawab sebelum barang tiba. Dua lapis ini **tidak boleh dilebur** menjadi satu angka.

**Bucket keterlambatan di kedua strata:**

| Bucket | n semua | Rata-rata semua | n sesudah | Rata-rata sesudah (% ≤2) | n sebelum | Rata-rata sebelum (% ≤2) |
|---|---:|---:|---:|---:|---:|---:|
| on-time/early | 89.443 | 4,290 | 89.263 | 4,291 (9,25%) | 180 | 3,956 (17,22%) |
| telat 1–3 hari | 1.852 | 3,291 | 1.436 | 3,746 (18,59%) | 416 | 1,721 (78,85%) |
| telat 4–7 hari | 1.748 | 2,103 | 396 | 3,692 (20,45%) | 1.352 | 1,638 (81,51%) |
| telat > 7 hari | 2.781 | 1,696 | 76 | 3,368 (30,26%) | 2.705 | 1,649 (80,67%) |

- Pada strata **sebelum**, rata-rata hampir konstan (1,64–1,72) tak peduli berapa hari telat. Pada strata **sesudah**, skor turun pelan: 3,746 → 3,692 → 3,368 (n hanya 76 pada > 7 hari).
- Gradien curam pada "semua order" (3,29 → 2,10 → 1,70) sebagian besar adalah **efek komposisi**: porsi yang menjawab sebelum barang tiba naik dari 22,5% (telat 1–3 hari) → 77,3% (4–7) → 97,3% (> 7).
- **Tren bulanan dua lapis:** rata-rata late yang dijawab sesudah barang sampai stabil 3,3–4,0 (abaikan 2017-01..02, n kecil) sementara late semua 1,9–3,0 dan on-time 4,2–4,4. Porsi late yang dijawab sebelum tiba mencapai 73–78% pada bulan padat (2017-11 73,7%, 2018-02 78,2%, 2018-03 75,4%) tetapi hanya **46,8% pada 2018-08**, bertepatan dengan rata-rata late semua tertinggi (2,995).

### 3. Associated Review Score per kategori (Review ∩ Revenue; ≥100 order)
52 kategori memenuhi minimum volume. Rentang rata-rata **3,619–4,503** (median 4,107); korelasi lintas-kategori skor vs Late Rate hanya −0,204.

| Terendah | n order | Skor terasosiasi | % ≤2 | Skor order on-time |
|---|---:|---:|---:|---:|
| office_furniture | 1.262 | **3,619** | 22,66% | 3,756 |
| fashion_male_clothing | 110 | 3,727 | 25,45% | 3,891 |
| audio | 346 | 3,844 | 21,68% | 4,118 |
| home_comfort | 395 | 3,861 | 19,24% | 4,059 |
| construction_tools_safety | 164 | 3,872 | 20,12% | 4,045 |
| fashion_underwear_beach | 120 | 3,933 | 18,33% | 4,257 |
| unknown | 1.425 | 3,934 | 19,51% | 4,159 |
| fixed_telephony | 211 | 3,943 | 17,54% | 4,060 |
| home_construction | 487 | 3,967 | 17,66% | 4,077 |
| **bed_bath_table** | **9.295** | 3,974 | 16,66% | 4,138 |

| Tertinggi | n order | Skor terasosiasi | % ≤2 |
|---|---:|---:|---:|
| books_general_interest | 501 | **4,503** | 7,19% |
| books_technical | 257 | 4,401 | 10,12% |
| food_drink | 225 | 4,396 | 5,33% |
| luggage_accessories | 1.026 | 4,344 | 8,87% |
| food | 444 | 4,284 | 11,26% |
| stationery | 2.284 | 4,256 | 11,16% |
| pet_shop | 1.697 | 4,246 | 11,43% |
| fashion_shoes | 234 | 4,235 | 11,97% |
| construction_tools_garden | 192 | 4,219 | 13,02% |
| perfumery | 3.134 | 4,215 | 13,02% |

- `office_furniture` tetap terendah bahkan pada order on-time (3,756 vs rata-rata on-time keseluruhan 4,29), sehingga rendahnya skor kategori ini tidak hanya soal keterlambatan; `bed_bath_table` adalah kategori terbesar berdasarkan order dengan skor di bawah rata-rata.
- **Pengaruh bauran multi-kategori kecil:** selisih rata-rata mutlak antara skor semua order dan skor order satu kategori hanya **0,021** (maks 0,111, pada home_construction; home_comfort ≈ 0,09).

### 4. Review score per state (27 state, n selalu ditampilkan)
- Rentang rata-rata **3,609 (RR, n = 46) – 4,205 (AM, n = 146)**. Negara bagian besar: SP **4,173** (12,64% ≤2; late 4,44%), PR 4,181, MG 4,135, RS 4,132; **RJ 3,877** (20,69% ≤2; late 11,92%), **BA 3,862**, CE 3,857, PA 3,850, **MA 3,757** (21,83% ≤2; late 17,14%), **AL 3,756** (23,90% ≤2; late 20,81%), SE 3,808.
- **Korelasi lintas-state skor rata-rata vs Late Rate = −0,821** (27 titik). Rata-rata skor order on-time jauh lebih rata antar state (4,14–4,39: terendah BA 4,144, PA 4,154, MA 4,175; tertinggi RN 4,390, MS 4,363, SP 4,325). Perbedaan skor antar state sebagian besar mengikuti Late Rate state. Ini korelasi tingkat state (ekologis), bukan klaim tentang individu.

### 5. Review score per seller (Single-Seller ∩ Review; ≥30 order)
- **619 seller** memenuhi ≥30 order, mencakup **79.915 order (83,07%)** dari order single-seller ber-review. Rata-rata skor seller: P10 **3,81**, P50 **4,185**, P90 **4,51**; korelasi skor seller vs Late Rate seller **−0,541**.
- **Terendah:** `1ca7077d…` (SP, 112 order) 2,330 (61,61% ≤2; late 17,14%); `2eb70248…` (SP, 196) 2,684 (50,51%; late 10,99%); `54965bbe…` (PR, 73) 3,027 (late 29,41%); `a49928bc…` (SP, 95) 3,063 (late 22,58%); `972d0f9c…` (SC, 73) 3,082 (late 12,33%). Sebagian seller berskor rendah punya Late Rate rendah (`8444e55c…` 3,323 dengan late 6,67%; `710e3548…` 3,368 dengan late 3,13%; `a7f13822…` 3,338 dengan late 4,17%), sehingga rendahnya skor tidak selalu karena keterlambatan.
- **Tertinggi:** `48efc9d9…` (PR) 5,000 (n = 33), `02f5837…` (PR) 4,833 (30), `d13e50ea…` 4,821 (67), `83e197e9…` (RJ) 4,809 (47). Seller dengan n 30–67 rentan noise.

### 6. Bukti caveat order-level
Order **multi-seller** (1.264 order ber-review) berskor **2,858** (47,31% ≤2) vs **single-seller** (96.653) **4,121** (13,76% ≤2), selisih 1,26 poin. Karena review menempel pada order, menerapkan skor order multi-seller ke setiap seller atau kategori akan mencemari skornya; analisis seller karena itu hanya memakai Single-Seller Population dan skor kategori disebut **Associated Review Score**.

### 7. Komentar dan waktu survei
- **Komentar:** 41,30% review ber-komentar (40.748). Rasio per skor: **76,61%** (skor 1), 68,13% (2), 43,49% (3), 31,22% (4), 35,84% (5). Rata-rata skor review dengan komentar 3,669 vs tanpa komentar 4,380. (Angka roadmap 76,55% adalah referensi baris mentah; di data dedup 76,61%.)
- **Jeda jawab (`review_creation` → `review_answer`):** median 1,68 hari, P75 3,10, P95 6,98, maks 518,7. < 1 hari 24,56% (rata-rata skor 3,886), 1–2 hari 31,20% (4,237), 2–7 hari 39,27% (4,101), 7–30 hari 4,27% (4,005), ≥ 30 hari 0,69% (4,100).
- **Makna `review_creation_date` (tanggal survei dikirim):** untuk order terkirim, tanggal survei jatuh **+1 hari** setelah tanggal barang tersampai pada **89,04%** (median = P25 = P75 = 1); hari yang sama 3,30%; sebelum tanggal sampai 5,19% (4.976); +2 hari 1,02%; +3..7 hari 0,83%; > 7 hari 0,62%. Untuk 4.653 review yang dijawab **sebelum** barang sampai, tanggal survei jatuh **+2 hari setelah tanggal estimasi** (median = P25 = P75 = 2; 95,04% pada atau setelah estimasi). Pola ini konsisten dengan deskripsi dataset di Kaggle bahwa survei dikirim begitu barang diterima atau tanggal estimasi pengiriman sudah lewat. Dengan demikian pelanggan dengan barang yang terlambat disurvei saat barang belum sampai, yang menjelaskan strata "dijawab sebelum barang sampai".

## Hipotesis Kandidat (untuk Tahap 13–17 dan 21, belum diuji)
- **H-V1** Sebagian besar kesenjangan skor late vs on-time (≈ 72%) berasosiasi dengan survei yang terkirim sebelum barang tiba; efek keterlambatan pasca-terima jauh lebih kecil (−0,57 poin). Laporan wajib menampilkan dua lapis. → Tahap 21
- **H-V2** Bulan dengan Late Rate tinggi (Black Friday 2017-11, Feb–Mar 2018) adalah bulan dengan skor rata-rata terendah; skor on-time juga sedikit lebih rendah pada bulan padat. → Tahap 21
- **H-V3** Perbedaan skor antar state sebagian besar mengikuti Late Rate state (r = −0,82); state dengan skor terendah (RJ, BA, CE, MA, AL, SE) adalah state dengan Late Rate tinggi. → Tahap 16
- **H-V4** `office_furniture` dan `bed_bath_table` memiliki skor rendah yang tidak sepenuhnya dijelaskan keterlambatan. → Tahap 14
- **H-V5** Skor seller sebagian dipengaruhi keterlambatan (r = −0,54), tetapi beberapa seller berskor rendah bukan seller yang terlambat. → Tahap 15
- **H-V6** Order multi-seller berskor jauh lebih rendah (2,86 vs 4,12). → Tahap 15

## Output
- Tabel: `sat_monthly` (26 bulan), `sat_findings` (37 metrik)
- `data/processed/11_sat_monthly.parquet` (26 baris), `11_sat_findings.parquet` (37 baris); ter-ignore git
- Caveat "Associated Review Score" ditambahkan ke `docs/assumptions.md` (bagian 9)

## Assumptions
- Avg Review Score = rata-rata skor pada Review Population (dedup 1 review/order, D3), definisi terkunci.
- Late = `is_late` (tanggal, D1); `answered_before_delivery` hanya terisi untuk Delivered Population.
- Bucket keterlambatan berbasis selisih tanggal terima vs tanggal estimasi (hari).
- Skor kategori memakai pasangan order-kategori unik; order multi-kategori dihitung di tiap kategori ("Associated Review Score").
- Skor seller hanya dari Single-Seller Population dengan ≥30 order ber-review.
- Pernyataan tentang kapan survei dikirim didasarkan pada deskripsi dataset Kaggle (survei dikirim ketika barang diterima atau estimasi sudah lewat) dan pola data; teks kamus kolom per kolom tidak diperiksa langsung.

## Batasan data
- Review adalah order-level; tidak ada skor per item, per seller, atau per kategori pada order campuran.
- Review Population juga memuat review pada order yang tidak pernah berstatus delivered (2.849 review di luar Delivered ∩ Review, termasuk 605 canceled dan 595 unavailable). Dari angka sel D4, rata-rata Delivered ∩ Review ≈ 4,16 dan rata-rata 2.849 review lainnya ≈ 1,75 (perhitungan turunan dari angka yang dilaporkan; belum diverifikasi dengan query langsung). Avg Review Score terkunci (4,0864) mencakup keduanya.
- Rata-rata skor dan Late Rate per state dihitung pada tingkat state; korelasi −0,82 tidak boleh ditafsirkan sebagai efek pada pelanggan individu.
- Sampel kecil: late dijawab sesudah pada > 7 hari (n = 76), RR (46), AP (67), AC (81), seller dengan 30–67 order.
- Tidak ada kontrol terhadap variabel perancu (kategori, seller, state, harga) pada seluruh perbandingan.

## Kesimpulan
Review Population dan Avg Review Score reconcile penuh, dan stratifikasi timing (D4) tereproduksi persis. Kepuasan pelanggan tinggi secara umum (57,8% skor 5; rata-rata 4,09), tetapi kesenjangan late vs on-time (−2,02 poin pada lapis 1) sebagian besar berasosiasi dengan survei yang terkirim sebelum barang sampai; setelah barang tiba, efek keterlambatan hanya ≈ −0,57 poin. Perbedaan skor antar bulan dan antar state sangat searah dengan Late Rate, sedangkan perbedaan antar kategori dan seller tidak sepenuhnya dijelaskan keterlambatan. Skor kategori harus disebut Associated Review Score dan skor seller hanya dari order single-seller.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** laporkan skor late dengan dua lapis; periksa waktu pengiriman survei terhadap estimasi; fokus pada kategori berskor rendah dan bervolume besar (`bed_bath_table`, `office_furniture`) serta state dengan skor dan Late Rate rendah (RJ, BA, MA, AL).
