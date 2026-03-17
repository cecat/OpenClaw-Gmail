# RUNBOOK_STYLE_REVIEW.md — Monthly Writing Style Review

**Triggered by:** CALENDAR.md entry (monthly) or YOUR_NAME via Slack.

**Runs:** Monthly. Reviews last 30 days of sent mail and updates writing-style.md.

---

## Step 1 — Collect last 30 days of sent mail (script)

```
exec: /scripts/harvest-sent-sample.sh --days 30
```

Output is written to `/tmp/gmail-agent-sent-sample.jsonl`.

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

## Step 3 — Update contacts for new recipients (script)

```
exec: /scripts/harvest-sent-contacts.sh --days 30
```

---

## Step 4 — Log and report

Update `/workspace/CHANGELOG.md`.

DM YOUR_SLACK_USER_ID only if the style guide was meaningfully changed:
> "Monthly style review complete. Updated [section names] in writing-style.md
>  based on [N] sent messages from the past 30 days."

If no changes were needed, no DM required.
