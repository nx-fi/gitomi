(function () {
  "use strict";

  const svgNS = "http://www.w3.org/2000/svg";
  let diagramCount = 0;

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

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

  function commentTextarea() {
    return document.querySelector(".issue-comment-form textarea[name='body']");
  }

  function commentReplyInput() {
    return document.querySelector(".issue-comment-form input[name='reply_parent_ref']");
  }

  function appendCommentText(value) {
    const textarea = commentTextarea();
    if (!textarea || !value) return false;
    const current = textarea.value.replace(/\s+$/g, "");
    textarea.value = current ? current + "\n\n" + value : value;
    textarea.focus();
    textarea.scrollIntoView({ block: "center" });
    const end = textarea.value.length;
    textarea.setSelectionRange(end, end);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  }

  function setReplyTarget(ref) {
    const input = commentReplyInput();
    if (!input) return;
    input.value = ref || "";
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

  function filterIssueSidebarMenu(input) {
    const popover = input.closest(".issue-sidebar-popover");
    if (!popover) return;
    const query = String(input.value || "").trim().toLowerCase();
    popover.querySelectorAll("[data-sidebar-filter-text]").forEach(function (row) {
      const text = String(row.getAttribute("data-sidebar-filter-text") || "").toLowerCase();
      row.hidden = query.length > 0 && text.indexOf(query) === -1;
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
          const input = menu.querySelector("[data-issue-sidebar-filter]");
          if (input) window.setTimeout(function () { input.focus(); }, 0);
        }
      });
      menu.querySelectorAll("[data-issue-sidebar-filter]").forEach(function (input) {
        input.addEventListener("input", function () {
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

  function renderLatex(value) {
    let html = escapeHtml(String(value || "").trim());
    html = html.replace(/\\frac\{([^{}]+)\}\{([^{}]+)\}/g, '<span class="math-frac"><span>$1</span><span>$2</span></span>');
    html = html.replace(/\\sqrt\{([^{}]+)\}/g, '<span class="math-sqrt">$1</span>');
    html = html.replace(/\^\{([^{}]+)\}/g, "<sup>$1</sup>");
    html = html.replace(/_\{([^{}]+)\}/g, "<sub>$1</sub>");
    html = html.replace(/\^([A-Za-z0-9+-]+)/g, "<sup>$1</sup>");
    html = html.replace(/_([A-Za-z0-9+-]+)/g, "<sub>$1</sub>");
    html = html.replace(/\\\\/g, "<br>");

    const commands = {
      alpha: "&alpha;",
      beta: "&beta;",
      gamma: "&gamma;",
      delta: "&delta;",
      epsilon: "&epsilon;",
      theta: "&theta;",
      lambda: "&lambda;",
      mu: "&mu;",
      pi: "&pi;",
      rho: "&rho;",
      sigma: "&sigma;",
      tau: "&tau;",
      phi: "&phi;",
      omega: "&omega;",
      Gamma: "&Gamma;",
      Delta: "&Delta;",
      Theta: "&Theta;",
      Lambda: "&Lambda;",
      Pi: "&Pi;",
      Sigma: "&Sigma;",
      Phi: "&Phi;",
      Omega: "&Omega;",
      sum: "&sum;",
      prod: "&prod;",
      int: "&int;",
      infty: "&infin;",
      le: "&le;",
      ge: "&ge;",
      neq: "&ne;",
      times: "&times;",
      cdot: "&middot;",
      approx: "&asymp;",
      to: "&rarr;",
      leftarrow: "&larr;",
      rightarrow: "&rarr;",
    };

    Object.keys(commands).forEach(function (name) {
      html = html.replace(new RegExp("\\\\" + name + "\\b", "g"), commands[name]);
    });
    return html;
  }

  function renderMath() {
    document.querySelectorAll("[data-latex-inline], [data-latex-display]").forEach(function (element) {
      if (element.dataset.rendered === "yes") return;
      element.innerHTML = renderLatex(element.textContent || "");
      element.dataset.rendered = "yes";
    });
  }

  function parseNode(raw, nodes) {
    const value = String(raw || "").trim().replace(/;$/, "");
    const match = value.match(/^([A-Za-z0-9_.:-]+)\s*(?:\["?([^"\]]+)"?\]|\(([^)]+)\)|\{([^}]+)\})?$/);
    if (!match) return null;
    const id = match[1];
    const label = (match[2] || match[3] || match[4] || id).trim();
    if (!nodes.has(id)) nodes.set(id, { id: id, label: label });
    if (label !== id) nodes.get(id).label = label;
    return id;
  }

  function parseStatement(statement, nodes, edges) {
    const edgeMatch = statement.match(/^(.+?)\s*(-\.->|-->|---|==>)\s*(?:\|([^|]+)\|\s*)?(.+)$/);
    if (edgeMatch) {
      const from = parseNode(edgeMatch[1], nodes);
      const to = parseNode(edgeMatch[4], nodes);
      if (from && to) {
        edges.push({
          from: from,
          to: to,
          label: (edgeMatch[3] || "").trim(),
          dashed: edgeMatch[2] === "-.->",
          directed: edgeMatch[2] !== "---",
        });
        return true;
      }
    }
    return parseNode(statement, nodes) !== null;
  }

  function parseMermaid(source) {
    const lines = String(source || "")
      .split(/\r?\n/)
      .map(function (line) { return line.trim(); })
      .filter(function (line) { return line && !line.startsWith("%%"); });
    if (!lines.length) return null;

    const header = lines[0].match(/^(?:graph|flowchart)\s+(TD|TB|BT|LR|RL)\b/i);
    if (!header) return null;

    const nodes = new Map();
    const edges = [];
    lines.slice(1).forEach(function (line) {
      line.split(";").forEach(function (part) {
        const statement = part.trim();
        if (statement) parseStatement(statement, nodes, edges);
      });
    });

    if (!nodes.size) return null;
    return { direction: header[1].toUpperCase(), nodes: nodes, edges: edges };
  }

  function buildRanks(diagram) {
    const ranks = new Map();
    const incoming = new Map();
    diagram.nodes.forEach(function (_, id) { incoming.set(id, 0); });
    diagram.edges.forEach(function (edge) {
      incoming.set(edge.to, (incoming.get(edge.to) || 0) + 1);
    });

    const roots = Array.from(diagram.nodes.keys()).filter(function (id) {
      return (incoming.get(id) || 0) === 0;
    });
    if (!roots.length) roots.push(Array.from(diagram.nodes.keys())[0]);
    roots.forEach(function (id) { ranks.set(id, 0); });

    for (let pass = 0; pass < diagram.nodes.size; pass += 1) {
      let changed = false;
      diagram.edges.forEach(function (edge) {
        if (!ranks.has(edge.from)) return;
        const nextRank = Math.min((ranks.get(edge.from) || 0) + 1, diagram.nodes.size - 1);
        if (!ranks.has(edge.to) || nextRank > ranks.get(edge.to)) {
          ranks.set(edge.to, nextRank);
          changed = true;
        }
      });
      if (!changed) break;
    }

    diagram.nodes.forEach(function (_, id) {
      if (!ranks.has(id)) ranks.set(id, 0);
    });
    return ranks;
  }

  function layoutDiagram(diagram) {
    const nodeWidth = 156;
    const nodeHeight = 48;
    const rankGap = 116;
    const nodeGap = 32;
    const padding = 28;
    const horizontal = diagram.direction === "LR" || diagram.direction === "RL";
    const reverse = diagram.direction === "RL" || diagram.direction === "BT";
    const ranks = buildRanks(diagram);
    const groups = new Map();

    diagram.nodes.forEach(function (node, id) {
      const rank = ranks.get(id) || 0;
      if (!groups.has(rank)) groups.set(rank, []);
      groups.get(rank).push(node);
    });

    const rankKeys = Array.from(groups.keys()).sort(function (a, b) { return a - b; });
    const rankCount = rankKeys.length;
    const maxGroup = Math.max.apply(null, rankKeys.map(function (rank) { return groups.get(rank).length; }));
    const width = horizontal
      ? padding * 2 + nodeWidth + (rankCount - 1) * rankGap
      : padding * 2 + maxGroup * nodeWidth + (maxGroup - 1) * nodeGap;
    const height = horizontal
      ? padding * 2 + maxGroup * nodeHeight + (maxGroup - 1) * nodeGap
      : padding * 2 + nodeHeight + (rankCount - 1) * rankGap;
    const positions = new Map();

    rankKeys.forEach(function (rank, rankIndex) {
      const visualRank = reverse ? rankCount - rankIndex - 1 : rankIndex;
      groups.get(rank).forEach(function (node, itemIndex) {
        const x = horizontal ? padding + visualRank * rankGap : padding + itemIndex * (nodeWidth + nodeGap);
        const y = horizontal ? padding + itemIndex * (nodeHeight + nodeGap) : padding + visualRank * rankGap;
        positions.set(node.id, { x: x, y: y, width: nodeWidth, height: nodeHeight });
      });
    });

    return { width: width, height: height, positions: positions };
  }

  function shortLabel(label) {
    const value = String(label || "");
    return value.length > 28 ? value.slice(0, 25) + "..." : value;
  }

  function addSvgElement(parent, name, attrs, text) {
    const element = document.createElementNS(svgNS, name);
    Object.keys(attrs || {}).forEach(function (key) {
      element.setAttribute(key, String(attrs[key]));
    });
    if (text !== undefined) element.textContent = text;
    parent.appendChild(element);
    return element;
  }

  function edgePoints(from, to) {
    if (Math.abs(from.x - to.x) > Math.abs(from.y - to.y)) {
      if (from.x < to.x) {
        return [from.x + from.width, from.y + from.height / 2, to.x, to.y + to.height / 2];
      }
      return [from.x, from.y + from.height / 2, to.x + to.width, to.y + to.height / 2];
    }
    if (from.y < to.y) {
      return [from.x + from.width / 2, from.y + from.height, to.x + to.width / 2, to.y];
    }
    return [from.x + from.width / 2, from.y, to.x + to.width / 2, to.y + to.height];
  }

  function renderMermaidBlock(pre) {
    if (pre.dataset.rendered === "yes") return;
    const diagram = parseMermaid(pre.textContent || "");
    if (!diagram) return;

    const layout = layoutDiagram(diagram);
    const markerId = "mermaid-arrow-" + (++diagramCount);
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("class", "mermaid-diagram");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", "Mermaid diagram");
    svg.setAttribute("width", String(layout.width));
    svg.setAttribute("height", String(layout.height));
    svg.setAttribute("viewBox", "0 0 " + layout.width + " " + layout.height);

    const defs = addSvgElement(svg, "defs", {});
    const marker = addSvgElement(defs, "marker", {
      id: markerId,
      markerWidth: "10",
      markerHeight: "10",
      refX: "8",
      refY: "3",
      orient: "auto",
      markerUnits: "strokeWidth",
    });
    addSvgElement(marker, "path", { d: "M0,0 L0,6 L9,3 z", class: "mermaid-arrow" });

    diagram.edges.forEach(function (edge) {
      const from = layout.positions.get(edge.from);
      const to = layout.positions.get(edge.to);
      if (!from || !to) return;
      const points = edgePoints(from, to);
      const attrs = {
        x1: points[0],
        y1: points[1],
        x2: points[2],
        y2: points[3],
        class: edge.dashed ? "mermaid-edge dashed" : "mermaid-edge",
      };
      if (edge.directed) attrs["marker-end"] = "url(#" + markerId + ")";
      addSvgElement(svg, "line", attrs);
      if (edge.label) {
        addSvgElement(svg, "text", {
          x: (points[0] + points[2]) / 2,
          y: (points[1] + points[3]) / 2 - 8,
          class: "mermaid-edge-label",
          "text-anchor": "middle",
        }, shortLabel(edge.label));
      }
    });

    diagram.nodes.forEach(function (node) {
      const box = layout.positions.get(node.id);
      if (!box) return;
      addSvgElement(svg, "rect", {
        x: box.x,
        y: box.y,
        width: box.width,
        height: box.height,
        rx: "7",
        class: "mermaid-node",
      });
      addSvgElement(svg, "text", {
        x: box.x + box.width / 2,
        y: box.y + box.height / 2 + 5,
        class: "mermaid-label",
        "text-anchor": "middle",
      }, shortLabel(node.label));
    });

    pre.replaceWith(svg);
  }

  function renderMermaid() {
    document.querySelectorAll("pre[data-mermaid]").forEach(renderMermaidBlock);
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
    button.setAttribute("aria-label", "Copy code to clipboard");
    setButtonState(button, "Copy");
    button.addEventListener("click", async function () {
      const original = button.textContent || "Copy";
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

  function renderCodeCopyButtons() {
    document.querySelectorAll(".markdown-body pre").forEach(enhanceCodeBlock);
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
    preview.innerHTML = '<p class="muted">Loading preview...</p>';
    try {
      const response = await fetch("/markdown/preview", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: source,
      });
      if (!response.ok) throw new Error("preview failed");
      preview.innerHTML = await response.text();
      renderMath();
      renderMermaid();
      renderCodeCopyButtons();
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

  function renderMarkdownEnhancements() {
    renderMath();
    renderMermaid();
    renderCodeCopyButtons();
    renderRelativeTimes();
    initIssueActionMenus();
    initIssueSidebarMenus();
    initMarkdownEditors();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderMarkdownEnhancements);
  } else {
    renderMarkdownEnhancements();
  }
})();
