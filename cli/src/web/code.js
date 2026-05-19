(function () {
  "use strict";

  const symbolsStorageKey = "gitomi.symbolsPanel";
  const symbolsWidthKey = "gitomi.symbolsPanelWidth";
  const minSymbolsWidth = 300;
  const maxSymbolsWidth = 640;
  let rightPanelOffsetResizeBound = false;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function setButtonState(button, label) {
    const labelNode = button.querySelector("[data-button-label]");
    if (labelNode) {
      labelNode.textContent = label;
    } else {
      button.textContent = label;
    }
  }

  function storedSymbolsVisible() {
    try {
      return window.localStorage.getItem(symbolsStorageKey) !== "hidden";
    } catch (_) {
      return true;
    }
  }

  function storeSymbolsVisible(visible) {
    try {
      if (visible) {
        window.localStorage.removeItem(symbolsStorageKey);
      } else {
        window.localStorage.setItem(symbolsStorageKey, "hidden");
      }
    } catch (_) {}
  }

  function maxSymbolsWidthForLayout(layout) {
    const layoutWidth = layout.getBoundingClientRect().width || window.innerWidth;
    return Math.min(maxSymbolsWidth, Math.max(minSymbolsWidth, layoutWidth - 520));
  }

  function setSymbolsWidth(layout, width, persist) {
    const next = clamp(width, minSymbolsWidth, maxSymbolsWidthForLayout(layout));
    layout.style.setProperty("--symbols-width", `${next}px`);
    if (persist) {
      try {
        window.localStorage.setItem(symbolsWidthKey, String(next));
      } catch (_) {}
    }
  }

  function setSymbolsVisible(layout, sidebar, button, visible, persist) {
    layout.classList.toggle("symbols-collapsed", !visible);
    sidebar.hidden = !visible;
    if (button) {
      button.setAttribute("aria-expanded", String(visible));
      setButtonState(button, visible ? "Hide symbols" : "Show symbols");
      button.setAttribute("aria-label", visible ? "Hide symbols panel" : "Show symbols panel");
      button.title = visible ? "Hide symbols panel" : "Show symbols panel";
    }
    if (persist) storeSymbolsVisible(visible);
  }

  function syncRightPanelOffset(layout) {
    layout.style.setProperty("--right-panel-offset", "0px");
  }

  function syncRightPanelOffsets() {
    document.querySelectorAll(".code-layout.has-symbols, .code-layout.has-markdown-outline").forEach(syncRightPanelOffset);
  }

  function initRightPanelOffsets() {
    syncRightPanelOffsets();
    if (rightPanelOffsetResizeBound) return;
    rightPanelOffsetResizeBound = true;
    window.addEventListener("resize", syncRightPanelOffsets);
    window.addEventListener("load", syncRightPanelOffsets);
  }

  function initSymbolsToggle(button) {
    const sidebarId = button.getAttribute("aria-controls");
    const sidebar = sidebarId ? document.getElementById(sidebarId) : document.querySelector("[data-symbols-sidebar]");
    const layout = button.closest(".code-layout") || document.querySelector(".code-layout.has-symbols");
    if (!sidebar || !layout) return;
    if (button.dataset.symbolsToggleReady === "yes") return;
    button.dataset.symbolsToggleReady = "yes";

    setSymbolsVisible(layout, sidebar, button, storedSymbolsVisible(), false);
    button.addEventListener("click", function () {
      setSymbolsVisible(layout, sidebar, button, button.getAttribute("aria-expanded") !== "true", true);
    });
  }

  function symbolRows(sidebar) {
    return Array.prototype.slice.call(sidebar.querySelectorAll("[data-symbol-row]"));
  }

  function symbolRowDepth(row) {
    const depth = Number(row.dataset.symbolDepth);
    return Number.isFinite(depth) ? depth : 0;
  }

  function applySymbolTreeVisibility(sidebar, ignoreCollapsed) {
    let collapsedDepth = null;
    symbolRows(sidebar).forEach(function (row) {
      const depth = symbolRowDepth(row);
      if (collapsedDepth !== null && depth <= collapsedDepth) collapsedDepth = null;

      const filtered = row.dataset.symbolFilterHidden === "true";
      const collapsed = collapsedDepth !== null;
      row.hidden = filtered || (!ignoreCollapsed && collapsed);

      if (!filtered && !ignoreCollapsed && row.dataset.symbolCollapsed === "true") {
        collapsedDepth = depth;
      }
    });
  }

  function filterSymbols(sidebar, query) {
    const value = String(query || "").trim().toLowerCase();
    const rows = symbolRows(sidebar);
    if (value === "") {
      rows.forEach(function (row) {
        row.dataset.symbolFilterHidden = "false";
      });
      applySymbolTreeVisibility(sidebar, false);
      return;
    }

    const visible = new Set();
    rows.forEach(function (row, index) {
      if ((row.textContent || "").toLowerCase().indexOf(value) === -1) return;
      visible.add(row);
      let parentDepth = symbolRowDepth(row);
      for (let previous = index - 1; previous >= 0 && parentDepth > 0; previous -= 1) {
        const candidate = rows[previous];
        const candidateDepth = symbolRowDepth(candidate);
        if (candidateDepth < parentDepth) {
          visible.add(candidate);
          parentDepth = candidateDepth;
        }
      }
    });

    rows.forEach(function (row) {
      row.dataset.symbolFilterHidden = visible.has(row) ? "false" : "true";
    });
    applySymbolTreeVisibility(sidebar, true);
  }

  function initSymbolTree(sidebar) {
    sidebar.querySelectorAll("[data-symbol-toggle]").forEach(function (toggle) {
      if (toggle.dataset.symbolToggleReady === "yes") return;
      toggle.dataset.symbolToggleReady = "yes";
      toggle.addEventListener("click", function () {
        const row = toggle.closest("[data-symbol-row]");
        if (!row) return;
        const expanded = toggle.getAttribute("aria-expanded") !== "false";
        const nextExpanded = !expanded;
        toggle.setAttribute("aria-expanded", String(nextExpanded));
        toggle.setAttribute("aria-label", nextExpanded ? "Collapse symbol children" : "Expand symbol children");
        toggle.title = nextExpanded ? "Collapse symbol children" : "Expand symbol children";
        row.dataset.symbolCollapsed = nextExpanded ? "false" : "true";
        const input = sidebar.querySelector("[data-symbols-filter]");
        applySymbolTreeVisibility(sidebar, input && String(input.value || "").trim() !== "");
      });
    });
  }

  function initSymbolsPanel(sidebar) {
    const layout = sidebar.closest(".code-layout") || document.querySelector(".code-layout.has-symbols");
    const button = layout ? layout.querySelector("[data-symbols-toggle]") : null;
    const input = sidebar.querySelector("[data-symbols-filter]");
    const close = sidebar.querySelector("[data-symbols-close]");

    initSymbolTree(sidebar);
    filterSymbols(sidebar, input ? input.value : "");
    initSymbolsResize(sidebar);
    if (sidebar.dataset.symbolsPanelReady === "yes") return;
    sidebar.dataset.symbolsPanelReady = "yes";

    if (input) {
      input.addEventListener("input", function () {
        filterSymbols(sidebar, input.value);
      });
    }
    if (close && layout) {
      close.addEventListener("click", function () {
        setSymbolsVisible(layout, sidebar, button, false, true);
      });
    }
  }

  function initSymbolsResize(sidebar) {
    const layout = sidebar.closest(".code-layout") || document.querySelector(".code-layout.has-symbols");
    const handle = layout ? layout.querySelector("[data-symbols-resizer]") : null;
    if (!handle || !layout) return;
    if (sidebar.dataset.symbolsResizeReady === "yes") return;
    sidebar.dataset.symbolsResizeReady = "yes";

    try {
      const stored = Number(window.localStorage.getItem(symbolsWidthKey));
      if (Number.isFinite(stored) && stored > 0) {
        setSymbolsWidth(layout, stored, false);
      }
    } catch (_) {}

    handle.addEventListener("pointerdown", function (event) {
      if (sidebar.hidden || layout.classList.contains("symbols-collapsed")) return;
      event.preventDefault();
      handle.setPointerCapture(event.pointerId);
      document.documentElement.classList.add("symbols-resizing");

      const onMove = function (moveEvent) {
        const right = layout.getBoundingClientRect().right;
        setSymbolsWidth(layout, right - moveEvent.clientX, true);
      };
      const onEnd = function () {
        document.documentElement.classList.remove("symbols-resizing");
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onEnd);
        window.removeEventListener("pointercancel", onEnd);
      };

      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onEnd);
      window.addEventListener("pointercancel", onEnd);
    });
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.top = "-1000px";
    document.body.appendChild(textarea);
    textarea.select();
    try {
      document.execCommand("copy");
    } finally {
      textarea.remove();
    }
  }

  function initCopyButton(button) {
    button.addEventListener("click", async function () {
      const url = button.dataset.copyRaw;
      if (!url) return;

      const labelNode = button.querySelector("[data-button-label]");
      const original = (labelNode && labelNode.textContent) || button.textContent || "Copy";
      button.disabled = true;
      setButtonState(button, "Copying");
      try {
        const response = await fetch(url, { cache: "no-store" });
        if (!response.ok) throw new Error("Raw fetch failed");
        await copyText(await response.text());
        setButtonState(button, "Copied");
      } catch (_) {
        setButtonState(button, "Failed");
      } finally {
        window.setTimeout(function () {
          button.disabled = false;
          setButtonState(button, original);
        }, 1200);
      }
    });
  }

  function initCopyButtons() {
    document.querySelectorAll("[data-copy-raw]").forEach(initCopyButton);
  }

  function initPathCopyButton(button) {
    button.addEventListener("click", async function () {
      const path = button.dataset.copyPath || "";
      const original = button.title || "Copy path";
      button.disabled = true;
      try {
        await copyText(path);
        button.title = "Copied path";
        button.setAttribute("aria-label", "Copied path");
      } catch (_) {
        button.title = "Copy failed";
        button.setAttribute("aria-label", "Copy failed");
      } finally {
        window.setTimeout(function () {
          button.disabled = false;
          button.title = original;
          button.setAttribute("aria-label", original);
        }, 1200);
      }
    });
  }

  function initPathCopyButtons() {
    document.querySelectorAll("[data-copy-path]").forEach(initPathCopyButton);
  }

  function initTextCopyButton(button) {
    button.addEventListener("click", async function () {
      const text = button.dataset.copyText || "";
      const original = button.title || button.getAttribute("aria-label") || "Copy";
      if (!text) return;
      button.disabled = true;
      try {
        await copyText(text);
        button.title = "Copied";
        button.setAttribute("aria-label", "Copied");
      } catch (_) {
        button.title = "Copy failed";
        button.setAttribute("aria-label", "Copy failed");
      } finally {
        window.setTimeout(function () {
          button.disabled = false;
          button.title = original;
          button.setAttribute("aria-label", original);
        }, 1200);
      }
    });
  }

  function initTextCopyButtons() {
    document.querySelectorAll("[data-copy-text]").forEach(initTextCopyButton);
  }

  let activeLine = null;
  let activeLineButton = null;
  let activeLineRange = [];
  let rangeAnchorLine = null;
  let lineDrag = null;
  let suppressNextLineClick = false;
  let lineMenu = null;
  let lineDocumentHandlersBound = false;

  function lineNumber(row) {
    return row.dataset.lineNumber || (row.id || "").replace(/^L/, "");
  }

  function lineContainer(row) {
    return row.closest("[data-code-lines]");
  }

  function lineSelectionContainer(row) {
    return lineContainer(row) || row.closest(".blame-lines");
  }

  function numericLineNumber(row) {
    const value = Number(lineNumber(row));
    return Number.isInteger(value) && value > 0 ? value : null;
  }

  function lineRowByNumber(number) {
    const row = document.getElementById(`L${number}`);
    return row && row.matches("[data-line-row], .blame-row") ? row : null;
  }

  function lineRowsInContainer(container) {
    return Array.prototype.slice.call(container.querySelectorAll("[data-line-row], .blame-row"));
  }

  function lineRowsBetween(startRow, endRow) {
    const container = lineSelectionContainer(startRow);
    if (!container || lineSelectionContainer(endRow) !== container) return [];
    const start = numericLineNumber(startRow);
    const end = numericLineNumber(endRow);
    if (start === null || end === null) return [];
    const first = Math.min(start, end);
    const last = Math.max(start, end);
    return lineRowsInContainer(container).filter(function (row) {
      const number = numericLineNumber(row);
      return number !== null && number >= first && number <= last;
    });
  }

  function linePath(row) {
    const container = lineContainer(row);
    return (container && container.dataset.path) || "";
  }

  function lineCode(row) {
    const code = row.querySelector("code");
    return (code && code.textContent) || "";
  }

  function lineHashForRows(rows) {
    if (!rows.length) return "";
    const start = lineNumber(rows[0]);
    const end = lineNumber(rows[rows.length - 1]);
    return start === end ? `L${start}` : `L${start}-L${end}`;
  }

  function setLocationHashForRows(rows, replace) {
    const hash = lineHashForRows(rows);
    if (!hash) return;
    const url = new URL(window.location.href);
    url.hash = hash;
    if (url.href === window.location.href) return;
    try {
      if (replace) {
        window.history.replaceState(null, "", url);
      } else {
        window.history.pushState(null, "", url);
      }
    } catch (_) {
      window.location.hash = hash;
    }
  }

  function lineSelectionUrl(rows) {
    const url = new URL(window.location.href);
    const hash = lineHashForRows(rows);
    if (hash) url.hash = hash;
    return url;
  }

  function linePermalinkUrl(rows) {
    const first = rows[0];
    if (!first) return new URL(window.location.href);
    const container = lineContainer(first);
    const href = (container && (container.dataset.permalinkHref || container.dataset.codeHref)) || "";
    const url = href ? new URL(href, window.location.href) : lineSelectionUrl(rows);
    const hash = lineHashForRows(rows);
    if (hash) url.hash = hash;
    return url;
  }

  function blameUrl(rows) {
    const first = rows[0];
    if (!first) return new URL(window.location.href);
    const container = lineContainer(first);
    const href = (container && container.dataset.blameHref) || "";
    const url = href ? new URL(href, window.location.href) : new URL(window.location.href);
    url.pathname = "/blame";
    const hash = lineHashForRows(rows);
    if (hash) url.hash = hash;
    return url;
  }

  function lineReference(rows) {
    const first = rows[0];
    if (!first) return "line";
    const path = linePath(first);
    const start = lineNumber(first);
    const end = lineNumber(rows[rows.length - 1]);
    const suffix = start === end ? start : `${start}-${end}`;
    return path ? `${path}:${suffix}` : `line ${suffix}`;
  }

  function newIssueUrl(rows) {
    const params = new URLSearchParams();
    const reference = lineReference(rows);
    params.set("title", `Reference ${reference}`);
    params.set("body", `${reference}\n\n${linePermalinkUrl(rows).href}`);
    return `/new-issue?${params.toString()}`;
  }

  function setMenuItemDisabled(action, disabled) {
    if (!lineMenu) return;
    const item = lineMenu.querySelector(`[data-line-action="${action}"]`);
    if (item) item.disabled = disabled;
  }

  function setMenuItemLabel(action, label) {
    if (!lineMenu) return;
    const item = lineMenu.querySelector(`[data-line-action="${action}"] [data-line-action-label]`);
    if (item) item.textContent = label;
  }

  function activeSelectionRows(fallbackRow) {
    if (activeLineRange.length) return activeLineRange;
    if (activeLine) return [activeLine];
    return fallbackRow ? [fallbackRow] : [];
  }

  function updateLineMenuLabels() {
    const isRange = activeLineRange.length > 1;
    setMenuItemLabel("copy-line", isRange ? "Copy block" : "Copy line");
    setMenuItemLabel("copy-permalink", isRange ? "Copy range permalink" : "Copy permalink");
    setMenuItemLabel("view-blame", isRange ? "View git blame for range" : "View git blame");
    setMenuItemLabel("new-issue", isRange ? "Reference range in new issue" : "Reference in new issue");
  }

  function ensureLineMenu() {
    if (lineMenu) return lineMenu;

    lineMenu = document.createElement("div");
    lineMenu.className = "line-actions-menu";
    lineMenu.setAttribute("role", "menu");
    lineMenu.hidden = true;
    lineMenu.innerHTML = [
      '<button type="button" role="menuitem" data-line-action="copy-line"><span data-line-action-label>Copy line</span></button>',
      '<button type="button" role="menuitem" data-line-action="copy-permalink"><span data-line-action-label>Copy permalink</span></button>',
      '<button type="button" role="menuitem" data-line-action="view-blame"><span data-line-action-label>View git blame</span></button>',
      '<button type="button" role="menuitem" data-line-action="new-issue"><span data-line-action-label>Reference in new issue</span></button>',
      '<button type="button" role="menuitem" data-line-action="switch-ref"><span>View file in different branch/tag</span><kbd>W</kbd></button>',
    ].join("");
    document.body.appendChild(lineMenu);

    lineMenu.addEventListener("click", async function (event) {
      const item = event.target.closest("[data-line-action]");
      if (!item || item.disabled || activeSelectionRows().length === 0) return;
      event.preventDefault();
      await runLineAction(item.dataset.lineAction);
    });

    return lineMenu;
  }

  function positionLineMenu(button) {
    if (!lineMenu || lineMenu.hidden) return;
    lineMenu.style.visibility = "hidden";
    lineMenu.style.left = "0";
    lineMenu.style.top = "0";

    const rect = button.getBoundingClientRect();
    const width = lineMenu.offsetWidth;
    const height = lineMenu.offsetHeight;
    const gap = 6;
    const margin = 8;
    let left = rect.left;
    let top = rect.bottom + gap;

    if (left + width > window.innerWidth - margin) {
      left = window.innerWidth - width - margin;
    }
    if (top + height > window.innerHeight - margin) {
      top = rect.top - height - gap;
    }

    lineMenu.style.left = `${Math.max(margin, left)}px`;
    lineMenu.style.top = `${Math.max(margin, top)}px`;
    lineMenu.style.visibility = "";
  }

  function closeLineMenu() {
    if (lineMenu) lineMenu.hidden = true;
    if (activeLineButton) activeLineButton.setAttribute("aria-expanded", "false");
    activeLineButton = null;
  }

  function openLineMenu(row, button) {
    ensureLineMenu();
    activeLineButton = button;
    button.setAttribute("aria-expanded", "true");
    updateLineMenuLabels();
    setMenuItemDisabled("switch-ref", document.querySelector("[data-branch-switcher]") === null);
    lineMenu.hidden = false;
    positionLineMenu(button);
    const first = lineMenu.querySelector("[data-line-action]:not(:disabled)");
    if (first) first.focus();
  }

  function clearActiveLine() {
    if (!activeLine) return;
    activeLine.classList.remove("line-selected");
    const button = activeLine.querySelector("[data-line-menu-button]");
    if (button) {
      button.setAttribute("aria-expanded", "false");
      button.tabIndex = -1;
    }
    activeLine = null;
  }

  function clearActiveLineRange() {
    activeLineRange.forEach(function (row) {
      row.classList.remove("line-range-selected", "line-range-start", "line-range-end");
      const button = row.querySelector("[data-line-menu-button]");
      if (button) {
        button.setAttribute("aria-expanded", "false");
        button.tabIndex = -1;
      }
    });
    activeLineRange = [];
  }

  function setActiveLineRange(rows, options) {
    const opts = options || {};
    if (rows.length <= 1) {
      if (rows.length === 1) setActiveLine(rows[0], opts);
      return;
    }
    closeLineMenu();
    clearActiveLine();
    clearActiveLineRange();
    activeLineRange = rows;
    rows.forEach(function (row, index) {
      row.classList.add("line-range-selected");
      if (index === 0) {
        row.classList.add("line-range-start");
        const button = row.querySelector("[data-line-menu-button]");
        if (button) button.tabIndex = 0;
      }
      if (index === rows.length - 1) row.classList.add("line-range-end");
    });
    if (opts.setAnchor !== false) rangeAnchorLine = rows[0];
    if (opts.updateHash !== false) setLocationHashForRows(rows, opts.replaceHash === true);
  }

  function setActiveLine(row, options) {
    const opts = options || {};
    clearActiveLineRange();
    if (activeLine !== row) {
      closeLineMenu();
      clearActiveLine();
      activeLine = row;
      row.classList.add("line-selected");
      const nextButton = row.querySelector("[data-line-menu-button]");
      if (nextButton) nextButton.tabIndex = 0;
    }

    if (opts.setAnchor !== false) rangeAnchorLine = row;
    if (opts.updateHash !== false && row.id) setLocationHashForRows([row], opts.replaceHash === true);

    const button = row.querySelector("[data-line-menu-button]");
    if (opts.openMenu && button) {
      openLineMenu(row, button);
    }
  }

  async function runLineAction(action) {
    const rows = activeSelectionRows();
    if (rows.length === 0) return;
    if (action === "copy-line") {
      await copyText(rows.map(lineCode).join("\n"));
      closeLineMenu();
    } else if (action === "copy-permalink") {
      await copyText(linePermalinkUrl(rows).href);
      closeLineMenu();
    } else if (action === "view-blame") {
      window.location.href = blameUrl(rows).href;
    } else if (action === "new-issue") {
      window.location.href = newIssueUrl(rows);
    } else if (action === "switch-ref") {
      focusBranchSwitcher();
    }
  }

  function focusBranchSwitcher() {
    const select = document.querySelector("[data-branch-switcher]");
    if (!select) return;
    closeLineMenu();
    select.focus();
    select.classList.add("branch-switcher-pulse");
    window.setTimeout(function () {
      select.classList.remove("branch-switcher-pulse");
    }, 900);
  }

  function lineRangeFromCurrentHash() {
    const id = window.location.hash.replace(/^#/, "");
    if (!id) return null;
    let decoded = id;
    try {
      decoded = decodeURIComponent(id);
    } catch (_) {}
    const match = /^L([1-9][0-9]*)(?:-L?([1-9][0-9]*))?$/.exec(decoded);
    if (!match) return null;
    const first = Number(match[1]);
    const second = match[2] ? Number(match[2]) : first;
    if (!Number.isSafeInteger(first) || !Number.isSafeInteger(second)) return null;
    return {
      start: Math.min(first, second),
      end: Math.max(first, second),
    };
  }

  function lineSelectionFromCurrentHash() {
    const range = lineRangeFromCurrentHash();
    if (!range) return null;

    const startRow = lineRowByNumber(range.start);
    const endRow = lineRowByNumber(range.end);
    if (!startRow || !endRow) return null;

    const rows = lineRowsBetween(startRow, endRow);
    if (rows.length === 0) return null;
    return {
      rows: rows,
      firstRow: rows[0],
      isRange: range.start !== range.end,
    };
  }

  function stickyBottom(element) {
    if (!element) return 0;
    const position = window.getComputedStyle(element).position;
    if (position !== "sticky" && position !== "fixed") return 0;
    const rect = element.getBoundingClientRect();
    if (rect.bottom <= 0 || rect.top >= window.innerHeight) return 0;
    return Math.max(0, Math.min(window.innerHeight, rect.bottom));
  }

  function lineViewportTop(row) {
    const panel = row.closest(".code-panel");
    const panelHead = panel && panel.querySelector(".code-panel-head");
    return Math.max(
      stickyBottom(document.querySelector(".topbar")),
      stickyBottom(panelHead),
    );
  }

  function scrollLineIntoView(row) {
    const gap = 8;
    const top = Math.min(window.innerHeight, lineViewportTop(row) + gap);
    const rect = row.getBoundingClientRect();
    const nextTop = window.scrollY + rect.top - top;
    if (Math.abs(rect.top - top) > 1) {
      window.scrollTo({ top: Math.max(0, nextTop), left: window.scrollX, behavior: "auto" });
    }
  }

  function scrollLineIntoViewSoon(row) {
    window.requestAnimationFrame(function () {
      scrollLineIntoView(row);
      window.requestAnimationFrame(function () {
        scrollLineIntoView(row);
      });
    });
  }

  function syncLineSelectionFromHash() {
    const selection = lineSelectionFromCurrentHash();
    if (selection) {
      const row = selection.firstRow;
      if (row.matches("[data-line-row]")) {
        if (selection.isRange) {
          setActiveLineRange(selection.rows, { updateHash: false });
        } else {
          setActiveLine(row, { updateHash: false, openMenu: false });
        }
      } else {
        closeLineMenu();
        clearActiveLine();
        if (selection.isRange) {
          setActiveLineRange(selection.rows, { updateHash: false });
        } else {
          clearActiveLineRange();
        }
      }
      scrollLineIntoViewSoon(row);
    } else {
      closeLineMenu();
      clearActiveLine();
      clearActiveLineRange();
    }
  }

  function selectLineRange(startRow, endRow, options) {
    const rows = lineRowsBetween(startRow, endRow);
    if (rows.length === 0) return;
    setActiveLineRange(rows, options);
  }

  function selectLine(row, event) {
    closeLineMenu();
    const anchor = rangeAnchorLine && lineSelectionContainer(rangeAnchorLine) === lineSelectionContainer(row)
      ? rangeAnchorLine
      : activeLine;
    if (event.shiftKey && anchor && anchor !== row) {
      selectLineRange(anchor, row, { setAnchor: false });
      return;
    }
    setActiveLine(row, { openMenu: false });
  }

  function rowAtPoint(event, container) {
    const element = document.elementFromPoint(event.clientX, event.clientY);
    if (!element) return null;
    const row = element.closest("[data-line-row]");
    return row && container.contains(row) ? row : null;
  }

  function beginLineDrag(event, container) {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
    const line = event.target.closest(".line-num");
    if (!line || !container.contains(line)) return;
    const row = line.closest("[data-line-row]");
    if (!row) return;
    lineDrag = {
      container: container,
      startRow: row,
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      moved: false,
    };
    rangeAnchorLine = row;
    try {
      line.setPointerCapture(event.pointerId);
    } catch (_) {}
  }

  function updateLineDrag(event) {
    if (!lineDrag || event.pointerId !== lineDrag.pointerId) return;
    const distanceX = Math.abs(event.clientX - lineDrag.startX);
    const distanceY = Math.abs(event.clientY - lineDrag.startY);
    if (!lineDrag.moved && distanceX < 4 && distanceY < 4) return;
    const row = rowAtPoint(event, lineDrag.container);
    if (!row) return;
    lineDrag.moved = true;
    event.preventDefault();
    selectLineRange(lineDrag.startRow, row, { replaceHash: true, setAnchor: false });
  }

  function endLineDrag(event) {
    if (!lineDrag || event.pointerId !== lineDrag.pointerId) return;
    if (lineDrag.moved) {
      suppressNextLineClick = true;
      event.preventDefault();
      window.setTimeout(function () {
        suppressNextLineClick = false;
      }, 0);
    }
    lineDrag = null;
  }

  function bindLineDocumentHandlers() {
    if (lineDocumentHandlersBound) return;
    lineDocumentHandlersBound = true;

    document.addEventListener("click", function (event) {
      if (!lineMenu || lineMenu.hidden) return;
      if (lineMenu.contains(event.target)) return;
      if (activeLineButton && activeLineButton.contains(event.target)) return;
      closeLineMenu();
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        const button = activeLineButton;
        closeLineMenu();
        if (button) button.focus();
        return;
      }
      if (!lineMenu || lineMenu.hidden) return;
      if (event.key.toLowerCase() === "w" && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault();
        focusBranchSwitcher();
      }
    });

    window.addEventListener("resize", closeLineMenu);
    window.addEventListener("hashchange", syncLineSelectionFromHash);
    window.addEventListener("popstate", syncLineSelectionFromHash);
  }

  function initCodeLineActions(container) {
    bindLineDocumentHandlers();

    container.addEventListener("pointerdown", function (event) {
      beginLineDrag(event, container);
    });

    container.addEventListener("pointermove", updateLineDrag);
    container.addEventListener("pointerup", endLineDrag);
    container.addEventListener("pointercancel", endLineDrag);

    container.addEventListener("click", function (event) {
      const button = event.target.closest("[data-line-menu-button]");
      if (button && container.contains(button)) {
        const row = button.closest("[data-line-row]");
        if (!row) return;
        event.preventDefault();
        event.stopPropagation();
        const shouldOpen = !lineMenu || lineMenu.hidden || activeLineButton !== button;
        if (shouldOpen) {
          if (activeLineRange.indexOf(row) === -1 && activeLine !== row) {
            setActiveLine(row, { openMenu: false });
          }
          openLineMenu(row, button);
        } else {
          closeLineMenu();
        }
        return;
      }

      const line = event.target.closest(".line-num");
      if (!line || !container.contains(line)) return;
      const row = line.closest("[data-line-row]");
      if (!row) return;
      event.preventDefault();
      event.stopPropagation();
      if (suppressNextLineClick) return;
      selectLine(row, event);
    });
  }

  function initCodeLineActionControls() {
    bindLineDocumentHandlers();
    document.querySelectorAll("[data-code-lines]").forEach(initCodeLineActions);
    syncLineSelectionFromHash();
  }

  function initSymbolsToggles() {
    document.querySelectorAll("[data-symbols-toggle]").forEach(initSymbolsToggle);
    document.querySelectorAll("[data-symbols-sidebar]").forEach(initSymbolsPanel);
  }

  function syncRootSidebarScroll(sidebar) {
    const rect = sidebar.getBoundingClientRect();
    const height = Math.max(sidebar.scrollHeight || 0, rect.height || 0);
    sidebar.style.setProperty("--root-sidebar-height", `${Math.ceil(height)}px`);
  }

  function syncRootSidebars(root) {
    const scope = root || document;
    scope.querySelectorAll(".root-sidebar").forEach(function (sidebar) {
      syncRootSidebarScroll(sidebar);
    });
  }

  function initRootSidebarScroll(root) {
    const scope = root || document;
    scope.querySelectorAll(".root-sidebar").forEach(function (sidebar) {
      syncRootSidebarScroll(sidebar);
      if (sidebar.dataset.rootSidebarScrollReady === "yes") return;
      sidebar.dataset.rootSidebarScrollReady = "yes";

      if ("ResizeObserver" in window) {
        const observer = new ResizeObserver(function () {
          syncRootSidebarScroll(sidebar);
        });
        observer.observe(sidebar);
        sidebar.gitomiRootSidebarObserver = observer;
      }
    });
  }

  function notifyPartialRefresh(root) {
    document.dispatchEvent(new CustomEvent("gitomi:partial-refresh", {
      detail: { root: root || document },
    }));
  }

  function partialErrorMessage(slot, error) {
    if (error && error.name === "AbortError") {
      const seconds = Math.max(1, Math.round(rootPartialTimeout(slot) / 1000));
      return `This section took longer than ${seconds}s to load.`;
    }
    return "Could not load this section.";
  }

  function partialErrorNode(slot, error) {
    if (slot.hasAttribute("data-root-partial-field") || slot.hasAttribute("data-root-partial-inline")) {
      const wrap = document.createElement("span");
      wrap.className = "root-partial-field-error";

      const message = document.createElement("span");
      message.textContent = partialErrorMessage(slot, error);
      wrap.appendChild(message);

      const retry = document.createElement("button");
      retry.className = "button secondary root-partial-retry root-partial-field-retry";
      retry.type = "button";
      retry.textContent = "Retry";
      retry.addEventListener("click", function () {
        scheduleRootPartial(slot, true);
      });
      wrap.appendChild(retry);
      return wrap;
    }

    const section = document.createElement("div");
    section.className = "root-sidebar-section root-sidebar-error";

    const heading = document.createElement("h2");
    heading.textContent = slot.dataset.rootPartialLabel || "Section";
    section.appendChild(heading);

    const message = document.createElement("p");
    message.className = "root-sidebar-empty";
    message.textContent = partialErrorMessage(slot, error);
    section.appendChild(message);

    const retry = document.createElement("button");
    retry.className = "button secondary root-partial-retry";
    retry.type = "button";
    retry.textContent = "Retry";
    retry.addEventListener("click", function () {
      scheduleRootPartial(slot, true);
    });
    section.appendChild(retry);

    return section;
  }

  function clearRootFileListNotice(slot) {
    const notice = slot.previousElementSibling;
    if (notice && notice.hasAttribute("data-root-file-list-notice")) notice.remove();
  }

  function setRootFileCommitPlaceholders(slot, message, isError) {
    slot.querySelectorAll(".root-file-commit-deferred").forEach(function (node) {
      node.textContent = message;
      node.classList.toggle("root-file-commit-error", Boolean(isError));
    });
  }

  function handleRootFileListPartialError(slot, error) {
    if (!slot.hasAttribute("data-root-file-list")) return false;
    setRootFileCommitPlaceholders(slot, "Commit history unavailable", true);
    if (slot.previousElementSibling && slot.previousElementSibling.hasAttribute("data-root-file-list-notice")) return true;

    const notice = document.createElement("div");
    notice.className = "root-file-list-notice";
    notice.setAttribute("data-root-file-list-notice", "");

    const message = document.createElement("span");
    message.textContent = partialErrorMessage(slot, error);
    notice.appendChild(message);

    const retry = document.createElement("button");
    retry.className = "button secondary root-partial-retry root-file-list-retry";
    retry.type = "button";
    retry.textContent = "Retry";
    retry.addEventListener("click", function () {
      clearRootFileListNotice(slot);
      setRootFileCommitPlaceholders(slot, "Loading commit...", false);
      scheduleRootPartial(slot, true);
    });
    notice.appendChild(retry);
    slot.before(notice);
    return true;
  }

  const rootPartialMaxConcurrent = 2;
  const rootPartialDefaultTimeoutMs = 15000;
  const rootContributorLargeSlocThreshold = 200000;
  let rootPartialActive = 0;
  let rootPartialSequence = 0;
  let rootPartialDrainScheduled = false;
  const rootPartialQueue = [];

  function rootPartialPriority(slot) {
    const priority = Number(slot.dataset.rootPartialPriority);
    return Number.isFinite(priority) ? priority : 100;
  }

  function sortRootPartialQueue() {
    rootPartialQueue.sort(function (a, b) {
      if (a.priority !== b.priority) return a.priority - b.priority;
      return a.sequence - b.sequence;
    });
  }

  function rootPartialTimeout(slot) {
    const timeout = Number(slot.dataset.rootPartialTimeoutMs);
    return Number.isFinite(timeout) && timeout > 0 ? timeout : rootPartialDefaultTimeoutMs;
  }

  function scheduleRootPartialDrain() {
    if (rootPartialDrainScheduled) return;
    rootPartialDrainScheduled = true;
    window.setTimeout(function () {
      rootPartialDrainScheduled = false;
      drainRootPartialQueue();
    }, 0);
  }

  function isServerRootPartialSlot(slot) {
    return slot && slot.dataset.rootPartialOwner === "gitomi";
  }

  function isAllowedRootPartialUrl(url) {
    if (!url) return false;
    try {
      const parsed = new URL(url, window.location.href);
      if (parsed.origin !== window.location.origin) return false;
      return /^\/code\/root\/(?:about|toolbar-refs|repository|repository-tracked-size|repository-directory-size|branch|branch-sync|branch-changes|branch-diff|branch-state|file-list|stats|contributors|docs|search|commit-count)$/.test(parsed.pathname);
    } catch (_) {
      return false;
    }
  }

  function scheduleRootPartial(slot, retrying) {
    if (!isServerRootPartialSlot(slot)) return;
    const url = slot.dataset.rootPartial;
    if (!isAllowedRootPartialUrl(url)) return;
    if (slot.dataset.rootPartialState === "queued" || slot.dataset.rootPartialState === "loading") return;
    if (!retrying && slot.dataset.rootPartialReady === "yes") return;
    slot.dataset.rootPartialReady = "yes";
    slot.dataset.rootPartialState = "queued";
    rootPartialQueue.push({
      slot,
      priority: rootPartialPriority(slot),
      sequence: rootPartialSequence++,
    });
    sortRootPartialQueue();
    scheduleRootPartialDrain();
  }

  function promoteDeferredRootPartial(slot) {
    if (!isServerRootPartialSlot(slot)) return;
    const url = slot.dataset.rootPartialDeferred;
    if (!isAllowedRootPartialUrl(url) || slot.dataset.rootPartial) return;
    slot.dataset.rootPartial = url;
    delete slot.dataset.rootPartialDeferred;
    scheduleRootPartial(slot, false);
  }

  function drainRootPartialQueue() {
    while (rootPartialActive < rootPartialMaxConcurrent && rootPartialQueue.length !== 0) {
      const item = rootPartialQueue.shift();
      if (!item.slot.isConnected) {
        delete item.slot.dataset.rootPartialState;
        continue;
      }

      rootPartialActive += 1;
      item.slot.dataset.rootPartialState = "loading";
      loadRootPartial(item.slot).finally(function () {
        rootPartialActive -= 1;
        drainRootPartialQueue();
      });
    }
  }

  async function loadRootPartial(slot) {
    if (!isServerRootPartialSlot(slot)) return;
    const url = slot.dataset.rootPartial;
    if (!isAllowedRootPartialUrl(url)) return;
    slot.setAttribute("aria-busy", "true");
    const controller = "AbortController" in window ? new AbortController() : null;
    const timeout = window.setTimeout(function () {
      if (controller) controller.abort();
    }, rootPartialTimeout(slot));

    try {
      const response = await fetch(url, {
        cache: "no-store",
        headers: { Accept: "text/html" },
        signal: controller ? controller.signal : undefined,
      });
      if (!response.ok) throw new Error("partial load failed");
      const html = (await response.text()).trim();
      if (!slot.isConnected) return;
      const parent = slot.parentElement;
      if (!html) {
        slot.remove();
        notifyPartialRefresh(parent);
        return;
      }

      const template = document.createElement("template");
      template.innerHTML = html;
      if (slot.hasAttribute("data-root-file-list")) clearRootFileListNotice(slot);
      slot.replaceWith(template.content);
      notifyPartialRefresh(parent);
    } catch (error) {
      if (!slot.isConnected) return;
      slot.dataset.rootPartialState = "error";
      slot.removeAttribute("aria-busy");
      if (handleRootFileListPartialError(slot, error)) return;
      if (slot.hasAttribute("data-root-partial-silent")) return;
      slot.replaceChildren(partialErrorNode(slot, error));
    } finally {
      window.clearTimeout(timeout);
    }
  }

  function initRootPartialTriggers(root) {
    const scope = root || document;
    scope.querySelectorAll("[data-root-partial-trigger]").forEach(function (button) {
      if (button.dataset.rootPartialTriggerReady === "yes") return;
      button.dataset.rootPartialTriggerReady = "yes";
      button.addEventListener("click", function () {
        const slot = button.closest("[data-root-partial-owner=\"gitomi\"]");
        if (slot) promoteDeferredRootPartial(slot);
      });
    });
  }

  function contributorAutoLoadLimit(slot) {
    const value = Number(slot.dataset.rootContributorsAutoSlocLimit);
    return Number.isFinite(value) && value >= 0 ? value : rootContributorLargeSlocThreshold;
  }

  function autoLoadContributorsForSmallRepo(root) {
    const scope = root || document;
    scope.querySelectorAll("[data-root-sloc-total]").forEach(function (marker) {
      const total = Number(marker.dataset.rootSlocTotal);
      if (!Number.isFinite(total) || total >= rootContributorLargeSlocThreshold) return;

      const container = marker.closest(".root-sidebar") || document;
      container.querySelectorAll("[data-root-contributors-slot][data-root-partial-deferred]").forEach(function (slot) {
        if (total < contributorAutoLoadLimit(slot)) promoteDeferredRootPartial(slot);
      });
    });
  }

  function initRootPartials(root) {
    const scope = root || document;
    initRootPartialTriggers(scope);
    autoLoadContributorsForSmallRepo(scope);
    scope.querySelectorAll("[data-root-partial-owner=\"gitomi\"][data-root-partial]").forEach(function (slot) {
      scheduleRootPartial(slot, false);
    });
  }

  function initCodeControls() {
    initRightPanelOffsets();
    initCopyButtons();
    initPathCopyButtons();
    initTextCopyButtons();
    initCodeLineActionControls();
    initSymbolsToggles();
    initRootSidebarScroll(document);
    initRootPartials(document);
  }

  document.addEventListener("gitomi:partial-refresh", function (event) {
    const detail = event.detail || {};
    initRootSidebarScroll(document);
    window.requestAnimationFrame(function () {
      syncRootSidebars(document);
    });
    initRootPartials(detail.root || document);
  });

  document.addEventListener("gitomi:root-partial-load", function (event) {
    const detail = event.detail || {};
    const scope = detail.root || document;
    scope.querySelectorAll("[data-root-partial-owner=\"gitomi\"][data-root-partial-deferred]").forEach(promoteDeferredRootPartial);
  });

  window.addEventListener("resize", function () {
    syncRootSidebars(document);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initCodeControls);
  } else {
    initCodeControls();
  }
})();
