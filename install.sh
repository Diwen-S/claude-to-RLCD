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

probe() {
  curl -sf -m 4 "http://$1/" -o /dev/null
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
mkdir -p "$CLAUDE_DIR"
printf '%s\n' "$HOST" > "$CLAUDE_DIR/esp32-ip"
echo "Wrote $CLAUDE_DIR/esp32-ip ($HOST)"

# --- pairing token ------------------------------------------------------------
# The ESP rejects /notify without ?t=<token> once it has been paired. The
# device is either:
#   - already paired by the gifter — recipient types the token on the sticker
#   - in open mode — anyone on LAN may pair it now by choosing a token
device_state=$(curl -s -m 3 "http://$HOST/" | awk '/^paired/ {print $3, $4, $5}')
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
    pair_resp=$(curl -sf -m 5 "http://$HOST/pair?token=$new_token") || {
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
  if [ -n "$existing_token" ] && curl -sf -m 4 "http://$HOST/notify?t=$existing_token&src=__probe&status=__probe" -o /dev/null; then
    # Undo the probe so we don't leave junk on the screen.
    curl -sf -m 3 "http://$HOST/forget?t=$existing_token&src=__probe" -o /dev/null || true
    echo "  Existing $CLAUDE_DIR/esp32-token already works — keeping it."
  else
    printf "Enter pairing token from the device owner: "
    read -r entered_token
    entered_token=$(printf '%s' "$entered_token" | tr -d ' \n\r')
    [ -z "$entered_token" ] && { echo "No token given. Aborting."; exit 1; }
    if ! curl -sf -m 4 "http://$HOST/notify?t=$entered_token&src=__probe&status=__probe" -o /dev/null; then
      echo "Token rejected by device. Ask owner for the right one, or run"
      echo "  curl http://$HOST/show-token   (flashes it on the LCD)"
      exit 1
    fi
    curl -sf -m 3 "http://$HOST/forget?t=$entered_token&src=__probe" -o /dev/null || true
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

install_codex() {
  cp "$SCRIPT_DIR/notify-esp32-codex.sh" "$CLAUDE_DIR/notify-esp32-codex.sh"
  chmod +x "$CLAUDE_DIR/notify-esp32-codex.sh"
  echo "  Installed $CLAUDE_DIR/notify-esp32-codex.sh"
  local script="$CLAUDE_DIR/notify-esp32-codex.sh"

  # Locate the Codex home (config.toml lives here).
  local cdir=""
  if [ -n "$CODEX_HOME" ] && [ -d "$CODEX_HOME" ]; then
    cdir="$CODEX_HOME"
  elif [ -d "$HOME/.codex" ]; then
    cdir="$HOME/.codex"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    # WSL with Codex installed on the Windows side.
    local d
    for d in /mnt/c/Users/*/.codex; do
      if [ -f "$d/config.toml" ]; then cdir="$d"; break; fi
    done
  fi
  if [ -z "$cdir" ]; then
    printf "  Could not find a Codex home. Enter path to your .codex dir (Enter to skip): "
    read -r cdir
    cdir=$(printf '%s' "$cdir" | tr -d ' \n\r')
    [ -z "$cdir" ] && { echo "  Skipped Codex."; return; }
  fi
  [ -d "$cdir" ] || { echo "  $cdir is not a directory — skipping Codex."; return; }
  local conf="$cdir/config.toml"
  [ -f "$conf" ] || : > "$conf"

  # Codex runs the hook on its own OS. If its home is a Windows mount, Codex is
  # the Windows build and reaches the WSL script via wsl.exe; otherwise it calls
  # the script directly.
  local run="$script"
  case "$cdir" in
    /mnt/[a-z]/*) run="wsl.exe -e $script" ;;
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
command = '$run working'

[[hooks.Stop]]
matcher = ""
[[hooks.Stop.hooks]]
type = "command"
command = '$run done'

[[hooks.PermissionRequest]]
matcher = ""
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '$run action'

[[hooks.PreToolUse]]
matcher = ""
[[hooks.PreToolUse.hooks]]
type = "command"
command = '$run clear'
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
# Strip any prior managed block, then append the fresh one at EOF.
text = re.sub(
    r"\n*# >>> claude-rlcd codex hooks.*?# <<< claude-rlcd codex hooks <<<\n?",
    "\n", text, flags=re.S)
text = text.rstrip("\n")
text = (text + "\n\n" if text else "") + block + "\n"
with open(conf, "w") as f:
    f.write(text)
PY
  echo "  Wrote Codex hooks into $conf  (backup saved alongside)"
  echo "  NOTE: Codex trust-gates hooks — approve them on your first 'codex' run."
}

echo
printf "Set up Claude Code? [Y/n]: "
read -r want_claude
case "$want_claude" in
  [nN]*) echo "  Skipped Claude Code." ;;
  *)     install_claude ;;
esac

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
