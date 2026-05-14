/*
Language: TLA+
Description: TLA+ specification language syntax definition for Highlight.js.
Website: https://lamport.azurewebsites.net/tla/tla.html
Category: formal
*/

(function () {
  "use strict";

  function tla(hljs) {
    const IDENT_RE = "[A-Za-z_][A-Za-z0-9_]*";
    const KEYWORDS = {
      keyword:
        "ACTION ASSUME ASSUMPTION AXIOM BY CASE CONSTANT CONSTANTS COROLLARY " +
        "DEF DEFINE ELSE ENABLED EXCEPT EXTENDS HAVE HIDE IF IN INSTANCE " +
        "LAMBDA LEMMA LET LOCAL MODULE NEW OBVIOUS OMITTED ONLY OTHER PICK " +
        "PROOF PROPOSITION PROVE QED RECURSIVE SF_ STATE SUBSET SUFFICES " +
        "TAKE TEMPORAL THEN THEOREM UNCHANGED UNION USE VARIABLE VARIABLES " +
        "WF_ WITH WITNESS",
      literal: "BOOLEAN FALSE TRUE",
      built_in:
        "Append Cardinality Cat DOMAIN Head Int Len Nat Range Seq SelectSeq " +
        "STRING SubSeq Tail",
    };

    const MODULE_HEADER = {
      className: "meta",
      begin: /^-{4,}\s*MODULE\s+[A-Za-z_][A-Za-z0-9_]*\s*-{4,}/,
      keywords: KEYWORDS,
    };

    const MODULE_END = {
      className: "meta",
      begin: /^={4,}/,
    };

    const LABEL = {
      className: "symbol",
      begin: /\b[A-Za-z_][A-Za-z0-9_]*::/,
    };

    const STRING = {
      className: "string",
      begin: /"/,
      end: /"/,
      contains: [hljs.BACKSLASH_ESCAPE],
    };

    const NUMBER = {
      className: "number",
      variants: [
        { begin: /\b\\[oO][0-7]+/ },
        { begin: /\b\\[hH][0-9a-fA-F]+/ },
        { begin: /\b[0-9]+(?:\.[0-9]+)?/ },
      ],
      relevance: 0,
    };

    const OPERATOR = {
      className: "operator",
      variants: [
        { begin: /\\[A-Za-z][A-Za-z0-9_]*/ },
        { begin: /<=>|=>|==|\/\\|\\\/|\\in|\\notin|\\subseteq|\\union|\\intersect|\\A|\\E|\\AA|\\EE/ },
        { begin: /[\[\]{}()<>.=,;:|!+\-*/%#&~?^@]+/ },
      ],
    };

    const DEFINITION = {
      begin: [new RegExp("\\b" + IDENT_RE + "\\b"), /\s*(?:\([^)]*\)\s*)?==/],
      className: { 1: "title.function", 2: "operator" },
      keywords: KEYWORDS,
    };

    return {
      name: "TLA+",
      aliases: ["tla", "tlaplus"],
      case_insensitive: false,
      keywords: KEYWORDS,
      contains: [
        MODULE_HEADER,
        MODULE_END,
        hljs.COMMENT(/\\\*/, /$/),
        STRING,
        NUMBER,
        LABEL,
        DEFINITION,
        OPERATOR,
      ],
    };
  }

  if (typeof hljs !== "undefined") {
    hljs.registerLanguage("tla", tla);
    hljs.registerLanguage("tlaplus", tla);
  } else if (typeof document !== "undefined") {
    document.addEventListener("DOMContentLoaded", function () {
      if (typeof hljs !== "undefined") {
        hljs.registerLanguage("tla", tla);
        hljs.registerLanguage("tlaplus", tla);
      }
    });
  }

  if (typeof window !== "undefined") {
    window.tla = tla;
  }
})();
