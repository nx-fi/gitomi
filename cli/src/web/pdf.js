(function () {
  "use strict";

  const pdfjsModuleUrl = "/vendor/pdfjs/build/pdf.mjs";
  const pdfjsWorkerUrl = "/vendor/pdfjs/build/pdf.worker.mjs";
  const defaultLimits = Object.freeze({
    maxPages: 20,
    maxCanvasPixels: 4000000,
    maxTotalPixels: 40000000,
    maxCssWidth: 1200,
    maxCssHeight: 1800,
    minRemainingPixels: 250000,
  });
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

  function readLimit(root, key, fallback, min, max) {
    const value = Number(root.dataset[key]);
    if (!Number.isFinite(value)) return fallback;
    return Math.max(min, Math.min(max, Math.floor(value)));
  }

  function limitsFor(root) {
    return {
      maxPages: readLimit(root, "pdfMaxPages", defaultLimits.maxPages, 1, defaultLimits.maxPages),
      maxCanvasPixels: readLimit(root, "pdfMaxCanvasPixels", defaultLimits.maxCanvasPixels, 250000, defaultLimits.maxCanvasPixels),
      maxTotalPixels: readLimit(root, "pdfMaxTotalPixels", defaultLimits.maxTotalPixels, 250000, defaultLimits.maxTotalPixels),
      maxCssWidth: readLimit(root, "pdfMaxCssWidth", defaultLimits.maxCssWidth, 320, defaultLimits.maxCssWidth),
      maxCssHeight: readLimit(root, "pdfMaxCssHeight", defaultLimits.maxCssHeight, 320, defaultLimits.maxCssHeight),
    };
  }

  function addNotice(root, message) {
    const notice = document.createElement("div");
    notice.className = "pdf-preview-notice";
    notice.textContent = message;
    const pages = root.querySelector("[data-pdf-pages]");
    if (pages) root.insertBefore(notice, pages);
    else root.appendChild(notice);
  }

  function assertSafeViewport(viewport) {
    if (
      !viewport ||
      !Number.isFinite(viewport.width) ||
      !Number.isFinite(viewport.height) ||
      viewport.width <= 0 ||
      viewport.height <= 0
    ) {
      throw new Error("PDF page dimensions are invalid.");
    }
  }

  function planPageRender(root, pages, page, limits, state) {
    const baseViewport = page.getViewport({ scale: 1 });
    assertSafeViewport(baseViewport);

    const containerWidth = pages.clientWidth || root.clientWidth || 760;
    const targetWidth = Math.max(320, Math.min(limits.maxCssWidth, containerWidth - 36));
    const scale = Math.min(2.25, targetWidth / baseViewport.width, limits.maxCssHeight / baseViewport.height);
    if (!Number.isFinite(scale) || scale <= 0) {
      throw new Error("PDF page dimensions are too large to preview safely.");
    }

    const viewport = page.getViewport({ scale: scale });
    assertSafeViewport(viewport);

    const cssWidth = Math.max(1, Math.ceil(viewport.width));
    const cssHeight = Math.max(1, Math.ceil(viewport.height));
    if (cssWidth > limits.maxCssWidth + 1 || cssHeight > limits.maxCssHeight + 1) {
      throw new Error("PDF page dimensions are too large to preview safely.");
    }

    const remainingPixels = limits.maxTotalPixels - state.renderedPixels;
    const pixelBudget = Math.min(limits.maxCanvasPixels, remainingPixels);
    if (pixelBudget < defaultLimits.minRemainingPixels) return null;

    const cssPixels = Math.max(1, cssWidth * cssHeight);
    const deviceScale = Math.max(1, Math.min(2, Number(window.devicePixelRatio) || 1));
    const budgetScale = Math.sqrt(pixelBudget / cssPixels);
    const outputScale = Math.min(deviceScale, budgetScale);
    if (!Number.isFinite(outputScale) || outputScale <= 0) return null;

    const canvasWidth = Math.max(1, Math.floor(cssWidth * outputScale));
    const canvasHeight = Math.max(1, Math.floor(cssHeight * outputScale));
    const pixelCount = canvasWidth * canvasHeight;
    if (pixelCount <= 0 || pixelCount > pixelBudget) return null;

    return {
      viewport: viewport,
      outputScale: outputScale,
      cssWidth: cssWidth,
      cssHeight: cssHeight,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      pixelCount: pixelCount,
    };
  }

  function nextFrame() {
    return new Promise(function (resolve) {
      if (typeof window.requestAnimationFrame === "function") {
        window.requestAnimationFrame(resolve);
      } else {
        window.setTimeout(resolve, 0);
      }
    });
  }

  async function renderPage(root, pages, pdf, pageNumber, limits, state) {
    const page = await pdf.getPage(pageNumber);
    const renderPlan = planPageRender(root, pages, page, limits, state);
    if (!renderPlan) return false;

    const pageShell = document.createElement("section");
    pageShell.className = "pdf-page";
    pageShell.setAttribute("aria-label", "Page " + pageNumber);

    const canvas = document.createElement("canvas");
    canvas.width = renderPlan.canvasWidth;
    canvas.height = renderPlan.canvasHeight;
    canvas.style.width = renderPlan.cssWidth + "px";
    canvas.style.height = renderPlan.cssHeight + "px";

    const label = document.createElement("div");
    label.className = "pdf-page-label";
    label.textContent = "Page " + pageNumber;

    pageShell.appendChild(canvas);
    pageShell.appendChild(label);
    pages.appendChild(pageShell);

    const context = canvas.getContext("2d", { alpha: false });
    if (!context) throw new Error("Canvas rendering is unavailable.");
    context.setTransform(renderPlan.outputScale, 0, 0, renderPlan.outputScale, 0, 0);
    state.renderedPixels += renderPlan.pixelCount;
    await page.render({ canvasContext: context, viewport: renderPlan.viewport }).promise;
    return true;
  }

  async function renderPdf(root) {
    const url = root.dataset.pdfUrl;
    if (!url) return;

    const pages = root.querySelector("[data-pdf-pages]");
    if (!pages) return;

    try {
      const limits = limitsFor(root);
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
      const renderCount = Math.min(pageCount, limits.maxPages);
      const state = { renderedPixels: 0 };
      let renderedPages = 0;

      setStatus(root, renderCount === 1 ? "Rendering 1 page..." : "Rendering " + renderCount + " pages...");
      for (let pageNumber = 1; pageNumber <= renderCount; pageNumber += 1) {
        setStatus(root, "Rendering page " + pageNumber + " of " + pageCount + "...");
        const rendered = await renderPage(root, pages, pdf, pageNumber, limits, state);
        if (!rendered) break;
        renderedPages += 1;
        await nextFrame();
      }

      if (renderedPages < pageCount) {
        if (renderedPages === 0) {
          addNotice(root, "No pages were rendered. This PDF exceeds the preview rendering budget.");
          setStatus(root, "Preview not rendered");
        } else {
          addNotice(root, "Rendered first " + renderedPages + " of " + pageCount + " pages. The preview is capped to protect browser memory.");
          setStatus(root, "Rendered " + renderedPages + " of " + pageCount + " pages");
        }
      } else {
        setStatus(root, pageCount === 1 ? "1 page" : pageCount + " pages");
      }
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
