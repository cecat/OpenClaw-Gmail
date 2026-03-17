# RUNBOOK_STYLE_REVIEW.md — Monthly Writing Style Review

**Triggered by:** CALENDAR.md entry (monthly) or YOUR_NAME via Slack.

**Runs:** Monthly. Reviews last 30 days of sent mail, updates writing-style.md,
and harvests any new contacts from the past 30 days of inbox mail.

---

## Step 1 — Collect last 30 days of sent mail (script)

```
exec: /scripts/harvest-sent-sample.sh --days 30
```

Output written to `/tmp/gmail-agent-sent-sample.jsonl`.

---

## Step 2 — Update writing style (LLM)

Read `/tmp/gmail-agent-sent-sample.jsonl`.
Read existing `/workspace/writing-style.md`.

Compare the recent sample to the existing style guide. Ask:
- Have any patterns shifted?
- Are there new phrases or closings appearing consistently?
- Are any documented patterns no longer appearing?

Make targeted updates to `writing-style.md`. Preserve the existing structure.
Do not rewrite sections that have not changed. Add a dated note at the top of
any section you modify: `_(updated YYYY-MM-DD)_`.

---

## Step 3 — Update sent-mail contacts for new recipients (script)

```
exec: /scripts/harvest-sent-contacts.sh --days 30
```

---

## Step 4 — Received-mail contact candidates (script)

```
exec: /scripts/harvest-received-contacts.sh --days 30
```

Output written to `/tmp/gmail-agent-received-candidates.jsonl`.

---

## Step 5 — Name and contact detail extraction (LLM)

Read `/tmp/gmail-agent-received-candidates.jsonl`.

For each record, examine `from_display_name` and `body_text` to extract:
- `given`: first/given name (string or null)
- `family`: family/last name (string or null)
- `phone`: phone number in any format found in the body (string or null)
- `org`: organization or company name (string or null)
- `title`: job title (string or null)

Rules:
- Do **not** guess. If you cannot determine a field with confidence, set it to null.
- `from_display_name` is the primary name source; check body/signature for detail.
- For phone: look for US patterns (312-555-1234) or international (+972-50-...),
  or phrases like "my number is..." or "call me at...".
- If the display name is clearly a group or list, set all fields to null.
- Do not use email local parts as names without body confirmation.

Write one JSON line per input record to `/tmp/gmail-agent-enriched-candidates.jsonl`:
```json
{"from_email": "...", "given": "...", "family": "...", "phone": "...", "org": "...", "title": "..."}
```

---

## Step 6 — Create enriched contacts (script)

```
exec: /scripts/create-enriched-contacts.sh
```

---

## Step 7 — Log and report

Update `/workspace/CHANGELOG.md`.

DM YOUR_NAME (YOUR_SLACK_USER_ID) only if the style guide was meaningfully changed
or new contacts were added:
> "Monthly review complete.
>
> **Style:** [section names] updated based on [N] sent messages.
> (or: No style changes needed.)
>
> **New contacts — sent harvest:** [N] added.
> Added: Name <email>, ... (list each from contacts_added_list; omit line if empty)
>
> **New contacts — received harvest:** [N] added.
> Added: Name <email> [ph: xxx] [org: xxx], ... (omit line if empty)"

If nothing changed and no contacts were added, no DM required.
