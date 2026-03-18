# RUNBOOK_INBOX_ANALYSIS.md — Daily Inbox Triage

**Triggered by:** CALENDAR.md at YOUR_TRIAGE_TIMES UTC daily, or manual Slack trigger:
`PLAN: /workspace/runbooks/RUNBOOK_INBOX_ANALYSIS.md`

**Purpose:** Deep per-message analysis of today's unread email. Writes action
items to TODO.md, stages filter suggestions in pending-filters.json, and posts
an actionable-only summary to Slack. Does NOT send email or apply filters
without explicit confirmation.

---

## Step 1 — Fetch today's unread messages

Calculate today's date in YYYY/MM/DD format:
```
exec: python3 /scripts/gmail_api.py search "in:inbox is:unread after:YYYY/MM/DD" --max 100 --format full
```

If the result is empty, skip to Step 6.

---

## Step 2 — Per-message analysis (LLM)

For each message in the result, analyse the full body and determine:

- **reply_expected** (bool): Does the sender clearly expect a reply?
- **urgency** (`high`/`normal`/`low`): Is this time-sensitive?
- **action_items** (list of strings): Specific tasks implied by the email.
- **category**: One of `personal`, `work`, `meeting_request`, `near_spam`,
  `newsletter`, `automated`
- **meeting_details** (if category is `meeting_request`): date, time, location/link
- **filter_suggestion** (optional): If this looks like a pattern that should be
  labelled or archived automatically, suggest a Gmail filter expression.

---

## Step 3 — Write action items to TODO.md

For any message where `reply_expected` is true or `action_items` is non-empty,
append to `/workspace/TODO.md`:

```
TODO [YYYY-MM-DDTHH:MM] Reply to <From Name>: <subject>
```

Set the timestamp to 2 hours from now (UTC).

---

## Step 4 — Stage filter suggestions

For any message that produced a `filter_suggestion`, append to
`/workspace/memory/pending-filters.json`:

```json
{
  "created": "<timestamp>",
  "expression": "<filter_suggestion>",
  "reason": "<category>: <subject>",
  "from_email": "<from_email>",
  "source_message_id": "<message_id>",
  "status": "pending"
}
```

Do NOT apply filters directly. YOUR_NAME reviews and approves these manually.

---

## Step 5 — Post Slack summary

Post to YOUR_SLACK_CHANNEL_ID only with **actionable** items:
- Messages where `reply_expected` is true
- Messages with `urgency: high`
- Messages with non-empty `action_items`
- Messages with `category: meeting_request`

Omit newsletters, automated messages, and near-spam from the summary.

Format:
> **Inbox triage — N messages**
>
> 🔴 **[high urgency]** From Name — Subject
> → urgency reason
>
> 📅 **[meeting request]** From Name — Subject
> → Date/time/location
>
> 💬 **[reply expected]** From Name — Subject

If nothing is actionable, post:
> "Inbox checked — nothing actionable."

Write to `/shared/slack-outbox/<timestamp>-inbox-analysis.json`:
```json
{
  "channel": "YOUR_SLACK_CHANNEL_ID",
  "text": "...",
  "requested_by": "YOUR_AGENT_ID",
  "requested_at": "<timestamp>",
  "status": "pending"
}
```

---

## Step 6 — Cleanup

```
exec: rm -f /tmp/gmail-agent-inbox-*.jsonl
```
