# telegram-bridge — setup, troubleshooting & keeping the skill

## How it works (architecture)

```
Telegram app  ──►  Telegram Bot API  ◄── getUpdates (polling, every 2 min)
                                          │
                          launchd/cron ── tg-chat.sh
                                          │  claude -p --resume   (conversation memory)
                                          ▼
                                      your repo  ──►  sendMessage / sendVideo ──► Telegram
```

- **No webhook, no server.** The script *pulls* updates (`getUpdates`) and runs Claude locally, so
  it works behind NAT / a firewall with no public address — but it depends on your machine being
  awake.
- **Single consumer:** only `tg-chat.sh` reads messages (it advances the `offset`). Do not run two
  consumers against the same bot — they will "steal" each other's messages.
- **Half-duplex with a lock:** `.tg-bridge/.lock` ensures a single instance at a time; a long task
  blocks the next tick until it finishes.

## Files and their roles

| Path | git? | Role |
|---|---|---|
| `tools/tg-bridge/tg.py` | ✅ | Telegram helper (stdlib only) |
| `tools/tg-bridge/tg-chat.sh` | ✅ | The chat bridge |
| `tools/tg-bridge/tg-scheduled.sh` | ✅ | Scheduled-task runner |
| `tools/tg-bridge/prompt.md` | ✅ | System prompt / the repo's "work plan" |
| `tools/tg-bridge/launchd/*.plist` | ✅ | Source plists (with absolute paths) |
| `.env` | ❌ (gitignored) | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| `.tg-bridge/offset.txt` | ❌ | Last processed update_id |
| `.tg-bridge/session.txt` | ❌ | Claude session_id (memory). Delete = fresh conversation |
| `.tg-bridge/logs/` | ❌ | Logs |
| `.tg-bridge/.lock` | ❌ | Concurrency lock |
| `~/Library/LaunchAgents/<LABEL>.plist` | — | The installed copy launchd actually runs |

## Prerequisites — expanded

- **Machine awake + unlocked.** launchd only fires `StartInterval` while the system is awake. On
  macOS: System Settings → Lock Screen / Battery → enable "Prevent automatic sleeping when display
  is off", or run `caffeinate -s` in the background. A user session must be logged in (this is a
  LaunchAgent, not a LaunchDaemon).
- **Not in macOS protected folders.** `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive — TCC
  blocks background processes from reading these and the bot fails *silently*. Put the repo in
  `~/<repo>` or `~/code/<repo>`.
- **Claude Code installed.** `command -v claude`. If it lives only in `~/.local/bin` and isn't on
  the non-interactive shell's PATH, the script falls back to `$HOME/.local/bin/claude`. Force it
  with `CLAUDE_BIN`.
- **`.env` is loaded** by the script (`set -a; . ./.env`). Ensure no spaces around `=` and no
  unquoted special characters.

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| No reply at all | `launchctl list \| grep <LABEL>` — middle column should be `0`. `126` = run problem (below). |
| exit **126** | ProgramArguments must be `/bin/bash` `-l` `<script>` as three separate `<string>`s. **Not** `-lc`. |
| Loaded but silent | Read `.tg-bridge/logs/chat.err.log` and `chat_*.err`. Usually wrong token/chat_id, or TCC. |
| "claude: command not found" in log | Set `CLAUDE_BIN` to the full path, or add it to PATH in `~/.zprofile`. |
| Bot replays old messages | Delete `.tg-bridge/offset.txt` — it re-baselines to "now" on the next run. |
| Claude "forgot" context / stuck | Delete `.tg-bridge/session.txt` (fresh conversation). |
| Two replies per message | More than one instance/consumer is running. Keep only one agent loaded. |
| Stuck on "working on this" | A long run holds `.lock`. Check for a live `claude` process; if hung, `rmdir .tg-bridge/.lock`. |

**Reload after editing a script/plist:**
```
launchctl unload ~/Library/LaunchAgents/<LABEL>.plist
launchctl load  -w ~/Library/LaunchAgents/<LABEL>.plist
```
(Make sure no run is active — `.tg-bridge/.lock` absent — before editing.)

## Security

- The bridge runs Claude with `--dangerously-skip-permissions`. **Any message in your chat = running
  commands on the repo without approval.** `tg.py` filters by `TELEGRAM_CHAT_ID` — only your messages
  are processed.
- Don't share the bot or add it to groups. Never commit `.env` (GitHub secret scanning will burn the
  token). If a token leaks — `/revoke` in @BotFather and issue a new one.
- The `prompt.md` instructs treating public-facing output as a draft awaiting approval; strengthen
  this per repo.

## Linux (instead of launchd)

**cron:**
```
crontab -e
*/2 * * * * /bin/bash -l /path/to/repo/tools/tg-bridge/tg-chat.sh >> /path/to/repo/.tg-bridge/logs/cron.log 2>&1
30 8 * * *  /bin/bash -l /path/to/repo/tools/tg-bridge/tg-scheduled.sh "summarize the repo status" >> /path/to/repo/.tg-bridge/logs/sched.log 2>&1
```
**systemd:** create `tg-chat.service` (Type=oneshot running the script) + `tg-chat.timer`
(`OnUnitActiveSec=120`), then `systemctl --user enable --now tg-chat.timer`. Note:
`loginctl enable-linger <user>` so it runs without an active session.

---

## Keeping / porting the skill

The skill is **one self-contained folder** (`SKILL.md` + `templates/` + `reference/`). Copy it and
you're done. Three ways:

### 1. Global / personal skill — available in every repo on the machine (recommended)
```
git clone https://github.com/shmilson/claude-telegram-bridge ~/.claude/skills/telegram-bridge
```
From then on `/telegram-bridge` works in any folder you open Claude Code in, independent of any repo.

### 2. Project skill — travels with a repo via git
Keep it at `<repo>/.claude/skills/telegram-bridge/` and `git add` it. Everyone who clones the repo
gets the skill.

### 3. Moving between machines
- Via git: if it's a repo (way 1/2), it already travels with `git clone`/`pull`.
- Manually: copy the folder (zip/AirDrop/scp) into `~/.claude/skills/` on the target machine.
- **`.env` does NOT travel** (gitignored, by design). On a new machine/repo you re-enter the token +
  chat id in Step 1.

### Updating a version
This is a plain folder — edit `templates/*` and `SKILL.md`, sync again (clone/pull/cp). A change to
`templates/tg-chat.sh` does **not** retroactively affect already-connected repos (they run their own
copy under `tools/tg-bridge/`) — copy it there again and `launchctl` reload.
