(function () {
  "use strict";

  const treeCollapsedKey = "gitomi.treeSidebarCollapsed";
  const treeWidthKey = "gitomi.treeSidebarWidth";
  const minTreeWidth = 220;
  const maxTreeWidth = 520;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function setTreeWidth(layout, width) {
    const next = clamp(width, minTreeWidth, Math.min(maxTreeWidth, Math.max(minTreeWidth, window.innerWidth - 520)));
    layout.style.setProperty("--tree-width", `${next}px`);
    try {
      window.localStorage.setItem(treeWidthKey, String(next));
    } catch (_) {}
  }

  function initTreeResize(sidebar) {
    const handle = sidebar.querySelector("[data-tree-resizer]");
    const layout = sidebar.closest(".code-layout");
    if (!handle || !layout) return;

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
    const button = sidebar.querySelector("[data-tree-collapse]");
    if (!button) return;
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

  function fuzzyMatch(text, token) {
    if (token === "") return true;
    if (text.includes(token)) return true;
    if (token.length > text.length) return false;

    let tokenIndex = 0;
    for (let i = 0; i < text.length && tokenIndex < token.length; i += 1) {
      if (text.charCodeAt(i) === token.charCodeAt(tokenIndex)) tokenIndex += 1;
    }
    return tokenIndex === token.length;
  }

  function itemMatchesSearch(item, tokens) {
    if (tokens.length === 0) return false;
    return tokens.every((token) => fuzzyMatch(item.name, token) || fuzzyMatch(item.path, token));
  }

  function initTree(nav) {
    const nodes = Array.from(nav.querySelectorAll("[data-tree-path]"));
    const byPath = new Map();
    const items = nodes.map((node) => {
      const path = (node.dataset.treePath || "").toLowerCase();
      const slash = path.lastIndexOf("/");
      const name = slash === -1 ? path : path.slice(slash + 1);
      const item = {
        node,
        path,
        name,
        parentPath: (node.dataset.treeParent || "").toLowerCase(),
        parent: null,
        matched: false,
        descendantMatched: false,
        visible: false,
      };
      byPath.set(path, item);
      return item;
    });
    items.forEach((item) => {
      item.parent = byPath.get(item.parentPath) || null;
    });
    const itemsByDepth = items.slice().sort((a, b) => b.path.length - a.path.length);

    let activeTokens = [];
    let syncFrame = 0;

    function syncVisibility() {
      const searching = activeTokens.length !== 0;

      if (searching) {
        items.forEach((item) => {
          item.matched = item.path !== "" && itemMatchesSearch(item, activeTokens);
          item.descendantMatched = false;
        });
        itemsByDepth.forEach((item) => {
          if ((item.matched || item.descendantMatched) && item.parent) {
            item.parent.descendantMatched = true;
          }
        });
      }

      items.forEach((item) => {
        let show = false;
        if (item.path === "") {
          show = true;
        } else if (searching) {
          show = item.matched || item.descendantMatched;
        } else {
          const parentVisible = item.parent ? item.parent.visible : true;
          const parentExpanded = item.parent ? item.parent.node.classList.contains("expanded") : true;
          show = parentVisible && parentExpanded;
        }
        item.visible = show;
        item.node.hidden = !show;
        item.node.classList.toggle("collapsed-child", !show);
        item.node.classList.toggle("search-match", searching && item.matched);
      });
    }

    function scheduleVisibilitySync() {
      if (syncFrame !== 0) return;
      syncFrame = window.requestAnimationFrame(() => {
        syncFrame = 0;
        syncVisibility();
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
      search.addEventListener("input", () => {
        activeTokens = searchTokens(search.value);
        scheduleVisibilitySync();
      });
    }
  }

  function initRootFileSearch(input) {
    const panel = input.closest(".root-page-main") || document;
    const rows = Array.from(panel.querySelectorAll("[data-root-file-row]"));
    const items = rows.map((row) => ({
      row,
      name: (row.dataset.rootFileName || "").toLowerCase(),
      path: (row.dataset.rootFilePath || "").toLowerCase(),
    }));
    const sync = () => {
      const tokens = searchTokens(input.value);
      items.forEach((item) => {
        item.row.hidden = tokens.length !== 0 && !itemMatchesSearch(item, tokens);
      });
    };
    input.addEventListener("input", sync);
    input.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      const firstItem = items.find((item) => !item.row.hidden);
      const first = firstItem ? firstItem.row : null;
      const link = first ? first.querySelector("a[href]") : null;
      if (link) link.click();
    });
    sync();
  }

  function initRootFileSearchShortcut(input) {
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

  function initTrees() {
    document.querySelectorAll("[data-tree-nav]").forEach(initTree);
    document.querySelectorAll("[data-tree-sidebar]").forEach((sidebar) => {
      initTreeCollapse(sidebar);
      initTreeResize(sidebar);
    });
    document.querySelectorAll("[data-branch-switcher]").forEach(initBranchSwitcher);
    document.querySelectorAll("[data-root-file-search]").forEach((input) => {
      initRootFileSearch(input);
      initRootFileSearchShortcut(input);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initTrees);
  } else {
    initTrees();
  }
})();
