(function () {
  "use strict";

  const storageKey = "gitomi.diffScrollAnchor";

  function viewportTop() {
    const topbar = document.querySelector(".topbar");
    const top = topbar ? topbar.getBoundingClientRect().bottom : 0;
    return Math.max(0, Math.min(window.innerHeight, top));
  }

  function locationKey(url) {
    return url.pathname + url.search;
  }

  function visibleRows(file) {
    const top = viewportTop();
    return Array.from(file.querySelectorAll("[data-diff-row]")).filter((row) => {
      if (row.classList.contains("diff-expand")) return false;
      if (!row.dataset.diffOld && !row.dataset.diffNew) return false;
      const rect = row.getBoundingClientRect();
      return rect.bottom >= top && rect.top <= window.innerHeight;
    });
  }

  function bestVisibleRow(file) {
    const top = viewportTop();
    let best = null;
    let bestDistance = Infinity;
    for (const row of visibleRows(file)) {
      const rect = row.getBoundingClientRect();
      const distance = Math.abs(rect.top - top);
      if (distance < bestDistance) {
        best = row;
        bestDistance = distance;
      }
    }
    return best;
  }

  function nearbyRow(row, direction) {
    let next = row;
    while (next) {
      next = direction < 0 ? next.previousElementSibling : next.nextElementSibling;
      if (!next || !next.matches("[data-diff-row]")) continue;
      if (next.classList.contains("diff-expand")) continue;
      if (next.dataset.diffOld || next.dataset.diffNew) return next;
    }
    return null;
  }

  function anchorRowForClick(link) {
    const file = link.closest("[data-diff-file]");
    if (!file) return null;

    const visible = bestVisibleRow(file);
    if (visible) return visible;

    const expand = link.closest("[data-diff-row]");
    return expand ? nearbyRow(expand, -1) || nearbyRow(expand, 1) : null;
  }

  function rowAnchor(row) {
    const file = row.closest("[data-diff-file]");
    if (!file) return null;

    const rect = row.getBoundingClientRect();
    return {
      fileIndex: file.dataset.diffFileIndex || "",
      filePath: file.dataset.diffFilePath || "",
      oldLine: row.dataset.diffOld || "",
      newLine: row.dataset.diffNew || "",
      kind: row.dataset.diffKind || "",
      offset: rect.top - viewportTop(),
    };
  }

  function storeAnchor(link) {
    const row = anchorRowForClick(link);
    if (!row) return;

    const target = new URL(link.getAttribute("href"), window.location.href);
    target.hash = "";

    const anchor = rowAnchor(row);
    if (!anchor) return;
    anchor.url = locationKey(target);

    try {
      window.sessionStorage.setItem(storageKey, JSON.stringify(anchor));
    } catch (_) {}
  }

  function findFile(anchor) {
    const files = Array.from(document.querySelectorAll("[data-diff-file]"));
    return files.find((file) => file.dataset.diffFileIndex === anchor.fileIndex) ||
      files.find((file) => file.dataset.diffFilePath === anchor.filePath) ||
      null;
  }

  function sameRow(row, anchor) {
    if (row.dataset.diffKind !== anchor.kind) return false;
    if (anchor.oldLine && row.dataset.diffOld !== anchor.oldLine) return false;
    if (anchor.newLine && row.dataset.diffNew !== anchor.newLine) return false;
    return Boolean(anchor.oldLine || anchor.newLine);
  }

  function lineNumber(value) {
    const parsed = Number.parseInt(value || "", 10);
    return Number.isFinite(parsed) ? parsed : null;
  }

  function nearestRow(file, anchor) {
    const wantedNew = lineNumber(anchor.newLine);
    const wantedOld = lineNumber(anchor.oldLine);
    let best = null;
    let bestDistance = Infinity;

    for (const row of file.querySelectorAll("[data-diff-row]")) {
      if (row.classList.contains("diff-expand")) continue;
      const rowNew = lineNumber(row.dataset.diffNew);
      const rowOld = lineNumber(row.dataset.diffOld);
      const distance = wantedNew != null && rowNew != null
        ? Math.abs(rowNew - wantedNew)
        : wantedOld != null && rowOld != null
          ? Math.abs(rowOld - wantedOld)
          : Infinity;
      if (distance < bestDistance) {
        best = row;
        bestDistance = distance;
      }
    }

    return best;
  }

  function findRow(file, anchor) {
    return Array.from(file.querySelectorAll("[data-diff-row]")).find((row) => sameRow(row, anchor)) ||
      nearestRow(file, anchor) ||
      file;
  }

  function restoreAnchor() {
    let anchor = null;
    try {
      const raw = window.sessionStorage.getItem(storageKey);
      if (!raw) return;
      window.sessionStorage.removeItem(storageKey);
      anchor = JSON.parse(raw);
    } catch (_) {
      return;
    }

    if (!anchor || anchor.url !== locationKey(window.location)) return;

    const file = findFile(anchor);
    if (!file) return;
    const target = findRow(file, anchor);

    window.requestAnimationFrame(() => {
      const top = window.scrollY + target.getBoundingClientRect().top - viewportTop() - (anchor.offset || 0);
      window.scrollTo({ top: Math.max(0, top), left: window.scrollX, behavior: "auto" });
    });
  }

  function initDiffAnchors() {
    document.addEventListener("click", (event) => {
      const link = event.target.closest("[data-diff-expand]");
      if (!link) return;
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      storeAnchor(link);
    });
    restoreAnchor();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initDiffAnchors);
  } else {
    initDiffAnchors();
  }
})();
