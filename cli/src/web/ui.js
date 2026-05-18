(function () {
  const popoverMenuSelector = "details[data-popover-menu]";
  const indexViewSnapshotKey = "gitomi.indexViewSnapshot.v1";
  const submitLockMs = 3000;
  const notificationTimeoutMs = 6000;
  const nativeFetch = window.fetch ? window.fetch.bind(window) : null;

  function notificationRoot() {
    let root = document.querySelector("[data-gitomi-notifications]");
    if (root) return root;
    root = document.createElement("div");
    root.className = "gitomi-notification-bar";
    root.setAttribute("data-gitomi-notifications", "");
    root.setAttribute("role", "status");
    root.setAttribute("aria-live", "polite");
    root.setAttribute("aria-atomic", "false");
    document.body.appendChild(root);
    return root;
  }

  function normalizeNotificationMessage(message) {
    const text = String(message || "").replace(/\s+/g, " ").trim();
    return text || "The action failed.";
  }

  function notify(message, kind) {
    const root = notificationRoot();
    const item = document.createElement("div");
    const level = kind === "success" ? "success" : "error";
    item.className = "gitomi-notification " + level;
    item.textContent = normalizeNotificationMessage(message);
    root.appendChild(item);
    window.setTimeout(function () {
      item.classList.add("is-hiding");
      window.setTimeout(function () {
        if (item.parentNode) item.parentNode.removeChild(item);
        if (!root.children.length && root.parentNode) root.parentNode.removeChild(root);
      }, 160);
    }, notificationTimeoutMs);
  }

  window.gitomiNotify = notify;

  function messageFromHtml(html) {
    if (!window.DOMParser) return "";
    try {
      const doc = new DOMParser().parseFromString(html, "text/html");
      const flash = doc.querySelector(".flash.error, [role='alert'], .error");
      if (flash && flash.textContent.trim()) return flash.textContent;
      if (doc.title && doc.title.trim()) return doc.title;
      return doc.body ? doc.body.textContent : "";
    } catch (_) {
      return "";
    }
  }

  function messageFromText(text) {
    const trimmed = String(text || "").trim();
    if (!trimmed) return "";
    if (trimmed[0] === "<") return messageFromHtml(trimmed);
    return trimmed;
  }

  function responseMessage(response) {
    return response.clone().text().then(function (text) {
      return normalizeNotificationMessage(messageFromText(text) || (response.status + " " + response.statusText));
    }).catch(function () {
      return normalizeNotificationMessage(response.status + " " + response.statusText);
    });
  }

  function requestMethod(input, init) {
    if (init && init.method) return String(init.method).toUpperCase();
    if (typeof Request !== "undefined" && input instanceof Request && input.method) {
      return String(input.method).toUpperCase();
    }
    return "GET";
  }

  function isWriteMethod(method) {
    return method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE";
  }

  function shouldNotifyFetchError(input, init) {
    if (init && init.gitomiSuppressErrorNotification) return false;
    return isWriteMethod(requestMethod(input, init));
  }

  function initFetchErrorNotifications() {
    if (!nativeFetch || window.gitomiFetchErrorNotificationsReady === "yes") return;
    window.gitomiFetchErrorNotificationsReady = "yes";
    window.fetch = function (input, init) {
      return nativeFetch(input, init).then(function (response) {
        if (!response.ok && shouldNotifyFetchError(input, init)) {
          responseMessage(response).then(function (message) {
            notify(message, "error");
          });
        }
        return response;
      }).catch(function (error) {
        if (shouldNotifyFetchError(input, init)) {
          notify(error && error.message ? error.message : "The action failed.", "error");
        }
        throw error;
      });
    };
  }

  function postForm(form) {
    return String(form.getAttribute("method") || "get").toUpperCase() === "POST";
  }

  function sameOriginAction(form) {
    try {
      const url = new URL(form.getAttribute("action") || window.location.href, window.location.href);
      return url.origin === window.location.origin ? url : null;
    } catch (_) {
      return null;
    }
  }

  function submitterFor(event, form) {
    if (event.submitter) return event.submitter;
    const active = document.activeElement;
    return active && form.contains(active) ? active : null;
  }

  function isSubmitLocked(form) {
    const until = Number(form.dataset.gitomiSubmitLockedUntil || "0");
    return Number.isFinite(until) && until > Date.now();
  }

  function setSubmitLock(form) {
    const until = Date.now() + submitLockMs;
    form.dataset.gitomiSubmitLockedUntil = String(until);
    window.setTimeout(function () {
      if (Number(form.dataset.gitomiSubmitLockedUntil || "0") <= until) {
        delete form.dataset.gitomiSubmitLockedUntil;
      }
    }, submitLockMs);
  }

  function submitControls(form, submitter) {
    const controls = Array.from(form.querySelectorAll("button:not([type]), button[type='submit'], input[type='submit'], input[type='image']"));
    if (submitter && controls.indexOf(submitter) === -1) controls.push(submitter);
    return controls;
  }

  function lockSubmitControls(form, submitter) {
    submitControls(form, submitter).forEach(function (control) {
      if (!control || control.dataset.gitomiSubmitLock === "yes") return;
      control.dataset.gitomiSubmitLock = "yes";
      control.dataset.gitomiWasDisabled = control.disabled ? "yes" : "no";
      control.disabled = true;
      window.setTimeout(function () {
        if (control.dataset.gitomiSubmitLock !== "yes") return;
        if (control.dataset.gitomiWasDisabled !== "yes") control.disabled = false;
        delete control.dataset.gitomiSubmitLock;
        delete control.dataset.gitomiWasDisabled;
      }, submitLockMs);
    });
  }

  function ensureSubmitterShadow(form, submitter) {
    if (!submitter || !submitter.name || submitter.tagName === "INPUT" && submitter.type === "image") return null;
    const shadow = document.createElement("input");
    shadow.type = "hidden";
    shadow.name = submitter.name;
    shadow.value = submitter.value || "";
    shadow.setAttribute("data-gitomi-submit-shadow", "");
    form.appendChild(shadow);
    return shadow;
  }

  function urlEncodedFormBody(form) {
    const data = new FormData(form);
    const params = new URLSearchParams();
    data.forEach(function (value, key) {
      if (typeof value === "string") params.append(key, value);
    });
    return params.toString();
  }

  function replaceDocument(html, url) {
    document.open();
    document.write(html);
    document.close();
    if (url && url !== window.location.href) {
      try {
        window.history.replaceState(null, "", url);
      } catch (_) {}
    }
  }

  async function submitPostForm(form, action, shadow) {
    const headers = {
      "Accept": "text/html,text/plain,*/*",
      "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"
    };
    const body = urlEncodedFormBody(form);
    if (shadow && shadow.parentNode) shadow.parentNode.removeChild(shadow);

    const response = await nativeFetch(action.href, {
      method: "POST",
      credentials: "same-origin",
      headers: headers,
      body: body,
      gitomiSuppressErrorNotification: true
    });

    if (response.redirected) {
      window.location.assign(response.url);
      return;
    }

    if (!response.ok) {
      notify(await responseMessage(response), "error");
      return;
    }

    if (response.status === 204) {
      window.location.reload();
      return;
    }

    const contentType = response.headers.get("Content-Type") || "";
    if (contentType.toLowerCase().indexOf("text/html") !== -1) {
      replaceDocument(await response.text(), response.url);
      return;
    }

    const text = await response.text();
    if (text.trim()) notify(text, "success");
  }

  function initSubmitLocks() {
    if (document.body.dataset.submitLocksReady === "yes") return;
    document.body.dataset.submitLocksReady = "yes";

    document.addEventListener("submit", function (event) {
      if (event.defaultPrevented) return;
      const form = event.target instanceof HTMLFormElement ? event.target : null;
      if (!form || !postForm(form)) return;

      if (isSubmitLocked(form)) {
        event.preventDefault();
        notify("That action is already running.", "error");
        return;
      }

      const submitter = submitterFor(event, form);
      const shadow = ensureSubmitterShadow(form, submitter);
      setSubmitLock(form);
      lockSubmitControls(form, submitter);

      const action = sameOriginAction(form);
      if (!nativeFetch || !action || form.enctype === "multipart/form-data") return;

      event.preventDefault();
      submitPostForm(form, action, shadow).catch(function (error) {
        notify(error && error.message ? error.message : "The action failed.", "error");
      });
    });
  }

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

  function normalizePickerValue(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
  }

  function pickerValues(hidden) {
    return String(hidden && hidden.value || "")
      .split(",")
      .map(normalizePickerValue)
      .filter(function (value, index, values) {
        return value.length > 0 && values.indexOf(value) === index;
      });
  }

  function setPickerOptionSelected(option, selected) {
    option.classList.toggle("is-selected", selected);
    option.setAttribute("aria-pressed", selected ? "true" : "false");
  }

  function pickerOptionValue(option) {
    return normalizePickerValue(option.dataset.value || option.getAttribute("data-value") || "");
  }

  function findPickerOption(picker, value) {
    const normalized = normalizePickerValue(value);
    return Array.from(picker.querySelectorAll("[data-issue-form-picker-option]")).find(function (option) {
      return pickerOptionValue(option) === normalized;
    }) || null;
  }

  function appendPickerFallbackContent(picker, item, value) {
    if ((picker.dataset.issueFormPickerKind || "") === "labels") {
      const label = document.createElement("span");
      label.className = "issue-label label-default";
      label.textContent = value;
      item.appendChild(label);
      return;
    }

    const avatar = document.createElement("span");
    avatar.className = "issue-form-assignee-dot";
    avatar.setAttribute("aria-hidden", "true");
    const name = document.createElement("span");
    name.className = "issue-sidebar-picker-primary";
    name.textContent = value;
    item.appendChild(avatar);
    item.appendChild(name);
  }

  function renderPickerSelected(picker, values) {
    const selectedRoot = picker.querySelector("[data-issue-form-picker-selected]");
    if (!selectedRoot) return;
    selectedRoot.textContent = "";

    if (!values.length) {
      const placeholder = document.createElement("span");
      placeholder.className = "issue-form-picker-placeholder";
      placeholder.textContent = picker.dataset.issueFormPickerEmpty || "None selected";
      selectedRoot.appendChild(placeholder);
      return;
    }

    values.forEach(function (value) {
      const item = document.createElement("span");
      item.className = "issue-form-selected-item";
      if ((picker.dataset.issueFormPickerKind || "") === "assignees") {
        item.className += " issue-form-selected-person";
      }

      const option = findPickerOption(picker, value);
      const content = option ? option.querySelector("[data-issue-form-picker-content]") : null;
      if (content) item.appendChild(content.cloneNode(true));
      else appendPickerFallbackContent(picker, item, value);
      selectedRoot.appendChild(item);
    });
  }

  function syncPicker(picker, values) {
    const hidden = picker.querySelector("[data-issue-form-picker-value]");
    if (!hidden) return;
    hidden.value = values.join(", ");
    picker.querySelectorAll("[data-issue-form-picker-option]").forEach(function (option) {
      setPickerOptionSelected(option, values.indexOf(pickerOptionValue(option)) !== -1);
    });
    renderPickerSelected(picker, values);
  }

  function makePickerFallbackContent(picker, value) {
    const content = document.createElement("span");
    content.className = "issue-form-picker-option-content";
    content.setAttribute("data-issue-form-picker-content", "");
    appendPickerFallbackContent(picker, content, value);
    return content;
  }

  function bindIssueFormPickerOption(picker, option) {
    if (option.dataset.issueFormPickerOptionReady === "yes") return;
    option.dataset.issueFormPickerOptionReady = "yes";
    option.addEventListener("click", function () {
      const hidden = picker.querySelector("[data-issue-form-picker-value]");
      if (!hidden) return;
      const value = pickerOptionValue(option);
      if (!value) return;
      const values = pickerValues(hidden);
      const index = values.indexOf(value);
      if (index === -1) values.push(value);
      else values.splice(index, 1);
      syncPicker(picker, values);
    });
  }

  function createIssueFormPickerOption(picker, value) {
    const normalized = normalizePickerValue(value);
    if (!normalized) return null;

    let option = findPickerOption(picker, normalized);
    if (option) return option;

    const customRoot = picker.querySelector("[data-issue-form-picker-custom-options]");
    if (!customRoot) return null;

    option = document.createElement("button");
    option.type = "button";
    option.className = "issue-sidebar-picker-row issue-form-picker-option";
    option.setAttribute("data-issue-form-picker-option", "");
    option.setAttribute("data-sidebar-filter-text", normalized);
    option.dataset.value = normalized;
    option.setAttribute("aria-pressed", "false");

    const check = document.createElement("span");
    check.className = "issue-sidebar-picker-check";
    check.setAttribute("aria-hidden", "true");
    option.appendChild(check);
    option.appendChild(makePickerFallbackContent(picker, normalized));
    customRoot.hidden = false;
    customRoot.appendChild(option);
    bindIssueFormPickerOption(picker, option);
    return option;
  }

  function addIssueFormPickerEntry(picker) {
    const input = picker.querySelector("[data-issue-form-picker-entry]");
    const hidden = picker.querySelector("[data-issue-form-picker-value]");
    if (!input || !hidden) return;
    const value = normalizePickerValue(input.value);
    if (!value) return;

    createIssueFormPickerOption(picker, value);
    const values = pickerValues(hidden);
    if (values.indexOf(value) === -1) values.push(value);
    syncPicker(picker, values);
    input.value = "";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.focus();
  }

  function initIssueFormPickers(root) {
    (root || document).querySelectorAll("[data-issue-form-picker]").forEach(function (picker) {
      if (picker.dataset.issueFormPickerReady === "yes") return;
      picker.dataset.issueFormPickerReady = "yes";

      const hidden = picker.querySelector("[data-issue-form-picker-value]");
      if (!hidden) return;

      picker.querySelectorAll("[data-issue-form-picker-option]").forEach(function (option) {
        bindIssueFormPickerOption(picker, option);
      });

      const addButton = picker.querySelector("[data-issue-form-picker-add]");
      if (addButton) {
        addButton.addEventListener("click", function () {
          addIssueFormPickerEntry(picker);
        });
      }

      const entry = picker.querySelector("[data-issue-form-picker-entry]");
      if (entry) {
        entry.addEventListener("keydown", function (event) {
          if (event.key !== "Enter") return;
          event.preventDefault();
          addIssueFormPickerEntry(picker);
        });
      }

      syncPicker(picker, pickerValues(hidden));
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
    initFetchErrorNotifications();
    initSubmitLocks();
    initPopoverMenus();
    initNavStats();
    initLabelsPage();
    initIssueFormPickers(document);
    initPullMergeMethodMenus();
    initAvatars(document);
    initIndexViewSnapshot();
  }

  document.addEventListener("gitomi:partial-refresh", function (event) {
    const detail = event.detail || {};
    initIssueFormPickers(detail.root || document);
    initAvatars(detail.root || document);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initUi);
  } else {
    initUi();
  }
}());
