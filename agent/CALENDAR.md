# CALENDAR.md — recurring duties
#
# Format:  DAYS HH:MM | task description   (HH:MM is always UTC)
# DAYS:    DAILY | WEEKDAYS | WEEKENDS | MON TUE WED THU FRI SAT SUN | MON,THU
#
# Task description conventions:
#   plain text          -> agent uses judgment
#   SLACK_POST | <id> | <msg>
#   SLACK_DM   | <id> | <msg>
#   PLAN: <path>        -> agent reads .md file at <path> for detailed steps
#
# IMPORTANT: This file is NEVER modified during execution. check-todos.sh reads
# it and writes READY entries to TODO.md when an entry comes due. The agent
# executes the READY item and removes it from TODO.md -- not from here.
# To disable a duty, comment it out. To add one, append a new line.
#
# See AGENTS.md for the full three-tier scheduling framework.
# -----------------------------------------------------------------------------

# Daily email digest (adjust UTC time to match your preferred local time)
DAILY 13:00 | PLAN: /workspace/runbooks/RUNBOOK_EMAIL_DIGEST.md

# Monthly writing style review -- uncomment after one-time sync is complete
# MON 14:00 | PLAN: /workspace/runbooks/RUNBOOK_STYLE_REVIEW.md
