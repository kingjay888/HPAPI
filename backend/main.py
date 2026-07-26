from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .config import settings
from .excel_parser import parse_product_list
from .image_service import fetch_many_products, fetch_product_images

ROOT_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = ROOT_DIR / "frontend"

app = FastAPI(
    title="HP Printer Image Fetcher",
    description="Upload an Excel product list and retrieve HP printer product images.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ProductRequest(BaseModel):
    products: list[str] = Field(..., min_length=1)


class SingleProductRequest(BaseModel):
    product: str = Field(..., min_length=1)


@app.get("/api/health")
async def health() -> dict:
    return {
        "status": "ok",
        "catalog_api_configured": settings.catalog_configured,
        "country": settings.hp_country_code,
    }


@app.post("/api/fetch-images")
async def fetch_images(payload: ProductRequest) -> dict:
    products = [item.strip() for item in payload.products if item.strip()]
    if not products:
        raise HTTPException(status_code=400, detail="No valid product numbers provided.")

    results = await fetch_many_products(products)
    return {
        "total": len(results),
        "found": sum(1 for item in results if item.get("found")),
        "results": results,
    }


@app.post("/api/fetch-image")
async def fetch_single_image(payload: SingleProductRequest) -> dict:
    import httpx

    timeout = httpx.Timeout(settings.request_timeout_seconds)
    async with httpx.AsyncClient(timeout=timeout) as client:
        return await fetch_product_images(client, payload.product.strip())


@app.post("/api/upload-excel")
async def upload_excel(file: UploadFile = File(...)) -> dict:
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded.")

    # openpyxl only supports xlsx; reject other extensions early.
    if not file.filename.lower().endswith((".xlsx", ".xlsm")):
        raise HTTPException(
            status_code=400,
            detail="Please upload an Excel file (.xlsx).",
        )

    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(status_code=400, detail="Uploaded file is empty.")

    try:
        products = parse_product_list(file_bytes)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not read Excel file: {exc}") from exc

    if not products:
        raise HTTPException(
            status_code=400,
            detail=(
                "No product numbers found. Add a column named 'Product Number' "
                "or place product numbers in the first column."
            ),
        )

    results = await fetch_many_products(products)
    return {
        "filename": file.filename,
        "products_parsed": len(products),
        "total": len(results),
        "found": sum(1 for item in results if item.get("found")),
        "results": results,
    }


if FRONTEND_DIR.exists():
    app.mount("/assets", StaticFiles(directory=FRONTEND_DIR), name="assets")

    @app.get("/")
    async def index() -> FileResponse:
        return FileResponse(FRONTEND_DIR / "index.html")
