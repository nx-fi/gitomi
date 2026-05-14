(function () {
  "use strict";

  function registerLocalAliases() {
    if (typeof hljs === "undefined") return;
    if (hljs.getLanguage("ini") && !hljs.getLanguage("toml")) {
      hljs.registerAliases(["toml"], { languageName: "ini" });
    }
  }

  function highlightElement(element) {
    if (typeof hljs === "undefined" || !element || element.dataset.highlighted === "yes") return;
    try {
      hljs.highlightElement(element);
    } catch (_) {
      element.classList.add("hljs");
      element.dataset.highlighted = "yes";
    }
  }

  function highlightAll() {
    registerLocalAliases();
    document.querySelectorAll("pre code, .blob-lines code, .blame-lines code").forEach(highlightElement);
  }

  window.gitomiHighlightAll = highlightAll;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", highlightAll);
  } else {
    highlightAll();
  }
})();
