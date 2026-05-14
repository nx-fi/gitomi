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
  const centeredHintTargetSelector = [
    ".topbar nav a",
    ".issues-state-tabs a",
    ".issues-filter-menus summary",
    ".issues-filter-menus a",
    ".view-tabs a",
    ".code-view-switch a",
    ".refs-filter-tabs a",
    "[role='menuitem']",
  ].join(",");
  const tabBarSelector = [
    ".view-tabs",
    ".code-view-switch",
    ".issues-state-tabs",
    ".refs-filter-tabs",
    ".topbar nav",
  ].join(",");

  let active = false;
  let hints = [];
  let sequence = [];
  let layer = null;
  let timer = 0;
  let layoutFrame = 0;
  let shortcutConfig = null;
  let helpPopover = null;
  let commandPrefix = "";
  let commandTimer = 0;

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

  function isCenteredHintTarget(element) {
    return element.matches(centeredHintTargetSelector) || Boolean(element.closest(centeredHintTargetSelector));
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

  function clampedPosition(left, top, width, height) {
    const margin = 4;
    return {
      left: Math.max(margin, Math.min(left, window.innerWidth - width - margin)),
      top: Math.max(margin, Math.min(top, window.innerHeight - height - margin)),
    };
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
    const centered = isCenteredHintTarget(hint.target);
    hint.node.classList.toggle("is-centered", centered);

    const width = hint.node.offsetWidth;
    const height = hint.node.offsetHeight;
    const gap = 5;
    let left;
    let top;

    if (centered) {
      left = rect.left + rect.width / 2 - width / 2;
      top = rect.top + rect.height / 2 - height / 2;
    } else {
      left = rect.right + gap;
      top = rect.top + Math.min(4, Math.max(0, rect.height - height));

      if (left + width > window.innerWidth - 4) {
        left = rect.left + gap;
      }
      if (top + height > window.innerHeight - 4) {
        top = rect.bottom - height - gap;
      }
    }

    const position = clampedPosition(left, top, width, height);
    hint.node.style.transform = `translate(${position.left}px, ${position.top}px)`;
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

  function clearCommandTimer() {
    if (!commandTimer) return;
    window.clearTimeout(commandTimer);
    commandTimer = 0;
  }

  function clearCommandPrefix() {
    commandPrefix = "";
    clearCommandTimer();
  }

  function setCommandPrefix(prefix) {
    commandPrefix = prefix;
    clearCommandTimer();
    commandTimer = window.setTimeout(clearCommandPrefix, 900);
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
    clearCommandPrefix();
    if (layoutFrame) {
      window.cancelAnimationFrame(layoutFrame);
      layoutFrame = 0;
    }
    if (layer) {
      layer.querySelectorAll(".gitomi-shortcut-hint").forEach((node) => node.remove());
      if (!helpPopover) layer.classList.remove("has-popover");
    }
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

  function keyDisplay(value) {
    return value === " " ? "Space" : String(value || "");
  }

  function appendHelpRow(list, keys, description) {
    const row = document.createElement("div");
    row.className = "gitomi-shortcut-help-row";

    const keyCell = document.createElement("div");
    keyCell.className = "gitomi-shortcut-help-keys";
    keys.forEach((key) => {
      const kbd = document.createElement("kbd");
      kbd.textContent = keyDisplay(key);
      keyCell.appendChild(kbd);
    });

    const descriptionCell = document.createElement("div");
    descriptionCell.textContent = description;

    row.appendChild(keyCell);
    row.appendChild(descriptionCell);
    list.appendChild(row);
  }

  function appendHelpSection(container, title, rows) {
    const section = document.createElement("section");
    const heading = document.createElement("h3");
    const list = document.createElement("div");
    heading.textContent = title;
    list.className = "gitomi-shortcut-help-list";
    rows.forEach((row) => appendHelpRow(list, row.keys, row.description));
    section.appendChild(heading);
    section.appendChild(list);
    container.appendChild(section);
  }

  function closeShortcutHelp() {
    if (helpPopover) {
      helpPopover.remove();
      helpPopover = null;
    }
    if (layer) layer.classList.remove("has-popover");
  }

  function showShortcutHelp() {
    const config = shortcutConfig || readConfig();
    cancelHints();
    closeShortcutHelp();

    const layerNode = ensureLayer();
    layerNode.classList.add("has-popover");

    helpPopover = document.createElement("div");
    helpPopover.className = "gitomi-shortcut-help";
    helpPopover.setAttribute("role", "dialog");
    helpPopover.setAttribute("aria-modal", "true");
    helpPopover.setAttribute("aria-labelledby", "gitomi-shortcut-help-title");

    const head = document.createElement("div");
    head.className = "gitomi-shortcut-help-head";
    const title = document.createElement("h2");
    title.id = "gitomi-shortcut-help-title";
    title.textContent = "Keyboard shortcuts";
    const close = document.createElement("button");
    close.type = "button";
    close.className = "gitomi-shortcut-help-close";
    close.setAttribute("aria-label", "Close keyboard shortcuts");
    close.textContent = "Close";
    close.addEventListener("click", closeShortcutHelp);
    head.appendChild(title);
    head.appendChild(close);
    helpPopover.appendChild(head);

    appendHelpSection(helpPopover, "Click hints", [
      { keys: [config.leader], description: "Show shortcuts for clickable elements" },
      { keys: [config.leader, config.leader], description: "Show this shortcut reference" },
      { keys: ["A"], description: "Activate a displayed one-key hint" },
      { keys: ["A", "J"], description: "Activate a displayed multi-key hint" },
      { keys: ["Esc"], description: "Close shortcut hints" },
    ]);
    appendHelpSection(helpPopover, "Navigation", [
      { keys: ["j"], description: "Scroll down" },
      { keys: ["k"], description: "Scroll up" },
      { keys: ["h"], description: "Scroll left" },
      { keys: ["l"], description: "Scroll right" },
      { keys: ["g", "g"], description: "Jump to top" },
      { keys: ["G"], description: "Jump to bottom" },
      { keys: ["["], description: "Previous tab" },
      { keys: ["]"], description: "Next tab" },
      { keys: ["b"], description: "Go back" },
    ]);
    appendHelpSection(helpPopover, "Search and Edit", [
      { keys: ["/"], description: "Focus page search" },
      { keys: ["t"], description: "Focus file search" },
      { keys: ["n"], description: "Open the first visible New action" },
      { keys: ["e"], description: "Open the first visible Edit action" },
    ]);

    layerNode.appendChild(helpPopover);
    close.focus();
  }

  function showHints() {
    const config = shortcutConfig || readConfig();
    const targets = collectTargets();
    if (targets.length === 0 || config.keys.length === 0) return;

    closeShortcutHelp();
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
    if (token === config.leader || token === "Space") {
      showShortcutHelp();
      return;
    }

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

  function focusElement(element) {
    try {
      element.focus({ preventScroll: true });
    } catch (_) {
      try {
        element.focus();
      } catch (_) {}
    }
  }

  function clickElement(element) {
    if (!element || !document.contains(element) || isDisabled(element)) return false;
    focusElement(element);
    element.click();
    return true;
  }

  function elementLabel(element) {
    return [
      element.getAttribute("aria-label") || "",
      element.getAttribute("title") || "",
      element.textContent || "",
    ].join(" ").replace(/\s+/g, " ").trim();
  }

  function firstVisibleSearch(preferFileSearch) {
    const selectors = preferFileSearch
      ? ["[data-root-file-search]", "[data-tree-search]", "input[type='search']"]
      : ["input[type='search']", "[data-root-file-search]", "[data-tree-search]"];

    const seen = new Set();
    for (const selector of selectors) {
      const inputs = Array.from(document.querySelectorAll(selector));
      for (const input of inputs) {
        if (seen.has(input) || isDisabled(input) || !visibleRect(input)) continue;
        seen.add(input);
        return input;
      }
    }
    return null;
  }

  function focusSearch(preferFileSearch) {
    const input = firstVisibleSearch(preferFileSearch);
    if (!input) return false;
    focusElement(input);
    if (typeof input.select === "function") input.select();
    return true;
  }

  function firstClickableMatching(predicate) {
    return collectTargets().find((element) => predicate(element, elementLabel(element)));
  }

  function clickFirstAction(kind) {
    if (kind === "new") {
      return clickElement(firstClickableMatching((element, label) => {
        const href = element.getAttribute("href") || "";
        return /^\/new(?:-|\/|$)/.test(href) || /^new\b/i.test(label) || /^create\b/i.test(label);
      }));
    }

    if (kind === "edit") {
      return clickElement(firstClickableMatching((_, label) => /^edit\b/i.test(label)));
    }

    if (kind === "back") {
      const target = firstClickableMatching((_, label) => /^back\b/i.test(label));
      if (target) return clickElement(target);
      if (window.history.length > 1) {
        window.history.back();
        return true;
      }
    }

    return false;
  }

  function tabLinks(bar) {
    return Array.from(bar.querySelectorAll("a[href], button")).filter((element) => !isDisabled(element) && visibleRect(element));
  }

  function activateAdjacentTab(direction) {
    const bars = Array.from(document.querySelectorAll(tabBarSelector)).filter(visibleRect);
    for (const bar of bars) {
      const links = tabLinks(bar);
      if (links.length < 2) continue;
      const activeIndex = links.findIndex((link) => (
        link.classList.contains("active") ||
        link.getAttribute("aria-current") === "page" ||
        link.getAttribute("aria-selected") === "true"
      ));
      if (activeIndex === -1) continue;
      const nextIndex = (activeIndex + direction + links.length) % links.length;
      return clickElement(links[nextIndex]);
    }
    return false;
  }

  function scrollViewport(xPages, yPages) {
    window.scrollBy({
      left: Math.round(window.innerWidth * xPages),
      top: Math.round(window.innerHeight * yPages),
      behavior: "auto",
    });
    return true;
  }

  function runGlobalShortcut(event) {
    const rawKey = event.key || "";
    const lower = rawKey.toLowerCase();

    if (commandPrefix === "g") {
      clearCommandPrefix();
      if (lower === "g" && rawKey === lower) {
        window.scrollTo({ top: 0, left: window.scrollX, behavior: "auto" });
        return true;
      }
    }

    if (rawKey === "G") {
      window.scrollTo({ top: document.documentElement.scrollHeight, left: window.scrollX, behavior: "auto" });
      return true;
    }

    switch (lower) {
      case "j":
        return scrollViewport(0, 0.55);
      case "k":
        return scrollViewport(0, -0.55);
      case "h":
        return scrollViewport(-0.55, 0);
      case "l":
        return scrollViewport(0.55, 0);
      case "g":
        if (rawKey === lower) {
          setCommandPrefix("g");
          return true;
        }
        return false;
      case "/":
        return focusSearch(false);
      case "t":
        return focusSearch(true);
      case "n":
        return clickFirstAction("new");
      case "e":
        return clickFirstAction("edit");
      case "b":
        return clickFirstAction("back");
      case "[":
        return activateAdjacentTab(-1);
      case "]":
        return activateAdjacentTab(1);
      case "?":
        showShortcutHelp();
        return true;
      default:
        return false;
    }
  }

  function onKeyDown(event) {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;

    const token = tokenFromEvent(event);
    if (!token) return;

    if (helpPopover) {
      if (token === "Escape" || token === "Space") {
        event.preventDefault();
        event.stopPropagation();
        closeShortcutHelp();
      }
      return;
    }

    if (active) {
      handleActiveKey(event, token);
      return;
    }

    if (event.defaultPrevented || isEditingTarget(event.target)) {
      clearCommandPrefix();
      return;
    }

    const config = shortcutConfig || readConfig();
    if (token === config.leader) {
      event.preventDefault();
      event.stopPropagation();
      showHints();
      return;
    }

    if (runGlobalShortcut(event)) {
      event.preventDefault();
      event.stopPropagation();
    } else {
      clearCommandPrefix();
    }
  }

  function initShortcuts() {
    shortcutConfig = readConfig();
    document.addEventListener("keydown", onKeyDown, true);
    document.addEventListener("pointerdown", function (event) {
      if (helpPopover && !helpPopover.contains(event.target)) closeShortcutHelp();
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
