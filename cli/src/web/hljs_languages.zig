const std = @import("std");

pub const Language = struct {
    id: []const u8,
    name: []const u8,
    aliases: []const []const u8,
};

// Generated from cli/src/web/vendor/hljs/languages plus Gitomi-local highlight extensions.
// Later entries intentionally win alias conflicts, matching highlight.js registration behavior.
const aliases_1c = [_][]const u8{};
const aliases_abnf = [_][]const u8{};
const aliases_accesslog = [_][]const u8{};
const aliases_actionscript = [_][]const u8{ "as" };
const aliases_ada = [_][]const u8{};
const aliases_angelscript = [_][]const u8{ "asc" };
const aliases_apache = [_][]const u8{ "apacheconf" };
const aliases_applescript = [_][]const u8{ "osascript" };
const aliases_arcade = [_][]const u8{};
const aliases_arduino = [_][]const u8{ "cc", "c++", "h++", "hpp", "hh", "hxx", "cxx" };
const aliases_armasm = [_][]const u8{ "arm" };
const aliases_asciidoc = [_][]const u8{ "adoc" };
const aliases_aspectj = [_][]const u8{};
const aliases_autohotkey = [_][]const u8{ "ahk" };
const aliases_autoit = [_][]const u8{};
const aliases_avrasm = [_][]const u8{};
const aliases_awk = [_][]const u8{};
const aliases_axapta = [_][]const u8{ "x++" };
const aliases_bash = [_][]const u8{ "sh", "zsh" };
const aliases_basic = [_][]const u8{};
const aliases_bnf = [_][]const u8{};
const aliases_brainfuck = [_][]const u8{ "bf" };
const aliases_c = [_][]const u8{ "h" };
const aliases_cal = [_][]const u8{};
const aliases_capnproto = [_][]const u8{ "capnp" };
const aliases_ceylon = [_][]const u8{};
const aliases_clean = [_][]const u8{ "icl", "dcl" };
const aliases_clojure_repl = [_][]const u8{};
const aliases_clojure = [_][]const u8{ "clj", "edn" };
const aliases_cmake = [_][]const u8{ "cmake.in" };
const aliases_coffeescript = [_][]const u8{ "coffee", "cson", "iced" };
const aliases_coq = [_][]const u8{};
const aliases_cos = [_][]const u8{ "cls" };
const aliases_cpp = [_][]const u8{ "cc", "c++", "h++", "hpp", "hh", "hxx", "cxx" };
const aliases_crmsh = [_][]const u8{ "crm", "pcmk" };
const aliases_crystal = [_][]const u8{ "cr" };
const aliases_csharp = [_][]const u8{ "cs", "c#" };
const aliases_csp = [_][]const u8{};
const aliases_css = [_][]const u8{};
const aliases_d = [_][]const u8{};
const aliases_dart = [_][]const u8{};
const aliases_delphi = [_][]const u8{ "dpr", "dfm", "pas", "pascal" };
const aliases_diff = [_][]const u8{ "patch" };
const aliases_django = [_][]const u8{ "jinja" };
const aliases_dns = [_][]const u8{ "bind", "zone" };
const aliases_dockerfile = [_][]const u8{ "docker" };
const aliases_dos = [_][]const u8{ "bat", "cmd" };
const aliases_dsconfig = [_][]const u8{};
const aliases_dts = [_][]const u8{};
const aliases_dust = [_][]const u8{ "dst" };
const aliases_ebnf = [_][]const u8{};
const aliases_elixir = [_][]const u8{ "ex", "exs" };
const aliases_elm = [_][]const u8{};
const aliases_erb = [_][]const u8{};
const aliases_erlang_repl = [_][]const u8{};
const aliases_erlang = [_][]const u8{ "erl" };
const aliases_excel = [_][]const u8{ "xlsx", "xls" };
const aliases_fix = [_][]const u8{};
const aliases_flix = [_][]const u8{};
const aliases_fortran = [_][]const u8{ "f90", "f95" };
const aliases_fsharp = [_][]const u8{ "fs", "f#" };
const aliases_gams = [_][]const u8{ "gms" };
const aliases_gauss = [_][]const u8{ "gss" };
const aliases_gcode = [_][]const u8{ "nc" };
const aliases_gherkin = [_][]const u8{ "feature" };
const aliases_glsl = [_][]const u8{};
const aliases_gml = [_][]const u8{};
const aliases_go = [_][]const u8{ "golang" };
const aliases_golo = [_][]const u8{};
const aliases_gradle = [_][]const u8{};
const aliases_graphql = [_][]const u8{ "gql" };
const aliases_groovy = [_][]const u8{};
const aliases_haml = [_][]const u8{};
const aliases_handlebars = [_][]const u8{ "hbs", "html.hbs", "html.handlebars", "htmlbars" };
const aliases_haskell = [_][]const u8{ "hs" };
const aliases_haxe = [_][]const u8{ "hx" };
const aliases_hsp = [_][]const u8{};
const aliases_http = [_][]const u8{ "https" };
const aliases_hy = [_][]const u8{ "hylang" };
const aliases_inform7 = [_][]const u8{ "i7" };
const aliases_ini = [_][]const u8{ "toml" };
const aliases_irpf90 = [_][]const u8{};
const aliases_isbl = [_][]const u8{};
const aliases_java = [_][]const u8{ "jsp" };
const aliases_javascript = [_][]const u8{ "js", "jsx", "mjs", "cjs" };
const aliases_jboss_cli = [_][]const u8{ "wildfly-cli" };
const aliases_json = [_][]const u8{ "jsonc" };
const aliases_julia_repl = [_][]const u8{ "jldoctest" };
const aliases_julia = [_][]const u8{};
const aliases_kotlin = [_][]const u8{ "kt", "kts" };
const aliases_lasso = [_][]const u8{ "ls", "lassoscript" };
const aliases_latex = [_][]const u8{ "tex" };
const aliases_ldif = [_][]const u8{};
const aliases_leaf = [_][]const u8{};
const aliases_less = [_][]const u8{};
const aliases_lisp = [_][]const u8{};
const aliases_livecodeserver = [_][]const u8{};
const aliases_livescript = [_][]const u8{ "ls" };
const aliases_llvm = [_][]const u8{};
const aliases_lsl = [_][]const u8{};
const aliases_lua = [_][]const u8{ "pluto" };
const aliases_makefile = [_][]const u8{ "mk", "mak", "make" };
const aliases_markdown = [_][]const u8{ "md", "mkdown", "mkd" };
const aliases_mathematica = [_][]const u8{ "mma", "wl" };
const aliases_matlab = [_][]const u8{};
const aliases_maxima = [_][]const u8{};
const aliases_mel = [_][]const u8{};
const aliases_mercury = [_][]const u8{ "m", "moo" };
const aliases_mipsasm = [_][]const u8{ "mips" };
const aliases_mizar = [_][]const u8{};
const aliases_mojolicious = [_][]const u8{};
const aliases_monkey = [_][]const u8{};
const aliases_moonscript = [_][]const u8{ "moon" };
const aliases_n1ql = [_][]const u8{};
const aliases_nestedtext = [_][]const u8{ "nt" };
const aliases_nginx = [_][]const u8{ "nginxconf" };
const aliases_nim = [_][]const u8{};
const aliases_nix = [_][]const u8{ "nixos" };
const aliases_node_repl = [_][]const u8{};
const aliases_nsis = [_][]const u8{};
const aliases_objectivec = [_][]const u8{ "mm", "objc", "obj-c", "obj-c++", "objective-c++" };
const aliases_ocaml = [_][]const u8{ "ml" };
const aliases_openscad = [_][]const u8{ "scad" };
const aliases_oxygene = [_][]const u8{};
const aliases_parser3 = [_][]const u8{};
const aliases_perl = [_][]const u8{ "pl", "pm" };
const aliases_pf = [_][]const u8{ "pf.conf" };
const aliases_pgsql = [_][]const u8{ "postgres", "postgresql" };
const aliases_php_template = [_][]const u8{};
const aliases_php = [_][]const u8{};
const aliases_plaintext = [_][]const u8{ "text", "txt" };
const aliases_pony = [_][]const u8{};
const aliases_powershell = [_][]const u8{ "pwsh", "ps", "ps1" };
const aliases_processing = [_][]const u8{ "pde" };
const aliases_profile = [_][]const u8{};
const aliases_prolog = [_][]const u8{};
const aliases_properties = [_][]const u8{};
const aliases_protobuf = [_][]const u8{ "proto" };
const aliases_puppet = [_][]const u8{ "pp" };
const aliases_purebasic = [_][]const u8{ "pb", "pbi" };
const aliases_python_repl = [_][]const u8{ "pycon" };
const aliases_python = [_][]const u8{ "py", "gyp", "ipython" };
const aliases_q = [_][]const u8{ "k", "kdb" };
const aliases_qml = [_][]const u8{ "qt" };
const aliases_r = [_][]const u8{};
const aliases_reasonml = [_][]const u8{ "re" };
const aliases_rib = [_][]const u8{};
const aliases_roboconf = [_][]const u8{ "graph", "instances" };
const aliases_routeros = [_][]const u8{ "mikrotik" };
const aliases_rsl = [_][]const u8{};
const aliases_ruby = [_][]const u8{ "rb", "gemspec", "podspec", "thor", "irb" };
const aliases_ruleslanguage = [_][]const u8{};
const aliases_rust = [_][]const u8{ "rs" };
const aliases_sas = [_][]const u8{};
const aliases_scala = [_][]const u8{};
const aliases_scheme = [_][]const u8{ "scm" };
const aliases_scilab = [_][]const u8{ "sci" };
const aliases_scss = [_][]const u8{};
const aliases_shell = [_][]const u8{ "console", "shellsession" };
const aliases_smali = [_][]const u8{};
const aliases_smalltalk = [_][]const u8{ "st" };
const aliases_sml = [_][]const u8{ "ml" };
const aliases_sqf = [_][]const u8{};
const aliases_sql = [_][]const u8{};
const aliases_stan = [_][]const u8{ "stanfuncs" };
const aliases_stata = [_][]const u8{ "do", "ado" };
const aliases_step21 = [_][]const u8{ "p21", "step", "stp" };
const aliases_stylus = [_][]const u8{ "styl" };
const aliases_subunit = [_][]const u8{};
const aliases_swift = [_][]const u8{};
const aliases_taggerscript = [_][]const u8{};
const aliases_tap = [_][]const u8{};
const aliases_tcl = [_][]const u8{ "tk" };
const aliases_thrift = [_][]const u8{};
const aliases_tp = [_][]const u8{};
const aliases_twig = [_][]const u8{ "craftcms" };
const aliases_typescript = [_][]const u8{ "js", "jsx", "mjs", "cjs" };
const aliases_vala = [_][]const u8{};
const aliases_vbnet = [_][]const u8{ "vb" };
const aliases_vbscript_html = [_][]const u8{};
const aliases_vbscript = [_][]const u8{ "vbs" };
const aliases_verilog = [_][]const u8{ "v", "sv", "svh" };
const aliases_vhdl = [_][]const u8{};
const aliases_vim = [_][]const u8{};
const aliases_wasm = [_][]const u8{};
const aliases_wren = [_][]const u8{};
const aliases_x86asm = [_][]const u8{};
const aliases_xl = [_][]const u8{ "tao" };
const aliases_xml = [_][]const u8{ "html", "xhtml", "rss", "atom", "xjb", "xsd", "xsl", "plist", "wsf", "svg" };
const aliases_xquery = [_][]const u8{ "xpath", "xq", "xqm" };
const aliases_yaml = [_][]const u8{ "yml" };
const aliases_zephir = [_][]const u8{ "zep" };
const aliases_zig = [_][]const u8{ "zig" };
const aliases_solidity = [_][]const u8{ "sol" };
const aliases_tla = [_][]const u8{ "tlaplus" };
const aliases_toml = [_][]const u8{ "toml" };

pub const languages = [_]Language{
    .{ .id = "1c", .name = "1C:Enterprise", .aliases = &aliases_1c },
    .{ .id = "abnf", .name = "Augmented Backus-Naur Form", .aliases = &aliases_abnf },
    .{ .id = "accesslog", .name = "Apache Access Log", .aliases = &aliases_accesslog },
    .{ .id = "actionscript", .name = "actionscript", .aliases = &aliases_actionscript },
    .{ .id = "ada", .name = "Ada", .aliases = &aliases_ada },
    .{ .id = "angelscript", .name = "angelscript", .aliases = &aliases_angelscript },
    .{ .id = "apache", .name = "apache", .aliases = &aliases_apache },
    .{ .id = "applescript", .name = "AppleScript", .aliases = &aliases_applescript },
    .{ .id = "arcade", .name = "ArcGIS Arcade", .aliases = &aliases_arcade },
    .{ .id = "arduino", .name = "C++", .aliases = &aliases_arduino },
    .{ .id = "armasm", .name = "ARM Assembly", .aliases = &aliases_armasm },
    .{ .id = "asciidoc", .name = "AsciiDoc", .aliases = &aliases_asciidoc },
    .{ .id = "aspectj", .name = "AspectJ", .aliases = &aliases_aspectj },
    .{ .id = "autohotkey", .name = "autohotkey", .aliases = &aliases_autohotkey },
    .{ .id = "autoit", .name = "autoit", .aliases = &aliases_autoit },
    .{ .id = "avrasm", .name = "avrasm", .aliases = &aliases_avrasm },
    .{ .id = "awk", .name = "awk", .aliases = &aliases_awk },
    .{ .id = "axapta", .name = "X++", .aliases = &aliases_axapta },
    .{ .id = "bash", .name = "bash", .aliases = &aliases_bash },
    .{ .id = "basic", .name = "basic", .aliases = &aliases_basic },
    .{ .id = "bnf", .name = "bnf", .aliases = &aliases_bnf },
    .{ .id = "brainfuck", .name = "Brainfuck", .aliases = &aliases_brainfuck },
    .{ .id = "c", .name = "C", .aliases = &aliases_c },
    .{ .id = "cal", .name = "cal", .aliases = &aliases_cal },
    .{ .id = "capnproto", .name = "Cap\\u2019n Proto", .aliases = &aliases_capnproto },
    .{ .id = "ceylon", .name = "ceylon", .aliases = &aliases_ceylon },
    .{ .id = "clean", .name = "clean", .aliases = &aliases_clean },
    .{ .id = "clojure-repl", .name = "clojure-repl", .aliases = &aliases_clojure_repl },
    .{ .id = "clojure", .name = "clojure", .aliases = &aliases_clojure },
    .{ .id = "cmake", .name = "cmake", .aliases = &aliases_cmake },
    .{ .id = "coffeescript", .name = "coffeescript", .aliases = &aliases_coffeescript },
    .{ .id = "coq", .name = "coq", .aliases = &aliases_coq },
    .{ .id = "cos", .name = "cos", .aliases = &aliases_cos },
    .{ .id = "cpp", .name = "C++", .aliases = &aliases_cpp },
    .{ .id = "crmsh", .name = "crmsh", .aliases = &aliases_crmsh },
    .{ .id = "crystal", .name = "crystal", .aliases = &aliases_crystal },
    .{ .id = "csharp", .name = "C#", .aliases = &aliases_csharp },
    .{ .id = "csp", .name = "csp", .aliases = &aliases_csp },
    .{ .id = "css", .name = "CSS", .aliases = &aliases_css },
    .{ .id = "d", .name = "d", .aliases = &aliases_d },
    .{ .id = "dart", .name = "Dart", .aliases = &aliases_dart },
    .{ .id = "delphi", .name = "Delphi", .aliases = &aliases_delphi },
    .{ .id = "diff", .name = "Diff", .aliases = &aliases_diff },
    .{ .id = "django", .name = "Django", .aliases = &aliases_django },
    .{ .id = "dns", .name = "dns", .aliases = &aliases_dns },
    .{ .id = "dockerfile", .name = "dockerfile", .aliases = &aliases_dockerfile },
    .{ .id = "dos", .name = "Batch file (DOS)", .aliases = &aliases_dos },
    .{ .id = "dsconfig", .name = "dsconfig", .aliases = &aliases_dsconfig },
    .{ .id = "dts", .name = "Device Tree", .aliases = &aliases_dts },
    .{ .id = "dust", .name = "dust", .aliases = &aliases_dust },
    .{ .id = "ebnf", .name = "Extended Backus-Naur Form", .aliases = &aliases_ebnf },
    .{ .id = "elixir", .name = "elixir", .aliases = &aliases_elixir },
    .{ .id = "elm", .name = "Elm", .aliases = &aliases_elm },
    .{ .id = "erb", .name = "erb", .aliases = &aliases_erb },
    .{ .id = "erlang-repl", .name = "erlang-repl", .aliases = &aliases_erlang_repl },
    .{ .id = "erlang", .name = "Erlang", .aliases = &aliases_erlang },
    .{ .id = "excel", .name = "excel", .aliases = &aliases_excel },
    .{ .id = "fix", .name = "fix", .aliases = &aliases_fix },
    .{ .id = "flix", .name = "flix", .aliases = &aliases_flix },
    .{ .id = "fortran", .name = "Fortran", .aliases = &aliases_fortran },
    .{ .id = "fsharp", .name = "fsharp", .aliases = &aliases_fsharp },
    .{ .id = "gams", .name = "gams", .aliases = &aliases_gams },
    .{ .id = "gauss", .name = "gauss", .aliases = &aliases_gauss },
    .{ .id = "gcode", .name = "G-code (ISO 6983)", .aliases = &aliases_gcode },
    .{ .id = "gherkin", .name = "gherkin", .aliases = &aliases_gherkin },
    .{ .id = "glsl", .name = "glsl", .aliases = &aliases_glsl },
    .{ .id = "gml", .name = "gml", .aliases = &aliases_gml },
    .{ .id = "go", .name = "Go", .aliases = &aliases_go },
    .{ .id = "golo", .name = "golo", .aliases = &aliases_golo },
    .{ .id = "gradle", .name = "gradle", .aliases = &aliases_gradle },
    .{ .id = "graphql", .name = "GraphQL", .aliases = &aliases_graphql },
    .{ .id = "groovy", .name = "Groovy", .aliases = &aliases_groovy },
    .{ .id = "haml", .name = "haml", .aliases = &aliases_haml },
    .{ .id = "handlebars", .name = "Handlebars", .aliases = &aliases_handlebars },
    .{ .id = "haskell", .name = "haskell", .aliases = &aliases_haskell },
    .{ .id = "haxe", .name = "haxe", .aliases = &aliases_haxe },
    .{ .id = "hsp", .name = "hsp", .aliases = &aliases_hsp },
    .{ .id = "http", .name = "HTTP", .aliases = &aliases_http },
    .{ .id = "hy", .name = "hy", .aliases = &aliases_hy },
    .{ .id = "inform7", .name = "inform7", .aliases = &aliases_inform7 },
    .{ .id = "ini", .name = "ini", .aliases = &aliases_ini },
    .{ .id = "irpf90", .name = "IRPF90", .aliases = &aliases_irpf90 },
    .{ .id = "isbl", .name = "ISBL", .aliases = &aliases_isbl },
    .{ .id = "java", .name = "Java", .aliases = &aliases_java },
    .{ .id = "javascript", .name = "JavaScript", .aliases = &aliases_javascript },
    .{ .id = "jboss-cli", .name = "jboss-cli", .aliases = &aliases_jboss_cli },
    .{ .id = "json", .name = "JSON", .aliases = &aliases_json },
    .{ .id = "julia-repl", .name = "julia-repl", .aliases = &aliases_julia_repl },
    .{ .id = "julia", .name = "julia", .aliases = &aliases_julia },
    .{ .id = "kotlin", .name = "kotlin", .aliases = &aliases_kotlin },
    .{ .id = "lasso", .name = "lasso", .aliases = &aliases_lasso },
    .{ .id = "latex", .name = "LaTeX", .aliases = &aliases_latex },
    .{ .id = "ldif", .name = "ldif", .aliases = &aliases_ldif },
    .{ .id = "leaf", .name = "leaf", .aliases = &aliases_leaf },
    .{ .id = "less", .name = "less", .aliases = &aliases_less },
    .{ .id = "lisp", .name = "lisp", .aliases = &aliases_lisp },
    .{ .id = "livecodeserver", .name = "livecodeserver", .aliases = &aliases_livecodeserver },
    .{ .id = "livescript", .name = "LiveScript", .aliases = &aliases_livescript },
    .{ .id = "llvm", .name = "LLVM IR", .aliases = &aliases_llvm },
    .{ .id = "lsl", .name = "LSL (Linden Scripting Language)", .aliases = &aliases_lsl },
    .{ .id = "lua", .name = "Lua", .aliases = &aliases_lua },
    .{ .id = "makefile", .name = "makefile", .aliases = &aliases_makefile },
    .{ .id = "markdown", .name = "markdown", .aliases = &aliases_markdown },
    .{ .id = "mathematica", .name = "mathematica", .aliases = &aliases_mathematica },
    .{ .id = "matlab", .name = "Matlab", .aliases = &aliases_matlab },
    .{ .id = "maxima", .name = "maxima", .aliases = &aliases_maxima },
    .{ .id = "mel", .name = "mel", .aliases = &aliases_mel },
    .{ .id = "mercury", .name = "mercury", .aliases = &aliases_mercury },
    .{ .id = "mipsasm", .name = "mipsasm", .aliases = &aliases_mipsasm },
    .{ .id = "mizar", .name = "mizar", .aliases = &aliases_mizar },
    .{ .id = "mojolicious", .name = "mojolicious", .aliases = &aliases_mojolicious },
    .{ .id = "monkey", .name = "Monkey", .aliases = &aliases_monkey },
    .{ .id = "moonscript", .name = "MoonScript", .aliases = &aliases_moonscript },
    .{ .id = "n1ql", .name = "n1ql", .aliases = &aliases_n1ql },
    .{ .id = "nestedtext", .name = "nestedtext", .aliases = &aliases_nestedtext },
    .{ .id = "nginx", .name = "nginx", .aliases = &aliases_nginx },
    .{ .id = "nim", .name = "nim", .aliases = &aliases_nim },
    .{ .id = "nix", .name = "nix", .aliases = &aliases_nix },
    .{ .id = "node-repl", .name = "node-repl", .aliases = &aliases_node_repl },
    .{ .id = "nsis", .name = "NSIS", .aliases = &aliases_nsis },
    .{ .id = "objectivec", .name = "Objective-C", .aliases = &aliases_objectivec },
    .{ .id = "ocaml", .name = "ocaml", .aliases = &aliases_ocaml },
    .{ .id = "openscad", .name = "OpenSCAD", .aliases = &aliases_openscad },
    .{ .id = "oxygene", .name = "Oxygene", .aliases = &aliases_oxygene },
    .{ .id = "parser3", .name = "Parser3", .aliases = &aliases_parser3 },
    .{ .id = "perl", .name = "perl", .aliases = &aliases_perl },
    .{ .id = "pf", .name = "pf", .aliases = &aliases_pf },
    .{ .id = "pgsql", .name = "PostgreSQL", .aliases = &aliases_pgsql },
    .{ .id = "php-template", .name = "php-template", .aliases = &aliases_php_template },
    .{ .id = "php", .name = "php", .aliases = &aliases_php },
    .{ .id = "plaintext", .name = "plaintext", .aliases = &aliases_plaintext },
    .{ .id = "pony", .name = "pony", .aliases = &aliases_pony },
    .{ .id = "powershell", .name = "powershell", .aliases = &aliases_powershell },
    .{ .id = "processing", .name = "Processing", .aliases = &aliases_processing },
    .{ .id = "profile", .name = "profile", .aliases = &aliases_profile },
    .{ .id = "prolog", .name = "prolog", .aliases = &aliases_prolog },
    .{ .id = "properties", .name = ".properties", .aliases = &aliases_properties },
    .{ .id = "protobuf", .name = "Protocol Buffers", .aliases = &aliases_protobuf },
    .{ .id = "puppet", .name = "Puppet", .aliases = &aliases_puppet },
    .{ .id = "purebasic", .name = "purebasic", .aliases = &aliases_purebasic },
    .{ .id = "python-repl", .name = "python-repl", .aliases = &aliases_python_repl },
    .{ .id = "python", .name = "python", .aliases = &aliases_python },
    .{ .id = "q", .name = "q", .aliases = &aliases_q },
    .{ .id = "qml", .name = "QML", .aliases = &aliases_qml },
    .{ .id = "r", .name = "R", .aliases = &aliases_r },
    .{ .id = "reasonml", .name = "reasonml", .aliases = &aliases_reasonml },
    .{ .id = "rib", .name = "rib", .aliases = &aliases_rib },
    .{ .id = "roboconf", .name = "Roboconf", .aliases = &aliases_roboconf },
    .{ .id = "routeros", .name = "MikroTik RouterOS script", .aliases = &aliases_routeros },
    .{ .id = "rsl", .name = "RenderMan RSL", .aliases = &aliases_rsl },
    .{ .id = "ruby", .name = "ruby", .aliases = &aliases_ruby },
    .{ .id = "ruleslanguage", .name = "ruleslanguage", .aliases = &aliases_ruleslanguage },
    .{ .id = "rust", .name = "Rust", .aliases = &aliases_rust },
    .{ .id = "sas", .name = "SAS", .aliases = &aliases_sas },
    .{ .id = "scala", .name = "Scala", .aliases = &aliases_scala },
    .{ .id = "scheme", .name = "scheme", .aliases = &aliases_scheme },
    .{ .id = "scilab", .name = "Scilab", .aliases = &aliases_scilab },
    .{ .id = "scss", .name = "SCSS", .aliases = &aliases_scss },
    .{ .id = "shell", .name = "shell", .aliases = &aliases_shell },
    .{ .id = "smali", .name = "Smali", .aliases = &aliases_smali },
    .{ .id = "smalltalk", .name = "Smalltalk", .aliases = &aliases_smalltalk },
    .{ .id = "sml", .name = "sml", .aliases = &aliases_sml },
    .{ .id = "sqf", .name = "sqf", .aliases = &aliases_sqf },
    .{ .id = "sql", .name = "SQL", .aliases = &aliases_sql },
    .{ .id = "stan", .name = "Stan", .aliases = &aliases_stan },
    .{ .id = "stata", .name = "stata", .aliases = &aliases_stata },
    .{ .id = "step21", .name = "step21", .aliases = &aliases_step21 },
    .{ .id = "stylus", .name = "Stylus", .aliases = &aliases_stylus },
    .{ .id = "subunit", .name = "subunit", .aliases = &aliases_subunit },
    .{ .id = "swift", .name = "Swift", .aliases = &aliases_swift },
    .{ .id = "taggerscript", .name = "taggerscript", .aliases = &aliases_taggerscript },
    .{ .id = "tap", .name = "tap", .aliases = &aliases_tap },
    .{ .id = "tcl", .name = "Tcl", .aliases = &aliases_tcl },
    .{ .id = "thrift", .name = "thrift", .aliases = &aliases_thrift },
    .{ .id = "tp", .name = "tp", .aliases = &aliases_tp },
    .{ .id = "twig", .name = "Twig", .aliases = &aliases_twig },
    .{ .id = "typescript", .name = "JavaScript", .aliases = &aliases_typescript },
    .{ .id = "vala", .name = "vala", .aliases = &aliases_vala },
    .{ .id = "vbnet", .name = "Visual Basic .NET", .aliases = &aliases_vbnet },
    .{ .id = "vbscript-html", .name = "vbscript-html", .aliases = &aliases_vbscript_html },
    .{ .id = "vbscript", .name = "VBScript", .aliases = &aliases_vbscript },
    .{ .id = "verilog", .name = "Verilog", .aliases = &aliases_verilog },
    .{ .id = "vhdl", .name = "VHDL", .aliases = &aliases_vhdl },
    .{ .id = "vim", .name = "vim", .aliases = &aliases_vim },
    .{ .id = "wasm", .name = "wasm", .aliases = &aliases_wasm },
    .{ .id = "wren", .name = "Wren", .aliases = &aliases_wren },
    .{ .id = "x86asm", .name = "x86asm", .aliases = &aliases_x86asm },
    .{ .id = "xl", .name = "XL", .aliases = &aliases_xl },
    .{ .id = "xml", .name = "xml", .aliases = &aliases_xml },
    .{ .id = "xquery", .name = "xquery", .aliases = &aliases_xquery },
    .{ .id = "yaml", .name = "yaml", .aliases = &aliases_yaml },
    .{ .id = "zephir", .name = "Zephir", .aliases = &aliases_zephir },
    .{ .id = "zig", .name = "Zig", .aliases = &aliases_zig },
    .{ .id = "solidity", .name = "Solidity", .aliases = &aliases_solidity },
    .{ .id = "tla", .name = "TLA+", .aliases = &aliases_tla },
    .{ .id = "toml", .name = "TOML", .aliases = &aliases_toml },
};

pub fn languageForToken(token: []const u8) ?[]const u8 {
    if (token.len == 0) return null;
    var i = languages.len;
    while (i > 0) {
        i -= 1;
        const language = languages[i];
        if (std.ascii.eqlIgnoreCase(token, language.id)) return language.id;
        for (language.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(token, alias)) return language.id;
        }
    }
    return null;
}

pub fn displayName(language_id: []const u8) []const u8 {
    var i = languages.len;
    while (i > 0) {
        i -= 1;
        const language = languages[i];
        if (std.ascii.eqlIgnoreCase(language_id, language.id)) return language.name;
    }
    return language_id;
}

