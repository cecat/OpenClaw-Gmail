# OpenClaw Gmail Agent

A drop-in agent for [OpenClaw](https://openclaw.ai) that manages a Gmail inbox,
Google Calendar, and Google Contacts on your behalf. It triages email, delivers
a daily digest, maintains a contacts list from your sent mail, and learns your
writing style so it can draft replies for your approval.

---

## Architecture

### 1. Sandboxing

Each agent runs in an isolated Docker container (sandbox) with explicit bind
mounts. The agent can only read or write paths you explicitly grant — its own
workspace, a shared directory, and specific credential files. Nothing else on
the host is accessible. This limits blast radius if the agent misbehaves and
makes it easy to audit exactly what it can touch.

### 2. Scheduling — three tiers

| Tier | File | How it fires |
|------|------|-------------|
| Always-on | `HEARTBEAT.md` | Runs on every heartbeat poll (e.g., every 15 min) |
| Recurring | `CALENDAR.md` | `check-todos.sh` (cron) reads this and writes `READY` entries to `TODO.md` when an entry comes due |
| One-shot | `TODO.md` | Agent writes deferred tasks here; heartbeat executes and removes them |

`CALENDAR.md` is never modified at runtime — it is the standing schedule set by
the human. `TODO.md` is runtime state and is gitignored.

### 3. Scripts vs. LLM

Deterministic work belongs in shell/Python scripts: paging through the Gmail
API, extracting email addresses, checking whether a contact exists, writing
JSON files. These are fast, auditable, and do not consume LLM tokens.

The LLM handles what it is actually good at: reading a sample of your sent
email and synthesising a writing-style guide, formatting a digest, deciding
whether a message is important. The scripts produce structured data (JSONL);
the LLM reads it and generates natural language output.

---

## What you get

- **`@agent` email commands** — send email to yourself with `@YOUR_AGENT_ID` in
  the subject line to queue tasks for the agent from anywhere
- **Daily digest** — email to your preferred address summarising inbox messages
  from known contacts
- **Contact hygiene** — recipients from your sent mail are added to Google
  Contacts automatically, with filtering to exclude mailing lists and automated
  senders
- **Writing style learning** — the agent analyses your sent mail and maintains a
  style guide it uses when drafting replies
- **Monthly style refresh** — the style guide is updated from the past 30 days
  of sent mail

---

## Repository layout

```
agent/          Drop-in workspace — copy this into your OpenClaw agents directory
  runbooks/     Step-by-step procedures the LLM follows
scripts/        Deterministic shell/Python scripts (no LLM)
openclaw/       Example openclaw.json agent stanza
```

## Quick start

See [SETUP.md](SETUP.md) for the full step-by-step.

---

## Related work

[Harper Reed](https://harperreed.com)'s
[GSuite MCP Server](https://github.com/2389-research/gsuite-mcp) takes a
different and complementary approach: it exposes Gmail, Calendar, Contacts, and
Tasks as native MCP tools that an LLM can call directly, without any shell
scripting layer in between. It is well-engineered, fast (Go), and covers
considerably more of the Google Workspace surface area than this project does.

The philosophy here is deliberately narrower. Bulk operations — paging through
hundreds of sent messages, filtering addresses, counting frequencies, checking
contact existence — are handled by plain shell/Python scripts that run
deterministically, produce no surprises, and consume no LLM tokens. The LLM is
only invoked for tasks that genuinely require language understanding: analysing
writing style, formatting a digest, deciding what is worth your attention.

**gsuite-mcp may suit you better if:**
- You want a faster path to a working assistant with minimal scripting
- Your use cases are mostly interactive (compose, reply, schedule) rather than
  bulk or scheduled
- You prefer to let the model handle API orchestration directly rather than
  wrapping it in scripts

**This approach may suit you better if:**
- You are running scheduled, unattended workloads (daily digests, contact
  harvests) where reliability and cost matter more than flexibility
- You want auditability — every API call is in a readable bash or Python script
  you can inspect, test, and fix independently of the LLM
- You are sensitive to inference cost today

The two approaches share the same underlying assumption: models are improving
rapidly, and the operational cost of calling them will continue to fall. The
difference is tactical, not philosophical. The scripting layer here is a
present-day choice — optimising for reliability and cost right now — not a
claim that it will always be the right architecture.

There is also a conceptual parallel worth noting. The scripts in this project
are effectively tools: the agent decides what to do, calls a script, and
receives structured output — the same pattern as MCP tool-calling, just
implemented in bash and Python rather than as a registered MCP server. A common
pattern in multi-agent OpenClaw deployments is to decompose work across highly
specialised agents — one agent manages contacts, another handles writing-style
capture, another reads and triages email. This project takes the same
decomposition idea but applies it within a single agent: rather than spawning a
separate contacts agent, the agent calls a contacts management script. The
three-tier scheduling system (HEARTBEAT / CALENDAR / TODO) follows the same
logic — a deterministic external clock handles *when*, the model handles *what*
— and that separation is likely to remain a sound design regardless of how
capable models become.
