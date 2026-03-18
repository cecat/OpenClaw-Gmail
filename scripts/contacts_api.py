#!/usr/bin/env python3
"""
contacts_api.py — Google People/Contacts API client, stdlib only.

Usage:
  contacts_api.py search <email_or_name>
  contacts_api.py create --email ADDR --given NAME [--family NAME]
                         [--phone NUM] [--org NAME] [--title TITLE]

Token/creds paths follow the same convention as gmail_api.py.
"""
import argparse, datetime, json, os, re, sys
import time, urllib.error, urllib.parse, urllib.request

# ── paths ─────────────────────────────────────────────────────────────────────
HOME       = os.environ.get("HOME", os.path.expanduser("~"))
TOKEN_PATH = os.environ.get("GSUITE_MCP_TOKEN_PATH",
             os.path.join(HOME, ".local", "share", "gsuite-mcp", "token.json"))
CREDS_PATH = os.environ.get("GSUITE_MCP_CREDENTIALS_PATH",
             os.path.join(HOME, ".config", "gsuite-mcp", "credentials.json"))

PEOPLE_BASE = "https://people.googleapis.com/v1"
TOKEN_URL   = "https://oauth2.googleapis.com/token"

# ── auth (same logic as gmail_api.py) ─────────────────────────────────────────
def _load_token():
    with open(TOKEN_PATH) as f:
        return json.load(f)

def _save_token(tok):
    os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
    with open(TOKEN_PATH, "w") as f:
        json.dump(tok, f, indent=2)

def _is_expired(tok):
    s = tok.get("expiry", "")
    if not s:
        return True
    try:
        m = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{2}:\d{2}|Z)?$',
                     s.replace("Z", "+00:00"))
        if m:
            dt = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
            off = m.group(3) or "+00:00"
            sign = 1 if off[0] == "+" else -1
            h, mi = int(off[1:3]), int(off[4:6])
            utc_ts = dt.timestamp() - sign * (h * 3600 + mi * 60)
            return time.time() > utc_ts - 60
    except Exception:
        pass
    return True

def _refresh(tok):
    with open(CREDS_PATH) as f:
        installed = json.load(f).get("installed", {})
    data = urllib.parse.urlencode({
        "client_id":     installed["client_id"],
        "client_secret": installed["client_secret"],
        "refresh_token": tok["refresh_token"],
        "grant_type":    "refresh_token",
    }).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req) as resp:
        new = json.loads(resp.read())
    tok["access_token"] = new["access_token"]
    exp = new.get("expires_in", 3600)
    tok["expiry"] = (datetime.datetime.utcnow() +
                     datetime.timedelta(seconds=exp)
                     ).strftime("%Y-%m-%dT%H:%M:%S.000000+00:00")
    _save_token(tok)
    return tok

def _token():
    tok = _load_token()
    if _is_expired(tok):
        tok = _refresh(tok)
    return tok["access_token"]

# ── HTTP helpers ───────────────────────────────────────────────────────────────
def _request(method, path, params=None, body=None):
    url = f"{PEOPLE_BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_token()}")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()}")

# ── commands ──────────────────────────────────────────────────────────────────
def cmd_search(query):
    """Search contacts by email or name. Returns found/not-found with list."""
    data = _request("GET", "people:searchContacts", {
        "query":    query,
        "readMask": "names,emailAddresses,phoneNumbers,organizations",
        "pageSize": 10,
    })
    results = data.get("results", [])
    if not results:
        return {"found": False, "count": 0, "contacts": []}

    contacts = []
    for r in results:
        person = r.get("person", {})
        names  = person.get("names", [])
        emails = person.get("emailAddresses", [])
        phones = person.get("phoneNumbers", [])
        orgs   = person.get("organizations", [])
        contacts.append({
            "resourceName": person.get("resourceName", ""),
            "name":  names[0].get("displayName", "")  if names  else "",
            "email": emails[0].get("value", "")        if emails else "",
            "phone": phones[0].get("value", "")        if phones else "",
            "org":   orgs[0].get("name", "")           if orgs   else "",
        })

    return {"found": True, "count": len(contacts), "contacts": contacts}


def cmd_create(email, given, family=None, phone=None, org=None, title=None):
    """Create a new contact. Skips if already exists (checks first)."""
    # Check existence first — idempotent
    existing = cmd_search(email)
    for c in existing.get("contacts", []):
        if c["email"].lower() == email.lower():
            return {"created": False, "already_existed": True,
                    "email": email, "name": c["name"]}

    person = {
        "emailAddresses": [{"value": email}],
        "names": [{"givenName": given}],
    }
    if family:
        person["names"][0]["familyName"] = family
    if phone:
        person["phoneNumbers"] = [{"value": phone}]
    if org or title:
        entry = {}
        if org:   entry["name"]  = org
        if title: entry["title"] = title
        person["organizations"] = [entry]

    result = _request("POST", "people:createContact",
                      params={"personFields": "names,emailAddresses"},
                      body=person)
    display = f"{given} {family}".strip() if family else given
    return {
        "created": True,
        "resourceName": result.get("resourceName", ""),
        "name":  display,
        "email": email,
        "phone": phone or "",
        "org":   org or "",
    }

# ── main ──────────────────────────────────────────────────────────────────────
def main():
    p = argparse.ArgumentParser(description="Google Contacts API client (stdlib only)")
    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("search")
    ps.add_argument("query")

    pc = sub.add_parser("create")
    pc.add_argument("--email",  required=True)
    pc.add_argument("--given",  required=True)
    pc.add_argument("--family", default=None)
    pc.add_argument("--phone",  default=None)
    pc.add_argument("--org",    default=None)
    pc.add_argument("--title",  default=None)

    args = p.parse_args()

    if args.cmd == "search":
        out = cmd_search(args.query)
    elif args.cmd == "create":
        out = cmd_create(email=args.email, given=args.given, family=args.family,
                         phone=args.phone, org=args.org, title=args.title)

    print(json.dumps(out, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
