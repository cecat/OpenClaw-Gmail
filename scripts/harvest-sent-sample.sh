#!/usr/bin/env bash
# harvest-sent-sample.sh
# Collect a representative sample of sent email bodies for writing-style analysis.
#
# Usage:
#   harvest-sent-sample.sh              # 12-month window, up to 100 samples
#   harvest-sent-sample.sh --days 30    # last 30 days, all messages
#
# Output: /tmp/gmail-agent-sent-sample.jsonl  (JSONL — one record per line)
#   Each line: {"date":"...","to":"...","subject":"...","body_text":"..."}
#
# Skips: self-sent messages, messages with empty body, very short messages (<50 chars),
#        forwarded threads.
#
# JSON structure from gog gmail get --format full --results-only:
#   { "body": "<decoded text>",
#     "headers": { "to":"...", "subject":"...", "from":"...", "date":"..." },
#     "message": { ... } }
# The top-level "body" field contains already-decoded text. The "headers" dict
# uses lowercase keys.

set -euo pipefail

DAYS="${1:-}"
if [[ "$DAYS" == "--days" ]]; then
  DAYS="$2"
  AFTER_DATE=$(date -d "-${DAYS} days" +%Y/%m/%d 2>/dev/null \
    || date -v "-${DAYS}d" +%Y/%m/%d)
  MAX_SAMPLE=999
else
  AFTER_DATE=$(date -d "-12 months" +%Y/%m/%d 2>/dev/null \
    || date -v "-12m" +%Y/%m/%d)
  MAX_SAMPLE=100
fi

SELF="${GOG_ACCOUNT:-YOUR_GMAIL_ADDRESS}"
OUTPUT="/tmp/gmail-agent-sent-sample.jsonl"

echo "[harvest-sent-sample] window: after $AFTER_DATE  max=$MAX_SAMPLE" >&2

# Fetch message IDs, shuffle for a spread across time
TMPIDS=$(mktemp)
gog gmail list -j --results-only \
  "in:sent after:${AFTER_DATE}" \
  --max 500 --all 2>/dev/null \
  | python3 -c "
import json,sys,random
msgs = json.load(sys.stdin)
ids = [m['id'] for m in msgs]
random.shuffle(ids)
for i in ids[:${MAX_SAMPLE}]:
    print(i)
" > "$TMPIDS"

TOTAL=$(wc -l < "$TMPIDS" | tr -d ' ')
echo "[harvest-sent-sample] sampling up to $TOTAL messages" >&2

> "$OUTPUT"   # clear/create output file
COLLECTED=0

while IFS= read -r msgid; do
  # --format full --results-only gives us decoded body + flat headers dict
  raw=$(gog gmail get -j --results-only --format full "$msgid" 2>/dev/null || true)
  [[ -z "$raw" ]] && continue

  result=$(echo "$raw" | python3 -c "
import json,sys,re

d = json.load(sys.stdin)

# Top-level flat headers dict (lowercase keys)
h       = d.get('headers', {})
to_val  = h.get('to', '')
subj    = h.get('subject', '')
date    = h.get('date', '')
from_v  = h.get('from', '').lower()

# Top-level decoded body (no base64 decoding needed)
body = d.get('body', '').strip()
body = re.sub(r'\s+', ' ', body)

# Skip self-sent (to: only contains self)
self = '${SELF}'.lower()
if self in from_v and (not to_val or self == to_val.lower().strip()):
    sys.exit(0)

# Skip empty or very short
if len(body) < 50:
    sys.exit(0)

# Skip forwarded
if re.match(r'^(fwd?|fw)[:\s]', subj, re.IGNORECASE):
    sys.exit(0)

print(json.dumps({
    'date': date,
    'to': to_val,
    'subject': subj,
    'body_text': body[:2000]
}))
" 2>/dev/null || true)

  [[ -z "$result" ]] && continue

  # JSONL: one record per line
  echo "$result" >> "$OUTPUT"
  COLLECTED=$((COLLECTED+1))
  echo "[harvest-sent-sample] collected $COLLECTED: $msgid" >&2
done < "$TMPIDS"

rm -f "$TMPIDS"

echo "[harvest-sent-sample] done: $COLLECTED messages written to $OUTPUT" >&2
echo "{\"output\": \"$OUTPUT\", \"format\": \"jsonl\", \"messages_collected\": $COLLECTED}"
