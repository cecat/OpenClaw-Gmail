# RUNBOOK_INBOX_ANALYSIS.md — Daily Inbox Analysis

**Triggered by:** CALENDAR.md entries at 13:00 UTC and 20:00 UTC daily.
YOUR_NAME can also trigger manually: `PLAN: /workspace/runbooks/RUNBOOK_INBOX_ANALYSIS.md`

**Purpose:** Deep per-message classification of today's inbox — beyond the brief
daily digest. Surfaces actionable items: replies expected, urgent messages, action
items, meeting requests. Flags near-spam for filtering. Does not summarise
newsletter or automated mail.

**Pre-approved actions:** Writing to TODO.md, writing filter suggestions to
memory/pending-filters.json, and posting a Slack summary are all pre-approved
standing actions. Sending email or creating Gmail filters are NOT pre-approved —
those require YOUR_NAME's explicit confirmation.

---

## Step 1 — Fetch today's unread messages (script)

```
exec: /scripts/fetch-inbox-digest.sh
```

Output: `/tmp/gmail-agent-inbox-digest.jsonl`
Format per line: `{message_id, from, from_email, in_contacts, subject, snippet}`

If the file is empty after running, skip to Step 6 (no messages, no Slack post).

---

## Step 2 — Per-message deep analysis (LLM)

For each record in `/tmp/gmail-agent-inbox-digest.jsonl`, fetch the full message body:
```
exec: gog gmail get -j --results-only --format full <message_id>
```

Then classify the message across these dimensions. Output one JSON line per
message to `/tmp/gmail-agent-inbox-analysis.jsonl`:

```json
{
  "message_id": "...",
  "from_email": "...",
  "from_name": "...",
  "subject": "...",
  "reply_expected": true,
  "reply_summary": "Aaron is asking if you are free next week",
  "urgency": "high",
  "urgency_reason": "Deadline: proposal due March 31",
  "action_items": ["Review the attached draft", "Send revised budget"],
  "category": "personal",
  "meeting_details": null,
  "filter_suggestion": null
}
```

**Classification rules:**

`reply_expected`: true if the message contains a direct question addressed to
YOUR_NAME, an explicit request for a response, or an expectation of a decision.
Summarise the ask in one plain sentence in `reply_summary`. False otherwise.

`urgency`:
- "high" — explicit deadline, "urgent", "ASAP", "by EOD/COB", or time-sensitive
  event within 48 hours
- "low" — newsletters, digests, automated notifications, things requiring no action
- "normal" — everything else

`action_items`: list of specific tasks asked of YOUR_NAME. Empty list if none.
Keep each item short (one clause). Do not fabricate items not in the message.

`category`:
- "personal" — from a known person, personal/social content
- "work" — professional content, work projects, colleagues
- "meeting_request" — contains a request or proposal to meet, with or without
  a specific time
- "near_spam" — fundraising, political solicitation, unsolicited marketing,
  even if disguised as personal outreach
- "newsletter" — subscribed or unsubscribed bulk content, digests, updates
- "automated" — system notifications, receipts, confirmations, alerts
- "other" — does not fit the above

`meeting_details` (populate only if category is "meeting_request"):
```json
{
  "proposed_time": "2pm",
  "proposed_date": "Thursday March 20",
  "location_or_link": "Zoom / in person / null",
  "organiser": "name or email"
}
```

`filter_suggestion` (populate only if category is "near_spam" or "newsletter"):
A Gmail search expression that would match this sender's future messages, e.g.:
`from:fundraising@example.org` or `from:@example-pac.com`
Keep it specific enough to avoid catching legitimate mail.

---

## Step 3 — Write action items to TODO.md

Read `/tmp/gmail-agent-inbox-analysis.jsonl`.

For each record with a non-empty `action_items` list, append one line to
`/workspace/TODO.md` per item:
```
<now+2hours_UTC> | Email action: <item> (from <from_email>, re: <subject>)
```

Use `date -u +%Y-%m-%dT%H:%M:%SZ` for the timestamp, offset by 2 hours.

---

## Step 4 — Record filter suggestions

For each record with a non-null `filter_suggestion`:

Append to `/workspace/memory/pending-filters.json`:
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

Do NOT apply the filter automatically. YOUR_NAME reviews pending-filters.json
and approves filters via Slack command (future feature).

---

## Step 5 — Post Slack summary

Read `/tmp/gmail-agent-inbox-analysis.jsonl`. Build a Slack message and write to
`/shared/slack-outbox/<timestamp>-inbox-analysis.json`.

Include ONLY:
- Messages with `reply_expected: true` — list from, subject, and reply_summary
- Messages with `urgency: high` — list from, subject, urgency_reason
- Action items added to TODO.md (brief list)
- Meeting requests — from, subject, proposed time/date

Do NOT include: near_spam, newsletter, automated, or low-urgency items.

If nothing actionable was found (all items are low urgency, no replies expected,
no action items), write a single brief post:
> "Inbox analysis complete — nothing requiring your attention."

Slack outbox format:
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
exec: rm -f /tmp/gmail-agent-inbox-digest.jsonl /tmp/gmail-agent-inbox-analysis.jsonl
```
