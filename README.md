# OpenClaw Gmail Agent

A drop-in agent for [OpenClaw](https://openclaw.ai) that manages a Gmail inbox
and Google Contacts on your behalf. It triages email, delivers a daily digest,
maintains a contacts list from your sent and received mail, and learns your
writing style so it can draft replies for your approval.

---

## Architecture

### Sandboxing

The agent runs in an isolated Docker container with explicit bind mounts. It
can only read or write paths you explicitly grant — its own workspace, a shared
directory, and specific credential files. Nothing else on the host is
accessible.

### Scheduling — three tiers

| Tier | File | How it fires |
|------|------|-------------|
| Always-on | `HEARTBEAT.md` | Runs on every heartbeat poll (e.g., every 15 min) |
| Recurring | `CALENDAR.md` | `check-todos.sh` (cron) reads this and writes `READY` entries to `TODO.md` when an entry comes due |
| One-shot | `TODO.md` | Agent writes deferred tasks here; heartbeat executes and removes them |

`CALENDAR.md` is never modified at runtime. `TODO.md` is runtime state and is
gitignored.

### Scripts vs. LLM

Deterministic, procedural work belongs in Python scripts: paging through the
Gmail API, extracting email addresses, checking whether a contact exists. These
are fast, auditable, and consume no LLM tokens.

The LLM handles what it is actually good at: reading a sample of your sent
email and synthesising a writing-style guide, formatting a digest, deciding
whether a message is worth your attention, extracting names and phone numbers
from email signatures.

### Gmail and Contacts API access

Gmail and Contacts API calls are made directly via two stdlib-only Python
scripts (`gmail_api.py`, `contacts_api.py`) that use `urllib` — no pip
dependencies. OAuth is handled by
[gsuite-mcp](https://github.com/2389-research/gsuite-mcp) (Harper Reed), which
manages the browser consent flow and writes a standard Google OAuth2 token to
`~/.local/share/gsuite-mcp/token.json`. The agent scripts read that token
directly and refresh it automatically when it expires.

The Docker sandbox binds the token directory into the container at
`/tmp/.local/share/gsuite-mcp` (`HOME=/tmp` is set in the sandbox env). No
keyring daemon, no wrapper scripts.

---

## What you get

- **Daily digest** — email summarising inbox messages from known contacts
- **Contact hygiene** — recipients from sent mail added to Google Contacts
  automatically; name, phone, and org extracted from email signatures
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

## Note on GOG

An earlier version of this project used [GOG](https://github.com/steipete/gogcli)
as the Gmail CLI. GOG is a third-party command-line wrapper around a subset of
the Google APIs. It was a natural fit here because OpenClaw agents execute shell
commands — calling a CLI tool is simpler than embedding auth and HTTP code —
and GOG handles OAuth so you do not have to write any of that yourself.

The problem is that GOG's list command calls `threads.list`, which gives a
conversational view (one result per thread). This is a sensible choice for a
human browsing email, but `threads.list` returns the first message of each
thread regardless of search filters. A "sent mail" query silently returned
inbound messages rather than outbound replies, so contact harvesting never
worked. `messages.list` — which respects filters and returns individual messages
— exists in the Google API; GOG simply does not expose it.

gsuite-mcp uses `messages.list` because it was built for a different purpose:
giving an LLM access to individual messages. The two tools made different
choices appropriate to their intended use cases. Ours happened to require
`messages.list`, so we replaced GOG with direct API calls via `urllib`, using
the OAuth token that gsuite-mcp provisions.


---

## OpenClaw Context and Inference: What Operators Need to Know

**The 8 auto-loaded files.** On every inference call — every Slack message, every
heartbeat — OpenClaw reads exactly 8 named files from the agent workspace into the
system prompt: `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`,
`HEARTBEAT.md`, `BOOTSTRAP.md`, and `MEMORY.md`. No other files (runbooks,
templates, CALENDAR.md, etc.) are loaded automatically; the agent must explicitly
read them via tool call. The per-file budget is 20,000 characters; the total budget
across all 8 files is 150,000 characters. These limits are set in `openclaw.json`
under `agents.defaults.bootstrapMaxChars` and `agents.defaults.bootstrapTotalMaxChars`.

**Behavioral implication.** Hard rules — output formats, approval requirements,
channel hygiene — belong in the 8 auto-loaded files (preferably `SOUL.md` or
`IDENTITY.md`). If a format spec lives only in a template file, the agent will
ignore it whenever its session history contains examples of an older format.
The session replay (accumulated conversation history) can override written
instructions; the 8 auto-loaded files are the only reliable anchor.

**Prefill vs. generation — why TTFT is interactive.** The model runs at ~50
tokens/second, but that figure applies only to *output generation*. Input
processing (prefill) is parallel — the GPU computes attention for all input
tokens simultaneously as a single matrix operation, typically completing in
1–3 seconds for a normal agent context. Time To First Token equals prefill
time. Even a 150,000-character system prompt (~37,500 tokens) takes roughly
15–30 seconds to prefill, not the hours a naive calculation implies. The
actual latency risk is unbounded session history: OpenClaw replays the full
conversation on every call, and sessions that grow very large (hundreds of
thousands of tokens) produce multi-minute prefill times. Daily session resets
(see `spark-ai-agents/ARCHITECTURE.md`) address this.
