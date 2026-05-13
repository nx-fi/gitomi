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

  function renderMarkdownEnhancements() {
    renderMath();
    renderMermaid();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderMarkdownEnhancements);
  } else {
    renderMarkdownEnhancements();
  }
})();
