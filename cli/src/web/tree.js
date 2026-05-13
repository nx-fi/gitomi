(function () {
  "use strict";

  function initTree(nav) {
    const nodes = Array.from(nav.querySelectorAll("[data-tree-path]"));
    const byPath = new Map();
    nodes.forEach((node) => {
      byPath.set(node.dataset.treePath || "", node);
    });

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
        const show = parentVisible && parentExpanded;
        node.hidden = !show;
        node.classList.toggle("collapsed-child", !show);
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
  }

  function initTrees() {
    document.querySelectorAll("[data-tree-nav]").forEach(initTree);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initTrees);
  } else {
    initTrees();
  }
})();
