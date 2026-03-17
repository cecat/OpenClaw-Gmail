#!/usr/bin/env bash
# fetch-inbox-digest.sh
# Fetch today's unread inbox messages and classify each sender as
# "in contacts" or "not in contacts".
#
# Output: /tmp/gmail-agent-inbox-digest.jsonl  (JSONL — one record per line)
#   Each line: {"message_id":"...","from":"...","from_email":"...",
#               "in_contacts":true/false,"subject":"...","snippet":"..."}
#
# JSON structure from gog gmail get --format full --results-only:
#   { "body":"...", "headers":{"to":"...","from":"...","subject":"..."},
#     "message":{"snippet":"...", ...} }
# The top-level "headers" dict uses lowercase keys.

set -euo pipefail

OUTPUT="/tmp/gmail-agent-inbox-digest.jsonl"
AFTER_DATE=$(date +%Y/%m/%d)
SELF="${GOG_ACCOUNT:-YOUR_GMAIL_ADDRESS}"

echo "[fetch-inbox-digest] fetching unread from $AFTER_DATE" >&2

TMPIDS=$(mktemp)
gog gmail list -j --results-only \
  "is:unread in:inbox after:${AFTER_DATE}" \
  --max 100 2>/dev/null \
  | python3 -c "
import json,sys
msgs = json.load(sys.stdin)
for m in msgs:
    print(m['id'])
" > "$TMPIDS"

TOTAL=$(wc -l < "$TMPIDS" | tr -d ' ')
echo "[fetch-inbox-digest] $TOTAL unread messages today" >&2

> "$OUTPUT"

while IFS= read -r msgid; do
  raw=$(gog gmail get -j --results-only --format full "$msgid" 2>/dev/null || true)
  [[ -z "$raw" ]] && continue

  # Extract fields using top-level headers dict and message.snippet
  record=$(echo "$raw" | python3 -c "
import json,sys,re

d = json.load(sys.stdin)
h       = d.get('headers', {})
from_v  = h.get('from', '')
subj    = h.get('subject', '(no subject)')
snippet = d.get('message', {}).get('snippet', '')[:200]

# Extract email address from From header
m = re.search(r'[\w.\-+]+@[\w.\-]+\.[a-zA-Z]{2,}', from_v)
from_email = m.group().lower() if m else from_v.lower()

# Display name
name_m = re.match(r'^(.+?)\s*<', from_v)
from_name = name_m.group(1).strip().strip('\"') if name_m else from_email

print(json.dumps({
    'message_id': '$msgid',
    'from': from_name,
    'from_email': from_email,
    'subject': subj,
    'snippet': snippet,
    'in_contacts': '__CHECK__'
}))
" 2>/dev/null || true)

  [[ -z "$record" ]] && continue

  from_email=$(echo "$record" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['from_email'])" 2>/dev/null || true)

  # Check contacts
  in_contacts="false"
  if [[ -n "$from_email" && "$from_email" != "$SELF" ]]; then
    count=$(gog contacts search -j --results-only "$from_email" 2>/dev/null \
      | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]] && in_contacts="true"
  fi

  # Write final JSONL record
  echo "$record" | python3 -c "
import json,sys
d = json.load(sys.stdin)
d['in_contacts'] = $in_contacts
print(json.dumps(d))
" >> "$OUTPUT" 2>/dev/null || true

  echo "[fetch-inbox-digest] $from_email in_contacts=$in_contacts" >&2
done < "$TMPIDS"

rm -f "$TMPIDS"

FROM_CONTACTS=$(python3 -c "
import json
count = 0
with open('$OUTPUT') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        if d['in_contacts']:
            count += 1
print(count)
" 2>/dev/null || echo 0)

TOTAL_OUT=$(wc -l < "$OUTPUT" | tr -d ' ')

echo "[fetch-inbox-digest] done: $TOTAL_OUT messages, $FROM_CONTACTS from contacts → $OUTPUT" >&2
echo "{\"output\": \"$OUTPUT\", \"format\": \"jsonl\", \"total_messages\": $TOTAL_OUT, \"from_contacts\": $FROM_CONTACTS}"
