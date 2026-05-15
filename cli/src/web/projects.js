(function () {
  const cardSelector = "[data-project-card]";
  const columnSelector = "[data-project-column]";
  let activeCard = null;

  function closestColumn(target) {
    return target instanceof Element ? target.closest(columnSelector) : null;
  }

  function clearDropTargets() {
    document.querySelectorAll(columnSelector + ".is-drop-target").forEach(function (column) {
      column.classList.remove("is-drop-target");
    });
  }

  function setBoardBusy(card, busy) {
    const board = card && card.closest(".kanban-board");
    if (board) board.classList.toggle("is-updating", busy);
  }

  function postMove(card, targetColumn) {
    const project = card.getAttribute("data-project") || "";
    const issue = card.getAttribute("data-issue-id") || card.getAttribute("data-issue-ref") || "";
    const fromColumn = card.getAttribute("data-column") || "";
    const toColumn = targetColumn.getAttribute("data-column") || "";
    if (!project || !issue || fromColumn === toColumn) return;

    const form = new FormData();
    form.set("action", "move");
    form.set("project", project);
    form.set("issue", issue);
    form.set("from_column", fromColumn);
    form.set("column", toColumn);
    form.set("view", "board");
    form.set("request_mode", "async");

    setBoardBusy(card, true);
    fetch("/projects/items", {
      method: "POST",
      body: form,
      credentials: "same-origin",
    }).then(function (response) {
      if (response.ok) {
        window.location.reload();
        return;
      }
      return response.text().then(function (message) {
        throw new Error(message || "Could not move issue");
      });
    }).catch(function (error) {
      window.alert(error && error.message ? error.message : "Could not move issue");
      setBoardBusy(card, false);
    });
  }

  function initCard(card) {
    if (card.dataset.projectDragReady === "yes") return;
    card.dataset.projectDragReady = "yes";

    card.addEventListener("dragstart", function (event) {
      if (event.target instanceof Element && event.target.closest("a, button, input, select, textarea, summary")) {
        event.preventDefault();
        return;
      }
      activeCard = card;
      card.classList.add("is-dragging");
      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", card.getAttribute("data-issue-id") || "");
      }
    });

    card.addEventListener("dragend", function () {
      card.classList.remove("is-dragging");
      activeCard = null;
      clearDropTargets();
    });
  }

  function initColumn(column) {
    if (column.dataset.projectDropReady === "yes") return;
    column.dataset.projectDropReady = "yes";

    column.addEventListener("dragover", function (event) {
      if (!activeCard) return;
      const targetColumn = closestColumn(event.target);
      if (!targetColumn || targetColumn.getAttribute("data-column") === activeCard.getAttribute("data-column")) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
      clearDropTargets();
      targetColumn.classList.add("is-drop-target");
    });

    column.addEventListener("drop", function (event) {
      if (!activeCard) return;
      const targetColumn = closestColumn(event.target);
      if (!targetColumn) return;
      event.preventDefault();
      clearDropTargets();
      postMove(activeCard, targetColumn);
    });
  }

  function activeProjectTabId(root) {
    const hash = window.location.hash && window.location.hash.charAt(0) === "#" ? window.location.hash.slice(1) : "";
    let matched = "";
    root.querySelectorAll("[data-project-index-panel]").forEach(function (panel) {
      if (panel.id === hash) matched = panel.id;
    });
    return matched || "projects";
  }

  function syncProjectIndexTabs(root) {
    const activeId = activeProjectTabId(root);
    root.querySelectorAll("[data-project-index-tab]").forEach(function (tab) {
      const selected = tab.getAttribute("data-project-index-tab") === activeId;
      tab.classList.toggle("active", selected);
      tab.setAttribute("aria-selected", selected ? "true" : "false");
      if (selected) {
        tab.setAttribute("aria-current", "page");
      } else {
        tab.removeAttribute("aria-current");
      }
    });
    root.querySelectorAll("[data-project-index-panel]").forEach(function (panel) {
      panel.hidden = panel.id !== activeId;
    });
  }

  function initProjectIndexTabs() {
    document.querySelectorAll("[data-project-index-tabs]").forEach(function (root) {
      if (root.dataset.projectIndexTabsReady === "yes") return;
      root.dataset.projectIndexTabsReady = "yes";

      root.querySelectorAll("[data-project-index-tab]").forEach(function (tab) {
        tab.addEventListener("click", function () {
          window.setTimeout(function () {
            syncProjectIndexTabs(root);
          }, 0);
        });
      });
      window.addEventListener("hashchange", function () {
        syncProjectIndexTabs(root);
      });
      syncProjectIndexTabs(root);
    });
  }

  function initProjects() {
    initProjectIndexTabs();
    document.querySelectorAll(cardSelector).forEach(initCard);
    document.querySelectorAll(columnSelector).forEach(initColumn);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initProjects);
  } else {
    initProjects();
  }
}());
