# Olist Brazilian E-commerce Analytics

Proyek data analytics end-to-end (SQL + DuckDB + Power BI) di atas dataset **Olist Brazilian E-Commerce**:
9 tabel relasional, fokus pada delivery/logistics, customer satisfaction, seller performance, dan customer repeat (deskriptif).

> 🚧 **Status:** Tahap 0 — project skeleton. Progress lengkap ada di Traceability Matrix pada roadmap.

## Headline Findings (preliminary)

> ⚠️ *Preliminary — diverifikasi ulang di Tahap 9–17, final di Tahap 21.* Bahasa asosiasi, bukan kausal.

1. **Timing jawaban review (A9/D4):** skor order yang telat sangat bergantung pada timing jawaban review (rata-rata 1,652 vs 3,72).
2. **Estimasi Olist konservatif (A20):** order yang on-time rata-rata tiba 13,51 hari lebih cepat dari estimasi.
3. **Keterlambatan dominan di sisi kurir (A21):** transit kurir ~3,5x vs handover seller ~2x.
4. **Konsentrasi seller (A18/D11):** 210 seller Top-tier = 51,48% revenue.

## Struktur Repository

```
data/raw/        CSV mentah dari Kaggle (tidak di-commit)
data/processed/  output antara (parquet besar tidak di-commit)
data/data_mart/  parquet mart untuk dashboard (di-commit)
sql/             02_*.sql – 18_*.sql (flat, tanpa subfolder)
docs/            dokumen .md pendamping tiap file SQL + dokumentasi final
dashboard/       olist_ecommerce.pbix (di-commit)
screenshots/     screenshot tiap halaman dashboard
notebooks/       kpi_crosscheck.ipynb (Reconciliation Automated Gate, Tahap 19)
```

## Cara Reproduce

1. Download 9 CSV dari Kaggle: *Brazilian E-Commerce Public Dataset by Olist* → taruh di `data/raw/`.
2. Buka DuckDB: `duckdb olist.duckdb`
3. Jalankan berurutan: `.read sql/02_data_collection.sql`, lalu `03_…` dst. sampai `18_parquet_export.sql`.
4. Jalankan `notebooks/kpi_crosscheck.ipynb` — seluruh 6 KPI harus **PASS** sebelum membuka `.pbix`.

## Atribusi Dataset

Dataset: Olist Brazilian E-Commerce Public Dataset (Kaggle). Cek lisensi & ketentuan di halaman dataset Kaggle
dan cantumkan di sini sebelum publish.

## Batas Scope

Tidak ada analisis profit/margin, CLV/RFM, funnel/CAC, atau sentiment analysis teks review.
