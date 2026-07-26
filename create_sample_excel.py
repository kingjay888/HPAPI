#!/usr/bin/env python3
"""Create a sample Excel file for testing."""

from pathlib import Path

from openpyxl import Workbook

SAMPLE_PRODUCTS = [
    "2Z599F",
    "W1A52A",
    "W1A53A",
    "LaserJet Pro 4001n",
]

output = Path(__file__).resolve().parent / "sample_products.xlsx"
workbook = Workbook()
sheet = workbook.active
sheet.title = "Products"
sheet.append(["Product Number", "Notes"])
for product in SAMPLE_PRODUCTS:
    sheet.append([product, "HP printer"])
workbook.save(output)
print(f"Created {output}")
