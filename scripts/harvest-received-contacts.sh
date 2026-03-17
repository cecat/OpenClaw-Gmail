#!/usr/bin/env bash
# harvest-received-contacts.sh
# Harvest senders from received (inbox) mail and output candidate contacts
# for LLM-based name/phone/org/title extraction.
#
# Usage:
#   harvest-received-contacts.sh              # 12-month window
#   harvest-received-contacts.sh --days N     # last N days
#
# Environment: GOG_ACCOUNT and GOG_CLIENT must be set (handled by sandbox).
# Output:
#   stdout      — summary JSON {messages_scanned, candidates_found, output_file}
#   /tmp/gmail-agent-received-candidates.jsonl — one record per candidate:
#     {from_email, from_display_name, freq, message_id, body_text}
#
# This script does NOT create contacts. It outputs candidates for the LLM
# step in the runbook, which extracts name/phone/org/title, followed by
# cecat-create-enriched-contacts.sh which calls gog contacts create.
#
# FILTERING RULES (same as sent-contacts, adapted for received mail):
#   1. Skip SELF — own address
#   2. Address pattern filter — no-reply, newsletter, bounce, etc.
#   3. Domain block list — known automated platforms
#   4. Skip forwarded threads (Fwd:/FW: subjects)
#   5. Frequency >= 2 — sender must appear in at least 2 separate messages
#   6. Skip senders already in Google Contacts
#
# JSON structure from gog (--format full --results-only):
#   { "body": "<decoded text>",
#     "headers": { "from":"...", "subject":"...", "to":"...", "date":"..." },
#     "message": { ... } }

set -euo pipefail

DAYS="${1:-}"
if [[ "$DAYS" == "--days" ]]; then
  DAYS="$2"
  AFTER_DATE=$(date -d "-${DAYS} days" +%Y/%m/%d 2>/dev/null \
    || date -v "-${DAYS}d" +%Y/%m/%d)
else
  AFTER_DATE=$(date -d "-12 months" +%Y/%m/%d 2>/dev/null \
    || date -v "-12m" +%Y/%m/%d)
fi

SELF="${GOG_ACCOUNT:-YOUR_GMAIL_ADDRESS}"
OUTPUT="/tmp/gmail-agent-received-candidates.jsonl"

echo "[harvest-received-contacts] window: after $AFTER_DATE  self=$SELF" >&2

# ── Fetch all inbox message IDs ───────────────────────────────────────────────
TMPIDS=$(mktemp)
gog gmail list -j --results-only \
  "in:inbox after:${AFTER_DATE}" \
  --max 500 --all 2>/dev/null \
  | python3 -c "
import json,sys
msgs = json.load(sys.stdin)
for m in msgs:
    print(m['id'])
" > "$TMPIDS"

TOTAL=$(wc -l < "$TMPIDS" | tr -d ' ')
echo "[harvest-received-contacts] found $TOTAL inbox messages to scan" >&2

# ── Pass 1: collect metadata, build frequency count ──────────────────────────
# Compact each gog response to single line for JSONL processing.

TMPDATA=$(mktemp)
while IFS= read -r msgid; do
  raw=$(gog gmail get -j --results-only --format metadata \
    --headers "From,Subject" "$msgid" 2>/dev/null || true)
  [[ -z "$raw" ]] && continue
  echo "$raw" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || true
done < "$TMPIDS" > "$TMPDATA"

# ── Python: filter + count sender frequencies ────────────────────────────────
TMPFREQ=$(mktemp)

python3 << PYEOF > "$TMPFREQ"
import json, sys, re
from collections import Counter

BAD_ADDRESS_RE = re.compile(r'''(?x)
    ^(no[-.]?reply|noreply|do[-.]?not[-.]?reply|donotreply
    |newsletter|news|updates|digest|bulletin
    |notifications?|notify|alerts?|automated
    |bounce|mailer[-.]daemon|postmaster|daemon
    |unsubscribe|listserv?|majordomo|mailman
    |support|helpdesk|ticket|feedback|survey
    |billing|invoice|receipt|orders?|shipping
    |admin|webmaster|hostmaster|abuse|spam
    |marketing|promo|promotions?|offers?|deals?
    |info|contact|hello|hi|team|staff|crew
    |sales|noc|devnull|blackhole|junk)@
''', re.IGNORECASE)

BAD_DOMAIN_RE = re.compile(r'''(?x)
    (mailchimp|sendgrid|amazonses|sparkpost|postmarkapp
    |mandrill|mailgun|constantcontact|exacttarget
    |salesforce|marketo|hubspot|pardot|eloqua
    |zendesk|freshdesk|servicenow|jira\.com|atlassian
    |github\.com|gitlab\.com|circleci|travisci
    |pagerduty|opsgenie|victorops|statuspage
    |slack\.com|zoom\.us|webex\.com|gotomeeting
    |eventbrite|meetup\.com|doodle\.com
    |linkedin\.com|twitter\.com|facebook\.com
    |bounce\.|reply\.|\.mail\.|send\.|smtp\.|mta\.)
''', re.IGNORECASE)

EMAIL_RE = re.compile(r'[\w.\-+]+@[\w.\-]+\.[a-zA-Z]{2,}')
SELF = '${SELF}'.lower()

freq = Counter()
display = {}
last_msgid = {}

with open('${TMPDATA}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except:
            continue

        h = d.get('headers', {})
        from_v  = h.get('from', '')
        subj    = h.get('subject', '')
        msg_id  = d.get('message', {}).get('id', '')

        # Skip forwarded threads
        if re.match(r'^(fwd?|fw)[:\s]', subj, re.IGNORECASE):
            continue

        m = EMAIL_RE.search(from_v)
        if not m:
            continue
        email = m.group().lower()
        domain = email.split('@')[1] if '@' in email else ''

        # Skip SELF
        if email == SELF:
            continue

        # Address pattern filter
        if BAD_ADDRESS_RE.match(email):
            continue

        # Domain block
        if BAD_DOMAIN_RE.search(domain):
            continue

        freq[email] += 1
        last_msgid[email] = msg_id

        # Capture display name
        name_m = re.match(r'^"?([^"<]+)"?\s*<', from_v)
        if name_m and email not in display:
            display[email] = name_m.group(1).strip().strip('"')

# Frequency >= 2
qualified = {e: c for e, c in freq.items() if c >= 2}
print(json.dumps({
    'freq': qualified,
    'display': display,
    'last_msgid': last_msgid
}))
PYEOF

CANDIDATES=$(python3 -c "import json; d=json.load(open('$TMPFREQ')); print(len(d['freq']))" 2>/dev/null || echo 0)
echo "[harvest-received-contacts] $CANDIDATES candidate senders (freq>=2, passed filters)" >&2

# ── Pass 2: skip existing contacts, fetch body for new candidates ─────────────
> "$OUTPUT"
WRITTEN=0
SKIPPED_EXISTING=0

while IFS=$'\t' read -r email display_name freq_count last_id; do

  # Skip if already in contacts
  existing=$(gog contacts search -j --results-only "$email" 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [[ "$existing" -gt 0 ]]; then
    echo "[harvest-received-contacts] already in contacts: $email" >&2
    SKIPPED_EXISTING=$((SKIPPED_EXISTING+1))
    continue
  fi

  # Fetch body of most recent message from this sender
  body_text=""
  if [[ -n "$last_id" ]]; then
    body_text=$(gog gmail get -j --results-only --format full "$last_id" 2>/dev/null \
      | python3 -c "
import json,sys,re
d = json.load(sys.stdin)
body = d.get('body', '').strip()
body = re.sub(r'\s+', ' ', body)
print(body[:3000])
" 2>/dev/null || true)
  fi

  # Write JSONL record
  python3 -c "
import json
print(json.dumps({
    'from_email': '$email',
    'from_display_name': $(python3 -c "import json; print(json.dumps('$display_name'))"),
    'freq': $freq_count,
    'message_id': '$last_id',
    'body_text': $(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$body_text")
}))
" >> "$OUTPUT" 2>/dev/null || true

  echo "[harvest-received-contacts] candidate: $email (freq=$freq_count)" >&2
  WRITTEN=$((WRITTEN+1))

done < <(python3 -c "
import json
d = json.load(open('$TMPFREQ'))
for email in d['freq']:
    name = d['display'].get(email, '')
    freq = d['freq'][email]
    msgid = d['last_msgid'].get(email, '')
    print(f'{email}\t{name}\t{freq}\t{msgid}')
")

rm -f "$TMPIDS" "$TMPDATA" "$TMPFREQ"

echo "[harvest-received-contacts] done: $WRITTEN candidates written to $OUTPUT (skipped $SKIPPED_EXISTING existing)" >&2
python3 -c "
import json
print(json.dumps({
    'after_date': '$AFTER_DATE',
    'messages_scanned': $TOTAL,
    'candidates_found': $WRITTEN,
    'skipped_existing': $SKIPPED_EXISTING,
    'output': '$OUTPUT'
}, indent=2))
"
