(function () {
  "use strict";

  function setButtonState(button, label) {
    button.textContent = label;
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

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initCopyButtons);
  } else {
    initCopyButtons();
  }
})();
