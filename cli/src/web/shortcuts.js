(function () {
  "use strict";

  const defaultConfig = {
    leader: "Space",
    keys: "A S D F J K L E R U I O W Q P Z X C V B N M G H Y T",
    sequenceTimeoutMs: 900,
  };
  const targetSelector = [
    "a[href]",
    "button",
    "summary",
    "input[type='button']",
    "input[type='submit']",
    "input[type='reset']",
    "input[type='checkbox']",
    "input[type='radio']",
    "select",
    "[role='button']",
    "[role='link']",
    "[role='menuitem']",
    "[onclick]",
  ].join(",");

  let active = false;
  let hints = [];
  let sequence = [];
  let layer = null;
  let timer = 0;
  let layoutFrame = 0;
  let shortcutConfig = null;

  function specialToken(value) {
    const normalized = String(value || "").trim().toLowerCase();
    if (value === " " || normalized === "space" || normalized === "spacebar") return "Space";
    if (normalized === "esc" || normalized === "escape") return "Escape";
    if (normalized === "return" || normalized === "enter") return "Enter";
    if (normalized === "tab") return "Tab";
    if (normalized === "backspace") return "Backspace";
    if (normalized === "arrowup" || normalized === "up") return "ArrowUp";
    if (normalized === "arrowdown" || normalized === "down") return "ArrowDown";
    if (normalized === "arrowleft" || normalized === "left") return "ArrowLeft";
    if (normalized === "arrowright" || normalized === "right") return "ArrowRight";
    return null;
  }

  function normalizeToken(value) {
    const special = specialToken(value);
    if (special) return special;

    const trimmed = String(value || "").trim();
    if (trimmed.length === 1) return trimmed.toUpperCase();
    return trimmed;
  }

  function tokenFromEvent(event) {
    if (event.code === "Space" || event.key === " ") return "Space";
    return normalizeToken(event.key);
  }

  function parseKeyTokens(value, leader) {
    let raw = [];
    if (Array.isArray(value)) {
      raw = value;
    } else {
      const text = String(value || "");
      raw = /\s/.test(text) ? text.trim().split(/\s+/) : Array.from(text);
    }

    const seen = new Set();
    const keys = [];
    raw.forEach((item) => {
      const token = normalizeToken(item);
      if (!token || token === leader || seen.has(token)) return;
      seen.add(token);
      keys.push(token);
    });
    return keys;
  }

  function readConfig() {
    const raw = window.gitomiShortcutConfig || {};
    const leader = normalizeToken(raw.leader || defaultConfig.leader) || defaultConfig.leader;
    let keys = parseKeyTokens(raw.keys || defaultConfig.keys, leader);
    if (keys.length === 0) keys = parseKeyTokens(defaultConfig.keys, leader);

    const timeout = Number(raw.sequenceTimeoutMs);
    return {
      leader,
      keys,
      sequenceTimeoutMs: Number.isFinite(timeout) ? Math.max(150, Math.min(5000, timeout)) : defaultConfig.sequenceTimeoutMs,
    };
  }

  function isEditingTarget(target) {
    if (!target || !(target instanceof Element)) return false;
    const editable = target.closest("input, textarea, select, [contenteditable='true'], [contenteditable='']");
    if (!editable) return false;
    if (editable.matches("input")) {
      const type = (editable.getAttribute("type") || "text").toLowerCase();
      return !["button", "checkbox", "radio", "reset", "submit"].includes(type);
    }
    return true;
  }

  function isDisabled(element) {
    return Boolean(
      element.disabled ||
      element.getAttribute("aria-disabled") === "true" ||
      element.closest("[hidden], [inert]"),
    );
  }

  function visibleRect(element) {
    const style = window.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || style.pointerEvents === "none") return null;

    const rects = Array.from(element.getClientRects());
    for (const rect of rects) {
      if (rect.width < 1 || rect.height < 1) continue;
      if (rect.bottom < 0 || rect.top > window.innerHeight || rect.right < 0 || rect.left > window.innerWidth) continue;
      return rect;
    }
    return null;
  }

  function isShortcutTarget(element) {
    if (!(element instanceof HTMLElement)) return false;
    if (element.closest(".gitomi-shortcut-layer")) return false;
    if (isDisabled(element)) return false;
    if (element.matches("a[href]") && !element.getAttribute("href")) return false;
    return visibleRect(element) !== null;
  }

  function collectTargets() {
    const seen = new Set();
    const targets = [];
    document.querySelectorAll(targetSelector).forEach((element) => {
      if (seen.has(element) || !isShortcutTarget(element)) return;
      seen.add(element);
      targets.push(element);
    });
    return targets;
  }

  function sequenceLength(count, keyCount) {
    let length = 1;
    let capacity = keyCount;
    while (count > capacity && length < 5) {
      length += 1;
      capacity *= keyCount;
    }
    return length;
  }

  function capacityFor(length, keyCount) {
    let capacity = 1;
    for (let i = 0; i < length; i += 1) capacity *= keyCount;
    return capacity;
  }

  function sequenceForIndex(index, length, keys) {
    const result = new Array(length);
    let value = index;
    for (let i = length - 1; i >= 0; i -= 1) {
      result[i] = keys[value % keys.length];
      value = Math.floor(value / keys.length);
    }
    return result;
  }

  function ensureLayer() {
    if (layer) return layer;
    layer = document.createElement("div");
    layer.className = "gitomi-shortcut-layer";
    layer.setAttribute("aria-hidden", "true");
    document.body.appendChild(layer);
    return layer;
  }

  function positionHint(hint) {
    if (hint.sequenceVisible === false) {
      hint.node.hidden = true;
      return;
    }

    const rect = visibleRect(hint.target);
    if (!rect) {
      hint.node.hidden = true;
      return;
    }

    hint.node.hidden = false;
    const width = hint.node.offsetWidth;
    const height = hint.node.offsetHeight;
    const gap = 5;
    const margin = 4;
    let left = rect.right + gap;
    let top = rect.top + Math.min(4, Math.max(0, rect.height - height));

    if (left + width > window.innerWidth - margin) {
      left = rect.left + gap;
    }
    if (top + height > window.innerHeight - margin) {
      top = rect.bottom - height - gap;
    }

    hint.node.style.transform = `translate(${Math.max(margin, left)}px, ${Math.max(margin, top)}px)`;
  }

  function layoutHints() {
    layoutFrame = 0;
    hints.forEach(positionHint);
  }

  function scheduleLayout() {
    if (!active || layoutFrame !== 0) return;
    layoutFrame = window.requestAnimationFrame(layoutHints);
  }

  function clearTimer() {
    if (!timer) return;
    window.clearTimeout(timer);
    timer = 0;
  }

  function scheduleCancel(delay) {
    clearTimer();
    timer = window.setTimeout(cancelHints, delay);
  }

  function cancelHints() {
    active = false;
    sequence = [];
    hints = [];
    clearTimer();
    if (layoutFrame) {
      window.cancelAnimationFrame(layoutFrame);
      layoutFrame = 0;
    }
    if (layer) layer.replaceChildren();
  }

  function sequenceStartsWith(keys, prefix) {
    if (prefix.length > keys.length) return false;
    for (let i = 0; i < prefix.length; i += 1) {
      if (keys[i] !== prefix[i]) return false;
    }
    return true;
  }

  function sameSequence(a, b) {
    return a.length === b.length && sequenceStartsWith(a, b);
  }

  function updateMatchedHints() {
    hints.forEach((hint) => {
      const matched = sequenceStartsWith(hint.keys, sequence);
      hint.sequenceVisible = matched;
      hint.node.hidden = !matched;
      hint.node.classList.toggle("is-pending", matched && sequence.length > 0);
    });
    scheduleLayout();
  }

  function activateHint(hint) {
    const target = hint.target;
    cancelHints();
    if (!document.contains(target) || isDisabled(target)) return;

    try {
      target.focus({ preventScroll: true });
    } catch (_) {
      try {
        target.focus();
      } catch (_) {}
    }
    target.click();
  }

  function showHints() {
    const config = shortcutConfig || readConfig();
    const targets = collectTargets();
    if (targets.length === 0 || config.keys.length === 0) return;

    cancelHints();
    active = true;
    shortcutConfig = config;

    const length = sequenceLength(targets.length, config.keys.length);
    const capacity = capacityFor(length, config.keys.length);
    const layerNode = ensureLayer();

    targets.slice(0, capacity).forEach((target, index) => {
      const keys = sequenceForIndex(index, length, config.keys);
      const node = document.createElement("span");
      const kbd = document.createElement("kbd");
      node.className = "gitomi-shortcut-hint";
      kbd.textContent = keys.join(" ");
      node.appendChild(kbd);
      layerNode.appendChild(node);
      hints.push({ target, keys, node, sequenceVisible: true });
    });

    layoutHints();
    scheduleCancel(Math.max(2500, config.sequenceTimeoutMs * 3));
  }

  function handleActiveKey(event, token) {
    event.preventDefault();
    event.stopPropagation();

    if (token === "Escape") {
      cancelHints();
      return;
    }

    const config = shortcutConfig || readConfig();
    if (!config.keys.includes(token)) {
      cancelHints();
      return;
    }

    sequence.push(token);
    const matches = hints.filter((hint) => sequenceStartsWith(hint.keys, sequence));
    if (matches.length === 0) {
      cancelHints();
      return;
    }

    const exact = matches.find((hint) => sameSequence(hint.keys, sequence));
    if (exact) {
      activateHint(exact);
      return;
    }

    updateMatchedHints();
    scheduleCancel(config.sequenceTimeoutMs);
  }

  function onKeyDown(event) {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;

    const token = tokenFromEvent(event);
    if (!token) return;

    if (active) {
      handleActiveKey(event, token);
      return;
    }

    if (event.defaultPrevented || isEditingTarget(event.target)) return;

    const config = shortcutConfig || readConfig();
    if (token !== config.leader) return;

    event.preventDefault();
    event.stopPropagation();
    showHints();
  }

  function initShortcuts() {
    shortcutConfig = readConfig();
    document.addEventListener("keydown", onKeyDown, true);
    document.addEventListener("pointerdown", function () {
      if (active) cancelHints();
    }, true);
    window.addEventListener("resize", scheduleLayout);
    window.addEventListener("scroll", scheduleLayout, true);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initShortcuts);
  } else {
    initShortcuts();
  }
})();
