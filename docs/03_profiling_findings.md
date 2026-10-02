# 04 — Data Profiling Findings

> Pendamping `sql/03_data_profiling.sql`. Hasil dijalankan di DuckDB lokal. Tahap ini hanya mencatat masalah; tidak ada cleaning.

## Input
- Tabel `raw_*` di `data/olist.duckdb` (hasil Tahap 2, tidak diubah)
- Ekspektasi angka dari roadmap v1.6 (`olist_profiling.md` + `03b`/`03c`/`03d`)

## Proses Analisis
1. Helper view `p_*` (TRY_CAST) untuk profiling tanpa mengubah raw.
2. Null & blank profile seluruh 52 kolom.
3. Profiling per tabel; rekonsiliasi item+freight vs payment dengan Fan-out Guard (aggregate ke `order_id` dulu).
4. Cakupan waktu bulanan (bulan kosong tetap tampil).
5. Verifikasi aktual vs ekspektasi → `prof_findings` (129 metrik).
6. Ekspor `data/processed/03_profiling_summary.parquet` (275 baris: null_profile 52, category_dist 68, monthly 26, findings 129).

## Temuan

### Ringkasan verifikasi

**124 dari 129 metrik PASS, 5 CHECK** (dijelaskan di bagian "Metrik CHECK"). Semua angka lain cocok dengan roadmap, termasuk seluruh anomali timestamp, populasi order, duplikasi review, dan geolocation.

### Null & blank (kolom yang punya null)

| Tabel | Kolom | n_null | n_blank | % null |
|---|---|---:|---:|---:|
| order_reviews | review_comment_title | 87.656 | 2 | 88,34 |
| order_reviews | review_comment_message | 58.247 | 9 | 58,70 |
| orders | order_delivered_customer_date | 2.965 | 0 | 2,98 |
| orders | order_delivered_carrier_date | 1.783 | 0 | 1,79 |
| orders | order_approved_at | 160 | 0 | 0,16 |
| products | category, name_lenght, description_lenght, photos_qty | 610 | 0 | 1,85 |
| products | weight, length, height, width | 2 | 0 | 0,01 |

Kolom di tabel lain (customers, order_items, order_payments, sellers, geolocation, category_translation) tidak punya null.

### Orders

**Status**

| Status | n | % |
|---|---:|---:|
| delivered | 96.478 | 97,02 |
| shipped | 1.107 | 1,11 |
| canceled | 625 | 0,63 |
| unavailable | 609 | 0,61 |
| invoiced | 314 | 0,32 |
| processing | 301 | 0,30 |
| created | 5 | 0,01 |
| approved | 2 | 0,00 |

**Null struktural vs status**

| Status | n | null approved | null carrier | null customer |
|---|---:|---:|---:|---:|
| delivered | 96.478 | 14 | 2 | 8 |
| shipped | 1.107 | 0 | 0 | 1.107 |
| canceled | 625 | 141 | 550 | 619 |
| unavailable | 609 | 0 | 609 | 609 |
| invoiced | 314 | 0 | 314 | 314 |
| processing | 301 | 0 | 301 | 301 |
| created | 5 | 5 | 5 | 5 |
| approved | 2 | 0 | 2 | 2 |

Null sebagian besar mengikuti status (struktural). Anomali: 8 order `delivered` tanpa tanggal terima, 2 tanpa tanggal carrier, dan 6 order `canceled` yang punya tanggal terima (625 − 619).

**Anomali urutan timestamp:** carrier < purchase **166**; carrier < approved **1.359**; customer < carrier **23**; approved < purchase 0.

**Late mentah (timestamp):** 7.827 dari 96.476 order bertanggal terima (8,11%). `order_estimated_delivery_date` selalu jam 00:00:00 (0 pengecualian), jadi definisi `is_late` final perlu perbandingan tanggal (D1, Tahap 6).

**Durasi purchase → diterima:** median 10,22 hari, P95 29,28, maks 209,63.

**Cakupan waktu (bulan pembelian)**

| Bulan | n_orders | n_delivered | n_in_flight | % in-flight |
|---|---:|---:|---:|---:|
| 2016-09 | 4 | 1 | 1 | 25,00 |
| 2016-10 | 324 | 265 | 28 | 8,64 |
| **2016-11** | **0** | 0 | 0 | — |
| 2016-12 | 1 | 1 | 0 | 0,00 |
| 2017-01 | 800 | 750 | 37 | 4,63 |
| 2017-02 | 1.780 | 1.653 | 65 | 3,65 |
| 2017-03 | 2.682 | 2.546 | 71 | 2,65 |
| 2017-04 | 2.404 | 2.303 | 74 | 3,08 |
| 2017-05 | 3.700 | 3.546 | 94 | 2,54 |
| 2017-06 | 3.245 | 3.135 | 70 | 2,16 |
| 2017-07 | 4.026 | 3.872 | 74 | 1,84 |
| 2017-08 | 4.331 | 4.193 | 79 | 1,82 |
| 2017-09 | 4.285 | 4.150 | 77 | 1,80 |
| 2017-10 | 4.631 | 4.478 | 69 | 1,49 |
| 2017-11 | 7.544 | 7.289 | 134 | 1,78 |
| 2017-12 | 5.673 | 5.513 | 107 | 1,89 |
| 2018-01 | 7.269 | 7.069 | 118 | 1,62 |
| 2018-02 | 6.728 | 6.555 | 70 | 1,04 |
| 2018-03 | 7.211 | 7.003 | 165 | 2,29 |
| 2018-04 | 6.939 | 6.798 | 121 | 1,74 |
| 2018-05 | 6.873 | 6.749 | 84 | 1,22 |
| 2018-06 | 6.167 | 6.099 | 46 | 0,75 |
| 2018-07 | 6.292 | 6.159 | 74 | 1,18 |
| 2018-08 | 6.512 | 6.351 | 70 | 1,07 |
| 2018-09 | 16 | 0 | 1 | 6,25 |
| 2018-10 | 4 | 0 | 0 | 0,00 |

Periode penuh 2017-01 s.d. 2018-08 terkonfirmasi (20 bulan). 2016-09/10/12 tipis, 2016-11 kosong, 2018-09/10 terpotong. Order in-flight pada bulan lama (mis. 2017-01: 4,63%; 2017-02 sampai 2017-04: 2,65–3,65%) kemungkinan status basi, bukan order yang benar-benar masih jalan.

### Customers

| n order per orang | n orang | % |
|---:|---:|---:|
| 1 | 93.099 | 96,88 |
| 2 | 2.745 | 2,86 |
| 3 | 203 | 0,21 |
| 4 | 30 | 0,03 |
| 5 | 8 | 0,01 |
| 6 | 6 | 0,01 |
| 7 | 3 | 0,00 |
| 9 | 1 | 0,00 |
| 17 | 1 | 0,00 |

96.096 orang unik dari 99.441 `customer_id`. Konsistensi lokasi per orang: 250 punya >1 zip, 122 >1 kota, 39 >1 state. Zip 5 karakter semua, 24,13% diawali 0, 39 zip muncul di >1 kota.

### Order items

- 112.650 baris, 98.666 order unik; **775 order tanpa item**: unavailable 603, canceled 164, created 5, invoiced 2, shipped 1.
- Item per order: 1 item 88.863 order (90,06%), 2 item 7.516 (7,62%), maks 21 item. 7.088 pasangan order-produk berulang; 1.278 order multi-seller; 3.236 order multi-produk.
- `price`: min 0,85 · median 74,99 · P95 349,90 · maks 6.735. Outlier IQR 8.427 baris (7,48%).
- `freight_value`: min 0 · median 16,26 · maks 409,68; 383 baris freight = 0.
- 4 baris (3 order) dengan `shipping_limit_date` tahun 2020.

### Order payments

| Tipe | n | % |
|---|---:|---:|
| credit_card | 76.795 | 73,92 |
| boleto | 19.784 | 19,04 |
| voucher | 5.775 | 5,56 |
| debit_card | 1.529 | 1,47 |
| not_defined | 3 | 0,00 |

103.886 baris, 99.440 order (1 order tanpa payment). 2.246 order (2,26%) pakai >1 tipe; 80 order tanpa `payment_sequential = 1`; 9 baris `payment_value = 0`; 2 baris `installments = 0`.

**Rekonsiliasi item+freight vs payment** (98.665 order, Fan-out Guard lolos: selisih agregat vs raw = 0):

| Selisih | n order |
|---|---:|
| ≤ 0,01 | 98.362 |
| 0,01 – 1 | 54 |
| > 1 | 249 |

Selisih maks 182,81. Arah selisih pada 249 order: payment > item+freight **232 order** (total 3.064,76); payment < item+freight **17 order** (total 197,57).

### Order reviews

| Skor | n | % |
|---:|---:|---:|
| 1 | 11.424 | 11,51 |
| 2 | 3.151 | 3,18 |
| 3 | 8.179 | 8,24 |
| 4 | 19.142 | 19,29 |
| 5 | 57.328 | 57,78 |

Rata-rata 4,086 (sebelum dedup). 99.224 baris, 98.673 order unik; **547 order punya >1 review** (202 di antaranya skornya bertentangan); 789 `review_id` muncul di >1 order; 768 order tanpa review; 74 review dibuat sebelum purchase. Komentar kosong: title 88,34%, message 58,70%.

### Products & category translation

- 610 produk (1,85%) tanpa kategori/nama/deskripsi/foto (null bersamaan); 2 produk tanpa berat & dimensi; 4 produk berat = 0.
- 2 kategori tanpa terjemahan: `portateis_cozinha_e_preparadores_de_alimentos` (10 produk), `pc_gamer` (3 produk).
- Typo bawaan di terjemahan: `costruction_tools_garden`, `costruction_tools_tools`, `home_confort`, `fashio_female_clothing`.

### Sellers

- 3.095 seller di 23 state. `seller_city` kotor terdeteksi (aturan heuristik) 23 seller, contoh: `sao paulo - sp` (3 seller), `vendas@creditparts.com.br`, `04482255`, `sbc/sp`, `sp / sp`, `novo hamburgo, rio grande do sul, brasil`.
- 4 state customer tanpa seller: AL (413 customer), AP (68), RR (46), TO (280).

### Geolocation

- 1.000.163 baris; **261.831 (26,18%) duplikat penuh**; 93,5% zip punya >1 pasangan koordinat; 45,0% zip punya >1 kota.
- 42 baris koordinat di luar kotak kasar Brasil.
- Ejaan kota ganda setelah accent-strip, mis. `arapua`/`arapuã`, `santo estevao`/`santo estêvão` (sampai 3 ejaan per kota).
- Customer tanpa zip di geolocation: 278 baris (157 zip); seller: 7 baris.

### Kelengkapan relasi (order tanpa child)

| Relasi | n |
|---|---:|
| order tanpa item | 775 |
| order tanpa payment | 1 |
| order tanpa review | 768 |

Payment tanpa item: 775 order senilai R$ 162.591,95.

### Metrik CHECK (5)

| Section | Metrik | Aktual | Ekspektasi |
|---|---|---:|---:|
| order_payments | recon_diff_le_001 | 98.362 | 98.285 |
| order_payments | recon_diff_001_1 | 54 | 131 |
| order_payments | recon_le_001_pct | 99,693 | 99,615 |
| order_reviews | message_whitespace_only | 9 | 27 |
| sellers | dirty_seller_city (heuristik) | 23 | 34 |

**Penjelasan (hipotesis; belum diverifikasi lewat query):**

1. **Rekonsiliasi (3 metrik).** Total tidak berubah: 98.362 + 54 = 98.285 + 131 = 98.416, dan bucket > 1 identik (249). Berarti 77 order berpindah antara bucket ≤0,01 dan 0,01–1. Script ini memakai `ROUND(ABS(selisih), 2)`, sedangkan angka roadmap kemungkinan memakai selisih floating-point tanpa pembulatan, sehingga selisih tepat 1 sen (mis. 0,0100000000002) terhitung > 0,01. Karena harga dan payment berpresisi 2 desimal, angka di script ini kemungkinan yang benar secara eksak.
2. **`message_whitespace_only`.** `TRIM()` DuckDB hanya membuang spasi, bukan newline/tab. Komentar yang hanya berisi `\n`, `\r`, atau tab tidak terhitung, jadi 9 kemungkinan undercount dan 27 di roadmap kemungkinan memakai pola `\s`. Catatan yang sama berlaku untuk kolom `n_blank` di null profile.
3. **`dirty_seller_city`.** Aturan deteksi saya (angka, `@`, `/`, `,`, atau ` - `) lebih sempit dari yang dipakai roadmap. Semua contoh roadmap tertangkap, tapi 11 seller lain belum teridentifikasi.

Selisih median (10,22 vs 10,21) dan P95 (29,28 vs 29,29) masih dalam toleransi 0,011 (beda interpolasi/pembulatan), status PASS.

### Query verifikasi opsional (belum dijalankan)

```sql
-- (1) apakah 77 order itu memang selisih tepat 1 sen yang tergeser floating point?
SELECT COUNT(*) FROM (
  SELECT ABS(i.t - p.t) AS d
  FROM (SELECT order_id, SUM(price+freight) t FROM p_items GROUP BY 1) i
  JOIN (SELECT order_id, SUM(pay_value) t FROM p_pay GROUP BY 1) p USING (order_id))
WHERE d > 0.01 AND d < 0.0101;              -- diharapkan 77

-- (2) whitespace-only dengan pola \s
SELECT COUNT(*) FROM raw_order_reviews
WHERE review_comment_message IS NOT NULL AND regexp_matches(review_comment_message, '^\s*$');  -- diharapkan 27
```

## Output
- Tabel: `prof_null_summary`, `prof_monthly`, `prof_category_dist`, `prof_findings`, `prof_summary` di `data/olist.duckdb`
- `data/processed/03_profiling_summary.parquet` (275 baris; ter-ignore git)

## Assumptions
- Null = nilai kosong pada CSV; `n_blank` hanya menangkap string yang habis setelah `TRIM` (spasi saja).
- Late mentah memakai perbandingan timestamp; definisi final `is_late` ditetapkan di Tahap 6 (D1).
- Outlier harga memakai 1,5 × IQR pada seluruh baris item.
- Ekspektasi diambil dari angka di roadmap, bukan dibaca langsung dari `olist_profiling.md`.

## Batasan data
- Profiling tidak mengubah data; semua anomali hanya dicatat untuk Tahap 5.
- Metrik heuristik (kota seller kotor, kotak koordinat Brasil) sensitif terhadap aturan deteksi. Kotak koordinat cocok 42/42; kota seller belum.
- Hipotesis penyebab CHECK belum diverifikasi.

## Kesimpulan
Profiling menutup semua kategori anomali dengan angka pasti: null, duplikat, kunci, format, outlier, urutan tanggal, relasi antar tabel, dan gap waktu. 124 dari 129 metrik cocok dengan roadmap; 5 sisanya berasal dari definisi pembulatan (rekonsiliasi), fungsi `TRIM` (whitespace), dan aturan heuristik (kota seller), bukan dari perbedaan data.

**Untuk Tahap 5–6:**
- Cast `price`, `freight_value`, `payment_value` ke `DECIMAL(12,2)` di `stg_*` supaya rekonsiliasi eksak, lalu perbarui angka A4/D9 di roadmap jika hipotesis (1) terbukti (98.362 / 54 / 249).
- Deteksi whitespace pakai `regexp_matches(..., '^\s*$')`.
- `seller_city` dirapikan dengan tabel mapping eksplisit, bukan aturan regex.
- Perlakukan order in-flight di bulan lama sebagai status basi (sensitivity delivered-only sudah ada di D2).
