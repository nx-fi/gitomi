(function () {
  "use strict";

  const symbolsStorageKey = "gitomi.symbolsPanel";

  function setButtonState(button, label) {
    button.textContent = label;
  }

  function storedSymbolsVisible() {
    try {
      return window.localStorage.getItem(symbolsStorageKey) !== "hidden";
    } catch (_) {
      return true;
    }
  }

  function storeSymbolsVisible(visible) {
    try {
      if (visible) {
        window.localStorage.removeItem(symbolsStorageKey);
      } else {
        window.localStorage.setItem(symbolsStorageKey, "hidden");
      }
    } catch (_) {}
  }

  function setSymbolsVisible(layout, sidebar, button, visible, persist) {
    layout.classList.toggle("symbols-collapsed", !visible);
    sidebar.hidden = !visible;
    button.setAttribute("aria-expanded", String(visible));
    button.textContent = visible ? "Hide symbols" : "Show symbols";
    button.title = visible ? "Hide symbols panel" : "Show symbols panel";
    if (persist) storeSymbolsVisible(visible);
  }

  function initSymbolsToggle(button) {
    const sidebarId = button.getAttribute("aria-controls");
    const sidebar = sidebarId ? document.getElementById(sidebarId) : document.querySelector("[data-symbols-sidebar]");
    const layout = button.closest(".code-layout") || document.querySelector(".code-layout.has-symbols");
    if (!sidebar || !layout) return;

    setSymbolsVisible(layout, sidebar, button, storedSymbolsVisible(), false);
    button.addEventListener("click", function () {
      setSymbolsVisible(layout, sidebar, button, button.getAttribute("aria-expanded") !== "true", true);
    });
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.top = "-1000px";
    document.body.appendChild(textarea);
    textarea.select();
    try {
      document.execCommand("copy");
    } finally {
      textarea.remove();
    }
  }

  function initCopyButton(button) {
    button.addEventListener("click", async function () {
      const url = button.dataset.copyRaw;
      if (!url) return;

      const original = button.textContent || "Copy";
      button.disabled = true;
      setButtonState(button, "Copying");
      try {
        const response = await fetch(url, { cache: "no-store" });
        if (!response.ok) throw new Error("Raw fetch failed");
        await copyText(await response.text());
        setButtonState(button, "Copied");
      } catch (_) {
        setButtonState(button, "Failed");
      } finally {
        window.setTimeout(function () {
          button.disabled = false;
          setButtonState(button, original);
        }, 1200);
      }
    });
  }

  function initCopyButtons() {
    document.querySelectorAll("[data-copy-raw]").forEach(initCopyButton);
  }

  function initSymbolsToggles() {
    document.querySelectorAll("[data-symbols-toggle]").forEach(initSymbolsToggle);
  }

  function initCodeControls() {
    initCopyButtons();
    initSymbolsToggles();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initCodeControls);
  } else {
    initCodeControls();
  }
})();
