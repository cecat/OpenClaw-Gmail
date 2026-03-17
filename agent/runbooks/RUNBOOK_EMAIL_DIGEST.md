# RUNBOOK_EMAIL_DIGEST.md — Daily Email Digest

**Triggered by:** CALENDAR.md entry daily at YOUR_DIGEST_TIME UTC.

**Delivers:** Email to YOUR_DIGEST_EMAIL summarizing today's inbox messages
from known contacts. This send is pre-approved — no per-message confirmation needed.

---

## Step 1 — Fetch inbox and classify senders (script)

```
exec: /scripts/fetch-inbox-digest.sh
```

Output is written to `/tmp/gmail-agent-inbox-digest.jsonl`.
Format: one JSON object per line: `{message_id, from, from_email, in_contacts, subject, snippet}`

---

## Step 2 — Check for anything to report

Read `/tmp/gmail-agent-inbox-digest.jsonl`.

If the file is empty, or no messages have `in_contacts: true`:
- Write a single line to `/tmp/gmail-agent-digest-body.txt`:
  `No messages from known contacts today.`
- Skip to Step 4 (send anyway — YOUR_NAME expects the daily email).

---

## Step 3 — Generate digest (LLM)

For each message where `in_contacts` is true, write a digest entry:

```
From: <from name> (<from_email>)
Subject: <subject>
<snippet>
```

Separate entries with a blank line. Keep the digest factual — do not editorialize.

Also include a brief section at the bottom listing senders NOT in contacts
(just names/addresses, no content):

```
--- Also received (not in contacts) ---
<from_email>: <subject>
...
```

If there are no non-contact messages, omit this section.

Write the full digest to `/tmp/gmail-agent-digest-body.txt`.

---

## Step 4 — Send digest email (pre-approved standing action)

```
exec: gog gmail send \
  --to YOUR_DIGEST_EMAIL \
  --subject "Daily Email Digest - $(date +%Y-%m-%d)" \
  --body-file /tmp/gmail-agent-digest-body.txt
```

---

## Step 5 — Extensibility notes (for future rules)

The digest filter can be expanded by updating `fetch-inbox-digest.sh` to also flag:
- Messages where subject contains a keyword from a watchlist
- Messages from a domain on a watchlist (e.g., @yourorganization.org)

The script outputs structured JSONL — the LLM only needs to handle presentation.

---

## Step 6 — Cleanup

```
exec: rm -f /tmp/gmail-agent-inbox-digest.jsonl /tmp/gmail-agent-digest-body.txt
```
