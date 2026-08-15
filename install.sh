#!/usr/bin/env bash
# Install the ESP32 RLCD notifier hooks for Claude Code and/or Codex.
# Usage:  ./install.sh [host-or-ip]
# Runs on WSL, macOS, and Linux.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_HOST="claude-rlcd.local"
CLAUDE_DIR="$HOME/.claude"

# --- dependency check ---------------------------------------------------------
missing=()
for cmd in node python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing required commands: ${missing[*]}"
  case "$(uname -s)" in
    Linux*)  echo "Install with: sudo apt install ${missing[*]}  (or your distro's equivalent)";;
    Darwin*) echo "Install with: brew install ${missing[*]}";;
  esac
  exit 1
fi

# Every device call needs a generous cap. Two costs stack: mDNS resolution from
# WSL2 measured 1.2-1.6s on its own, and the ST7305 repaints synchronously
# before the handler answers. /pair is the worst case — it paints the token
# banner, sleeps 2.5s, then repaints — and was measured at 5.24s end to end,
# which the previous -m 5 lost a coin flip to on the recipient's first install.
DEV_TIMEOUT=20

probe() {
  curl -sf -m "$DEV_TIMEOUT" "http://$1/" -o /dev/null
}

# --- discovery ----------------------------------------------------------------
HOST=""
if [ $# -ge 1 ] && [ -n "$1" ]; then
  echo "Probing user-supplied host: $1 ..."
  if probe "$1"; then HOST="$1"; else echo "  cannot reach http://$1/"; fi
fi

if [ -z "$HOST" ]; then
  echo "Probing $DEFAULT_HOST (mDNS) ..."
  if probe "$DEFAULT_HOST"; then
    HOST="$DEFAULT_HOST"
  else
    echo "  not reachable via mDNS (common on WSL2 — no avahi)."
  fi
fi

if [ -z "$HOST" ] && [ -f "$CLAUDE_DIR/esp32-ip" ]; then
  prev=$(tr -d ' \n\r' < "$CLAUDE_DIR/esp32-ip")
  if [ -n "$prev" ]; then
    echo "Probing previously-saved IP: $prev ..."
    if probe "$prev"; then HOST="$prev"; fi
  fi
fi

if [ -z "$HOST" ]; then
  echo
  echo "Could not auto-discover the ESP. Find its IP from the device screen"
  echo "(shown small in the top-right block) or your router's client list."
  printf "Enter ESP32 IP or hostname: "
  read -r entered
  entered=$(printf '%s' "$entered" | tr -d ' \n\r')
  [ -z "$entered" ] && { echo "No host given. Aborting."; exit 1; }
  if ! probe "$entered"; then
    echo "Cannot reach http://$entered/  — check power, WiFi, and that it's on the same LAN."
    exit 1
  fi
  HOST="$entered"
fi

echo "Reached ESP at: $HOST"

# --- common: device IP file (both agents read this) ---------------------------
# Store a literal IP, never the mDNS name, even though mDNS is what we probed
# with. Hooks fire on every prompt and every tool call, and mDNS resolution
# from WSL2 measured 1.2-1.6s *per call* — which both dwarfs the device's own
# ~0.17s response and is the reason hooks intermittently dropped updates and
# left stale cells (curl rc=6 when the name fails to resolve). Codex compounds
# it: it caps hooks at timeoutSec=1, so an mDNS-resolved call cannot finish
# inside the budget at all.
#
# The device reports its own address in the status dump, which is more reliable
# than resolving locally (no avahi needed in WSL). Fall back to whatever we
# probed with if that lookup fails, so this can only improve on the old
# behaviour. The notifier scripts retry against the mDNS name and re-cache if
# the stored IP ever stops answering, so a DHCP lease change self-heals.
mkdir -p "$CLAUDE_DIR"
# Retry: the ESP serves one request at a time, so a hook firing from an active
# session elsewhere on the LAN can make a single attempt fail on a reset
# connection. Observed in testing — one attempt is a coin flip when anything
# else is talking to the board.
DEVICE_IP=""
for _attempt in 1 2 3; do
  DEVICE_IP=$(curl -s -m "$DEV_TIMEOUT" "http://$HOST/" | awk '/^ip[[:space:]]*=/ {print $3; exit}')
  printf '%s' "$DEVICE_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' && break
  DEVICE_IP=""
  sleep 1
done
if [ -n "$DEVICE_IP" ] && probe "$DEVICE_IP"; then
  printf '%s\n' "$DEVICE_IP" > "$CLAUDE_DIR/esp32-ip"
  if [ "$DEVICE_IP" = "$HOST" ]; then
    echo "Wrote $CLAUDE_DIR/esp32-ip ($DEVICE_IP)"
  else
    echo "Wrote $CLAUDE_DIR/esp32-ip ($DEVICE_IP, resolved from $HOST — avoids per-hook mDNS)"
  fi
else
  printf '%s\n' "$HOST" > "$CLAUDE_DIR/esp32-ip"
  echo "Wrote $CLAUDE_DIR/esp32-ip ($HOST)"
  echo "  note: could not read a literal IP from the device; hooks will resolve"
  echo "        $HOST on every call, which is slower and can drop updates."
fi

# --- pairing token ------------------------------------------------------------
# The ESP rejects /notify without ?t=<token> once it has been paired. The
# device is either:
#   - already paired by the gifter — recipient types the token on the sticker
#   - in open mode — anyone on LAN may pair it now by choosing a token
device_state=$(curl -s -m "$DEV_TIMEOUT" "http://$HOST/" | awk '/^paired/ {print $3, $4, $5}')
existing_token=""
if [ -f "$CLAUDE_DIR/esp32-token" ]; then
  existing_token=$(tr -d ' \n\r' < "$CLAUDE_DIR/esp32-token")
fi

if printf '%s' "$device_state" | grep -q "^no"; then
  echo
  echo "Device is in OPEN mode (no token saved). Set one now."
  printf "Choose a token (4-32 alphanumeric chars), or press Enter to skip: "
  read -r new_token
  new_token=$(printf '%s' "$new_token" | tr -d ' \n\r')
  if [ -n "$new_token" ]; then
    if ! printf '%s' "$new_token" | grep -Eq '^[A-Za-z0-9]{4,32}$'; then
      echo "Token shape invalid (need 4-32 alphanumeric). Aborting."
      exit 1
    fi
    pair_resp=$(curl -sf -m "$DEV_TIMEOUT" "http://$HOST/pair?token=$new_token") || {
      echo "Pairing call failed."; exit 1; }
    echo "  $pair_resp"
    printf '%s\n' "$new_token" > "$CLAUDE_DIR/esp32-token"
    chmod 600 "$CLAUDE_DIR/esp32-token"
    echo "Wrote $CLAUDE_DIR/esp32-token"
  else
    echo "Skipped — device stays in open mode (any LAN host can push)."
  fi
else
  echo
  echo "Device is already paired."
  if [ -n "$existing_token" ] && curl -sf -m "$DEV_TIMEOUT" "http://$HOST/notify?t=$existing_token&src=__probe&status=__probe" -o /dev/null; then
    # Undo the probe so we don't leave junk on the screen.
    curl -sf -m "$DEV_TIMEOUT" "http://$HOST/forget?t=$existing_token&src=__probe" -o /dev/null || true
    echo "  Existing $CLAUDE_DIR/esp32-token already works — keeping it."
  else
    printf "Enter pairing token from the device owner: "
    read -r entered_token
    entered_token=$(printf '%s' "$entered_token" | tr -d ' \n\r')
    [ -z "$entered_token" ] && { echo "No token given. Aborting."; exit 1; }
    if ! curl -sf -m "$DEV_TIMEOUT" "http://$HOST/notify?t=$entered_token&src=__probe&status=__probe" -o /dev/null; then
      echo "Token rejected by device. Ask owner for the right one, or run"
      echo "  curl http://$HOST/show-token   (flashes it on the LCD)"
      exit 1
    fi
    curl -sf -m "$DEV_TIMEOUT" "http://$HOST/forget?t=$entered_token&src=__probe" -o /dev/null || true
    printf '%s\n' "$entered_token" > "$CLAUDE_DIR/esp32-token"
    chmod 600 "$CLAUDE_DIR/esp32-token"
    echo "Wrote $CLAUDE_DIR/esp32-token"
  fi
fi

# --- agent wiring (opt-in, sequential) ---------------------------------------
install_claude() {
  cp "$SCRIPT_DIR/notify-esp32.sh" "$CLAUDE_DIR/notify-esp32.sh"
  chmod +x "$CLAUDE_DIR/notify-esp32.sh"
  echo "  Installed $CLAUDE_DIR/notify-esp32.sh"
  local SNIPPET="$SCRIPT_DIR/settings-snippet.json"
  local SETTINGS="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS" ]; then
  echo "{}" > "$SETTINGS"
fi

# Back up before mutating.
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"

python3 - "$SETTINGS" "$SNIPPET" <<'PY'
import json, sys
settings_path, snippet_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        settings = json.load(f)
        if not isinstance(settings, dict):
            settings = {}
except Exception:
    settings = {}
with open(snippet_path) as f:
    snippet = json.load(f)

hooks = settings.get("hooks", {}) or {}
for event, handlers in snippet.get("hooks", {}).items():
    existing = hooks.get(event, []) or []
    # Drop any prior entries that point at notify-esp32.sh; keep everything else.
    kept = []
    for h in existing:
        cmds = [hh.get("command", "") for hh in h.get("hooks", [])]
        if any("notify-esp32.sh" in c for c in cmds):
            continue
        kept.append(h)
    hooks[event] = kept + handlers
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
echo "  Merged hooks into $SETTINGS  (backup saved alongside)"
}

# Wire the Claude Code DESKTOP app on Windows. Only meaningful from WSL: the
# desktop app has no notifier of its own, it calls back into this distro and
# reuses the same notify-esp32.sh with a "win" host argument.
install_claude_desktop() {
  # The desktop hooks execute the WSL-resident script, so it must exist even
  # if the user declined the CLI wiring a moment ago.
  if [ ! -x "$CLAUDE_DIR/notify-esp32.sh" ]; then
    cp "$SCRIPT_DIR/notify-esp32.sh" "$CLAUDE_DIR/notify-esp32.sh"
    chmod +x "$CLAUDE_DIR/notify-esp32.sh"
    echo "  Installed $CLAUDE_DIR/notify-esp32.sh (needed by the desktop hooks)"
  fi

  # Locate %USERPROFILE%\.claude as seen from WSL.
  local wdir="" winprofile=""
  winprofile=$(powershell.exe -NoProfile -Command 'Write-Output $env:USERPROFILE' 2>/dev/null | tr -d ' \r\n') || true
  if [ -n "$winprofile" ] && command -v wslpath >/dev/null 2>&1; then
    local conv
    conv=$(wslpath -u "$winprofile" 2>/dev/null) || conv=""
    [ -n "$conv" ] && [ -d "$conv" ] && wdir="$conv/.claude"
  fi
  if [ -z "$wdir" ]; then
    local d
    for d in /mnt/c/Users/*/.claude; do
      [ -d "$d" ] && { wdir="$d"; break; }
    done
  fi
  if [ -z "$wdir" ]; then
    printf "  Could not find your Windows .claude dir. Enter it (Enter to skip): "
    read -r wdir
    wdir=$(printf '%s' "$wdir" | tr -d ' \n\r')
    [ -z "$wdir" ] && { echo "  Skipped Claude Code desktop."; return; }
  fi
  mkdir -p "$wdir" 2>/dev/null || { echo "  Cannot write $wdir — skipping desktop."; return; }

  local wsettings="$wdir/settings.json"
  [ -f "$wsettings" ] || echo "{}" > "$wsettings"
  cp "$wsettings" "$wsettings.bak.$(date +%Y%m%d-%H%M%S)"

  # MSYS_NO_PATHCONV=1 is not optional. The desktop app runs hooks through Git
  # Bash, whose MSYS2 layer rewrites absolute POSIX arguments, so a bare
  # /home/... path reaches wsl.exe as C:/Program Files/Git/home/... and fails.
  # Equally: do NOT wrap this in `cmd.exe /c`. Under Git Bash that becomes an
  # interactive cmd which consumes the JSON payload from stdin and exits 0,
  # reporting success while never contacting the device.
  WSETTINGS="$wsettings" NOTIFY="$CLAUDE_DIR/notify-esp32.sh" python3 - <<'PY'
import json, os
path   = os.environ["WSETTINGS"]
notify = os.environ["NOTIFY"]
try:
    with open(path) as f:
        settings = json.load(f)
        if not isinstance(settings, dict):
            settings = {}
except Exception:
    settings = {}

events = {
    "UserPromptSubmit": "working",
    "Stop":             "done",
    "Notification":     "action",
    "PreToolUse":       "clear",
    "SessionEnd":       "closed",
}

hooks = settings.get("hooks", {}) or {}
for event, mode in events.items():
    cmd = f"MSYS_NO_PATHCONV=1 wsl.exe -e {notify} {mode} win"
    kept = []
    for h in (hooks.get(event, []) or []):
        cmds = [hh.get("command", "") for hh in h.get("hooks", [])]
        if any("notify-esp32.sh" in c for c in cmds):
            continue
        kept.append(h)
    kept.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
    hooks[event] = kept
settings["hooks"] = hooks

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
  echo "  Merged desktop hooks into $wsettings  (backup saved alongside)"
  echo "  NOTE: quit the Claude desktop app COMPLETELY and relaunch it."
  echo "        settings.json is read once at startup; check the system tray too."
}

install_codex_home() {
  local cdir="$1"
  local script="$CLAUDE_DIR/notify-esp32-codex.sh"
  [ -d "$cdir" ] || { echo "  $cdir is not a directory — skipping it."; return; }
  local conf="$cdir/config.toml"
  [ -f "$conf" ] || : > "$conf"

  # Codex runs the hook on its own OS. If its home is a Windows mount, Codex is
  # the Windows build and reaches the WSL script via wsl.exe; otherwise it calls
  # the script directly.
  # A Windows-mounted Codex home means the Windows build, which reaches the
  # WSL-resident script through wsl.exe and takes the "win" host argument.
  # That argument tags the cell (Codex W) and, importantly, makes the script
  # run synchronously: a job backgrounded inside `wsl.exe -e` is killed the
  # moment the command returns, because WSL reaps the whole session.
  local run="$script" hostarg=""
  case "$cdir" in
    /mnt/[a-z]/*) run="wsl.exe -e $script"; hostarg=" win" ;;
  esac

  cp "$conf" "$conf.bak.$(date +%Y%m%d-%H%M%S)"

  # Marker-delimited block so re-running install.sh replaces, not duplicates.
  local block
  block=$(cat <<EOF
# >>> claude-rlcd codex hooks (managed by install.sh) >>>
[[hooks.UserPromptSubmit]]
matcher = ""
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '$run working$hostarg'

[[hooks.Stop]]
matcher = ""
[[hooks.Stop.hooks]]
type = "command"
command = '$run done$hostarg'

[[hooks.PermissionRequest]]
matcher = ""
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '$run action$hostarg'

[[hooks.PreToolUse]]
matcher = ""
[[hooks.PreToolUse.hooks]]
type = "command"
command = '$run clear$hostarg'

[[hooks.SessionEnd]]
matcher = ""
[[hooks.SessionEnd.hooks]]
type = "command"
command = '$run closed$hostarg'
timeout = 3
# <<< claude-rlcd codex hooks <<<
EOF
)

  CONF="$conf" BLOCK="$block" python3 - <<'PY'
import os, re
conf = os.environ["CONF"]; block = os.environ["BLOCK"]
try:
    with open(conf) as f: text = f.read()
except Exception:
    text = ""

# Our block sits at EOF, and Codex appends keys it writes itself (notably
# [projects."<dir>"] trust_level) to EOF too — so they land *inside* the
# markers. Stripping the whole span would silently delete them. Remove only
# the tables we generated and re-emit anything else above the fresh block.
OURS = re.compile(
    r"\[\[hooks\.(?:UserPromptSubmit|Stop|PermissionRequest|PreToolUse|SessionEnd)"
    r"(?:\.hooks)?\]\]$")
HEADER = re.compile(r"\[\[?[^\[\]]+\]\]?$")
MARKER = re.compile(r"# (?:>>>|<<<) claude-rlcd codex hooks")

def strip_managed(text):
    m = re.search(
        r"\n*# >>> claude-rlcd codex hooks.*?# <<< claude-rlcd codex hooks <<<\n?",
        text, flags=re.S)
    if not m:
        return text
    kept, cur, keep = [], [], False
    for line in m.group(0).splitlines():
        s = line.strip()
        if MARKER.search(s):
            continue
        if HEADER.match(s):
            if keep: kept.extend(cur)
            cur, keep = [line], not OURS.match(s)
        elif keep:
            cur.append(line)
    if keep: kept.extend(cur)
    foreign = "\n".join(kept).strip("\n")
    return text[:m.start()] + ("\n" + foreign + "\n" if foreign else "\n") + text[m.end():]

text = strip_managed(text)
text = text.rstrip("\n")
text = (text + "\n\n" if text else "") + block + "\n"
with open(conf, "w") as f:
    f.write(text)
PY
  echo "  Wrote Codex hooks into $conf  (backup saved alongside)"
}

install_codex() {
  cp "$SCRIPT_DIR/notify-esp32-codex.sh" "$CLAUDE_DIR/notify-esp32-codex.sh"
  chmod +x "$CLAUDE_DIR/notify-esp32-codex.sh"
  echo "  Installed $CLAUDE_DIR/notify-esp32-codex.sh"

  # Wire *every* Codex home found, not just the first. A WSL box commonly has
  # two — the native CLI in ~/.codex and the Windows build under
  # /mnt/c/Users/<you>/.codex — and each needs a differently-shaped hook
  # command (the Windows one goes through wsl.exe and takes the "win" arg).
  # Configuring only one silently left the other agent unable to reach the
  # display, which looked exactly like a broken hook.
  local -a cdirs=()
  local d c seen
  for d in ${CODEX_HOME:+"$CODEX_HOME"} "$HOME/.codex" \
           $(grep -qi microsoft /proc/version 2>/dev/null && echo /mnt/c/Users/*/.codex); do
    [ -d "$d" ] || continue
    seen=""
    for c in "${cdirs[@]}"; do [ "$c" = "$d" ] && seen=1; done
    [ -n "$seen" ] || cdirs+=("$d")
  done

  if [ ${#cdirs[@]} -eq 0 ]; then
    local entered
    printf "  Could not find a Codex home. Enter path to your .codex dir (Enter to skip): "
    read -r entered
    entered=$(printf '%s' "$entered" | tr -d ' \n\r')
    [ -z "$entered" ] && { echo "  Skipped Codex."; return; }
    cdirs=("$entered")
  fi

  for d in "${cdirs[@]}"; do install_codex_home "$d"; done

  echo "  NOTE: Codex trust-gates hooks — until you approve them they report"
  echo "        enabled but never fire. In the CLI, run 'codex' once and choose"
  echo "        'Trust all and continue'. The desktop app has no hooks UI at all;"
  echo "        see the Codex section of the README for the by-hand procedure."
  echo "        Check any time with: tools/codex-hooks-status.py"
}

echo
printf "Set up Claude Code? [Y/n]: "
read -r want_claude
case "$want_claude" in
  [nN]*) echo "  Skipped Claude Code." ;;
  *)     install_claude ;;
esac

# Offered only under WSL: the desktop app reaches the notifier through
# wsl.exe, so there is nothing to wire from a native Linux or macOS install.
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo
  echo "The Claude Code desktop app on Windows is configured separately from"
  echo "the CLI (its own settings.json in your Windows profile)."
  printf "Set up Claude Code desktop for Windows? [y/N]: "
  read -r want_desktop
  case "$want_desktop" in
    [yY]*) install_claude_desktop ;;
    *)     echo "  Skipped Claude Code desktop." ;;
  esac
fi

echo
printf "Set up Codex? [y/N]: "
read -r want_codex
case "$want_codex" in
  [yY]*) install_codex ;;
  *)     echo "  Skipped Codex." ;;
esac

# --- optional: calendar sidecar ----------------------------------------------
# Wires up the calendar view (single-tap KEY on the device). Opt-in because
# (a) plenty of users only want the Claude notifier, (b) it touches more of
# the system (venv, conf file, system timer) than the notifier does.

bootstrap_venv() {
  local venv="$1"
  local vendor="$SCRIPT_DIR/tools/vendor"
  if [ -x "$venv/bin/python" ]; then
    # Venvs created before the macOS CA fix lack certifi — backfill so a
    # plain `git pull && ./install.sh` repairs CERTIFICATE_VERIFY_FAILED.
    if ! "$venv/bin/python" -c "import certifi" 2>/dev/null; then
      "$venv/bin/pip" install --quiet --no-index --find-links "$vendor" certifi 2>/dev/null \
        || "$venv/bin/pip" install --quiet certifi 2>/dev/null \
        || echo "  warning: could not install certifi into existing venv (https fetches may fail on macOS)"
    fi
    return 0
  fi
  # Wall-clock varies wildly with filesystem: ~5-10 s on native Linux/macOS,
  # but up to ~60 s on WSL when the repo lives on /mnt/c or /mnt/d (per-file
  # NTFS-via-9P overhead). The PyPI fallback adds another 5-30 s on top.
  echo "Creating Python venv at $venv ... (~10 s on native filesystems, ~1 min on WSL/Windows mounts)"
  if ! python3 -m venv "$venv" 2>/dev/null; then
    echo "  python3 -m venv failed (likely missing python3-venv)."
    case "$(uname -s)" in
      Linux*)  echo "  Fix: sudo apt install python3-venv     (Debian/Ubuntu)"
               echo "       sudo dnf install python3-virtualenv  (Fedora)"
               echo "       (Arch / openSUSE ship venv with python3 already)";;
      Darwin*) echo "  Fix: brew install python  (then re-run ./install.sh)";;
    esac
    return 1
  fi

  # Try the bundled wheels first so install works on offline / locked-down
  # networks. Skip the pip self-upgrade in this path — every modern pip
  # handles --find-links fine, and skipping it keeps the offline path offline.
  if [ -d "$vendor" ] && ls "$vendor"/*.whl >/dev/null 2>&1; then
    if "$venv/bin/pip" install --quiet --no-index --find-links "$vendor" \
         icalendar recurring_ical_events python-dateutil certifi 2>/dev/null; then
      echo "  installed from bundled wheels in $vendor (offline)"
      return 0
    fi
    echo "  bundled wheels in $vendor didn't satisfy resolver — falling back to PyPI"
  fi
  # PyPI path: upgrade pip first since we're about to hit the network anyway.
  "$venv/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
  if "$venv/bin/pip" install --quiet icalendar recurring_ical_events python-dateutil certifi; then
    echo "  installed from PyPI: icalendar, recurring_ical_events, python-dateutil, certifi"
    return 0
  fi
  echo "  pip install failed — no network and bundled wheels missing / incompatible."
  echo "  Re-run after restoring internet, or re-run ./tools/vendor/refresh.sh on a connected box."
  return 1
}

install_timer_systemd() {
  local push_cmd="$1"
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/claude-calendar.service" <<EOF
[Unit]
Description=Push today's calendar to the Claude RLCD

[Service]
Type=oneshot
ExecStart=$push_cmd
EOF
  cat > "$unit_dir/claude-calendar.timer" <<EOF
[Unit]
Description=Push today's calendar every 5 min

[Timer]
OnBootSec=30
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now claude-calendar.timer >/dev/null
  echo "  Installed systemd-user timer: claude-calendar.timer"
  echo "  Check status:  systemctl --user status claude-calendar.timer"
}

install_timer_launchd() {
  local push_cmd="$1"
  local plist="$HOME/Library/LaunchAgents/sh.diwen.claude-calendar.plist"
  # Split the command into argv (venv-python, script, --push) safely.
  read -r venv_py script_path flag <<<"$push_cmd"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>sh.diwen.claude-calendar</string>
  <key>ProgramArguments</key>
  <array>
    <string>$venv_py</string>
    <string>$script_path</string>
    <string>$flag</string>
  </array>
  <key>StartInterval</key>    <integer>300</integer>
  <key>RunAtLoad</key>        <true/>
</dict>
</plist>
EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  echo "  Installed launchd agent: sh.diwen.claude-calendar"
  echo "  Check status:  launchctl list | grep claude-calendar"
}

install_timer_cron() {
  local push_cmd="$1"
  if crontab -l 2>/dev/null | grep -qF "calendar-push.py"; then
    echo "  cron entry already exists — leaving it in place."
    return
  fi
  local entry="*/5 * * * * $push_cmd >/dev/null 2>&1"
  (crontab -l 2>/dev/null; echo "$entry") | crontab -
  echo "  Installed cron entry: $entry"
  if ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
    echo "  WARNING: no cron daemon running. On WSL2 Ubuntu:  sudo service cron start"
  fi
}

install_calendar_timer() {
  local push_cmd="$1"
  # Prefer systemd-user when actually present; fall back to launchd on macOS,
  # then cron everywhere else.
  if systemctl --user is-system-running >/dev/null 2>&1; then
    install_timer_systemd "$push_cmd"
  elif [ "$(uname -s)" = "Darwin" ]; then
    install_timer_launchd "$push_cmd"
  else
    install_timer_cron "$push_cmd"
  fi
}

echo
echo "Calendar view (single-tap KEY on the device) shows today's events from any"
echo "calendar that exposes an ICS URL — Google, Outlook, iCloud, Fastmail, etc."
echo "Setting this up is optional."
printf "Connect a calendar now? [y/N]: "
read -r want_cal
case "$want_cal" in
  [yY]*)
    VENV="$SCRIPT_DIR/tools/.venv"
    if bootstrap_venv "$VENV"; then
      CONF_DIR="$HOME/.config/claude-rlcd"
      CONF="$CONF_DIR/calendar.conf"
      mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR"

      have_url=0
      if [ -f "$CONF" ] && grep -qE '^(https?|webcal|file)://' "$CONF"; then
        url_count=$(grep -cE '^(https?|webcal|file)://' "$CONF")
        echo "Found $url_count existing URL(s) in $CONF — keeping them."
        have_url=1
      fi

      # Collect as many ICS URLs as the user wants; events from all of them
      # get merged into one list. With pre-existing URLs we only offer to add
      # more; on a fresh conf we go straight to the first URL prompt.
      adding=1
      if [ "$have_url" -eq 1 ]; then
        printf "Add another calendar? [y/N]: "
        read -r more
        case "$more" in [yY]*) ;; *) adding=0 ;; esac
      fi

      if [ "$adding" -eq 1 ]; then
        cat <<'EOM'

Paste the ICS URL from your calendar provider. Where to find it:
  Google:   Settings → my calendar → "Secret address in iCal format"
  Outlook:  Settings → Calendar → Shared calendars → Publish a calendar
            (permission must be "Limited details" or higher)
  iCloud:   right-click calendar → Share → Public Calendar  (webcal://)
  Fastmail / Proton / Nextcloud: per-calendar "subscribe" link
EOM
      fi

      while [ "$adding" -eq 1 ]; do
        printf "ICS URL (or Enter to skip): "
        read -r ics_url
        ics_url=$(printf '%s' "$ics_url" | tr -d ' \n\r')
        if [ -n "$ics_url" ]; then
          if [ ! -f "$CONF" ]; then
            printf '# One ICS URL per line. Lines starting with # are ignored.\n' > "$CONF"
          fi
          printf '%s\n' "$ics_url" >> "$CONF"
          chmod 600 "$CONF"
          echo "  Wrote $CONF"
          have_url=1
        fi
        printf "Add another calendar? [y/N]: "
        read -r more
        case "$more" in [yY]*) ;; *) adding=0 ;; esac
      done

      if [ "$have_url" -eq 0 ]; then
        echo "  Skipped — calendar view will show 'no sidecar push yet' until you add one."
      fi

      if [ "$have_url" -eq 1 ]; then
        echo "Validating against the device ..."
        if "$VENV/bin/python" "$SCRIPT_DIR/tools/calendar-push.py" --push 2>&1 | sed 's/^/  /'; then
          printf "Install a 5-minute auto-refresh timer? [y/N]: "
          read -r want_timer
          case "$want_timer" in
            [yY]*) install_calendar_timer "$VENV/bin/python $SCRIPT_DIR/tools/calendar-push.py --push" ;;
            *)     echo "  Skipped. Manual refresh:  $VENV/bin/python $SCRIPT_DIR/tools/calendar-push.py --push" ;;
          esac
        else
          echo "  Push failed. Inspect the URL in $CONF and re-run ./install.sh"
        fi
      fi
    fi
    ;;
  *)
    echo "Skipped — single-tap KEY will show 'no sidecar push yet'."
    ;;
esac

# --- done ---------------------------------------------------------------------
cat <<EOF

Installed.
  Device:      http://$HOST/
  Claude hook: $CLAUDE_DIR/notify-esp32.sh        (if you enabled Claude Code)
  Codex hook:  $CLAUDE_DIR/notify-esp32-codex.sh  (if you enabled Codex)

Test the link to the device:
  curl http://$HOST/

Start a new Claude Code and/or Codex session — the screen switches to WORKING
on your first prompt and DONE when the agent finishes. Codex will ask you to
trust its hooks the first time.

Optional (the t= query arg is your pairing token; required once paired):
  echo "MyLabel" > ~/.claude/session-label                       # rename Claude session
  echo "MyLabel" > ~/.claude/session-label-codex                 # rename Codex session
  curl "http://$HOST/forget?t=\$(cat ~/.claude/esp32-token)&all=1"   # wipe sources
  curl "http://$HOST/reset-wifi?t=\$(cat ~/.claude/esp32-token)"     # re-portal
  curl "http://$HOST/show-token"                                  # flash token on LCD
EOF
