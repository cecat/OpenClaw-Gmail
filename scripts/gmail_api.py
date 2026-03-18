#!/usr/bin/env python3
"""
gmail_api.py — Gmail API client, stdlib only (no pip dependencies).

Usage:
  gmail_api.py search <query> [--max N] [--format ids|headers|full]
  gmail_api.py get <message_id> [--format metadata|full]
  gmail_api.py send --to ADDR --subject SUBJ (--body TEXT | --body-file FILE)

Token path  (in order): GSUITE_MCP_TOKEN_PATH env, $HOME/.local/share/gsuite-mcp/token.json
Creds path  (in order): GSUITE_MCP_CREDENTIALS_PATH env, $HOME/.config/gsuite-mcp/credentials.json

HOME defaults to /tmp when running inside the openclaw sandbox.
"""
import argparse, base64, datetime, json, os, re, sys
import time, urllib.error, urllib.parse, urllib.request
from email.mime.text import MIMEText

# ── paths ─────────────────────────────────────────────────────────────────────
HOME       = os.environ.get("HOME", os.path.expanduser("~"))
TOKEN_PATH = os.environ.get("GSUITE_MCP_TOKEN_PATH",
             os.path.join(HOME, ".local", "share", "gsuite-mcp", "token.json"))
CREDS_PATH = os.environ.get("GSUITE_MCP_CREDENTIALS_PATH",
             os.path.join(HOME, ".config", "gsuite-mcp", "credentials.json"))

GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"
TOKEN_URL  = "https://oauth2.googleapis.com/token"

# ── auth ──────────────────────────────────────────────────────────────────────
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
def _get(path, params=None):
    url = f"{GMAIL_BASE}/{path}"
    if params:
        # params may be a dict or a list of (key, value) tuples.
        # urlencode handles both; list-of-tuples allows repeated keys
        # (needed for metadataHeaders=From&metadataHeaders=To etc.)
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {_token()}")
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()}")

def _post(path, body, params=None):
    url = f"{GMAIL_BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    req.add_header("Authorization", f"Bearer {_token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()}")

# ── body extraction ────────────────────────────────────────────────────────────
def _extract_body(payload, preferred="text/plain"):
    mime = payload.get("mimeType", "")
    body = payload.get("body", {})
    if mime == preferred and body.get("size", 0) > 0:
        raw = body.get("data", "")
        if raw:
            return base64.urlsafe_b64decode(raw + "==").decode("utf-8", errors="replace")
    for part in payload.get("parts", []):
        result = _extract_body(part, preferred)
        if result:
            return result
    return ""

def _parse_message(detail, fmt):
    payload = detail.get("payload", {})
    headers = {h["name"].lower(): h["value"]
               for h in payload.get("headers", [])}
    out = {"id": detail["id"], "headers": headers,
           "snippet": detail.get("snippet", "")}
    if fmt == "full":
        body = _extract_body(payload)
        # Trim and normalise whitespace
        body = re.sub(r'\s+', ' ', body).strip()
        out["body"] = body[:4000]
    return out

# ── commands ──────────────────────────────────────────────────────────────────
def cmd_search(query, max_results, fmt):
    results = []
    page_token = None
    remaining = max_results
    while remaining > 0:
        params = {"q": query, "maxResults": min(remaining, 500)}
        if page_token:
            params["pageToken"] = page_token
        data = _get("messages", params)
        msgs = data.get("messages", [])
        if not msgs:
            break
        for m in msgs:
            if fmt == "ids":
                results.append({"id": m["id"]})
            else:
                api_fmt = "full" if fmt == "full" else "metadata"
                # metadataHeaders must be repeated query params, not comma-separated
                params = [("format", api_fmt)] + [
                    ("metadataHeaders", h) for h in ["From", "To", "Cc", "Subject", "Date"]
                ]
                detail = _get(f"messages/{m['id']}", params)
                results.append(_parse_message(detail, fmt))
            remaining -= 1
            if remaining <= 0:
                break
        page_token = data.get("nextPageToken")
        if not page_token:
            break
    return results

def cmd_get(msg_id, fmt):
    params = [("format", fmt)] + [
        ("metadataHeaders", h) for h in ["From", "To", "Cc", "Subject", "Date"]
    ]
    detail = _get(f"messages/{msg_id}", params)
    return _parse_message(detail, fmt)

def cmd_send(to, subject, body_text):
    msg = MIMEText(body_text, "plain", "utf-8")
    msg["To"]      = to
    msg["Subject"] = subject
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    result = _post("messages/send", {"raw": raw})
    return {"sent": True, "id": result.get("id", ""), "to": to, "subject": subject}

# ── main ──────────────────────────────────────────────────────────────────────
def main():
    p = argparse.ArgumentParser(description="Gmail API client (stdlib only)")
    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("search")
    ps.add_argument("query")
    ps.add_argument("--max", type=int, default=200)
    ps.add_argument("--format", choices=["ids", "headers", "full"], default="headers")

    pg = sub.add_parser("get")
    pg.add_argument("message_id")
    pg.add_argument("--format", choices=["metadata", "full"], default="full")

    pn = sub.add_parser("send")
    pn.add_argument("--to", required=True)
    pn.add_argument("--subject", required=True)
    pn.add_argument("--body", default=None)
    pn.add_argument("--body-file", default=None)

    args = p.parse_args()

    if args.cmd == "search":
        out = cmd_search(args.query, args.max, args.format)
    elif args.cmd == "get":
        out = cmd_get(args.message_id, args.format)
    elif args.cmd == "send":
        if args.body_file:
            with open(args.body_file) as f:
                body_text = f.read()
        elif args.body:
            body_text = args.body
        else:
            body_text = sys.stdin.read()
        out = cmd_send(args.to, args.subject, body_text)

    print(json.dumps(out, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
