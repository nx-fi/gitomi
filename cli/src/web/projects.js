(function () {
  const cardSelector = "[data-project-card]";
  const columnSelector = "[data-project-column]";
  const dropzoneSelector = "[data-project-dropzone]";
  const datePickerSelector = "input[data-date-picker]";
  const maxIssueSearchResults = 30;
  const fuzzySearch = window.gitomiFuzzySearch;
  const searchTokens = fuzzySearch.searchTokens;
  const rankedSearchItems = fuzzySearch.rankedSearchItems;
  const appendHighlightedText = fuzzySearch.appendHighlightedText;
  let activeCard = null;
  let activeOrigin = null;
  let activeDropped = false;
  let activeDatePicker = null;

  function closestColumn(target) {
    return target instanceof Element ? target.closest(columnSelector) : null;
  }

  function scopedQuery(root, selector) {
    const scope = root || document;
    const nodes = [];
    if (scope instanceof Element && scope.matches(selector)) nodes.push(scope);
    if (!scope || typeof scope.querySelectorAll !== "function") return nodes;
    scope.querySelectorAll(selector).forEach(function (node) {
      nodes.push(node);
    });
    return nodes;
  }

  function clearDropTargets() {
    document.querySelectorAll(columnSelector + ".is-drop-target").forEach(function (column) {
      column.classList.remove("is-drop-target");
    });
  }

  function setBoardBusy(card, busy) {
    const board = card && card.closest(".kanban-board");
    if (!board) return;
    board.classList.toggle("is-updating", busy);
    if (busy) {
      board.setAttribute("aria-busy", "true");
      const status = ensureBoardStatus(board);
      status.hidden = false;
    } else {
      board.removeAttribute("aria-busy");
      const status = board.querySelector(".kanban-board-status");
      if (status) status.hidden = true;
    }
  }

  function ensureBoardStatus(board) {
    let status = board.querySelector(".kanban-board-status");
    if (status) return status;
    status = document.createElement("div");
    status.className = "kanban-board-status";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");

    const spinner = document.createElement("span");
    spinner.className = "kanban-board-spinner";
    spinner.setAttribute("aria-hidden", "true");

    const text = document.createElement("span");
    text.className = "kanban-board-status-text";
    text.textContent = "Moving issue...";

    status.appendChild(spinner);
    status.appendChild(text);
    board.appendChild(status);
    return status;
  }

  function notifyMoveError(message) {
    const text = String(message || "Could not move issue").replace(/\s+/g, " ").trim() || "Could not move issue";
    if (typeof window.gitomiNotify === "function") {
      window.gitomiNotify(text, "error");
    } else if (window.console && typeof window.console.error === "function") {
      window.console.error(text);
    }
  }

  function notifyPartialRefresh(root) {
    document.dispatchEvent(new CustomEvent("gitomi:partial-refresh", {
      detail: { root: root || document },
    }));
  }

  function columnFromDropzone(dropzone) {
    return dropzone && dropzone.closest ? dropzone.closest(columnSelector) : null;
  }

  function columnStatusLabel(column) {
    const title = column && column.querySelector(".kanban-column-title h2");
    return title && title.textContent.trim() || column && column.getAttribute("data-column") || "None";
  }

  function toneClass(node) {
    if (!node || !node.classList) return "";
    return Array.from(node.classList).find(function (name) {
      return /^tone-/.test(name);
    }) || "";
  }

  function setStatusChip(card, column) {
    const chip = card.querySelector(".project-status-chip");
    if (!chip) return;
    Array.from(chip.classList).forEach(function (name) {
      if (/^tone-/.test(name)) chip.classList.remove(name);
    });
    const tone = toneClass(column);
    if (tone) chip.classList.add(tone);

    let dot = chip.querySelector(".kanban-status-dot");
    if (!dot) {
      dot = document.createElement("span");
      dot.className = "kanban-status-dot";
      dot.setAttribute("aria-hidden", "true");
    }
    chip.textContent = "";
    chip.appendChild(dot);
    chip.appendChild(document.createTextNode(columnStatusLabel(column)));
  }

  function syncColumnState(column) {
    if (!column) return;
    const dropzone = column.querySelector(dropzoneSelector);
    if (!dropzone) return;
    const count = dropzone.querySelectorAll(cardSelector).length;
    const countNode = column.querySelector(".kanban-count");
    if (countNode) countNode.textContent = String(count);
    dropzone.querySelectorAll(".kanban-empty-drop").forEach(function (empty) {
      empty.remove();
    });
    if (count === 0) {
      const empty = document.createElement("div");
      empty.className = "kanban-empty-drop";
      empty.textContent = "No issues";
      dropzone.appendChild(empty);
    }
  }

  function commitMove(card, targetColumn, origin) {
    card.setAttribute("data-column", targetColumn.getAttribute("data-column") || "");
    setStatusChip(card, targetColumn);
    syncColumnState(columnFromDropzone(origin && origin.parent));
    syncColumnState(targetColumn);
    setBoardBusy(card, false);
    notifyPartialRefresh(targetColumn.closest(".kanban-board") || card);
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
      syncColumnState(columnFromDropzone(origin && origin.parent));
      syncColumnState(targetColumn);
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
      gitomiSuppressErrorNotification: true,
    }).then(function (response) {
      if (response.ok) {
        commitMove(card, targetColumn, origin);
        return;
      }
      return response.text().then(function (message) {
        throw new Error(message || "Could not move issue");
      });
    }).catch(function (error) {
      restoreCard(card, origin);
      syncColumnState(columnFromDropzone(origin && origin.parent));
      syncColumnState(targetColumn);
      notifyMoveError(error && error.message ? error.message : "Could not move issue");
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

  function appendSearchField(parts, name, value) {
    if (!value) return;
    parts.push(value);
    parts.push(name + ":" + value);
    value.trim().split(/\s+/).filter(Boolean).forEach(function (part) {
      parts.push(name + ":" + part);
    });
  }

  function issueSearchItems() {
    return Array.from(document.querySelectorAll("[data-project-issue-search-item]")).map(function (node) {
      const ref = node.dataset.issueRef || "";
      const title = node.dataset.issueTitle || "";
      const state = node.dataset.issueState || "";
      const priority = node.dataset.issuePriority || "";
      const status = node.dataset.issueStatus || "";
      const milestone = node.dataset.issueMilestone || "";
      const issueType = node.dataset.issueType || "";
      const labels = node.dataset.issueLabels || "";
      const assignees = node.dataset.issueAssignees || "";
      const display = node.dataset.issueDisplay || ref;
      const meta = [display, status, priority, state, issueType, milestone, labels, assignees].filter(Boolean).join(" ");
      const fieldSearch = [display];
      appendSearchField(fieldSearch, "state", state);
      if (state) fieldSearch.push("is:" + state);
      appendSearchField(fieldSearch, "priority", priority);
      appendSearchField(fieldSearch, "status", status);
      appendSearchField(fieldSearch, "type", issueType);
      appendSearchField(fieldSearch, "milestone", milestone);
      appendSearchField(fieldSearch, "label", labels);
      appendSearchField(fieldSearch, "assignee", assignees);
      const path = [meta, title].filter(Boolean).join(" ");
      return {
        ref: ref,
        name: [display, title].filter(Boolean).join(" "),
        path: path,
        searchName: [display, title].join(" ").toLowerCase(),
        searchPath: [path, fieldSearch.join(" ")].join(" ").toLowerCase(),
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

    const multi = input.hasAttribute("data-project-issue-multiple");
    const multiRoot = multi ? input.closest("[data-project-issue-multi-search]") : null;
    const tokenInput = multiRoot ? multiRoot.querySelector("[data-project-issue-token-input]") : null;
    const selectedRoot = multiRoot ? multiRoot.querySelector("[data-project-selected-issues]") : null;
    let results = [];
    let activeIndex = -1;
    let renderFrame = 0;

    function selectedIssueValues() {
      if (!selectedRoot) return [];
      return Array.from(selectedRoot.querySelectorAll("input[type='hidden'][name='issue']")).map(function (hidden) {
        return hidden.value || "";
      }).filter(Boolean);
    }

    function clearMultiValidity() {
      input.setCustomValidity("");
      if (tokenInput) tokenInput.classList.remove("is-invalid");
    }

    function updateMultiSearchState() {
      if (!multi) return;
      const hasSelection = selectedIssueValues().length > 0;
      input.placeholder = hasSelection ? "Search another issue" : "Search issues or paste a ref";
      if (tokenInput) tokenInput.classList.toggle("has-selection", hasSelection);
      if (hasSelection) clearMultiValidity();
    }

    function addIssueToken(item) {
      if (!multi || !selectedRoot || !item || !item.ref) return false;
      if (selectedIssueValues().indexOf(item.ref) !== -1) {
        clearMultiValidity();
        return false;
      }

      const token = document.createElement("span");
      token.className = "project-selected-issue";
      token.dataset.issueRef = item.ref;

      const hidden = document.createElement("input");
      hidden.type = "hidden";
      hidden.name = "issue";
      hidden.value = item.ref;
      token.appendChild(hidden);

      const label = document.createElement("span");
      label.className = "project-selected-issue-label";
      label.textContent = item.name || item.ref;
      token.appendChild(label);

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "project-selected-issue-remove";
      remove.setAttribute("aria-label", "Remove " + item.ref);
      const icon = document.createElement("span");
      icon.setAttribute("aria-hidden", "true");
      remove.appendChild(icon);
      remove.addEventListener("click", function (event) {
        event.preventDefault();
        event.stopPropagation();
        token.remove();
        updateMultiSearchState();
        setMenuOpen(false);
      });
      token.appendChild(remove);

      selectedRoot.appendChild(token);
      updateMultiSearchState();
      return true;
    }

    function addPendingInputValue() {
      if (!multi) return false;
      const ref = input.value.trim();
      if (!ref) return false;
      const lower = ref.toLowerCase();
      const match = issueSearchItems().find(function (item) {
        return item.ref.toLowerCase() === lower || item.name.toLowerCase() === lower;
      });
      const added = addIssueToken(match || { ref: ref, name: ref, path: ref });
      input.value = "";
      return added;
    }

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
      if (multi) {
        addIssueToken(result.item);
        input.value = "";
        if (renderFrame !== 0) {
          window.cancelAnimationFrame(renderFrame);
          renderFrame = 0;
        }
        setMenuOpen(false);
        input.blur();
        return;
      }
      input.value = result.item.ref;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      if (renderFrame !== 0) {
        window.cancelAnimationFrame(renderFrame);
        renderFrame = 0;
      }
      setMenuOpen(false);
      input.focus();
      input.select();
    }

    function renderResults() {
      renderFrame = 0;
      const tokens = searchTokens(input.value);
      let items = issueSearchItems();
      if (multi) {
        const selected = selectedIssueValues();
        items = items.filter(function (item) {
          return selected.indexOf(item.ref) === -1;
        });
      }
      results = rankedSearchItems(items, tokens, maxIssueSearchResults, { includeEmpty: true });
      menu.textContent = "";

      if (results.length === 0) {
        const empty = document.createElement("div");
        empty.className = "tree-search-empty";
        empty.textContent = tokens.length === 0 ? "No issues available" : "No matching issues";
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

    input.addEventListener("input", function () {
      if (multi) clearMultiValidity();
      scheduleRender();
    });
    input.addEventListener("focus", function () {
      scheduleRender();
    });
    if (tokenInput) {
      tokenInput.addEventListener("click", function (event) {
        if (event.target.closest(".project-selected-issue")) return;
        input.focus();
      });
    }
    input.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        setMenuOpen(false);
        return;
      }
      if (multi && event.key === "Backspace" && input.value === "" && selectedRoot) {
        const tokens = selectedRoot.querySelectorAll(".project-selected-issue");
        const token = tokens[tokens.length - 1];
        if (token) {
          token.remove();
          updateMultiSearchState();
          scheduleRender();
        }
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

    if (multi && input.form) {
      input.form.addEventListener("submit", function (event) {
        addPendingInputValue();
        if (selectedIssueValues().length > 0) {
          clearMultiValidity();
          return;
        }
        event.preventDefault();
        input.setCustomValidity("Select at least one issue");
        if (tokenInput) tokenInput.classList.add("is-invalid");
        input.reportValidity();
      });
      updateMultiSearchState();
    }

    menu.addEventListener("mousemove", function (event) {
      const button = event.target.closest(".tree-search-result");
      if (!button || !menu.contains(button)) return;
      setActiveIndex(Number(button.dataset.index));
    });
    menu.addEventListener("click", function (event) {
      const button = event.target.closest(".tree-search-result");
      if (!button || !menu.contains(button)) return;
      event.preventDefault();
      selectResult(results[Number(button.dataset.index)]);
    });
    document.addEventListener("click", function (event) {
      if (container.contains(event.target)) return;
      if (event.composedPath && event.composedPath().indexOf(container) !== -1) return;
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

  function initProjectIndexTabs(root) {
    scopedQuery(root, "[data-project-index-tabs]").forEach(function (root) {
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

  function initProjectUpdateHealthMenu(menu) {
    if (menu.dataset.projectUpdateHealthMenuReady === "yes") return;
    menu.dataset.projectUpdateHealthMenuReady = "yes";

    menu.querySelectorAll("input[type='radio'][name='update_health']").forEach(function (input) {
      input.addEventListener("change", function () {
        menu.open = false;
        const summary = menu.querySelector("summary");
        if (summary) summary.focus();
      });
    });
  }

  function initProjectChoiceMenu(menu) {
    if (menu.dataset.projectChoiceMenuReady === "yes") return;
    menu.dataset.projectChoiceMenuReady = "yes";

    const selectedRoot = menu.querySelector("[data-project-choice-selected]");

    function syncSelected(input) {
      if (!selectedRoot || !input) return;
      const option = input.closest(".project-choice-option");
      const content = option ? option.querySelector("[data-project-choice-option-content]") : null;
      if (!content) return;
      selectedRoot.textContent = "";
      Array.from(content.childNodes).forEach(function (node) {
        selectedRoot.appendChild(node.cloneNode(true));
      });
    }

    const checked = menu.querySelector("input[type='radio']:checked");
    syncSelected(checked);

    menu.querySelectorAll("input[type='radio']").forEach(function (input) {
      input.addEventListener("change", function () {
        syncSelected(input);
        menu.open = false;
        const summary = menu.querySelector("summary");
        if (summary) summary.focus();
      });
    });
  }

  function padDatePart(value) {
    return value < 10 ? "0" + value : String(value);
  }

  function dateKey(date) {
    return date.getFullYear() + "-" + padDatePart(date.getMonth() + 1) + "-" + padDatePart(date.getDate());
  }

  function parseDateKey(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
    if (!match) return null;
    const year = Number(match[1]);
    const month = Number(match[2]) - 1;
    const day = Number(match[3]);
    const date = new Date(year, month, day);
    if (
      date.getFullYear() !== year ||
      date.getMonth() !== month ||
      date.getDate() !== day
    ) {
      return null;
    }
    date.setHours(0, 0, 0, 0);
    return date;
  }

  function todayDate() {
    const date = new Date();
    date.setHours(0, 0, 0, 0);
    return date;
  }

  function monthStart(date) {
    return new Date(date.getFullYear(), date.getMonth(), 1);
  }

  function addMonths(date, amount) {
    return new Date(date.getFullYear(), date.getMonth() + amount, 1);
  }

  function monthGridStart(monthDate) {
    const first = monthStart(monthDate);
    const mondayOffset = (first.getDay() + 6) % 7;
    return new Date(first.getFullYear(), first.getMonth(), 1 - mondayOffset);
  }

  function monthTitle(date) {
    return new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" }).format(date);
  }

  function dateLabel(value, placeholder) {
    const date = parseDateKey(value);
    if (!date) return placeholder;
    return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(date);
  }

  function closeActiveDatePicker(except) {
    if (!activeDatePicker || activeDatePicker === except) return;
    activeDatePicker.close();
    activeDatePicker = null;
  }

  function initDatePicker(input) {
    if (input.dataset.datePickerReady === "yes") return;
    input.dataset.datePickerReady = "yes";

    const inline = input.dataset.datePickerInline === "yes";
    const autoSubmit = input.dataset.datePickerAutosubmit === "yes";
    const placeholder = input.dataset.datePickerPlaceholder || "Select date";
    const label = input.dataset.datePickerLabel || input.getAttribute("aria-label") || placeholder;
    const canClear = input.dataset.datePickerClear !== "no" && !input.required;
    const invalidUntilDate = parseDateKey(input.dataset.datePickerInvalidUntil || "");
    const invalidUntilKey = invalidUntilDate ? dateKey(invalidUntilDate) : "";
    const invalidFromDate = parseDateKey(input.dataset.datePickerInvalidFrom || "");
    const invalidFromKey = invalidFromDate ? dateKey(invalidFromDate) : "";
    const root = document.createElement("div");
    const calendar = document.createElement("div");
    const today = todayDate();
    let viewMonth = monthStart(today);
    let trigger = null;
    let open = inline;

    root.className = inline ? "date-picker date-picker-inline" : "date-picker";
    calendar.className = inline ? "date-picker-calendar" : "date-picker-popover date-picker-calendar";
    calendar.setAttribute("role", "dialog");
    calendar.setAttribute("aria-label", label);
    if (!inline) calendar.hidden = true;

    input.classList.add("date-picker-native-input");
    input.setAttribute("aria-hidden", "true");
    input.tabIndex = -1;

    if (!input.parentNode) return;
    input.parentNode.insertBefore(root, input.nextSibling);

    if (!inline) {
      trigger = document.createElement("button");
      trigger.type = "button";
      trigger.className = "date-picker-trigger";
      trigger.setAttribute("aria-haspopup", "dialog");
      trigger.setAttribute("aria-expanded", "false");
      trigger.textContent = dateLabel(input.value, placeholder);
      root.appendChild(trigger);
    }

    root.appendChild(calendar);

    function syncTrigger() {
      if (!trigger) return;
      trigger.textContent = dateLabel(input.value, placeholder);
      trigger.classList.toggle("is-empty", !input.value);
    }

    function setInputValue(value) {
      input.value = value;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      syncTrigger();
      closePicker();
      if (!autoSubmit && trigger) trigger.focus();
      if (autoSubmit && input.form) {
        if (typeof input.form.requestSubmit === "function") {
          input.form.requestSubmit();
        } else {
          input.form.submit();
        }
      }
    }

    function closePicker() {
      if (inline) return;
      open = false;
      calendar.hidden = true;
      if (trigger) trigger.setAttribute("aria-expanded", "false");
      if (activeDatePicker === api) activeDatePicker = null;
    }

    function openPicker() {
      if (inline) return;
      closeActiveDatePicker(api);
      open = true;
      activeDatePicker = api;
      calendar.hidden = false;
      if (trigger) trigger.setAttribute("aria-expanded", "true");
      render();
      const selected = calendar.querySelector(".date-picker-day.is-selected") ||
        calendar.querySelector(".date-picker-day.is-today:not(:disabled)") ||
        calendar.querySelector(".date-picker-day:not(:disabled)");
      if (selected) selected.focus();
    }

    function isInvalidDateKey(key) {
      if (invalidUntilKey && key <= invalidUntilKey) return true;
      if (invalidFromKey && key >= invalidFromKey) return true;
      return false;
    }

    function renderMonth(monthDate) {
      const month = monthDate.getMonth();
      const selectedKey = input.value || "";
      const todayKey = dateKey(today);
      const section = document.createElement("section");
      const weekdays = document.createElement("div");
      const days = document.createElement("div");
      const gridStart = monthGridStart(monthDate);

      section.className = "date-picker-month";
      weekdays.className = "date-picker-weekdays";
      ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].forEach(function (name) {
        const weekday = document.createElement("span");
        weekday.textContent = name;
        weekdays.appendChild(weekday);
      });
      days.className = "date-picker-days";

      for (let index = 0; index < 42; index += 1) {
        const date = new Date(gridStart.getFullYear(), gridStart.getMonth(), gridStart.getDate() + index);
        const key = dateKey(date);
        const button = document.createElement("button");
        button.type = "button";
        button.className = "date-picker-day";
        button.dataset.date = key;
        button.textContent = String(date.getDate());
        button.setAttribute("aria-label", dateLabel(key, key));
        if (isInvalidDateKey(key)) {
          button.disabled = true;
          button.setAttribute("aria-disabled", "true");
          button.classList.add("is-disabled");
        }
        if (date.getMonth() !== month) button.classList.add("is-outside");
        if (key < todayKey) button.classList.add("is-past");
        if (key === todayKey) button.classList.add("is-today");
        if (key === selectedKey) {
          button.classList.add("is-selected");
          button.setAttribute("aria-pressed", "true");
        } else {
          button.setAttribute("aria-pressed", "false");
        }
        days.appendChild(button);
      }

      section.appendChild(weekdays);
      section.appendChild(days);
      return section;
    }

    function render() {
      calendar.textContent = "";

      const head = document.createElement("div");
      const prev = document.createElement("button");
      const next = document.createElement("button");
      const firstTitle = document.createElement("h3");
      const secondTitle = document.createElement("h3");
      const months = document.createElement("div");
      head.className = "date-picker-head";
      prev.type = "button";
      prev.className = "date-picker-nav date-picker-prev";
      prev.setAttribute("aria-label", "Previous two months");
      prev.innerHTML = "<span aria-hidden=\"true\"></span>";
      next.type = "button";
      next.className = "date-picker-nav date-picker-next";
      next.setAttribute("aria-label", "Next two months");
      next.innerHTML = "<span aria-hidden=\"true\"></span>";
      firstTitle.textContent = monthTitle(viewMonth);
      secondTitle.textContent = monthTitle(addMonths(viewMonth, 1));
      months.className = "date-picker-months";
      months.appendChild(renderMonth(viewMonth));
      months.appendChild(renderMonth(addMonths(viewMonth, 1)));
      head.appendChild(prev);
      head.appendChild(firstTitle);
      head.appendChild(secondTitle);
      head.appendChild(next);
      calendar.appendChild(head);
      calendar.appendChild(months);

      if (canClear) {
        const footer = document.createElement("div");
        const clear = document.createElement("button");
        footer.className = "date-picker-footer";
        clear.type = "button";
        clear.className = "date-picker-clear";
        clear.textContent = "Clear";
        clear.disabled = input.value === "";
        footer.appendChild(clear);
        calendar.appendChild(footer);
      }
    }

    function moveFocus(from, amount) {
      const days = Array.from(calendar.querySelectorAll(".date-picker-day:not(:disabled)"));
      const index = days.indexOf(from);
      if (index === -1) return;
      const next = days[index + amount];
      if (next) {
        next.focus();
        return;
      }
      viewMonth = addMonths(viewMonth, amount > 0 ? 2 : -2);
      render();
      const refreshed = Array.from(calendar.querySelectorAll(".date-picker-day:not(:disabled)"));
      const target = refreshed[Math.max(0, Math.min(refreshed.length - 1, index))];
      if (target) target.focus();
    }

    const api = { close: closePicker };

    if (trigger) {
      syncTrigger();
      trigger.addEventListener("click", function () {
        if (open) {
          closePicker();
        } else {
          openPicker();
        }
      });

      const labelElement = input.closest("label");
      if (labelElement) {
        labelElement.addEventListener("click", function (event) {
          const target = event.target;
          if (!(target instanceof Element)) return;
          if (root.contains(target) || target.closest("button, input, select, textarea, a")) return;
          event.preventDefault();
          openPicker();
        });
      }
    }

    calendar.addEventListener("click", function (event) {
      event.stopPropagation();
      const target = event.target;
      const day = target instanceof Element ? target.closest(".date-picker-day") : null;
      if (day && calendar.contains(day)) {
        event.preventDefault();
        if (day.disabled) return;
        setInputValue(day.dataset.date || "");
        return;
      }

      const nav = target instanceof Element ? target.closest(".date-picker-nav") : null;
      if (nav && calendar.contains(nav)) {
        event.preventDefault();
        viewMonth = addMonths(viewMonth, nav.classList.contains("date-picker-next") ? 2 : -2);
        render();
        return;
      }

      const clear = target instanceof Element ? target.closest(".date-picker-clear") : null;
      if (clear && calendar.contains(clear)) {
        event.preventDefault();
        setInputValue("");
      }
    });

    calendar.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        closePicker();
        if (trigger) trigger.focus();
        return;
      }
      const day = event.target instanceof Element ? event.target.closest(".date-picker-day") : null;
      if (!day) return;
      if (event.key === "ArrowRight") {
        event.preventDefault();
        moveFocus(day, 1);
      } else if (event.key === "ArrowLeft") {
        event.preventDefault();
        moveFocus(day, -1);
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        moveFocus(day, 7);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        moveFocus(day, -7);
      }
    });

    if (inline) render();
  }

  function initDatePickers(root) {
    scopedQuery(root, datePickerSelector).forEach(initDatePicker);
    if (document.body.dataset.datePickerDismissReady === "yes") return;
    document.body.dataset.datePickerDismissReady = "yes";
    window.addEventListener("pointerdown", function (event) {
      const target = event.target;
      if (target instanceof Element && target.closest(".date-picker-calendar")) {
        event.stopPropagation();
      }
    }, true);
    document.addEventListener("pointerdown", function (event) {
      if (!activeDatePicker) return;
      const target = event.target;
      if (target instanceof Element && target.closest(".date-picker")) return;
      closeActiveDatePicker(null);
    }, true);
  }

  function initProjects(root) {
    const scope = root || document;
    initProjectIndexTabs(scope);
    initDatePickers(scope);
    scopedQuery(scope, "[data-project-issue-search]").forEach(initIssueSearchMenu);
    scopedQuery(scope, "[data-project-update-health-menu]").forEach(initProjectUpdateHealthMenu);
    scopedQuery(scope, "[data-project-choice-menu]").forEach(initProjectChoiceMenu);
    scopedQuery(scope, cardSelector).forEach(initCard);
    scopedQuery(scope, columnSelector).forEach(initColumn);
  }

  document.addEventListener("gitomi:partial-refresh", function (event) {
    const detail = event.detail || {};
    initProjects(detail.root || document);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      initProjects();
    });
  } else {
    initProjects();
  }
}());
