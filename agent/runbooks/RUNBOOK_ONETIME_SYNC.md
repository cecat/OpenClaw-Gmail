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

## Step 2 — Contacts harvest (script does all API work)

```
exec: /scripts/harvest-sent-contacts.sh
```

This script:
- Pages through 12 months of sent mail
- Extracts **To: recipients only** (Cc: is skipped)
- Skips forwarded threads (Fwd:/FW: subjects)
- Rejects automated address patterns (no-reply, newsletter, bounce, etc.)
- Rejects known automated sending domains (mailchimp, sendgrid, etc.)
- Only adds addresses that appeared in **2 or more** separate sent messages
- Outputs a summary JSON to stdout

Note: the contact list will not include every address ever emailed — only
genuine recurring human contacts. This is by design.

Save the JSON output to `/workspace/memory/onetime-sync-contacts-result.json`.

---

## Step 3 — Email sample collection (script does all API work)

```
exec: /scripts/harvest-sent-sample.sh
```

This script:
- Fetches up to 100 representative sent messages from the past 12 months
- Skips self-sent messages and very short messages
- Writes sample to `/tmp/gmail-agent-sent-sample.jsonl`

---

## Step 4 — Writing style analysis (LLM work)

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

## Step 5 — Set guard flag and report

```
exec: echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /workspace/memory/onetime-sync-complete
```

Update `/workspace/CHANGELOG.md` with a brief entry.

DM YOUR_SLACK_USER_ID:
> "One-time sync complete. [N] contacts added, [N] already existed.
>  writing-style.md updated with analysis of [N] sent messages."
