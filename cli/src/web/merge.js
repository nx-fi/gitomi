(function () {
  "use strict";

  function lineText(row) {
    const code = row.querySelector("[data-merge-line-text]");
    return code ? code.textContent : "";
  }

  function plural(count, singular, pluralValue) {
    return count === 1 ? singular : pluralValue;
  }

  function unresolvedConflictCount(scope) {
    return scope.querySelectorAll("[data-conflict-actions]").length;
  }

  function mergeFiles(form) {
    return Array.from(form.querySelectorAll("[data-merge-file]"));
  }

  function unsupportedFiles(form) {
    return mergeFiles(form).filter((file) => file.classList.contains("is-unsupported"));
  }

  function unresolvedFiles(form) {
    return mergeFiles(form).filter((file) => unresolvedConflictCount(file) > 0);
  }

  function unresolvedActions(form) {
    return Array.from(form.querySelectorAll("[data-conflict-actions]"));
  }

  function fileLabel(count) {
    if (count === 0) return "Resolved";
    return count + " unresolved";
  }

  function linkLabel(file, count) {
    if (file.classList.contains("is-unsupported")) return "Unsupported";
    if (count === 0) return "Done";
    return count + " " + plural(count, "conflict", "conflicts");
  }

  function syncFile(file) {
    const textarea = file.querySelector("[data-merge-content]");
    if (textarea) {
      const lines = Array.from(file.querySelectorAll("[data-merge-line]"))
        .filter((row) => row.dataset.mergeDeleted !== "true")
        .map(lineText);
      textarea.value = lines.join("\n");
    }

    const unresolved = unresolvedConflictCount(file);
    const unsupported = file.classList.contains("is-unsupported");
    file.classList.toggle("is-resolved", !unsupported && unresolved === 0);
    const status = file.querySelector("[data-merge-file-status]");
    if (status && !unsupported) status.textContent = fileLabel(unresolved);

    const index = file.dataset.fileIndex || "";
    const link = document.querySelector('[data-merge-file-link][data-file-index="' + index + '"]');
    if (link) {
      link.classList.toggle("is-resolved", !unsupported && unresolved === 0);
      const linkStatus = link.querySelector("[data-merge-link-status]");
      if (linkStatus) linkStatus.textContent = linkLabel(file, unresolved);
    }
  }

  function refreshProgress(form) {
    const submit = form.querySelector("[data-merge-submit]");
    const submitLabel = form.querySelector("[data-merge-submit-label]");
    const progress = form.querySelector("[data-merge-progress]");
    const progressBar = form.querySelector("[data-merge-progress-bar]");

    const hasUnsupported = form.dataset.mergeUnsupported === "true";
    const unsupported = unsupportedFiles(form).length;
    const unresolved = unresolvedConflictCount(form);
    const total = Math.max(Number(form.dataset.mergeTotalConflicts || "0"), unresolved);
    const resolved = Math.max(0, total - unresolved);

    if (progress) {
      if (hasUnsupported && unsupported > 0) {
        progress.textContent = unresolved + " unresolved, " + unsupported + " unsupported";
      } else if (total === 0) {
        progress.textContent = "No editable conflicts";
      } else {
        progress.textContent = resolved + " of " + total + " " + plural(total, "conflict", "conflicts") + " resolved";
      }
    }

    if (progressBar) {
      const percentage = total === 0 ? 0 : Math.round((resolved / total) * 100);
      progressBar.style.width = Math.max(0, Math.min(100, percentage)) + "%";
    }

    if (!submit) return;
    submit.disabled = hasUnsupported || unresolved > 0;
    if (submitLabel) {
      if (hasUnsupported) {
        submitLabel.textContent = "Unsupported conflicts";
      } else if (unresolved > 0) {
        submitLabel.textContent = "Resolve " + unresolved + " " + plural(unresolved, "conflict", "conflicts");
      } else {
        submitLabel.textContent = "Commit resolution";
      }
    }
  }

  function cleanupResolvedRow(row) {
    row.classList.remove("merge-current", "merge-incoming", "merge-base", "merge-context-edited");
    row.classList.add("merge-resolved");
    row.removeAttribute("data-conflict-group");
    row.removeAttribute("data-conflict-side");
    const code = row.querySelector("[data-merge-line-text]");
    if (code) code.dataset.originalText = code.textContent;
  }

  function updateLineState(row) {
    if (!row || row.classList.contains("merge-marker") || row.dataset.mergeDeleted === "true") return;
    const code = row.querySelector("[data-merge-line-text]");
    if (!code) return;
    const original = code.dataset.originalText || "";
    const edited = code.textContent !== original || row.dataset.mergeInserted === "true";
    const contextEdit = edited && !row.hasAttribute("data-conflict-group");
    row.classList.toggle("merge-edited", edited);
    row.classList.toggle("merge-context-edited", contextEdit);
  }

  function updateFileLineStates(file) {
    file.querySelectorAll("[data-merge-line]").forEach(updateLineState);
  }

  function acceptConflict(button, mode) {
    const group = button.closest("[data-conflict-group]");
    if (!group) return;
    const file = group.closest("[data-merge-file]");
    if (!file) return;

    const groupId = group.dataset.conflictGroup || "";
    const rows = Array.from(file.querySelectorAll('[data-conflict-group="' + groupId + '"]'));
    if (rows.length === 0) return;

    const sides = mode === "both" ? new Set(["current", "incoming"]) : new Set([mode]);
    const chosen = rows.filter((row) => row.hasAttribute("data-merge-line") && sides.has(row.dataset.conflictSide || ""));
    const chosenSet = new Set(chosen);
    const first = rows[0];

    for (const row of chosen) {
      cleanupResolvedRow(row);
      first.parentNode.insertBefore(row, first);
    }
    for (const row of rows) {
      if (!chosenSet.has(row)) row.remove();
    }

    syncFile(file);
    updateFileLineStates(file);
    const form = file.closest("[data-merge-editor]");
    if (form) {
      refreshProgress(form);
      updateActiveFile(form);
    }
  }

  function scrollToRelativeConflict(form, direction) {
    const groups = unresolvedActions(form);
    if (groups.length === 0) return;
    const edge = Math.max(120, Math.round(window.innerHeight * 0.28));
    let current = -1;
    for (let index = 0; index < groups.length; index += 1) {
      const rect = groups[index].getBoundingClientRect();
      if (rect.top <= edge) {
        current = index;
      }
    }

    let next;
    if (direction > 0) {
      next = current < 0 ? 0 : Math.min(groups.length - 1, current + 1);
    } else {
      next = current < 0 ? groups.length - 1 : Math.max(0, current - 1);
    }
    groups[next].scrollIntoView({ block: "center", behavior: "smooth" });
  }

  function setCaret(element, offset) {
    const selection = window.getSelection();
    if (!selection) return;
    const text = element.firstChild || element;
    const range = document.createRange();
    range.setStart(text, Math.min(offset, text.textContent.length));
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function textSelectionOffsets(element) {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) {
      const length = element.textContent.length;
      return { start: length, end: length };
    }
    const range = selection.getRangeAt(0);
    if (!element.contains(range.commonAncestorContainer)) {
      const length = element.textContent.length;
      return { start: length, end: length };
    }

    const beforeStart = range.cloneRange();
    beforeStart.selectNodeContents(element);
    beforeStart.setEnd(range.startContainer, range.startOffset);
    const beforeEnd = range.cloneRange();
    beforeEnd.selectNodeContents(element);
    beforeEnd.setEnd(range.endContainer, range.endOffset);
    return { start: beforeStart.toString().length, end: beforeEnd.toString().length };
  }

  function cloneEditableRow(row, text) {
    const next = document.createElement("div");
    next.className = row.className;
    next.classList.remove("merge-edited", "merge-context-edited", "merge-line-deleted");
    next.classList.add("merge-inserted");
    next.dataset.mergeLine = "";
    next.dataset.mergeInserted = "true";
    if (row.hasAttribute("data-conflict-group")) next.dataset.conflictGroup = row.dataset.conflictGroup || "";
    if (row.hasAttribute("data-conflict-side")) next.dataset.conflictSide = row.dataset.conflictSide || "";

    const number = document.createElement("span");
    number.className = "merge-line-number";
    number.textContent = "+";

    const sourceCode = row.querySelector("[data-merge-line-text]");
    const code = document.createElement("code");
    code.className = sourceCode ? sourceCode.className.replace(/\bhljs\b/g, "").trim() : "";
    code.dataset.mergeLineText = "";
    code.dataset.originalText = "";
    code.contentEditable = "true";
    code.spellcheck = false;
    code.setAttribute("role", "textbox");
    code.setAttribute("aria-label", "Inserted merge line");
    code.textContent = text;

    next.appendChild(number);
    next.appendChild(code);
    return next;
  }

  function splitLineAtSelection(code) {
    const row = code.closest("[data-merge-line]");
    if (!row || row.classList.contains("merge-marker") || row.dataset.mergeDeleted === "true") return;

    const value = code.textContent;
    const offsets = textSelectionOffsets(code);
    const before = value.slice(0, offsets.start);
    const after = value.slice(offsets.end);
    code.textContent = before;

    const inserted = cloneEditableRow(row, after);
    row.parentNode.insertBefore(inserted, row.nextSibling);
    updateLineState(row);
    updateLineState(inserted);
    syncFile(row.closest("[data-merge-file]"));

    const nextCode = inserted.querySelector("[data-merge-line-text]");
    if (nextCode) {
      nextCode.focus();
      setCaret(nextCode, 0);
    }
  }

  function markLineDeleted(row) {
    const code = row.querySelector("[data-merge-line-text]");
    if (!code || row.classList.contains("merge-marker")) return false;

    if (row.dataset.mergeInserted === "true") {
      const focusTarget = row.previousElementSibling || row.nextElementSibling;
      row.remove();
      const nextCode = focusTarget && focusTarget.querySelector("[data-merge-line-text]");
      if (nextCode && nextCode.isContentEditable) nextCode.focus();
      return true;
    }

    row.dataset.mergeDeleted = "true";
    row.classList.remove("merge-edited", "merge-context-edited");
    row.classList.add("merge-line-deleted");
    code.dataset.deletedText = code.dataset.deletedText || code.textContent;
    code.removeAttribute("contenteditable");
    code.removeAttribute("role");
    code.textContent = "";

    const label = document.createElement("span");
    label.className = "merge-deleted-label";
    label.textContent = "Deleted line";
    const restore = document.createElement("button");
    restore.type = "button";
    restore.dataset.mergeRestoreLine = "";
    restore.textContent = "Restore";
    code.appendChild(label);
    code.appendChild(restore);
    return true;
  }

  function restoreDeletedLine(button) {
    const row = button.closest("[data-merge-line]");
    if (!row) return;
    const code = row.querySelector("[data-merge-line-text]");
    if (!code) return;
    const text = code.dataset.deletedText || code.dataset.originalText || "";
    delete row.dataset.mergeDeleted;
    row.classList.remove("merge-line-deleted");
    code.textContent = text;
    code.contentEditable = "true";
    code.spellcheck = false;
    code.setAttribute("role", "textbox");
    updateLineState(row);
    syncFile(row.closest("[data-merge-file]"));
    code.focus();
    setCaret(code, code.textContent.length);
  }

  function toggleFold(button) {
    const file = button.closest("[data-merge-file]");
    if (!file) return;
    const target = button.dataset.mergeFoldTarget || "";
    const rows = Array.from(file.querySelectorAll('[data-merge-fold-id="' + target + '"]'));
    const expanded = button.getAttribute("aria-expanded") === "true";
    rows.forEach((row) => {
      row.hidden = expanded;
    });
    button.setAttribute("aria-expanded", String(!expanded));
    const count = button.dataset.mergeFoldCount || String(rows.length);
    button.textContent = (expanded ? "Show " : "Hide ") + count + " unchanged " + plural(Number(count), "line", "lines");
  }

  function firstBlockingFile(form) {
    return unresolvedFiles(form)[0] || unsupportedFiles(form)[0] || null;
  }

  function setActiveFile(form, file) {
    mergeFiles(form).forEach((item) => item.classList.toggle("is-active", item === file));
    form.querySelectorAll("[data-merge-file-link]").forEach((link) => {
      const active = file && link.dataset.fileIndex === (file.dataset.fileIndex || "");
      link.classList.toggle("is-active", active);
    });
  }

  function updateActiveFile(form) {
    const files = mergeFiles(form);
    let activeFile = files[0] || null;
    let activeDistance = Number.POSITIVE_INFINITY;
    for (const file of files) {
      const rect = file.getBoundingClientRect();
      const distance = Math.abs(rect.top - 112);
      if (rect.bottom > 112 && distance < activeDistance) {
        activeFile = file;
        activeDistance = distance;
      }
    }
    setActiveFile(form, activeFile);
  }

  function scheduleActiveFile(form) {
    if (form.dataset.mergeActiveFrame === "true") return;
    form.dataset.mergeActiveFrame = "true";
    window.requestAnimationFrame(() => {
      delete form.dataset.mergeActiveFrame;
      updateActiveFile(form);
    });
  }

  function initMergeEditor() {
    const form = document.querySelector("[data-merge-editor]");
    if (!form) return;

    for (const file of form.querySelectorAll("[data-merge-file]")) {
      updateFileLineStates(file);
      syncFile(file);
    }
    refreshProgress(form);
    updateActiveFile(form);

    form.addEventListener("click", (event) => {
      const restore = event.target.closest("[data-merge-restore-line]");
      if (restore) {
        event.preventDefault();
        restoreDeletedLine(restore);
        refreshProgress(form);
        return;
      }

      const fold = event.target.closest("[data-merge-fold-toggle]");
      if (fold) {
        event.preventDefault();
        toggleFold(fold);
        updateActiveFile(form);
        return;
      }

      const action = event.target.closest("[data-merge-action]");
      if (action) {
        event.preventDefault();
        acceptConflict(action, action.dataset.mergeAction || "");
        return;
      }

      if (event.target.closest("[data-merge-prev]")) {
        event.preventDefault();
        scrollToRelativeConflict(form, -1);
        return;
      }

      if (event.target.closest("[data-merge-next]")) {
        event.preventDefault();
        scrollToRelativeConflict(form, 1);
      }
    });

    form.addEventListener("keydown", (event) => {
      const code = event.target.closest("[data-merge-line-text]");
      const currentRow = code ? code.closest("[data-merge-line]") : null;
      if (!code || (currentRow && currentRow.dataset.mergeDeleted === "true")) return;
      if (event.key === "Enter") {
        event.preventDefault();
        splitLineAtSelection(code);
        return;
      }

      if ((event.key === "Backspace" || event.key === "Delete") && code.textContent.length === 0) {
        const row = code.closest("[data-merge-line]");
        if (row && markLineDeleted(row)) {
          event.preventDefault();
          syncFile(row.closest("[data-merge-file]"));
        }
      }
    });

    form.addEventListener("input", (event) => {
      const code = event.target.closest("[data-merge-line-text]");
      if (!code) return;
      const file = code.closest("[data-merge-file]");
      if (!file) return;
      updateLineState(code.closest("[data-merge-line]"));
      syncFile(file);
      refreshProgress(form);
    });

    form.addEventListener("paste", (event) => {
      const target = event.target.closest("[data-merge-line-text]");
      if (!target) return;
      const text = event.clipboardData ? event.clipboardData.getData("text/plain") : "";
      if (!text) return;
      event.preventDefault();
      document.execCommand("insertText", false, text);
    });

    form.addEventListener("submit", (event) => {
      for (const file of form.querySelectorAll("[data-merge-file]")) {
        updateFileLineStates(file);
        syncFile(file);
      }
      refreshProgress(form);
      const blocked = firstBlockingFile(form);
      if (blocked) {
        event.preventDefault();
        blocked.scrollIntoView({ block: "start", behavior: "smooth" });
      }
    });

    window.addEventListener("scroll", () => scheduleActiveFile(form), { passive: true });
    window.addEventListener("resize", () => scheduleActiveFile(form));
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initMergeEditor);
  } else {
    initMergeEditor();
  }
})();
