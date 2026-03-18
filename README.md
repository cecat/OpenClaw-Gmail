# OpenClaw Gmail Agent

A drop-in agent for [OpenClaw](https://openclaw.ai) that manages a Gmail inbox,
Google Contacts, and writing style on your behalf. It triages email, delivers
a daily digest, maintains a contacts list from your sent and received mail, and
learns your writing style so it can draft replies for your approval.

---

## How we got here — the GOG detour

The first version of this project used [GOG](https://github.com/toqueteos/gog),
a third-party CLI that wraps the Google APIs. It handled OAuth and offered a
convenient `gog gmail list` command, so it seemed like a natural fit for
harvesting contacts from sent mail.

The problem: GOG's Gmail list command calls the [threads.list](https://developers.google.com/gmail/api/reference/rest/v1/users.threads/list)
endpoint, not [messages.list](https://developers.google.com/gmail/api/reference/rest/v1/users.messages/list).
`threads.list` returns one entry per conversation thread — and that entry is
always the **first** (oldest) message of the thread, not the matching message.
Applied to a "sent" query, it returned inbound messages from other people rather
than your own outbound replies. Contact harvesting silently failed: the addresses
extracted were senders *to* you, not recipients *from* you, and they were already
in your inbox. No new contacts were ever added.

We confirmed this by reading GOG's source code, which shows a direct call to
`s.svc.Users.Threads.List("me")`. The workaround would have been to fetch every
matching thread and then scan inside it — a round-trip per thread, expensive,
and still fragile because GOG doesn't expose the underlying messages API.

The fix was to drop GOG entirely and call the Gmail REST API directly.

---

## How gsuite-mcp made this simple

[Harper Reed](https://harperreed.com)'s
[gsuite-mcp](https://github.com/2389-research/gsuite-mcp) turned out to be
exactly the right tool — not as an MCP tool (OpenClaw ignores MCP servers), but
as an **OAuth setup helper**. Running `gsuite-mcp setup` handles the full
browser-based consent flow, writes a standard Google OAuth2 `token.json` to
`~/.local/share/gsuite-mcp/token.json`, and manages token refresh. That token
is a plain Google OAuth2 token that any HTTP client can use.

The result: two small stdlib-only Python scripts (`gmail_api.py`,
`contacts_api.py`) that read gsuite-mcp's token directly and call the Gmail
and People APIs via `urllib`. No pip dependencies, no keyring daemon, no
wrapper scripts. The Docker sandbox just needs a bind mount for the token
directory and it works.

What was ~740 lines across 5 bash scripts (most of it keyring plumbing and
GOG workarounds) became ~360 lines in two readable Python files.

---

## Architecture

### 1. Sandboxing

Each agent runs in an isolated Docker container with explicit bind mounts.
The agent can only read or write paths you explicitly grant — its own workspace,
a shared directory, and specific credential files.

### 2. Scheduling — three tiers

| Tier | File | How it fires |
|------|------|-------------|
| Always-on | `HEARTBEAT.md` | Runs on every heartbeat poll (e.g., every 15 min) |
| Recurring | `CALENDAR.md` | `check-todos.sh` (cron) reads this and writes `READY` entries to `TODO.md` when an entry comes due |
| One-shot | `TODO.md` | Agent writes deferred tasks here; heartbeat executes and removes them |

`CALENDAR.md` is never modified at runtime — it is the standing schedule set by
the human. `TODO.md` is runtime state and is gitignored.

### 3. Scripts vs. LLM

Deterministic, procedural work belongs in Python scripts: paging through the
Gmail API, extracting email addresses, checking whether a contact exists,
writing JSON. These are fast, auditable, and consume no LLM tokens.

The LLM handles what it is actually good at: reading a sample of your sent
email and synthesising a writing-style guide, formatting a digest, deciding
whether a message is worth your attention, extracting names and phone numbers
from email signatures. The scripts produce structured data; the LLM reads it
and generates natural language output.

This separation maps directly onto how gsuite-mcp is used: Harper's server
does the OAuth heavy lifting (browser flow, token refresh), and our scripts
do the bulk data work (pagination, filtering, frequency counting) that would
be expensive and fragile if left to an LLM.

---

## What you get

- **Daily digest** — email summarising inbox messages from known contacts
- **Contact hygiene** — recipients from sent mail are added to Google Contacts
  automatically, with name/phone/org extraction from email signatures
- **Writing style learning** — the agent analyses sent mail and maintains a
  style guide it uses when drafting replies
- **Monthly style refresh** — updated from the past 30 days of sent mail
- **Inbox triage** — action items, urgency flags, and meeting requests surfaced
  to Slack twice daily

---

## Repository layout

```
agent/          Drop-in workspace — copy into your OpenClaw agents directory
  runbooks/     Step-by-step procedures the LLM follows
scripts/        Python scripts for deterministic API work (no LLM)
openclaw/       Example openclaw.json agent stanza
```

## Quick start

See [SETUP.md](SETUP.md) for the full step-by-step.

---

## Related work

[Harper Reed](https://harperreed.com)'s
[gsuite-mcp](https://github.com/2389-research/gsuite-mcp) exposes Gmail,
Calendar, Contacts, and Tasks as native MCP tools that an LLM can call
directly, and it is what makes this project work. We use gsuite-mcp for OAuth
setup and rely on the token it writes for all direct API calls.

Harper's server correctly calls `users.messages.list` (not `threads.list`),
which is what revealed the GOG bug and pointed the way to the right fix.

**gsuite-mcp may suit you better if:**
- You want a faster path to a working assistant with minimal scripting
- Your use cases are mostly interactive (compose, reply, search) rather than
  bulk or scheduled
- You are using an agent framework that can actually invoke MCP tools
  (note: OpenClaw ignores MCP servers — it cannot call gsuite-mcp tools directly)

**This approach may suit you better if:**
- You are running scheduled, unattended workloads (daily digests, contact
  harvests) where determinism and cost matter
- You want auditability — every API call is in a readable Python script you
  can inspect, test, and fix independently of the LLM
- You are sensitive to inference cost for bulk operations

The two are complementary, not competing. gsuite-mcp handles OAuth; these
scripts handle bulk data work. The split reflects the same principle that
runs through the whole project: use the right tool for each job.
