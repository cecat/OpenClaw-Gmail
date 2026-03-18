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

## Agent Context, Inference, and Behavioral Reliability

### What the agent sees on every call

Every inference call — every Slack message, every heartbeat — sends two things
to the model: a freshly rebuilt **system prompt** and the full **session history**
(the accumulated conversation replay from the agent's `.jsonl` session file).

The system prompt is assembled from exactly 8 named workspace files on every call:
`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`,
`BOOTSTRAP.md`, and `MEMORY.md`. No other files are loaded automatically —
runbooks, templates, `CALENDAR.md`, and similar files are invisible to the model
unless the agent explicitly reads them via tool call. OpenClaw enforces a per-file
budget of 20,000 characters and a total system-prompt budget of 150,000 characters,
configured in `openclaw.json` under `agents.defaults.bootstrapMaxChars` and
`agents.defaults.bootstrapTotalMaxChars`.

Session history has no equivalent hard cap. It grows with every interaction until
the session is reset. Both the system prompt and the session history are sent to
the model on every call — the model weighs them together, not in isolation.

### Behavioral reliability and change propagation

Not all changes to agent files take effect with equal speed or certainty:

| Where the change is made | When the agent sees it | Reliability |
|---|---|---|
| One of the 8 system-prompt files | Next inference call — system prompt is rebuilt | High, but session history can override |
| Non-auto-loaded file (`EMAIL.md`, templates, etc.) | Only when the agent explicitly reads it again | Indeterminate — may never happen |
| A RUNBOOK | Read fresh from disk on every trigger | Reliable — no caching between runs |
| Session history (examples of old behavior) | Every call, until session is reset | Works against you |

RUNBOOKs are the most reliable vehicle for procedural changes: they are read
explicitly at trigger time and not held in memory between runs. The problem with
rules is different from the problem with procedures. Getting a new rule into the
system prompt (by editing one of the 8 files) is necessary but not sufficient —
the model simultaneously reads session history that may contain many examples of
the old behavior, and example-weight often beats instruction-weight in practice.

**Hard behavioral rules** — output formats, approval requirements, channel hygiene
— belong in the 8 system-prompt files (preferably `SOUL.md` or `IDENTITY.md`), not
in secondary files. When a rule lives only in a template file, the agent will tend
to ignore it once its session history contains enough examples of older behavior.

**To lock in a change immediately:** edit the relevant file, then truncate the
agent's session `.jsonl` to remove accumulated examples of old behavior:

```bash
docker exec openclaw-gateway truncate -s 0   /home/node/.openclaw/agents/<agent-id>/sessions/main.jsonl
```

If the changed rule is in a non-auto-loaded file, also DM the agent to re-read
it in the fresh session. Verify the next execution follows the new rule; do not
assume the change took effect.

### Prefill vs. generation — why TTFT stays interactive

LLM inference has two phases with very different speeds. When operators first see
that an agent context can reach tens of thousands of tokens, and the model is
running at, say, 50 tokens/second, it is natural to worry: does a 40,000-token
context mean 800 seconds before the first response? No — because that tokens/second
figure applies only to *output generation*, not to input processing.

**Phase 1 — Prefill (input).** All input tokens — system prompt, session history,
new message — are processed *in parallel* as a single matrix operation across the
GPU. The GPU computes attention for every position simultaneously, fully saturating
its parallel compute. A typical agent context of 10,000–40,000 tokens prefills in
roughly **1–10 seconds** on modern hardware, largely independent of context size
within that range. Time To First Token equals prefill time: the user sees the first
output token as soon as prefill completes.

**Phase 2 — Generation (output).** Each output token depends on the previous one,
so generation is sequential. The GPU loads the full model weight matrix from memory
on every step — a memory-bandwidth-bound operation. This is what people quote as
"inference speed" (e.g. 50 tokens/second), and it applies only to output. A
200-token response takes a few seconds to generate regardless of how large the
input context was.

| Phase | Mechanism | Typical speed | Time for a normal exchange |
|---|---|---|---|
| Prefill (input) | Parallel GPU matrix ops | Thousands of tokens/sec | 1–10 seconds |
| Generation (output) | Sequential, memory-bandwidth-bound | Tens to low hundreds of tokens/sec | 2–10 seconds |

Even a slower model running at only a few dozen tokens/second output remains fully
interactive for agents, because TTFT is set by the fast parallel prefill — not by
generation speed. The 150,000-character system-prompt budget OpenClaw supports
corresponds to roughly 37,500 tokens; at typical prefill speeds this adds seconds,
not minutes, to the first response.

The genuine latency risk is **unbounded session history**. Unlike the system prompt
(bounded by the 150K budget), session history grows without a hard cap and is
replayed in full on every call. Sessions that accumulate hundreds of thousands of
tokens will produce multi-minute prefill times on any hardware. This is why daily
session resets are part of the recommended operating procedure: not to reduce system
prompt size, but to prevent session history from growing into a latency problem.
