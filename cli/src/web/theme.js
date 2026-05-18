(function () {
  "use strict";

  const themeKey = "gitomi.theme";
  const modeKey = "gitomi.themeMode";
  const customCssKey = "gitomi.theme.customCss";
  const legacyCustomModeKey = "gitomi.theme.customMode";
  const customStyleId = "gitomi-custom-theme-tokens";
  const themeStyleId = "gitomi-theme-stylesheet";
  const themes = {
    gitomi: { label: "Gitomi" },
    capucine: { label: "Capucine" },
  };

  function isTheme(value) {
    return Object.prototype.hasOwnProperty.call(themes, value);
  }

  function isMode(value) {
    return value === "light" || value === "dark";
  }

  function systemMode() {
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

  function normalizeTheme(value) {
    return isTheme(value) ? value : "gitomi";
  }

  function normalizeMode(value) {
    return isMode(value) ? value : systemMode();
  }

  function storedTheme() {
    return normalizeTheme(getStored(themeKey));
  }

  function storedMode() {
    const value = getStored(modeKey);
    if (isMode(value)) return value;

    const legacyTheme = getStored(themeKey);
    if (isMode(legacyTheme)) return legacyTheme;

    const legacyCustomMode = getStored(legacyCustomModeKey);
    if (isMode(legacyCustomMode)) return legacyCustomMode;

    return systemMode();
  }

  function currentTheme() {
    return normalizeTheme(document.documentElement.dataset.theme || getStored(themeKey));
  }

  function currentMode() {
    return normalizeMode(document.documentElement.dataset.themeMode || getStored(modeKey));
  }

  function themeAssetVersion() {
    const link = document.getElementById(themeStyleId);
    return (link && link.dataset.themeVersion) || window.gitomiThemeAssetVersion || "";
  }

  function themeHref(theme) {
    const version = themeAssetVersion();
    return `/themes/${theme}.css${version ? `?v=${encodeURIComponent(version)}` : ""}`;
  }

  function ensureThemeStylesheet(theme) {
    let link = document.getElementById(themeStyleId);
    if (!link) {
      link = document.createElement("link");
      link.id = themeStyleId;
      link.rel = "stylesheet";
      link.setAttribute("data-theme-stylesheet", "");
      if (window.gitomiThemeAssetVersion) link.dataset.themeVersion = window.gitomiThemeAssetVersion;
      document.head.appendChild(link);
    }
    const href = themeHref(theme);
    const current = link.getAttribute("href") || "";
    if (current !== href) link.setAttribute("href", href);
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

  function applyThemeState(theme, mode) {
    const nextTheme = normalizeTheme(theme);
    const nextMode = normalizeMode(mode);
    document.documentElement.dataset.theme = nextTheme;
    document.documentElement.dataset.themeMode = nextMode;
    document.documentElement.style.colorScheme = nextMode;
    ensureThemeStylesheet(nextTheme);
    applyCustomCss();

    document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
      const isDark = nextMode === "dark";
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
      detail: { theme: nextTheme, mode: nextMode },
    }));
  }

  function persistTheme(theme) {
    const nextTheme = normalizeTheme(theme);
    setStored(themeKey, nextTheme);
    applyThemeState(nextTheme, currentMode());
  }

  function persistMode(mode) {
    const nextMode = normalizeMode(mode);
    setStored(modeKey, nextMode);
    applyThemeState(currentTheme(), nextMode);
  }

  function migrateLegacyThemeState() {
    const stored = getStored(themeKey);
    if (stored === "light" || stored === "dark") {
      setStored(modeKey, stored);
      setStored(themeKey, "gitomi");
    } else if (!isTheme(stored)) {
      setStored(themeKey, "gitomi");
    }
    removeStored(legacyCustomModeKey);
  }

  function toggleMode() {
    persistMode(currentMode() === "dark" ? "light" : "dark");
  }

  function initThemeControls() {
    migrateLegacyThemeState();
    applyThemeState(storedTheme(), storedMode());
    document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
      button.addEventListener("click", toggleMode);
    });
  }

  function initThemeSettings() {
    const root = document.querySelector("[data-theme-settings]");
    if (!root) return;

    const customCss = root.querySelector("[data-theme-custom-css]");
    if (customCss) customCss.value = getStored(customCssKey) || "";

    root.querySelectorAll("[data-theme-choice]").forEach((input) => {
      input.checked = input.value === currentTheme();
      input.addEventListener("change", () => {
        if (input.checked) persistTheme(input.value);
      });
    });

    const save = root.querySelector("[data-theme-save-custom]");
    if (save && customCss) {
      save.addEventListener("click", () => {
        setStored(customCssKey, customCss.value);
        applyThemeState(currentTheme(), currentMode());
      });
    }

    const reset = root.querySelector("[data-theme-reset-custom]");
    if (reset && customCss) {
      reset.addEventListener("click", () => {
        customCss.value = "";
        removeStored(customCssKey);
        applyCustomCss();
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
