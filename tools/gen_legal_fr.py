# Sinh ba mang *SectionsFR trong LegalView.swift tu kho dich tools/legal-fr/legal-fr-final.json.
#
#   python tools/gen_legal_fr.py
#
# Ghi de VUNG DANH DAU giua hai dong MARK "Ban tieng Phap (SINH BANG MAY..." va "Het ban tieng
# Phap" — ✗ sua tay vung do. Sua ban dich thi sua JSON roi chay lai.
# Email / ten phap nhan / dia chi buu chinh duoc doi nguoc thanh noi suy \(contactEmail)...
# de ba hang so o dau LegalDoc van la nguon su that duy nhat.
import json, os, re, sys, io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, "Sources", "Account", "LegalView.swift")
STORE = os.path.join(ROOT, "tools", "legal-fr", "legal-fr-final.json")

BEGIN = "// MARK: - Bản tiếng Pháp (SINH BẰNG MÁY từ tools/legal-fr — ✗ SỬA TAY, chạy tools/gen_legal_fr.py)"
END = "// MARK: - Hết bản tiếng Pháp"

d = json.load(open(STORE, encoding="utf-8"))
src = open(SWIFT, encoding="utf-8").read()

CONSTS = dict(re.findall(r'static let (\w+) = "([^"]*)"', src))
SUBST = [(CONSTS[n], n) for n in ("postalAddress", "legalEntity", "contactEmail")]
SUBST.sort(key=lambda kv: -len(kv[0]))

def swift_lit(s):
    if "\n" in s:
        raise SystemExit(f"!! co xuong dong trong: {s[:60]!r}")
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    for value, name in SUBST:
        s = s.replace(value, "\\(" + name + ")")
    return '"' + s + '"'

en_counts = {k: len(re.findall(r'\n        \("', src.split(f"static let {k}Sections: [(String, String)] = [")[1].split("\n    ]")[0]))
             for k in ("privacy", "terms", "eula")}

blocks = [BEGIN, ""]
for key, name in [("privacy", "privacySectionsFR"), ("terms", "termsSectionsFR"), ("eula", "eulaSectionsFR")]:
    secs = d["docs"][key]["sections"]
    if len(secs) != en_counts[key]:
        raise SystemExit(f"!! {key}: FR {len(secs)} muc nhung EN {en_counts[key]} muc")
    blocks.append("extension LegalDoc {")
    blocks.append(f"    static let {name}: [(String, String)] = [")
    for s in secs:
        blocks.append(f"        ({swift_lit(s['heading_fr'])},")
        blocks.append(f"         {swift_lit(s['text_fr'])}),")
    blocks.append("    ]")
    blocks.append("}")
    blocks.append("")
blocks.append(END)
region = "\n".join(blocks)

if BEGIN in src:
    src = src[:src.index(BEGIN)] + region + src[src.index(END) + len(END):]
else:
    marker = "// MARK: - Views"
    if marker not in src:
        raise SystemExit("!! khong tim thay cho chen")
    src = src.replace(marker, region + "\n\n" + marker, 1)

open(SWIFT, "w", encoding="utf-8", newline="").write(src)
for key in ("privacy", "terms", "eula"):
    print(f"{key:8} {len(d['docs'][key]['sections'])} muc FR (EN: {en_counts[key]})")
print("da ghi vung FR vao LegalView.swift")
