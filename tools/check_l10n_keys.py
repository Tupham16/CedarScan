# Fails when a customer-facing Swift string literal has no key in Localization/translations.json:
# Swift looks the key up at run time, finds nothing and shows the English text in all 7 other
# languages, with CI green. build.yml runs this right after the String Catalog check.
#
#   python tools/check_l10n_keys.py          (exit 1 + one ::error:: line per problem)
#
# Customer-facing = a literal that Swift turns into a localization key:
#   - String(localized: "..."), AttributedString(localized: "..."), LocalizedStringKey("..."),
#     LocalizedStringResource("..."), NSLocalizedString("..."), and a literal typed
#     LocalizedStringKey / LocalizedStringResource / String.LocalizationValue (also in an array);
#   - the first unlabeled argument of the SwiftUI views / modifiers in VIEW_CALLS / MODIFIERS
#     (Text, Button, Label, Toggle, Picker, TextField, Section, .navigationTitle, .alert, ...),
#     `prompt:` of .searchable, `named:` of .accessibilityAction, and parameters of our own funcs /
#     inits / memberwise inits declared with one of the three types above. A String VARIABLE in
#     those places is shown verbatim, so only literals count; both literals of `c ? "A" : "B"` do.
# Exempt: Text(verbatim:), comments, literals without a letter (emoji, "$\(price)", "\(n)%",
#   "000000"), and ALLOW below (deliberate English: brand, domain).
# Key = the literal with each \(x) replaced by %lld (Int) or %@ (String, Text, Date, ...), as Swift
#   builds it. The type of x is inferred from its declaration (heuristic: the nearest declaration
#   in the file, else every declaration of that name in Sources must agree; TYPE_HINTS overrides).
#   A key whose specifier contradicts an inferred type fails; a type it cannot infer is accepted.
#   The key store only knows %@ and %lld (tools/build_xcstrings.py), so a Double / Float / Bool /
#   Int32 interpolation fails until both tools learn its specifier.
# Keys no Swift literal uses are listed, not failed (e.g. a key kept for an old build).
# Validated 20/10/2026 against the compiler's own extraction (SWIFT_EMIT_LOC_STRINGS, Xcode 26.3).
import json, os, re, sys, unicodedata

sys.stdout.reconfigure(encoding="utf-8")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
    "Tab", "Gauge",
]
MODIFIERS = [
    "navigationTitle", "navigationSubtitle", "navigationBarTitle", "alert", "confirmationDialog",
    "help", "badge", "accessibilityLabel", "accessibilityHint", "accessibilityValue",
]
LOC_TYPES = r"(?:LocalizedStringKey|LocalizedStringResource|String\.LocalizationValue)"
TYPE_RE = r"[A-Za-z_][\w.<>?!]*"
SPEC = re.compile(r"%(@|lld)")
INTERP = "\ue000"            # one interpolation inside a decoded literal
NL, CONT = "\ue001", "\ue002"  # escaped newline / line continuation (multi-line literals)


class SwiftSyntax(Exception):
    pass


class Lit:
    def __init__(self, start, end, parts, line):
        self.start, self.end, self.parts, self.line = start, end, parts, line

    @property
    def interps(self):
        return [p for p in self.parts if isinstance(p, tuple)]

    def text(self, specs=None):
        """INTERP-marked text, or (specs given) the format key Swift builds."""
        out, k = [], 0
        for p in self.parts:
            if isinstance(p, tuple):
                out.append("%" + specs[k] if specs else INTERP)
                k += 1
            else:
                out.append(p.replace("%", "%%") if specs else p)
        return "".join(out)


# ---------------------------------------------------------------- lexer
# masked    = the file with comments AND string literals blanked, except interpolation code
# nocomment = the file with comments blanked (literals kept)
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
    if multiline:
        nl = src.find("\n", j)
        if nl < 0 or src[j:nl].strip():
            raise SwiftSyntax('text after an opening """')
        j = nl + 1
    raw, interps, code_ranges = [], [], []
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
                raw.append(INTERP)
                j = b + 1
                continue
            if ch == "u":
                mu = UNI_RE.match(src, k)
                if not mu:
                    raise SwiftSyntax("bad \\u escape")
                raw.append(chr(int(mu.group(1), 16)))
                j = mu.end()
                continue
            if multiline and CONT_RE.match(src, k):
                raw.append(CONT)  # `\` at the end of a line: no line break there
                j = k
                continue
            if ch not in SIMPLE_ESC:
                raise SwiftSyntax("unknown escape \\" + ch)
            raw.append(NL if ch == "n" and multiline else SIMPLE_ESC[ch])
            j = k + 1
            continue
        if src[j] == "\n" and not multiline:
            raise SwiftSyntax("line break in a one-line string literal")
        raw.append(src[j])
        j += 1
    end = j + len(close)
    text = "".join(raw)
    if multiline:
        lines = text.split("\n")
        indent = lines[-1]
        if indent.strip():
            raise SwiftSyntax('closing """ must be on its own line')
        out = []
        for ln in lines[:-1]:
            if ln.startswith(indent):
                out.append(ln[len(indent):])
            elif ln.strip() == "":
                out.append("")
            else:
                raise SwiftSyntax("a line of a multi-line literal is less indented than its closing quotes")
        text = re.sub(CONT + r"[ \t]*\n", "", "\n".join(out)).replace(CONT, "").replace(NL, "\n")
    parts, buf, k = [], [], 0
    for ch in text:
        if ch == INTERP:
            if buf:
                parts.append("".join(buf))
                buf = []
            parts.append(interps[k])
            k += 1
        else:
            buf.append(ch)
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


def literals_of_arg(masked, lits_by_start, a, b):
    """The literals that ARE the expression [a, b): one literal, or both of `c ? "A" : "B"`."""
    top, k = [], a
    while k < b:
        lit = lits_by_start.get(k)
        if lit:
            top.append(lit)
            k = lit.end
        else:
            k += 1
    if not top:
        return []
    tpl, k = [], a
    for lit in top:
        tpl.append(masked[k:lit.start])
        tpl.append("\x01")
        k = lit.end
    tpl.append(masked[k:b])
    tpl = "".join(tpl)
    if re.fullmatch(r"\s*\x01\s*", tpl):
        return top
    if len(top) == 2 and re.fullmatch(r"[^\x01]+\s\?\s*\x01\s*:\s*\x01\s*", tpl, re.S):
        return top
    return []


def enclosing_type(masked, pos):
    """Name of the innermost struct / class / enum / extension / actor around pos."""
    depth, k = 0, pos
    while k > 0:
        k -= 1
        c = masked[k]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth:
                depth -= 1
                continue
            m = re.search(r"\b(?:struct|class|enum|extension|actor)\s+([A-Za-z_][\w.]*)[^{};]*$",
                          masked[max(0, k - 300):k])
            if m:
                return m.group(1).split(".")[-1]
    return None


def custom_callees(files):
    """Our own funcs / inits / memberwise inits with a parameter of a localizable type:
    callee name -> set of argument labels ('_' = the first, unlabeled, argument)."""
    found = {}
    for f in files.values():
        masked = f["masked"]
        for m in re.finditer(r"\b(?:func\s+([A-Za-z_]\w*)|init)\s*(?:<[^>]*>)?\s*\(", masked):
            name = m.group(1) or enclosing_type(masked, m.start())
            if not name:
                continue
            for label, a, b in call_args(masked, m.end() - 1):
                if label is not None:   # `name: Type` (external label = name)
                    if re.match(r"\s*" + LOC_TYPES + r"\b", masked[a:b]):
                        found.setdefault(name, set()).add(label)
                    continue
                mp = re.match(r"\s*(\w+)\s+\w+\s*:\s*" + LOC_TYPES + r"\b", masked[a:b])
                if mp:                   # `ext name: Type` / `_ name: Type`
                    found.setdefault(name, set()).add(mp.group(1))
        for m in re.finditer(r"\b(?:let|var)\s+(\w+)\s*:\s*" + LOC_TYPES + r"[ \t]*(?:\n|;|$)", masked):
            t = enclosing_type(masked, m.start())
            if t:
                found.setdefault(t, set()).add(m.group(1))
    return found


def localizable_literals(f, customs):
    masked, lits = f["masked"], f["lits"]
    by_start = {l.start: l for l in lits}
    hits = {}

    def take(a, b, why):
        for lit in literals_of_arg(masked, by_start, a, b):
            hits.setdefault(lit.start, (lit, why))

    def labeled(open_paren, wanted, why):
        for label, a, b in call_args(masked, open_paren):
            if label == wanted:
                take(a, b, why)

    def first_unlabeled(open_paren, why):
        args = call_args(masked, open_paren)
        if args and args[0][0] is None:
            take(args[0][1], args[0][2], why)

    for m in re.finditer(r"(?<![\w.])(" + "|".join(VIEW_CALLS) + r")\s*\(", masked):
        first_unlabeled(m.end() - 1, m.group(1))
    for m in re.finditer(r"\.(" + "|".join(MODIFIERS) + r")\s*\(", masked):
        first_unlabeled(m.end() - 1, "." + m.group(1))
    for m in re.finditer(r"(?<![\w.])(LocalizedStringKey|LocalizedStringResource|NSLocalizedString)\s*\(", masked):
        first_unlabeled(m.end() - 1, m.group(1))
    for m in re.finditer(r"(?<![\w.])(?:String|AttributedString)\s*\(", masked):
        labeled(m.end() - 1, "localized", "String(localized:)")
    for m in re.finditer(r"\.searchable\s*\(", masked):
        labeled(m.end() - 1, "prompt", ".searchable(prompt:)")
    for m in re.finditer(r"\.accessibilityAction\s*\(", masked):
        labeled(m.end() - 1, "named", ".accessibilityAction(named:)")
    # `x: LocalizedStringKey = "..."`, `xs: [LocalizedStringResource] = ["...", ...]`
    for m in re.finditer(r":\s*(\[\s*)?" + LOC_TYPES + r"\s*(\])?\s*=\s*", masked):
        p = m.end()
        if not m.group(1):
            q = masked.find("\n", p)
            take(p, len(masked) if q < 0 else q, "typed literal")
            continue
        if masked[p:p + 1] != "[":
            continue
        k = p + 1
        while k < len(masked) and masked[k] != "]":
            e = arg_end(masked, k)
            take(k, e, "typed array")
            k = e + (masked[e:e + 1] == ",")
            if e < len(masked) and masked[e] in ")}":
                break
    for name, labels in customs.items():
        for m in re.finditer(r"(?<![\w.])" + re.escape(name) + r"\s*\(", masked):
            if re.search(r"\b(?:func|init)\s*$", masked[max(0, m.start() - 6):m.start()]):
                continue
            for idx, (label, a, b) in enumerate(call_args(masked, m.end() - 1)):
                if label in labels or (label is None and idx == 0 and "_" in labels):
                    take(a, b, name + "(" + (label or "_") + ":)")
    return list(hits.values())


# ---------------------------------------------------------------- interpolation types

def type_kind(t):
    t = re.sub(r"[?!]+$", "", t.strip())
    if t in ("Int", "Int64"):
        return "lld"
    if t in ("String", "Substring", "Text", "Date", "URL", "AttributedString", "Image",
             "LocalizedStringKey", "LocalizedStringResource"):
        return "@"
    if t in ("Int32", "Int16", "Int8", "UInt", "UInt64", "UInt32", "UInt16", "UInt8",
             "Double", "Float", "CGFloat", "TimeInterval", "Bool"):
        return "?" + t  # Swift gives these other specifiers (%d, %llu, %lf, ...): unsupported
    return None


def balanced_end(s, i):
    """Index of the bracket closing the one at s[i] (literals already blanked), or -1."""
    depth = 0
    for k in range(i, len(s)):
        depth += s[k] in "([{"
        depth -= s[k] in ")]}"
        if depth == 0:
            return k
    return -1


def blank_literals(e):
    return re.sub(r'"(?:\\.|[^"\\])*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', e)


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


TYPE_SCOPE = re.compile(r"\b(?:struct|class|enum|extension|actor|protocol)\s+"
                        r"(?!func\b|var\b|let\b|subscript\b|init\b|override\b|final\b)[A-Za-z_]")


def member_offsets(masked, offsets):
    """offset -> True when its innermost enclosing { } is a type body (a property, not a local)."""
    res, stack, boundary, oi = {}, [], 0, 0
    offs = sorted(set(offsets))
    for k, c in enumerate(masked):
        while oi < len(offs) and offs[oi] <= k:
            res[offs[oi]] = bool(stack) and stack[-1]
            oi += 1
        if c == "{":
            stack.append(bool(TYPE_SCOPE.search(masked[boundary:k])))
            boundary = k + 1
        elif c == "}":
            if stack:
                stack.pop()
            boundary = k + 1
    for o in offs[oi:]:
        res[o] = bool(stack) and stack[-1]
    return res


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


class Types:
    def __init__(self, files):
        # name -> [(path, offset, type or None, initializer or None, is_property)]
        self.decls = {}
        # func name -> [(external labels, kind of the declared return type)]
        self.funcs = {}
        # The initializer is read by a lookahead, so `let a = x, let b = y` yields both.
        decl_re = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*(" + TYPE_RE + r"))?\s*(?:=(?=([^\n;]*)))?")
        param_re = re.compile(r"[(,]\s*(?:([A-Za-z_]\w*)\s+)?([A-Za-z_]\w*)\s*:\s*(?:inout\s+)?(?:@\w+\s+)*(" + TYPE_RE + r")")
        for path, f in files.items():
            masked, nocomment = f["masked"], f["nocomment"]
            found = list(decl_re.finditer(masked))
            member = member_offsets(masked, [m.start() for m in found])
            for m in found:
                init = cut_expr(nocomment[m.start(3):m.end(3)]) if m.group(3) is not None else None
                self.decls.setdefault(m.group(1), []).append(
                    (path, m.start(), m.group(2), init or None, member[m.start()]))
            for m in re.finditer(r"\b(?:func\s+(\w+)|init)\s*(?:<[^>]*>)?\s*\(", masked):
                q = m.end() - 1
                e = balanced_end(masked, q)
                if e < 0:
                    continue
                labels = []
                for pm in param_re.finditer(masked[q:e + 1]):
                    self.decls.setdefault(pm.group(2), []).append((path, q + pm.start(2), pm.group(3), None, False))
                    labels.append(pm.group(1) or pm.group(2))
                mr = re.match(r"\s*(?:async\s+)?(?:throws\s+)?->\s*(" + TYPE_RE + ")", masked[e + 1:e + 200])
                if m.group(1) and mr:
                    self.funcs.setdefault(m.group(1), []).append((tuple(labels), type_kind(mr.group(1))))
            for m in re.finditer(r"\bfor\s+(\w+)\s+in\s+\d+\s*\.\.[.<]", masked):
                self.decls.setdefault(m.group(1), []).append((path, m.start(1), "Int", None, False))

    def infer(self, expr, path, pos, depth=0):
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
            ka = self.infer(e[ops["?"] + 1:ops[":"]], path, pos, depth + 1)
            kb = self.infer(e[ops[":"] + 1:], path, pos, depth + 1)
            return ka if ka == kb else None
        if "??" in ops:
            k = ops["??"]
            right = self.infer(e[k + 2:], path, pos, depth + 1)
            return right if right is not None else self.infer(e[:k], path, pos, depth + 1)
        if "bin" in ops:                   # a + b, n - 1, ...
            ks = {self.infer(e[a:b], path, pos, depth + 1) for a, b in ops["bin"]}
            ks.discard(None)
            return ks.pop() if len(ks) == 1 else None
        if re.fullmatch(r"-?\d[\d_]*", e):
            return "lld"
        if re.fullmatch(r"-?\d[\d_]*\.\d[\d_]*", e):
            return "?Double"
        if e[:1] == '"' or e[:2] == '#"':
            return "@"
        if e in ("true", "false"):
            return "?Bool"
        return self.chain(s, path, pos, depth)

    def chain(self, s, path, pos, depth):
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
        if kind == "index":
            return None
        if kind == "call":
            _, callee = links[-2]
            if len(links) == 2:
                tk = type_kind(callee)
                if tk or callee[:1].isupper():
                    return tk              # Int(x), String(format:), SomeType(...) -> None
            if callee in ("formatted", "uppercased", "lowercased", "trimmingCharacters", "joined",
                          "replacingOccurrences", "capitalized"):
                return "@"
            cands = self.funcs.get(callee, [])
            labels = call_labels(value)
            exact = {kd for lb, kd in cands if lb[:len(labels)] == labels}
            ks = exact if exact else {kd for _, kd in cands}
            ks.discard(None)
            return ks.pop() if len(ks) == 1 else None
        if kind == "member":
            if value in ("count", "endIndex", "startIndex"):
                return "lld"
            if value in ("description", "localizedDescription", "capitalized", "localizedCapitalized"):
                return "@"
            mode = "self" if len(links) == 2 and links[0][1] in ("self", "Self") else "member"
            return self.lookup(value, path, pos, depth, mode)
        return self.lookup(value, path, pos, depth, "local")

    def lookup(self, name, path, pos, depth, mode):
        """local: the nearest declaration of the name before the use in the file decides.
        self, or local with none before: the file's properties of that name must agree.
        Then (member `x.name` with x of an unknown type) every property of that name in Sources
        whose type is known must agree."""
        ds = self.decls.get(name, [])
        same = [d for d in ds if d[0] == path]
        if mode == "local":
            before = [d for d in same if d[1] < pos]
            if before:
                return self.decl_kind(max(before, key=lambda d: d[1]), depth)
        if mode in ("local", "self"):
            ks = {self.decl_kind(d, depth) for d in same if d[4]} - {None}
            if len(ks) == 1:
                return ks.pop()
            if ks:
                return None
        ks = {self.decl_kind(d, depth) for d in ds if d[4]} - {None}
        return ks.pop() if len(ks) == 1 else None

    def decl_kind(self, d, depth):
        path, off, typ, init, _ = d
        if typ:
            return type_kind(typ)
        if init:
            return self.infer(init, path, off, depth + 1)
        return None


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
            spaced = k > 0 and s[k - 1] == " " and s[k + 1:k + 2] == " "
            if s.startswith("??", k):
                out.setdefault("??", k)
                k += 2
                continue
            if c == "?" and spaced:
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
            src = open(p, encoding="utf-8").read()
            try:
                masked, nocomment, lits = scan(src)
            except SwiftSyntax as e:
                errors.append(f"{rel}: cannot read it ({e}) - extend tools/check_l10n_keys.py")
                continue
            files[rel] = {"src": src, "masked": masked, "nocomment": nocomment, "lits": lits}
    store = json.load(open(os.path.join(ROOT, "Localization", "translations.json"), encoding="utf-8"))
    keys = {k["key"] for k in store["keys"]}
    by_shape = {}
    for k in keys:
        by_shape.setdefault(SPEC.sub(INTERP, k).replace("%%", "%"), []).append(k)

    customs = custom_callees(files)
    types = Types(files)
    used, checked, allowed, report = set(), 0, 0, []
    for rel, f in files.items():
        for lit, why in sorted(localizable_literals(f, customs), key=lambda h: h[0].start):
            shape = lit.text()
            where = f"{rel}:{lit.line}"
            if not has_letter(shape.replace(INTERP, "")):
                continue
            if shape in ALLOW:
                allowed += 1
                continue
            checked += 1
            kinds = [types.infer(code, rel, off) for code, off in lit.interps]
            report.append((where, why, shape, kinds))
            bad = [(code, k) for (code, _), k in zip(lit.interps, kinds) if k and k[0] == "?"]
            for code, k in bad:
                errors.append(f"{where}: \\({code}) is a {k[1:]}, but keys only know %@ / %lld: "
                              f"interpolate a String or an Int [{why}]")
            if bad:
                continue
            if not lit.interps:            # no interpolation: the key is the text as written
                cands = [shape] if shape in keys else []
            else:
                cands = by_shape.get(shape, [])
            ok = [c for c in cands if all(k in (None, sp) for k, sp in zip(kinds, SPEC.findall(c)))]
            if ok:
                used.update(ok)
                continue
            want = lit.text([k or "@" for k in kinds])
            unknown = [code for (code, _), k in zip(lit.interps, kinds) if k is None]
            hint = f" (type of {', '.join(unknown)} not inferred: %lld if Int)" if unknown else ""
            if cands:
                errors.append(f"{where}: wrong specifier in key {cands[0]!r}: Swift looks up {want!r} "
                              f"(type wrong? TYPE_HINTS in tools/check_l10n_keys.py) [{why}]")
            else:
                errors.append(f"{where}: not in translations.json: {want!r}{hint} [{why}]")
    if "--dump" in sys.argv:
        for where, why, shape, kinds in report:
            print("LIT", where, why, repr(shape), kinds)
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
