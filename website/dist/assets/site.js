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

  function initParallax() {
    if (reduceMotion) return;

    const layers = Array.from(document.querySelectorAll("[data-parallax]"));
    if (!layers.length) return;

    let pointerX = 0;
    let pointerY = 0;
    let ticking = false;

    function clamp(value, min, max) {
      return Math.min(max, Math.max(min, value));
    }

    function update() {
      const viewportHeight = window.innerHeight || 1;

      layers.forEach((layer) => {
        const depth = Number.parseFloat(layer.getAttribute("data-depth") || "10");
        const rect = layer.getBoundingClientRect();
        const centerOffset = rect.top + rect.height / 2 - viewportHeight / 2;
        const progress = clamp(centerOffset / (viewportHeight * 0.7), -1, 1);
        const explode = clamp(Math.abs(progress) * 1.18, 0, 1);
        const scrollX = progress * depth * 4.2;
        const scrollY = -progress * Math.abs(depth) * 8.6;
        const rotate = progress * depth * 0.08;
        const mouseX = pointerX * depth * 0.72;
        const mouseY = pointerY * Math.abs(depth) * 0.42;

        layer.style.setProperty("--progress", progress.toFixed(3));
        layer.style.setProperty("--explode", explode.toFixed(3));
        layer.style.setProperty("--mouse-x", `${mouseX.toFixed(2)}px`);
        layer.style.setProperty("--mouse-y", `${mouseY.toFixed(2)}px`);
        layer.style.setProperty("--scroll-x", `${scrollX.toFixed(2)}px`);
        layer.style.setProperty("--scroll-y", `${scrollY.toFixed(2)}px`);
        layer.style.setProperty("--scroll-rotate", `${rotate.toFixed(2)}deg`);
      });

      ticking = false;
    }

    function requestUpdate() {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(update);
    }

    window.addEventListener(
      "pointermove",
      (event) => {
        pointerX = (event.clientX / Math.max(window.innerWidth, 1) - 0.5) * 2;
        pointerY = (event.clientY / Math.max(window.innerHeight, 1) - 0.5) * 2;
        requestUpdate();
      },
      { passive: true }
    );
    window.addEventListener("scroll", requestUpdate, { passive: true });
    window.addEventListener("resize", requestUpdate);
    requestUpdate();
  }

  initCopyButtons();
  initTypewriter();
  initParallax();
})();
