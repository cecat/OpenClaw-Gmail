# RUNBOOK_ONETIME_SYNC.md — One-Time 12-Month Contacts & Style Bootstrap

**Triggered by:** YOUR_NAME via Slack:
`PLAN: /workspace/runbooks/RUNBOOK_ONETIME_SYNC.md`

**Runs:** Once only. Guarded by flag file `memory/onetime-sync-complete`.

---

## Step 1 — Guard check

```
exec: test -f /workspace/memory/onetime-sync-complete && echo ALREADY_DONE || echo PROCEED
```

If output is `ALREADY_DONE`: stop immediately, DM YOUR_NAME:
> "One-time sync already completed. See memory/onetime-sync-complete for timestamp."

If output is `PROCEED`: continue to Step 2.

---

## Step 2 — Sent-mail contacts harvest

Calculate the date 12 months ago in YYYY/MM/DD format. Search sent mail:

```
exec: python3 /scripts/gmail_api.py search "in:sent after:YYYY/MM/DD" --max 500 --format headers
```

From the JSON output, collect all unique email addresses from `To` and `Cc` headers.
Parse each address using the pattern `Display Name <email@domain>` or bare `email@domain`.

**Filtering rules — skip any address that:**
- Is YOUR_GMAIL_ADDRESS (self)
- Local part matches: no-reply, noreply, do-not-reply, donotreply, newsletter,
  notifications, notify, alerts, automated, bounce, mailer-daemon, postmaster,
  unsubscribe, support, helpdesk, billing, invoice, orders, shipping, admin,
  webmaster, marketing, promo, info, contact, hello, team, sales
- Domain contains: mailchimp, sendgrid, amazonses, sparkpost, hubspot, zendesk,
  github, gitlab, circleci, pagerduty, slack.com, zoom.us, linkedin, twitter, facebook

**Frequency filter:** only keep addresses that appear in `To` or `Cc` of **2 or more**
distinct sent messages.

For each qualifying address, check whether it already exists:
```
exec: python3 /scripts/contacts_api.py search EMAIL
```

For addresses where `found` is false, extract the best display name from the
`To` header. Parse into given/family if clearly two words; otherwise use full
display name as given name only. Create the contact:
```
exec: python3 /scripts/contacts_api.py create --email EMAIL --given GIVEN [--family FAMILY]
```

Track every successfully created contact: `{email, name}`.

---

## Step 3 — Received-mail contact candidates

Search inbox:
```
exec: python3 /scripts/gmail_api.py search "in:inbox after:YYYY/MM/DD" --max 500 --format headers
```

From the `From` headers, count sender frequency. Apply the same filtering rules
as Step 2. Skip addresses already in contacts (check with `contacts_api.py search`).

For each sender with **frequency ≥ 2** who is not yet in contacts, fetch the
body of their most recent message:
```
exec: python3 /scripts/gmail_api.py get MESSAGE_ID --format full
```

**LLM extraction:** For each candidate, examine `from` display name and `body`
to extract:
- `given`: first/given name — **do not guess; null if uncertain**
- `family`: family name — null if uncertain
- `phone`: any phone number in the body/signature (US or international)
- `org`: organisation or company name
- `title`: job title

Rules: Do not derive names from email local parts. If the display name is
clearly a mailing list or automated sender, set all fields to null.

For each candidate where `given` is not null:
```
exec: python3 /scripts/contacts_api.py create --email EMAIL --given GIVEN \
  [--family FAMILY] [--phone PHONE] [--org ORG] [--title TITLE]
```

Track every successfully created contact: `{email, name, phone, org}`.

---

## Step 4 — Writing style analysis

Collect up to 100 sent messages with full body:
```
exec: python3 /scripts/gmail_api.py search "in:sent after:YYYY/MM/DD" --max 100 --format full
```

Read existing `/workspace/writing-style.md`. Analyse the sample and update the
style guide. Focus on: overall tone, typical greeting and closing patterns
(with verbatim examples), sentence length and structure, vocabulary
characteristics, what YOUR_NAME consistently does NOT do, 3–5 representative
verbatim sentences, and notes by email type (brief reply vs. longer message).

Write updates to `/workspace/writing-style.md`.

---

## Step 5 — Set guard flag and report

```
exec: echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /workspace/memory/onetime-sync-complete
```

Update `/workspace/CHANGELOG.md` with a brief entry.

DM YOUR_NAME (YOUR_SLACK_USER_ID):
> "One-time sync complete.
>
> **Sent harvest:** N added, N already existed.
> Added: Name \<email\>, Name \<email\> ... (list each; omit line if none)
>
> **Received harvest:** N added, N skipped (name not determinable).
> Added: Name \<email\> [ph: xxx] [org: xxx], ... (list each; omit line if none)
>
> **Writing style:** updated with analysis of N sent messages."
