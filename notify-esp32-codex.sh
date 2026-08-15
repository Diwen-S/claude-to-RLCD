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

# Arg 2: (empty) = Codex CLI running natively in this WSL distro.
#        "win"   = Codex on Windows, bridged in through `wsl.exe -e`.
HOST=${2:-}

# Slurp the JSON payload Codex pipes on stdin before doing anything async.
HOOK_JSON=$(cat 2>/dev/null)

# Codex common hook fields: session_id, cwd, hook_event_name, model.
#
# Passed by environment rather than stdin so the body can be a quoted heredoc,
# and emitted as shlex-quoted assignments rather than a space-separated `read`:
# a Windows cwd may contain spaces (`C:\My Documents\...`), which the old
# `read SID_FULL CWD` split across fields.
JSON_VARS=$(HOOK_JSON="$HOOK_JSON" python3 - <<'PY' 2>/dev/null
import os, json, shlex, ntpath, re
raw = os.environ.get('HOOK_JSON') or ''
try: d = json.loads(raw or '{}')
except Exception: d = {}
if not isinstance(d, dict): d = {}
sid = d.get('session_id') or ''
cwd = d.get('cwd') or ''
# Lenient fallback for a payload with unescaped Windows separators, which is
# not legal JSON and would otherwise discard the whole object.
if not sid:
    m = re.search(r'"session_id"\s*:\s*"([^"]*)"', raw)
    if m: sid = m.group(1)
if not cwd:
    m = re.search(r'"cwd"\s*:\s*"(.*?)"\s*[,}]', raw)
    if m: cwd = m.group(1).replace('\\\\', '\\')
# ntpath.basename handles both separators once '/' is normalised to '\'.
norm = cwd.replace('/', '\\').rstrip('\\')
base = ntpath.basename(norm) if cwd else ''
# A Codex Desktop chat with no folder attached ("projectless") runs with cwd set
# to the app's own install directory, so the basename is a meaningless "app":
#   C:\Program Files\WindowsApps\OpenAI.Codex_<ver>_x64__<hash>\app
# Flag it so the caller can substitute a real label instead.
low = norm.lower()
projectless = '\\windowsapps\\' in low and 'openai.codex' in low
print('SID_FULL=' + shlex.quote(str(sid)))
print('CWD_BASE=' + shlex.quote('' if projectless else str(base)))
print('PROJECTLESS=' + ('1' if projectless else ''))
PY
)
SID_FULL=""; CWD_BASE=""; PROJECTLESS=""
eval "$JSON_VARS" 2>/dev/null

# Recovery path only — install.sh caches a literal IP in esp32-ip so hooks
# never pay mDNS resolution (1.2-1.6s from WSL2, against a ~0.17s device
# response). That margin matters more here than for Claude: Codex caps hook
# execution at timeoutSec=1, which an mDNS-resolved call cannot fit inside.
MDNS_NAME="claude-rlcd.local"

# Send one request, preferring the cached address; on failure retry once over
# mDNS and re-cache the literal IP so a DHCP lease change self-heals.
dev_get() {
  local ep="$1"; shift
  curl -s -m 10 -G "$@" "http://$IP/$ep" >/dev/null 2>&1 && return 0
  [ "$IP" = "$MDNS_NAME" ] && return 1
  curl -s -m 20 -G "$@" "http://$MDNS_NAME/$ep" >/dev/null 2>&1 || return 1
  local newip tmp
  newip=$(curl -s -m 20 "http://$MDNS_NAME/" | awk '/^ip[[:space:]]*=/ {print $3; exit}')
  if printf '%s' "$newip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    tmp=$(mktemp "$HOME/.claude/.esp32-ip.XXXXXX" 2>/dev/null) || return 0
    printf '%s\n' "$newip" > "$tmp" && mv -f "$tmp" "$HOME/.claude/esp32-ip"
  fi
  return 0
}

main() {
  IP=$(cat "$HOME/.claude/esp32-ip" 2>/dev/null | tr -d ' \n\r')
  [ -z "$IP" ] && return
  TOKEN=$(cat "$HOME/.claude/esp32-token" 2>/dev/null | tr -d ' \n\r')

  # Session label priority:
  #   1. ~/.claude/session-label-codex
  #   2. $CODEX_SESSION_LABEL
  #   3. basename of the hook JSON cwd
  #   4. ~/.claude/session-label-codex-default, else "Chat", when the session is
  #      projectless (a Codex Desktop chat with no folder attached, whose cwd is
  #      the app install dir and so would otherwise label every such cell "app")
  #   5. hostname
  SESSION_NAME=$(cat "$HOME/.claude/session-label-codex" 2>/dev/null | tr -d ' \n\r')
  [ -z "$SESSION_NAME" ] && SESSION_NAME="${CODEX_SESSION_LABEL}"
  [ -z "$SESSION_NAME" ] && SESSION_NAME="${CWD_BASE}"
  if [ -z "$SESSION_NAME" ] && [ -n "$PROJECTLESS" ]; then
    SESSION_NAME=$(cat "$HOME/.claude/session-label-codex-default" 2>/dev/null | tr -d ' \n\r')
    [ -z "$SESSION_NAME" ] && SESSION_NAME="Chat"
  fi
  [ -z "$SESSION_NAME" ] && [ "$HOST" = "win" ] && SESSION_NAME="Windows"
  { [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "/" ]; } && SESSION_NAME=$(hostname 2>/dev/null)

  # Per-session suffix from session_id — the LAST 4 chars, not the first.
  # Codex issues time-ordered (UUIDv7-style) session ids, so every session
  # started in the same period shares a leading prefix: 01a00488, 01a00489,
  # 01a004ad, 01a004d8 were five separate sessions in one afternoon, all of
  # which rendered as "/01a0" and collapsed into a single cell. The tail is
  # the random part. Claude's ids are UUIDv4 so either end works there, and
  # notify-esp32.sh uses the tail too, to keep the two scripts consistent.
  TAG=""
  [ -n "$SID_FULL" ] && TAG="/${SID_FULL: -4}"

  # Host tag. ASCII only — the label is drawn with u8g2 drawStr, which walks
  # raw bytes instead of decoding UTF-8.
  HOSTTAG=""
  [ "$HOST" = "win" ] && HOSTTAG=" W"
  SRC="${SESSION_NAME}${TAG} (Codex${HOSTTAG})"

  # SessionEnd: drop this cell and stop. Codex gained SessionEnd in 0.147.0
  # (0.142-alpha did not have it) and it does fire, delivering session_id and
  # cwd like every other event — so a (Codex) cell no longer has to linger
  # until something evicts it. Mirrors the `closed` path in notify-esp32.sh.
  if [ "$MODE" = "closed" ]; then
    # Let the Stop hook's notify land first. Codex fires Stop and SessionEnd in
    # the same second, and Stop self-backgrounds — so without this pause the
    # forget wins the race and the backgrounded `done` immediately recreates
    # the cell we just removed. Measured: the notify completes ~0.25s in.
    #
    # The budget for this is 3s: Codex kills a hook at `timeout` seconds
    # (default 1, and it really does kill it — a 3s sleep was cut off mid-way
    # in testing), and 3 is the largest value it accepts, so install.sh sets
    # `timeout = 3` on this hook alone.
    sleep 1
    FORGET_ARGS=( --data-urlencode "src=$SRC" )
    [ -n "$TOKEN" ] && FORGET_ARGS+=( --data-urlencode "t=$TOKEN" )
    dev_get forget "${FORGET_ARGS[@]}"
    return
  fi

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

  dev_get notify "${ARGS[@]}"
}

# When bridged from Windows we must run synchronously: WSL reaps the whole
# session the moment the `wsl.exe -e` command returns, which kills any
# background job (setsid and nohup do not escape it — both measured dying).
# The Windows hook wraps the call in `cmd /c start /b` so nothing blocks over
# there. A native CLI session self-backgrounds as before; stdin was already
# slurped, so that is safe under dash.
# `closed` joins the synchronous group: Codex is tearing the session down and
# will take any background job with it, exactly as Claude does on SessionEnd.
if [ "$HOST" = "win" ] || [ "$MODE" = "closed" ]; then
  main
else
  main </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi
exit 0
