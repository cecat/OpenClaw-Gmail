# Tools

## GOG Gmail / Contacts / Calendar CLI

`GOG_ACCOUNT` and `GOG_CLIENT` are pre-set in the sandbox environment.
Do not pass `--account` or `--client` flags.

### gog JSON response structure (--results-only)

```
{ "body":    "<decoded plain text>",
  "headers": { "to":"...", "from":"...", "subject":"...", "date":"...", "cc":"..." },
  "message": { "id":"...", "snippet":"...", "labelIds":[...], ... } }
```

Always use the top-level `headers` dict (lowercase keys) and `body` field.
Do not parse `message.payload.headers` — it is the raw API response and varies.

### Gmail

```bash
# List/search
gog gmail list -j --results-only "is:unread" --max 50
gog gmail list -j --results-only "subject:@YOUR_AGENT_ID is:unread" --max 50

# Get full message
gog gmail get -j --results-only --format full <messageId>

# Modify
gog gmail modify <messageId> --mark-read
gog gmail modify <messageId> --remove-label INBOX
gog gmail modify <messageId> --add-label <labelName>

# Send (pre-approved for daily digest only -- see SOUL.md)
gog gmail send --to <addr> --subject "..." --body "..."
gog gmail send --to <addr> --subject "..." --body-file /tmp/body.txt
```

### Contacts

```bash
gog contacts search -j --results-only "email@example.com"
gog contacts create --given "First" --family "Last" --email "addr@example.com" --no-input
gog contacts list -j --results-only
```

### Calendar

```bash
gog calendar list -j --results-only --max 10
```

---

## Slack

**Primary — sessions_send (OpenClaw built-in):**
Use for `SLACK_DM` and `SLACK_POST` typed actions in TODO.md.

**Secondary — slack-outbox (for posting from exec: context):**
Write a JSON file to `/shared/slack-outbox/`. The `send-slack-posts.sh` cron
(every 5 min) picks it up and posts via the Slack API.

```python
import json, time, pathlib
pathlib.Path('/shared/slack-outbox').mkdir(exist_ok=True)
msg = {
  "channel": "YOUR_SLACK_CHANNEL_ID",
  "text": "Your message here",
  "requested_by": "YOUR_AGENT_ID",
  "requested_at": "2026-01-01T00:00:00Z",
  "status": "pending"
}
pathlib.Path(f'/shared/slack-outbox/{int(time.time())}-agent.json').write_text(json.dumps(msg))
```

### Key IDs (fill in after setup)
- Owner DM: `YOUR_SLACK_USER_ID`
- Agent channel: `YOUR_SLACK_CHANNEL_ID`
