---
name: telegram-bridge
description: Connect ANY git repo to a Telegram bot as a full Claude Code chat bridge — you message the bot, Claude Code acts on the repo (with conversation memory) and replies, plus optional scheduled tasks that report to Telegram. Portable across repos and machines. Use when the user wants to "connect a/the repo to Telegram", "set up a Telegram bot for this project", "chat with Claude Code over Telegram", or schedule tasks that ping Telegram. Also triggers on Hebrew such as "לחבר לטלגרם", "בוט טלגרם", "צ'אט עם קלוד בטלגרם". Requires the host machine awake + unlocked and Claude Code installed. NOT for sending marketing content to end-users.
---

# Telegram ↔ Claude Code Bridge

Goal: connect **any repo** to a Telegram bot so you can message the bot from anywhere and Claude
Code acts on the repo (with conversation memory) and replies — plus optional scheduled tasks that
report to Telegram. Everything runs locally on the user's machine; no server, no cloud.

This is an **interactive skill: you perform the wiring, not just explain it.** Match the language
the user speaks to you in.

## Step 0 — Explain briefly + check prerequisites (required, before any action)

Tell the user in one short pass what will happen, and confirm these hold:

1. **The machine must be awake and unlocked** when the bot should respond. The background job
   (launchd/cron) does not run while the machine sleeps. Recommend: System Settings → Lock Screen /
   Battery → "Prevent automatic sleeping when display is off" (or run `caffeinate`).
2. **Claude Code is installed** and reachable from the shell (`command -v claude`). If not, stop and
   have the user install it.
3. **The repo is NOT under `~/Desktop` / `~/Documents` / `~/Downloads` / iCloud Drive on macOS.**
   TCC silently blocks background processes there and the bot will fail quietly. If it is, recommend
   moving it (e.g. to `~/<repo>`).
4. **A Telegram bot + chat id.** If the user already has one, reuse it. Otherwise create one (Step 1).
5. **Security awareness:** the bridge runs Claude with `--dangerously-skip-permissions`, so **any
   message in your chat can run commands on the repo**. It is filtered to your chat id only, and the
   token lives in `.env` (gitignored). Make sure the user understands this.

Platform details, troubleshooting, and how to keep/port the skill: `reference/SETUP.md` — read it
before installing.

## Step 1 — Token + Chat ID

First check whether `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` already exist in the repo's `.env`
(or another repo the user points at). If so, confirm you'll reuse them.

To create a new bot (the user does this in the Telegram app, not you):
1. Open a chat with **@BotFather** → `/newbot` → give a name + username → receive the **token**.
2. Send any message to the new bot (so there's an update to read).
3. Discover the chat id (after the token is set):
   `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([m.get("message",{}).get("chat",{}).get("id") for m in d["result"]])'`
   The chat id is the number shown (a private chat is a positive integer).

## Step 2 — Install the files into the repo

With `<REPO>` = absolute repo root:

1. Create `<REPO>/tools/tg-bridge/` and copy from `templates/`: `tg.py`, `tg-chat.sh`,
   `tg-scheduled.sh`, `prompt.md`. `chmod +x` the `.sh` files and `tg.py`.
2. **`.env`:** add/verify `TELEGRAM_BOT_TOKEN=...` and `TELEGRAM_CHAT_ID=...`. Create `.env` if
   missing. Ensure `.env` is in `.gitignore`. **Never commit the token.**
3. **`.gitignore`:** add `.tg-bridge/` (runtime state: offset, session, logs, lock — not committed).
   Files under `tools/tg-bridge/` are committed (code + prompt).

## Step 3 — Tailor the repo's "work plan"

Edit `<REPO>/tools/tg-bridge/prompt.md` — the system prompt prepended to every message. This is
where you adapt the bot to the repo: its role, which skills/tools to prefer, tone/values rules, and
what counts as "a draft needing approval". Ask the user what this bot is for in this repo and write
it there. (The default is generic and fine to start with.)

## Step 4 — Install the scheduler

### macOS (launchd) — recommended
1. Take `templates/launchd/chat.plist.template`, replace `__REPO__` with the repo root and
   `__LABEL__` with a unique label (e.g. `com.<user>.<repo>.tg-chat`).
2. Save it to `<REPO>/tools/tg-bridge/launchd/<LABEL>.plist` AND copy to
   `~/Library/LaunchAgents/<LABEL>.plist`.
3. Load: `launchctl load -w ~/Library/LaunchAgents/<LABEL>.plist`
4. Verify: `launchctl list | grep <LABEL>` — the middle column must be `0` (not `126`).
   **Important:** ProgramArguments must be `/bin/bash -l <script>` (with `-l`, no `-c` — `-lc`
   causes exit 126).

### Linux (cron)
`crontab -e` and add: `*/2 * * * * /bin/bash -l <REPO>/tools/tg-bridge/tg-chat.sh >> <REPO>/.tg-bridge/logs/cron.log 2>&1`

## Step 5 — Verify

1. Ask the user to send a test message to the bot (e.g. "test, who are you?").
2. Within ~2 minutes the bot should reply "✓ Got it — working on this…" and then the answer.
3. If nothing comes, check `<REPO>/.tg-bridge/logs/chat*.log` and `launchctl list | grep <LABEL>`
   (see troubleshooting in `reference/SETUP.md`).

## Optional — scheduled tasks

To run a one-shot task on a schedule (e.g. "every morning summarize X and message me"):
1. `tg-scheduled.sh "<PROMPT>"` runs a single prompt (no conversation memory) and sends the output
   to Telegram.
2. Use `templates/launchd/scheduled.plist.template` (with `StartCalendarInterval`), replace
   `__REPO__`, `__LABEL__`, `__PROMPT__`, `__HOUR__`, `__MINUTE__`, install and load as in Step 4.

## Operational notes

- **Chat commands:** `/new` (or `/reset`, `/clear`) starts a fresh conversation — deletes the
  session so `--resume` context stops growing. Handled locally, no Claude call. This is the cheapest
  way to keep token usage down on a long-lived bot.
- **Response latency** ~1–2 min (poll interval + Claude startup). Lower `StartInterval` to speed up.
- **Concurrency lock:** `tg-chat.sh` holds `.tg-bridge/.lock` so only one instance runs at a time
  (a long task isn't clobbered). Before editing + reloading, make sure no run is active (the lock is
  absent).
- **Reload after editing a script/plist:** `launchctl unload ... && launchctl load -w ...`.
