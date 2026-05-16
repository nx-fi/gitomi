(function () {
  const cardSelector = "[data-project-card]";
  const columnSelector = "[data-project-column]";
  const dropzoneSelector = "[data-project-dropzone]";
  const maxIssueSearchResults = 30;
  let activeCard = null;
  let activeOrigin = null;
  let activeDropped = false;

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

  function restoreCard(card, origin) {
    if (!card || !origin || !origin.parent) return;
    if (origin.next && origin.next.parentElement === origin.parent) {
      origin.parent.insertBefore(card, origin.next);
    } else {
      origin.parent.appendChild(card);
    }
    card.setAttribute("data-column", origin.column || "");
  }

  function cardAfterPointer(dropzone, y) {
    const cards = Array.from(dropzone.querySelectorAll(cardSelector + ":not(.is-dragging)"));
    let closest = { offset: Number.NEGATIVE_INFINITY, node: null };
    cards.forEach(function (card) {
      const rect = card.getBoundingClientRect();
      const offset = y - rect.top - rect.height / 2;
      if (offset < 0 && offset > closest.offset) {
        closest = { offset: offset, node: card };
      }
    });
    return closest.node;
  }

  function placeActiveCard(targetColumn, y) {
    if (!activeCard || !targetColumn) return;
    const dropzone = targetColumn.querySelector(dropzoneSelector);
    if (!dropzone) return;
    dropzone.querySelectorAll(".kanban-empty-drop").forEach(function (empty) {
      empty.remove();
    });
    dropzone.insertBefore(activeCard, cardAfterPointer(dropzone, y));
  }

  function postMove(card, targetColumn, origin) {
    const board = targetColumn.closest(".kanban-board") || card.closest(".kanban-board");
    const project = card.getAttribute("data-project") || targetColumn.getAttribute("data-project") || (board ? board.getAttribute("data-project") : "") || "";
    const issue = card.getAttribute("data-issue-id") || card.getAttribute("data-issue-ref") || "";
    const fromColumn = (origin && origin.column) || card.getAttribute("data-column") || "";
    const toColumn = targetColumn.getAttribute("data-column") || "";
    if (fromColumn === toColumn) return;
    if (!project || !issue || !toColumn) {
      restoreCard(card, origin);
      return;
    }

    const form = new URLSearchParams();
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
      headers: {
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      },
    }).then(function (response) {
      if (response.ok) {
        window.location.reload();
        return;
      }
      return response.text().then(function (message) {
        throw new Error(message || "Could not move issue");
      });
    }).catch(function (error) {
      restoreCard(card, origin);
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
      activeOrigin = {
        parent: card.parentElement,
        next: card.nextElementSibling,
        column: card.getAttribute("data-column") || "",
      };
      activeDropped = false;
      card.classList.add("is-dragging");
      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", card.getAttribute("data-issue-id") || "");
      }
    });

    card.addEventListener("dragend", function () {
      if (!activeDropped) restoreCard(card, activeOrigin);
      card.classList.remove("is-dragging");
      activeCard = null;
      activeOrigin = null;
      activeDropped = false;
      clearDropTargets();
    });
  }

  function initColumn(column) {
    if (column.dataset.projectDropReady === "yes") return;
    column.dataset.projectDropReady = "yes";

    column.addEventListener("dragover", function (event) {
      if (!activeCard) return;
      const targetColumn = closestColumn(event.target);
      if (!targetColumn) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
      clearDropTargets();
      targetColumn.classList.add("is-drop-target");
      placeActiveCard(targetColumn, event.clientY);
    });

    column.addEventListener("drop", function (event) {
      if (!activeCard) return;
      const targetColumn = closestColumn(event.target) || activeCard.closest(columnSelector);
      if (!targetColumn) return;
      event.preventDefault();
      clearDropTargets();
      activeDropped = true;
      postMove(activeCard, targetColumn, activeOrigin);
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
    let score = 0;
    tokens.forEach(function (token) {
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

  function rankedSearchItems(items, tokens, limit) {
    if (tokens.length === 0) return [];
    return items
      .map(function (item) {
        return { item: item, score: scoreSearchItem(item, tokens) };
      })
      .filter(function (result) {
        return result.score !== null;
      })
      .sort(function (a, b) {
        return a.score - b.score ||
          a.item.searchPath.length - b.item.searchPath.length ||
          a.item.searchPath.localeCompare(b.item.searchPath);
      })
      .slice(0, limit);
  }

  function appendHighlightedText(parent, text, tokens) {
    const lower = text.toLowerCase();
    const ranges = [];

    tokens.forEach(function (token) {
      if (!token) return;
      let start = lower.indexOf(token);
      while (start !== -1) {
        ranges.push({ start: start, end: start + token.length });
        start = lower.indexOf(token, start + token.length);
      }
    });

    ranges.sort(function (a, b) {
      return a.start - b.start || b.end - a.end;
    });

    let cursor = 0;
    ranges.forEach(function (range) {
      if (range.start < cursor) return;
      if (range.start > cursor) {
        parent.appendChild(document.createTextNode(text.slice(cursor, range.start)));
      }
      const mark = document.createElement("mark");
      mark.textContent = text.slice(range.start, range.end);
      parent.appendChild(mark);
      cursor = range.end;
    });

    if (cursor < text.length) {
      parent.appendChild(document.createTextNode(text.slice(cursor)));
    }
  }

  function issueSearchItems() {
    return Array.from(document.querySelectorAll("[data-project-issue-search-item]")).map(function (node) {
      const ref = node.dataset.issueRef || "";
      const title = node.dataset.issueTitle || "";
      const state = node.dataset.issueState || "";
      const priority = node.dataset.issuePriority || "";
      const status = node.dataset.issueStatus || "";
      const display = node.dataset.issueDisplay || ref;
      const meta = [display, status, priority, state].filter(Boolean).join(" ");
      const path = [meta, title].filter(Boolean).join(" ");
      return {
        ref: ref,
        name: [display, title].filter(Boolean).join(" "),
        path: path,
        searchName: [display, title].join(" ").toLowerCase(),
        searchPath: path.toLowerCase(),
      };
    });
  }

  function initIssueSearchMenu(input) {
    if (input.dataset.projectIssueSearchReady === "yes") return;
    input.dataset.projectIssueSearchReady = "yes";

    const label = input.closest(".tree-search-label") || input.parentElement;
    const container = input.closest(".tree-search-wrap") || label;
    if (!container) return;

    const menu = document.createElement("div");
    const menuId = "project-issue-search-menu-" + Math.random().toString(36).slice(2);
    menu.id = menuId;
    menu.className = "tree-search-menu project-issue-search-menu";
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
      Array.from(menu.querySelectorAll(".tree-search-result")).forEach(function (node, i) {
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

    function selectResult(result) {
      if (!result) return;
      input.value = result.item.ref;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      setMenuOpen(false);
      input.focus();
      input.select();
    }

    function renderResults() {
      renderFrame = 0;
      const tokens = searchTokens(input.value);
      results = rankedSearchItems(issueSearchItems(), tokens, maxIssueSearchResults);
      menu.textContent = "";

      if (tokens.length === 0) {
        setMenuOpen(false);
        return;
      }

      if (results.length === 0) {
        const empty = document.createElement("div");
        empty.className = "tree-search-empty";
        empty.textContent = "No matching issues";
        menu.appendChild(empty);
        setMenuOpen(true);
        setActiveIndex(-1);
        return;
      }

      results.forEach(function (result, index) {
        const item = result.item;
        const button = document.createElement("button");
        button.id = menuId + "-result-" + index;
        button.className = "tree-search-result project-issue-search-result";
        button.type = "button";
        button.setAttribute("role", "option");
        button.setAttribute("aria-selected", "false");
        button.tabIndex = -1;
        button.dataset.index = String(index);

        const name = document.createElement("span");
        name.className = "tree-search-result-name";
        appendHighlightedText(name, item.name, tokens);
        button.appendChild(name);

        const path = document.createElement("span");
        path.className = "tree-search-result-path";
        appendHighlightedText(path, item.path, tokens);
        button.appendChild(path);

        menu.appendChild(button);
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
    input.addEventListener("focus", function () {
      if (searchTokens(input.value).length !== 0) scheduleRender();
    });
    input.addEventListener("keydown", function (event) {
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
      if (event.key === "Enter" && !menu.hidden) {
        flushRender();
        const result = results[activeIndex] || results[0];
        if (!result) return;
        event.preventDefault();
        selectResult(result);
      }
    });

    menu.addEventListener("mousemove", function (event) {
      const button = event.target.closest(".tree-search-result");
      if (!button || !menu.contains(button)) return;
      setActiveIndex(Number(button.dataset.index));
    });
    menu.addEventListener("click", function (event) {
      const button = event.target.closest(".tree-search-result");
      if (!button || !menu.contains(button)) return;
      selectResult(results[Number(button.dataset.index)]);
    });
    document.addEventListener("click", function (event) {
      if (container.contains(event.target)) return;
      setMenuOpen(false);
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
    document.querySelectorAll("[data-project-issue-search]").forEach(initIssueSearchMenu);
    document.querySelectorAll(cardSelector).forEach(initCard);
    document.querySelectorAll(columnSelector).forEach(initColumn);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initProjects);
  } else {
    initProjects();
  }
}());
