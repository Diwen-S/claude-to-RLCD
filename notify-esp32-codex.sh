#!/usr/bin/env bash
# Notify the ESP32 RLCD of a Codex CLI state change.
# Invoked (via wsl.exe) by Codex lifecycle hooks. Arg 1: working | done | action | clear
#
# Differs from the Claude notify-esp32.sh:
#   * src is tagged "(Codex)" so it gets its own cell alongside Claude cells.
#   * No ccusage stats: ccusage reads CLAUDE usage, which is meaningless here.
#   * action fires unconditionally — Codex has a dedicated PermissionRequest
#     event, so no notification_type filtering is needed.
#   * Session label is taken from the hook JSON `cwd`, not $PWD: when Codex
#     runs on Windows and bridges in via wsl.exe, $PWD is the WSL landing dir,
#     not the project Codex is working in.
# Codex has no documented session-end event, so the cell is not auto-forgotten;
# it persists until overwritten.

set +e

MODE=${1:-done}

# Slurp the JSON payload Codex pipes on stdin before doing anything async.
HOOK_JSON=$(cat 2>/dev/null)

# Codex common hook fields: session_id, cwd, hook_event_name, model.
read SID_FULL CWD <<< "$(printf '%s' "$HOOK_JSON" | python3 -c "
import sys, json
try: d = json.loads(sys.stdin.read() or '{}')
except Exception: d = {}
print(d.get('session_id','-'), d.get('cwd','-'))
" 2>/dev/null)"
[ "$SID_FULL" = "-" ] && SID_FULL=""
[ "$CWD"      = "-" ] && CWD=""

main() {
  IP=$(cat "$HOME/.claude/esp32-ip" 2>/dev/null | tr -d ' \n\r')
  [ -z "$IP" ] && return
  TOKEN=$(cat "$HOME/.claude/esp32-token" 2>/dev/null | tr -d ' \n\r')

  # Session label priority:
  #   1. ~/.claude/session-label-codex
  #   2. $CODEX_SESSION_LABEL
  #   3. basename of the hook JSON cwd
  #   4. hostname
  SESSION_NAME=$(cat "$HOME/.claude/session-label-codex" 2>/dev/null | tr -d ' \n\r')
  [ -z "$SESSION_NAME" ] && SESSION_NAME="${CODEX_SESSION_LABEL}"
  [ -z "$SESSION_NAME" ] && [ -n "$CWD" ] && SESSION_NAME=$(basename "$CWD" 2>/dev/null)
  { [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "/" ]; } && SESSION_NAME=$(hostname 2>/dev/null)

  # Per-session suffix from session_id (first 4 chars).
  TAG=""
  [ -n "$SID_FULL" ] && TAG="/${SID_FULL:0:4}"
  SRC="${SESSION_NAME}${TAG} (Codex)"

  ARGS=( --data-urlencode "src=$SRC" )
  [ -n "$TOKEN" ] && ARGS+=( --data-urlencode "t=$TOKEN" )
  case "$MODE" in
    clear)
      ARGS+=( --data-urlencode "alert=" )
      ;;
    action)
      ARGS+=( --data-urlencode "alert=Action required" )
      ;;
    working)
      ARGS+=( --data-urlencode "status=working"
              --data-urlencode "ts=$(date +%H:%M:%S)"
              --data-urlencode "alert=" )
      ;;
    *)
      ARGS+=( --data-urlencode "status=done"
              --data-urlencode "ts=$(date +%H:%M:%S)"
              --data-urlencode "alert=" )
      ;;
  esac

  curl -s -m 3 -G "${ARGS[@]}" "http://$IP/notify" >/dev/null 2>&1
}

# Self-background so Codex doesn't block on the HTTP round-trip. stdin was
# already slurped above, so backgrounding is safe.
main </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
