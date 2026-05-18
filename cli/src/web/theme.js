(function () {
  "use strict";

  const themeKey = "gitomi.theme";
  const customCssKey = "gitomi.theme.customCss";
  const customModeKey = "gitomi.theme.customMode";
  const customStyleId = "gitomi-custom-theme-tokens";
  const themes = {
    light: { label: "Light", mode: "light" },
    dark: { label: "Dark", mode: "dark" },
    capucine: { label: "Capucine", mode: "light" },
    custom: { label: "Custom", mode: "light" },
  };

  function isTheme(value) {
    return Object.prototype.hasOwnProperty.call(themes, value);
  }

  function systemTheme() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function getStored(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  function setStored(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch (_) {}
  }

  function removeStored(key) {
    try {
      window.localStorage.removeItem(key);
    } catch (_) {}
  }

  function storedTheme() {
    const value = getStored(themeKey);
    return isTheme(value) ? value : null;
  }

  function customMode() {
    const value = getStored(customModeKey);
    return value === "dark" ? "dark" : "light";
  }

  function themeMode(theme) {
    if (theme === "custom") return customMode();
    return themes[theme] ? themes[theme].mode : "light";
  }

  function currentTheme() {
    const value = document.documentElement.dataset.theme;
    if (isTheme(value)) return value;
    return storedTheme() || systemTheme();
  }

  function applyCustomCss() {
    const css = getStored(customCssKey) || "";
    let style = document.getElementById(customStyleId);
    if (!css) {
      if (style) style.remove();
      return;
    }
    if (!style) {
      style = document.createElement("style");
      style.id = customStyleId;
      style.setAttribute("data-custom-theme-tokens", "");
      document.head.appendChild(style);
    }
    style.textContent = css;
  }

  function applyTheme(theme) {
    const nextTheme = isTheme(theme) ? theme : systemTheme();
    const mode = themeMode(nextTheme);
    document.documentElement.dataset.theme = nextTheme;
    document.documentElement.dataset.themeMode = mode;
    document.documentElement.style.colorScheme = mode;
    applyCustomCss();

    document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
      const isDark = mode === "dark";
      button.setAttribute("aria-pressed", String(isDark));
      button.setAttribute("aria-label", isDark ? "Switch to light mode" : "Switch to dark mode");
      button.setAttribute("title", isDark ? "Switch to light mode" : "Switch to dark mode");
    });

    document.querySelectorAll("[data-theme-choice]").forEach((input) => {
      input.checked = input.value === nextTheme;
    });
    document.querySelectorAll("[data-theme-option]").forEach((option) => {
      option.classList.toggle("selected", option.dataset.themeOption === nextTheme);
    });

    document.dispatchEvent(new CustomEvent("gitomi:themechange", {
      detail: { theme: nextTheme, mode },
    }));
  }

  function persistTheme(theme) {
    if (!isTheme(theme)) return;
    setStored(themeKey, theme);
    applyTheme(theme);
  }

  function toggleTheme() {
    persistTheme(themeMode(currentTheme()) === "dark" ? "light" : "dark");
  }

  function initThemeControls() {
    applyTheme(currentTheme());
    document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
      button.addEventListener("click", toggleTheme);
    });
  }

  function initThemeSettings() {
    const root = document.querySelector("[data-theme-settings]");
    if (!root) return;

    const customCss = root.querySelector("[data-theme-custom-css]");
    const customModeSelect = root.querySelector("[data-theme-custom-mode]");
    if (customCss) customCss.value = getStored(customCssKey) || "";
    if (customModeSelect) customModeSelect.value = customMode();

    root.querySelectorAll("[data-theme-choice]").forEach((input) => {
      input.checked = input.value === currentTheme();
      input.addEventListener("change", () => {
        if (input.checked) persistTheme(input.value);
      });
    });

    if (customModeSelect) {
      customModeSelect.addEventListener("change", () => {
        setStored(customModeKey, customModeSelect.value === "dark" ? "dark" : "light");
        if (currentTheme() === "custom") applyTheme("custom");
      });
    }

    const save = root.querySelector("[data-theme-save-custom]");
    if (save && customCss) {
      save.addEventListener("click", () => {
        setStored(customCssKey, customCss.value);
        persistTheme("custom");
      });
    }

    const reset = root.querySelector("[data-theme-reset-custom]");
    if (reset && customCss) {
      reset.addEventListener("click", () => {
        customCss.value = "";
        removeStored(customCssKey);
        applyCustomCss();
        if (currentTheme() === "custom") applyTheme("custom");
      });
    }
  }

  function init() {
    initThemeControls();
    initThemeSettings();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
