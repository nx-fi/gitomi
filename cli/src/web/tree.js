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

  function nodeMatchesSearch(node, query) {
    if (!query) return false;
    const path = (node.dataset.treePath || "").toLowerCase();
    return path.includes(query);
  }

  function initTree(nav) {
    const nodes = Array.from(nav.querySelectorAll("[data-tree-path]"));
    const byPath = new Map();
    nodes.forEach((node) => {
      byPath.set(node.dataset.treePath || "", node);
    });

    let searchQuery = "";

    function syncVisibility() {
      const visible = new Map();
      nodes.forEach((node) => {
        const path = node.dataset.treePath || "";
        if (path === "") {
          node.hidden = false;
          visible.set(path, true);
          return;
        }

        const parent = byPath.get(node.dataset.treeParent || "");
        const parentPath = parent ? parent.dataset.treePath || "" : "";
        const parentVisible = parent ? visible.get(parentPath) !== false : true;
        const parentExpanded = parent ? parent.classList.contains("expanded") : true;
        let show = parentVisible && parentExpanded;
        if (searchQuery) {
          const selfMatch = nodeMatchesSearch(node, searchQuery);
          const descendantMatch = nodes.some((candidate) => {
            const candidatePath = candidate.dataset.treePath || "";
            return candidatePath.startsWith(path + "/") && nodeMatchesSearch(candidate, searchQuery);
          });
          const ancestorMatch = nodes.some((candidate) => {
            const candidatePath = candidate.dataset.treePath || "";
            return nodeMatchesSearch(candidate, searchQuery) && path !== "" && candidatePath.startsWith(path + "/");
          });
          show = selfMatch || descendantMatch || ancestorMatch;
        }
        node.hidden = !show;
        node.classList.toggle("collapsed-child", !show);
        node.classList.toggle("search-match", searchQuery !== "" && nodeMatchesSearch(node, searchQuery));
        visible.set(path, show);
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
        searchQuery = search.value.trim().toLowerCase();
        syncVisibility();
      });
    }
  }

  function initTrees() {
    document.querySelectorAll("[data-tree-nav]").forEach(initTree);
    document.querySelectorAll("[data-tree-sidebar]").forEach((sidebar) => {
      initTreeCollapse(sidebar);
      initTreeResize(sidebar);
    });
    document.querySelectorAll("[data-branch-switcher]").forEach(initBranchSwitcher);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initTrees);
  } else {
    initTrees();
  }
})();
