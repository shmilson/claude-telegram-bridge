#!/usr/bin/env bash
# Telegram <-> Claude Code chat bridge (portable, single Telegram consumer).
#
# Every new message from your chat is forwarded to Claude Code (with conversation
# memory via --resume); Claude acts on THIS repo and its final reply is sent back
# to Telegram. Filtered to your chat id only (tg.py enforces it).
#
# Runs on an interval (launchd/cron). Exits instantly when there's nothing new,
# so it is cheap to leave running all day.
set -euo pipefail

# --- Locate repo + tooling (portable: repo is two levels above this script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${TG_BRIDGE_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
command -v claude >/dev/null 2>&1 && CLAUDE_BIN="claude"

cd "$REPO"
[ -f .env ] && { set -a; . ./.env; set +a; }
PY="$REPO/.venv/bin/python"; [ -x "$PY" ] || PY="python3"
TG="$SCRIPT_DIR/tg.py"

STATE="$REPO/.tg-bridge"; LOG="$STATE/logs"; mkdir -p "$LOG"
OFF="$STATE/offset.txt"; SESS="$STATE/session.txt"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"

DEFAULT_PROMPT="You are connected to this repository over Telegram. A message from the user follows. Act on it using full access to the repo and its skills; be concise. Treat any public-facing output as a draft awaiting the user's approval. Do NOT send your text reply yourself — the runner sends your final output to Telegram."

# One dispatcher at a time (a long task can take minutes).
LOCK="$STATE/.lock"; mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# First run: baseline to "now" so we don't replay old history.
[ -f "$OFF" ] || "$PY" "$TG" get-offset > "$OFF" 2>>"$LOG/chat.err"
SINCE="$(cat "$OFF")"

UPD="$("$PY" "$TG" updates "$SINCE" 2>>"$LOG/chat.err")" || exit 0
MAX="$(printf '%s' "$UPD" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["max"])')"
"$PY" - "$UPD" > "$STATE/.chat-msgs.txt" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
for m in d["messages"]:
    print(m["text"].replace("\r", " ").replace("\n", " ").strip())
PYEOF
COUNT="$(grep -c . "$STATE/.chat-msgs.txt" || true)"
if [ "${COUNT:-0}" = 0 ]; then printf '%s' "$MAX" > "$OFF"; exit 0; fi

SYS="$( [ -f "$PROMPT_FILE" ] && cat "$PROMPT_FILE" || printf '%s' "$DEFAULT_PROMPT" )"

while IFS= read -r MSG; do
  [ -z "$MSG" ] && continue
  STAMP="$(date +%F_%H%M%S)"

  # Reset command: start a fresh conversation (drops memory). Handled here, no
  # Claude call, so it costs nothing and shrinks the growing --resume context.
  LMSG="$(printf '%s' "$MSG" | tr '[:upper:]' '[:lower:]')"
  case "$LMSG" in
    /new|/reset|/clear|"new chat"|"reset")
      rm -f "$SESS"
      "$PY" "$TG" send-text "🔄 Fresh conversation started. Previous context cleared." >/dev/null 2>&1 || true
      continue ;;
  esac

  # Acknowledge receipt immediately (a task may take minutes).
  "$PY" "$TG" send-text "✓ Got it — working on this…" >/dev/null 2>>"$LOG/chat_$STAMP.err" || true

  WRAP="$SYS

Message from user: \"$MSG\""

  RESUME=""; [ -s "$SESS" ] && RESUME="--resume $(cat "$SESS")"
  if ! OUT="$("$CLAUDE_BIN" -p $RESUME "$WRAP" --dangerously-skip-permissions --output-format json 2>>"$LOG/chat_$STAMP.err")"; then
    # Session may be stale/corrupt; retry fresh (no --resume).
    OUT="$("$CLAUDE_BIN" -p "$WRAP" --dangerously-skip-permissions --output-format json 2>>"$LOG/chat_$STAMP.err")" || true
  fi
  printf '%s' "$OUT" > "$LOG/chat_$STAMP.json"
  RES="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' "$LOG/chat_$STAMP.json" 2>/dev/null || true)"
  SID="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("session_id",""))' "$LOG/chat_$STAMP.json" 2>/dev/null || true)"
  IS_ERR="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("is_error"))' "$LOG/chat_$STAMP.json" 2>/dev/null || echo True)"
  [ -n "$SID" ] && printf '%s' "$SID" > "$SESS"

  if [ -z "$OUT" ] || [ "$IS_ERR" = "True" ]; then
    "$PY" "$TG" send-text "⚠️ Something went wrong while processing your request. Log: .tg-bridge/logs/chat_$STAMP.*" >/dev/null 2>&1 || true
  elif [ -n "$RES" ]; then
    "$PY" "$TG" send-text "$RES" >>"$LOG/chat_$STAMP.json" 2>>"$LOG/chat_$STAMP.err"
  fi
done < "$STATE/.chat-msgs.txt"

printf '%s' "$MAX" > "$OFF"
echo "chat tick done: processed $COUNT message(s)"
