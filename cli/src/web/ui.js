(function () {
  const popoverMenuSelector = "details[data-popover-menu]";
  const indexViewSnapshotKey = "gitomi.indexViewSnapshot.v1";

  function summaryFor(menu) {
    return menu.querySelector("summary");
  }

  function setExpanded(menu) {
    const summary = summaryFor(menu);
    if (summary) summary.setAttribute("aria-expanded", menu.open ? "true" : "false");
  }

  function closestPopoverMenu(target) {
    return target instanceof Element ? target.closest(popoverMenuSelector) : null;
  }

  function closePopoverMenus(except) {
    document.querySelectorAll(popoverMenuSelector + "[open]").forEach(function (menu) {
      if (menu !== except) {
        menu.open = false;
        setExpanded(menu);
      }
    });
  }

  function initPopoverMenus() {
    document.querySelectorAll(popoverMenuSelector).forEach(function (menu) {
      if (menu.dataset.popoverMenuReady === "yes") return;
      menu.dataset.popoverMenuReady = "yes";
      setExpanded(menu);
      menu.addEventListener("toggle", function () {
        setExpanded(menu);
        if (menu.open) closePopoverMenus(menu);
      });
    });

    if (document.body.dataset.popoverMenusReady === "yes") return;
    document.body.dataset.popoverMenusReady = "yes";

    document.addEventListener("pointerdown", function (event) {
      closePopoverMenus(closestPopoverMenu(event.target));
    }, true);

    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") return;

      const openMenu = document.querySelector(popoverMenuSelector + "[open]");
      if (!openMenu) return;

      const activeMenu = closestPopoverMenu(event.target);
      closePopoverMenus(null);
      if (activeMenu) {
        const summary = summaryFor(activeMenu);
        if (summary) summary.focus();
      }
      event.preventDefault();
      event.stopPropagation();
    }, true);
  }

  function setNavBadge(link, value) {
    let badge = link.querySelector(".nav-badge");
    if (value > 0) {
      if (!badge) {
        badge = document.createElement("span");
        badge.className = "nav-badge";
        link.appendChild(badge);
      }
      badge.textContent = String(value);
    } else if (badge) {
      badge.remove();
    }
  }

  function updateNavStats(stats) {
    ["issues", "pulls"].forEach(function (key) {
      const value = Number(stats && stats[key]);
      if (!Number.isFinite(value)) return;
      document.querySelectorAll('[data-nav-count="' + key + '"]').forEach(function (link) {
        setNavBadge(link, value);
      });
    });
  }

  function initNavStats() {
    if (!window.fetch || document.body.dataset.navStatsReady === "yes") return;
    if (!document.querySelector("[data-nav-count]")) return;
    document.body.dataset.navStatsReady = "yes";

    fetch("/nav/stats", { cache: "no-store" })
      .then(function (response) {
        return response.ok ? response.json() : null;
      })
      .then(function (stats) {
        if (stats) updateNavStats(stats);
      })
      .catch(function () {});
  }

  function labelRowName(row) {
    return (row.dataset.labelName || "").toLocaleLowerCase();
  }

  function labelRowTotal(row) {
    const value = Number(row.dataset.labelTotal || "0");
    return Number.isFinite(value) ? value : 0;
  }

  function labelRowOrder(row) {
    const value = Number(row.dataset.labelOrder || "0");
    return Number.isFinite(value) ? value : 0;
  }

  function initLabelsPage() {
    document.querySelectorAll("[data-labels-page]").forEach(function (page) {
      if (page.dataset.labelsReady === "yes") return;
      page.dataset.labelsReady = "yes";

      const list = page.querySelector("[data-label-list]");
      const search = page.querySelector("[data-label-search]");
      const visibleCount = page.querySelector("[data-label-visible-count]");
      const countWord = page.querySelector("[data-label-count-word]");
      const empty = page.querySelector("[data-label-empty]");
      const sortLabel = page.querySelector("[data-label-sort-label]");
      const sortButtons = Array.from(page.querySelectorAll("[data-label-sort]"));
      const rows = Array.from(page.querySelectorAll("[data-label-row]"));
      const csrfField = page.dataset.labelCsrfField || "_csrf";
      const csrfToken = page.dataset.labelCsrf || "";
      const dialog = page.querySelector("[data-label-dialog]");
      const dialogTitle = dialog ? dialog.querySelector("[data-label-dialog-title]") : null;
      const dialogAction = dialog ? dialog.querySelector("[data-label-dialog-action]") : null;
      const dialogOriginal = dialog ? dialog.querySelector("[data-label-dialog-original]") : null;
      const dialogName = dialog ? dialog.querySelector("[data-label-dialog-name]") : null;
      const dialogDescription = dialog ? dialog.querySelector("[data-label-dialog-description]") : null;
      const dialogColor = dialog ? dialog.querySelector("[data-label-dialog-color]") : null;
      const dialogPreview = dialog ? dialog.querySelector("[data-label-dialog-preview]") : null;
      const dialogSubmit = dialog ? dialog.querySelector("[data-label-dialog-submit]") : null;
      const labelColors = ["#0075ca", "#d73a4a", "#a2eeef", "#7057ff", "#008672", "#e4e669", "#d876e3", "#b60205", "#0e8a16", "#fbca04", "#5319e7", "#cfd3d7"];
      let sortMode = "manual";
      let draggedRow = null;

      function setSelectedSort() {
        sortButtons.forEach(function (button) {
          const selected = button.dataset.labelSort === sortMode;
          button.classList.toggle("selected", selected);
          button.setAttribute("aria-pressed", selected ? "true" : "false");
          if (selected && sortLabel) sortLabel.textContent = button.textContent.trim();
        });
      }

      function compareRows(left, right) {
        if (sortMode === "manual") {
          const orderDiff = labelRowOrder(left) - labelRowOrder(right);
          if (orderDiff !== 0) return orderDiff;
        }
        if (sortMode === "usage") {
          const usageDiff = labelRowTotal(right) - labelRowTotal(left);
          if (usageDiff !== 0) return usageDiff;
        }
        return labelRowName(left).localeCompare(labelRowName(right));
      }

      function labelSearchQuery() {
        return search ? search.value.trim().toLocaleLowerCase() : "";
      }

      function updateDragHandles(query) {
        rows.forEach(function (row) {
          const handle = row.querySelector("[data-label-drag-handle]");
          if (handle) handle.draggable = query.length === 0;
        });
      }

      function applyLabelsView() {
        const query = labelSearchQuery();
        const visibleRows = [];
        rows.forEach(function (row) {
          const text = (row.dataset.labelSearchText || "").toLocaleLowerCase();
          const hidden = query.length > 0 && !text.includes(query);
          row.hidden = hidden;
          if (!hidden) visibleRows.push(row);
        });
        visibleRows.sort(compareRows).forEach(function (row) {
          list.appendChild(row);
        });
        if (visibleCount) visibleCount.textContent = String(visibleRows.length);
        if (countWord) countWord.textContent = visibleRows.length === 1 ? "label" : "labels";
        if (empty) empty.hidden = rows.length === 0 || visibleRows.length !== 0;
        updateDragHandles(query);
      }

      function setManualSort() {
        sortMode = "manual";
        setSelectedSort();
      }

      function updateLabelOrderFromDom() {
        if (!list) return;
        Array.from(list.querySelectorAll("[data-label-row]")).forEach(function (row, index) {
          row.dataset.labelOrder = String(index);
        });
      }

      function persistLabelOrder() {
        if (!list || !window.fetch || !csrfToken) return;
        const params = new URLSearchParams();
        params.set(csrfField, csrfToken);
        params.set("action", "reorder");
        params.set("order", Array.from(list.querySelectorAll("[data-label-row]")).map(function (row) {
          return row.dataset.labelName || "";
        }).filter(Boolean).join("\n"));
        fetch("/settings/labels", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: params.toString()
        }).catch(function () {});
      }

      function moveDraggedRow(targetRow, clientY) {
        if (!list || !draggedRow || !targetRow || targetRow === draggedRow) return;
        const rect = targetRow.getBoundingClientRect();
        const after = clientY > rect.top + rect.height / 2;
        list.insertBefore(draggedRow, after ? targetRow.nextSibling : targetRow);
      }

      function normalizedColor(value) {
        const color = String(value || "").trim();
        return /^#[0-9a-f]{6}$/i.test(color) ? color.toLowerCase() : "#0075ca";
      }

      function setDialogPreview() {
        if (!dialogPreview) return;
        const name = dialogName && dialogName.value.trim() ? dialogName.value.trim() : "label";
        const color = normalizedColor(dialogColor ? dialogColor.value : "");
        dialogPreview.textContent = name;
        dialogPreview.style.setProperty("--label-color", color);
      }

      function setDialogColor(value) {
        if (dialogColor) dialogColor.value = normalizedColor(value);
        setDialogPreview();
      }

      function closeLabelDialog() {
        if (!dialog) return;
        dialog.hidden = true;
        document.body.classList.remove("has-modal");
      }

      function openLabelDialog(mode, row) {
        if (!dialog) return;
        const creating = mode === "create";
        const name = creating ? "" : (row.dataset.labelName || "");
        const description = creating ? "" : (row.dataset.labelDescription || "");
        const color = creating ? "#0075ca" : (row.dataset.labelColor || "#0075ca");
        if (dialogTitle) dialogTitle.textContent = creating ? "New label" : "Edit label";
        if (dialogAction) dialogAction.value = creating ? "create" : "update";
        if (dialogOriginal) dialogOriginal.value = name;
        if (dialogName) dialogName.value = name;
        if (dialogDescription) dialogDescription.value = description;
        setDialogColor(color);
        if (dialogSubmit) dialogSubmit.textContent = creating ? "Create label" : "Save changes";
        dialog.hidden = false;
        document.body.classList.add("has-modal");
        if (dialogName) {
          dialogName.focus();
          dialogName.select();
        }
      }

      page.addEventListener("click", function (event) {
        const newToggle = event.target.closest("[data-label-new-toggle]");
        if (newToggle && page.contains(newToggle)) {
          openLabelDialog("create", null);
          event.preventDefault();
          return;
        }

        const editToggle = event.target.closest("[data-label-edit-toggle]");
        if (editToggle && page.contains(editToggle)) {
          const row = editToggle.closest("[data-label-row]");
          if (row) openLabelDialog("edit", row);
          const menu = editToggle.closest("details");
          if (menu) {
            menu.open = false;
            setExpanded(menu);
          }
          event.preventDefault();
          return;
        }

        const cancel = event.target.closest("[data-label-dialog-cancel], [data-label-dialog-close]");
        if (cancel && page.contains(cancel)) {
          closeLabelDialog();
          event.preventDefault();
          return;
        }

        const randomColor = event.target.closest("[data-label-color-random]");
        if (randomColor && page.contains(randomColor)) {
          const current = normalizedColor(dialogColor ? dialogColor.value : "");
          const next = labelColors[(labelColors.indexOf(current) + 1 + labelColors.length) % labelColors.length];
          setDialogColor(next);
          event.preventDefault();
          return;
        }

        if (dialog && event.target === dialog) {
          closeLabelDialog();
          event.preventDefault();
        }
      });

      page.addEventListener("dragstart", function (event) {
        const handle = event.target.closest("[data-label-drag-handle]");
        if (!handle || !page.contains(handle) || labelSearchQuery().length !== 0) {
          event.preventDefault();
          return;
        }
        draggedRow = handle.closest("[data-label-row]");
        if (!draggedRow) return;
        setManualSort();
        draggedRow.classList.add("is-dragging");
        if (event.dataTransfer) {
          event.dataTransfer.effectAllowed = "move";
          event.dataTransfer.setData("text/plain", draggedRow.dataset.labelName || "");
        }
      });

      page.addEventListener("dragover", function (event) {
        if (!draggedRow) return;
        const targetRow = event.target.closest("[data-label-row]");
        if (!targetRow || !page.contains(targetRow) || targetRow.hidden) return;
        event.preventDefault();
        moveDraggedRow(targetRow, event.clientY);
      });

      page.addEventListener("drop", function (event) {
        if (!draggedRow) return;
        event.preventDefault();
        updateLabelOrderFromDom();
        persistLabelOrder();
        draggedRow.classList.remove("is-dragging");
        draggedRow = null;
      });

      page.addEventListener("dragend", function () {
        if (!draggedRow) return;
        updateLabelOrderFromDom();
        persistLabelOrder();
        draggedRow.classList.remove("is-dragging");
        draggedRow = null;
      });

      if (dialogName) dialogName.addEventListener("input", setDialogPreview);
      if (dialogColor) dialogColor.addEventListener("input", setDialogPreview);
      page.addEventListener("keydown", function (event) {
        if (event.key === "Escape" && dialog && !dialog.hidden) {
          closeLabelDialog();
          event.preventDefault();
        }
      });

      if (search) {
        search.addEventListener("input", applyLabelsView);
      }
      sortButtons.forEach(function (button) {
        button.addEventListener("click", function () {
          sortMode = button.dataset.labelSort || "manual";
          setSelectedSort();
          applyLabelsView();
          const menu = button.closest("details");
          if (menu) {
            menu.open = false;
            setExpanded(menu);
          }
        });
      });

      setSelectedSort();
      applyLabelsView();
    });
  }

  function initPullMergeMethodMenus() {
    document.querySelectorAll(".pull-merge-button-group").forEach(function (group) {
      if (group.dataset.mergeMenuReady === "yes") return;
      group.dataset.mergeMenuReady = "yes";

      const submit = group.querySelector(".pull-merge-submit");
      const label = submit ? submit.querySelector("[data-merge-submit-label]") : null;
      const menu = group.querySelector(".pull-merge-method-menu");
      const options = Array.from(group.querySelectorAll(".pull-merge-method-option"));
      if (!submit || !label || !menu || options.length === 0) return;

      function selectMethod(option) {
        const method = option.value || "merge";
        const text = option.dataset.mergeButtonLabel || method;
        submit.value = method;
        label.textContent = text;
        options.forEach(function (item) {
          const selected = item === option;
          item.classList.toggle("is-selected", selected);
          item.setAttribute("aria-checked", selected ? "true" : "false");
        });
      }

      options.forEach(function (option) {
        option.addEventListener("click", function (event) {
          event.preventDefault();
          selectMethod(option);
          menu.open = false;
          setExpanded(menu);
          submit.focus();
        });
      });

      const selected = options.find(function (option) {
        return option.classList.contains("is-selected");
      });
      if (selected) selectMethod(selected);
    });
  }

  const githubAvatarChecks = new Map();

  function equalBuffers(left, right) {
    if (!left || !right || left.byteLength !== right.byteLength) return false;
    const a = new Uint8Array(left);
    const b = new Uint8Array(right);
    for (let i = 0; i < a.length; i += 1) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }

  function fetchAvatarBytes(url) {
    if (!window.fetch || !url) return Promise.resolve(null);
    return fetch(url, {
      cache: "force-cache",
      credentials: "omit",
      mode: "cors",
      redirect: "follow"
    }).then(function (response) {
      if (!response.ok) return null;
      return response.arrayBuffer();
    }).catch(function () {
      return null;
    });
  }

  function githubIdenticonUrl(login) {
    return "https://github.com/identicons/" + encodeURIComponent(login) + ".png?size=80";
  }

  function githubAvatarIsCustom(img) {
    const login = img.dataset.avatarGithubLogin || "";
    if (!login) return Promise.resolve(false);

    const src = img.currentSrc || img.src || "";
    if (/\/identicons\//i.test(src)) return Promise.resolve(false);

    const key = login.toLocaleLowerCase() + "\n" + src;
    if (githubAvatarChecks.has(key)) return githubAvatarChecks.get(key);

    const check = Promise.all([
      fetchAvatarBytes(src),
      fetchAvatarBytes(githubIdenticonUrl(login))
    ]).then(function (buffers) {
      const avatar = buffers[0];
      const identicon = buffers[1];
      if (!avatar) return true;
      if (!identicon) return true;
      return !equalBuffers(avatar, identicon);
    });
    githubAvatarChecks.set(key, check);
    return check;
  }

  function activateAvatarCandidate(container, img) {
    if (container.dataset.avatarResolved === "yes") return;
    container.dataset.avatarResolved = "yes";
    container.querySelectorAll(".avatar-image.is-active").forEach(function (active) {
      active.classList.remove("is-active");
    });
    img.classList.add("is-active");
    container.classList.add("has-external-avatar");
  }

  function tryAvatarCandidate(container, candidates, index) {
    if (container.dataset.avatarResolved === "yes") return;
    if (index >= candidates.length) {
      container.dataset.avatarResolved = "generated";
      return;
    }

    const img = candidates[index];
    function next() {
      tryAvatarCandidate(container, candidates, index + 1);
    }
    function loaded() {
      if (!img.naturalWidth || !img.naturalHeight) {
        next();
        return;
      }
      if (img.dataset.avatarSource === "github") {
        githubAvatarIsCustom(img).then(function (custom) {
          if (custom) activateAvatarCandidate(container, img);
          else next();
        });
        return;
      }
      activateAvatarCandidate(container, img);
    }

    if (img.complete) {
      loaded();
      return;
    }
    img.addEventListener("load", loaded, { once: true });
    img.addEventListener("error", next, { once: true });
  }

  function initAvatars(root) {
    const scope = root || document;
    scope.querySelectorAll(".nouns-avatar").forEach(function (container) {
      if (container.dataset.avatarReady === "yes") return;
      const candidates = Array.from(container.querySelectorAll(".avatar-image"));
      if (candidates.length === 0) return;
      container.dataset.avatarReady = "yes";
      tryAvatarCandidate(container, candidates, 0);
    });
  }

  function syncSnapshotFormState(sourceRoot, cloneRoot) {
    const sourceControls = Array.from(sourceRoot.querySelectorAll("input, textarea, select, option"));
    const cloneControls = Array.from(cloneRoot.querySelectorAll("input, textarea, select, option"));
    sourceControls.forEach(function (control, index) {
      const clone = cloneControls[index];
      if (!clone || clone.tagName !== control.tagName) return;

      if (control.tagName === "INPUT") {
        const type = (control.getAttribute("type") || "text").toLowerCase();
        if (type === "checkbox" || type === "radio") {
          if (control.checked) clone.setAttribute("checked", "");
          else clone.removeAttribute("checked");
          return;
        }
        if (type !== "password") clone.setAttribute("value", control.value);
        return;
      }

      if (control.tagName === "TEXTAREA") {
        clone.textContent = control.value;
        return;
      }

      if (control.tagName === "OPTION") {
        if (control.selected) clone.setAttribute("selected", "");
        else clone.removeAttribute("selected");
      }
    });
  }

  function cloneSnapshotNode(node) {
    const clone = node.cloneNode(true);
    syncSnapshotFormState(node, clone);
    return clone;
  }

  function snapshotStorage() {
    try {
      return window.sessionStorage;
    } catch (_) {
      return null;
    }
  }

  function saveIndexViewSnapshot() {
    const storage = snapshotStorage();
    if (!storage) return;
    if (document.querySelector("[data-index-popover]")) return;

    const header = document.querySelector(".topbar");
    const main = document.querySelector("main.page");
    if (!header || !main) return;

    try {
      const snapshot = {
        version: 1,
        url: window.location.pathname + window.location.search + window.location.hash,
        title: document.title,
        bodyClass: document.body.className || "",
        header: cloneSnapshotNode(header).outerHTML,
        main: cloneSnapshotNode(main).outerHTML,
        scrollX: window.scrollX || 0,
        scrollY: window.scrollY || 0,
        savedAt: Date.now()
      };
      storage.setItem(indexViewSnapshotKey, JSON.stringify(snapshot));
    } catch (_) {}
  }

  function initIndexViewSnapshot() {
    saveIndexViewSnapshot();
    window.addEventListener("pagehide", saveIndexViewSnapshot);
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "hidden") saveIndexViewSnapshot();
    });
  }

  function initUi() {
    initPopoverMenus();
    initNavStats();
    initLabelsPage();
    initPullMergeMethodMenus();
    initAvatars(document);
    initIndexViewSnapshot();
  }

  document.addEventListener("gitomi:partial-refresh", function (event) {
    const detail = event.detail || {};
    initAvatars(detail.root || document);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initUi);
  } else {
    initUi();
  }
}());
