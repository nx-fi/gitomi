(function () {
  const popoverMenuSelector = "details[data-popover-menu]";

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
      let sortMode = "name";

      function setSelectedSort() {
        sortButtons.forEach(function (button) {
          const selected = button.dataset.labelSort === sortMode;
          button.classList.toggle("selected", selected);
          button.setAttribute("aria-pressed", selected ? "true" : "false");
          if (selected && sortLabel) sortLabel.textContent = button.textContent.trim();
        });
      }

      function compareRows(left, right) {
        if (sortMode === "usage") {
          const usageDiff = labelRowTotal(right) - labelRowTotal(left);
          if (usageDiff !== 0) return usageDiff;
        }
        return labelRowName(left).localeCompare(labelRowName(right));
      }

      function applyLabelsView() {
        const query = search ? search.value.trim().toLocaleLowerCase() : "";
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
          sortMode = button.dataset.labelSort || "name";
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

  function initUi() {
    initPopoverMenus();
    initNavStats();
    initLabelsPage();
    initPullMergeMethodMenus();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initUi);
  } else {
    initUi();
  }
}());
