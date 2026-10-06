# 15 — Regional Performance Analysis

> Pendamping `sql/15_regional_performance.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah. **State tidak ditier (D12):** semua 27 state ditampilkan dengan n dan share; kolom `low_n_flag` hanya penanda keandalan (n kecil), bukan segmen.

## Input
- Model dimensional Tahap 8: `fact_orders`, `dim_seller`, `dim_geo_zip`
- Populasi: Order Population (99.441), Revenue Population (98.199), Delivered Population (96.470), Review Population (98.673), Single-Seller Delivered dengan koordinat valid (94.724) untuk standardisasi jarak

## Proses Analisis
1. Tabel silang per state (`regional_state`, 27 state): order, revenue, AOV, freight, `delivery_days`, Late Rate, skor review, pembatalan.
2. Konsentrasi (SP, RJ, MG) dan korelasi antar state.
3. **Absolute vs relative:** kinerja state dibandingkan dengan ekspektasi menurut bauran jarak seller–customer (standardisasi tidak langsung dari rata-rata nasional per band jarak; `regional_relative`), dan skor review relatif terhadap rata-rata nasional.
4. Kota (kombinasi state–kota; `regional_city`): hanya kota ≥ 100 order untuk rate/ranking (D6); top kota, revenue, AOV, Late Rate, skor; kota terbesar relatif terhadap state-nya; variasi antar kota di dalam state.
5. Reconcile dan uji D12 (`regional_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**27 metrik: 24 PASS, 2 INFO, 1 CHECK** (dijelaskan di bawah). Jumlah order 27 state = **99.441** (Order Population) dan **98.199** (Revenue Population); revenue = R$ 13.494.400,74; delivered = 96.470; review = 98.673; AOV nasional R$ 137,42 dan Late Rate 6,773% sama dengan nilai terkunci. **D12 terpenuhi:** tidak ada kolom bernama *tier* di `regional_state`, `regional_city`, maupun `regional_relative`.

### 1. Konsentrasi dan tabel silang per state (27 state)
- **Konsentrasi (bukan tier):** SP **41,98%** order (41,88% revenue order; 38,27% revenue), RJ 12,92% (12,93%; 13,43% revenue), MG 11,70% (11,71%; 11,66%). SP + RJ + MG = **66,6%** order dan **63,36%** revenue. HHI order antar state 2.168,6. **15 state masing-masing < 1% order** (0,05–0,98%: PA, MT, MA, MS, PB, PI, RN, AL, SE, TO, RO, AM, AC, AP, RR).
- **AOV:** terendah **SP R$ 125,57** (41.125 revenue order), ES 135,55, PR 135,87; tertinggi **PB R$ 216,34** (531), AP 198,15 (68), AC 197,32 (81), AL 195,41 (411), RO 187,12 (246), PA 184,54. State besar: RJ 142,68, MG 136,87, RS 137,13, SC 144,09, BA 151,65, DF 141,93, GO 144,08.
- **Ongkir:** rata-rata per order SP **R$ 17,37** (13,83% dari harga) hingga RR R$ 49,10 (28,55%), PB 48,30, RO 46,31, AC 45,52, MA 42,66 (26,32%).
- **Waktu kirim (median) dan Late Rate:** SP 7,21 hari / **4,49%**; PR 10,43 / 4,04%; MG 10,31 / 4,57%; DF 11,36 / 5,67%; **RJ 12,04 / 12,11%**; RS 13,18 / 6,08%; SC 13,01 / 8,21%; ES 13,64 / 10,73%; BA 16,91 / 12,16%; CE 18,21 / 13,76%; PA 21,08 / 11,21%; **MA 19,19 / 17,43%**; **AL 22,33 / 21,41%**. State Utara kecil berestimasi panjang tetapi Late Rate rendah: AM 25,88 hari / 2,76%, RO 2,88%, AP 2,99%, AC 3,75%.
- **Skor review:** SP 4,173, PR 4,181, MG 4,135, RS 4,132; RJ **3,877**, BA 3,862, CE 3,857, PA 3,850, SE 3,808, MA 3,757, AL 3,756, RR 3,609 (n = 46). Porsi skor ≤ 2: SP 12,64% sampai AL 23,90%, RR 23,91%, MA 21,83%, SE 21,78%, RJ 20,69%.
- **Korelasi antar 27 state (ekologis):** Late Rate vs skor **−0,82**; ongkir per order vs `delivery_days` rata-rata **0,805**; AOV vs freight % 0,579; `delivery_days` vs Late Rate 0,32; log(order) vs Late Rate −0,083.

### 2. Absolute vs relative (standardisasi jarak; 94.724 order Single-Seller terkirim ber-jarak)
Rasio `delivery_days` observasi/ekspektasi (> 1 = lebih lambat dari ekspektasi bauran jaraknya) dan selisih Late Rate (poin):

| State | n ber-jarak | Jarak rata-rata (km) | Delivery obs / eks (hari) | Rasio | Late Rate obs vs eks | Selisih (poin) |
|---|---:|---:|---:|---:|---:|---:|
| RR | 41 | 3.243,6 | 29,39 / 21,21 | 1,386 | 12,20 / 12,09 | +0,11 |
| **AL** | 394 | 1.832,0 | 24,60 / 18,25 | **1,348** | 21,57 / 9,87 | **+11,71** |
| **RJ** | **12.144** | 488,7 | 15,37 / 12,80 | **1,201** | 12,22 / 6,80 | **+5,43** |
| SE | 331 | 1.647,7 | 21,56 / 18,11 | 1,190 | 15,41 / 9,77 | +5,64 |
| PA | 935 | 2.282,3 | 23,78 / 20,64 | 1,153 | 11,23 / 11,65 | −0,42 |
| SC | 3.497 | 572,5 | 14,99 / 13,24 | 1,132 | 8,26 / 6,90 | +1,37 |
| BA | 3.202 | 1.343,8 | 19,37 / 17,61 | 1,099 | 12,21 / 9,36 | +2,85 |
| MA | 702 | 2.100,7 | 21,57 / 20,06 | 1,075 | 17,38 / 11,27 | +6,11 |
| SP | 39.840 | 249,4 | 8,79 / 9,80 | 0,897 | 4,55 / 5,60 | −1,05 |
| DF | 1.894 | 838,0 | 13,00 / 14,81 | 0,878 | 5,81 / 7,41 | −1,61 |
| MG | 11.155 | 532,3 | 12,04 / 12,88 | 0,934 | 4,61 / 6,79 | −2,18 |
| PR | 4.838 | 485,6 | 12,01 / 12,79 | 0,939 | 4,03 / 6,76 | −2,73 |

- **Peringkat absolut → relatif** (state ≥ 300 order ber-jarak): AL 1 → 1, MA 2 → 2, SE 3 → 3, **RJ 7 → 4**, ES 9 → 5, PI 4 → 6, BA 6 → 7, CE 5 → 8, **PA 8 → 11**, PB 10 → 13, PE 12 → 15, MT 17 → 21 (terbaik relatif: −3,42 poin), SP 20 → 14.
- **Terjelaskan jarak:** Late Rate tinggi pada PA, PB, PE, CE, MT sebagian besar sepadan dengan jarak seller–customer. **Tetap lebih buruk dari ekspektasi:** RJ (rasio 1,20; +5,4 poin; 12.144 order), AL, MA, SE, ES, PI, BA — mengarah pada isu logistik spesifik wilayah, bukan sekadar jarak.
- **State Utara kecil** (AM −9,28; AP −8,99; RO −8,60; AC −8,26 poin; n = 67–238) jauh lebih sering tepat waktu daripada ekspektasi: konsisten dengan estimasi yang jauh lebih longgar; n kecil.
- **Skor relatif terhadap rata-rata nasional (4,0864):** RR −0,478 (n = 46), AL **−0,330**, MA −0,329, SE −0,278, PA −0,236, CE −0,230, BA −0,225, RJ −0,209, PI −0,168; AM +0,119 (n = 146), AP +0,108 (67), PR +0,095, SP +0,087. **Pada order on-time**, selisih mengecil: AL +0,008, SE −0,037, RJ −0,047, CE −0,045; yang tetap −0,12 s.d. −0,15 hanya BA (−0,147), PA (−0,137), MA (−0,116). Kesenjangan skor antar state sebagian besar berasosiasi dengan Late Rate.

### 3. Kota (kombinasi state–kota)
- **Cakupan:** **4.310** kombinasi state–kota; **141 kota ≥ 100 order** mencakup **66.919 order (67,3%)**; **407 kota ≥ 30 order** mencakup 81,63%.
- **Konsentrasi kota:** São Paulo (SP) saja **15.540 order (15,63%)**; top-5 kota 29,01%, top-10 35,24%, top-20 42,24% dari seluruh order. Top kota: São Paulo 15.540, Rio de Janeiro 6.882 (6,92%), Belo Horizonte 2.773 (2,79%), Brasília 2.131 (2,14%), Curitiba 1.521, Campinas 1.444, Porto Alegre 1.379, Salvador 1.245, Guarulhos 1.189, São Bernardo do Campo 938.
- **Revenue terbesar:** São Paulo R$ 1.897.019,80 (AOV R$ 124,06), Rio de Janeiro R$ 986.528,05 (145,08), Belo Horizonte 350.760,93 (128,16), Brasília 300.202,76 (142,21), Curitiba 208.008,66, Campinas 186.925,85, Porto Alegre 186.788,31, Salvador 180.735,72 (146,46).
- **AOV (≥ 100 order):** tertinggi Divinópolis (MG) **R$ 262,92** (134 revenue order), João Pessoa 208,58 (253), Porto Velho 201,27 (109), Nova Friburgo 187,26, Maceió 181,72, Belém 181,71 (440); terendah seluruhnya SP wilayah penyangga/pinggiran: Francisco Morato **R$ 89,11** (97), Franco da Rocha 92,86, Ribeirão Pires 94,86, Jacareí 95,29, Itu 95,49, Carapicuíba 99,29 (324), Diadema 103,31 (282).
- **Late Rate tertinggi (≥ 100 order):** Maceió (AL) **27,12%** (236 terkirim; median 23,54 hari; skor 3,637), São Gonçalo (RJ) 21,56% (385), Cabo Frio (RJ) 21,24%, Nova Friburgo (RJ) 19,72%, São Luís (MA) 19,40% (335), Teresina (PI) 18,82% (271), Rio das Ostras (RJ) 17,69%, São João de Meriti (RJ) 16,13%, Macaé (RJ) 15,79%, Resende (RJ) 15,65%. **Delapan dari sepuluh adalah kota di RJ (selain Rio sendiri).**
- **Late Rate terendah:** Araçatuba 0,73%, Divinópolis 0,76% (137), Gravataí 0,90%, Franco da Rocha 0,93%, São Caetano do Sul 1,84%, Piracicaba 1,97%, Cotia 2,07%, Bragança Paulista 2,08%.
- **Skor:** terendah Macaé 3,604, Rio das Ostras 3,625, Maceió 3,637, Nova Friburgo 3,642, Belford Roxo 3,651 (Late Rate hanya 6,73%, n = 111), São Gonçalo 3,657, Cabo Frio 3,675, São Luís 3,691; tertinggi Uberaba 4,440, Rio Claro 4,431, Pindamonhangaba 4,406, Santa Bárbara d'Oeste 4,393, Ponta Grossa 4,392, Araraquara 4,370.
- **Relatif terhadap state-nya (15 kota terbesar):** Campinas Late Rate 8,46% vs SP 4,49% (**+3,97 poin**); Porto Alegre 10,14% vs RS 6,08% (+4,06); Goiânia 9,70% vs GO 6,54% (+3,16); Salvador 14,65% vs BA 12,16% (+2,48; skor −0,143); Santos +2,22; Santo André 2,70% (−1,79). **Rio de Janeiro (kota) 10,70% lebih baik daripada RJ (state) 12,11%**: masalah Late Rate RJ terkonsentrasi di kota-kota lain di negara bagian itu.
- **Variasi di dalam state (kota ≥ 100 order):** SP (58 kota) 0,73–15,49% (rentang **14,77 poin**); RJ (20 kota) 2,83–21,56% (**18,73**); RS (10) 0,90–12,40% (11,50); SC (7) 4,97–14,43% (9,46); MG (15) 0,76–7,81% (7,06); ES (5) 9,09–13,80%; PR (6) 3,36–6,16% (2,81). Rata-rata state menyembunyikan variasi antar kota yang besar.

### Metrik CHECK (1)
| Metrik | Aktual | Roadmap | Penjelasan |
|---|---:|---:|---|
| State < 1% order | **15** | 17 | Tidak terreproduksi pada basis mana pun: Order Population dan Revenue Population masing-masing 15 state (PA 0,98% sampai RR 0,05%); basis revenue 13 state. Kemungkinan angka "17" di roadmap salah hitung. Teks roadmap/dashboard sebaiknya memakai **15**. Tidak mempengaruhi DoD. |

## Hipotesis Kandidat (untuk Tahap 17 dan 21, belum diuji)
- **H-R1** Permintaan sangat terkonsentrasi geografis: SP + RJ + MG = 66,6% order; São Paulo (kota) = 15,6%; 15 state < 1% order tetap harus ditampilkan dengan n. → Tahap 21
- **H-R2** State jauh (Utara/Timur Laut) berAOV tinggi dan menanggung ongkir tinggi (freight % 20–29%); SP berAOV terendah dengan ongkir terendah. → Tahap 21
- **H-R3** Jarak menjelaskan sebagian besar perbedaan absolut, tetapi RJ, AL, MA, SE, ES lebih lambat dan lebih sering terlambat daripada ekspektasi jarak mereka (isu logistik spesifik wilayah/lane). → Tahap 21
- **H-R4** Estimasi tampak jauh lebih longgar untuk state Utara kecil (AM, AP, RO, AC): Late Rate 8–9 poin di bawah ekspektasi. → Tahap 21 (batasan; n kecil)
- **H-R5** Kesenjangan skor antar state terutama berasosiasi dengan Late Rate (r = −0,82); pada order on-time selisih kecil, kecuali BA, PA, MA. → Tahap 21
- **H-R6** Keterlambatan RJ terkonsentrasi di kota-kota di luar Rio (São Gonçalo, Cabo Frio, Nova Friburgo, Rio das Ostras, Macaé). → Tahap 21
- **H-R7** Variasi antar kota di dalam state besar (SP 14,8 poin; RJ 18,7 poin) menuntut analisis tingkat kota di samping state. → Tahap 21

## Output
- Tabel: `regional_state` (27), `regional_relative` (27), `regional_city` (407), `regional_findings` (27)
- `data/processed/15_regional_state.parquet` (27), `15_regional_city.parquet` (407), `15_regional_findings.parquet` (27); ter-ignore git

## Assumptions
- Kota = kombinasi (`customer_state`, `customer_city`); hanya kota ≥ 100 order (D6) untuk ranking/rate; kota 30–99 order tercatat di `regional_city` dengan penanda `memenuhi_min_volume = FALSE`.
- Standardisasi jarak: ekspektasi per state = rata-rata nasional per band jarak (< 100, 100–299, 300–599, 600–999, 1.000–1.999, ≥ 2.000 km) dibobot bauran jarak state tersebut; jarak = haversine antar-centroid zip; peringkat relatif hanya untuk state dengan ≥ 300 order ber-jarak.
- Skor relatif memakai rata-rata nasional Review Population (4,0864) dan rata-rata nasional order on-time terkirim.
- Late Rate dan `delivery_days` dari Delivered Population; AOV dan freight dari Revenue Population.

## Batasan data
- Korelasi antar state adalah korelasi agregat (ekologis); tidak mewakili efek pada pelanggan individu.
- State dengan n kecil (AP 68, RR 46, AC 81, AM 148, TO 280, SE 350, AL 413) menghasilkan rate yang tidak stabil; standardisasi jarak pada state itu juga rapuh.
- Standardisasi jarak tidak mengontrol kategori, berat, seller, atau musim; hanya jarak.
- Jarak adalah jarak antar-centroid zip, bukan alamat; 5.476 order Single-Seller terkirim tidak punya jarak (zip placeholder atau tanpa koordinat valid).
- Nama kota diambil dari data pelanggan apa adanya (lowercase, tanpa aksen); variasi ejaan tidak dikonsolidasi.
- Seluruh perbandingan wilayah adalah asosiasi tanpa kontrol variabel perancu.

## Kesimpulan
Order, revenue, delivered, dan review per state reconcile penuh ke populasi terkunci, dan D12 terpenuhi (tanpa tiering). Permintaan terkonsentrasi (SP, RJ, MG = 66,6% order; São Paulo kota = 15,6%), AOV dan ongkir naik menjauhi SP. Perbedaan kinerja absolut antar state sebagian besar sepadan dengan jarak, tetapi RJ, AL, MA, SE, dan ES lebih buruk daripada ekspektasi jarak mereka, dengan masalah RJ terkonsentrasi di kota-kota di luar Rio. Variasi antar kota di dalam state sangat besar, dan angka roadmap "17 state < 1% order" sebenarnya 15.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** fokus investigasi logistik pada RJ (terutama São Gonçalo, Cabo Frio, Nova Friburgo, Macaé) dan lane menuju AL/MA/SE; baca kinerja state selalu bersama n dan jarak; laporan wilayah menampilkan state dan kota ≥ 100 order, tanpa tiering state.
