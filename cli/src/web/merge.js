(function () {
  "use strict";

  function lineText(row) {
    const code = row.querySelector("[data-merge-line-text]");
    return code ? code.textContent : "";
  }

  function syncFile(file) {
    const textarea = file.querySelector("[data-merge-content]");
    if (!textarea) return;
    const lines = Array.from(file.querySelectorAll("[data-merge-line]")).map(lineText);
    textarea.value = lines.join("\n");

    const unresolved = file.querySelector("[data-conflict-group]") != null;
    file.classList.toggle("is-resolved", !unresolved);
    const status = file.querySelector("[data-merge-file-status]");
    if (status) status.textContent = unresolved ? "Unresolved" : "Resolved";

    const index = file.dataset.fileIndex || "";
    const link = document.querySelector('[data-merge-file-link][data-file-index="' + index + '"]');
    if (link) link.classList.toggle("is-resolved", !unresolved);
  }

  function refreshSubmit(form) {
    const submit = form.querySelector("[data-merge-submit]");
    if (!submit) return;
    const hasUnsupported = form.dataset.mergeUnsupported === "true";
    const hasConflicts = form.querySelector("[data-conflict-group]") != null;
    submit.disabled = hasUnsupported || hasConflicts;
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
    refreshSubmit(file.closest("[data-merge-editor]"));
  }

  function unresolvedFiles(form) {
    return Array.from(form.querySelectorAll("[data-merge-file]")).filter((file) => file.querySelector("[data-conflict-group]"));
  }

  function scrollToRelativeFile(form, direction) {
    const files = unresolvedFiles(form);
    if (files.length === 0) return;
    const current = files.findIndex((file) => file.getBoundingClientRect().bottom > 120);
    const next = current < 0
      ? 0
      : Math.max(0, Math.min(files.length - 1, current + direction));
    files[next].scrollIntoView({ block: "start", behavior: "smooth" });
  }

  function initMergeEditor() {
    const form = document.querySelector("[data-merge-editor]");
    if (!form) return;

    for (const file of form.querySelectorAll("[data-merge-file]")) syncFile(file);
    refreshSubmit(form);

    form.addEventListener("click", (event) => {
      const action = event.target.closest("[data-merge-action]");
      if (action) {
        event.preventDefault();
        acceptConflict(action, action.dataset.mergeAction || "");
        return;
      }

      if (event.target.closest("[data-merge-prev]")) {
        event.preventDefault();
        scrollToRelativeFile(form, -1);
        return;
      }

      if (event.target.closest("[data-merge-next]")) {
        event.preventDefault();
        scrollToRelativeFile(form, 1);
      }
    });

    form.addEventListener("input", (event) => {
      if (!event.target.matches("[data-merge-line-text]")) return;
      const file = event.target.closest("[data-merge-file]");
      if (!file) return;
      syncFile(file);
    });

    form.addEventListener("submit", (event) => {
      for (const file of form.querySelectorAll("[data-merge-file]")) syncFile(file);
      const firstUnresolved = unresolvedFiles(form)[0];
      if (firstUnresolved || form.dataset.mergeUnsupported === "true") {
        event.preventDefault();
        if (firstUnresolved) firstUnresolved.scrollIntoView({ block: "start", behavior: "smooth" });
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initMergeEditor);
  } else {
    initMergeEditor();
  }
})();
