# KitaBisa Donor Scraper

Scraper untuk mengambil data donatur dari campaign KitaBisa.com menggunakan Selenium.

## Data yang Diambil

**Per Donatur:**
- Nama donatur
- Jumlah donasi
- Waktu donasi

**Metadata Campaign:**
- N (Total donatur)
- Durasi campaign
- Target dana

## Instalasi

```bash
uv sync
```

## Cara Menjalankan

```bash
# Default campaign (masjidkemasjid)
uv run python main.py

# Campaign tertentu
uv run python main.py <campaign_slug>
```

**Contoh:**
```bash
uv run python main.py banaborong
```

## Output

File disimpan di folder `<campaign_slug>/`:
- `donors_<timestamp>.csv`
- `donors_<timestamp>.json`
