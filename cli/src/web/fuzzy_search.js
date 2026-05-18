(function () {
  "use strict";

  function searchTokens(value) {
    return value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  }

  function fuzzyScore(text, token) {
    if (token === "") return 0;
    if (text === token) return 0;
    if (text.startsWith(token)) return 20 + text.length - token.length;

    const exactIndex = text.indexOf(token);
    if (exactIndex !== -1) return 45 + exactIndex * 2 + text.length - token.length;
    if (token.length > text.length) return null;

    let first = -1;
    let last = -1;
    let tokenIndex = 0;
    for (let i = 0; i < text.length && tokenIndex < token.length; i += 1) {
      if (text.charCodeAt(i) === token.charCodeAt(tokenIndex)) {
        if (first === -1) first = i;
        last = i;
        tokenIndex += 1;
      }
    }
    if (tokenIndex !== token.length) return null;

    const spread = last - first + 1 - token.length;
    return 90 + first * 3 + spread * 5 + text.length;
  }

  function baseScore(item, options) {
    if (options && typeof options.baseScore === "function") return options.baseScore(item);
    if (options && Number.isFinite(options.baseScore)) return options.baseScore;
    return 0;
  }

  function scoreSearchItem(item, tokens, options) {
    if (tokens.length === 0) return null;
    let score = baseScore(item, options);
    tokens.forEach(function (token) {
      if (score === null) return;
      const nameScore = fuzzyScore(item.searchName, token);
      const pathScore = fuzzyScore(item.searchPath, token);
      if (nameScore === null && pathScore === null) {
        score = null;
      } else {
        score += Math.min(
          nameScore === null ? Number.POSITIVE_INFINITY : nameScore,
          pathScore === null ? Number.POSITIVE_INFINITY : pathScore + 12,
        );
      }
    });
    return score;
  }

  function rankedSearchItems(items, tokens, limit, options) {
    const settings = options || {};
    const currentItems = typeof items === "function" ? items() : items;
    const source = Array.isArray(currentItems) ? currentItems : [];
    if (tokens.length === 0) {
      if (!settings.includeEmpty) return [];
      return source.slice(0, limit).map(function (item) {
        return { item: item, score: 0 };
      });
    }
    return source
      .map(function (item) {
        return {
          item: item,
          score: settings.skipEmptyPath && item.path === "" ? null : scoreSearchItem(item, tokens, settings),
        };
      })
      .filter(function (result) {
        return result.score !== null;
      })
      .sort(function (a, b) {
        return a.score - b.score ||
          a.item.searchPath.length - b.item.searchPath.length ||
          a.item.searchPath.localeCompare(b.item.searchPath);
      })
      .slice(0, limit);
  }

  function appendHighlightedText(parent, text, tokens) {
    const lower = text.toLowerCase();
    const ranges = [];

    tokens.forEach(function (token) {
      if (!token) return;
      let start = lower.indexOf(token);
      while (start !== -1) {
        ranges.push({ start: start, end: start + token.length });
        start = lower.indexOf(token, start + token.length);
      }
    });

    ranges.sort(function (a, b) {
      return a.start - b.start || b.end - a.end;
    });

    let cursor = 0;
    ranges.forEach(function (range) {
      if (range.start < cursor) return;
      if (range.start > cursor) {
        parent.appendChild(document.createTextNode(text.slice(cursor, range.start)));
      }

      const mark = document.createElement("mark");
      mark.textContent = text.slice(range.start, range.end);
      parent.appendChild(mark);
      cursor = range.end;
    });

    if (cursor < text.length) parent.appendChild(document.createTextNode(text.slice(cursor)));
  }

  window.gitomiFuzzySearch = {
    searchTokens: searchTokens,
    fuzzyScore: fuzzyScore,
    rankedSearchItems: rankedSearchItems,
    appendHighlightedText: appendHighlightedText,
  };
})();
