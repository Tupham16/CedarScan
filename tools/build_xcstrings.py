# Sinh Localization/Localizable.xcstrings + Localization/InfoPlist.xcstrings tu kho dich
# Localization/translations.json. CHAY LAI file nay sau khi sua kho dich — ✗ sua tay .xcstrings.
#
#   python tools/build_xcstrings.py
#
# Kiem truoc khi ghi:
#   - moi ngon ngu du 7 ban dich (vi fr de cs sk es nl) cho tung khoa;
#   - placeholder (%@ / %lld, ke ca dang vi tri %1$@...) khop DUNG BO voi khoa goc;
#   - khong markdown (** hoac __) lot vao ban dich;
#   - khong ky tu % tran (phai la %@ / %lld / %n$@ / %n$lld — % van ban thi khoa goc cung phai
#     mang %% va bo kiem nay phai duoc sua theo).
# Lech mot dieu la DUNG, khong ghi file.
import json, os, re, sys, io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOC = os.path.join(ROOT, "Localization")
LANGS = ["vi", "fr", "de", "cs", "sk", "es", "nl"]

SPEC = re.compile(r"%(?:(\d+)\$)?(@|lld)")

def spec_bag(s):
    """Tra ve multiset specifier da chuan hoa (bo chi so vi tri) + tap chi so vi tri."""
    bag, pos = [], []
    for m in SPEC.finditer(s):
        bag.append(m.group(2))
        if m.group(1):
            pos.append(int(m.group(1)))
    return sorted(bag), pos

def bare_percent(s):
    return SPEC.sub("", s).count("%") > 0

def check(key, lang, val, errors):
    kb, _ = spec_bag(key)
    vb, vpos = spec_bag(val)
    if kb != vb:
        errors.append(f"[{lang}] lech placeholder {kb} vs {vb}: {key[:60]!r}")
    if vpos and sorted(set(vpos)) != list(range(1, len(kb) + 1)):
        errors.append(f"[{lang}] chi so vi tri sai {vpos}: {key[:60]!r}")
    if bare_percent(val) or bare_percent(key):
        errors.append(f"[{lang}] ky tu % tran: {key[:60]!r}")
    if "**" in val or "__" in val:
        errors.append(f"[{lang}] markdown lot vao: {key[:60]!r}")
    if not val.strip():
        errors.append(f"[{lang}] ban dich rong: {key[:60]!r}")

def entry(translations):
    return {
        "extractionState": "manual",
        "localizations": {
            lang: {"stringUnit": {"state": "translated", "value": translations[lang]}}
            for lang in LANGS if lang in translations
        },
    }

def build(keys, path, require_all):
    errors, strings = [], {}
    for k in keys:
        key = k["key"]
        tr = k["translations"]
        missing = [l for l in LANGS if l not in tr]
        if require_all and missing:
            errors.append(f"thieu {missing}: {key[:60]!r}")
        for lang, val in tr.items():
            check(key, lang, val, errors)
        strings[key] = entry(tr)
    if errors:
        for e in errors:
            print("HONG", e)
        sys.exit(1)
    doc = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"OK  {os.path.relpath(path, ROOT)}: {len(strings)} khoa x {len(LANGS)} ngon ngu")

store = json.load(open(os.path.join(LOC, "translations.json"), encoding="utf-8"))
build(store["keys"], os.path.join(LOC, "Localizable.xcstrings"), require_all=True)
build([{"key": k, "translations": v} for k, v in store["infoplist"].items()],
      os.path.join(LOC, "InfoPlist.xcstrings"), require_all=True)
