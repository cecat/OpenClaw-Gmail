# RUNBOOK_EMAIL_DIGEST.md — Daily Email Digest

**Triggered by:** CALENDAR.md entry daily at YOUR_DIGEST_TIME UTC.

**Delivers:** Email to YOUR_DIGEST_EMAIL summarising today's inbox messages
from known contacts. This send is pre-approved — no per-message confirmation needed.

---

## Step 1 — Fetch today's inbox

Calculate today's date in YYYY/MM/DD format. Fetch unread messages:

```
exec: python3 /scripts/gmail_api.py search "in:inbox is:unread after:YYYY/MM/DD" --max 50 --format headers
```

For each message, check whether the sender is a known contact:
```
exec: python3 /scripts/contacts_api.py search FROM_EMAIL
```

Build a list of messages tagged `in_contacts: true/false`.

---

## Step 2 — Check for anything to report

If the message list is empty, or no messages have `in_contacts: true`:
- Body text: `No messages from known contacts today.`
- Skip to Step 4 (send anyway — YOUR_NAME expects the daily email).

---

## Step 3 — Generate digest (LLM)

For each message where `in_contacts` is true, write a digest entry:

```
From: <display name> (<email>)
Subject: <subject>
<snippet>
```

Separate entries with a blank line. Keep the digest factual — do not editorialize.

Include a brief section at the bottom listing senders NOT in contacts:

```
--- Also received (not in contacts) ---
<email>: <subject>
```

Omit this section if there are no non-contact messages.

Write the full digest to `/tmp/gmail-agent-digest-body.txt`.

---

## Step 4 — Send digest email (pre-approved standing action)

```
exec: python3 /scripts/gmail_api.py send \
  --to YOUR_DIGEST_EMAIL \
  --subject "Daily Email Digest - DATE" \
  --body-file /tmp/gmail-agent-digest-body.txt
```

---

## Step 5 — Cleanup

```
exec: rm -f /tmp/gmail-agent-digest-body.txt
```
