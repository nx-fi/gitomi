(function () {
  "use strict";

  const reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function initCopyButtons() {
    document.querySelectorAll("[data-copy-command]").forEach((button) => {
      button.addEventListener("click", async () => {
        const card = button.closest(".command-code");
        const code = card ? card.querySelector("code") : null;
        if (!code || !navigator.clipboard) return;

        const previousLabel = button.getAttribute("aria-label") || "Copy command";
        button.setAttribute("aria-label", "Copied");
        button.classList.add("is-copied");

        try {
          await navigator.clipboard.writeText(code.textContent || "");
        } finally {
          window.setTimeout(() => {
            button.setAttribute("aria-label", previousLabel);
            button.classList.remove("is-copied");
          }, 1200);
        }
      });
    });
  }

  function initTypewriter() {
    document.querySelectorAll("[data-typewriter]").forEach((target) => {
      const words = (target.getAttribute("data-words") || "")
        .split("|")
        .map((word) => word.trim())
        .filter(Boolean);
      if (!words.length) return;

      if (reduceMotion) {
        target.textContent = words[0];
        return;
      }

      const initialWord = target.textContent ? target.textContent.trim() : "";
      let wordIndex = Math.max(words.indexOf(initialWord), 0);
      let charIndex = words[wordIndex].length;
      let deleting = false;
      target.textContent = words[wordIndex];

      function tick() {
        const word = words[wordIndex];
        let delay = 58;

        if (deleting) {
          charIndex -= 1;
          target.textContent = word.slice(0, charIndex);
          delay = 34;
          if (charIndex === 0) {
            deleting = false;
            wordIndex = (wordIndex + 1) % words.length;
            delay = 300;
          }
        } else if (charIndex < word.length) {
          charIndex += 1;
          target.textContent = word.slice(0, charIndex);
        } else {
          deleting = true;
          delay = 1200;
        }

        window.setTimeout(tick, delay);
      }

      window.setTimeout(tick, 900);
    });
  }

  function initFloatingBrand() {
    const brand = document.querySelector("[data-floating-brand]");
    const slot = document.querySelector("[data-brand-slot]");
    if (!brand || !slot) return;

    let startTop = 0;
    let startLeft = 0;
    let dockTop = 18;
    let dockLeft = 18;
    let startScale = 1.16;
    let dockScale = 0.78;
    let ticking = false;

    function clamp(value, min, max) {
      return Math.min(max, Math.max(min, value));
    }

    function ease(value) {
      return value * value * (3 - 2 * value);
    }

    function lerp(from, to, amount) {
      return from + (to - from) * amount;
    }

    function measure() {
      const rect = slot.getBoundingClientRect();
      startTop = rect.top + window.scrollY;
      startLeft = rect.left;
      dockTop = window.innerWidth <= 820 ? 12 : 18;
      dockLeft = window.innerWidth <= 820 ? 12 : 18;
      startScale = window.innerWidth <= 520 ? 0.92 : 1.16;
      dockScale = window.innerWidth <= 520 ? 0.68 : 0.78;
    }

    function update() {
      const scrollY = window.scrollY || window.pageYOffset || 0;
      const progress = ease(clamp(scrollY / 320, 0, 1));
      const naturalTop = startTop - scrollY;
      const top = lerp(naturalTop, dockTop, progress);
      const left = lerp(startLeft, dockLeft, progress);
      const scale = lerp(startScale, dockScale, progress);

      brand.style.setProperty("--brand-top", `${top.toFixed(2)}px`);
      brand.style.setProperty("--brand-left", `${left.toFixed(2)}px`);
      brand.style.setProperty("--brand-scale", scale.toFixed(3));
      brand.classList.toggle("is-docked", progress > 0.92);
      ticking = false;
    }

    function requestUpdate() {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(update);
    }

    measure();
    update();
    window.addEventListener("scroll", requestUpdate, { passive: true });
    window.addEventListener("resize", () => {
      measure();
      requestUpdate();
    });
  }

  initCopyButtons();
  initTypewriter();
  initFloatingBrand();
})();
