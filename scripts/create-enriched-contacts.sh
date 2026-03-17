#!/usr/bin/env bash
# create-enriched-contacts.sh
# Read LLM-enriched contact candidates and create them in Google Contacts.
#
# Usage:
#   create-enriched-contacts.sh
#
# Input: /tmp/gmail-agent-enriched-candidates.jsonl
#   Each line written by the LLM extraction step:
#   {"from_email":"...", "given":"...", "family":"...",
#    "phone":"...", "org":"...", "title":"..."}
#   Any field may be null. Records where given is null are skipped.
#
# Output: summary JSON to stdout.
#
# Environment: GOG_ACCOUNT and GOG_CLIENT must be set (handled by sandbox).

set -euo pipefail

INPUT="/tmp/gmail-agent-enriched-candidates.jsonl"

if [[ ! -f "$INPUT" ]]; then
  echo '{"error": "input file not found", "file": "'"$INPUT"'"}' >&2
  exit 1
fi

ADDED=0
SKIPPED_NO_NAME=0
SKIPPED_EXISTS=0
FAILED=0

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue

  # Parse fields from JSON line
  from_email=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('from_email','') or '')" 2>/dev/null || true)
  given=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('given'); print(v if v else '')" 2>/dev/null || true)
  family=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('family'); print(v if v else '')" 2>/dev/null || true)
  phone=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('phone'); print(v if v else '')" 2>/dev/null || true)
  org=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('org'); print(v if v else '')" 2>/dev/null || true)
  title=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('title'); print(v if v else '')" 2>/dev/null || true)

  [[ -z "$from_email" ]] && continue

  # Skip if LLM could not determine a given name — do not create unnamed contacts
  if [[ -z "$given" ]]; then
    echo "[create-enriched-contacts] SKIP (no name): $from_email" >&2
    SKIPPED_NO_NAME=$((SKIPPED_NO_NAME+1))
    continue
  fi

  # Skip if already in contacts
  existing=$(gog contacts search -j --results-only "$from_email" 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [[ "$existing" -gt 0 ]]; then
    echo "[create-enriched-contacts] already exists: $from_email" >&2
    SKIPPED_EXISTS=$((SKIPPED_EXISTS+1))
    continue
  fi

  # Build gog contacts create command with available fields
  cmd=(gog contacts create --email "$from_email" --given "$given" --no-input)
  [[ -n "$family" ]] && cmd+=(--family "$family")
  [[ -n "$phone"  ]] && cmd+=(--phone "$phone")
  [[ -n "$org"    ]] && cmd+=(--org "$org")
  [[ -n "$title"  ]] && cmd+=(--title "$title")

  if "${cmd[@]}" 2>/dev/null; then
    echo "[create-enriched-contacts] added: $given $family <$from_email>${phone:+ ph:$phone}${org:+ org:$org}" >&2
    ADDED=$((ADDED+1))
  else
    echo "[create-enriched-contacts] FAILED: $from_email" >&2
    FAILED=$((FAILED+1))
  fi

done < "$INPUT"

python3 -c "
import json
print(json.dumps({
  'contacts_added': $ADDED,
  'skipped_no_name': $SKIPPED_NO_NAME,
  'skipped_already_existed': $SKIPPED_EXISTS,
  'failed': $FAILED
}, indent=2))
"
