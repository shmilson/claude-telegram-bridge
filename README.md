# claude-telegram-bridge

Connect **any git repo** to a Telegram bot as a full [Claude Code](https://claude.com/claude-code)
chat bridge. You message the bot from anywhere; Claude Code acts on the repo (with conversation
memory) and replies. Optional scheduled tasks report back to Telegram too.

It's packaged as a **Claude Code skill** — invoke `/telegram-bridge` and Claude walks you through
the setup *and performs the wiring for you*.

```
Telegram app  ──►  Telegram Bot API  ◄── getUpdates (polling, every 2 min)
                                          │
                          launchd/cron ── tg-chat.sh
                                          │  claude -p --resume   (conversation memory)
                                          ▼
                                      your repo  ──►  sendMessage / sendVideo ──► Telegram
```

## Why

- **No server, no webhook, no cloud.** The bridge *polls* Telegram and runs Claude locally, so it
  works behind NAT / a firewall with no public address.
- **Full agent, not a command menu.** Every message is a prompt to Claude Code with full repo
  access and conversation memory — ask questions, request edits, or kick off long jobs.
- **Portable.** One self-contained folder. Drop it into any repo or install it globally.

## Requirements

- **The host machine must be awake and unlocked** when you expect a reply. The background job
  (launchd/cron) does not run while the machine sleeps.
- **Claude Code installed** and reachable from the shell (`command -v claude`).
- **macOS:** keep the repo out of `~/Desktop`, `~/Documents`, `~/Downloads`, and iCloud Drive —
  macOS TCC silently blocks background processes from those folders. Use `~/<repo>` instead.
- A Telegram bot **token** + your **chat id** (the skill helps you create them).

## Quick start (with Claude Code)

```bash
# Install as a global skill (available in every repo on this machine):
git clone https://github.com/shmilson/claude-telegram-bridge ~/.claude/skills/telegram-bridge
```

Then, inside the repo you want to connect, run `/telegram-bridge` in Claude Code and follow the
steps. It will: check prerequisites → get/create the bot token + chat id → install the files into
`tools/tg-bridge/` → customize the per-repo prompt → install and load the scheduler → verify with a
test message.

## Manual install (no skill runner)

1. Copy `templates/` into your repo as `tools/tg-bridge/` and `chmod +x` the `.sh` + `tg.py`.
2. Add `TELEGRAM_BOT_TOKEN=...` and `TELEGRAM_CHAT_ID=...` to the repo's `.env` (gitignored).
3. Add `.tg-bridge/` to `.gitignore`.
4. Edit `tools/tg-bridge/prompt.md` to describe what the bot is for in this repo.
5. **macOS:** fill `__REPO__` / `__LABEL__` in `templates/launchd/chat.plist.template`, save it to
   `~/Library/LaunchAgents/<LABEL>.plist`, then
   `launchctl load -w ~/Library/LaunchAgents/<LABEL>.plist`.
   **Linux:** add a cron line — see [`reference/SETUP.md`](reference/SETUP.md).
6. Send the bot a message; within ~2 minutes it acknowledges and replies.

## Chat commands

Send `/new` (or `/reset`, `/clear`) to start a fresh conversation. It drops the resumed session so
context stops accumulating, which is the main token cost of a long-lived bot. Handled locally with
no Claude call.

## Scheduled tasks

`tools/tg-bridge/tg-scheduled.sh "<prompt>"` runs a one-shot Claude task and sends the result to
Telegram. Wire it to a launchd `StartCalendarInterval` (template provided) or a cron line for
"every morning summarize X and message me".

## Security

The bridge runs Claude with `--dangerously-skip-permissions`, so **any message in your chat can run
commands on the repo without a prompt.** `tg.py` filters strictly to your `TELEGRAM_CHAT_ID`, so
only your messages are processed. Never share the bot or add it to groups, never commit `.env`, and
if a token leaks, `/revoke` it in @BotFather and issue a new one.

## What's in here

| Path | Role |
|---|---|
| `SKILL.md` | The Claude Code skill: the interactive install procedure |
| `reference/SETUP.md` | Architecture, troubleshooting, security, Linux, how to keep/port the skill |
| `templates/tg.py` | Telegram helper (stdlib only — no dependencies) |
| `templates/tg-chat.sh` | The chat bridge |
| `templates/tg-scheduled.sh` | Scheduled-task runner |
| `templates/prompt.md` | Per-repo system prompt (the "work plan") |
| `templates/launchd/*.template` | macOS scheduler templates |

## License

GPL-3.0. See [`LICENSE`](LICENSE).
