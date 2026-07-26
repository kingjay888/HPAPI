const excelInput = document.getElementById("excelInput");
const dropzone = document.getElementById("dropzone");
const selectedFile = document.getElementById("selectedFile");
const manualProducts = document.getElementById("manualProducts");
const fetchBtn = document.getElementById("fetchBtn");
const clearBtn = document.getElementById("clearBtn");
const progress = document.getElementById("progress");
const resultsGrid = document.getElementById("resultsGrid");
const summary = document.getElementById("summary");
const apiStatus = document.getElementById("apiStatus");
const resultCardTemplate = document.getElementById("resultCardTemplate");

let selectedExcelFile = null;

async function checkHealth() {
  try {
    const response = await fetch("/api/health");
    const data = await response.json();
    if (data.catalog_api_configured) {
      apiStatus.textContent = "HP Catalog API configured";
      apiStatus.classList.add("ok");
    } else {
      apiStatus.textContent = "Using HP Shop fallback (Catalog API not configured)";
      apiStatus.classList.add("warn");
    }
  } catch (error) {
    apiStatus.textContent = "API unavailable";
    apiStatus.classList.add("warn");
  }
}

function setLoading(isLoading) {
  fetchBtn.disabled = isLoading;
  progress.classList.toggle("hidden", !isLoading);
}

function parseManualProducts() {
  return manualProducts.value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function renderResults(payload) {
  const results = payload.results || [];
  resultsGrid.innerHTML = "";

  if (!results.length) {
    resultsGrid.innerHTML = '<div class="empty-state">No results to display.</div>';
    summary.textContent = "No results.";
    return;
  }

  summary.textContent = `${payload.found || 0} of ${payload.total || results.length} products returned images.`;

  for (const item of results) {
    const card = resultCardTemplate.content.cloneNode(true);
    const title = card.querySelector(".product-title");
    const number = card.querySelector(".product-number");
    const source = card.querySelector(".product-source");
    const gallery = card.querySelector(".image-gallery");
    const error = card.querySelector(".result-error");

    title.textContent = item.product_name || item.input;
    number.textContent = `Product: ${item.product_number || item.input}`;
    source.textContent = item.source ? `Source: ${item.source}` : "Source: not found";

    if (item.found && item.images?.length) {
      for (const image of item.images) {
        const imageCard = document.createElement("div");
        imageCard.className = "image-card";
        imageCard.innerHTML = `
          <img src="${image.url}" alt="${image.label || "Product image"}" loading="lazy" />
          <a href="${image.url}" target="_blank" rel="noopener noreferrer">Open image</a>
        `;
        gallery.appendChild(imageCard);
      }
    } else {
      error.textContent = item.message || (item.errors || []).join(" ") || "No image found for this product.";
      error.classList.remove("hidden");
    }

    resultsGrid.appendChild(card);
  }
}

async function fetchFromExcel(file) {
  const formData = new FormData();
  formData.append("file", file);

  const response = await fetch("/api/upload-excel", {
    method: "POST",
    body: formData,
  });

  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.detail || "Upload failed.");
  }
  return data;
}

async function fetchFromProducts(products) {
  const response = await fetch("/api/fetch-images", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ products }),
  });

  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.detail || "Fetch failed.");
  }
  return data;
}

async function handleFetch() {
  const manualList = parseManualProducts();

  if (!selectedExcelFile && !manualList.length) {
    summary.textContent = "Select an Excel file or enter product numbers.";
    return;
  }

  setLoading(true);
  summary.textContent = "Fetching images from HP...";

  try {
    const payload = selectedExcelFile
      ? await fetchFromExcel(selectedExcelFile)
      : await fetchFromProducts(manualList);
    renderResults(payload);
  } catch (error) {
    summary.textContent = error.message;
    resultsGrid.innerHTML = `<div class="empty-state">${error.message}</div>`;
  } finally {
    setLoading(false);
  }
}

function handleFile(file) {
  if (!file) return;
  selectedExcelFile = file;
  selectedFile.textContent = file.name;
}

dropzone.addEventListener("dragover", (event) => {
  event.preventDefault();
  dropzone.classList.add("dragover");
});

dropzone.addEventListener("dragleave", () => {
  dropzone.classList.remove("dragover");
});

dropzone.addEventListener("drop", (event) => {
  event.preventDefault();
  dropzone.classList.remove("dragover");
  const file = event.dataTransfer.files?.[0];
  handleFile(file);
});

excelInput.addEventListener("change", (event) => {
  handleFile(event.target.files?.[0]);
});

fetchBtn.addEventListener("click", handleFetch);

clearBtn.addEventListener("click", () => {
  selectedExcelFile = null;
  excelInput.value = "";
  manualProducts.value = "";
  selectedFile.textContent = "No file selected";
  resultsGrid.innerHTML = "";
  summary.textContent = "Upload a file or enter product numbers to begin.";
});

checkHealth();
