(function () {
  "use strict";

  const reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const typewriterObservers = [];

  function getCopyText(code) {
    const clone = code.cloneNode(true);
    clone.querySelectorAll(".prompt, [data-copy-exclude]").forEach((node) => node.remove());

    return (clone.textContent || "")
      .split(/\r?\n/)
      .map((line) => line.replace(/^\s*[$#>]\s+/, "").trim())
      .join("\n")
      .trim();
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

        try {
          await navigator.clipboard.writeText(getCopyText(code));
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
      let timeoutId = 0;
      let isDocumentVisible = !document.hidden;
      let isTargetVisible = true;
      target.textContent = words[wordIndex];

      function isNearViewport() {
        const rect = target.getBoundingClientRect();
        return rect.bottom >= -120 && rect.top <= window.innerHeight + 120;
      }

      function isActive() {
        return isDocumentVisible && isTargetVisible;
      }

      function clearTimer() {
        if (!timeoutId) return;
        window.clearTimeout(timeoutId);
        timeoutId = 0;
      }

      function schedule(delay) {
        clearTimer();
        if (!isActive()) return;
        timeoutId = window.setTimeout(tick, delay);
      }

      function syncTimer(delay) {
        if (isActive()) {
          if (!timeoutId) schedule(delay);
        } else {
          clearTimer();
        }
      }

      function tick() {
        timeoutId = 0;
        if (!isActive()) return;

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

        schedule(delay);
      }

      if ("IntersectionObserver" in window) {
        isTargetVisible = isNearViewport();
        const observer = new IntersectionObserver((entries) => {
          isTargetVisible = entries.some((entry) => entry.isIntersecting || entry.intersectionRatio > 0);
          syncTimer(180);
        }, { rootMargin: "120px 0px" });
        observer.observe(target);
        typewriterObservers.push(observer);
      }

      document.addEventListener("visibilitychange", () => {
        isDocumentVisible = !document.hidden;
        syncTimer(240);
      });

      schedule(900);
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
    let startScale = 2.32;
    let dockScale = 1.248;
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
      startScale = window.innerWidth <= 520 ? 1.84 : 2.32;
      dockScale = window.innerWidth <= 520 ? 1.088 : 1.248;
    }

    function update() {
      const scrollY = window.scrollY || 0;
      const progress = ease(clamp(scrollY / 320, 0, 1));
      const naturalTop = startTop - scrollY;
      const top = lerp(naturalTop, dockTop, progress);
      const left = lerp(startLeft, dockLeft, progress);
      const scale = lerp(startScale, dockScale, progress);

      brand.style.setProperty("--brand-top", `${top.toFixed(2)}px`);
      brand.style.setProperty("--brand-left", `${left.toFixed(2)}px`);
      brand.style.setProperty("--brand-scale", scale.toFixed(3));
      brand.classList.toggle("is-docked", progress > 0.92);
      brand.classList.toggle("is-interpolating", progress > 0.02 && progress < 0.92);
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
