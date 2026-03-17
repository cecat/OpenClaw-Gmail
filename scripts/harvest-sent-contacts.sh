#!/usr/bin/env bash
# harvest-sent-contacts.sh
# Harvest TO recipients from sent mail and add qualifying ones to Google Contacts.
#
# Usage:
#   harvest-sent-contacts.sh              # 12-month window (one-time sync)
#   harvest-sent-contacts.sh --days N     # last N days (ongoing maintenance)
#
# Environment: GOG_ACCOUNT and GOG_CLIENT must be set (handled by sandbox).
# Output: summary JSON to stdout, progress to stderr.
#
# FILTERING RULES (all must pass to add a contact):
#   1. To: only — Cc: recipients are skipped entirely
#   2. Not a forwarded thread — subjects starting with Fwd:/FW: are skipped
#   3. Address pattern filter — rejects no-reply, newsletter, list, bounce, etc.
#   4. Domain block list — rejects known automated sending platforms
#   5. Frequency >= 2 — address must appear in To: of at least 2 separate sent messages
#
# JSON structure from gog gmail get --format metadata --results-only:
#   { "headers": { "to": "...", "subject": "...", "from": "...", "cc": "..." },
#     "message": { ... } }
# The top-level "headers" dict uses lowercase keys.

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

echo "[harvest-sent-contacts] window: after $AFTER_DATE  self=$SELF" >&2

# ── Fetch all sent message IDs ───────────────────────────────────────────────
TMPIDS=$(mktemp)
gog gmail list -j --results-only \
  "in:sent after:${AFTER_DATE}" \
  --max 500 --all 2>/dev/null \
  | python3 -c "
import json,sys
msgs = json.load(sys.stdin)
for m in msgs:
    print(m['id'])
" > "$TMPIDS"

TOTAL=$(wc -l < "$TMPIDS" | tr -d ' ')
echo "[harvest-sent-contacts] found $TOTAL sent messages to scan" >&2

# ── Pass 1: collect metadata for all messages, build frequency count ─────────
# gog returns pretty-printed JSON; compact each message to a single line for JSONL.

TMPDATA=$(mktemp)

while IFS= read -r msgid; do
  raw=$(gog gmail get -j --results-only --format metadata \
    --headers "To,Subject" "$msgid" 2>/dev/null || true)
  [[ -z "$raw" ]] && continue
  echo "$raw" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || true
done < "$TMPIDS" > "$TMPDATA"

# ── Python: filter + count frequencies ──────────────────────────────────────
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

with open('${TMPDATA}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except:
            continue

        # Use top-level headers dict (lowercase keys) from --results-only response
        h = d.get('headers', {})
        subj    = h.get('subject', '')
        to_val  = h.get('to', '')

        # Rule 2: skip forwarded threads
        if re.match(r'^(fwd?|fw)[:\s]', subj, re.IGNORECASE):
            continue

        # Rule 1: To: only (cc is already excluded — we only requested To)
        if not to_val:
            continue

        for m in EMAIL_RE.finditer(to_val):
            email = m.group().lower()
            domain = email.split('@')[1] if '@' in email else ''

            # Rule 3: address pattern
            if BAD_ADDRESS_RE.match(email):
                continue

            # Rule 4: domain block
            if BAD_DOMAIN_RE.search(domain):
                continue

            # Skip self
            if email == SELF:
                continue

            freq[email] += 1

            # Capture display name if present
            name_m = re.search(r'([^<",]+)<' + re.escape(email) + '>', to_val, re.IGNORECASE)
            if name_m and email not in display:
                display[email] = name_m.group(1).strip().strip('"')

# Rule 5: frequency >= 2
qualified = {e: c for e, c in freq.items() if c >= 2}
print(json.dumps({'freq': qualified, 'display': display}))
PYEOF

QUALIFIED=$(python3 -c "import json; d=json.load(open('$TMPFREQ')); print(len(d['freq']))" 2>/dev/null || echo 0)
echo "[harvest-sent-contacts] $QUALIFIED addresses qualified (freq>=2, passed all filters)" >&2

# ── Pass 2: add qualified addresses not already in contacts ──────────────────
ADDED=0
ALREADY=0
FAILED=0

while IFS=$'\t' read -r email display_name; do

  existing=$(gog contacts search -j --results-only "$email" 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "$existing" -gt 0 ]]; then
    echo "[harvest-sent-contacts] already exists: $email" >&2
    ALREADY=$((ALREADY+1))
  else
    given="${display_name%% *}"
    [[ -z "$given" ]] && given="${email%@*}"
    family=""
    if [[ "$display_name" == *" "* ]]; then
      family="${display_name#* }"
    fi

    if [[ -n "$family" ]]; then
      if gog contacts create --email "$email" --given "$given" --family "$family" \
          --no-input 2>/dev/null; then
        echo "[harvest-sent-contacts] added: $given $family <$email>" >&2
        ADDED=$((ADDED+1))
      else
        echo "[harvest-sent-contacts] FAILED: $email" >&2
        FAILED=$((FAILED+1))
      fi
    else
      if gog contacts create --email "$email" --given "$given" \
          --no-input 2>/dev/null; then
        echo "[harvest-sent-contacts] added: $given <$email>" >&2
        ADDED=$((ADDED+1))
      else
        echo "[harvest-sent-contacts] FAILED: $email" >&2
        FAILED=$((FAILED+1))
      fi
    fi
  fi
done < <(python3 -c "
import json
d = json.load(open('$TMPFREQ'))
for email in d['freq']:
    name = d['display'].get(email, '')
    print(f'{email}\t{name}')
")

rm -f "$TMPIDS" "$TMPDATA" "$TMPFREQ"

python3 -c "
import json
print(json.dumps({
  'after_date': '$AFTER_DATE',
  'messages_scanned': $TOTAL,
  'addresses_qualified': $QUALIFIED,
  'contacts_added': $ADDED,
  'contacts_already_existed': $ALREADY,
  'contacts_failed': $FAILED
}, indent=2))
"
