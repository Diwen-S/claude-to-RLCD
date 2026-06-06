#!/usr/bin/env bash
# Remove the Claude Code -> ESP32 RLCD notifier from THIS machine.
# Leaves the device itself alone (other paired machines keep working).
# Also tears down the calendar sidecar's auto-refresh timer (systemd-user
# unit / launchd agent / cron entry) if install.sh set one up. The calendar
# conf file and the sidecar's Python venv are kept by default — pass
# --purge-calendar to delete those too.
# To wipe the device's pairing token entirely, hit GET /unpair on the device.
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAL_CONF_DIR="$HOME/.config/claude-rlcd"

# --- remove the local files we put down --------------------------------------
removed=()
for f in notify-esp32.sh esp32-ip esp32-token; do
  if [ -e "$CLAUDE_DIR/$f" ]; then
    rm -f "$CLAUDE_DIR/$f"
    removed+=("$CLAUDE_DIR/$f")
  fi
done

# --- tear down the calendar timer (whichever platform installed it) ----------
cal_timer_removed=""
if systemctl --user is-system-running >/dev/null 2>&1 \
   && systemctl --user list-unit-files 2>/dev/null | grep -q '^claude-calendar\.timer'; then
  systemctl --user disable --now claude-calendar.timer >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/claude-calendar.timer" \
        "$HOME/.config/systemd/user/claude-calendar.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  cal_timer_removed="systemd-user timer"
fi
plist="$HOME/Library/LaunchAgents/sh.diwen.claude-calendar.plist"
if [ -f "$plist" ]; then
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  cal_timer_removed="${cal_timer_removed:+$cal_timer_removed, }launchd agent"
fi
if crontab -l 2>/dev/null | grep -qF "calendar-push.py"; then
  crontab -l 2>/dev/null | grep -vF "calendar-push.py" | crontab -
  cal_timer_removed="${cal_timer_removed:+$cal_timer_removed, }cron entry"
fi

# Calendar conf + venv: leave behind by default (URLs are user data; the venv
# is reusable). Pass --purge-calendar to also wipe them.
purge_calendar=0
for arg in "$@"; do
  [ "$arg" = "--purge-calendar" ] && purge_calendar=1
done
cal_purged=""
if [ "$purge_calendar" -eq 1 ]; then
  if [ -d "$CAL_CONF_DIR" ]; then
    rm -rf "$CAL_CONF_DIR"
    cal_purged="$CAL_CONF_DIR"
  fi
  if [ -d "$SCRIPT_DIR/tools/.venv" ]; then
    rm -rf "$SCRIPT_DIR/tools/.venv"
    cal_purged="${cal_purged:+$cal_purged, }$SCRIPT_DIR/tools/.venv"
  fi
fi

# --- strip our hook entries from settings.json -------------------------------
hooks_stripped=0
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
  hooks_stripped=$(python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        settings = json.load(f)
        if not isinstance(settings, dict): settings = {}
except Exception:
    settings = {}
hooks = settings.get("hooks", {}) or {}
removed = 0
for event in list(hooks.keys()):
    kept = []
    for h in hooks[event] or []:
        cmds = [hh.get("command","") for hh in h.get("hooks", [])]
        if any("notify-esp32.sh" in c for c in cmds):
            removed += 1
            continue
        kept.append(h)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)
with open(p, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(removed)
PY
)
fi

# --- report ------------------------------------------------------------------
echo "Uninstalled."
if [ ${#removed[@]} -gt 0 ]; then
  printf "  removed:\n"; printf "    %s\n" "${removed[@]}"
else
  echo "  no local files to remove (already clean)"
fi
echo "  stripped $hooks_stripped notify-esp32.sh hook entr$([ "$hooks_stripped" = "1" ] && echo "y" || echo "ies") from $SETTINGS"
if [ -n "$cal_timer_removed" ]; then
  echo "  removed calendar timer ($cal_timer_removed)"
fi
if [ -n "$cal_purged" ]; then
  echo "  purged calendar files: $cal_purged"
elif [ -d "$CAL_CONF_DIR" ] || [ -d "$SCRIPT_DIR/tools/.venv" ]; then
  echo "  calendar conf + venv kept (run ./uninstall.sh --purge-calendar to remove)"
fi
echo
echo "The ESP itself was NOT touched. To wipe its pairing token too:"
echo "  curl \"http://claude-rlcd.local/unpair?t=<current-token>\""
echo "(or hit /reset-wifi to also reopen the captive portal)"
