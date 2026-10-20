#!/usr/bin/env python3
"""List / revoke the development certificates CI creates on the App Store Connect account.

Why: release.yml archives with automatic signing on a throw-away runner, so Xcode creates a new
"Apple Development" certificate through the API key on every run (its private key dies with the
runner). Dry run #13 (20/10/2026) then failed: "Your account has reached the maximum number of
certificates". This tool only ever touches DEVELOPMENT certificates whose display name is
"Created via API" (made by an API key, i.e. by CI): never AltStore's, never the owner's own,
never a distribution certificate.

  list                     every certificate, marking the ones this tool may revoke
  snapshot <file>          save the ids of the CI-made ones (release.yml, before the archive)
  revoke-new <file>        revoke CI-made ones NOT in the snapshot (release.yml, last step)
  revoke-all --yes         revoke every CI-made one (one-off cleanup; owner OK 21/10/2026)

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8). Needs PyJWT with cryptography.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
DEV_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}
CI_NAME = "Created via API"


def token():
    with open(os.environ["ASC_KEY_PATH"], encoding="utf-8") as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, url, bearer):
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:500]
        raise SystemExit(f"{method} {url} -> HTTP {e.code}: {detail}")


def certificates(bearer):
    url = f"{API}/v1/certificates?limit=200"
    out = []
    while url:
        _, page = call("GET", url, bearer)
        out.extend(page.get("data", []))
        url = (page.get("links") or {}).get("next")
    return out


def is_ci_dev(cert):
    a = cert.get("attributes") or {}
    if a.get("certificateType") not in DEV_TYPES:
        return False
    return a.get("displayName") == CI_NAME or CI_NAME in (a.get("name") or "")


def show(certs):
    for c in sorted(certs, key=lambda c: (c["attributes"].get("expirationDate") or "")):
        a = c["attributes"]
        mark = "CI " if is_ci_dev(c) else "   "
        print(f"{mark} {c['id']}  {a.get('certificateType', '?'):<16} {a.get('displayName') or '-':<24} "
              f"{a.get('name') or '-':<44} exp {a.get('expirationDate') or '-'}")
    ci = [c for c in certs if is_ci_dev(c)]
    print(f"{len(certs)} certificates, {len(ci)} CI-made development ones (marked CI).")


def revoke(certs, bearer):
    for c in certs:
        status, _ = call("DELETE", f"{API}/v1/certificates/{c['id']}", bearer)
        print(f"revoked {c['id']} ({c['attributes'].get('name')}) -> HTTP {status}")
    print(f"{len(certs)} revoked.")


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    mode = argv[1]
    bearer = token()
    certs = certificates(bearer)
    if mode == "list":
        show(certs)
    elif mode == "snapshot" and len(argv) == 3:
        ids = sorted(c["id"] for c in certs if is_ci_dev(c))
        with open(argv[2], "w", encoding="utf-8") as f:
            json.dump(ids, f)
        print(f"snapshot: {len(ids)} CI-made development certificates before this run.")
    elif mode == "revoke-new" and len(argv) == 3:
        with open(argv[2], encoding="utf-8") as f:
            before = set(json.load(f))
        new = [c for c in certs if is_ci_dev(c) and c["id"] not in before]
        if not new:
            print("no new CI-made certificate: nothing to revoke.")
        revoke(new, bearer)
    elif mode == "revoke-all" and argv[2:] == ["--yes"]:
        show(certs)
        revoke([c for c in certs if is_ci_dev(c)], bearer)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
