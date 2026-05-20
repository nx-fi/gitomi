(function () {
  "use strict";

  const markdownOutlineWidthKey = "gitomi.markdownOutlinePanelWidth";
  const minMarkdownOutlineWidth = 260;
  const maxMarkdownOutlineWidth = 560;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function setButtonState(button, label) {
    const accessibleLabel = label === "Copy" ? "Copy code to clipboard" : label;
    button.dataset.copyState = label;
    button.title = accessibleLabel;
    button.setAttribute("aria-label", accessibleLabel);
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

  function plural(value, unit) {
    return value + " " + unit + (value === 1 ? "" : "s");
  }

  function relativeTimeLabel(date, now) {
    const deltaSeconds = Math.round((now.getTime() - date.getTime()) / 1000);
    if (!Number.isFinite(deltaSeconds)) return "";

    const future = deltaSeconds < -30;
    const seconds = Math.abs(deltaSeconds);
    if (seconds < 60) return future ? "in less than a minute" : "just now";

    const units = [
      { name: "year", seconds: 365 * 24 * 60 * 60 },
      { name: "month", seconds: 30 * 24 * 60 * 60 },
      { name: "week", seconds: 7 * 24 * 60 * 60 },
      { name: "day", seconds: 24 * 60 * 60 },
      { name: "hour", seconds: 60 * 60 },
      { name: "minute", seconds: 60 },
    ];

    for (let index = 0; index < units.length; index += 1) {
      const unit = units[index];
      if (seconds >= unit.seconds) {
        const value = Math.max(1, Math.floor(seconds / unit.seconds));
        const label = plural(value, unit.name);
        return future ? "in " + label : label + " ago";
      }
    }

    return future ? "in less than a minute" : "just now";
  }

  let relativeTimeTimer = 0;

  function renderRelativeTimes() {
    const now = new Date();
    document.querySelectorAll("time[data-relative-time]").forEach(function (element) {
      const raw = element.getAttribute("datetime") || element.textContent || "";
      const date = new Date(raw);
      if (Number.isNaN(date.getTime())) return;
      const label = relativeTimeLabel(date, now);
      if (label) element.textContent = label;
      if (!element.getAttribute("title")) {
        element.setAttribute("title", date.toLocaleString());
      }
    });
    if (!relativeTimeTimer) {
      relativeTimeTimer = window.setInterval(renderRelativeTimes, 60 * 1000);
    }
  }

  function issueMenuMarkdown(menu) {
    const template = menu.querySelector("template[data-issue-markdown]");
    if (!template) return "";
    if (template.content) return template.content.textContent || "";
    return template.textContent || "";
  }

  function issueMenuPermalink(menu) {
    const url = new URL(window.location.href);
    const anchor = menu.dataset.issueAnchor || "";
    url.hash = anchor;
    return url.href;
  }

  function quoteMarkdown(markdown) {
    const value = String(markdown || "").replace(/\s+$/g, "");
    if (!value) return "";
    return value.split(/\r?\n/).map(function (line) {
      return line ? "> " + line : ">";
    }).join("\n") + "\n\n";
  }

  function commentTextarea(form) {
    if (form) return form.querySelector("textarea[name='body']");
    return document.querySelector(".issue-comment-form textarea[name='body']");
  }

  function commentReplyInput(form) {
    if (form) return form.querySelector("input[name='reply_parent_ref']");
    return document.querySelector(".issue-comment-form input[name='reply_parent_ref']");
  }

  function appendCommentText(value) {
    const textarea = commentTextarea();
    if (!textarea || !value) return false;
    const current = textarea.value.replace(/\s+$/g, "");
    textarea.value = current ? current + "\n\n" + value : value;
    focusCommentForm();
    const end = textarea.value.length;
    textarea.setSelectionRange(end, end);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  }

  function setReplyTarget(ref, form) {
    const input = commentReplyInput(form);
    if (!input) return false;
    input.value = ref || "";
    return true;
  }

  function focusCommentForm(form) {
    const textarea = commentTextarea(form);
    if (!textarea) return false;
    textarea.focus();
    textarea.scrollIntoView({ block: "center" });
    return true;
  }

  function clearInlineReplyForm(form) {
    const textarea = commentTextarea(form);
    if (textarea) {
      textarea.value = "";
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    }
    setReplyTarget("", form);
  }

  function removeInlineReplyForm(form) {
    if (!form) return;
    clearInlineReplyForm(form);
    form.remove();
  }

  function inlineReplyAnchor(button) {
    if (!button) return null;
    return button.closest(".reaction-bar") || button;
  }

  function ensureInlineReplyForm(button, ref) {
    const template = document.querySelector("template[data-comment-reply-form-template]");
    const anchor = inlineReplyAnchor(button);
    if (!template || !anchor) return null;

    let form = document.querySelector("[data-inline-comment-reply-form]");
    if (!form) {
      const fragment = template.content ? template.content.cloneNode(true) : null;
      form = fragment ? fragment.querySelector("[data-inline-comment-reply-form]") : null;
      if (!form) return null;
      anchor.insertAdjacentElement("afterend", form);
    } else if (form.previousElementSibling !== anchor) {
      anchor.insertAdjacentElement("afterend", form);
    }
    if ((form.dataset.replyRef || "") !== (ref || "")) clearInlineReplyForm(form);
    form.dataset.replyRef = ref || "";
    setReplyTarget(ref || "", form);
    initMarkdownEditors();
    return form;
  }

  function startCommentReply(ref, button) {
    const inlineForm = ensureInlineReplyForm(button, ref);
    if (inlineForm) return focusCommentForm(inlineForm);
    if (!setReplyTarget(ref || "")) return false;
    return focusCommentForm();
  }

  function issueMenuLabel(button) {
    return button.querySelector("[data-issue-menu-label]") || button;
  }

  function flashIssueMenuLabel(button, label) {
    const labelElement = issueMenuLabel(button);
    const original = labelElement.textContent || "";
    labelElement.textContent = label;
    window.setTimeout(function () {
      labelElement.textContent = original;
    }, 1200);
  }

  function copyLinkUrl(value) {
    return new URL(value || window.location.pathname, window.location.href).href;
  }

  function notifyCopyResult(message, kind) {
    if (typeof window.gitomiNotify === "function") {
      window.gitomiNotify(message, kind);
    }
  }

  async function copyWorkItemLink(button) {
    if (button.disabled) return;
    const originalLabel = button.getAttribute("aria-label") || "Copy link";
    button.disabled = true;
    button.setAttribute("aria-label", "Copying");
    button.title = "Copying";
    try {
      await copyText(copyLinkUrl(button.dataset.copyWorkItemLink));
      button.setAttribute("aria-label", "Copied");
      button.title = "Copied";
      notifyCopyResult("Link copied.", "success");
    } catch (_) {
      button.setAttribute("aria-label", "Copy failed");
      button.title = "Copy failed";
      notifyCopyResult("Could not copy link.", "error");
    } finally {
      window.setTimeout(function () {
        button.disabled = false;
        button.setAttribute("aria-label", originalLabel);
        button.title = originalLabel;
      }, 1200);
    }
  }

  function initWorkItemCopyButtons() {
    document.querySelectorAll("[data-copy-work-item-link]").forEach(function (button) {
      if (button.dataset.copyWorkItemReady === "yes") return;
      button.dataset.copyWorkItemReady = "yes";
      button.addEventListener("click", function () {
        copyWorkItemLink(button);
      });
    });
  }

  function closeIssueMenus(except) {
    document.querySelectorAll("details[data-issue-menu][open]").forEach(function (menu) {
      if (menu !== except) menu.open = false;
    });
  }

  function closeIssueSidebarMenus(except) {
    document.querySelectorAll("details[data-issue-sidebar-menu][open]").forEach(function (menu) {
      if (menu !== except) menu.open = false;
    });
  }

  async function runIssueAction(menu, button) {
    if (button.disabled) return;
    const action = button.dataset.issueAction || "";
    const markdown = issueMenuMarkdown(menu);
    if (action === "copy-link") {
      try {
        await copyText(issueMenuPermalink(menu));
        flashIssueMenuLabel(button, "Copied");
        window.setTimeout(function () { closeIssueMenus(null); }, 250);
      } catch (_) {
        flashIssueMenuLabel(button, "Failed");
      }
      return;
    }
    if (action === "copy-markdown") {
      try {
        await copyText(markdown);
        flashIssueMenuLabel(button, "Copied");
        window.setTimeout(function () { closeIssueMenus(null); }, 250);
      } catch (_) {
        flashIssueMenuLabel(button, "Failed");
      }
      return;
    }
    if (action === "quote-reply") {
      if (appendCommentText(quoteMarkdown(markdown))) {
        setReplyTarget(menu.dataset.issueReplyRef || "");
        closeIssueMenus(null);
      }
      return;
    }
    if (action === "edit") {
      const href = menu.dataset.issueEditHref || "";
      if (href) window.location.href = href;
    }
  }

  function initIssueActionMenus() {
    document.querySelectorAll("details[data-issue-menu]").forEach(function (menu) {
      if (menu.dataset.issueMenuReady === "yes") return;
      menu.dataset.issueMenuReady = "yes";
      const summary = menu.querySelector("summary");
      if (summary) summary.setAttribute("aria-expanded", menu.open ? "true" : "false");
      menu.addEventListener("toggle", function () {
        if (summary) summary.setAttribute("aria-expanded", menu.open ? "true" : "false");
        if (menu.open) {
          closeIssueMenus(menu);
          closeIssueSidebarMenus(null);
        }
      });
      menu.addEventListener("click", function (event) {
        const target = event.target instanceof Element ? event.target : null;
        if (!target) return;
        const button = target.closest("[data-issue-action]");
        if (!button || !menu.contains(button)) return;
        event.preventDefault();
        runIssueAction(menu, button);
      });
    });

    if (document.body.dataset.issueMenusReady === "yes") return;
    document.body.dataset.issueMenusReady = "yes";
    document.addEventListener("click", function (event) {
      const target = event.target instanceof Element ? event.target : null;
      if (!target || !target.closest("details[data-issue-menu]")) {
        closeIssueMenus(null);
      }
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeIssueMenus(null);
    });
  }

  function initCommentReplyButtons() {
    if (document.body.dataset.commentReplyButtonsReady === "yes") return;
    document.body.dataset.commentReplyButtonsReady = "yes";
    document.addEventListener("click", function (event) {
      const target = event.target instanceof Element ? event.target : null;
      if (!target) return;
      const button = target.closest("[data-comment-reply-ref]");
      if (!button) return;
      event.preventDefault();
      startCommentReply(button.getAttribute("data-comment-reply-ref") || "", button);
    });
    document.addEventListener("click", function (event) {
      const target = event.target instanceof Element ? event.target : null;
      if (!target) return;
      const button = target.closest("[data-comment-reply-cancel]");
      if (!button) return;
      event.preventDefault();
      removeInlineReplyForm(button.closest("[data-inline-comment-reply-form]"));
    });
  }

  function filterIssueSidebarMenu(input) {
    const popover = input.closest("[data-issue-relationship-panel]") || input.closest(".issue-sidebar-popover");
    if (!popover) return;
    const searchInput = popover.querySelector("[data-issue-sidebar-filter]");
    const stateInput = popover.querySelector("[data-issue-sidebar-state-filter]");
    const query = String(searchInput && searchInput.value || "").trim().toLowerCase();
    const state = String(stateInput && stateInput.value || "").trim().toLowerCase();
    popover.querySelectorAll("[data-sidebar-filter-text]").forEach(function (row) {
      const text = String(row.getAttribute("data-sidebar-filter-text") || "").toLowerCase();
      const rowState = String(row.getAttribute("data-sidebar-state") || "").toLowerCase();
      const matchesQuery = query.length === 0 || text.indexOf(query) !== -1;
      const matchesState = state.length === 0 || rowState === state;
      row.hidden = !matchesQuery || !matchesState;
    });
  }

  function firstVisibleSidebarFilter(menu) {
    return Array.from(menu.querySelectorAll("[data-issue-sidebar-filter]")).find(function (input) {
      return !input.closest("[hidden]");
    }) || null;
  }

  function resetIssueRelationshipPanel(panel) {
    panel.querySelectorAll("[data-issue-sidebar-filter]").forEach(function (input) {
      input.value = "";
      filterIssueSidebarMenu(input);
    });
  }

  function focusIssueRelationshipPanel(panel) {
    const focusTarget = firstVisibleSidebarFilter(panel) ||
      panel.querySelector("[data-issue-relationship-panel-target], button, input, select, textarea, a");
    if (focusTarget) window.setTimeout(function () { focusTarget.focus(); }, 0);
  }

  function showIssueRelationshipPanel(root, panelName, focus) {
    let activePanel = null;
    root.querySelectorAll("[data-issue-relationship-panel]").forEach(function (panel) {
      const active = (panel.getAttribute("data-issue-relationship-panel") || "") === panelName;
      panel.hidden = !active;
      panel.classList.toggle("is-active", active);
      if (active) {
        activePanel = panel;
        resetIssueRelationshipPanel(panel);
      }
    });
    if (focus && activePanel) focusIssueRelationshipPanel(activePanel);
  }

  function resetIssueRelationshipMenus(menu) {
    menu.querySelectorAll("[data-issue-relationship-menu]").forEach(function (root) {
      showIssueRelationshipPanel(root, "actions", false);
    });
  }

  function initIssueSidebarMenus() {
    document.querySelectorAll("details[data-issue-sidebar-menu]").forEach(function (menu) {
      if (menu.dataset.issueSidebarMenuReady === "yes") return;
      menu.dataset.issueSidebarMenuReady = "yes";
      const summary = menu.querySelector("summary");
      if (summary) summary.setAttribute("aria-expanded", menu.open ? "true" : "false");
      menu.addEventListener("toggle", function () {
        if (summary) summary.setAttribute("aria-expanded", menu.open ? "true" : "false");
        if (menu.open) {
          closeIssueMenus(null);
          closeIssueSidebarMenus(menu);
          resetIssueRelationshipMenus(menu);
          const input = firstVisibleSidebarFilter(menu);
          if (input) window.setTimeout(function () { input.focus(); }, 0);
          else {
            const panel = menu.querySelector("[data-issue-relationship-panel]:not([hidden])");
            if (panel) focusIssueRelationshipPanel(panel);
          }
        }
      });
      menu.addEventListener("click", function (event) {
        const target = event.target instanceof Element ? event.target : null;
        if (!target) return;
        const toggle = target.closest("[data-issue-relationship-panel-target]");
        if (!toggle || !menu.contains(toggle)) return;
        const root = toggle.closest("[data-issue-relationship-menu]");
        if (!root) return;
        event.preventDefault();
        showIssueRelationshipPanel(root, toggle.getAttribute("data-issue-relationship-panel-target") || "actions", true);
      });
      menu.querySelectorAll("[data-issue-sidebar-filter]").forEach(function (input) {
        input.addEventListener("input", function () {
          filterIssueSidebarMenu(input);
        });
      });
      menu.querySelectorAll("[data-issue-sidebar-state-filter]").forEach(function (input) {
        input.addEventListener("change", function () {
          filterIssueSidebarMenu(input);
        });
      });
    });

    if (document.body.dataset.issueSidebarMenusReady === "yes") return;
    document.body.dataset.issueSidebarMenusReady = "yes";
    document.addEventListener("click", function (event) {
      const target = event.target instanceof Element ? event.target : null;
      if (!target || !target.closest("details[data-issue-sidebar-menu]")) {
        closeIssueSidebarMenus(null);
      }
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeIssueSidebarMenus(null);
    });
  }

  function decodeBase64Utf8(value) {
    const raw = window.atob(String(value || "").replace(/\s+/g, ""));
    const bytes = new Uint8Array(raw.length);
    for (let index = 0; index < raw.length; index += 1) {
      bytes[index] = raw.charCodeAt(index);
    }
    if (window.TextDecoder) return new TextDecoder("utf-8").decode(bytes);

    let escaped = "";
    for (let index = 0; index < bytes.length; index += 1) {
      escaped += "%" + bytes[index].toString(16).padStart(2, "0");
    }
    return decodeURIComponent(escaped);
  }

  function markdownSource(block) {
    if ((block.dataset.markdownEncoding || "") === "base64") {
      return decodeBase64Utf8(block.textContent || "");
    }
    return block.textContent || "";
  }

  function markdownParser() {
    if (!window.marked) return null;
    if (typeof window.marked.parse === "function") return window.marked;
    if (typeof window.marked.marked === "function") return { parse: window.marked.marked };
    if (typeof window.marked === "function") return { parse: window.marked };
    return null;
  }

  function sanitizeMarkdownHtml(html) {
    if (!window.DOMPurify) return "<pre>" + escapeHtml(html) + "</pre>";
    return window.DOMPurify.sanitize(html, {
      USE_PROFILES: { html: true },
      ALLOW_DATA_ATTR: false,
      ADD_TAGS: ["input", "source", "video"],
      ADD_ATTR: [
        "aria-hidden",
        "aria-label",
        "checked",
        "class",
        "controls",
        "disabled",
        "preload",
        "rel",
        "target",
        "type",
      ],
      FORBID_TAGS: [
        "button",
        "embed",
        "fieldset",
        "form",
        "iframe",
        "object",
        "optgroup",
        "option",
        "script",
        "select",
        "style",
        "textarea",
      ],
      FORBID_ATTR: [
        "action",
        "form",
        "formaction",
        "formenctype",
        "formmethod",
        "formnovalidate",
        "formtarget",
        "method",
        "style",
      ],
    });
  }

  function markdownHtml(source) {
    const parser = markdownParser();
    if (!parser) return "<pre>" + escapeHtml(source) + "</pre>";
    const html = parser.parse(String(source || ""), {
      async: false,
      breaks: false,
      gfm: true,
      pedantic: false,
      silent: true,
    });
    return sanitizeMarkdownHtml(html);
  }

  function isSafeHref(href) {
    const prefix = String(href || "").trimStart().slice(0, 12).toLowerCase();
    return prefix !== "" && !prefix.startsWith("javascript:") && !prefix.startsWith("data:");
  }

  function hasUriScheme(value) {
    return /^[A-Za-z][A-Za-z0-9+.-]*:/.test(String(value || ""));
  }

  function isRepositoryRelativeHref(href) {
    const value = String(href || "");
    if (!value || value[0] === "#" || value[0] === "?") return false;
    if (value.startsWith("//")) return false;
    return !hasUriScheme(value);
  }

  function hrefPathPart(href) {
    const value = String(href || "");
    const query = value.indexOf("?") === -1 ? value.length : value.indexOf("?");
    const fragment = value.indexOf("#") === -1 ? value.length : value.indexOf("#");
    return value.slice(0, Math.min(query, fragment));
  }

  function hrefFragmentPart(href) {
    const value = String(href || "");
    const index = value.indexOf("#");
    return index === -1 ? "" : value.slice(index);
  }

  function parentPath(path) {
    const value = String(path || "");
    const slash = value.lastIndexOf("/");
    return slash === -1 ? "" : value.slice(0, slash);
  }

  function resolveRepositoryPath(currentPath, hrefPath) {
    const rootRelative = String(hrefPath || "").startsWith("/");
    const segments = rootRelative ? [] : parentPath(currentPath).split("/").filter(Boolean);
    const parts = String(hrefPath || "").replace(/^\/+|\/+$/g, "").split("/");
    for (let index = 0; index < parts.length; index += 1) {
      const part = parts[index];
      if (!part || part === ".") continue;
      if (part === "..") {
        if (!segments.length) return null;
        segments.pop();
      } else {
        segments.push(part);
      }
    }
    return segments.join("/");
  }

  function decodeUrlPath(path) {
    try {
      return decodeURIComponent(String(path || ""));
    } catch (_) {
      return null;
    }
  }

  function decodeUrlHash(hash) {
    try {
      return decodeURIComponent(String(hash || "").slice(1));
    } catch (_) {
      return null;
    }
  }

  function encodePathQuery(value) {
    return String(value || "").split("/").map(encodeURIComponent).join("/");
  }

  function baseName(path) {
    const value = String(path || "");
    const slash = value.lastIndexOf("/");
    return slash === -1 ? value : value.slice(slash + 1);
  }

  function isMarkdownPath(path) {
    const value = String(path || "").toLowerCase();
    return value.endsWith(".md") || value.endsWith(".markdown") || baseName(value) === "readme";
  }

  function codeHref(ref, path, view) {
    let href = "/code?ref=" + encodeURIComponent(ref || "");
    if (path) href += "&path=" + encodePathQuery(path);
    if (view) href += "&view=" + encodeURIComponent(view);
    return href;
  }

  function rawHref(ref, path) {
    let href = "/raw?ref=" + encodeURIComponent(ref || "");
    if (path) href += "&path=" + encodePathQuery(path);
    return href;
  }

  function repositoryHref(href, context, raw) {
    if (!context || !context.ref || !context.path || !isRepositoryRelativeHref(href)) return "";
    const pathPart = hrefPathPart(href);
    if (!pathPart && href !== "/") return "";
    const decoded = decodeUrlPath(pathPart);
    if (decoded === null) return "";
    const target = resolveRepositoryPath(context.path, decoded);
    if (target === null) return "";
    const fragment = hrefFragmentPart(href);
    if (raw) return rawHref(context.ref, target) + fragment;
    return codeHref(context.ref, target, isMarkdownPath(target) ? "preview" : "") + fragment;
  }

  function isVideoHref(href) {
    return /\.(mp4|m4v|webm|ogv|ogg|mov)$/i.test(hrefPathPart(href));
  }

  function mediaContentType(href) {
    const path = hrefPathPart(href).toLowerCase();
    if (path.endsWith(".mp4") || path.endsWith(".m4v")) return "video/mp4";
    if (path.endsWith(".webm")) return "video/webm";
    if (path.endsWith(".ogv") || path.endsWith(".ogg")) return "video/ogg";
    if (path.endsWith(".mov")) return "video/quicktime";
    return "";
  }

  function rewriteMarkdownLinks(root, context) {
    root.querySelectorAll("a[href]").forEach(function (link) {
      const href = link.getAttribute("href") || "";
      if (!isSafeHref(href)) {
        link.removeAttribute("href");
        return;
      }
      const rewritten = repositoryHref(href, context, false);
      if (rewritten) link.setAttribute("href", rewritten);
    });
  }

  function rewriteMarkdownMedia(root, context) {
    root.querySelectorAll("audio").forEach(function (audio) {
      audio.removeAttribute("src");
    });

    root.querySelectorAll("video").forEach(function (video) {
      video.classList.add("markdown-media");
      video.setAttribute("controls", "");
      if (!video.getAttribute("preload")) video.setAttribute("preload", "metadata");
      video.removeAttribute("poster");
      if (video.hasAttribute("src")) {
        const src = video.getAttribute("src") || "";
        const rewritten = isSafeHref(src) ? repositoryHref(src, context, true) : "";
        if (rewritten) {
          video.setAttribute("src", rewritten);
        } else {
          video.removeAttribute("src");
        }
      }
    });

    root.querySelectorAll("track[src]").forEach(function (track) {
      track.remove();
    });

    root.querySelectorAll("source").forEach(function (source) {
      if (source.hasAttribute("srcset")) {
        source.remove();
        return;
      }
      const src = source.getAttribute("src") || "";
      const rewritten = isSafeHref(src) ? repositoryHref(src, context, true) : "";
      if (!rewritten) {
        source.remove();
        return;
      }
      source.setAttribute("src", rewritten);
    });

    root.querySelectorAll("img").forEach(function (image) {
      const src = image.getAttribute("src") || "";
      const rewritten = isSafeHref(src) ? repositoryHref(src, context, true) : "";
      image.removeAttribute("srcset");
      if (!rewritten) {
        image.remove();
        return;
      }
      if (isVideoHref(src)) {
        const video = document.createElement("video");
        video.className = "markdown-media";
        video.controls = true;
        video.preload = "metadata";
        const source = document.createElement("source");
        source.src = rewritten;
        const type = mediaContentType(src);
        if (type) source.type = type;
        video.appendChild(source);
        video.appendChild(document.createTextNode(image.getAttribute("alt") || ""));
        image.replaceWith(video);
        return;
      }
      image.classList.add("markdown-media");
      image.setAttribute("src", rewritten);
    });
  }

  function normalizeMarkdownTables(root) {
    root.querySelectorAll("table").forEach(function (table) {
      table.classList.add("markdown-table");
      if (table.parentElement && table.parentElement.classList.contains("markdown-table-wrap")) return;
      const wrapper = document.createElement("div");
      wrapper.className = "table-wrap markdown-table-wrap";
      table.parentNode.insertBefore(wrapper, table);
      wrapper.appendChild(table);
    });
  }

  function splitMarkdownLines(source) {
    return String(source || "").split("\n");
  }

  function trimLineEndCarriage(line) {
    return String(line || "").replace(/\r$/, "");
  }

  function markdownFenceMarker(line) {
    const match = /^( {0,3})(`{3,}|~{3,})/.exec(trimLineEndCarriage(line));
    if (!match) return null;
    return { char: match[2].charAt(0), length: match[2].length };
  }

  function markdownTaskLineInfo(line) {
    const match = /^([ \t]*)(?:[-*+]|\d+[.)])([ \t]+)\[([ xX])\](?=$|[ \t])/.exec(trimLineEndCarriage(line));
    if (!match) return null;
    return {
      checked: match[3] === "x" || match[3] === "X",
      indent: match[1].replace(/\t/g, "    ").length,
    };
  }

  function markdownTaskItemsFromLines(lines) {
    const items = [];
    let inFence = false;
    let fence = null;
    lines.forEach(function (line, lineIndex) {
      const marker = markdownFenceMarker(line);
      if (marker) {
        if (!inFence) {
          inFence = true;
          fence = marker;
        } else if (fence && marker.char === fence.char && marker.length >= fence.length) {
          inFence = false;
          fence = null;
        }
        return;
      }
      if (inFence) return;

      const task = markdownTaskLineInfo(line);
      if (task) {
        items.push({
          lineIndex: lineIndex,
          checked: task.checked,
          indent: task.indent,
        });
      }
    });
    return items;
  }

  function markdownTaskItems(source) {
    return markdownTaskItemsFromLines(splitMarkdownLines(source));
  }

  function setMarkdownTaskChecked(source, taskIndex, checked) {
    const lines = splitMarkdownLines(source);
    const items = markdownTaskItemsFromLines(lines);
    const item = items[taskIndex];
    if (!item) return source;
    lines[item.lineIndex] = lines[item.lineIndex].replace(
      /^([ \t]*(?:[-*+]|\d+[.)])[ \t]+\[)[ xX](\](?=$|[ \t]))/,
      "$1" + (checked ? "x" : " ") + "$2",
    );
    return lines.join("\n");
  }

  function taskBlockFromItems(lines, items, taskIndex) {
    const item = items[taskIndex];
    if (!item) return null;
    let end = lines.length;
    for (let index = item.lineIndex + 1; index < lines.length; index += 1) {
      const next = markdownTaskLineInfo(lines[index]);
      if (next && next.indent <= item.indent) {
        end = index;
        break;
      }
    }
    return {
      start: item.lineIndex,
      end: end,
    };
  }

  function moveMarkdownTask(source, fromIndex, toIndex, after) {
    if (fromIndex === toIndex) return source;
    const lines = splitMarkdownLines(source);
    const items = markdownTaskItemsFromLines(lines);
    const from = taskBlockFromItems(lines, items, fromIndex);
    const to = taskBlockFromItems(lines, items, toIndex);
    if (!from || !to) return source;
    if (from.start <= to.start && to.start < from.end) return source;

    const moved = lines.splice(from.start, from.end - from.start);
    let insertAt = after ? to.end : to.start;
    if (from.start < insertAt) insertAt -= moved.length;
    lines.splice(insertAt, 0, ...moved);
    return lines.join("\n");
  }

  function updateIssueMenuMarkdown(root, source) {
    const article = root.closest(".issue-comment-box");
    const template = article ? article.querySelector("template[data-issue-markdown]") : null;
    if (template) template.textContent = source || "";
  }

  async function saveChecklistMarkdown(root, source) {
    const action = root.dataset.checklistUpdateAction || "";
    if (!action) throw new Error("Checklist update action is missing.");

    const params = new URLSearchParams();
    params.set("body", source);
    const csrf = root.dataset.checklistCsrf || "";
    if (!csrf) throw new Error("Checklist CSRF token is missing.");
    const response = await fetch(action, {
      method: "POST",
      headers: {
        "Accept": "text/plain",
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
        "X-CSRF-Token": csrf,
      },
      body: params.toString(),
    });
    if (!response.ok) throw new Error("Checklist update failed.");
  }

  function markdownRenderContext(root) {
    return root.gitomiMarkdownContext || { ref: "", path: "" };
  }

  async function applyChecklistMarkdown(root, nextSource) {
    if (root.gitomiChecklistSaving) return;
    const previousSource = root.gitomiMarkdownSource || "";
    if (nextSource === previousSource) return;

    root.gitomiChecklistSaving = true;
    root.classList.add("markdown-checklist-saving");
    root.gitomiMarkdownSource = nextSource;
    renderMarkdownToElement(root, nextSource, markdownRenderContext(root));
    try {
      await saveChecklistMarkdown(root, nextSource);
    } catch (_) {
      root.gitomiMarkdownSource = previousSource;
      window.alert("Could not update checklist.");
    } finally {
      root.gitomiChecklistSaving = false;
      root.classList.remove("markdown-checklist-saving");
      renderMarkdownToElement(root, root.gitomiMarkdownSource || "", markdownRenderContext(root));
    }
  }

  function clearTaskDropClasses(root) {
    root.querySelectorAll(".task-list-item.is-dragging, .task-list-item.is-drop-before, .task-list-item.is-drop-after").forEach(function (item) {
      item.classList.remove("is-dragging", "is-drop-before", "is-drop-after");
    });
  }

  function eventTaskListItem(event, root) {
    const target = event.target instanceof Element ? event.target : null;
    const item = target ? target.closest(".task-list-item[data-task-index]") : null;
    return item && root.contains(item) ? item : null;
  }

  function numericTaskIndex(value) {
    const index = Number(value);
    return Number.isInteger(index) && index >= 0 ? index : -1;
  }

  function initMarkdownChecklistRoot(root) {
    if (root.dataset.checklistReady === "yes") return;
    root.dataset.checklistReady = "yes";

    root.addEventListener("change", function (event) {
      const input = event.target instanceof HTMLInputElement ? event.target : null;
      if (!input || !input.classList.contains("task-list-checkbox") || input.disabled) return;
      const taskIndex = numericTaskIndex(input.dataset.taskIndex);
      if (taskIndex < 0) return;
      const nextSource = setMarkdownTaskChecked(root.gitomiMarkdownSource || "", taskIndex, input.checked);
      applyChecklistMarkdown(root, nextSource);
    });

    root.addEventListener("dragstart", function (event) {
      const item = eventTaskListItem(event, root);
      if (!item || root.gitomiChecklistSaving) {
        event.preventDefault();
        return;
      }
      root.gitomiTaskDragIndex = item.dataset.taskIndex || "";
      item.classList.add("is-dragging");
      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", root.gitomiTaskDragIndex);
      }
    });

    root.addEventListener("dragover", function (event) {
      const item = eventTaskListItem(event, root);
      if (!item || root.gitomiTaskDragIndex === undefined) return;
      event.preventDefault();
      clearTaskDropClasses(root);
      const rect = item.getBoundingClientRect();
      const after = event.clientY > rect.top + rect.height / 2;
      item.classList.add(after ? "is-drop-after" : "is-drop-before");
      root.gitomiTaskDropIndex = item.dataset.taskIndex || "";
      root.gitomiTaskDropAfter = after ? "yes" : "no";
    });

    root.addEventListener("drop", function (event) {
      const item = eventTaskListItem(event, root);
      if (!item) return;
      event.preventDefault();
      const fromIndex = numericTaskIndex(root.gitomiTaskDragIndex);
      const toIndex = numericTaskIndex(item.dataset.taskIndex);
      const after = root.gitomiTaskDropAfter === "yes";
      clearTaskDropClasses(root);
      delete root.gitomiTaskDragIndex;
      delete root.gitomiTaskDropIndex;
      delete root.gitomiTaskDropAfter;
      if (fromIndex < 0 || toIndex < 0) return;
      const nextSource = moveMarkdownTask(root.gitomiMarkdownSource || "", fromIndex, toIndex, after);
      applyChecklistMarkdown(root, nextSource);
    });

    root.addEventListener("dragend", function () {
      clearTaskDropClasses(root);
      delete root.gitomiTaskDragIndex;
      delete root.gitomiTaskDropIndex;
      delete root.gitomiTaskDropAfter;
    });
  }

  function normalizeTaskListInputs(root, source) {
    const taskItems = markdownTaskItems(source);
    const editable = Boolean(root.dataset.checklistUpdateAction) && !root.gitomiChecklistSaving;
    let taskIndex = 0;
    root.querySelectorAll("input").forEach(function (input) {
      if (input.type !== "checkbox") {
        input.remove();
        return;
      }
      input.classList.add("task-list-checkbox");
      const item = input.closest("li");
      if (item) item.classList.add("task-list-item");

      const hasSourceTask = taskIndex < taskItems.length;
      input.dataset.taskIndex = String(taskIndex);
      input.disabled = !editable || !hasSourceTask;
      input.draggable = false;
      if (item) {
        item.dataset.taskIndex = String(taskIndex);
        if (editable && hasSourceTask) {
          item.setAttribute("draggable", "true");
        } else {
          item.removeAttribute("draggable");
        }
      }
      taskIndex += 1;
    });
    if (editable && taskItems.length > 0) initMarkdownChecklistRoot(root);
  }

  function isReferenceTrailingIdentifier(value) {
    return /[A-Za-z0-9_-]/.test(value || "");
  }

  function isPositiveDecimalReference(value) {
    return /^[0-9]+$/.test(value) && /[1-9]/.test(value);
  }

  function isObjectRefPrefix(value) {
    return /^[0-9A-Fa-f]{7,64}$/.test(value || "");
  }

  function issueReferenceEnd(value, start) {
    if (value[start] !== "#") return 0;
    let end = start + 1;
    if (end >= value.length || !/[0-9A-Fa-f]/.test(value[end])) return 0;
    while (end < value.length && /[0-9A-Fa-f]/.test(value[end])) end += 1;
    if (end < value.length && isReferenceTrailingIdentifier(value[end])) return 0;
    const token = value.slice(start + 1, end);
    return isPositiveDecimalReference(token) || isObjectRefPrefix(token) ? end : 0;
  }

  function shouldSkipIssueAutolink(node) {
    const parent = node.parentElement;
    if (!parent) return true;
    return Boolean(parent.closest("a, code, pre, kbd, samp, script, style, textarea, .katex, .mermaid"));
  }

  function autolinkIssueTextNode(node) {
    const text = node.nodeValue || "";
    let cursor = 0;
    let changed = false;
    const fragment = document.createDocumentFragment();
    for (let index = 0; index < text.length; index += 1) {
      const end = issueReferenceEnd(text, index);
      if (!end) continue;
      if (cursor < index) fragment.appendChild(document.createTextNode(text.slice(cursor, index)));
      const token = text.slice(index + 1, end);
      const link = document.createElement("a");
      link.href = "/issues/" + encodeURIComponent(token);
      link.textContent = "#" + token;
      fragment.appendChild(link);
      cursor = end;
      index = end - 1;
      changed = true;
    }
    if (!changed) return;
    if (cursor < text.length) fragment.appendChild(document.createTextNode(text.slice(cursor)));
    node.replaceWith(fragment);
  }

  function autolinkIssueReferences(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if ((node.nodeValue || "").indexOf("#") === -1) return NodeFilter.FILTER_REJECT;
        return shouldSkipIssueAutolink(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(autolinkIssueTextNode);
  }

  function prepareMermaidBlocks(root) {
    root.querySelectorAll("pre[data-mermaid], pre > code.language-mermaid, pre > code.language-mmd").forEach(function (node) {
      const pre = node.tagName === "PRE" ? node : node.closest("pre");
      if (!pre || pre.dataset.mermaidPrepared === "yes") return;
      const source = node.tagName === "PRE" ? pre.textContent || "" : node.textContent || "";
      const container = document.createElement("div");
      container.className = "mermaid mermaid-diagram";
      container.textContent = source;
      pre.dataset.mermaidPrepared = "yes";
      pre.replaceWith(container);
    });
  }

  let mermaidConfigured = false;

  function configureMermaid() {
    if (mermaidConfigured || !window.mermaid || typeof window.mermaid.initialize !== "function") return;
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: document.documentElement.dataset.themeMode === "dark" ? "dark" : "default",
      flowchart: { htmlLabels: false, useMaxWidth: true },
      sequence: { useMaxWidth: true },
    });
    mermaidConfigured = true;
  }

  function renderMarkdownToElement(root, source, context) {
    root.gitomiMarkdownSource = String(source || "");
    root.gitomiMarkdownContext = context || { ref: "", path: "" };
    const template = document.createElement("template");
    template.innerHTML = markdownHtml(source);
    rewriteMarkdownLinks(template.content, context);
    rewriteMarkdownMedia(template.content, context);
    root.replaceChildren(template.content);
    normalizeMarkdownTables(root);
    normalizeTaskListInputs(root, source);
    renderMath(root);
    autolinkIssueReferences(root);
    renderMermaid(root);
    renderCodeCopyButtons(root);
    updateIssueMenuMarkdown(root, source);
    if (window.gitomiHighlightAll) window.gitomiHighlightAll();
  }

  function renderMarkdownSourceBlocks() {
    document.querySelectorAll("[data-markdown-source]").forEach(function (block) {
      const root = block.closest(".markdown-body") || block.parentElement;
      if (!root) return;
      const context = {
        ref: block.dataset.markdownRef || "",
        path: block.dataset.markdownPath || "",
      };
      renderMarkdownToElement(root, markdownSource(block), context);
    });
  }

  function renderMath(root) {
    const scope = root || document;
    if (typeof window.renderMathInElement === "function") {
      window.renderMathInElement(scope, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "\\[", right: "\\]", display: true },
          { left: "\\(", right: "\\)", display: false },
          { left: "$", right: "$", display: false },
        ],
        ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code"],
        ignoredClasses: ["mermaid", "mermaid-diagram"],
        throwOnError: false,
        trust: false,
        strict: "ignore",
      });
      return;
    }
  }

  function renderMermaidBlock(pre) {
    if (pre.dataset.rendered === "yes") return;
    const container = document.createElement("div");
    container.className = "mermaid mermaid-diagram";
    container.textContent = pre.textContent || "";
    pre.dataset.rendered = "yes";
    pre.replaceWith(container);
  }

  function renderMermaid(root) {
    const scope = root || document;
    scope.querySelectorAll("pre[data-mermaid]").forEach(renderMermaidBlock);
    prepareMermaidBlocks(scope);
    configureMermaid();
    if (!window.mermaid || typeof window.mermaid.run !== "function") return;
    const nodes = Array.prototype.slice.call(scope.querySelectorAll(".mermaid:not([data-processed])"));
    if (!nodes.length) return;
    window.mermaid.run({ nodes: nodes, suppressErrors: true }).catch(function () {
      nodes.forEach(function (node) {
        if (!node.getAttribute("data-processed")) node.classList.add("mermaid-source");
      });
    });
  }

  function codeElementForPre(pre) {
    for (let index = 0; index < pre.children.length; index += 1) {
      if (pre.children[index].tagName === "CODE") return pre.children[index];
    }
    return null;
  }

  function enhanceCodeBlock(pre) {
    if (pre.dataset.copyEnhanced === "yes") return;
    const code = codeElementForPre(pre);
    if (!code || !pre.parentNode) return;

    const wrapper = document.createElement("div");
    wrapper.className = "markdown-codeblock";
    pre.parentNode.insertBefore(wrapper, pre);
    wrapper.appendChild(pre);

    const button = document.createElement("button");
    button.className = "markdown-copy-button";
    button.type = "button";
    const icon = document.createElement("span");
    icon.className = "button-icon icon-copy";
    icon.setAttribute("aria-hidden", "true");
    button.appendChild(icon);
    setButtonState(button, "Copy");
    button.addEventListener("click", async function () {
      const original = button.dataset.copyState || "Copy";
      button.disabled = true;
      setButtonState(button, "Copying");
      try {
        await copyText(code.textContent || "");
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
    wrapper.appendChild(button);
    pre.dataset.copyEnhanced = "yes";
  }

  function renderCodeCopyButtons(root) {
    const scope = root || document;
    scope.querySelectorAll(".markdown-body pre, pre").forEach(function (pre) {
      if (pre.closest(".markdown-body") || scope !== document) enhanceCodeBlock(pre);
    });
  }

  function slugifyHeading(text) {
    const slug = String(text || "")
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
    return slug || "section";
  }

  function ensureHeadingIds(root) {
    const used = Object.create(null);
    root.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach(function (heading) {
      let id = heading.id || slugifyHeading(heading.textContent || "");
      const base = id;
      let count = used[base] || 0;
      while (count > 0 || (document.getElementById(id) && document.getElementById(id) !== heading)) {
        count += 1;
        id = base + "-" + count;
        if (!document.getElementById(id) || document.getElementById(id) === heading) break;
      }
      used[base] = count + 1;
      heading.id = id;
    });
  }

  function markdownHeadings(root) {
    if (!root) return [];
    ensureHeadingIds(root);
    const headings = Array.prototype.slice.call(root.querySelectorAll("h1, h2, h3, h4, h5, h6"))
      .filter(function (heading) { return (heading.textContent || "").trim(); });
    if (!headings.length) return [];
    const minLevel = headings.reduce(function (min, heading) {
      const level = Number(heading.tagName.slice(1)) || 1;
      return Math.min(min, level);
    }, 6);
    return headings.map(function (heading) {
      const level = Number(heading.tagName.slice(1)) || 1;
      return {
        id: heading.id,
        text: (heading.textContent || "").trim(),
        depth: Math.max(0, level - minLevel),
      };
    });
  }

  function fillOutlineLinks(container, headings) {
    if (!container) return;
    container.innerHTML = "";
    headings.forEach(function (heading) {
      const link = document.createElement("a");
      link.className = "code-side-panel-link markdown-outline-link";
      link.href = "#" + heading.id;
      link.textContent = heading.text;
      link.style.setProperty("--depth", String(heading.depth));
      link.dataset.depth = String(Math.min(heading.depth, 5));
      container.appendChild(link);
    });
  }

  function filterOutlineLinks(container, query) {
    if (!container) return;
    const value = String(query || "").trim().toLowerCase();
    container.querySelectorAll(".markdown-outline-link").forEach(function (link) {
      link.hidden = value !== "" && (link.textContent || "").toLowerCase().indexOf(value) === -1;
    });
  }

  function maxMarkdownOutlineWidthForLayout(layout) {
    const layoutWidth = layout.getBoundingClientRect().width || window.innerWidth;
    return Math.min(maxMarkdownOutlineWidth, Math.max(minMarkdownOutlineWidth, layoutWidth - 520));
  }

  function setMarkdownOutlineWidth(layout, width, persist) {
    const next = clamp(width, minMarkdownOutlineWidth, maxMarkdownOutlineWidthForLayout(layout));
    layout.style.setProperty("--markdown-outline-width", `${next}px`);
    if (persist) {
      try {
        window.localStorage.setItem(markdownOutlineWidthKey, String(next));
      } catch (_) {}
    }
  }

  function initMarkdownOutlineResize(panel) {
    const layout = panel.closest(".code-layout");
    const handle = layout ? layout.querySelector("[data-markdown-outline-resizer]") : null;
    if (!handle || !layout || panel.dataset.markdownOutlineResizeReady === "yes") return;
    panel.dataset.markdownOutlineResizeReady = "yes";

    try {
      const stored = Number(window.localStorage.getItem(markdownOutlineWidthKey));
      if (Number.isFinite(stored) && stored > 0) {
        setMarkdownOutlineWidth(layout, stored, false);
      }
    } catch (_) {}

    handle.addEventListener("pointerdown", function (event) {
      if (panel.hidden || layout.classList.contains("markdown-outline-collapsed")) return;
      event.preventDefault();
      handle.setPointerCapture(event.pointerId);
      document.documentElement.classList.add("markdown-outline-resizing");

      const onMove = function (moveEvent) {
        const right = layout.getBoundingClientRect().right;
        setMarkdownOutlineWidth(layout, right - moveEvent.clientX, true);
      };
      const onEnd = function () {
        document.documentElement.classList.remove("markdown-outline-resizing");
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onEnd);
        window.removeEventListener("pointercancel", onEnd);
      };

      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onEnd);
      window.addEventListener("pointercancel", onEnd);
    });
  }

  function setMarkdownOutlineOpen(panel, open) {
    if (!panel) return;
    const layout = panel.closest(".code-layout");
    const button = layout ? layout.querySelector("[data-markdown-outline-toggle]") : null;
    panel.hidden = !open;
    if (layout) layout.classList.toggle("markdown-outline-collapsed", !open);
    if (button) {
      button.setAttribute("aria-expanded", open ? "true" : "false");
      button.setAttribute("aria-label", open ? "Hide outline" : "Show outline");
      button.setAttribute("title", open ? "Hide outline" : "Show outline");
      const label = button.querySelector("[data-button-label]");
      if (label) label.textContent = "Outline";
    }
  }

  function initMarkdownOutlinePanel(panel) {
    const layout = panel.closest(".code-layout") || document;
    const documentRoot = layout.querySelector('[data-markdown-document][data-markdown-outline="panel"]');
    const list = panel.querySelector("[data-markdown-outline-list]");
    const input = panel.querySelector("[data-markdown-outline-filter]");
    const button = layout.querySelector("[data-markdown-outline-toggle]");
    const headings = markdownHeadings(documentRoot);

    if (!headings.length) {
      panel.hidden = true;
      if (button) button.hidden = true;
      if (layout.classList) layout.classList.add("markdown-outline-collapsed");
      return;
    }

    fillOutlineLinks(list, headings);
    filterOutlineLinks(list, input ? input.value : "");
    if (button) button.hidden = false;
    setMarkdownOutlineOpen(panel, !panel.hidden);
    initMarkdownOutlineResize(panel);

    if (panel.dataset.markdownOutlineReady === "yes") return;
    panel.dataset.markdownOutlineReady = "yes";
    if (input) {
      input.addEventListener("input", function () {
        filterOutlineLinks(list, input.value);
      });
    }
    const close = panel.querySelector("[data-markdown-outline-close]");
    if (close) {
      close.addEventListener("click", function () {
        setMarkdownOutlineOpen(panel, false);
      });
    }
    if (button) {
      button.addEventListener("click", function () {
        setMarkdownOutlineOpen(panel, panel.hidden);
      });
    }
  }

  function activeRootMarkdownDocument(root) {
    return root.querySelector("[data-root-doc-panel]:not([hidden])");
  }

  function renderRootTocMenu(root) {
    const menu = root.querySelector("[data-markdown-toc-menu]");
    const list = root.querySelector("[data-markdown-toc-list]");
    const documentRoot = activeRootMarkdownDocument(root);
    if (!menu || !list || !documentRoot) return;
    const headings = markdownHeadings(documentRoot);
    menu.hidden = headings.length === 0;
    fillOutlineLinks(list, headings);
    list.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () {
        menu.open = false;
      });
    });
  }

  function setRootDocTab(root, id) {
    root.querySelectorAll("[data-root-doc-tab]").forEach(function (tab) {
      const active = tab.getAttribute("data-root-doc-tab") === id;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
    });
    root.querySelectorAll("[data-root-doc-panel]").forEach(function (panel) {
      panel.hidden = panel.getAttribute("data-root-doc-panel") !== id;
    });
    renderRootTocMenu(root);
  }

  function initRootDocTabs(root) {
    if (root.dataset.rootDocsReady !== "yes") {
      root.dataset.rootDocsReady = "yes";
      root.querySelectorAll("[data-root-doc-tab]").forEach(function (tab) {
        tab.addEventListener("click", function () {
          setRootDocTab(root, tab.getAttribute("data-root-doc-tab") || "readme");
        });
      });
    }
    renderRootTocMenu(root);
  }

  function renderMarkdownOutlines() {
    document.querySelectorAll("[data-markdown-outline-panel]").forEach(initMarkdownOutlinePanel);
    document.querySelectorAll("[data-root-docs]").forEach(initRootDocTabs);
    if (window.location.hash) {
      const id = decodeUrlHash(window.location.hash);
      if (id === null) return;
      const target = document.getElementById(id);
      if (target && !renderMarkdownOutlines.scrolledHash) {
        renderMarkdownOutlines.scrolledHash = true;
        target.scrollIntoView();
      }
    }
  }

  function selectionBounds(textarea) {
    return {
      start: textarea.selectionStart || 0,
      end: textarea.selectionEnd || 0,
      value: textarea.value || "",
    };
  }

  function replaceSelection(textarea, replacement, selectStart, selectEnd) {
    const bounds = selectionBounds(textarea);
    textarea.value = bounds.value.slice(0, bounds.start) + replacement + bounds.value.slice(bounds.end);
    const start = bounds.start + (selectStart || replacement.length);
    const end = bounds.start + (selectEnd || replacement.length);
    textarea.focus();
    textarea.setSelectionRange(start, end);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function wrapSelection(textarea, before, after, fallback) {
    const bounds = selectionBounds(textarea);
    const selected = bounds.value.slice(bounds.start, bounds.end) || fallback || "";
    replaceSelection(textarea, before + selected + after, before.length, before.length + selected.length);
  }

  function selectedLines(textarea) {
    const bounds = selectionBounds(textarea);
    const lineStart = bounds.value.lastIndexOf("\n", Math.max(0, bounds.start - 1)) + 1;
    let lineEnd = bounds.value.indexOf("\n", bounds.end);
    if (lineEnd === -1) lineEnd = bounds.value.length;
    return {
      value: bounds.value,
      start: lineStart,
      end: lineEnd,
      text: bounds.value.slice(lineStart, lineEnd),
    };
  }

  function prefixSelectedLines(textarea, prefixForLine) {
    const lines = selectedLines(textarea);
    const replacement = lines.text
      .split("\n")
      .map(function (line, index) { return prefixForLine(line, index); })
      .join("\n");
    textarea.value = lines.value.slice(0, lines.start) + replacement + lines.value.slice(lines.end);
    textarea.focus();
    textarea.setSelectionRange(lines.start, lines.start + replacement.length);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function insertMarkdown(textarea, action) {
    if (!textarea) return;
    if (action === "heading") {
      prefixSelectedLines(textarea, function (line) {
        const stripped = line.replace(/^#{1,6}\s+/, "");
        return "### " + stripped;
      });
    } else if (action === "bold") {
      wrapSelection(textarea, "**", "**", "bold text");
    } else if (action === "italic") {
      wrapSelection(textarea, "_", "_", "italic text");
    } else if (action === "quote") {
      prefixSelectedLines(textarea, function (line) { return "> " + line.replace(/^>\s?/, ""); });
    } else if (action === "code") {
      const bounds = selectionBounds(textarea);
      const selected = bounds.value.slice(bounds.start, bounds.end);
      if (selected.indexOf("\n") === -1) {
        wrapSelection(textarea, "`", "`", "code");
      } else {
        replaceSelection(textarea, "```\n" + selected + "\n```", 4, 4 + selected.length);
      }
    } else if (action === "link") {
      const bounds = selectionBounds(textarea);
      const selected = bounds.value.slice(bounds.start, bounds.end) || "link text";
      const replacement = "[" + selected + "](url)";
      replaceSelection(textarea, replacement, replacement.length - 4, replacement.length - 1);
    } else if (action === "unordered-list") {
      prefixSelectedLines(textarea, function (line) { return line.match(/^\s*[-*]\s+/) ? line : "- " + line; });
    } else if (action === "ordered-list") {
      prefixSelectedLines(textarea, function (line, index) {
        return line.match(/^\s*\d+\.\s+/) ? line : (index + 1) + ". " + line;
      });
    } else if (action === "task-list") {
      prefixSelectedLines(textarea, function (line) { return line.match(/^\s*-\s+\[[ xX]\]\s+/) ? line : "- [ ] " + line; });
    } else if (action === "mention") {
      replaceSelection(textarea, "@", 1, 1);
    } else if (action === "reference") {
      replaceSelection(textarea, "#", 1, 1);
    }
  }

  function setMarkdownEditorTab(editor, mode) {
    const textarea = editor.querySelector("[data-markdown-input]");
    const preview = editor.querySelector("[data-markdown-preview]");
    if (!textarea || !preview) return;
    const writeMode = mode !== "preview";
    editor.querySelectorAll("[data-markdown-tab]").forEach(function (tab) {
      const active = (tab.getAttribute("data-markdown-tab") === (writeMode ? "write" : "preview"));
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
    });
    textarea.hidden = !writeMode;
    preview.hidden = writeMode;
    if (!writeMode) renderMarkdownPreview(editor);
  }

  async function renderMarkdownPreview(editor) {
    const textarea = editor.querySelector("[data-markdown-input]");
    const preview = editor.querySelector("[data-markdown-preview]");
    if (!textarea || !preview) return;
    const source = textarea.value || "";
    if (!source.trim()) {
      preview.innerHTML = '<p class="muted">Nothing to preview.</p>';
      return;
    }
    try {
      renderMarkdownToElement(preview, source, {});
    } catch (_) {
      preview.innerHTML = '<p class="muted">Preview failed.</p>';
    }
  }

  function initMarkdownEditors() {
    document.querySelectorAll("[data-markdown-editor]").forEach(function (editor) {
      if (editor.dataset.markdownEditorReady === "yes") return;
      editor.dataset.markdownEditorReady = "yes";
      const textarea = editor.querySelector("[data-markdown-input]");
      editor.querySelectorAll("[data-markdown-action]").forEach(function (button) {
        button.addEventListener("click", function () {
          insertMarkdown(textarea, button.getAttribute("data-markdown-action") || "");
        });
      });
      editor.querySelectorAll("[data-markdown-tab]").forEach(function (tab) {
        tab.addEventListener("click", function () {
          setMarkdownEditorTab(editor, tab.getAttribute("data-markdown-tab") || "write");
        });
      });
      if (textarea) {
        textarea.addEventListener("input", function () {
          const preview = editor.querySelector("[data-markdown-preview]");
          if (preview && !preview.hidden) renderMarkdownPreview(editor);
        });
      }
    });
  }

  function projectMarkdownHashPayload(form) {
    const kind = form.dataset.projectContentKind || "";
    const markerName = kind === "project-update" ? "update_health" : "status";
    const checkedStatus = form.querySelector("input[type='radio'][name='" + markerName + "']:checked");
    const statusInput = checkedStatus || form.querySelector("[name='" + markerName + "']");
    const textarea = form.querySelector("[data-markdown-input]");
    const status = statusInput ? String(statusInput.value || "") : "";
    let body = textarea ? String(textarea.value || "") : "";
    if (kind === "project-update" && !body.trim()) body = "";
    return kind + "\u0000" + status + "\u0000" + body;
  }

  function hexFromArrayBuffer(buffer) {
    return Array.from(new Uint8Array(buffer)).map(function (byte) {
      return byte.toString(16).padStart(2, "0");
    }).join("");
  }

  async function sha256HexText(value) {
    if (!window.crypto || !window.crypto.subtle || typeof TextEncoder === "undefined") return "";
    const digest = await window.crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
    return hexFromArrayBuffer(digest);
  }

  async function updateProjectMarkdownCurrentHash(form) {
    const current = form.querySelector("[data-project-current-hash]");
    if (!current) return;
    const hash = await sha256HexText(projectMarkdownHashPayload(form));
    if (hash) current.value = hash;
  }

  function projectMarkdownSubmitter(event, form) {
    if (event.submitter) return event.submitter;
    const active = document.activeElement;
    return active && form.contains(active) ? active : null;
  }

  function resetProjectMarkdownForm(form) {
    form.reset();
    delete form.dataset.projectHashPending;
    delete form.dataset.projectHashSubmitting;
    form.querySelectorAll("details[open]").forEach(function (details) {
      details.open = false;
    });
    const previous = form.querySelector("[data-project-previous-hash]");
    const current = form.querySelector("[data-project-current-hash]");
    if (previous && current) current.value = previous.value || "";
    form.querySelectorAll("[data-markdown-editor]").forEach(function (editor) {
      const preview = editor.querySelector("[data-markdown-preview]");
      if (preview && !preview.hidden) renderMarkdownPreview(editor);
    });
  }

  function initProjectMarkdownForms() {
    document.querySelectorAll("[data-project-markdown-form]").forEach(function (form) {
      if (form.dataset.projectMarkdownFormReady === "yes") return;
      form.dataset.projectMarkdownFormReady = "yes";
      form.addEventListener("submit", function (event) {
        if (form.dataset.projectHashSubmitting === "yes") return;
        if (form.dataset.projectHashPending === "yes") {
          event.preventDefault();
          return;
        }
        if (!form.querySelector("[data-project-current-hash]")) return;
        if (!window.crypto || !window.crypto.subtle || typeof TextEncoder === "undefined") return;
        event.preventDefault();
        const submitter = projectMarkdownSubmitter(event, form);
        form.dataset.projectHashPending = "yes";
        updateProjectMarkdownCurrentHash(form).finally(function () {
          delete form.dataset.projectHashPending;
          form.dataset.projectHashSubmitting = "yes";
          if (typeof form.requestSubmit === "function") {
            if (submitter && submitter.form === form && !submitter.disabled) {
              try {
                form.requestSubmit(submitter);
              } catch (_) {
                form.requestSubmit();
              }
            } else {
              form.requestSubmit();
            }
          } else {
            form.submit();
          }
        });
      });
      form.querySelectorAll("[data-project-markdown-cancel]").forEach(function (button) {
        button.addEventListener("click", function () {
          resetProjectMarkdownForm(form);
          const details = form.closest("details");
          if (details) details.open = false;
        });
      });
    });
  }

  function renderMarkdownEnhancements() {
    renderMarkdownSourceBlocks();
    renderMath(document);
    renderMermaid(document);
    renderCodeCopyButtons(document);
    renderMarkdownOutlines();
    renderRelativeTimes();
    initWorkItemCopyButtons();
    initIssueActionMenus();
    initCommentReplyButtons();
    initIssueSidebarMenus();
    initMarkdownEditors();
    initProjectMarkdownForms();
  }

  document.addEventListener("gitomi:partial-refresh", renderMarkdownEnhancements);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderMarkdownEnhancements);
  } else {
    renderMarkdownEnhancements();
  }
})();
