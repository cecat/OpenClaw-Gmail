#!/bin/bash
# check-todos.sh — Promote due scheduled items to READY for agent heartbeat execution.
# Runs every 5 minutes via cron on the host. No credentials required.
#
# Setup:
#   1. Edit BASE_DIR below to match your spark-ai-agents checkout path.
#   2. Edit TODO_FILES and CALENDAR_PAIRS to list your agents.
#   3. Add to crontab: */5 * * * * /path/to/scripts/check-todos.sh
#
# Two scheduling mechanisms:
#
#   TODO.md  (one-shot):
#     Agent writes:  2026-03-04T23:00:00Z | Do something
#     Cron marks:    READY | 2026-03-04T23:00:00Z | Do something
#     Heartbeat:     sees READY, executes, removes line, logs to shared/todos/todo.log
#
#   CALENDAR.md  (recurring):
#     Human writes:  DAILY 13:00 | Run daily digest
#     Cron detects:  entry is due today and not yet fired
#     Cron appends:  READY | <ts> | Run daily digest  →  to TODO.md
#     Heartbeat:     sees READY, executes, removes line (CALENDAR.md is never modified)
#     State:         last-fired timestamps stored in shared/todos/calendar-state.json
#
# CALENDAR.md DAYS syntax:
#   DAILY  WEEKDAYS  WEEKENDS  MON  TUE  MON,THU  etc.
#   HH:MM is always UTC.
#
# See AGENTS.md for the full three-tier scheduling framework.

set -euo pipefail

# ── CONFIGURE THESE ──────────────────────────────────────────────────────────
BASE_DIR="$HOME/code/spark-ai-agents"

TODO_FILES=(
    "$BASE_DIR/YOUR_AGENT_ID/TODO.md"
    # Add more agents here:
    # "$BASE_DIR/another-agent/TODO.md"
)

# Each entry: "calendar_file:todo_file:agent_id"
CALENDAR_PAIRS=(
    "$BASE_DIR/YOUR_AGENT_ID/CALENDAR.md:$BASE_DIR/YOUR_AGENT_ID/TODO.md:YOUR_AGENT_ID"
    # Add more agents here:
    # "$BASE_DIR/another-agent/CALENDAR.md:$BASE_DIR/another-agent/TODO.md:another-agent"
)
# ── END CONFIGURE ────────────────────────────────────────────────────────────

LOG_FILE="$BASE_DIR/shared/todos/todo.log"
NOW=$(date -u +%s)

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | $*" >> "$LOG_FILE"
}

# ── TODO.md processing ────────────────────────────────────────────────────────
mark_ready() {
    local file="$1"
    local tmp="${file}.tmp"
    local changed=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^# ]] || [[ -z "$line" ]] || \
           [[ "$line" =~ ^READY\| ]] || [[ "$line" =~ ^READY\ \| ]] || \
           [[ "$line" =~ ^FAILED\| ]] || [[ "$line" =~ ^FAILED\ \| ]]; then
            echo "$line"
            continue
        fi

        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)[[:space:]]*\|[[:space:]]*(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"
            task="${BASH_REMATCH[2]}"
            ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)

            if [[ "$ts_epoch" -le "$NOW" && "$ts_epoch" -gt 0 ]]; then
                echo "READY | $ts | $task"
                log "TRIGGERED | $task"
                stale_secs=$(( NOW - ts_epoch ))
                if [[ "$stale_secs" -gt 3600 ]]; then
                    log "STALE | $task | ${stale_secs}s past due — check agent UTC conversion"
                fi
                changed=1
            else
                echo "$line"
            fi
        else
            echo "$line"
        fi
    done < "$file" > "$tmp"

    if [[ "$changed" -eq 1 ]]; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
}

# ── CALENDAR.md processing ────────────────────────────────────────────────────
process_calendar() {
    local calendar_file="$1"
    local todo_file="$2"
    local agent_id="$3"
    local state_file="$BASE_DIR/shared/todos/calendar-state.json"
    local today dow now_hhmm

    [[ -f "$calendar_file" ]] || return 0

    today=$(date -u +%Y-%m-%d)
    dow=$(date -u +%a | tr '[:lower:]' '[:upper:]')
    now_hhmm=$(date -u +%H:%M)

    if [[ ! -f "$state_file" ]] || ! jq -e . "$state_file" > /dev/null 2>&1; then
        echo '{}' > "$state_file"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi

        if [[ ! "$line" =~ ^([A-Z,]+)[[:space:]]+([0-9]{2}:[0-9]{2})[[:space:]]*\|[[:space:]]*(.+)$ ]]; then
            continue
        fi

        local days="${BASH_REMATCH[1]}"
        local hhmm="${BASH_REMATCH[2]}"
        local task="${BASH_REMATCH[3]}"

        local day_match=0
        case "$days" in
            DAILY)    day_match=1 ;;
            WEEKDAYS) [[ "$dow" =~ ^(MON|TUE|WED|THU|FRI)$ ]] && day_match=1 ;;
            WEEKENDS) [[ "$dow" =~ ^(SAT|SUN)$ ]] && day_match=1 ;;
            *)
                local d
                for d in ${days//,/ }; do
                    [[ "$d" == "$dow" ]] && { day_match=1; break; }
                done
                ;;
        esac
        [[ "$day_match" -eq 0 ]] && continue

        [[ "$now_hhmm" < "$hhmm" ]] && continue

        local key="${agent_id}|${days}|${hhmm}|${task}"
        local last_fired
        last_fired=$(jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null || true)
        [[ "$last_fired" == "${today}"* ]] && continue

        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        echo "READY | $ts | $task" >> "$todo_file"
        log "CALENDAR | $agent_id | $task"

        local tmp_state="${state_file}.tmp"
        if jq --arg k "$key" --arg v "$ts" '. + {($k): $v}' "$state_file" > "$tmp_state" 2>/dev/null; then
            mv "$tmp_state" "$state_file"
        else
            rm -f "$tmp_state"
            log "CALENDAR STATE WRITE FAILED | $agent_id | $task"
        fi

    done < "$calendar_file"
}

# ── Main ──────────────────────────────────────────────────────────────────────
for todo_file in "${TODO_FILES[@]}"; do
    [[ -f "$todo_file" ]] && mark_ready "$todo_file"
done

for pair in "${CALENDAR_PAIRS[@]}"; do
    cal_file="${pair%%:*}"
    rest="${pair#*:}"
    todo_file="${rest%%:*}"
    agent_id="${rest##*:}"
    process_calendar "$cal_file" "$todo_file" "$agent_id"
done
