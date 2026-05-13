(function () {
  "use strict";

  const keywordSets = {
    zig: "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
    javascript: "async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null return static super switch this throw true try typeof undefined var void while with yield",
    typescript: "abstract any as async await boolean break case catch class const continue debugger default delete do else enum export extends false finally for from function if implements import in instanceof interface let module namespace never new null number private protected public readonly return static string super switch this throw true try type typeof undefined var void while with yield",
    bash: "case do done elif else esac fi for function if in local readonly return shift then while",
    sh: "case do done elif else esac fi for function if in local readonly return shift then while",
    json: "false null true",
    markdown: "",
    toml: "false true",
    yaml: "false null true",
    css: "important",
    html: "",
    xml: "",
    sql: "alter and as by create delete drop exists from group having in insert into join left not null on or order primary select set table update values where",
    rust: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
    python: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield",
  };

  function escapeHtml(value) {
    return value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function languageOf(element) {
    const match = String(element.className || "").match(/(?:^|\s)language-([a-z0-9_+-]+)/i);
    return match ? match[1].toLowerCase() : "";
  }

  function keywordsFor(language) {
    const words = keywordSets[language] || "";
    return new Set(words.split(/\s+/).filter(Boolean));
  }

  function span(kind, value) {
    return '<span class="hljs-' + kind + '">' + escapeHtml(value) + "</span>";
  }

  function highlightString(code, index) {
    const quote = code[index];
    let end = index + 1;
    while (end < code.length) {
      if (code[end] === "\\") {
        end += 2;
        continue;
      }
      if (code[end] === quote) {
        end += 1;
        break;
      }
      end += 1;
    }
    return [span("string", code.slice(index, end)), end];
  }

  function highlightLineComment(code, index, marker) {
    return [span("comment", code.slice(index)), code.length];
  }

  function highlightBlockComment(code, index) {
    const end = code.indexOf("*/", index + 2);
    const stop = end === -1 ? code.length : end + 2;
    return [span("comment", code.slice(index, stop)), stop];
  }

  function highlightNumber(code, index) {
    const match = code.slice(index).match(/^0x[0-9a-fA-F_]+|^[0-9][0-9_]*(?:\.[0-9_]+)?/);
    const value = match ? match[0] : code[index];
    return [span("number", value), index + value.length];
  }

  function highlightIdentifier(code, index, keywords) {
    const match = code.slice(index).match(/^[A-Za-z_][A-Za-z0-9_]*/);
    const value = match ? match[0] : code[index];
    const kind = keywords.has(value) ? "keyword" : "title";
    return [keywords.has(value) ? span(kind, value) : escapeHtml(value), index + value.length];
  }

  function highlightJsonKey(code, index) {
    const match = code.slice(index).match(/^"([^"\\]|\\.)*"\s*:/);
    if (!match) return null;
    const text = match[0];
    const colon = text.lastIndexOf(":");
    return [span("attr", text.slice(0, colon)) + escapeHtml(text.slice(colon)), index + text.length];
  }

  function highlight(code, language) {
    const keywords = keywordsFor(language);
    let output = "";
    let index = 0;
    while (index < code.length) {
      if (language === "json") {
        const key = highlightJsonKey(code, index);
        if (key) {
          output += key[0];
          index = key[1];
          continue;
        }
      }
      if (code.startsWith("//", index)) {
        const part = highlightLineComment(code, index, "//");
        output += part[0];
        index = part[1];
      } else if ((language === "bash" || language === "sh" || language === "toml" || language === "yaml") && code[index] === "#") {
        const part = highlightLineComment(code, index, "#");
        output += part[0];
        index = part[1];
      } else if (code.startsWith("/*", index)) {
        const part = highlightBlockComment(code, index);
        output += part[0];
        index = part[1];
      } else if (code[index] === '"' || code[index] === "'" || code[index] === "`") {
        const part = highlightString(code, index);
        output += part[0];
        index = part[1];
      } else if (/[0-9]/.test(code[index])) {
        const part = highlightNumber(code, index);
        output += part[0];
        index = part[1];
      } else if (/[A-Za-z_]/.test(code[index])) {
        const part = highlightIdentifier(code, index, keywords);
        output += part[0];
        index = part[1];
      } else {
        output += escapeHtml(code[index]);
        index += 1;
      }
    }
    return output;
  }

  function highlightElement(element) {
    if (!element || element.dataset.highlighted === "yes") return;
    const language = languageOf(element);
    element.innerHTML = highlight(element.textContent || "", language);
    element.classList.add("hljs");
    element.dataset.highlighted = "yes";
  }

  function highlightAll() {
    document.querySelectorAll("pre code, .blob-lines code").forEach(highlightElement);
  }

  window.hljs = { highlightElement, highlightAll };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", highlightAll);
  } else {
    highlightAll();
  }
})();
