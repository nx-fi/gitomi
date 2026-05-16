(function () {
  "use strict";

  const treeCollapsedKey = "gitomi.treeSidebarCollapsed";
  const treeWidthKey = "gitomi.treeSidebarWidth";
  const minTreeWidth = 220;
  const maxTreeWidth = 520;
  const maxTreeSearchResults = 30;
  const rootFileNameColumnMin = 118;
  const treeFileNameColumnMin = 150;
  let measureContext = null;
  let fileListLayoutBound = false;
  let fileListLayoutScheduled = false;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function inlineMeasureContext() {
    if (measureContext) return measureContext;
    const canvas = document.createElement("canvas");
    measureContext = canvas.getContext("2d");
    return measureContext;
  }

  function naturalFileNameWidth(name) {
    const context = inlineMeasureContext();
    if (!context) return Math.ceil(name.getBoundingClientRect().width || name.scrollWidth);

    const style = window.getComputedStyle(name);
    context.font = style.font || `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;

    const icon = name.querySelector(".file-icon");
    const iconWidth = icon ? (icon.getBoundingClientRect().width || 18) : 0;
    const gap = icon ? (parseFloat(style.columnGap || style.gap || "0") || 0) : 0;
    return Math.ceil(context.measureText((name.textContent || "").trim()).width + iconWidth + gap);
  }

  function measureNameColumn(list, rowSelector, nameSelector, property, minWidth, maxShare) {
    const rows = Array.from(list.querySelectorAll(rowSelector));
    if (rows.length === 0) return;

    let measured = minWidth;
    rows.forEach((row) => {
      if (row.hidden) return;
      const name = row.querySelector(nameSelector);
      if (!name) return;
      measured = Math.max(measured, naturalFileNameWidth(name));
    });

    const listWidth = list.getBoundingClientRect().width || list.clientWidth;
    if (!listWidth) return;

    const maxWidth = Math.max(minWidth, Math.floor(listWidth * maxShare));
    list.style.setProperty(property, `${clamp(measured + 2, minWidth, maxWidth)}px`);
  }

  function syncMeasuredFileColumns() {
    document.querySelectorAll(".root-file-list").forEach((list) => {
      measureNameColumn(
        list,
        ".root-file-row",
        ".root-file-name",
        "--root-file-name-width",
        rootFileNameColumnMin,
        0.42,
      );
    });
    document.querySelectorAll(".file-list").forEach((list) => {
      measureNameColumn(
        list,
        ".file-row",
        ".file-name",
        "--file-list-name-width",
        treeFileNameColumnMin,
        0.46,
      );
    });
  }

  function commitTextWidth(element) {
    const bounds = element.getBoundingClientRect();
    if (bounds.width > 0) return Math.floor(bounds.width);
    const parent = element.closest(".file-commit");
    if (!parent) return 0;
    return Math.floor(parent.getBoundingClientRect().width);
  }

  function fullCommitText(element) {
    if (!element.dataset.fullCommitText) {
      element.dataset.fullCommitText = element.textContent || "";
    }
    return element.dataset.fullCommitText;
  }

  function truncateCommitText(element) {
    const full = fullCommitText(element);
    if (full.length === 0) return;

    element.textContent = full;
    const maxWidth = commitTextWidth(element);
    if (maxWidth <= 0 || element.scrollWidth <= maxWidth + 1) return;

    const suffix = "...";
    let low = 0;
    let high = full.length;
    while (low < high) {
      const mid = Math.ceil((low + high) / 2);
      element.textContent = full.slice(0, mid).trimEnd() + suffix;
      if (element.scrollWidth <= maxWidth + 1) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }

    const prefix = full.slice(0, low).trimEnd();
    element.textContent = prefix.length === 0 ? suffix : prefix + suffix;
  }

  function syncCommitTruncation() {
    document
      .querySelectorAll(".root-commit-message, a.root-file-commit, .file-commit:not(.worktree-change) a, .commit-bar strong a")
      .forEach(truncateCommitText);
  }

  function syncFileListLayout() {
    syncMeasuredFileColumns();
    syncCommitTruncation();
  }

  function scheduleFileListLayout() {
    if (fileListLayoutScheduled) return;
    fileListLayoutScheduled = true;
    window.requestAnimationFrame(() => {
      fileListLayoutScheduled = false;
      syncFileListLayout();
    });
  }

  function initFileListLayout() {
    syncFileListLayout();
    if (fileListLayoutBound) return;
    fileListLayoutBound = true;
    window.addEventListener("resize", scheduleFileListLayout);
    window.addEventListener("load", scheduleFileListLayout);
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(scheduleFileListLayout).catch(() => {});
    }
  }

  function setTreeWidth(layout, width) {
    const next = clamp(width, minTreeWidth, Math.min(maxTreeWidth, Math.max(minTreeWidth, window.innerWidth - 520)));
    layout.style.setProperty("--tree-width", `${next}px`);
    try {
      window.localStorage.setItem(treeWidthKey, String(next));
    } catch (_) {}
  }

  function initTreeResize(sidebar) {
    if (sidebar.dataset.treeResizeReady === "yes") return;
    const handle = sidebar.querySelector("[data-tree-resizer]");
    const layout = sidebar.closest(".code-layout");
    if (!handle || !layout) return;
    sidebar.dataset.treeResizeReady = "yes";

    try {
      const stored = Number(window.localStorage.getItem(treeWidthKey));
      if (Number.isFinite(stored) && stored > 0) {
        layout.style.setProperty("--tree-width", `${clamp(stored, minTreeWidth, maxTreeWidth)}px`);
      }
    } catch (_) {}

    handle.addEventListener("pointerdown", (event) => {
      if (layout.classList.contains("tree-collapsed")) return;
      event.preventDefault();
      handle.setPointerCapture(event.pointerId);
      document.documentElement.classList.add("tree-resizing");

      const onMove = (moveEvent) => {
        const left = layout.getBoundingClientRect().left;
        setTreeWidth(layout, moveEvent.clientX - left);
      };
      const onUp = () => {
        document.documentElement.classList.remove("tree-resizing");
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onUp);
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp, { once: true });
    });
  }

  function setTreeCollapsed(sidebar, collapsed, persist) {
    const layout = sidebar.closest(".code-layout");
    const button = sidebar.querySelector("[data-tree-collapse]");
    sidebar.classList.toggle("collapsed", collapsed);
    if (layout) layout.classList.toggle("tree-collapsed", collapsed);
    if (button) {
      button.setAttribute("aria-expanded", String(!collapsed));
      button.setAttribute("aria-label", collapsed ? "Expand files panel" : "Collapse files panel");
      button.title = collapsed ? "Expand files panel" : "Collapse files panel";
    }
    if (persist) {
      try {
        window.localStorage.setItem(treeCollapsedKey, collapsed ? "true" : "false");
      } catch (_) {}
    }
  }

  function initTreeCollapse(sidebar) {
    if (sidebar.dataset.treeCollapseReady === "yes") return;
    const button = sidebar.querySelector("[data-tree-collapse]");
    if (!button) return;
    sidebar.dataset.treeCollapseReady = "yes";
    let collapsed = false;
    try {
      collapsed = window.localStorage.getItem(treeCollapsedKey) === "true";
    } catch (_) {}
    setTreeCollapsed(sidebar, collapsed, false);
    button.addEventListener("click", () => {
      setTreeCollapsed(sidebar, !sidebar.classList.contains("collapsed"), true);
    });
  }

  function initBranchSwitcher(select) {
    if (select.dataset.branchSwitcherReady === "yes") return;
    select.dataset.branchSwitcherReady = "yes";
    select.addEventListener("change", () => {
      const ref = select.value;
      if (!ref) return;
      const params = new URLSearchParams();
      params.set("ref", ref);
      const path = select.dataset.activePath || "";
      if (path) params.set("path", path);
      window.location.href = `/code?${params.toString()}`;
    });
  }

  function searchTokens(value) {
    return value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  }

  function fuzzyScore(text, token) {
    if (token === "") return 0;
    if (text === token) return 0;
    if (text.startsWith(token)) return 20 + text.length - token.length;

    const exactIndex = text.indexOf(token);
    if (exactIndex !== -1) return 45 + exactIndex * 2 + text.length - token.length;
    if (token.length > text.length) return null;

    let first = -1;
    let last = -1;
    let tokenIndex = 0;
    for (let i = 0; i < text.length && tokenIndex < token.length; i += 1) {
      if (text.charCodeAt(i) === token.charCodeAt(tokenIndex)) {
        if (first === -1) first = i;
        last = i;
        tokenIndex += 1;
      }
    }
    if (tokenIndex !== token.length) return null;

    const spread = last - first + 1 - token.length;
    return 90 + first * 3 + spread * 5 + text.length;
  }

  function scoreSearchItem(item, tokens) {
    if (tokens.length === 0) return null;
    let score = item.kind === "tree" ? 8 : 0;
    tokens.forEach((token) => {
      if (score === null) return;
      const nameScore = fuzzyScore(item.searchName, token);
      const pathScore = fuzzyScore(item.searchPath, token);
      if (nameScore === null && pathScore === null) {
        score = null;
      } else {
        score += Math.min(
          nameScore === null ? Number.POSITIVE_INFINITY : nameScore,
          pathScore === null ? Number.POSITIVE_INFINITY : pathScore + 12,
        );
      }
    });
    return score;
  }

  function itemMatchesSearch(item, tokens) {
    return scoreSearchItem(item, tokens) !== null;
  }

  function rankedSearchItems(items, tokens, limit) {
    const currentItems = typeof items === "function" ? items() : items;
    if (tokens.length === 0) return [];
    return currentItems
      .map((item) => ({ item, score: item.path === "" ? null : scoreSearchItem(item, tokens) }))
      .filter((result) => result.score !== null)
      .sort((a, b) => (
        a.score - b.score ||
        a.item.searchPath.length - b.item.searchPath.length ||
        a.item.searchPath.localeCompare(b.item.searchPath)
      ))
      .slice(0, limit);
  }

  function appendHighlightedText(parent, text, tokens) {
    const lower = text.toLowerCase();
    const ranges = [];

    tokens.forEach((token) => {
      if (!token) return;
      let start = lower.indexOf(token);
      while (start !== -1) {
        ranges.push({ start, end: start + token.length });
        start = lower.indexOf(token, start + token.length);
      }
    });

    ranges.sort((a, b) => a.start - b.start || b.end - a.end);

    let cursor = 0;
    ranges.forEach((range) => {
      if (range.start < cursor) return;
      if (range.start > cursor) {
        parent.appendChild(document.createTextNode(text.slice(cursor, range.start)));
      }

      const mark = document.createElement("mark");
      mark.textContent = text.slice(range.start, range.end);
      parent.appendChild(mark);
      cursor = range.end;
    });

    if (cursor < text.length) parent.appendChild(document.createTextNode(text.slice(cursor)));
  }

  function initTree(nav) {
    if (nav.dataset.treeReady === "yes") return;
    nav.dataset.treeReady = "yes";
    const nodes = Array.from(nav.querySelectorAll("[data-tree-path]"));
    const byPath = new Map();
    const items = nodes.map((node) => {
      const path = node.dataset.treePath || "";
      const searchPath = path.toLowerCase();
      const slash = path.lastIndexOf("/");
      const name = slash === -1 ? path : path.slice(slash + 1);
      const link = node.querySelector("a[href]");
      const item = {
        node,
        path,
        name,
        searchPath,
        searchName: name.toLowerCase(),
        href: link ? link.getAttribute("href") : "",
        kind: node.dataset.treeKind || "blob",
        parentPath: node.dataset.treeParent || "",
        parent: null,
        visible: false,
      };
      byPath.set(path, item);
      return item;
    });
    items.forEach((item) => {
      item.parent = byPath.get(item.parentPath) || null;
    });

    function syncVisibility() {
      items.forEach((item) => {
        let show = false;
        if (item.path === "") {
          show = true;
        } else {
          const parentVisible = item.parent ? item.parent.visible : true;
          const parentExpanded = item.parent ? item.parent.node.classList.contains("expanded") : true;
          show = parentVisible && parentExpanded;
        }
        item.visible = show;
        item.node.hidden = !show;
        item.node.classList.toggle("collapsed-child", !show);
        item.node.classList.remove("search-match");
      });
    }

    nav.addEventListener("click", (event) => {
      const toggle = event.target.closest("[data-tree-toggle]");
      if (!toggle || !nav.contains(toggle)) return;

      const node = toggle.closest("[data-tree-path]");
      if (!node) return;

      const expanded = !node.classList.contains("expanded");
      node.classList.toggle("expanded", expanded);
      toggle.setAttribute("aria-expanded", String(expanded));
      toggle.setAttribute("aria-label", expanded ? "Collapse folder" : "Expand folder");
      syncVisibility();
    });

    syncVisibility();

    const sidebar = nav.closest("[data-tree-sidebar]");
    const search = sidebar ? sidebar.querySelector("[data-tree-search]") : null;
    if (search) {
      initTreeSearchMenu(search, items);
    }
  }

  function initTreeSearchMenu(input, items) {
    const label = input.closest(".tree-search-label, .root-file-search") || input.parentElement;
    const container = input.closest(".tree-search-wrap, .root-file-search-wrap") || label;
    if (!container) return;

    const menu = document.createElement("div");
    const menuId = `tree-search-menu-${Math.random().toString(36).slice(2)}`;
    menu.id = menuId;
    menu.className = "tree-search-menu";
    menu.setAttribute("role", "listbox");
    menu.hidden = true;
    container.appendChild(menu);
    input.setAttribute("aria-autocomplete", "list");
    input.setAttribute("aria-controls", menuId);
    input.setAttribute("aria-expanded", "false");
    input.setAttribute("role", "combobox");

    let results = [];
    let activeIndex = -1;
    let renderFrame = 0;

    function setMenuOpen(open) {
      menu.hidden = !open;
      input.setAttribute("aria-expanded", String(open));
      if (!open) {
        activeIndex = -1;
        input.removeAttribute("aria-activedescendant");
      }
    }

    function setActiveIndex(index) {
      activeIndex = index;
      Array.from(menu.querySelectorAll(".tree-search-result")).forEach((node, i) => {
        const active = i === activeIndex;
        node.classList.toggle("active", active);
        node.setAttribute("aria-selected", String(active));
        if (active) {
          input.setAttribute("aria-activedescendant", node.id);
          node.scrollIntoView({ block: "nearest" });
        }
      });
      if (activeIndex === -1) input.removeAttribute("aria-activedescendant");
    }

    function renderResults() {
      renderFrame = 0;
      const tokens = searchTokens(input.value);
      results = rankedSearchItems(items, tokens, maxTreeSearchResults);
      menu.textContent = "";

      if (tokens.length === 0) {
        setMenuOpen(false);
        return;
      }

      if (results.length === 0) {
        const empty = document.createElement("div");
        empty.className = "tree-search-empty";
        empty.textContent = "No matching files";
        menu.appendChild(empty);
        setMenuOpen(true);
        setActiveIndex(-1);
        return;
      }

      results.forEach((result, index) => {
        const item = result.item;
        const link = document.createElement("a");
        link.id = `${menuId}-result-${index}`;
        link.className = "tree-search-result";
        link.href = item.href;
        link.setAttribute("role", "option");
        link.setAttribute("aria-selected", "false");
        link.tabIndex = -1;
        link.dataset.index = String(index);

        const name = document.createElement("span");
        name.className = "tree-search-result-name";
        appendHighlightedText(name, item.name, tokens);
        link.appendChild(name);

        const path = document.createElement("span");
        path.className = "tree-search-result-path";
        appendHighlightedText(path, item.path, tokens);
        link.appendChild(path);

        menu.appendChild(link);
      });
      setMenuOpen(true);
      setActiveIndex(0);
    }

    function scheduleRender() {
      if (renderFrame !== 0) return;
      renderFrame = window.requestAnimationFrame(renderResults);
    }

    function flushRender() {
      if (renderFrame === 0) return;
      window.cancelAnimationFrame(renderFrame);
      renderResults();
    }

    input.addEventListener("input", scheduleRender);
    input.addEventListener("focus", () => {
      if (searchTokens(input.value).length !== 0) scheduleRender();
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        setMenuOpen(false);
        return;
      }
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        flushRender();
        if (menu.hidden) renderResults();
        if (results.length === 0) return;
        event.preventDefault();
        const step = event.key === "ArrowDown" ? 1 : -1;
        setActiveIndex((activeIndex + step + results.length) % results.length);
        return;
      }
      if (event.key === "Enter") {
        flushRender();
        const result = results[activeIndex] || results[0];
        if (!result) return;
        event.preventDefault();
        window.location.href = result.item.href;
      }
    });

    menu.addEventListener("mousemove", (event) => {
      const link = event.target.closest(".tree-search-result");
      if (!link || !menu.contains(link)) return;
      setActiveIndex(Number(link.dataset.index));
    });
    document.addEventListener("click", (event) => {
      if (container.contains(event.target)) return;
      setMenuOpen(false);
    });
  }

  function rootFileSearchItems(panel) {
    const index = panel.querySelector("[data-root-file-search-index]");
    const nodes = index ? Array.from(index.querySelectorAll("[data-root-file-search-item]")) : [];
    const rows = nodes.length === 0 ? Array.from(panel.querySelectorAll("[data-root-file-row]")) : [];
    return nodes.length !== 0
      ? nodes.map((node) => {
        const path = node.dataset.rootFilePath || "";
        const slash = path.lastIndexOf("/");
        const name = node.dataset.rootFileName || (slash === -1 ? path : path.slice(slash + 1));
        return {
          node,
          path,
          name,
          searchPath: path.toLowerCase(),
          searchName: name.toLowerCase(),
          href: node.getAttribute("href") || "",
          kind: node.dataset.rootFileKind || "blob",
        };
      })
      : rows.map((row) => {
        const path = row.dataset.rootFilePath || "";
        const name = row.dataset.rootFileName || path;
        const link = row.querySelector("a[href]");
        return {
          node: row,
          path,
          name,
          searchPath: path.toLowerCase(),
          searchName: name.toLowerCase(),
          href: link ? link.getAttribute("href") : "",
          kind: row.dataset.rootFileKind || "blob",
        };
      });
  }

  function initRootFileSearch(input) {
    if (input.dataset.rootFileSearchReady === "yes") return;
    input.dataset.rootFileSearchReady = "yes";
    const panel = input.closest(".root-page-main") || document;
    initTreeSearchMenu(input, () => rootFileSearchItems(panel));
  }

  function initRootFileSearchShortcut(input) {
    if (input.dataset.rootFileSearchShortcutReady === "yes") return;
    input.dataset.rootFileSearchShortcutReady = "yes";
    document.addEventListener("keydown", (event) => {
      if (event.defaultPrevented || event.key.toLowerCase() !== "t") return;
      const target = event.target;
      const editing = target && (
        target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.tagName === "SELECT" ||
        target.isContentEditable
      );
      if (editing) return;
      event.preventDefault();
      input.focus();
      input.select();
    });
  }

  function initTrees(root) {
    const scope = root || document;
    scope.querySelectorAll("[data-tree-nav]").forEach(initTree);
    scope.querySelectorAll("[data-tree-sidebar]").forEach((sidebar) => {
      initTreeCollapse(sidebar);
      initTreeResize(sidebar);
    });
    scope.querySelectorAll("[data-branch-switcher]").forEach(initBranchSwitcher);
    scope.querySelectorAll("[data-root-file-search]").forEach((input) => {
      initRootFileSearch(input);
      initRootFileSearchShortcut(input);
    });
    initFileListLayout();
  }

  document.addEventListener("gitomi:partial-refresh", function (event) {
    const detail = event.detail || {};
    initTrees(detail.root || document);
    document.querySelectorAll("[data-root-file-search]").forEach((input) => {
      if (input.value) input.dispatchEvent(new Event("input", { bubbles: true }));
    });
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => initTrees());
  } else {
    initTrees();
  }
})();
