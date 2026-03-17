# SETUP.md — Adding the Gmail Agent to OpenClaw

## Prerequisites

- OpenClaw gateway running and reachable
- [GOG CLI](https://github.com/toqueteos/gog) installed on the same host
- A Slack bot already created and its bot token available
- A Google account whose Gmail/Calendar/Contacts you want to manage

---

## Step 1 — Google Cloud Project

The agent needs OAuth credentials to call the Gmail, Contacts, and Calendar APIs.
You must create these under the Google account you want to manage so that account
is the project owner and can always authorise its own app.

1. Open [console.cloud.google.com](https://console.cloud.google.com) **signed in
   as `YOUR_GMAIL_ADDRESS`** (important — owner avoids test-user restrictions).
2. Create a new project: e.g. `MY-Gmail-Agent`.
3. **APIs & Services → Library** — enable:
   - Gmail API
   - Google People API (Contacts)
   - Google Calendar API
4. **APIs & Services → OAuth consent screen (Google Auth Platform → Audience)**
   - User type: **External**
   - App name: anything (e.g. `My Gmail Agent`)
   - Support email: `YOUR_GMAIL_ADDRESS`
   - Developer contact: `YOUR_GMAIL_ADDRESS`
   - Publishing status: leave as **Testing**
   - Test users → **+ Add users** → add `YOUR_GMAIL_ADDRESS`
5. **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
   - Application type: **Desktop app**
   - Download the JSON → save as e.g. `credentials.json`

> **Why Testing mode?** For a personal agent you will never need to publish the
> app publicly. Testing mode with yourself as a test user is sufficient and
> avoids Google's app verification process.

---

## Step 2 — GOG authentication

GOG is a Google API CLI that manages OAuth tokens in the system keyring.

```bash
# Register your credentials file under a named client
gog auth credentials set /path/to/credentials.json --client gmail-agent

# Verify
gog auth credentials list

# Authorise — this opens a browser URL
gog auth add YOUR_GMAIL_ADDRESS \
  --client gmail-agent \
  --services gmail,contacts,calendar \
  --manual --force-consent
# Paste the redirect URL back when prompted
```

> **Headless servers:** use `--manual` — GOG prints a URL, you open it in a
> browser on any machine, then paste the redirect URL back into the terminal.

> **Keyring on servers:** if your server has no keyring daemon, configure GOG to
> use a file-based keyring:
> ```bash
> gog config set keyring.backend file
> gog config set keyring.password YOUR_KEYRING_PASSWORD
> # Or set GOG_KEYRING_BACKEND=file and GOG_KEYRING_PASSWORD env vars
> ```

Verify the token was stored:
```bash
gog auth list
# Should show: YOUR_GMAIL_ADDRESS  gmail-agent  gmail,contacts,calendar
```

---

## Step 3 — Copy the agent workspace

```bash
# Assuming your OpenClaw workspace is at ~/openclaw-workspace/
cp -r agent/ ~/openclaw-workspace/YOUR_AGENT_ID/
```

Edit every file in `YOUR_AGENT_ID/` and replace the placeholders:

| Placeholder | Replace with |
|-------------|-------------|
| `YOUR_AGENT_ID` | Your chosen agent identifier (e.g. `gmail-agent`) |
| `YOUR_AGENT_NAME` | Display name (e.g. `Gmail-Agent`) |
| `YOUR_NAME` | Your name |
| `YOUR_GMAIL_ADDRESS` | The Gmail account being managed |
| `YOUR_SLACK_USER_ID` | Your Slack user ID (`U`-prefixed, from Slack profile) |
| `YOUR_SLACK_CHANNEL_ID` | Channel ID for the agent (`C`-prefixed, from channel details) |
| `YOUR_GOG_CLIENT_NAME` | The `--client` name you used in Step 2 (e.g. `gmail-agent`) |

A quick way to do all substitutions at once:
```bash
cd ~/openclaw-workspace/YOUR_AGENT_ID/
grep -rl 'YOUR_' . | xargs sed -i \
  -e 's/YOUR_AGENT_ID/gmail-agent/g' \
  -e 's/YOUR_AGENT_NAME/Gmail-Agent/g' \
  -e 's/YOUR_GMAIL_ADDRESS/you@gmail.com/g' \
  -e 's/YOUR_SLACK_USER_ID/U0XXXXXXXX/g' \
  -e 's/YOUR_SLACK_CHANNEL_ID/C0XXXXXXXX/g' \
  -e 's/YOUR_GOG_CLIENT_NAME/gmail-agent/g'
```

---

## Step 4 — Install scripts

Copy the scripts to a location on your host that survives reboots:

```bash
cp scripts/*.sh scripts/*.py /usr/local/bin/gmail-agent/
chmod +x /usr/local/bin/gmail-agent/*.sh
```

Or any directory you prefer — just update the path references in `PATHS.md`
and the runbooks to match.

---

## Step 5 — Update openclaw.json

Add the agent stanza from `openclaw/agent-block-example.json` to your
`openclaw.json` under `agents.list`.

At minimum you need:
```json
{
  "id": "YOUR_AGENT_ID",
  "workspace": "/path/to/YOUR_AGENT_ID",
  "heartbeat": { "every": "15m" }
}
```

> **Sandbox (recommended):** The example JSON in `openclaw/agent-block-example.json`
> shows a full sandbox configuration with explicit bind mounts for GOG credentials,
> the scripts directory, and the shared directory. See that file for details.
> If you use a different sandbox approach or none at all, adjust accordingly.

Also add a binding to route your Slack channel to this agent:
```json
{
  "agentId": "YOUR_AGENT_ID",
  "match": { "channel": "slack", "peer": { "kind": "channel", "id": "YOUR_SLACK_CHANNEL_ID" } }
}
```

And allow the channel:
```json
"YOUR_SLACK_CHANNEL_ID": { "allow": true, "requireMention": false }
```

After editing, restart the gateway:
```bash
cd /path/to/openclaw && docker compose restart openclaw-gateway
```

---

## Step 6 — Set up GOG keyring wrapper (sandbox only)

If running the agent in a Docker sandbox, the container runs as a different user
and cannot access the host keyring daemon. Use a file-based keyring with a
wrapper script:

```bash
# Store the keyring password
mkdir -p ~/.config/gogcli
echo "YOUR_KEYRING_PASSWORD" > ~/.config/gogcli/.gog_pw
chmod 600 ~/.config/gogcli/.gog_pw

# Create wrapper
mkdir -p ~/.local/bin
cat > ~/.local/bin/gog-wrap << 'EOF'
#!/bin/sh
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw 2>/dev/null)
export HOME=/tmp
exec /usr/local/bin/gog-real "$@"
EOF
chmod +x ~/.local/bin/gog-wrap
```

Then add these bind mounts in your agent's sandbox config:
```json
"/home/YOU/.config/gogcli:/tmp/.config/gogcli:rw",
"/home/YOU/.local/share/keyrings:/tmp/.local/share/keyrings:rw",
"/usr/local/bin/gog:/usr/local/bin/gog-real:ro",
"/home/YOU/.local/bin/gog-wrap:/usr/local/bin/gog:ro"
```

And these env vars:
```json
"GOG_KEYRING_BACKEND": "file",
"GOG_ACCOUNT": "YOUR_GMAIL_ADDRESS",
"GOG_CLIENT": "YOUR_GOG_CLIENT_NAME",
"HOME": "/tmp"
```

---

## Step 7 — Crontab

Two cron entries are required regardless of sandbox setup:

```bash
crontab -e
```

Add:
```cron
TZ=America/Chicago

# Scheduling engine — reads CALENDAR.md, writes READY entries to TODO.md
*/5 * * * * /usr/local/bin/gmail-agent/check-todos.sh >> /path/to/shared/todos/cron.log 2>&1

# Slack outbox delivery — posts pending JSON files to Slack
*/5 * * * * /usr/local/bin/gmail-agent/send-slack-posts.sh >> /path/to/shared/send-slack.log 2>&1
```

> **Timezone:** `check-todos.sh` evaluates CALENDAR.md times in UTC. Set your
> cron timezone to match your preferred reference timezone, or write all
> CALENDAR.md times in UTC explicitly.

If you use OpenClaw session seeding (recommended — ensures heartbeat sessions
survive gateway restarts):
```cron
*/30 * * * * /path/to/seed-sessions.sh >> /path/to/shared/seed.log 2>&1
```

---

## Step 8 — Slack setup

1. Invite your bot to the channel: `/invite @YOUR_BOT_NAME`
2. Get the channel ID: right-click channel → View channel details → bottom of About tab
3. Get your user ID: click your name in Slack → profile → three-dot menu → Copy member ID

Store your Slack bot token for `send-slack-posts.sh`:
```bash
mkdir -p ~/.config/slack
echo "xoxb-YOUR-BOT-TOKEN" > ~/.config/slack/bot_token
chmod 600 ~/.config/slack/bot_token
```

---

## Step 9 — One-time sync

Trigger the initial 12-month contacts harvest and writing style analysis.
In Slack (in your agent's channel):

```
PLAN: /workspace/runbooks/RUNBOOK_ONETIME_SYNC.md
```

The agent will:
1. Check the guard flag (runs once only)
2. Harvest contacts from 12 months of sent mail
3. Collect a sample of sent emails for style analysis
4. Analyse your writing style and update `writing-style.md`
5. DM you when complete

This may take 10–30 minutes depending on sent mail volume.

---

## Step 10 — Verify

```bash
# Confirm GOG can reach Gmail
gog gmail list --client gmail-agent -a YOUR_GMAIL_ADDRESS

# Manually trigger the daily digest
# In Slack:
PLAN: /workspace/runbooks/RUNBOOK_EMAIL_DIGEST.md
```

---

## Re-authentication

Tokens do not expire on a fixed schedule for apps in Testing mode, but if you
ever need to re-authorise:

```bash
gog auth add YOUR_GMAIL_ADDRESS \
  --client gmail-agent \
  --services gmail,contacts,calendar \
  --manual --force-consent
```
