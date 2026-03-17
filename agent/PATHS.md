# PATHS.md — Canonical Paths

All other .md files reference these paths.

## Your Workspace
- `/workspace/` — workspace root
- `/workspace/memory/` — daily memory logs (`YYYY-MM-DD.md`)
- `/workspace/writing-style.md` — owner email writing style guide
- `/workspace/CHANGELOG.md` — changelog for workspace files

## Shared Directory
- `/shared/` — shared directory root (accessible to all agents)
- `/shared/slack-outbox/` — Slack post queue (cron delivers every 5 min)
- `/shared/slack-sent/` — sent Slack posts archive
- `/shared/todos/todo.log` — task execution log

## Scripts
- `/scripts/` — shared scripts directory (read-only in sandbox)
- `/scripts/harvest-sent-contacts.sh`
- `/scripts/harvest-sent-sample.sh`
- `/scripts/fetch-inbox-digest.sh`

## Notes
- All paths are absolute from the sandbox container root.
- Do NOT use relative paths.
- Do NOT use `/workspace/shared/` — the shared mount is at `/shared/` directly.
