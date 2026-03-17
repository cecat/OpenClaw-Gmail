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

## Step 2 — Sent-mail contacts harvest (script)

```
exec: /scripts/harvest-sent-contacts.sh
```

This script pages through 12 months of sent mail, extracts To: recipients,
applies filtering rules (no automated addresses, freq >= 2), and adds
qualifying addresses to Google Contacts.

Save the JSON output to `/workspace/memory/onetime-sync-sent-result.json`.

---

## Step 3 — Received-mail contact candidates (script)

```
exec: /scripts/harvest-received-contacts.sh
```

This script pages through 12 months of inbox mail, counts sender frequency,
applies the same filtering rules, skips addresses already in contacts, and
writes candidates (with message bodies) to `/tmp/gmail-agent-received-candidates.jsonl`.
It does NOT create contacts — that happens after the LLM extraction step.

Save the JSON summary output to `/workspace/memory/onetime-sync-received-result.json`.

---

## Step 4 — Name and contact detail extraction (LLM)

Read `/tmp/gmail-agent-received-candidates.jsonl`.

For each record, examine `from_display_name` and `body_text` to extract:
- `given`: first/given name (string or null)
- `family`: family/last name (string or null)
- `phone`: phone number in any format found in the body (string or null)
- `org`: organization or company name (string or null)
- `title`: job title (string or null)

Rules:
- Do **not** guess. If you cannot determine a field with confidence, set it to null.
- `from_display_name` is the primary name source; check the body/signature for
  more detail (full name, phone, org).
- For phone: look for patterns like US numbers (312-555-1234, (312) 555-1234),
  international (+972-50-...), or phrases like "my number is..." or "call me at...".
- If the display name is clearly a group, list, or mailing address (e.g. "ABC
  Newsletter", "Team Foo"), set all fields to null — this record will be skipped.
- Email address local parts are unreliable proxies for names — do not use
  `jane` from `jane@foo.com` as a given name unless the body confirms it.

Write one JSON line per input record to `/tmp/gmail-agent-enriched-candidates.jsonl`:
```json
{"from_email": "...", "given": "...", "family": "...", "phone": "...", "org": "...", "title": "..."}
```

---

## Step 5 — Create enriched contacts (script)

```
exec: /scripts/create-enriched-contacts.sh
```

This script reads `/tmp/gmail-agent-enriched-candidates.jsonl`, skips records where
`given` is null, and calls `gog contacts create` with all available fields.

---

## Step 6 — Email sample collection (script)

```
exec: /scripts/harvest-sent-sample.sh
```

Fetches up to 100 representative sent messages from the past 12 months.
Writes sample to `/tmp/gmail-agent-sent-sample.jsonl`.

---

## Step 7 — Writing style analysis (LLM)

Read `/tmp/gmail-agent-sent-sample.jsonl`.
Read existing `/workspace/writing-style.md`.

Analyze the email sample and update `writing-style.md` with findings. Focus on:
- Overall tone (formal / professional / casual)
- Typical greeting and closing patterns (with examples)
- Sentence length and structure tendencies
- Vocabulary and phrasing characteristics
- What YOUR_NAME consistently does NOT do
- 3–5 representative verbatim sentences that exemplify the style
- Notes by email type (brief reply vs. longer message vs. note to self)

Write updates to `/workspace/writing-style.md`.

---

## Step 8 — Set guard flag and report

```
exec: echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /workspace/memory/onetime-sync-complete
```

Update `/workspace/CHANGELOG.md` with a brief entry.

DM YOUR_NAME (YOUR_SLACK_USER_ID):
> "One-time sync complete.
>
> **Sent harvest:** [N] added, [N] already existed.
> Added: Name <email>, Name <email>, ... (list each from contacts_added_list)
>
> **Received harvest:** [N] added, [N] skipped (name not determinable).
> Added: Name <email> [ph: xxx] [org: xxx], ... (list each from contacts_added_list,
>   including phone and org where populated)
>
> **Writing style:** updated with analysis of [N] sent messages."

If either contacts_added_list is empty, omit that "Added:" line and just report the count.
