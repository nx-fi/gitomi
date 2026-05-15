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

  let activeRange = null;
  let rangeButton = null;
  let activeForm = null;

  function diffReviewRoot(element) {
    return element ? element.closest("[data-diff-review-action]") : null;
  }

  function lineForSide(row, side) {
    return side === "old" ? (row.dataset.diffOld || "") : (row.dataset.diffNew || "");
  }

  function lineNumberTarget(target) {
    const num = target && target.closest ? target.closest(".diff-num.old, .diff-num.new") : null;
    if (!num) return null;
    const root = diffReviewRoot(num);
    if (!root) return null;
    const row = num.closest("[data-diff-row]");
    if (!row || row.classList.contains("diff-expand")) return null;
    if (row.dataset.diffKind === "hunk" || row.dataset.diffKind === "meta") return null;
    const side = num.classList.contains("old") ? "old" : "new";
    if (!lineForSide(row, side)) return null;
    return num;
  }

  function diffLineRows(file) {
    return Array.from(file.querySelectorAll("[data-diff-row]")).filter((row) => {
      if (row.classList.contains("diff-expand")) return false;
      if (row.dataset.diffKind === "hunk" || row.dataset.diffKind === "meta") return false;
      return Boolean(row.dataset.diffOld || row.dataset.diffNew);
    });
  }

  function rangeRows(range) {
    const rows = diffLineRows(range.file);
    const anchorIndex = rows.indexOf(range.anchorRow);
    const focusIndex = rows.indexOf(range.focusRow);
    if (anchorIndex < 0 || focusIndex < 0) return null;
    const first = Math.min(anchorIndex, focusIndex);
    const last = Math.max(anchorIndex, focusIndex);
    const selected = rows.slice(first, last + 1);
    const numbered = selected.filter((row) => lineForSide(row, range.side));
    if (!numbered.length) return null;
    return {
      rows: selected,
      numberedRows: numbered,
      startRow: numbered[0],
      endRow: numbered[numbered.length - 1],
    };
  }

  function selectedRangeInfo(range) {
    const rowInfo = rangeRows(range);
    if (!rowInfo) return null;
    const startLine = lineNumber(lineForSide(rowInfo.startRow, range.side));
    const endLine = lineNumber(lineForSide(rowInfo.endRow, range.side));
    if (startLine == null || endLine == null) return null;
    return {
      root: range.root,
      file: range.file,
      filePath: range.file.dataset.diffFilePath || "Patch",
      side: range.side,
      rows: rowInfo.rows,
      numberedRows: rowInfo.numberedRows,
      startRow: rowInfo.startRow,
      endRow: rowInfo.endRow,
      startLine: Math.min(startLine, endLine),
      endLine: Math.max(startLine, endLine),
    };
  }

  function clearRangeClasses() {
    document.querySelectorAll(".diff-row.is-range-selected, .diff-row.is-range-boundary").forEach((row) => {
      row.classList.remove("is-range-selected", "is-range-boundary", "is-range-side-old", "is-range-side-new");
    });
    document.querySelectorAll(".diff-num.is-range-selected").forEach((num) => {
      num.classList.remove("is-range-selected");
    });
  }

  function removeRangeButton() {
    if (rangeButton) {
      rangeButton.remove();
      rangeButton = null;
    }
  }

  function removeActiveForm() {
    if (activeForm) {
      activeForm.remove();
      activeForm = null;
    }
  }

  function clearActiveRange(options) {
    clearRangeClasses();
    removeRangeButton();
    activeRange = null;
    if (!options || !options.keepForm) removeActiveForm();
  }

  function applyRangeSelection() {
    clearRangeClasses();
    const info = activeRange ? selectedRangeInfo(activeRange) : null;
    if (!info) {
      removeRangeButton();
      return;
    }
    for (const row of info.rows) {
      row.classList.add("is-range-selected", "is-range-side-" + info.side);
      const num = row.querySelector(".diff-num." + info.side);
      if (num && lineForSide(row, info.side)) num.classList.add("is-range-selected");
    }
    info.startRow.classList.add("is-range-boundary");
    info.endRow.classList.add("is-range-boundary");
    if (!activeRange.dragging && !activeForm) placeRangeButton();
  }

  function ensureRangeButton() {
    if (rangeButton) return rangeButton;
    rangeButton = document.createElement("button");
    rangeButton.type = "button";
    rangeButton.className = "diff-range-button";
    rangeButton.textContent = "+";
    rangeButton.setAttribute("aria-label", "Add comment on selected lines");
    rangeButton.title = "Add comment";
    rangeButton.addEventListener("click", (event) => {
      event.preventDefault();
      openDiffReviewForm();
    });
    document.body.appendChild(rangeButton);
    return rangeButton;
  }

  function placeRangeButton() {
    const info = activeRange ? selectedRangeInfo(activeRange) : null;
    if (!info || activeForm) {
      removeRangeButton();
      return;
    }
    const num = info.endRow.querySelector(".diff-num." + info.side);
    if (!num) return;
    const rect = num.getBoundingClientRect();
    const button = ensureRangeButton();
    button.classList.toggle("is-old", info.side === "old");
    button.classList.toggle("is-new", info.side === "new");
    button.style.left = Math.max(8, rect.left + 6) + "px";
    button.style.top = Math.max(8, rect.top + rect.height / 2 - 12) + "px";
  }

  function lineRangeLabel(info) {
    const side = info.side === "old" ? "old" : "new";
    if (info.startLine === info.endLine) return side + " line " + info.startLine;
    return side + " lines " + info.startLine + "-" + info.endLine;
  }

  function appendHiddenInput(form, name, value) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = name;
    input.value = value;
    form.appendChild(input);
  }

  function openDiffReviewForm() {
    const info = activeRange ? selectedRangeInfo(activeRange) : null;
    if (!info) return;
    const action = info.root.dataset.diffReviewAction || "";
    if (!action) return;
    removeRangeButton();
    removeActiveForm();

    const formRow = document.createElement("div");
    formRow.className = "diff-row diff-review-row";
    formRow.setAttribute("data-diff-review-form", "");

    const oldNum = document.createElement("span");
    oldNum.className = "diff-num old";
    const newNum = document.createElement("span");
    newNum.className = "diff-num new";
    const form = document.createElement("form");
    form.className = "diff-review-form";
    form.method = "post";
    form.action = action;

    appendHiddenInput(form, "action", "comment");
    appendHiddenInput(form, "diff_file", info.filePath);
    appendHiddenInput(form, "diff_side", info.side);
    appendHiddenInput(form, "diff_start", String(info.startLine));
    appendHiddenInput(form, "diff_end", String(info.endLine));

    const context = document.createElement("p");
    context.className = "diff-review-context";
    context.textContent = info.filePath + " - " + lineRangeLabel(info);

    const textarea = document.createElement("textarea");
    textarea.name = "body";
    textarea.rows = 5;
    textarea.placeholder = "Leave a comment";
    textarea.required = true;

    const actions = document.createElement("div");
    actions.className = "diff-review-actions";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "button secondary";
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", () => clearActiveRange());
    const submit = document.createElement("button");
    submit.type = "submit";
    submit.className = "button primary";
    submit.textContent = "Start review";
    actions.append(cancel, submit);

    form.append(context, textarea, actions);
    formRow.append(oldNum, newNum, form);
    info.endRow.after(formRow);
    activeForm = formRow;
    textarea.focus();
  }

  function startRangeSelection(num, event) {
    const row = num.closest("[data-diff-row]");
    const file = num.closest("[data-diff-file]");
    const root = diffReviewRoot(num);
    if (!row || !file || !root) return;
    const side = num.classList.contains("old") ? "old" : "new";
    clearActiveRange();
    activeRange = {
      root,
      file,
      side,
      anchorRow: row,
      focusRow: row,
      dragging: true,
      pointerId: event.pointerId,
    };
    if (num.setPointerCapture) {
      try {
        num.setPointerCapture(event.pointerId);
      } catch (_) {}
    }
    applyRangeSelection();
  }

  function updateRangeFromPoint(event) {
    if (!activeRange || !activeRange.dragging) return;
    const target = document.elementFromPoint(event.clientX, event.clientY);
    const num = lineNumberTarget(target);
    if (!num) return;
    const row = num.closest("[data-diff-row]");
    const file = num.closest("[data-diff-file]");
    const side = num.classList.contains("old") ? "old" : "new";
    if (!row || file !== activeRange.file || side !== activeRange.side) return;
    if (row === activeRange.focusRow) return;
    activeRange.focusRow = row;
    applyRangeSelection();
  }

  function finishRangeSelection(event) {
    if (!activeRange || !activeRange.dragging) return;
    if (activeRange.pointerId !== event.pointerId) return;
    activeRange.dragging = false;
    applyRangeSelection();
    placeRangeButton();
  }

  function initDiffReviewRanges() {
    document.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      const num = lineNumberTarget(event.target);
      if (!num) return;
      event.preventDefault();
      startRangeSelection(num, event);
    });
    document.addEventListener("pointermove", (event) => {
      updateRangeFromPoint(event);
    });
    document.addEventListener("pointerup", (event) => {
      finishRangeSelection(event);
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && (activeRange || activeForm)) clearActiveRange();
    });
    window.addEventListener("scroll", () => {
      if (activeRange && !activeRange.dragging && !activeForm) placeRangeButton();
    }, { passive: true });
    window.addEventListener("resize", () => {
      if (activeRange && !activeRange.dragging && !activeForm) placeRangeButton();
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
    initDiffReviewRanges();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initDiffAnchors);
  } else {
    initDiffAnchors();
  }
})();
