# 08 — Sales & Revenue Performance

> Pendamping `sql/08_sales_revenue_performance.sql`. Hasil dijalankan di DuckDB lokal. Semua hubungan antar variabel adalah **asosiasi, bukan kausal**; definisi KPI terkunci (Tahap 6) tidak diubah.

## Input
- Model dimensional Tahap 8: `fact_orders`, `fact_order_items`, `dim_product`, `dim_date`
- Populasi: Revenue Population (98.199 order) dan Analysis Window (2017-01 s.d. 2018-08, `period_quality = full`)

## Proses Analisis
1. Tren bulanan (`sales_monthly`): order, Item Revenue, Freight Revenue, GMV, AOV (dengan dan tanpa ongkir). Semua bulan tampil dengan `period_quality`; MoM hanya dihitung bila kedua bulan `full`.
2. Tren kuartalan (bulan `full` saja) dan YoY bulan yang sama (Jan–Agu 2017 vs Jan–Agu 2018).
3. Dekomposisi lonjakan 2017-11 vs 2017-10: efek volume vs efek nilai per order, kontribusi per kategori dan per state, konsentrasi harian.
4. Rasio freight terhadap harga: per kategori (≥100 revenue order, D6), per state (semua 27 state, tanpa tiering, D12).
5. Sensitivity delivered-only vs Revenue Population penuh (D2), total dan per bulan.
6. Reconcile ke KPI terkunci dan identitas dekomposisi (`sales_findings`); ekspor parquet.

## Temuan

### Reconcile (DoD)
**21 metrik: 18 PASS, 3 INFO, 0 CHECK.**

| KPI terkunci | Nilai | Status |
|---|---:|---|
| Item Revenue Revenue Population | R$ 13.494.400,74 | PASS |
| Freight Revenue | R$ 2.241.126,29 | PASS |
| GMV incl. Freight | R$ 15.735.527,03 | PASS |
| Revenue Orders | 98.199 | PASS |
| AOV | R$ 137,42 | PASS |

Jumlah semua bulan di `sales_monthly` = total (Item Revenue, Revenue Orders, dan 99.441 order). Revenue di dalam + di luar Analysis Window = total. Revenue per kategori (`fact_order_items`) = Item Revenue total. Di luar Analysis Window hanya R$ 44.871,06 (0,33% revenue); di dalamnya R$ 13.449.529,68.

### 1. Tren bulanan (20 bulan `full`)
- Item Revenue naik dari R$ 120 ribu (2017-01) ke puncak **R$ 1,004 juta (2017-11)**, lalu mendatar di **R$ 0,85–0,99 juta per bulan** sepanjang 2018 (Maret–Mei ≈ R$ 0,98–0,99 juta; Juni–Agustus turun ke R$ 863 ribu, 878 ribu, 849 ribu).
- Revenue Orders puncak 7.421 (2017-11); 2018 berada di 6.145–7.187 per bulan.
- AOV bergerak di R$ 124,76 (2017-07) hingga R$ 152,60 (2017-01); AOV incl. freight R$ 146,67–174,01.
- Rasio freight/item naik pelan: 14,0–16,2% pada semester pertama 2017 menjadi 17,5–18,4% pada Maret dan Juni–Agustus 2018 (puncak 18,42% di 2018-07).
- Bulan non-`full` ditampilkan sebagai anotasi, bukan garis turun: 2016-09 (2 revenue order, R$ 207,86), 2016-10 (290, R$ 44.507,30), **2016-11 kosong**, 2016-12 (1, R$ 10,90), 2018-09 (1, R$ 145,00), 2018-10 (0). MoM bernilai NULL pada bulan-bulan tersebut dan pada 2017-01 (bulan sebelumnya tidak `full`).

### 2. Kuartalan dan YoY

| Kuartal | Revenue Orders | Item Revenue (R$) | AOV (R$) | Catatan |
|---|---:|---:|---:|---|
| 2017-Q1 | 5.122 | 733.398,94 | 143,19 | |
| 2017-Q2 | 9.222 | 1.286.918,78 | 139,55 | +75,5% vs Q1 |
| 2017-Q3 | 12.445 | 1.681.949,00 | 135,15 | +30,7% |
| 2017-Q4 | 17.586 | 2.406.225,55 | 136,83 | +43,1% |
| 2018-Q1 | 20.979 | 2.764.402,78 | 131,77 | +14,9% |
| 2018-Q2 | 19.897 | 2.849.730,26 | 143,22 | +3,1% |
| 2018-Q3 | 12.654 | 1.726.904,37 | 136,47 | **tidak lengkap** (2 bulan); rata-rata bulanan ≈ R$ 863 ribu vs ≈ R$ 950 ribu di Q2 |

YoY bulan yang sama, **Jan–Agu 2018 vs Jan–Agu 2017**: order **22.562 → 53.530 (+137,3%)**; Item Revenue **R$ 3,08 juta → R$ 7,34 juta (+138,3%, 2,38×)**. AOV agregat hampir tidak berubah (R$ 136,55 → 137,14), jadi pertumbuhan hampir seluruhnya berasal dari volume order.

Pertumbuhan YoY terus melambat: Item Revenue +687% (Jan), +242% (Feb), +166% (Mar), +181% (Apr), +97% (Mei), +101% (Jun), +78% (Jul), **+49% (Agu)**. Angka Januari–Februari dilebihkan oleh basis 2017 yang sangat kecil (2017-01 baru mulai 5 Januari).

### 3. Dekomposisi lonjakan 2017-11 vs 2017-10
- Item Revenue **+R$ 343.682,52 (+52,06%)**; Revenue Orders 4.547 → 7.421 (+63,2%), AOV 145,19 → 135,27 (−6,8%).
- **Efek volume order +R$ 417.276,50 (121,4% dari kenaikan)**; efek nilai per order **−R$ 73.593,98 (−21,4%)**. Kenaikan seluruhnya berasal dari jumlah order; nilai per order justru turun. Identitas dekomposisi eksak (selisih 0).
- **Harian:** 2017-11-24 (Jumat, bertepatan dengan Black Friday) = **1.166 revenue order, 15,71% order bulan itu, 6,27× median harian**, R$ 152.653,74. Tujuh hari 23–29 November menyumbang 3.420 order (46,1% order bulan itu); hari berikutnya 498, 400, 387, 376, 318, dan 275 (Kamis 23).
- **Per kategori:** kenaikan menyebar; 10 kategori teratas = 78,6% kenaikan. Terbesar: bed_bath_table +R$ 42.975 (12,5%), health_beauty +R$ 37.071 (10,8%), furniture_decor +R$ 32.821 (9,6%), watches_gifts +R$ 31.515 (9,2%), toys +R$ 29.959 (8,7%). Pertumbuhan order per kategori timpang: furniture_decor +103%, garden_tools +102%, housewares +84%, bed_bath_table +83%, toys +63%, health_beauty +60%, watches_gifts +50%, sports_leisure +31% (rata-rata +63%). Pergeseran porsi: bed_bath_table 7,00% → 8,88%, furniture_decor 4,57% → 6,28%, sports_leisure 7,51% → 6,35%.
- **Per state:** SP +R$ 129.693 (37,7%), RJ +R$ 53.264 (15,5%), MG +R$ 51.987 (15,1%) = 68,4% kenaikan; porsi kenaikan mendekati porsi dasar masing-masing state, dengan kenaikan porsi paling terasa di ES (1,57% → 2,42%), DF (1,98% → 2,68%), dan SC (3,18% → 4,02%).
- **Level shift:** Desember 2017 turun 26,1% tetapi masih 23,6% di atas Oktober; seluruh 2018 berada 35–58% di atas level Oktober 2017 (6.145–7.187 vs 4.547 revenue order). Lonjakan bukan sekadar puncak sesaat.

### 4. Rasio freight terhadap harga (keseluruhan 16,61% dari Item Revenue)
- **Per kategori (≥100 order):** tertinggi `christmas_supplies` 36,7% (127 order), `signaling_and_security` 30,3%, `food_drink` 29,7%, `electronics` 29,5% (2.543 order; rata-rata item per order R$ 61,8), `furniture_living_room` 26,1%, `office_furniture` 25,0% (1.272 order). Terendah `computers` 4,4%, `fixed_telephony` 7,9%, `agro_industry_and_commerce` 8,1%, `watches_gifts` 8,4% (5.604 order; rata-rata R$ 213,8 per order), `small_appliances` 8,4%. Pola konsisten dengan temuan EDA: beban ongkir turun seiring harga.
- **Per state (27 state, tanpa tiering):** rasio tertinggi RR 28,6% (45 order), MA 26,3% (736), RO 24,8%, AM 24,5%, PI 24,4%, SE 24,0%, TO 23,7%; **terendah SP 13,8%**, lalu DF 16,8%, RJ 16,8%, MG 17,1%. Ongkir rata-rata per order: SP R$ 17,37 vs RR R$ 49,10 (≈ 2,8×), PB R$ 48,30, RO R$ 46,31, AC R$ 45,52, MA R$ 42,66.
- AOV per state paling rendah di SP (R$ 125,57) dan paling tinggi di PB (R$ 216,34; 531 order), AC R$ 197,32 (81 order), AP R$ 198,15 (68 order). State dengan rasio freight tinggi cenderung juga ber-AOV tinggi; n kecil pada RR, AP, AC sehingga dibaca bersama jumlah order.

### 5. Sensitivity delivered-only (D2)

| Basis | Order | Item Revenue (R$) | AOV (R$) | % dari penuh |
|---|---:|---:|---:|---:|
| Revenue Population (penuh) | 98.199 | 13.494.400,74 | 137,42 | 100,00 |
| delivered-only | 96.478 | 13.221.498,11 | 137,04 | **97,98** |
| in-flight (status ≠ delivered) | 1.721 | 272.902,63 | 158,57 | **2,02** |

In-flight: `shipped` 1.106 order (R$ 150.727,44; 1,117%), `invoiced` 312 (R$ 61.526,37; 0,456%), `processing` 301 (R$ 60.439,22; 0,448%), `approved` 2 (R$ 209,60). Porsi in-flight per bulan: rata-rata 2,38%, tertinggi 2017-01 (6,91%), terendah 2018-06 (0,83%).

**Kesimpulan tren tidak berubah**: arah MoM sama pada **18 dari 19 bulan**. Satu-satunya yang beda adalah 2018-05 (−0,07% penuh vs +0,41% delivered-only), keduanya praktis datar. Selisih terbesar pada besar perubahan adalah 2017-02 (+104,0% vs +109,5%).

> Catatan: 96.478 order pada basis delivered-only = seluruh order berstatus `delivered` yang punya item; berbeda dengan Delivered Population (96.470) yang mensyaratkan tanggal terima.

## Output
- Tabel: `sales_monthly` (26 bulan), `sales_yoy`, `sales_findings`
- `data/processed/08_sales_monthly.parquet` (26 baris), `08_sales_findings.parquet` (21 baris); ter-ignore git

## Assumptions
- Revenue = `price` (Item Revenue); ongkir dilaporkan terpisah, GMV = Item + Freight, AOV tanpa ongkir kecuali berlabel "incl. freight".
- MoM hanya antar dua bulan `full`; YoY hanya bulan yang sama; kuartal dengan < 3 bulan `full` ditandai tidak lengkap.
- Dekomposisi memakai Oktober 2017 sebagai pembanding (MoM). Efek volume = Δorder × AOV Oktober; efek nilai = order November × ΔAOV.
- Kategori memakai `category_en_clean`; kategori di rasio freight hanya yang ≥100 revenue order (D6). State ditampilkan lengkap, tidak ditier (D12).
- Tanggal Black Friday (24 November 2017) berasal dari pengetahuan umum, bukan dari dataset.

## Batasan data
- Dataset tidak memuat promosi, harga diskon, atau traffic, sehingga penyebab lonjakan 2017-11 tidak dapat dipastikan; hanya konsentrasi volume pada hari tertentu yang teramati.
- Order in-flight tetap di Revenue Population (D2); sensitivity menunjukkan pengaruhnya kecil (2,02%).
- YoY awal tahun dilebihkan oleh basis 2017 yang kecil; 2018-09/10 terpotong, jadi YoY hanya Jan–Agu.
- State dengan sedikit order (mis. RR, AP, AC) menghasilkan AOV dan rasio freight yang rentan; jangan dibaca tanpa n.
- Rasio freight per kategori dan per state adalah asosiasi dan tercampur oleh harga, berat, dan jarak; tidak ada kontrol terhadap variabel perancu.

## Kesimpulan
Angka penjualan sepenuhnya reconcile dengan KPI terkunci dan lolos sensitivity delivered-only. Pertumbuhan 2017–2018 adalah pertumbuhan volume (+137% order YoY Jan–Agu, AOV hampir sama), melambat sepanjang 2018 dan mendatar di kisaran R$ 0,85–0,99 juta per bulan. Lonjakan November 2017 didorong volume order dan terkonsentrasi pada Black Friday, dengan efek level yang bertahan sesudahnya. Beban ongkir regresif terhadap harga dan paling tinggi di state Utara/Timur Laut, terendah di SP.

**Kandidat insight untuk Tahap 21 (belum rekomendasi final):** perencanaan kapasitas di sekitar Black Friday; beban ongkir pada barang murah dan di state jauh; pertumbuhan 2018 yang melambat dengan AOV datar.
