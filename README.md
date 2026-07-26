# HP Printer Image Fetcher

Upload an Excel list of HP printer product numbers and retrieve product images using HP APIs.

## Features

- Upload `.xlsx` files with a product list
- Paste product numbers manually in the UI
- Retrieve images via:
  1. **HP Catalog Service API (Hermes)** — official partner API for product images
  2. **HP Shop fallback** — scrapes HP Shop search/product pages for `ssl-product-images` URLs
- Product lookup/validation via **HP PartSurfer BFF API**
- Gallery UI to preview and open retrieved images

## Quick start

```bash
cd hp_printer_images
python3 -m pip install -r requirements.txt
python3 create_sample_excel.py
cp .env.example .env
python3 -m uvicorn backend.main:app --reload --port 8000
```

Open [http://localhost:8000](http://localhost:8000)

## Excel format

| Product Number | Notes |
|---|---|
| 2Z599F | LaserJet Pro 4001n |
| W1A52A | LaserJet Pro M404n |

Supported column headers: `Product Number`, `SKU`, `Part Number`, `Model`, `Device`, `Printer`.

If no header row is detected, the first column is treated as product numbers.

## HP Catalog Service API setup (recommended)

HP's official product image API requires partner registration:

1. Register at [HP Catalog Service API](https://syndication.inc.hp.com/content/serviceAPI/us/en/index.html)
2. Complete SSL certificate registration and IP whitelisting
3. Add credentials to `.env`:

```env
HP_CATALOG_REQUESTER_ID=your_partner_id
HP_CATALOG_CLIENT_CERT=/path/to/cert.pem
HP_CATALOG_CLIENT_KEY=/path/to/key.pem
```

Without credentials, the app falls back to HP Shop search scraping.

## API endpoints

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/health` | Service health and config status |
| `POST` | `/api/upload-excel` | Upload Excel and fetch images |
| `POST` | `/api/fetch-images` | Fetch images for a JSON product list |
| `POST` | `/api/fetch-image` | Fetch image for a single product |

## Project structure

```
hp_printer_images/
├── backend/
│   ├── main.py              # FastAPI app
│   ├── excel_parser.py      # Excel upload parsing
│   ├── hp_catalog.py        # HP Catalog Service API client
│   ├── hp_shop.py           # HP Shop fallback scraper
│   ├── hp_partsurfer.py     # PartSurfer product lookup
│   └── image_service.py     # Orchestration layer
├── frontend/
│   ├── index.html
│   ├── styles.css
│   └── app.js
├── sample_products.xlsx
└── requirements.txt
```
