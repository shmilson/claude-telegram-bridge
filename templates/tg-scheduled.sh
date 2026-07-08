#!/usr/bin/env bash
# Run a one-shot Claude Code task on a schedule and report the result to Telegram.
# Independent of the chat bridge (no --resume, no shared lock) so a scheduled run
# and a live chat can coexist. Wire it to a launchd StartCalendarInterval / cron.
#
# Usage:  tg-scheduled.sh "<the task prompt>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${TG_BRIDGE_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
command -v claude >/dev/null 2>&1 && CLAUDE_BIN="claude"

cd "$REPO"
[ -f .env ] && { set -a; . ./.env; set +a; }
PY="$REPO/.venv/bin/python"; [ -x "$PY" ] || PY="python3"
TG="$SCRIPT_DIR/tg.py"
LOG="$REPO/.tg-bridge/logs"; mkdir -p "$LOG"

TASK="${1:?usage: tg-scheduled.sh \"<prompt>\"}"
STAMP="$(date +%F_%H%M%S)"

OUT="$("$CLAUDE_BIN" -p "$TASK" --dangerously-skip-permissions --output-format json 2>>"$LOG/sched_$STAMP.err")" || true
printf '%s' "$OUT" > "$LOG/sched_$STAMP.json"
RES="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' "$LOG/sched_$STAMP.json" 2>/dev/null || true)"
IS_ERR="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("is_error"))' "$LOG/sched_$STAMP.json" 2>/dev/null || echo True)"

if [ -z "$OUT" ] || [ "$IS_ERR" = "True" ]; then
  "$PY" "$TG" send-text "⚠️ Scheduled task failed. Log: .tg-bridge/logs/sched_$STAMP.*" >/dev/null 2>&1 || true
elif [ -n "$RES" ]; then
  "$PY" "$TG" send-text "$RES" >/dev/null 2>>"$LOG/sched_$STAMP.err" || true
fi
