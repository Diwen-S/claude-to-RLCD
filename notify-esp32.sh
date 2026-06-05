#!/usr/bin/env bash
# Notify the ESP32 RLCD of a Claude Code state change + current usage stats.
# Invoked by Stop / UserPromptSubmit / Notification / PreToolUse / SessionEnd
# hooks.  Arg 1: working | done | action | clear | closed

set +e

MODE=${1:-done}

# Slurp the JSON payload Claude pipes to every hook on stdin BEFORE doing
# anything async. If we ran with `&` in settings.json, dash/sh would have
# redirected our stdin to /dev/null already; instead settings.json runs us
# foreground and we self-background below.
HOOK_JSON=$(cat 2>/dev/null)

# Extract session_id (UUID — same across every hook of one terminal session)
# and notification_type (only set on Notification events).
read SID_FULL NTYPE <<< "$(printf '%s' "$HOOK_JSON" | python3 -c "
import sys, json
try: d = json.loads(sys.stdin.read() or '{}')
except Exception: d = {}
print(d.get('session_id','-'), d.get('notification_type','-'))
" 2>/dev/null)"
[ "$SID_FULL" = "-" ] && SID_FULL=""
[ "$NTYPE"    = "-" ] && NTYPE=""

main() {
  IP=$(cat "$HOME/.claude/esp32-ip" 2>/dev/null | tr -d ' \n\r')
  [ -z "$IP" ] && return
  TOKEN=$(cat "$HOME/.claude/esp32-token" 2>/dev/null | tr -d ' \n\r')

  # Session label priority (PWD before $WSL_DISTRO_NAME so per-project terminals
  # auto-distinguish without having to set $CLAUDE_SESSION_LABEL):
  #   1. ~/.claude/session-label
  #   2. $CLAUDE_SESSION_LABEL
  #   3. PWD basename
  #   4. $WSL_DISTRO_NAME
  #   5. hostname
  SESSION_NAME=$(cat "$HOME/.claude/session-label" 2>/dev/null | tr -d ' \n\r')
  [ -z "$SESSION_NAME" ] && SESSION_NAME="${CLAUDE_SESSION_LABEL}"
  [ -z "$SESSION_NAME" ] && SESSION_NAME=$(basename "$PWD" 2>/dev/null)
  { [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "/" ]; } && SESSION_NAME="${WSL_DISTRO_NAME}"
  { [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "/" ]; } && SESSION_NAME=$(hostname 2>/dev/null)

  # Per-terminal suffix from session_id (4 hex chars). Manual test invocations
  # with no JSON payload leave TAG empty.
  TAG=""
  [ -n "$SID_FULL" ] && TAG="/${SID_FULL:0:4}"
  SRC="${SESSION_NAME}${TAG} (Code)"

  # SessionEnd: drop this cell, then exit. Different endpoint, no /notify call.
  if [ "$MODE" = "closed" ]; then
    FORGET_ARGS=( --data-urlencode "src=$SRC" )
    [ -n "$TOKEN" ] && FORGET_ARGS+=( --data-urlencode "t=$TOKEN" )
    curl -s -m 3 -G "${FORGET_ARGS[@]}" "http://$IP/forget" >/dev/null 2>&1
    return
  fi

  # Usage stats only matter on real state changes — skip for the alert flash.
  SESSION_PCT=""
  RESET_HHMM=""
  WEEKLY_USD=""
  if [ "$MODE" != "action" ] && [ "$MODE" != "clear" ]; then
    read SESSION_PCT RESET_HHMM WEEKLY_USD <<< "$(
      python3 - <<'PY' 2>/dev/null
import json, subprocess
from datetime import datetime, timezone
def jrun(args):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=8)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except Exception:
        return None
sp = ra = wu = ""
blocks = jrun(["npx", "--yes", "ccusage@latest", "blocks", "--json"])
if blocks:
    actives = [b for b in blocks.get("blocks", []) if b.get("isActive")]
    if actives:
        b = actives[0]
        s = datetime.fromisoformat(b["startTime"].replace("Z", "+00:00"))
        e = datetime.fromisoformat(b["endTime"].replace("Z", "+00:00"))
        n = datetime.now(timezone.utc)
        span = (e - s).total_seconds()
        if span > 0:
            sp = str(max(0, min(100, int((n - s).total_seconds() / span * 100))))
        ra = e.astimezone().strftime("%H:%M")
weekly = jrun(["npx", "--yes", "ccusage@latest", "weekly", "--json"])
if weekly:
    rows = weekly.get("weekly", [])
    if rows:
        wu = str(int(round(rows[-1].get("totalCost", 0))))
print(sp, ra, wu)
PY
    )"
  fi

  ARGS=( --data-urlencode "src=$SRC" )
  [ -n "$TOKEN" ] && ARGS+=( --data-urlencode "t=$TOKEN" )
  case "$MODE" in
    clear)
      ARGS+=( --data-urlencode "alert=" )
      ;;
    action)
      # Claude fires Notification for permission prompts AND idle waits;
      # only flash the alert for permission prompts.
      [ "$NTYPE" = "permission_prompt" ] || return
      ARGS+=( --data-urlencode "alert=Action required" )
      ;;
    working)
      ARGS+=( --data-urlencode "status=working"
              --data-urlencode "ts=$(date +%H:%M:%S)"
              --data-urlencode "alert="
              --data-urlencode "sp=$SESSION_PCT"
              --data-urlencode "r=$RESET_HHMM"
              --data-urlencode "wc=$WEEKLY_USD" )
      ;;
    *)
      ARGS+=( --data-urlencode "status=done"
              --data-urlencode "ts=$(date +%H:%M:%S)"
              --data-urlencode "alert="
              --data-urlencode "sp=$SESSION_PCT"
              --data-urlencode "r=$RESET_HHMM"
              --data-urlencode "wc=$WEEKLY_USD" )
      ;;
  esac

  curl -s -m 3 -G "${ARGS[@]}" "http://$IP/notify" >/dev/null 2>&1
}

# SessionEnd must run synchronously — Claude is about to exit and will kill
# any background work still in flight. All other modes self-background so
# Claude doesn't block on ccusage + the HTTP round-trip.
if [ "$MODE" = "closed" ]; then
  main
else
  main </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi
exit 0
