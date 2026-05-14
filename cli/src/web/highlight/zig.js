/*
Language: Zig
Description: Zig syntax definition for Highlight.js.
Website: https://ziglang.org
Category: common
*/

(function () {
  "use strict";

  function zig(hljs) {
    const IDENT_RE = "[A-Za-z_][A-Za-z0-9_]*";
    const KEYWORDS = {
      keyword:
        "addrspace align allowzero and anyframe anytype asm async await break " +
        "callconv catch comptime const continue defer else enum errdefer error " +
        "export extern fn for if inline linksection noalias noinline nosuspend " +
        "opaque or orelse packed pub resume return struct suspend switch test " +
        "threadlocal try union unreachable usingnamespace var volatile while",
      literal: "false null true undefined",
      built_in:
        "This anyerror anyframe anyopaque bool c_int c_long c_longdouble c_longlong " +
        "c_short c_uint c_ulong c_ulonglong c_ushort comptime_float comptime_int " +
        "f16 f32 f64 f80 f128 isize noreturn type usize void " +
        "i8 i16 i24 i32 i40 i48 i56 i64 i72 i80 i88 i96 i104 i112 i120 i128 i136 i144 i152 i160 i168 i176 i184 i192 i200 i208 i216 i224 i232 i240 i248 i256 " +
        "u8 u16 u24 u32 u40 u48 u56 u64 u72 u80 u88 u96 u104 u112 u120 u128 u136 u144 u152 u160 u168 u176 u184 u192 u200 u208 u216 u224 u232 u240 u248 u256",
    };

    const BUILTIN = {
      className: "built_in",
      begin: "@" + IDENT_RE,
    };

    const BUILTIN_STRING = {
      className: "symbol",
      begin: /@"/,
      end: /"/,
      contains: [hljs.BACKSLASH_ESCAPE],
    };

    const MULTILINE_STRING = {
      className: "string",
      begin: /\\\\/,
      end: /$/,
    };

    const NUMBER = {
      className: "number",
      variants: [
        { begin: /\b0b[01_]+/ },
        { begin: /\b0o[0-7_]+/ },
        { begin: /\b0x[0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][+-]?[0-9_]+)?/ },
        { begin: /\b[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?/ },
      ],
      relevance: 0,
    };

    const PARAMS = {
      className: "params",
      begin: /\(/,
      end: /\)/,
      keywords: KEYWORDS,
      contains: [
        hljs.C_LINE_COMMENT_MODE,
        hljs.APOS_STRING_MODE,
        hljs.QUOTE_STRING_MODE,
        MULTILINE_STRING,
        BUILTIN_STRING,
        BUILTIN,
        NUMBER,
      ],
    };

    return {
      name: "Zig",
      aliases: ["zig"],
      keywords: KEYWORDS,
      contains: [
        hljs.C_LINE_COMMENT_MODE,
        MULTILINE_STRING,
        BUILTIN_STRING,
        hljs.APOS_STRING_MODE,
        hljs.QUOTE_STRING_MODE,
        BUILTIN,
        NUMBER,
        {
          begin: [/\b(fn)\b/, /\s+/, IDENT_RE],
          className: { 1: "keyword", 3: "title.function" },
          contains: [PARAMS],
        },
        {
          begin: [/\b(const|var)\b/, /\s+/, IDENT_RE, /\s*=\s*/, /\b(struct|enum|union|opaque)\b/],
          className: { 1: "keyword", 3: "title.class", 5: "keyword" },
        },
        {
          begin: [/\b(struct|enum|union|opaque|error)\b/, /\s+/, IDENT_RE],
          className: { 1: "keyword", 3: "title.class" },
        },
        {
          className: "meta",
          begin: /\b(?:align|addrspace|callconv|linksection)\s*\(/,
          end: /\)/,
          keywords: KEYWORDS,
          contains: [BUILTIN, NUMBER, hljs.APOS_STRING_MODE, hljs.QUOTE_STRING_MODE],
        },
        {
          className: "operator",
          begin: /[-+*/%=!<>|&?:~]+/,
        },
        {
          className: "punctuation",
          begin: /[{}\[\]().,;]/,
        },
      ],
    };
  }

  if (typeof hljs !== "undefined") {
    hljs.registerLanguage("zig", zig);
  } else if (typeof document !== "undefined") {
    document.addEventListener("DOMContentLoaded", function () {
      if (typeof hljs !== "undefined") hljs.registerLanguage("zig", zig);
    });
  }

  if (typeof window !== "undefined") {
    window.zig = zig;
  }
})();
