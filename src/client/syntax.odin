package main

// Syntax-Highlighting für Multiline-Code-Blöcke (```lang … ```).
// Ein generischer Tokenizer + kompakte Sprachdefinitionen decken die
// gängigen Sprachen und Formate ab. Kein Anspruch auf Parser-Präzision —
// Kommentare, Strings, Zahlen und Keywords reichen für lesbaren Chat-Code.

import "core:strings"

import rl "vendor:raylib"

Tok_Kind :: enum {
	Plain,
	Keyword,
	Type, // Typen / Builtins / Konstanten (zweite Farbe)
	String,
	Number,
	Comment,
}

Token :: struct {
	text: string,
	kind: Tok_Kind,
}

Lang :: struct {
	label:            string,
	names:            []string, // Aliase hinter ```
	keywords:         []string,
	types:            []string,
	line_comments:    []string,
	block_open:       string,
	block_close:      string,
	quotes:           string, // Zeichen, die Strings öffnen/schließen
	case_insensitive: bool,   // SQL, Dockerfile
	markup:           bool,   // HTML/XML: <tag> einfärben
	dollar_var:       bool,   // bash/php: $ident hervorheben
	hex_hash:         bool,   // css: #fff als Zahl
}

syn_color :: proc(k: Tok_Kind) -> rl.Color {
	switch k {
	case .Plain:
		return SYN_TEXT
	case .Keyword:
		return SYN_KEYWORD
	case .Type:
		return SYN_TYPE
	case .String:
		return SYN_STRING
	case .Number:
		return SYN_NUMBER
	case .Comment:
		return SYN_COMMENT
	}
	return SYN_TEXT
}

// --- Sprachdefinitionen ---

@(private = "file")
LANGS := []Lang{
	{
		label = "JavaScript", names = {"js", "javascript", "jsx", "mjs", "cjs"},
		keywords = {"const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "import", "export", "from", "default", "try", "catch", "finally", "throw", "async", "await", "yield", "static", "get", "set", "void"},
		types = {"true", "false", "null", "undefined", "this", "console", "Promise", "Array", "Object", "Math", "JSON", "String", "Number", "Boolean", "Map", "Set", "Error", "window", "document"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'`",
	},
	{
		label = "TypeScript", names = {"ts", "typescript", "tsx"},
		keywords = {"const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "import", "export", "from", "default", "try", "catch", "finally", "throw", "async", "await", "yield", "static", "get", "set", "interface", "type", "enum", "implements", "declare", "readonly", "namespace", "abstract", "public", "private", "protected", "satisfies", "keyof", "infer", "as", "is", "void"},
		types = {"true", "false", "null", "undefined", "this", "console", "Promise", "Array", "Object", "Math", "JSON", "string", "number", "boolean", "any", "never", "unknown", "object", "Map", "Set", "Record", "Partial", "Error"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'`",
	},
	{
		label = "Python", names = {"py", "python", "python3"},
		keywords = {"def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "class", "import", "from", "as", "with", "try", "except", "finally", "raise", "yield", "lambda", "global", "nonlocal", "pass", "break", "continue", "del", "assert", "async", "await", "match", "case"},
		types = {"None", "True", "False", "self", "cls", "print", "len", "range", "int", "str", "float", "list", "dict", "set", "tuple", "bool", "super", "type", "isinstance", "enumerate", "zip", "open"},
		line_comments = {"#"}, quotes = "\"'",
	},
	{
		label = "Rust", names = {"rs", "rust"},
		keywords = {"fn", "let", "mut", "const", "static", "if", "else", "match", "for", "while", "loop", "in", "return", "break", "continue", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "super", "as", "ref", "move", "unsafe", "async", "await", "dyn", "where", "type", "macro_rules"},
		types = {"i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f32", "f64", "usize", "isize", "bool", "char", "str", "String", "Vec", "Option", "Some", "None", "Result", "Ok", "Err", "Box", "Rc", "Arc", "Self", "self", "true", "false", "println", "HashMap"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"",
	},
	{
		label = "Go", names = {"go", "golang"},
		keywords = {"break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"},
		types = {"bool", "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "byte", "rune", "error", "true", "false", "nil", "iota", "make", "new", "len", "cap", "append", "panic", "any", "fmt"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'`",
	},
	{
		label = "C", names = {"c", "h"},
		keywords = {"auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register", "return", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "volatile", "while", "restrict"},
		types = {"void", "char", "short", "int", "long", "float", "double", "NULL", "true", "false", "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "bool", "FILE", "printf", "malloc", "free", "memcpy"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'",
	},
	{
		label = "C++", names = {"cpp", "c++", "cc", "cxx", "hpp"},
		keywords = {"auto", "break", "case", "catch", "class", "const", "constexpr", "continue", "default", "delete", "do", "else", "enum", "explicit", "extern", "final", "for", "friend", "goto", "if", "inline", "namespace", "new", "noexcept", "operator", "override", "private", "protected", "public", "return", "sizeof", "static", "struct", "switch", "template", "throw", "try", "typedef", "typename", "union", "using", "virtual", "volatile", "while"},
		types = {"void", "char", "short", "int", "long", "float", "double", "bool", "true", "false", "nullptr", "this", "std", "string", "vector", "map", "size_t", "auto", "cout", "cin", "endl", "unique_ptr", "shared_ptr"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'",
	},
	{
		label = "C#", names = {"cs", "csharp", "c#"},
		keywords = {"abstract", "as", "base", "break", "case", "catch", "checked", "class", "const", "continue", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally", "fixed", "for", "foreach", "goto", "if", "implicit", "in", "interface", "internal", "is", "lock", "namespace", "new", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "sizeof", "static", "struct", "switch", "throw", "try", "typeof", "unchecked", "unsafe", "using", "var", "virtual", "volatile", "while", "async", "await", "yield"},
		types = {"bool", "byte", "char", "decimal", "double", "float", "int", "long", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void", "true", "false", "null", "this", "Console", "List", "Dictionary", "Task", "String"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'",
	},
	{
		label = "Java", names = {"java"},
		keywords = {"abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof", "interface", "native", "new", "package", "private", "protected", "public", "record", "return", "static", "strictfp", "super", "switch", "synchronized", "throw", "throws", "transient", "try", "var", "volatile", "while"},
		types = {"boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "true", "false", "null", "this", "String", "System", "Integer", "List", "Map", "Object", "Exception"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'",
	},
	{
		label = "Kotlin", names = {"kt", "kotlin", "kts"},
		keywords = {"fun", "val", "var", "if", "else", "when", "for", "while", "do", "return", "class", "object", "interface", "data", "sealed", "enum", "companion", "init", "constructor", "override", "open", "abstract", "final", "private", "public", "protected", "internal", "import", "package", "is", "in", "as", "try", "catch", "finally", "throw", "break", "continue", "by", "lazy", "suspend"},
		types = {"Int", "Long", "String", "Boolean", "Float", "Double", "List", "Map", "Set", "Unit", "Any", "Nothing", "true", "false", "null", "this", "super", "println"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'",
	},
	{
		label = "Swift", names = {"swift"},
		keywords = {"func", "let", "var", "if", "else", "guard", "switch", "case", "for", "while", "repeat", "return", "class", "struct", "enum", "protocol", "extension", "import", "private", "public", "internal", "fileprivate", "open", "static", "final", "override", "init", "deinit", "throws", "try", "catch", "defer", "in", "is", "as", "where", "break", "continue", "async", "await"},
		types = {"Int", "String", "Bool", "Double", "Float", "Array", "Dictionary", "Set", "Optional", "Any", "Self", "self", "true", "false", "nil", "print"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"",
	},
	{
		label = "PHP", names = {"php"},
		keywords = {"function", "return", "if", "else", "elseif", "for", "foreach", "while", "do", "switch", "case", "break", "continue", "class", "extends", "implements", "new", "echo", "print", "use", "namespace", "public", "private", "protected", "static", "const", "try", "catch", "finally", "throw", "as", "instanceof", "require", "require_once", "include", "include_once", "match", "fn"},
		types = {"true", "false", "null", "this", "self", "array", "string", "int", "float", "bool", "void", "mixed"},
		line_comments = {"//", "#"}, block_open = "/*", block_close = "*/", quotes = "\"'", dollar_var = true,
	},
	{
		label = "Ruby", names = {"rb", "ruby"},
		keywords = {"def", "end", "if", "elsif", "else", "unless", "case", "when", "while", "until", "for", "in", "do", "return", "class", "module", "begin", "rescue", "ensure", "yield", "and", "or", "not", "require", "require_relative", "attr_accessor", "attr_reader", "new", "lambda", "proc", "then", "raise", "break", "next"},
		types = {"self", "nil", "true", "false", "puts", "print", "Array", "Hash", "String", "Integer", "Float", "Symbol"},
		line_comments = {"#"}, quotes = "\"'",
	},
	{
		label = "Lua", names = {"lua"},
		keywords = {"and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while"},
		types = {"nil", "true", "false", "self", "print", "pairs", "ipairs", "table", "string", "math", "require", "type", "tostring", "tonumber"},
		line_comments = {"--"}, quotes = "\"'",
	},
	{
		label = "Odin", names = {"odin"},
		keywords = {"package", "import", "proc", "struct", "enum", "union", "map", "dynamic", "if", "else", "when", "for", "in", "not_in", "switch", "case", "defer", "return", "break", "continue", "fallthrough", "using", "distinct", "bit_set", "matrix", "or_else", "or_return", "where", "do", "foreign", "cast", "transmute", "auto_cast"},
		types = {"int", "uint", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f16", "f32", "f64", "bool", "b8", "b32", "string", "cstring", "rune", "rawptr", "byte", "uintptr", "any", "true", "false", "nil", "context", "len", "cap", "make", "append", "delete", "new", "free", "clamp", "min", "max"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'`",
	},
	{
		label = "Zig", names = {"zig"},
		keywords = {"const", "var", "fn", "pub", "if", "else", "while", "for", "switch", "defer", "errdefer", "return", "break", "continue", "struct", "enum", "union", "error", "try", "catch", "orelse", "unreachable", "comptime", "inline", "export", "extern", "async", "await", "test", "and", "or"},
		types = {"u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "usize", "isize", "bool", "void", "type", "anytype", "anyerror", "true", "false", "null", "undefined"},
		line_comments = {"//"}, quotes = "\"'",
	},
	{
		label = "SQL", names = {"sql", "mysql", "postgres", "postgresql", "sqlite"},
		keywords = {"select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "column", "index", "view", "join", "left", "right", "inner", "outer", "full", "cross", "on", "as", "and", "or", "not", "null", "primary", "key", "foreign", "references", "group", "by", "order", "having", "limit", "offset", "distinct", "union", "all", "exists", "between", "like", "in", "is", "asc", "desc", "if", "case", "when", "then", "else", "end", "begin", "commit", "rollback", "transaction"},
		types = {"count", "sum", "avg", "min", "max", "int", "integer", "varchar", "text", "boolean", "date", "timestamp", "serial", "bigint", "numeric", "true", "false", "coalesce", "now"},
		line_comments = {"--"}, block_open = "/*", block_close = "*/", quotes = "\"'", case_insensitive = true,
	},
	{
		label = "Shell", names = {"sh", "bash", "shell", "zsh", "console"},
		keywords = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "in", "echo", "exit", "return", "local", "export", "source", "set", "unset", "shift", "read", "cd", "break", "continue", "sudo", "alias", "test"},
		types = {"true", "false"},
		line_comments = {"#"}, quotes = "\"'", dollar_var = true,
	},
	{
		label = "PowerShell", names = {"powershell", "ps1", "pwsh"},
		keywords = {"function", "param", "if", "else", "elseif", "switch", "foreach", "for", "while", "do", "return", "try", "catch", "finally", "throw", "class", "enum", "begin", "process", "end", "in", "break", "continue"},
		types = {"Write-Host", "Get-Item", "Set-Item", "Write-Output", "true", "false", "null"},
		line_comments = {"#"}, block_open = "<#", block_close = "#>", quotes = "\"'", dollar_var = true, case_insensitive = true,
	},
	{
		label = "JSON", names = {"json", "jsonc"},
		keywords = {},
		types = {"true", "false", "null"},
		line_comments = {"//"}, quotes = "\"",
	},
	{
		label = "YAML", names = {"yaml", "yml"},
		keywords = {},
		types = {"true", "false", "null", "yes", "no", "on", "off"},
		line_comments = {"#"}, quotes = "\"'",
	},
	{
		label = "TOML", names = {"toml"},
		keywords = {},
		types = {"true", "false"},
		line_comments = {"#"}, quotes = "\"'",
	},
	{
		label = "INI", names = {"ini", "cfg", "conf"},
		keywords = {},
		types = {"true", "false"},
		line_comments = {";", "#"}, quotes = "\"'",
	},
	{
		label = "HTML", names = {"html", "htm"},
		keywords = {},
		types = {},
		block_open = "<!--", block_close = "-->", quotes = "\"'", markup = true,
	},
	{
		label = "XML", names = {"xml", "svg", "xhtml"},
		keywords = {},
		types = {},
		block_open = "<!--", block_close = "-->", quotes = "\"'", markup = true,
	},
	{
		label = "CSS", names = {"css", "scss", "less"},
		keywords = {"important", "media", "keyframes", "import", "supports", "font-face", "root"},
		types = {"px", "em", "rem", "vh", "vw", "deg", "fr", "auto", "none", "inherit", "initial", "flex", "grid", "block", "absolute", "relative", "fixed", "hidden", "solid"},
		line_comments = {"//"}, block_open = "/*", block_close = "*/", quotes = "\"'", hex_hash = true,
	},
	{
		label = "Dockerfile", names = {"dockerfile", "docker", "containerfile"},
		keywords = {"from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"},
		types = {},
		line_comments = {"#"}, quotes = "\"'", case_insensitive = true, dollar_var = true,
	},
	{
		label = "Makefile", names = {"makefile", "make", "mk"},
		keywords = {"ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", "unexport", "override"},
		types = {},
		line_comments = {"#"}, quotes = "\"'", dollar_var = true,
	},
	{
		label = "Diff", names = {"diff", "patch"},
		keywords = {},
		types = {},
		quotes = "",
	},
	{
		label = "Text", names = {"text", "txt", "plain", "plaintext", "md", "markdown"},
		keywords = {},
		types = {},
		quotes = "",
	},
}

// Sprache anhand des ```-Tags finden (nil = unbekannt → plain).
lang_lookup :: proc(name: string) -> ^Lang {
	if name == "" {
		return nil
	}
	n := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	for &l in LANGS {
		for alias in l.names {
			if alias == n {
				return &l
			}
		}
	}
	return nil
}

// --- Tokenizer ---

// Zeilenübergreifender Zustand (Block-Kommentare).
Highlighter :: struct {
	lang:             ^Lang,
	in_block_comment: bool,
}

@(private = "file")
is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_ident_start :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80
}

@(private = "file")
is_ident_char :: proc(c: byte) -> bool {
	return is_ident_start(c) || is_digit(c)
}

@(private = "file")
is_hex :: proc(c: byte) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

@(private = "file")
word_kind :: proc(l: ^Lang, word: string) -> Tok_Kind {
	w := word
	if l.case_insensitive {
		w = strings.to_lower(word, context.temp_allocator)
	}
	for k in l.keywords {
		if k == w {
			return .Keyword
		}
	}
	for t in l.types {
		if t == w {
			return .Type
		}
	}
	return .Plain
}

// Eine logische Zeile in Tokens zerlegen (temp-alloziert). Plain-Läufe
// werden zusammengefasst, damit wenige Draw-Calls entstehen.
highlight_line :: proc(hl: ^Highlighter, line: string) -> []Token {
	tokens := make([dynamic]Token, context.temp_allocator)
	if hl.lang == nil {
		if len(line) > 0 {
			append(&tokens, Token{line, .Plain})
		}
		return tokens[:]
	}
	l := hl.lang

	push :: proc(tokens: ^[dynamic]Token, text: string, kind: Tok_Kind) {
		if len(text) > 0 {
			append(tokens, Token{text, kind})
		}
	}

	i := 0
	run := 0 // Beginn des aktuellen Plain-Laufs
	for i < len(line) {
		// Innerhalb eines Block-Kommentars: bis zum Ende-Marker
		if hl.in_block_comment {
			end := strings.index(line[i:], l.block_close)
			if end < 0 {
				push(&tokens, line[i:], .Comment)
				return tokens[:]
			}
			stop := i + end + len(l.block_close)
			push(&tokens, line[i:stop], .Comment)
			hl.in_block_comment = false
			i = stop
			run = i
			continue
		}

		rest := line[i:]
		c := line[i]

		// Block-Kommentar-Start
		if l.block_open != "" && strings.has_prefix(rest, l.block_open) {
			push(&tokens, line[run:i], .Plain)
			hl.in_block_comment = true
			run = i
			// gleiche Iteration übernimmt den Kommentar-Zweig oben
			continue
		}

		// Zeilen-Kommentar
		line_comment := false
		for lc in l.line_comments {
			if strings.has_prefix(rest, lc) {
				push(&tokens, line[run:i], .Plain)
				push(&tokens, line[i:], .Comment)
				line_comment = true
				break
			}
		}
		if line_comment {
			return tokens[:]
		}

		// Markup-Tags: <name, </name, /> als Keyword
		if l.markup && c == '<' {
			push(&tokens, line[run:i], .Plain)
			j := i + 1
			if j < len(line) && line[j] == '/' {
				j += 1
			}
			for j < len(line) && (is_ident_char(line[j]) || line[j] == '-' || line[j] == '!') {
				j += 1
			}
			push(&tokens, line[i:j], .Keyword)
			i = j
			run = i
			continue
		}

		// String
		if len(l.quotes) > 0 && strings.index_byte(l.quotes, c) >= 0 {
			push(&tokens, line[run:i], .Plain)
			j := i + 1
			for j < len(line) {
				if line[j] == '\\' && j + 1 < len(line) {
					j += 2
					continue
				}
				if line[j] == c {
					j += 1
					break
				}
				j += 1
			}
			push(&tokens, line[i:j], .String)
			i = j
			run = i
			continue
		}

		// $variable (bash, php, make, docker)
		if l.dollar_var && c == '$' {
			push(&tokens, line[run:i], .Plain)
			j := i + 1
			if j < len(line) && (line[j] == '{' || line[j] == '(') {
				j += 1
			}
			for j < len(line) && is_ident_char(line[j]) {
				j += 1
			}
			if j < len(line) && (line[j] == '}' || line[j] == ')') {
				j += 1
			}
			push(&tokens, line[i:j], .Type)
			i = j
			run = i
			continue
		}

		// #hex-Farbe (css)
		if l.hex_hash && c == '#' && i + 1 < len(line) && is_hex(line[i+1]) {
			push(&tokens, line[run:i], .Plain)
			j := i + 1
			for j < len(line) && is_hex(line[j]) {
				j += 1
			}
			push(&tokens, line[i:j], .Number)
			i = j
			run = i
			continue
		}

		// Zahl (nur am Token-Anfang, nicht mitten im Ident)
		if is_digit(c) && (i == 0 || !is_ident_char(line[i-1])) {
			push(&tokens, line[run:i], .Plain)
			j := i
			for j < len(line) && (is_digit(line[j]) || is_hex(line[j]) ||
				line[j] == '.' || line[j] == '_' || line[j] == 'x' || line[j] == 'X' ||
				line[j] == 'o' || line[j] == 'b') {
				j += 1
			}
			push(&tokens, line[i:j], .Number)
			i = j
			run = i
			continue
		}

		// Wort → Keyword / Typ / Plain
		if is_ident_start(c) {
			j := i
			for j < len(line) && is_ident_char(line[j]) {
				j += 1
			}
			word := line[i:j]
			kind := word_kind(l, word)
			if kind != .Plain {
				push(&tokens, line[run:i], .Plain)
				push(&tokens, word, kind)
				run = j
			}
			i = j
			continue
		}

		i += 1
	}
	push(&tokens, line[run:], .Plain)
	return tokens[:]
}
