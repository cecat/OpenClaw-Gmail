#!/bin/bash
# send-slack-posts.sh — Cron job that posts pending Slack outbox items via Slack API.
# Runs on host, not inside an agent. Scans shared/slack-outbox/ for pending files.
#
# Setup:
#   1. Store your Slack bot token (xoxb-...) in ~/.config/slack/bot_token (chmod 600)
#   2. Ensure the bot is in the target channel (invite it: /invite @botname in Slack)
#   3. Bot needs OAuth scope: chat:write
#   4. Edit BASE_DIR below to match your spark-ai-agents checkout path.
#   5. Add to crontab: */5 * * * * /path/to/scripts/send-slack-posts.sh
#
# Agents write outbox files like this:
#   {
#     "channel": "CYOUR_CHANNEL_ID",
#     "text": "Message text here",
#     "requested_by": "YOUR_AGENT_ID",
#     "requested_at": "2026-03-13T04:05:00Z",
#     "status": "pending"
#   }
#
# This script picks up any file with "status": "pending", posts it to Slack,
# then moves it to shared/slack-sent/ with status updated to "sent".

set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# ── CONFIGURE THIS ───────────────────────────────────────────────────────────
BASE_DIR="$HOME/code/spark-ai-agents"
# ── END CONFIGURE ────────────────────────────────────────────────────────────

OUTBOX_DIR="$BASE_DIR/shared/slack-outbox"
SENT_DIR="$BASE_DIR/shared/slack-sent"
LOG_FILE="$BASE_DIR/shared/send-slack.log"
TOKEN_FILE="$HOME/.config/slack/bot_token"

log() { echo "$(date -Iseconds) $*" >> "$LOG_FILE"; }

if [[ ! -f "$TOKEN_FILE" ]]; then
    log "ABORT — Slack bot token not found at $TOKEN_FILE"
    log "  Create it: echo 'xoxb-...' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
    exit 1
fi
SLACK_BOT_TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')

mkdir -p "$OUTBOX_DIR" "$SENT_DIR"

shopt -s nullglob
for f in "$OUTBOX_DIR"/*.json; do
    status=$(jq -r '.status // empty' "$f" 2>/dev/null)
    [[ "$status" == "pending" ]] || continue

    filename=$(basename "$f")

    channel=$(jq -r '.channel // empty' "$f")
    if [[ -z "$channel" ]]; then
        log "SKIP $filename — missing 'channel' field"
        continue
    fi

    payload=$(jq -c '{channel: .channel, text: .text}' "$f")

    response=$(echo "$payload" | curl -sS \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        --data @- \
        https://slack.com/api/chat.postMessage)

    ok=$(echo "$response" | jq -r '.ok // false')
    if [[ "$ok" == "true" ]]; then
        jq --arg ts "$(date -Iseconds)" \
           '. + {status: "sent", sent_at: $ts}' "$f" \
           > "$SENT_DIR/$filename"
        rm -f "$f"
        log "SENT $filename to $channel"
    else
        error=$(echo "$response" | jq -r '.error // "unknown"')
        log "FAIL $filename — Slack API error: $error"
        # File stays in outbox with status "pending" and retries next run.
        # For persistent errors (e.g. invalid_auth), fix the token first.
    fi
done
