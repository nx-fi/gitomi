(function () {
  "use strict";

  /** @type {NodeListOf<HTMLAnchorElement>} */
  const navLinks = document.querySelectorAll(".site-topbar nav a[href^='#']");
  /** @type {HTMLElement[]} */
  const sections = Array.from(document.querySelectorAll("main section[id]"));

  function setActiveNav() {
    let activeId = sections[0] ? sections[0].id : "";
    for (const section of sections) {
      const rect = section.getBoundingClientRect();
      if (rect.top <= 140) activeId = section.id;
    }
    navLinks.forEach((link) => {
      link.classList.toggle("active", link.hash === "#" + activeId);
    });
  }

  function initCopyButtons() {
    document.querySelectorAll("[data-copy-command]").forEach((button) => {
      button.addEventListener("click", async () => {
        const card = button.closest(".command-code");
        const code = card ? card.querySelector("code") : null;
        if (!code || !navigator.clipboard) return;

        const previousLabel = button.getAttribute("aria-label") || "Copy command";
        button.setAttribute("aria-label", "Copied");
        button.classList.add("is-copied");
        await navigator.clipboard.writeText(code.textContent || "");
        window.setTimeout(() => {
          button.setAttribute("aria-label", previousLabel);
          button.classList.remove("is-copied");
        }, 1200);
      });
    });
  }

  window.addEventListener("scroll", setActiveNav, { passive: true });
  window.addEventListener("resize", setActiveNav);
  initCopyButtons();
  setActiveNav();
})();

