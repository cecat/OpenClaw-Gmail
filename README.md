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
