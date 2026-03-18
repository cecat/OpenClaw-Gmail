# SETUP.md — Adding the Gmail Agent to OpenClaw

## Prerequisites

- OpenClaw gateway running and reachable
- [gsuite-mcp](https://github.com/2389-research/gsuite-mcp) installed on the same host
- A Slack bot already created and its bot token available
- A Google account whose Gmail and Contacts you want to manage

---

## Step 1 — Google Cloud Project

The agent needs OAuth credentials to call the Gmail and People (Contacts) APIs.
Create these under the Google account you want to manage.

1. Open [console.cloud.google.com](https://console.cloud.google.com) **signed in
   as `YOUR_GMAIL_ADDRESS`**.
2. Create a new project: e.g. `MY-Gmail-Agent`.
3. **APIs & Services → Library** — enable:
   - Gmail API
   - Google People API (Contacts)
4. **APIs & Services → OAuth consent screen (Google Auth Platform → Audience)**
   - User type: **External**
   - App name: anything (e.g. `My Gmail Agent`)
   - Support email: `YOUR_GMAIL_ADDRESS`
   - Developer contact: `YOUR_GMAIL_ADDRESS`
   - Publishing status: leave as **Testing**
   - Test users → **+ Add users** → add `YOUR_GMAIL_ADDRESS`
5. **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
   - Application type: **Desktop app**

> **Credentials JSON:** The Google Cloud Console no longer has a direct JSON
> download button on the credentials list page. Either download from the edit
> page immediately after creating the client, or construct the file manually
> from the client ID and a freshly-created client secret:
> ```json
> {
>   "installed": {
>     "client_id": "YOUR_CLIENT_ID.apps.googleusercontent.com",
>     "project_id": "YOUR_PROJECT_ID",
>     "auth_uri": "https://accounts.google.com/o/oauth2/auth",
>     "token_uri": "https://oauth2.googleapis.com/token",
>     "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
>     "client_secret": "YOUR_CLIENT_SECRET",
>     "redirect_uris": ["http://localhost"]
>   }
> }
> ```

Save the file as `credentials.json`.

> **Why Testing mode?** For a personal agent you will never need to publish
> publicly. Testing mode with yourself as a test user is sufficient and avoids
> Google's app verification process.

---

## Step 2 — gsuite-mcp OAuth setup

[gsuite-mcp](https://github.com/2389-research/gsuite-mcp) handles the OAuth
browser flow and writes a standard token file that the agent scripts use.

### Install gsuite-mcp

```bash
# Install the Go binary (requires Go 1.21+)
go install github.com/2389-research/gsuite-mcp@latest
# or clone and build:
# git clone https://github.com/2389-research/gsuite-mcp && cd gsuite-mcp && go build -o gsuite-mcp .
```

### Copy credentials

```bash
mkdir -p ~/.config/gsuite-mcp
cp /path/to/credentials.json ~/.config/gsuite-mcp/credentials.json
```

If the server is headless (no browser), copy the credentials from your local
machine:
```bash
scp credentials.json yourserver:~/.config/gsuite-mcp/credentials.json
```

### Run the setup flow

```bash
gsuite-mcp setup
```

The command prints a URL. Open it in a browser on any machine, complete the
Google consent screen, then copy the `code=` value from the redirect URL
(even if the browser shows "can't connect" — the code is in the URL bar).
Paste the code back into the terminal.

On success:
```
Authentication successful! Token saved to ~/.local/share/gsuite-mcp/token.json
```

Verify:
```bash
gsuite-mcp whoami
# Should show your Gmail address and message count
```

The token at `~/.local/share/gsuite-mcp/token.json` is what the agent scripts
use. gsuite-mcp refreshes it automatically; the scripts also refresh it if
needed.

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
| `YOUR_DIGEST_EMAIL` | Where the daily digest is delivered (can be same as Gmail) |
| `YOUR_SLACK_USER_ID` | Your Slack user ID (`U`-prefixed, from Slack profile) |
| `YOUR_SLACK_CHANNEL_ID` | Channel ID for the agent (`C`-prefixed, from channel details) |

A quick way to do all substitutions at once:
```bash
cd ~/openclaw-workspace/YOUR_AGENT_ID/
grep -rl 'YOUR_' . | xargs sed -i \
  -e 's/YOUR_AGENT_ID/gmail-agent/g' \
  -e 's/YOUR_AGENT_NAME/Gmail-Agent/g' \
  -e 's/YOUR_NAME/Your Name/g' \
  -e 's/YOUR_GMAIL_ADDRESS/you@gmail.com/g' \
  -e 's/YOUR_DIGEST_EMAIL/you@gmail.com/g' \
  -e 's/YOUR_SLACK_USER_ID/U0XXXXXXXX/g' \
  -e 's/YOUR_SLACK_CHANNEL_ID/C0XXXXXXXX/g'
```

---

## Step 4 — Install scripts

Copy the scripts to a location on your host that survives reboots:

```bash
cp scripts/gmail_api.py scripts/contacts_api.py /usr/local/bin/gmail-agent/
cp scripts/check-todos.sh scripts/send-slack-posts.sh /usr/local/bin/gmail-agent/
chmod +x /usr/local/bin/gmail-agent/*.sh
```

Or any directory you prefer — just update the path in `PATHS.md` and the
runbooks to match.

---

## Step 5 — Update openclaw.json

Add the agent stanza from `openclaw/agent-block-example.json` to your
`openclaw.json` under `agents.list`.

The sandbox bind mounts needed for the agent scripts:

```json
"/home/YOU/.local/share/gsuite-mcp:/tmp/.local/share/gsuite-mcp:rw",
"/home/YOU/.config/gsuite-mcp:/tmp/.config/gsuite-mcp:ro",
"/usr/local/bin/gmail-agent:/scripts:ro"
```

The `rw` on the token directory allows the scripts to write a refreshed token.
`HOME` must be set to `/tmp` in the sandbox env so the scripts find the token
at the correct path.

Also add a binding to route your Slack channel to this agent:
```json
{
  "agentId": "YOUR_AGENT_ID",
  "match": { "channel": "slack", "peer": { "kind": "channel", "id": "YOUR_SLACK_CHANNEL_ID" } }
}
```

After editing, restart the gateway:
```bash
cd /path/to/openclaw && docker compose restart openclaw-gateway
```

---

## Step 6 — Crontab

Two cron entries are required:

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

If you use OpenClaw session seeding:
```cron
*/30 * * * * /path/to/seed-sessions.sh >> /path/to/shared/seed.log 2>&1
```

---

## Step 7 — Slack setup

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

## Step 8 — One-time sync

Trigger the initial 12-month contacts harvest and writing style analysis.
In Slack (in your agent's channel):

```
PLAN: /workspace/runbooks/RUNBOOK_ONETIME_SYNC.md
```

The agent will:
1. Check the guard flag (runs once only)
2. Harvest contacts from 12 months of sent mail
3. Collect received-mail contact candidates and extract name/phone/org from signatures
4. Analyse your writing style and update `writing-style.md`
5. DM you when complete

This may take 10–30 minutes depending on sent mail volume.

---

## Step 9 — Verify

```bash
# Confirm the token is readable from the sandbox path
cat ~/.local/share/gsuite-mcp/token.json | python3 -c "import json,sys; t=json.load(sys.stdin); print(t['access_token'][:20]+'...')"

# Manually trigger the daily digest
# In Slack:
PLAN: /workspace/runbooks/RUNBOOK_EMAIL_DIGEST.md
```

---

## Re-authentication

Tokens do not expire on a fixed schedule for apps in Testing mode, but if you
ever need to re-authorise:

```bash
gsuite-mcp setup
```
