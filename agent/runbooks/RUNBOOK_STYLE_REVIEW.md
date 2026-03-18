# RUNBOOK_STYLE_REVIEW.md — Monthly Writing Style Review

**Triggered by:** CALENDAR.md entry (monthly) or YOUR_NAME via Slack.

**Runs:** Monthly. Reviews last 30 days of sent mail, updates writing-style.md,
and harvests any new contacts from the past 30 days.

---

## Step 1 — Collect last 30 days of sent mail

Calculate the date 30 days ago in YYYY/MM/DD format:
```
exec: python3 /scripts/gmail_api.py search "in:sent after:YYYY/MM/DD" --max 100 --format full
```

---

## Step 2 — Update writing style (LLM)

Read `/workspace/writing-style.md`.

Compare the recent sample to the existing style guide. Ask:
- Have any patterns shifted?
- Are there new phrases or closings appearing consistently?
- Are any documented patterns no longer appearing?

Make targeted updates to `writing-style.md`. Preserve the existing structure.
Do not rewrite sections that have not changed. Add a dated note at the top of
any section you modify: `_(updated YYYY-MM-DD)_`.

---

## Step 3 — Sent-mail contact harvest

```
exec: python3 /scripts/gmail_api.py search "in:sent after:YYYY/MM/DD" --max 200 --format headers
```

Apply the same filtering rules as RUNBOOK_ONETIME_SYNC Step 2 (skip self,
automated addresses, low-frequency senders). For any qualifying address not
yet in contacts, create it:
```
exec: python3 /scripts/contacts_api.py create --email EMAIL --given GIVEN [--family FAMILY]
```

---

## Step 4 — Received-mail contact candidates

```
exec: python3 /scripts/gmail_api.py search "in:inbox after:YYYY/MM/DD" --max 200 --format headers
```

For freq ≥ 2 senders not in contacts, fetch one message body:
```
exec: python3 /scripts/gmail_api.py get MESSAGE_ID --format full
```

Run LLM extraction (given/family/phone/org/title — same rules as
RUNBOOK_ONETIME_SYNC Step 3), then:
```
exec: python3 /scripts/contacts_api.py create --email EMAIL --given GIVEN \
  [--family FAMILY] [--phone PHONE] [--org ORG] [--title TITLE]
```

---

## Step 5 — Log and report

Update `/workspace/CHANGELOG.md`.

DM YOUR_NAME (YOUR_SLACK_USER_ID) only if the style guide changed or new
contacts were added:
> "Monthly review complete.
>
> **Style:** sections updated based on N sent messages.
> (or: No style changes needed.)
>
> **Sent harvest:** N added. Added: Name \<email\>, ... (omit if none)
>
> **Received harvest:** N added. Added: Name \<email\> [ph: xxx], ... (omit if none)"

If nothing changed and no contacts were added, no DM needed.
