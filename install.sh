#!/usr/bin/env bash
# Install the Claude Code -> ESP32 RLCD notifier hooks on this machine.
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

# --- copy hook script ---------------------------------------------------------
mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_DIR/notify-esp32.sh" "$CLAUDE_DIR/notify-esp32.sh"
chmod +x "$CLAUDE_DIR/notify-esp32.sh"
echo "Installed $CLAUDE_DIR/notify-esp32.sh"

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

# --- merge hooks into settings.json ------------------------------------------
SNIPPET="$SCRIPT_DIR/settings-snippet.json"
SETTINGS="$CLAUDE_DIR/settings.json"

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
echo "Merged hooks into $SETTINGS  (backup saved alongside)"

# --- done ---------------------------------------------------------------------
cat <<EOF

Installed.
  Device:     http://$HOST/
  Hook script: $CLAUDE_DIR/notify-esp32.sh
  Settings:    $SETTINGS

Test the link to the device:
  curl http://$HOST/

Then start a new Claude Code session — the screen will switch to WORKING on
your first prompt and DONE when Claude finishes.

Optional (the t= query arg is your pairing token; required once paired):
  echo "MyLabel" > ~/.claude/session-label                       # rename session
  curl "http://$HOST/forget?t=\$(cat ~/.claude/esp32-token)&all=1"   # wipe sources
  curl "http://$HOST/reset-wifi?t=\$(cat ~/.claude/esp32-token)"     # re-portal
  curl "http://$HOST/show-token"                                  # flash token on LCD
EOF
