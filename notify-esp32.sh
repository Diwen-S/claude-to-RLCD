#!/usr/bin/env bash
# Notify the ESP32 RLCD of a Claude Code state change + current usage stats.
# Invoked by Stop / UserPromptSubmit / Notification / PreToolUse / SessionEnd
# hooks.  Arg 1: working | done | action | clear | closed
#         Arg 2: (empty) = Claude Code CLI in this WSL distro
#                "win"   = Claude Code desktop (claude.exe) bridged via wsl.exe

set +e

MODE=${1:-done}

# Arg 2 marks which host the session lives on. Empty (default) = this WSL
# distro, invoked directly by the Claude Code CLI. "win" = the Windows
# desktop app (claude.exe), which bridges in through `wsl.exe -e`. The
# distinction earns its own tag on screen and suppresses ccusage, because
# ccusage here reads WSL's ~/.claude/projects and knows nothing about the
# desktop app's usage inside its MSIX container.
HOST=${2:-}

# Slurp the JSON payload Claude pipes to every hook on stdin BEFORE doing
# anything async. If we ran with `&` in settings.json, dash/sh would have
# redirected our stdin to /dev/null already; instead settings.json runs us
# foreground and we self-background below.
HOOK_JSON=$(cat 2>/dev/null)

# Extract session_id (UUID — same across every hook of one terminal session),
# notification_type (only set on Notification events), and the basename of
# the hook's `cwd`.
#
# Passed via the environment rather than stdin so the python body can be a
# quoted heredoc (no shell interpolation to escape), and emitted as
# shlex-quoted assignments rather than a space-separated `read`, because a
# Windows cwd may contain spaces (`D:\My Documents\...`) and would otherwise
# split across fields.
JSON_VARS=$(HOOK_JSON="$HOOK_JSON" python3 - <<'PY' 2>/dev/null
import os, json, shlex, ntpath, re
raw = os.environ.get('HOOK_JSON') or ''
try: d = json.loads(raw or '{}')
except Exception: d = {}
if not isinstance(d, dict): d = {}
sid = d.get('session_id') or ''
nty = d.get('notification_type') or ''
cwd = d.get('cwd') or ''
# Lenient fallback. A payload carrying unescaped Windows separators
# ("cwd":"D:\Research\x") is not legal JSON — \R is not a valid escape — and
# strict parsing throws away the whole object over it. Rather than silently
# degrade to a meaningless label, scrape the two fields we need.
if not sid:
    m = re.search(r'"session_id"\s*:\s*"([^"]*)"', raw)
    if m: sid = m.group(1)
if not cwd:
    m = re.search(r'"cwd"\s*:\s*"(.*?)"\s*[,}]', raw)
    if m: cwd = m.group(1).replace('\\\\', '\\')
# ntpath.basename understands both separators once '/' is normalised to '\',
# so this handles a WSL path (/mnt/d/Research/proj) and a Windows one
# (D:\Research\proj) identically.
base = ntpath.basename(cwd.replace('/', '\\').rstrip('\\')) if cwd else ''
print('SID_FULL=' + shlex.quote(str(sid)))
print('NTYPE='    + shlex.quote(str(nty)))
print('CWD_BASE=' + shlex.quote(str(base)))
PY
)
SID_FULL=""; NTYPE=""; CWD_BASE=""
eval "$JSON_VARS" 2>/dev/null

# The device's mDNS name, used only as a recovery path. install.sh caches a
# literal IP in esp32-ip precisely so hooks don't resolve this on every call:
# mDNS from WSL2 measured 1.2-1.6s per lookup against a ~0.17s device response,
# and a failed lookup (curl rc=6) is why hooks silently dropped updates and
# left stale cells on screen.
MDNS_NAME="claude-rlcd.local"

# Send one request, preferring the cached address. If that fails, retry once
# over mDNS and re-cache the literal IP, so a DHCP lease change costs one slow
# hook rather than breaking the display until install.sh is re-run.
dev_get() {
  local ep="$1"; shift
  curl -s -m 10 -G "$@" "http://$IP/$ep" >/dev/null 2>&1 && return 0
  [ "$IP" = "$MDNS_NAME" ] && return 1
  curl -s -m 20 -G "$@" "http://$MDNS_NAME/$ep" >/dev/null 2>&1 || return 1
  local newip tmp
  newip=$(curl -s -m 20 "http://$MDNS_NAME/" | awk '/^ip[[:space:]]*=/ {print $3; exit}')
  if printf '%s' "$newip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    # Atomic replace: several sessions' hooks can race here.
    tmp=$(mktemp "$HOME/.claude/.esp32-ip.XXXXXX" 2>/dev/null) || return 0
    printf '%s\n' "$newip" > "$tmp" && mv -f "$tmp" "$HOME/.claude/esp32-ip"
  fi
  return 0
}

main() {
  IP=$(cat "$HOME/.claude/esp32-ip" 2>/dev/null | tr -d ' \n\r')
  [ -z "$IP" ] && return
  TOKEN=$(cat "$HOME/.claude/esp32-token" 2>/dev/null | tr -d ' \n\r')

  # Session label priority (the hook JSON's cwd before $PWD, and $PWD before
  # $WSL_DISTRO_NAME, so per-project sessions auto-distinguish without having
  # to set $CLAUDE_SESSION_LABEL):
  #   1. ~/.claude/session-label
  #   2. $CLAUDE_SESSION_LABEL
  #   3. basename of the hook JSON `cwd`
  #   4. PWD basename
  #   5. $WSL_DISTRO_NAME
  #   6. hostname
  #
  # (3) has to outrank (4): when the Windows desktop app bridges in through
  # `wsl.exe -e`, $PWD is whatever directory wsl.exe landed in, not the
  # project Claude is actually working in. Same reasoning as notify-esp32-codex.sh.
  SESSION_NAME=$(cat "$HOME/.claude/session-label" 2>/dev/null | tr -d ' \n\r')
  [ -z "$SESSION_NAME" ] && SESSION_NAME="${CLAUDE_SESSION_LABEL}"
  [ -z "$SESSION_NAME" ] && SESSION_NAME="${CWD_BASE}"
  # $PWD is only meaningful for a local CLI session. Under the wsl.exe bridge
  # it is wherever the Windows caller happened to be — typically /mnt/c, which
  # yields a cell labelled "c". Skip it rather than show that.
  [ -z "$SESSION_NAME" ] && [ "$HOST" != "win" ] && SESSION_NAME=$(basename "$PWD" 2>/dev/null)
  [ -z "$SESSION_NAME" ] && [ "$HOST" = "win" ] && SESSION_NAME="Windows"
  { [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "/" ]; } && SESSION_NAME="${WSL_DISTRO_NAME}"
  { [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "/" ]; } && SESSION_NAME=$(hostname 2>/dev/null)

  # Per-terminal suffix from session_id — the LAST 4 hex chars. Claude's ids
  # are random UUIDv4 so either end would do, but Codex issues time-ordered
  # ids whose leading chars are shared across sessions (see the note in
  # notify-esp32-codex.sh), and both scripts must agree so a mixed setup
  # reads consistently. Manual test invocations with no JSON payload leave
  # TAG empty.
  TAG=""
  [ -n "$SID_FULL" ] && TAG="/${SID_FULL: -4}"

  # Host tag. ASCII only: the label is drawn with u8g2 drawStr (main.cpp:233),
  # which walks raw bytes rather than decoding UTF-8, so a multi-byte
  # separator would render as garbage glyphs.
  HOSTTAG=""
  [ "$HOST" = "win" ] && HOSTTAG=" W"
  SRC="${SESSION_NAME}${TAG} (Code${HOSTTAG})"

  # SessionEnd: drop this cell, then exit. Different endpoint, no /notify call.
  if [ "$MODE" = "closed" ]; then
    FORGET_ARGS=( --data-urlencode "src=$SRC" )
    [ -n "$TOKEN" ] && FORGET_ARGS+=( --data-urlencode "t=$TOKEN" )
    # -m 10, not 3: /forget repaints the ST7305 synchronously before it
    # answers, so a 3s cap raced the response and left the cell stranded.
    # (Against a cached IP the whole call is ~0.17s; the headroom is for the
    # mDNS fallback path inside dev_get.)
    dev_get forget "${FORGET_ARGS[@]}"
    return
  fi

  # Usage stats only matter on real state changes — skip for the alert flash.
  # Also skipped for the Windows desktop app: ccusage runs in this WSL distro
  # and reads WSL's ~/.claude/projects, so it would report CLI figures against
  # a desktop session. Blank is honest; wrong numbers are not.
  SESSION_PCT=""
  RESET_HHMM=""
  WEEKLY_USD=""
  if [ "$MODE" != "action" ] && [ "$MODE" != "clear" ] && [ "$HOST" != "win" ]; then
    read SESSION_PCT RESET_HHMM WEEKLY_USD <<< "$(
      python3 - <<'PY' 2>/dev/null
import json, subprocess
from datetime import datetime, timezone
def jrun(args):
    # 60s, not 8s. Warm, `npx ccusage` answers in about 1s — but the first call
    # on a machine (or the first after npm evicts the cache) downloads the
    # package, which takes roughly 25s and blew straight through the old 8s
    # cap. That is exactly the recipient's first few sessions, where `--` in
    # the usage fields looks like the device is broken. Nothing waits on this:
    # the whole function runs in a backgrounded copy of the script.
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=60)
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

  dev_get notify "${ARGS[@]}"
}

# Backgrounding rules, one per invocation path:
#
#   closed      — must be synchronous: Claude is about to exit and will kill
#                 any background work still in flight.
#   HOST=win    — must be synchronous: we were invoked through `wsl.exe -e`,
#                 and WSL reaps the entire session (setsid and nohup do NOT
#                 escape it — both were measured dying) the moment the
#                 foreground command returns. The Windows hook detaches with
#                 `cmd /c start /b` instead, so nothing blocks over there.
#   otherwise   — self-background so the local CLI doesn't wait on ccusage
#                 plus the HTTP round-trip. stdin was slurped above, so this
#                 is safe under dash (see the `&` bug in the dev log).
if [ "$MODE" = "closed" ] || [ "$HOST" = "win" ]; then
  main
else
  main </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi
exit 0
