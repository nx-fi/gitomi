(function () {
  "use strict";

  const pdfjsModuleUrl = "/vendor/pdfjs/build/pdf.mjs";
  const pdfjsWorkerUrl = "/vendor/pdfjs/build/pdf.worker.mjs";
  let pdfjsPromise = null;

  function ensurePdfjs() {
    if (!pdfjsPromise) {
      pdfjsPromise = import(pdfjsModuleUrl).then(function (pdfjs) {
        pdfjs.GlobalWorkerOptions.workerSrc = pdfjsWorkerUrl;
        return pdfjs;
      });
    }
    return pdfjsPromise;
  }

  function setStatus(root, message) {
    const status = root.querySelector("[data-pdf-status]");
    if (status) status.textContent = message;
  }

  function showError(root, message) {
    root.classList.add("failed");
    setStatus(root, message);
  }

  async function renderPage(root, pages, pdf, pageNumber) {
    const page = await pdf.getPage(pageNumber);
    const baseViewport = page.getViewport({ scale: 1 });
    const width = Math.max(320, (pages.clientWidth || root.clientWidth || 760) - 36);
    const scale = Math.max(0.35, Math.min(2.25, width / baseViewport.width));
    const viewport = page.getViewport({ scale: scale });
    const outputScale = Math.max(1, Math.min(2, window.devicePixelRatio || 1));

    const pageShell = document.createElement("section");
    pageShell.className = "pdf-page";
    pageShell.setAttribute("aria-label", "Page " + pageNumber);

    const canvas = document.createElement("canvas");
    canvas.width = Math.floor(viewport.width * outputScale);
    canvas.height = Math.floor(viewport.height * outputScale);
    canvas.style.width = Math.floor(viewport.width) + "px";
    canvas.style.height = Math.floor(viewport.height) + "px";

    const label = document.createElement("div");
    label.className = "pdf-page-label";
    label.textContent = "Page " + pageNumber;

    pageShell.appendChild(canvas);
    pageShell.appendChild(label);
    pages.appendChild(pageShell);

    const context = canvas.getContext("2d", { alpha: false });
    context.setTransform(outputScale, 0, 0, outputScale, 0, 0);
    await page.render({ canvasContext: context, viewport: viewport }).promise;
  }

  async function renderPdf(root) {
    const url = root.dataset.pdfUrl;
    if (!url) return;

    const pages = root.querySelector("[data-pdf-pages]");
    if (!pages) return;

    try {
      const pdfjs = await ensurePdfjs();
      setStatus(root, "Loading PDF...");
      const loadingTask = pdfjs.getDocument({ url: url });
      const pdf = await loadingTask.promise;
      const pageCount = pdf.numPages || 0;
      if (pageCount === 0) {
        showError(root, "PDF has no pages.");
        return;
      }

      root.dataset.pdfReady = "yes";
      setStatus(root, pageCount === 1 ? "Rendering 1 page..." : "Rendering " + pageCount + " pages...");
      for (let pageNumber = 1; pageNumber <= pageCount; pageNumber += 1) {
        setStatus(root, "Rendering page " + pageNumber + " of " + pageCount + "...");
        await renderPage(root, pages, pdf, pageNumber);
      }
      setStatus(root, pageCount === 1 ? "1 page" : pageCount + " pages");
    } catch (error) {
      const message = error && error.message ? error.message : "Could not render PDF preview.";
      showError(root, message);
    }
  }

  function initPdfPreviews() {
    document.querySelectorAll("[data-pdf-preview]").forEach(function (root) {
      if (root.dataset.pdfPreviewReady === "yes") return;
      root.dataset.pdfPreviewReady = "yes";
      renderPdf(root);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initPdfPreviews);
  } else {
    initPdfPreviews();
  }
}());
