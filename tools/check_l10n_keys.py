# Fails when a customer-facing Swift string literal has no key in Localization/translations.json:
# Swift looks the key up at run time, finds nothing and shows the English text in all 7 other
# languages, with CI green. build.yml runs this right after the String Catalog check.
#
#   python tools/check_l10n_keys.py          (exit 1 + one ::error:: line per problem)
#   python tools/check_l10n_keys.py --root <another checkout>   (check that tree instead)
#
# Customer-facing = a literal that Swift turns into a localization key:
#   - String(localized: "..."), AttributedString(localized: "..."), LocalizedStringKey("..."),
#     LocalizedStringResource("..."), NSLocalizedString("..."), `"..." as LocalizedStringKey`, and a
#     literal typed LocalizedStringKey / LocalizedStringResource / String.LocalizationValue:
#     declared, assigned, a parameter default, in an array, or returned by a func / computed
#     property of such a type (return, single-expression body, switch / if expressions);
#   - the first unlabeled argument of the SwiftUI views / modifiers in VIEW_CALLS / MODIFIERS
#     (Text, Button, Label, Toggle, Picker, TextField, Section, .navigationTitle, .alert, ...),
#     `prompt:` of .searchable, `named:` of .accessibilityAction;
#   - arguments of our own funcs / inits / memberwise inits / enum cases declared with one of the
#     three types (or an array of them), called as name(...), self.name(...) or Type.name(...),
#     resolved like Swift (enclosing types first, then top level); x.name(...) only for funcs
#     declared in an extension. Implicit `.name(...)` is never matched (SDK factories share the
#     names: .custom, .success, .system) - write Type.name(...) there.
#   Ternaries: in a typed place every literal branch counts (`c ? "A" : other`); in a SwiftUI view /
#   modifier (it has a String overload) only when every branch is a literal or a localizable value,
#   else the whole is a String and shown verbatim.
# Exempt: Text(verbatim:), comments, literals without a letter (emoji, "$\(price)", "\(n)%",
#   "000000"), and ALLOW below (deliberate English: brand, domain).
# Key = the literal with each \(x) replaced by %lld (Int) or %@ (String, Text, Date, ...), as Swift
#   builds it. The type of x is inferred only where it is sure: literals, Int(...) / String(...),
#   .count, .formatted(...), a declaration in scope (local, parameter, closure / loop variable,
#   property of the enclosing type, TypeName.staticProperty). Anything else = unknown = accepted.
#   A key whose specifier contradicts an inferred type fails; so does a Double / Float / Bool /
#   Int32 value, because the key store only knows %@ and %lld (tools/build_xcstrings.py).
#   Inference wrong? Wrap the value: \(String(x)) or \(Int(x)) keeps Swift's key and is read as
#   sure (or add the code to TYPE_HINTS).
# Keys no Swift literal uses are listed, not failed (e.g. a key kept for an old build).
# Not seen: a literal passed to our own `String` parameter (not a key at all: shown verbatim, never
#   translated; the house rule is String(localized:) at the call site); dictionary values
#   `[K: LocalizedStringKey]`; array mutations (`keys.append("...")`, `+=`, `keys[0] = "..."`); a
#   receiver whose type is unknown (`banner.show("...")`); in a SwiftUI view, a ternary whose other
#   branch is `Type.member` / `f()` of a localizable type (`Text(c ? "A" : Copy.title)`); our own
#   func reusing a SwiftUI view / modifier name (an `.alert(_:note:)` extension: only the SwiftUI
#   rule, the first argument, applies); a closure with statements inside a switch-case value.
# Validated 20/10/2026 against the compiler's own extraction (SWIFT_EMIT_LOC_STRINGS, Xcode 26.3).
import json, os, re, sys, unicodedata

sys.stdout.reconfigure(encoding="utf-8")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if "--root" in sys.argv:
    ROOT = os.path.abspath(sys.argv[sys.argv.index("--root") + 1])
SRC = os.path.join(ROOT, "Sources")

# Deliberately English literals in localizable positions: literal -> why.
ALLOW = {
    "CedarScan": "app name (Home's navigation title)",
    "cedar247.com": "web address shown as a link label (Account)",
}
# Interpolation code whose type the inference gets wrong: exact code -> "lld" or "@".
TYPE_HINTS = {}

VIEW_CALLS = [
    "Text", "Button", "Label", "Toggle", "Picker", "TextField", "SecureField", "Section", "Menu",
    "Link", "ShareLink", "ProgressView", "ContentUnavailableView", "DisclosureGroup", "Stepper",
    "DatePicker", "ColorPicker", "LabeledContent", "NavigationLink", "GroupBox", "ControlGroup",
    "Tab", "Gauge", "PhotosPicker", "SharePreview",
]
MODIFIERS = [
    "navigationTitle", "navigationSubtitle", "navigationBarTitle", "alert", "confirmationDialog",
    "help", "badge", "accessibilityLabel", "accessibilityHint", "accessibilityValue",
    "accessibilityInputLabels",
]
# Our own funcs with these names are not matched on `x.name(...)`: os.Logger & co. own them.
SDK_METHOD_NAMES = {"error", "warning", "info", "debug", "notice", "fault", "log", "trace",
                    "critical", "print", "append", "insert", "contains", "send", "write"}
LOC_TYPES = r"(?:LocalizedStringKey|LocalizedStringResource|String\.LocalizationValue)"
TYPE_RE = r"(?:\[[^\]\n=]*\]\??|[A-Za-z_][\w.<>?!]*)"
SPEC = re.compile(r"%(@|lld)")
SHAPE = "{}"  # an interpolation in a literal's shape (keys: %@ / %lld)


class SwiftSyntax(Exception):
    pass


class Lit:
    def __init__(self, start, end, parts, line):
        self.start, self.end, self.parts, self.line = start, end, parts, line

    @property
    def interps(self):
        return [p for p in self.parts if isinstance(p, tuple)]

    def shape(self):
        """Text with each interpolation as {} and literal braces doubled (unambiguous)."""
        return "".join(SHAPE if isinstance(p, tuple) else p.replace("{", "{{").replace("}", "}}")
                       for p in self.parts)

    def key(self, specs):
        """The key Swift builds: the text as written, or a format when it has interpolations."""
        if not self.interps:
            return "".join(self.parts)
        out, k = [], 0
        for p in self.parts:
            if isinstance(p, tuple):
                out.append("%" + specs[k])
                k += 1
            else:
                out.append(p.replace("%", "%%"))
        return "".join(out)


def key_shape(k):
    """Shape of a translations.json key, comparable with Lit.shape() of an interpolated literal."""
    out, i = [], 0
    while i < len(k):
        m = SPEC.match(k, i)
        if m:
            out.append(SHAPE)
            i = m.end()
        elif k.startswith("%%", i):
            out.append("%")
            i += 2
        else:
            out.append(k[i].replace("{", "{{").replace("}", "}}"))
            i += 1
    return "".join(out)


# ---------------------------------------------------------------- lexer
# masked    = the file with comments, string and regex literals blanked (quotes kept), except
#             interpolation code; nocomment = the file with comments blanked (literals kept).
# Same offsets and line breaks as the source, so code regexes never match inside text/comments.

SIMPLE_ESC = {"0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'"}
OPEN_LIT = re.compile(r'(#*)("""|")')
CONT_RE = re.compile(r"[ \t]*\n")
UNI_RE = re.compile(r"u\{([0-9a-fA-F]{1,8})\}")


def scan(src):
    masked, nocomment, lits = list(src), list(src), []
    end = scan_code(src, 0, lits, masked, nocomment, interp=False)
    assert end == len(src)
    lits.sort(key=lambda l: l.start)
    return "".join(masked), "".join(nocomment), lits


def blank(buf, a, b):
    for k in range(a, b):
        if buf[k] != "\n":
            buf[k] = " "


def scan_code(src, i, lits, masked, nocomment, interp):
    """Scan code from i. interp=True: stop at the `)` that closes an interpolation, return its index."""
    n, depth = len(src), 0
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(masked, i, j)
            blank(nocomment, i, j)
            i = j
            continue
        if src.startswith("/*", i):
            j, level = i + 2, 1
            while level:
                if j >= n:
                    raise SwiftSyntax("unterminated /* comment")
                if src.startswith("/*", j):
                    level, j = level + 1, j + 2
                elif src.startswith("*/", j):
                    level, j = level - 1, j + 2
                else:
                    j += 1
            blank(masked, i, j)
            blank(nocomment, i, j)
            i = j
            continue
        c = src[i]
        if c == '"' or (c == "#" and re.match(r'#+"', src[i:i + 8])):
            i = read_literal(src, i, lits, masked, nocomment)
            continue
        if c == "#":
            mr = re.match(r"(#+)/", src[i:i + 8])
            if mr:                      # extended regex literal #/ ... /#  (\x escapes skipped)
                close = "/" + mr.group(1)
                j = i + mr.end()
                while j < n and not src.startswith(close, j):
                    j += 2 if src[j] == "\\" else 1
                if j >= n:
                    raise SwiftSyntax("unterminated regex literal")
                blank(masked, i, j + len(close))
                i = j + len(close)
                continue
        if interp:
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    return i
                depth -= 1
        i += 1
    if interp:
        raise SwiftSyntax("unterminated interpolation")
    return n


def read_literal(src, i, lits, masked, nocomment):
    m = OPEN_LIT.match(src, i)
    hashes = m.group(1)
    multiline = m.group(2) == '"""'
    close = m.group(2) + hashes
    esc = "\\" + hashes
    j = m.end()
    if multiline and hashes and src[j:src.find("\n", j) if "\n" in src[j:] else len(src)].strip():
        # `#"""#` / `#"""Hi"""#`: a raw ONE-line string whose text starts with quotes
        multiline, close, j = False, '"' + hashes, i + len(hashes) + 1
    if multiline:
        nl = src.find("\n", j)
        if nl < 0 or src[j:nl].strip():
            raise SwiftSyntax('text after an opening """')
        j = nl + 1
    # items: one source character (str), ("C", ch) = an escaped character, ("I", k) = interpolation,
    # ("CONT",) = `\` at the end of a line. Only str "\n" items are line breaks of the source.
    items, interps, code_ranges = [], [], []
    while True:
        if j >= len(src):
            raise SwiftSyntax("unterminated string literal")
        if src.startswith(close, j) and not (multiline and src.startswith('"' + close, j)):
            break
        if src.startswith(esc, j):
            k = j + len(esc)
            ch = src[k]
            if ch == "(":
                a = k + 1
                b = scan_code(src, a, lits, masked, nocomment, interp=True)
                interps.append((src[a:b].strip(), a))
                code_ranges.append((a, b))
                items.append(("I", len(interps) - 1))
                j = b + 1
                continue
            if ch == "u":
                mu = UNI_RE.match(src, k)
                if not mu:
                    raise SwiftSyntax("bad \\u escape")
                items.append(("C", chr(int(mu.group(1), 16))))
                j = mu.end()
                continue
            if multiline and CONT_RE.match(src, k):
                items.append(("CONT",))
                j = k
                continue
            if ch not in SIMPLE_ESC:
                raise SwiftSyntax("unknown escape \\" + ch)
            items.append(("C", SIMPLE_ESC[ch]))
            j = k + 1
            continue
        if src[j] == "\n" and not multiline:
            raise SwiftSyntax("line break in a one-line string literal")
        items.append(src[j])
        j += 1
    end = j + len(close)
    if multiline:
        lines, cur = [], []
        for it in items:
            if it == "\n":
                lines.append(cur)
                cur = []
            else:
                cur.append(it)
        indent = cur                      # what stands before the closing quotes
        if any(not (isinstance(x, str) and x in " \t") for x in indent):
            raise SwiftSyntax('closing """ must be on its own line')
        out = []
        for ln in lines:
            if ln[:len(indent)] == indent:
                ln = ln[len(indent):]
            elif all(isinstance(x, str) and x in " \t" for x in ln):
                ln = []
            else:
                raise SwiftSyntax("a line of a multi-line literal is less indented than its closing quotes")
            if out:
                out.append("\n")
            out.extend(ln)
        items, k = [], 0
        while k < len(out):               # `\` + spaces + line break = no line break
            if out[k] == ("CONT",):
                k += 1
                while k < len(out) and out[k] in (" ", "\t"):
                    k += 1
                if k < len(out) and out[k] == "\n":
                    k += 1
                continue
            items.append(out[k])
            k += 1
    parts, buf = [], []
    for it in items:
        if isinstance(it, tuple) and it[0] == "I":
            if buf:
                parts.append("".join(buf))
                buf = []
            parts.append(interps[it[1]])
        elif isinstance(it, tuple):
            buf.append(it[1])
        else:
            buf.append(it)
    if buf:
        parts.append("".join(buf))
    lits.append(Lit(i, end, parts, src.count("\n", 0, i) + 1))
    prev = i
    for a, b in code_ranges:
        blank(masked, prev, a)
        prev = b
    blank(masked, prev, end)
    masked[i] = masked[end - 1] = '"'  # a blanked literal must not look like nothing
    return end


# ---------------------------------------------------------------- file structure

TYPE_HEAD = re.compile(r"\b(?:struct|class|enum|extension|actor|protocol)\s+"
                       r"(?!func\b|var\b|let\b|subscript\b|init\b|override\b|final\b)([A-Za-z_][\w.]*)[^{};]*$")
FLOW_HEAD = re.compile(r"(?<!#)\b(if|else|for|while|switch|do|catch|repeat|guard|defer)\b(?!\s*:)[^{}]*$")
# A statement keyword at the start of a statement: the text is code, not a single expression.
STATEMENTS = re.compile(r"(?:^|[;\n{])[ \t]*(?:let|var|return|func|get|set|guard|defer|for|while|repeat|do|throw)\b(?!\s*:)")
CLOSURE_PARAMS = re.compile(r"\s*(?:\[[^\]]*\]\s*)?(\([^()]*\)|[A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_]\w*)*)"
                            r"\s*(?:->\s*[\w.<>?!\[\] ]+?\s*)?\bin\b")


class Block:
    __slots__ = ("open", "close", "head", "type_name", "type_qual", "supers", "flow", "inline")

    def __init__(self, open_, inline):
        self.open, self.close, self.inline = open_, None, inline
        self.head, self.type_name, self.type_qual, self.supers, self.flow = "", None, None, [], False

    def set_head(self, head):
        self.head = head
        mt = TYPE_HEAD.search(head)
        self.type_qual = mt.group(1) if mt else None          # `extension Outer.Row` -> Outer.Row
        self.type_name = self.type_qual.split(".")[-1] if mt else None
        if mt:                                                 # `: View, Bannering` (inherited API)
            ms = re.match(r"\s*(?:<[^>{]*>)?\s*:\s*([^{]*?)\s*(?:\bwhere\b.*)?$", head[mt.end(1):], re.S)
            self.supers = [re.sub(r"<.*$", "", x.strip()).split(".")[-1]   # `Base<Int>` -> Base
                           for x in ms.group(1).split(",") if x.strip()] if ms else []
        self.flow = bool(FLOW_HEAD.search(head)) and not self.type_name


def build_blocks(masked):
    """Brace blocks and their heads (the statement text before `{`). A `{` inside an unclosed
    ( or [ of its statement is an inline closure (`contains(where: { ... })`): it neither ends
    nor shows in the head of the statement around it."""
    blocks, stack, heads = [], [], []
    frames = [[0, 0]]                  # per open block: [unclosed ( and [, statement start]
    for k, c in enumerate(masked):
        f = frames[-1]
        if c in "([":
            f[0] += 1
        elif c in ")]":
            f[0] = max(0, f[0] - 1)
        elif c == "{":
            b = Block(k, f[0] > 0)
            blocks.append(b)
            stack.append(b)
            heads.append((b, f[1]))
            frames.append([0, k + 1])
        elif c == "}":
            if stack:
                b = stack.pop()
                b.close = k
                frames.pop()
                if not b.inline:
                    frames[-1][1] = k + 1
            else:
                frames[-1][1] = k + 1
    for b in stack:
        b.close = len(masked)
    inline = [b for b in blocks if b.inline]
    for b, start in heads:
        if b.inline:
            continue
        text = list(masked[start:b.open])
        for ib in inline:
            if start <= ib.open and ib.close < b.open:
                for i in range(ib.open - start, ib.close - start + 1):
                    if text[i] != "\n":
                        text[i] = " "
        b.set_head("".join(text))
    return blocks


class FileInfo:
    def __init__(self, rel, src):
        self.rel, self.src = rel, src
        self.masked, self.nocomment, self.lits = scan(src)
        self.blocks = build_blocks(self.masked)
        self.by_start = {l.start: l for l in self.lits}

    def innermost(self, pos):
        best = None
        for b in self.blocks:
            if b.open < pos < b.close and (best is None or b.open > best.open):
                best = b
        return best

    def next_block(self, pos):
        """The next statement block after pos (inline closures skipped)."""
        return next((b for b in self.blocks if b.open > pos and not b.inline), None)

    def type_blocks(self, pos):
        """The type (and extension) blocks around pos, innermost first."""
        ts = [b for b in self.blocks if b.type_name and b.open < pos < b.close]
        return sorted(ts, key=lambda b: -b.open)

    def type_chain(self, pos):
        """Names of the types (and extensions) around pos, innermost first."""
        return [b.type_name for b in self.type_blocks(pos)]

    def line_of(self, pos):
        return self.src.count("\n", 0, pos) + 1


# ---------------------------------------------------------------- call sites

def arg_end(masked, p):
    """End of the argument / element starting at p: a top-level `,` or the closing bracket."""
    depth, q = 0, p
    while q < len(masked):
        c = masked[q]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return q
            depth -= 1
        elif c == "," and depth == 0:
            return q
        q += 1
    return q


def call_args(masked, open_paren):
    """[(label or None, start, end)] for the call / signature whose `(` is at open_paren."""
    args, p = [], open_paren + 1
    while p < len(masked):
        q = arg_end(masked, p)
        seg = masked[p:q]
        ml = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", seg)
        if ml:
            args.append((ml.group(1), p + ml.end(), q))
        elif seg.strip():
            args.append((None, p, q))
        if q >= len(masked) or masked[q] != ",":
            break
        p = q + 1
    return args


def balanced_end(s, i):
    """Index of the bracket closing the one at s[i] (literals already blanked), or -1."""
    depth = 0
    for k in range(i, len(s)):
        depth += s[k] in "([{"
        depth -= s[k] in ")]}"
        if depth == 0:
            return k
    return -1


def is_ternary_q(s, k):
    """`?` of a ternary: whitespace on its left (`a?.b`, `as?`, `try?` have none), not `??`."""
    return s[k] == "?" and k > 0 and s[k - 1].isspace() and s[k + 1:k + 2] != "?"


def branch_literals(fi, a, b, typed=False, types=None):
    """The literals that ARE the value [a, b): one literal, or the leaves of `c ? x : y` (nested
    too; the condition is ignored, outer parentheses stripped). Untyped (a SwiftUI view or
    modifier with a String overload): every leaf must be a literal or a localizable value, else
    the whole is a String, shown verbatim (`c ? "" : route.title`). Typed (the place only takes
    LocalizedStringKey & co.): every literal leaf is a key, also the right side of `??`."""
    return leaf_literals(fi, a, b, typed, types) or []


def leaf_literals(fi, a, b, typed, types):
    masked, by_start = fi.masked, fi.by_start
    while a < b and masked[a].isspace():
        a += 1
    while b > a and masked[b - 1].isspace():
        b -= 1
    if a >= b:
        return [] if typed else None
    lit = by_start.get(a)
    if lit and lit.end >= b:
        return [lit] if masked[lit.end:b].strip() == "" else ([] if typed else None)
    if lit and re.fullmatch(r"\s+as\s+" + LOC_TYPES + r"\??", masked[lit.end:b]):
        return [lit]                      # "..." as LocalizedStringKey
    if masked[a] == "(" and balanced_end(masked, a) == b - 1:
        return leaf_literals(fi, a + 1, b - 1, typed, types)
    mas = re.search(r"\s+as\s+" + LOC_TYPES + r"\??$", masked[a:b])
    if mas:                               # (c ? "A" : "B") as LocalizedStringKey
        return leaf_literals(fi, a, a + mas.start(), True, types)
    mi = re.match(r"\.init\s*\(", masked[a:b])
    if mi and balanced_end(masked, a + mi.end() - 1) == b - 1:
        args = call_args(masked, a + mi.end() - 1)   # Text(.init("...")) = LocalizedStringKey(...)
        if len(args) == 1 and args[0][0] is None:
            return leaf_literals(fi, args[0][1], args[0][2], True, types)
        return [] if typed else None
    k, depth, q, qq = a, 0, None, None
    while k < b:
        lit = by_start.get(k)
        if lit:
            k = lit.end
            continue
        c = masked[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and masked.startswith("??", k) and qq is None:
            qq = k
            k += 2
            continue
        elif depth == 0 and is_ternary_q(masked, k):
            q = k
            break
        k += 1
    if q is None:
        if qq is not None and not assigns(masked, a, qq) and (typed or is_loc_value(fi, a, qq, types)):
            return leaf_literals(fi, qq + 2, b, True, types)     # x ?? "Default"
        return [] if typed or is_loc_value(fi, a, b, types) else None
    if assigns(masked, a, q):
        return [] if typed else None      # `plan = isTeam ? "Team" : "Pro"`: a statement
    k, depth, nest = q + 1, 0, 0
    while k < b:
        lit = by_start.get(k)
        if lit:
            k = lit.end
            continue
        c = masked[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and is_ternary_q(masked, k):
            nest += 1
        elif depth == 0 and c == ":":
            if nest == 0:
                yes = leaf_literals(fi, q + 1, k, typed, types)
                no = leaf_literals(fi, k + 1, b, typed, types)
                return yes + no if yes is not None and no is not None else None
            nest -= 1
        k += 1
    return [] if typed else None


def assigns(masked, a, b):
    """[a, b) holds a top-level assignment or starts with a statement keyword."""
    if re.match(r"\s*(?:let|var|return|if|guard|case)\b", masked[a:b]):
        return True
    depth = 0
    for k in range(a, b):
        c = masked[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c == "=" and masked[k + 1:k + 2] != "=" and k > 0 and masked[k - 1] not in "=!<>":
            return True
    return False


def is_loc_value(fi, a, b, types):
    """A non-literal value of a localizable type: `x as LocalizedStringKey`, LocalizedStringKey(...),
    or a name / self.name declared LocalizedStringKey & co. (in scope)."""
    e = fi.masked[a:b].strip()
    if re.search(r"\bas\s+" + LOC_TYPES + r"\??$", e) or re.match(LOC_TYPES + r"(?:\.init)?\s*\(", e):
        return True
    m = re.fullmatch(r"(self\.)?([A-Za-z_]\w*)", e)
    if not m or types is None:
        return False
    d = types.resolve(m.group(2), fi, a, "self" if m.group(1) else "local")
    return bool(d and d.typ and param_kind(d.typ) == "loc")


CONT_LINE = re.compile(r"\n[ \t]*(?:\?\?|[?:.+\-*/]|&&|\|\|)")
OP_END = re.compile(r"(?:[?:=+\-*/(\[,]|&&|\|\|)[ \t]*$")


def statement_end(masked, p, limit):
    """From p (after `return` / `case x:` / `=`): to the end of the statement's expression: the
    rest of the line (the next line when that is blank), continued while a line ends with an
    operator or the next one starts with one (`?`, `:`, `.`, `??`, `+`, ...). Brackets nest:
    `contains(where: { ... }) ? "A" : "B"` and a call split over lines stay whole."""
    q = p
    while q < limit and masked[q] in " \t":
        q += 1
    if q < limit and masked[q] == "\n":
        q += 1
        while q < limit and masked[q] in " \t\n":
            q += 1
    start, depth = q, 0
    while q < limit:
        c = masked[q]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return q
            depth -= 1
        elif depth == 0 and c == ";":
            return q
        elif depth == 0 and c == "\n":
            if not (CONT_LINE.match(masked, q) or OP_END.search(masked[start:q])):
                return q
            start = q + 1
        q += 1
    return q


def typed_end(masked, p):
    """End of `x: T = <value>` from p: a top-level `,` `)` `]` `}` `{` (observers) `;`, or the line
    end unless the value goes on (see statement_end)."""
    q, depth, start = p, 0, p
    while q < len(masked):
        c = masked[q]
        if c in "([":
            depth += 1
        elif c in ")]":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and c == "\n":
            if CONT_LINE.match(masked, q) or OP_END.search(masked[start:q]):
                start = q + 1
            else:
                break
        elif depth == 0 and c in ",{};":
            break
        q += 1
    return q


def label_ends(masked, a, b):
    """Positions right after `return`, `default:` and `case ...:` (its `:` at bracket depth 0,
    so `case .running(progress: let p):` works; `if case .x = y` is not a label) in [a, b)."""
    out = []
    for r in re.finditer(r"\breturn\b|\bdefault\s*:|\bcase\b", masked[a:b]):
        p = a + r.end()
        if r.group(0) == "case":
            k, depth = p, 0
            while k < b:
                c = masked[k]
                if c in "([":
                    depth += 1
                elif c in ")]":
                    depth -= 1
                elif c in "{}" or (c == "=" and masked[k + 1:k + 2] != "=" and masked[k - 1:k] not in "=!<>"):
                    k = b
                    break
                elif c == ":" and depth == 0:
                    break
                k += 1
            if k >= b:
                continue
            p = k + 1
        out.append(p)
    return out


def signature_labels(masked, open_paren, payload=False):
    """{label: param kind} of a func / init signature or an enum case payload; unlabeled
    parameters by position: '_0', '_1', ..."""
    labels = {}
    for idx, (label, a, b) in enumerate(call_args(masked, open_paren)):
        text = masked[a:b]
        if label is None:
            mp = re.match(r"\s*(\w+)\s+\w+\s*:\s*(.*)$", text, re.S)
            if mp:
                label, text = mp.group(1), mp.group(2)
            elif payload:
                label = "_"
            else:
                continue
        labels["_%d" % idx if label == "_" else label] = param_kind(text)
    return labels


def param_kind(type_text):
    t = type_text.strip()
    if re.match(LOC_TYPES + r"\??\s*(?:=|$)", t):
        return "loc"
    if re.match(r"\[\s*" + LOC_TYPES + r"\s*\]\??\s*(?:=|$)", t):
        return "array"
    return "other"


class Callees:
    """Our own funcs / inits / memberwise inits / enum cases and their parameter kinds.
    entries[name] = [(owner, file, {label: "loc" | "array" | "other"}, private)]: owner = the type a
    func or enum case belongs to, the PARENT type of a type for its inits (None at top level). A call
    resolves like Swift: enclosing types first, inherited ones, then top level (a private func
    only in its file); labels whose declarations disagree are dropped (overloads: String wins for a
    literal). Names of SwiftUI views / modifiers, and inits of types not declared in Sources
    (`extension Text { init(...) }`), are left to the SwiftUI rules: those calls have String
    overloads."""

    def __init__(self, files):
        self.entries, self.member_ok, self.supers = {}, set(), {}
        declared, top = set(), set()        # our types; those declared at top level
        for fi in files.values():
            for b in fi.blocks:
                if b.type_name:
                    self.supers.setdefault(b.type_name, set()).update(b.supers)
                if b.type_name and re.search(r"\b(?:struct|class|enum|actor)\s", b.head) \
                        and not re.search(r"\b(?:extension|protocol)\s", b.head):
                    declared.add(b.type_name)
                    if len(fi.type_blocks(b.open)) == 0:
                        top.add(b.type_name)
        private_type = lambda tb: bool(re.search(r"\b(?:private|fileprivate)\s+(?:(?:@\w+(?:\([^)]*\))?|final|indirect|nonisolated|distributed)\s+)*(?:struct|class|enum|actor|extension)\s", tb.head))
        for fi in files.values():
            masked = fi.masked
            for m in re.finditer(r"\b(?:func\s+([A-Za-z_]\w*)|(?<!\.)init[?!]?)\s*(?:<[^>]*>)?\s*\(", masked):
                chain = fi.type_chain(m.start())
                line = masked[masked.rfind("\n", 0, m.start()) + 1:m.start()]
                priv = bool(re.search(r"\b(?:private|fileprivate)\b", line))
                if m.group(1):
                    name, owner = m.group(1), (chain[0] if chain else None)
                    blk = fi.innermost(m.start())
                    if blk is not None and blk.type_name and re.search(r"\bextension\s", blk.head):
                        self.member_ok.add(name)   # declared in an extension: called as `x.name(...)`
                elif chain:
                    tb = fi.type_blocks(m.start())[0]
                    if "." in tb.type_qual:          # `extension Outer.Row { init(...) }`
                        name, owner = chain[0], tb.type_qual.split(".")[-2]
                        if name not in declared:
                            continue
                    else:
                        name, owner = chain[0], (chain[1] if len(chain) > 1 else None)
                        if (name not in top if owner is None else name not in declared):
                            continue                 # `extension Text { init(...) }`: an SDK type
                    priv = priv or private_type(tb)  # a private type's inits: its file only
                else:
                    continue
                self.add(name, owner, fi.rel, signature_labels(masked, m.end() - 1), priv)
            for blk in fi.blocks:                   # enum cases: `case a(T), b(label: T)`
                if not (blk.type_name and re.search(r"\benum\s", blk.head)):
                    continue
                for mc in re.finditer(r"\bcase\b", masked[blk.open + 1:blk.close]):
                    k = blk.open + 1 + mc.end()
                    if fi.innermost(k) is not blk:
                        continue                    # a `case` of a switch or of a nested type
                    while True:
                        mn = re.compile(r"\s*([A-Za-z_]\w*)\s*").match(masked, k)
                        if not mn:
                            break
                        k = mn.end()
                        labels = {}
                        if masked[k:k + 1] == "(":
                            labels = signature_labels(masked, k, payload=True)
                            k = balanced_end(masked, k) + 1
                        self.add(mn.group(1), blk.type_name, fi.rel, labels)
                        mr = re.compile(r"\s*=[^,\n]*").match(masked, k)
                        if mr:
                            k = mr.end()
                        mcomma = re.compile(r"\s*,").match(masked, k)
                        if not mcomma:
                            break
                        k = mcomma.end()
            for m in re.finditer(r"\b(let|var)\s+(\w+)\s*:\s*([^\n;{=]*?)[ \t]*(=[^\n;{]*)?(?:\n|;|$)", masked):
                blk = fi.innermost(m.start())
                if blk is None or not blk.type_name or not re.search(r"\bstruct\s", blk.head):
                    continue                        # memberwise init: stored properties of a struct
                if m.group(1) == "let" and m.group(4):
                    continue                        # `let x: T = v` is not a memberwise-init label
                chain = fi.type_chain(m.start())
                self.add(blk.type_name, chain[1] if len(chain) > 1 else None, fi.rel,
                         {m.group(2): param_kind(m.group(3))}, private_type(blk))
        sdk = set(VIEW_CALLS) | set(MODIFIERS) | {"String", "AttributedString", "LocalizedStringKey",
                                                  "LocalizedStringResource", "NSLocalizedString"}
        self.localizable = {n for n, es in self.entries.items() if (n not in sdk or n in declared)
                            and any(k != "other" for e in es for k in e[2].values())}

    def add(self, name, owner, rel, labels, priv=False):
        self.entries.setdefault(name, []).append((owner, rel, labels, priv))

    def labels_for(self, name, fi, pos, form, base=None):
        es = self.entries.get(name, [])
        sel = []
        if form in ("bare", "self"):
            blocks = fi.type_blocks(pos)
            for b in blocks:
                sel = [e[2] for e in es if e[0] == b.type_name]
                if sel:
                    break
            if not sel:                      # inherited: protocol extensions, superclasses (transitive)
                todo = [s for b in blocks for s in self.supers.get(b.type_name, ())]  # incl. `extension X: P`
                supers = set()
                while todo:
                    t = todo.pop()
                    if t not in supers:
                        supers.add(t)
                        todo.extend(self.supers.get(t, ()))
                sel = [e[2] for e in es if e[0] in supers]
            if not sel and form == "bare":   # top level: a private func only in its own file
                sel = [e[2] for e in es if e[0] is None and (not e[3] or e[1] == fi.rel)]
        elif form == "type":
            sel = [e[2] for e in es if e[0] == base]
        elif form == "member" and name in self.member_ok and name not in SDK_METHOD_NAMES:
            sel = [e[2] for e in es]
        merged = {}
        for lb in sel:
            for k, v in lb.items():
                merged.setdefault(k, set()).add(v)
        return {k: vs.pop() for k, vs in merged.items() if len(vs) == 1 and "other" not in vs}


def localizable_literals(fi, callees, types):
    masked = fi.masked
    hits = {}

    def keep(lits, why):
        for lit in lits:
            hits.setdefault(lit.start, (lit, why))

    def take(a, b, why, typed=False):
        keep(branch_literals(fi, a, b, typed, types), why)

    def take_array(a, b, why, typed=True):
        """Elements of an array literal. Untyped (an overload takes [String] too): only when every
        element is a literal or a localizable value, else the whole array is a [String]."""
        while a < b and masked[a].isspace():
            a += 1
        if masked[a:a + 1] != "[":
            take(a, b, why, typed)
            return
        end = balanced_end(masked, a)
        found, k = [], a + 1
        while 0 < end and k < end:
            e = min(arg_end(masked, k), end)
            leaves = leaf_literals(fi, k, e, typed, types)
            if leaves is None:
                return
            found += leaves
            k = e + 1
        keep(found, why)

    def take_value(p, limit, why, array=False, end=None):
        """A value of a localizable type from p: a literal / ternary up to the end of the statement,
        or an `if` / `switch` expression (the value of each branch)."""
        q = p
        while q < limit and masked[q].isspace():
            q += 1
        mk = re.match(r"(if|switch)\b", masked[q:limit])
        if not mk:
            e = statement_end(masked, p, limit) if end is None else end(masked, p)
            if array:
                take_array(p, e, why)
            else:
                take(p, e, why, True)
            return
        blk = fi.next_block(q)
        if blk is None or blk.open >= limit:
            return
        # Only expression branches hold values; a branch with statements returns through `return`
        # (taken by the returned rule), its first line is not a value.
        if mk.group(1) == "switch":
            for a, b in case_values(fi, blk):
                if not STATEMENTS.search(masked[a:b]):
                    take_value(a, b, why, array)
        else:
            for b in if_chain(fi, blk):
                if not STATEMENTS.search(top_text(fi, b)):
                    take_value(b.open + 1, b.close, why, array)

    def first_unlabeled(open_paren, why, array=False, typed=False):
        args = call_args(masked, open_paren)
        if args and args[0][0] is None:
            if array:
                take_array(args[0][1], args[0][2], why, typed)
            else:
                take(args[0][1], args[0][2], why, typed)

    def labeled(open_paren, wanted, why, typed=False):
        for label, a, b in call_args(masked, open_paren):
            if label == wanted:
                take(a, b, why, typed)

    for m in re.finditer(r"(?<![\w.])(" + "|".join(VIEW_CALLS) + r")(?:\.init)?\s*\(", masked):
        first_unlabeled(m.end() - 1, m.group(1))
    for m in re.finditer(r"\.(" + "|".join(MODIFIERS) + r")\s*\(", masked):
        first_unlabeled(m.end() - 1, "." + m.group(1), array=m.group(1) == "accessibilityInputLabels")
    for m in re.finditer(r"(?<![\w.])(LocalizedStringKey|LocalizedStringResource|NSLocalizedString)(?:\.init)?\s*\(", masked):
        first_unlabeled(m.end() - 1, m.group(1), typed=True)
    for m in re.finditer(r"(?<![\w.])(?:String|AttributedString)(?:\.init)?\s*\(", masked):
        labeled(m.end() - 1, "localized", "String(localized:)", typed=True)
    for m in re.finditer(r"\.searchable\s*\(", masked):
        labeled(m.end() - 1, "prompt", ".searchable(prompt:)")
    for m in re.finditer(r"\.accessibilityAction\s*\(", masked):
        labeled(m.end() - 1, "named", ".accessibilityAction(named:)")
    # a cast anywhere: `"..." as LocalizedStringKey`, `(c ? "A" : "B") as LocalizedStringKey`
    for m in re.finditer(r'([")])\s*as\s+' + LOC_TYPES + r"\b", masked):
        if m.group(1) == '"':
            lit = next((l for l in fi.lits if l.end == m.start() + 1), None)
            if lit:
                keep([lit], "cast")
        else:
            o = balanced_start(masked, m.start())
            before = masked[max(0, o - 80):o].rstrip() if o > 0 else ""
            call = before and (before[-1].isalnum() or before[-1] in "_)]>" or masked[o - 1] in "?!") and not \
                re.search(r"(?<![\w.])(?:return|in|throw|try|await|else|case|where|is|as|some|any|if|guard|while|switch|do|repeat)$", before)
            if o >= 0 and not call:
                take(o + 1, m.start(), "cast", True)   # `(c ? "A" : "B") as ...`, not `f(...) as ...`
    # declared / parameter default: `x: LocalizedStringKey = "..."`, `xs: [LocalizedStringResource] = [...]`
    for m in re.finditer(r":\s*(\[\s*)?" + LOC_TYPES + r"\s*(\])?\??\s*=(?!=)\s*", masked):
        p = m.end()
        if m.group(1):
            take_value(p, len(masked), "typed array", True,
                       end=lambda s, a: balanced_end(s, a) + 1 if s[a:a + 1] == "[" else typed_end(s, a))
        else:
            take_value(p, len(masked), "typed literal", end=typed_end)
    # assigned later: `title = "..."` / `self.title = "..."` where the declaration in scope is
    # typed LocalizedStringKey & co. (not a `let` / `var` / `case` statement)
    for m in re.finditer(r"(?<![\w.])(self[?!]?\.)?([A-Za-z_]\w*)\s*=(?!=)\s*", masked):
        ls = masked.rfind("\n", 0, m.start()) + 1
        line = masked[ls:m.start()]
        mk = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+|(?:private|fileprivate|public|internal|static|final|lazy"
                      r"|weak|unowned|override|nonisolated)\s+)*(case|let|var)\b", line)
        if mk and not re.search(r"[{;]", line[mk.end():]):
            if not (mk.group(1) == "case" and label_end(masked, ls + mk.end(), m.start()) is not None):
                continue                  # a declaration / enum case, not `case .x: title = "..."`
        d = types.resolve(m.group(2), fi, m.start(), "self" if m.group(1) else "local")
        kind = param_kind(d.typ) if d is not None and d.typ else "other"
        if kind in ("loc", "array"):
            take_value(m.end(), len(masked), "assigned", kind == "array")
    # our own APIs: `name(...)`, `self.name(...)`, `Type.name(...)` (Type = the declaring type);
    # `x.name(...)` only for funcs declared in an extension (view modifiers), never os.Logger-like
    # names; implicit `.name(...)` never (SDK factories: .custom, .success, .system, ...)
    for name in callees.localizable:
        for m in re.finditer(r"(\.)?\b" + re.escape(name) + r"\s*\(", masked):
            if re.search(r"\b(?:func|init|case)\s*$", masked[max(0, m.start() - 6):m.start()]):
                continue
            form, base = "bare", None
            if m.group(1):
                left = masked[max(0, m.start() - 200):m.start()].rstrip()
                # a receiver ends the text before the dot: `x`, `)`, `]`, `}`, `"`, or a postfix ?/!
                # glued to one (`center?` + line break + `.name(`); `c ? .name(` is a ternary
                if not left or not (left[-1].isalnum() or left[-1] in "_)]}\"`" or re.search(r"[\w)\]}\"`][?!]+$", left)) or re.search(
                        r"(?<![\w.])(?:return|in|throw|try[?!]?|await|else|case|where|is|as|some|any|if|guard"
                        r"|while|switch|do|repeat)$", left):
                    continue               # implicit member: its type is the context's
                mr = re.search(r"(?<![\w.)\]])((?:[A-Za-z_]\w*[?!]?\.)*[A-Za-z_]\w*[?!]?)$",
                               masked[max(0, m.start() - 120):m.start()])
                parts = [x.rstrip("?!") for x in mr.group(1).split(".")] if mr else []
                if parts == ["self"]:
                    form = "self"          # self.name(...), self?.name(...)
                elif parts and parts[0] == "Self" and all(x[:1].isupper() for x in parts[1:]):
                    chain = fi.type_chain(m.start())
                    form, base = "type", parts[-1] if len(parts) > 1 else (chain[0] if chain else None)
                elif parts and all(x[:1].isupper() for x in parts):
                    form, base = "type", parts[-1]   # Type.name(...), Outer.Inner.name(...)
                else:
                    form = "member"
            labels = callees.labels_for(name, fi, m.start(), form, base)
            if not labels:
                continue
            for idx, (label, a, b) in enumerate(call_args(masked, m.end() - 1)):
                kind = labels.get(label if label is not None else "_%d" % idx)
                if kind == "loc":
                    take(a, b, name + "(" + (label or "_") + ":)", True)
                elif kind == "array":
                    take_array(a, b, name + "(" + (label or "_") + ":)")
    # returned: `var t: LocalizedStringKey { ... }`, `func t() -> [LocalizedStringKey] { ... }`, its
    # `get { ... }`: the single-expression body (if / switch expressions too) and every `return`
    for m in re.finditer(r"(?::|->)\s*(\[\s*)?" + LOC_TYPES + r"\s*(\])?\??\s*\{", masked):
        body = fi.next_block(m.end() - 2)
        if body is None or body.open != m.end() - 1:
            continue
        array = bool(m.group(1))
        bodies = [body] + [b for b in fi.blocks if body.open < b.open < body.close and not b.inline
                           and re.search(r"\bget\s*$", b.head) and fi.innermost(b.open) is body]
        for blk in bodies:
            if not STATEMENTS.search(top_text(fi, blk)):
                take_value(blk.open + 1, blk.close, "returned", array)   # single-expression body
            for r in re.finditer(r"\breturn\b", masked[blk.open + 1:blk.close]):
                p = blk.open + 1 + r.end()
                if returns_to(fi, p, blk):
                    take_value(p, blk.close, "returned", array)
    return list(hits.values())


def balanced_start(s, i):
    """Index of the bracket opening the one closed at s[i], or -1."""
    depth = 0
    for k in range(i, -1, -1):
        depth += s[k] in ")]}"
        depth -= s[k] in "([{"
        if depth == 0:
            return k
    return -1


def top_text(fi, blk):
    """The block's own text, nested blocks blanked."""
    t = list(fi.masked[blk.open + 1:blk.close])
    for b in fi.blocks:
        if blk.open < b.open and b.close < blk.close:
            for i in range(b.open - blk.open - 1, b.close - blk.open):
                t[i] = " "
    return "".join(t)


def if_chain(fi, blk):
    """The branch blocks of `if c { } else if d { } else { }`, from the first one."""
    out = [blk]
    while True:
        m = re.compile(r"\s*else\b").match(fi.masked, blk.close + 1)
        if not m:
            return out
        blk = fi.next_block(m.end() - 1)
        if blk is None:
            return out
        out.append(blk)


def label_end(masked, p, b):
    """After `case`: the position right after its `:` (bracket depth 0), or None when this is not
    a label (`if case .x = y {`)."""
    k, depth = p, 0
    while k < b:
        c = masked[k]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "{" and depth > 0:      # `where xs.contains(where: { ... }):`
            depth += 1
        elif c == "}" and depth > 0:
            depth -= 1
        elif c in "{}" or (depth == 0 and c == "=" and masked[k + 1:k + 2] != "=" and masked[k - 1:k] not in "=!<>"):
            return None
        elif c == ":" and depth == 0:
            return k + 1
        k += 1
    return None


def case_values(fi, sw):
    """(start, end) of each case's value inside a `switch` block (labels start a statement, so
    `counts[kind, default: 0]` is not one)."""
    masked, labels, top = fi.masked, [], top_text(fi, sw)
    for r in re.finditer(r"(?<![.`])\bdefault\s*:|\bcase\b", masked[sw.open + 1:sw.close]):
        s = sw.open + 1 + r.start()
        if r.group(0) == "case" and re.search(r"\bfor(?:\s+try)?(?:\s+await)?\s+$", masked[max(0, s - 40):s]):
            continue                      # `for case` / `for try await case` loops
        seg = top[:s - sw.open - 1]
        if fi.innermost(s) is not sw or sum(map(seg.count, "([")) != sum(map(seg.count, ")]")):
            continue                      # inside ( or [: `counts[kind, default: 0]`, `f(\n default: x)`
        e = label_end(masked, sw.open + 1 + r.end(), sw.close) if r.group(0) == "case" else sw.open + 1 + r.end()
        if e is not None:
            labels.append((s, e))
    return [(e, labels[i + 1][0] if i + 1 < len(labels) else sw.close) for i, (s, e) in enumerate(labels)]


def returns_to(fi, pos, body):
    """True when pos sits directly in body, or only inside if / switch / ... blocks of it
    (a `return` in a closure or a nested func returns from that one)."""
    for b in fi.blocks:
        if body.open < b.open < pos < b.close and not b.flow:
            return False
    return True


# ---------------------------------------------------------------- interpolation types

FLOATS = ("Double", "Float", "CGFloat", "TimeInterval", "Float80", "Float16")


def type_kind(t):
    t = re.sub(r"[?!]+$", "", (t or "").strip())
    if t in ("Int", "Int64"):
        return "lld"
    if t in ("String", "Substring", "Text", "Date", "URL", "AttributedString", "Image",
             "LocalizedStringKey", "LocalizedStringResource"):
        return "@"
    if t in FLOATS or t in ("Int32", "Int16", "Int8", "UInt", "UInt64", "UInt32", "UInt16",
                           "UInt8", "Bool"):
        return "?" + t  # Swift gives these other specifiers (%d, %llu, %lf, ...): unsupported
    return None


def blank_literals(e):
    return re.sub(r'"(?:\\.|[^"\\])*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', e)


CONTINUES = re.compile(r"\s*\n\s*(?:\.|\?|:|\+|-|\*|/|&&|\|\||==|!=|<|>)")


def init_expr(fi, start, end):
    """The initializer text of a declaration, or None when it goes on to the next line."""
    text = fi.nocomment[start:end]
    if CONTINUES.match(fi.masked, end) or re.search(r"(?:[=+\-*/?:(\[,]|&&|\|\|)\s*$", fi.masked[start:end]):
        return None
    return cut_expr(text) or None


def cut_expr(e):
    """`a, let b = c {` / `x else {` -> the first expression only (if / guard let). A `{ ... }`
    followed by `.member` is a trailing closure and stays (`xs.filter { ... }.count`)."""
    s, depth, k = blank_literals(e), 0, 0
    while k < len(s):
        c = s[k]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth == 0 and (c == "," or s.startswith(" else", k)):
            return e[:k].strip()
        elif depth == 0 and c == "{":
            end = balanced_end(s, k)
            if end < 0 or not re.match(r"\s*[?!]?\.", s[end + 1:]):
                return e[:k].strip()
            k = end
        k += 1
    return e.strip()


class Decl:
    __slots__ = ("name", "fi", "off", "typ", "init", "scope", "prop", "lo", "hi")

    def __init__(self, name, fi, off, typ, init, scope, prop, lo=None, hi=None):
        self.name, self.fi, self.off, self.typ, self.init = name, fi, off, typ, init
        self.scope, self.prop = scope, prop
        self.lo = scope.open if lo is None and scope is not None else lo
        self.hi = scope.close if hi is None and scope is not None else hi


def scope_of(fi, d):
    """(block, lo, hi) where a declaration at d is visible: the if / while body for its
    condition bindings, its own case inside a switch, else the innermost block."""
    m = fi.masked
    ls = m.rfind("\n", 0, d) + 1
    prefix = m[ls:d]
    while ls > 0:                          # a condition list going on from earlier lines: `if a,\n let b`
        pl = m.rfind("\n", 0, ls - 1) + 1
        if not m[pl:ls - 1].rstrip().endswith(","):
            break
        prefix, ls = m[pl:ls - 1] + "\n" + prefix, pl
    # `if let x` (no `{` after the keyword: `if flag { let x }` is a local of the if body)
    if re.search(r"(?<!#)\b(?:if|while)\b[^{}]*$", prefix) and not re.search(r"\bguard\b[^{}]*$", prefix):
        b = fi.next_block(d)
        return b, None, None
    b = fi.innermost(d)
    if b is not None and not b.type_name and re.search(r"\bswitch\b", b.head):
        vals = case_values(fi, b)
        for i, (lo, hi) in enumerate(vals):
            if lo <= d < hi:
                return b, lo, hi
            if d < lo and (i == 0 or d >= vals[i - 1][1]):
                return b, d, hi           # a pattern binding in this case's label: this case only
    return b, None, None


class Types:
    def __init__(self, files):
        self.files = files
        self.decls = {}   # name -> [Decl]
        self.funcs = {}   # name -> [(external labels, kind of the declared return type)]
        decl_re = re.compile(r"\b(let|var)\s+([A-Za-z_]\w*)\s*(?::\s*(" + TYPE_RE + r"))?\s*(?:=(?=([^\n;]*)))?")
        param_re = re.compile(r"[(,]\s*(?:([A-Za-z_]\w*)\s+)?([A-Za-z_]\w*)\s*:\s*(?:inout\s+)?(?:@\w+\s+)*(" + TYPE_RE + r")")
        for fi in files.values():
            masked = fi.masked
            for m in decl_re.finditer(masked):
                d = m.start()
                prefix = masked[masked.rfind("\n", 0, d) + 1:d]
                scope, lo, hi = scope_of(fi, d)
                typ, init = m.group(3), None
                if re.search(r"\b(?:case|catch)\b", prefix) or re.search(r"\(\s*$", prefix):
                    typ = None                          # pattern binding: type unknown
                elif m.group(4) is not None:
                    init = init_expr(fi, m.start(4), m.end(4))
                prop = bool(scope and scope.type_name and fi.innermost(d) is scope)
                self.add(Decl(m.group(2), fi, d, typ, init, scope, prop, lo, hi))
                if re.search(r"\b(?:if|while|guard|case|for)\b", prefix):
                    continue
                eol = masked.find("\n", m.end())
                eol = len(masked) if eol < 0 else eol
                depth, k = 0, m.end()
                while k < eol:                          # `var a = 0, b: String = ""`
                    c = masked[k]
                    if c in "([{":
                        depth += 1
                    elif c in ")]}":
                        depth -= 1
                    elif c == "," and depth == 0:
                        mc = re.compile(r"\s*([A-Za-z_]\w*)\s*(?::\s*(" + TYPE_RE + r"))?\s*(=(?!=))?").match(masked, k + 1)
                        if mc and (mc.group(2) or mc.group(3)) and mc.group(1) not in ("let", "var", "case"):
                            self.add(Decl(mc.group(1), fi, k + 1, mc.group(2), None, scope, prop, lo, hi))
                    k += 1
            for m in re.finditer(r"\b(?:let|var)\s*\(([^()]*)\)", masked):   # let (a, b) = ...
                scope, lo, hi = scope_of(fi, m.start())
                for name in re.findall(r"[A-Za-z_]\w*", m.group(1)):
                    if name not in ("let", "var", "_"):
                        self.add(Decl(name, fi, m.start(), None, None, scope, False, lo, hi))
            for m in re.finditer(r"\bcase\s+(?:let|var)\s+([^:={]*)", masked):  # case let .x(title)
                scope, lo, hi = scope_of(fi, m.start())
                for name in re.findall(r"(?<![\w.])([a-z_]\w*)", m.group(1)):
                    if name not in ("let", "var", "_", "where", "is", "as"):
                        self.add(Decl(name, fi, m.start(), None, None, scope, False, lo, hi))
            for m in re.finditer(r"\b(?:func\s+(\w+)|(?<!\.)init[?!]?)\s*(?:<[^>]*>)?\s*\(", masked):
                q = m.end() - 1
                e = balanced_end(masked, q)
                if e < 0:
                    continue
                body = fi.next_block(e)
                between = masked[e + 1:body.open] if body else ""
                if body is None or re.search(r"\b(?:func|var|let|init|case)\b|[;}]", between):
                    body = None                         # no body (protocol requirement)
                labels = []
                for pm in param_re.finditer(masked[q:e + 1]):
                    labels.append(pm.group(1) or pm.group(2))
                    if body:
                        self.add(Decl(pm.group(2), fi, q + pm.start(2), pm.group(3), None, body, False))
                mr = re.match(r"\s*(?:async\s+)?(?:throws\s+|rethrows\s+)?->\s*(" + TYPE_RE + ")", masked[e + 1:e + 200])
                if m.group(1) and mr:
                    self.funcs.setdefault(m.group(1), []).append((tuple(labels), type_kind(mr.group(1))))
            for m in re.finditer(r"\bfor\s+(?:case\s+)?(?:let\s+|var\s+)?(\(?[\w\s,]*?\)?)\s+in\s+([^{]*)\{", masked):
                body = fi.next_block(m.end() - 2)
                if body is None:
                    continue
                ints = bool(re.match(r"\s*-?\d+\s*\.\.[.<]", m.group(2)))
                for name in re.findall(r"[A-Za-z_]\w*", m.group(1)):
                    self.add(Decl(name, fi, body.open, "Int" if ints and "," not in m.group(1) else None,
                                  None, body, False))
            for blk in fi.blocks:                       # closure parameters: `{ x in`, `{ (a, b) in`
                mc = CLOSURE_PARAMS.match(masked, blk.open + 1)
                if not mc or "\n\n" in mc.group(0):
                    continue
                inner = mc.group(1).strip("()")
                for piece in inner.split(","):
                    mp = re.match(r"\s*([A-Za-z_]\w*)\s*(?::\s*(" + TYPE_RE + r"))?", piece)
                    if mp and mp.group(1) != "_":
                        self.add(Decl(mp.group(1), fi, blk.open, mp.group(2), None, blk, False))

    def add(self, d):
        if d.scope is not None:
            self.decls.setdefault(d.name, []).append(d)

    def infer(self, expr, fi, pos, trace, depth=0):
        e = expr.strip()
        if e in TYPE_HINTS:
            return TYPE_HINTS[e]
        if depth > 6 or not e:
            return None
        s = blank_literals(e)
        while s.startswith("(") and balanced_end(s, 0) == len(s) - 1:
            e, s = e[1:-1].strip(), s[1:-1].strip()
        ops = top_operators(s)
        if "?" in ops and ":" in ops:      # ternary
            ka = self.infer(e[ops["?"] + 1:ops[":"]], fi, pos, trace, depth + 1)
            kb = self.infer(e[ops[":"] + 1:], fi, pos, trace, depth + 1)
            return ka if ka == kb else None
        if "??" in ops:
            k = ops["??"]
            right = self.infer(e[k + 2:], fi, pos, trace, depth + 1)
            return right if right is not None else self.infer(e[:k], fi, pos, trace, depth + 1)
        if "bin" in ops:                   # a + b, n - 1, area / 2, ...
            ks = {self.infer(e[a:b], fi, pos, trace, depth + 1) for a, b in ops["bin"]} - {None}
            floats = {k for k in ks if k[1:] in FLOATS}
            if floats:
                return floats.pop() if len(floats) == 1 else None
            return ks.pop() if len(ks) == 1 else None
        if re.fullmatch(r"-?\d[\d_]*", e):
            return "lld"
        if re.fullmatch(r"-?\d[\d_]*\.\d[\d_]*", e):
            return "?Double"
        if e[:1] == '"' or e[:2] == '#"':
            return "@"
        if e in ("true", "false"):
            return "?Bool"
        return self.chain(s, fi, pos, trace, depth)

    def chain(self, s, fi, pos, trace, depth):
        """Postfix chain: base(.member | (args) | [index] | { closure } | ? | !)*: kind of its end."""
        m = re.match(r"[A-Za-z_]\w*", s)
        if not m:
            return None
        links, k = [("name", m.group(0))], m.end()
        while k < len(s):
            c = s[k]
            if c in "?!":
                k += 1
            elif c == "." and re.match(r"\.[A-Za-z_]\w*", s[k:]):
                mm = re.match(r"\.([A-Za-z_]\w*)", s[k:])
                links.append(("member", mm.group(1)))
                k += mm.end()
            elif c in "([{":
                end = balanced_end(s, k)
                if end < 0:
                    return None
                if c == "[":
                    links.append(("index", None))
                elif c == "(" or links[-1][0] != "call":
                    links.append(("call", s[k:end + 1] if c == "(" else "()"))
                k = end + 1                # `f(x) { ... }`: the closure belongs to that call
            elif c == " " and re.match(r"\s*(?:\{|[?!]?\.)", s[k:]):
                k += 1                     # `xs.filter { ... }`, a chain broken by a space
            else:
                return None                # not a plain chain
        kind, value = links[-1]
        base = links[0][1]
        if kind == "index":
            return None
        if kind == "call":
            callee = links[-2][1]
            if len(links) == 2 and callee[:1].isupper():
                return type_kind(callee)   # Int(x), String(format:), SomeType(...) -> None
            if len(links) > 2 and callee in ("formatted", "uppercased", "lowercased", "trimmingCharacters",
                                             "joined", "replacingOccurrences", "capitalized"):
                return "@"
            if len(links) == 2 or base in ("self", "Self") or base[:1].isupper():
                labels = call_labels(value)
                cands = self.funcs.get(callee, [])
                ks = {kd for lb, kd in cands if lb[:len(labels)] == labels} - {None}
                return ks.pop() if len(ks) == 1 else None
            return None                    # x.method(): x's type unknown
        if kind == "member":
            if len(links) == 2 and base in ("self", "Self"):
                return self.lookup(value, fi, pos, trace, depth, "self")
            if len(links) == 2 and base[:1].isupper():
                return self.lookup(value, fi, pos, trace, depth, "type", base)
            builtin = {"count": "lld", "endIndex": "lld", "startIndex": "lld",
                       "description": "@", "localizedDescription": "@"}.get(value)
            if builtin:                    # unless a property of ours with that name says otherwise
                ours = {self.decl_kind(d, depth, []) for d in self.decls.get(value, []) if d.prop} - {None}
                return builtin if ours <= {builtin} else None
            return None                    # x.member: x's type unknown
        return self.lookup(value, fi, pos, trace, depth, "local")

    def resolve(self, name, fi, pos, mode):
        """The declaration `name` means at pos. local: the innermost one in scope (locals,
        parameters, closure / loop variables declared before pos; properties of an enclosing
        type). self: a property of the enclosing type."""
        types_here = [b for b in fi.blocks if b.type_name and b.open < pos < b.close]
        tblk = max(types_here, key=lambda b: b.open) if types_here else None
        cands = [d for d in self.decls.get(name, []) if d.fi is fi and d.lo < pos < d.hi
                 and (d.prop or d.off < pos) and (mode == "local" or d.prop)
                 and (not d.prop or d.scope is tblk)]   # an outer type's instance property is not visible
        if cands:
            return max(cands, key=lambda d: (d.lo, d.off))
        if tblk is not None:                  # declared in the type's body elsewhere (extensions)
            props = [d for d in self.decls.get(name, []) if d.prop and d.scope.type_name == tblk.type_name]
            if len(props) == 1:
                return props[0]
        return None

    def lookup(self, name, fi, pos, trace, depth, mode, type_name=None):
        """local / self: see resolve(). type: a static property of TypeName (any file)."""
        if mode == "type":
            ks = {self.decl_kind(d, depth, trace) for d in self.decls.get(name, [])
                  if d.prop and d.scope.type_name == type_name} - {None}
            return ks.pop() if len(ks) == 1 else None
        d = self.resolve(name, fi, pos, mode)
        return self.decl_kind(d, depth, trace) if d else None

    def decl_kind(self, d, depth, trace):
        trace.append(f"{d.name} at {d.fi.rel}:{d.fi.line_of(d.off)}")
        if d.typ:
            return type_kind(d.typ)
        if d.init:
            return self.infer(d.init, d.fi, d.off, trace, depth + 1)
        return None


def call_labels(args_text):
    """External labels of a call's arguments, '_' when unlabeled: '(ofProject: x, 3)' -> ('ofProject', '_')."""
    inner, pieces, depth, last = args_text[1:-1], [], 0, 0
    for k, c in enumerate(inner):
        depth += c in "([{"
        depth -= c in ")]}"
        if c == "," and depth == 0:
            pieces.append(inner[last:k])
            last = k + 1
    pieces.append(inner[last:])
    out = []
    for piece in pieces:
        if piece.strip():
            m = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", piece)
            out.append(m.group(1) if m else "_")
    return tuple(out)


def top_operators(s):
    """Top-level '?' / ':' of a ternary, '??', and the operand ranges of spaced + - * / ."""
    out, depth, k, cuts = {}, 0, 0, []
    while k < len(s):
        c = s[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0:
            spaced = k > 0 and s[k - 1].isspace() and s[k + 1:k + 2].isspace()
            if s.startswith("??", k):
                out.setdefault("??", k)
                k += 2
                continue
            if is_ternary_q(s, k):
                out.setdefault("?", k)
            elif c == ":" and "?" in out and ":" not in out:
                out[":"] = k
            elif c in "+-*/" and spaced:
                cuts.append(k)
        k += 1
    if cuts:
        bounds = [-1] + cuts + [len(s)]
        out["bin"] = [(bounds[i] + 1, bounds[i + 1]) for i in range(len(bounds) - 1)]
    return out


# ---------------------------------------------------------------- main

def has_letter(s):
    return any(unicodedata.category(ch).startswith("L") for ch in s)


def main():
    files, errors = {}, []
    for dp, dn, fn in os.walk(SRC):
        dn.sort()
        for name in sorted(fn):
            if not name.endswith(".swift"):
                continue
            p = os.path.join(dp, name)
            rel = os.path.relpath(p, ROOT).replace(os.sep, "/")
            try:
                files[rel] = FileInfo(rel, open(p, encoding="utf-8").read())
            except SwiftSyntax as e:
                errors.append(f"{rel}: cannot read it ({e}) - extend tools/check_l10n_keys.py")
    store = json.load(open(os.path.join(ROOT, "Localization", "translations.json"), encoding="utf-8"))
    keys = {k["key"] for k in store["keys"]}
    by_shape = {}
    for k in keys:
        by_shape.setdefault(key_shape(k), []).append(k)

    callees = Callees(files)
    types = Types(files)
    used, checked, allowed, report = set(), 0, 0, []
    for rel, fi in files.items():
        for lit, why in sorted(localizable_literals(fi, callees, types), key=lambda h: h[0].start):
            text = "".join(p for p in lit.parts if not isinstance(p, tuple))
            where = f"{rel}:{lit.line}"
            if not has_letter(text):
                continue
            if not lit.interps and lit.key([]) in ALLOW:
                allowed += 1
                continue
            checked += 1
            kinds, traces = [], []
            for code, off in lit.interps:
                trace = []
                kinds.append(types.infer(code, fi, off, trace))
                traces.append(trace)
            report.append((where, why, lit, kinds))
            bad = [(code, k, t) for (code, _), k, t in zip(lit.interps, kinds, traces) if k and k[0] == "?"]
            for code, k, t in bad:
                src = f" (from {t[0]})" if t else ""
                errors.append(f"{where}: \\({code}) is a {k[1:]}{src}: Swift builds a %lf / %d / %llu key, "
                              f"which translations.json cannot hold. Interpolate a String (e.g. .formatted()) "
                              f"or an Int; if the type is wrong, wrap it: \\(String(...)) [{why}]")
            if bad:
                continue
            if not lit.interps:
                cands = [lit.key([])] if lit.key([]) in keys else []
            else:
                cands = by_shape.get(lit.shape(), [])
            ok = [c for c in cands if all(k in (None, sp) for k, sp in zip(kinds, SPEC.findall(c)))]
            if ok:
                used.update(ok)
                continue
            want = lit.key([k or "@" for k in kinds])
            unknown = [code for (code, _), k in zip(lit.interps, kinds) if k is None]
            hint = f" (type of {', '.join(unknown)} unknown: %lld if Int)" if unknown else ""
            if cands:
                sure = "; ".join(f"\\({code}) = {'Int' if k == 'lld' else 'String'}"
                                 + (f" from {t[0]}" if t else "")
                                 for (code, _), k, t in zip(lit.interps, kinds, traces) if k)
                errors.append(f"{where}: key {cands[0]!r} has the wrong specifier: Swift looks up {want!r} "
                              f"({sure}). If that type is wrong, wrap it: \\(String(x)) / \\(Int(x)) [{why}]")
            else:
                errors.append(f"{where}: not in translations.json: {want!r}{hint} [{why}]")
    if "--dump" in sys.argv:
        for where, why, lit, kinds in report:
            text = "".join(chr(0xE000) if isinstance(p, tuple) else p for p in lit.parts)
            print("LIT", where, why, repr(text), kinds)
    unused = sorted(keys - used)
    print(f"check_l10n_keys: {checked} localizable literals checked, {allowed} allowed English, "
          f"{len(keys)} keys, {len(unused)} not used by a Swift literal" + (":" if unused else "."))
    for k in unused:
        print("   ", repr(k)[:110])
    if errors:
        for e in errors:
            print("::error::" + e)
        print(f"{len(errors)} problem(s). Fix: add the key + its 7 translations to Localization/translations.json, "
              "run python tools/build_xcstrings.py and commit Localization/. Deliberate English: "
              "Text(verbatim:) or ALLOW in tools/check_l10n_keys.py.")
        sys.exit(1)


if __name__ == "__main__":
    main()
