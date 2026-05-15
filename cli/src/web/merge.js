(function () {
  "use strict";

  function lineText(row) {
    const code = row.querySelector("[data-merge-line-text]");
    return code ? code.textContent : "";
  }

  function plural(count, singular, pluralValue) {
    return count === 1 ? singular : pluralValue;
  }

  function conflictIds(scope) {
    const ids = new Set();
    scope.querySelectorAll("[data-conflict-group]").forEach((node) => {
      const id = node.dataset.conflictGroup || "";
      if (id) ids.add(id);
    });
    return ids;
  }

  function unresolvedConflictCount(scope) {
    return conflictIds(scope).size;
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
      const lines = Array.from(file.querySelectorAll("[data-merge-line]")).map(lineText);
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
    row.classList.remove("merge-current", "merge-incoming", "merge-base");
    row.classList.add("merge-resolved");
    row.removeAttribute("data-conflict-group");
    row.removeAttribute("data-conflict-side");
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
    const form = file.closest("[data-merge-editor]");
    if (form) {
      refreshProgress(form);
      updateActiveFile(form);
    }
  }

  function scrollToRelativeConflict(form, direction) {
    const groups = unresolvedActions(form);
    if (groups.length === 0) return;
    const edge = 120;
    let current;
    if (direction > 0) {
      current = groups.findIndex((group) => group.getBoundingClientRect().top > edge);
    } else {
      current = -1;
      for (let index = groups.length - 1; index >= 0; index -= 1) {
        if (groups[index].getBoundingClientRect().top < edge) {
          current = index;
          break;
        }
      }
    }
    const next = current < 0
      ? (direction > 0 ? 0 : groups.length - 1)
      : Math.max(0, Math.min(groups.length - 1, current));
    groups[next].scrollIntoView({ block: "center", behavior: "smooth" });
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

    for (const file of form.querySelectorAll("[data-merge-file]")) syncFile(file);
    refreshProgress(form);
    updateActiveFile(form);

    form.addEventListener("click", (event) => {
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

    form.addEventListener("input", (event) => {
      if (!event.target.matches("[data-merge-line-text]")) return;
      const file = event.target.closest("[data-merge-file]");
      if (!file) return;
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
      for (const file of form.querySelectorAll("[data-merge-file]")) syncFile(file);
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
