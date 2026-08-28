#!/usr/bin/env bash
# Remove the Claude Code and Codex -> ESP32 RLCD notifiers from THIS machine.
# Leaves the device itself alone (other paired machines keep working).
# Also tears down the calendar sidecar's auto-refresh timer (systemd-user
# unit / launchd agent / cron entry) if install.sh set one up. The calendar
# conf file and the sidecar's Python venv are kept by default — pass
# --purge-calendar to delete those too.
#
# If you're about to delete the cloned repo folder from Windows Explorer,
# pass --purge-calendar; otherwise tools/.venv/ stays and its deeply nested
# wheel paths trip Explorer's 260-char MAX_PATH limit (error 0x80070780).
# Plain `rm -rf` from WSL/Linux/macOS doesn't have the same problem.
#
# To unpair the device and generate a fresh code, hit GET /unpair.
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAL_CONF_DIR="$HOME/.config/claude-rlcd"

# --- remove the local files we put down --------------------------------------
removed=()
for f in notify-esp32.sh notify-esp32-codex.sh esp32-ip esp32-token; do
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
# Used for both the CLI settings.json in $HOME and, under WSL, the Claude Code
# desktop app's settings.json in the Windows profile. Prints the number of
# handlers removed. Note the "notify-esp32.sh" match does not catch
# "notify-esp32-codex.sh", which is handled separately via its TOML block.
strip_settings() {
  local target="$1"
  [ -f "$target" ] || { echo 0; return; }
  cp "$target" "$target.bak.$(date +%Y%m%d-%H%M%S)"
  python3 - "$target" <<'PY'
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
}

hooks_stripped=$(strip_settings "$SETTINGS")

# Claude Code desktop on Windows keeps its own settings.json in the Windows
# profile. Mirrors install_claude_desktop's discovery.
desktop_stripped=0
desktop_settings=""
if grep -qi microsoft /proc/version 2>/dev/null; then
  winprofile=$(powershell.exe -NoProfile -Command 'Write-Output $env:USERPROFILE' 2>/dev/null | tr -d ' \r\n') || true
  if [ -n "$winprofile" ] && command -v wslpath >/dev/null 2>&1; then
    conv=$(wslpath -u "$winprofile" 2>/dev/null) || conv=""
    [ -n "$conv" ] && [ -f "$conv/.claude/settings.json" ] && desktop_settings="$conv/.claude/settings.json"
  fi
  if [ -z "$desktop_settings" ]; then
    for d in /mnt/c/Users/*/.claude/settings.json; do
      [ -f "$d" ] && { desktop_settings="$d"; break; }
    done
  fi
  if [ -n "$desktop_settings" ]; then
    desktop_stripped=$(strip_settings "$desktop_settings")
  fi
fi

# --- strip our Codex hook block from config.toml -----------------------------
# Mirrors install.sh's Codex-home discovery; removes only the marked block.
# Collect *every* Codex home, not just the first. A machine can easily have
# two — a native CLI in ~/.codex and the Windows build under /mnt/c/Users/<you>
# — and stopping at the first match used to leave the other one holding hooks
# that call a script this uninstaller has already deleted. Those dangling hooks
# then fail silently on every Codex session.
codex_stripped=0
codex_confs=()
add_conf() {
  [ -f "$1" ] || return 0
  local c
  for c in "${codex_confs[@]}"; do [ "$c" = "$1" ] && return 0; done
  codex_confs+=("$1")
}
[ -n "$CODEX_HOME" ] && add_conf "$CODEX_HOME/config.toml"
add_conf "$HOME/.codex/config.toml"
if grep -qi microsoft /proc/version 2>/dev/null; then
  for d in /mnt/c/Users/*/.codex; do add_conf "$d/config.toml"; done
fi

for codex_conf in "${codex_confs[@]}"; do
if grep -q '# >>> claude-rlcd codex hooks' "$codex_conf" 2>/dev/null; then
  cp "$codex_conf" "$codex_conf.bak.$(date +%Y%m%d-%H%M%S)"
  CONF="$codex_conf" python3 - <<'PY'
import os, re
p = os.environ["CONF"]
text = open(p).read()

# Keep this in step with install.sh: Codex appends its own keys (notably
# [projects."<dir>"] trust_level) at EOF, which is inside our markers. Drop
# only the tables install.sh generated; preserve everything else in place.
OURS = re.compile(
    r"\[\[hooks\.(?:UserPromptSubmit|Stop|PermissionRequest|PreToolUse|SessionEnd)"
    r"(?:\.hooks)?\]\]$")
HEADER = re.compile(r"\[\[?[^\[\]]+\]\]?$")
MARKER = re.compile(r"# (?:>>>|<<<) claude-rlcd codex hooks")

m = re.search(
    r"\n*# >>> claude-rlcd codex hooks.*?# <<< claude-rlcd codex hooks <<<\n?",
    text, flags=re.S)
if m:
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
    text = text[:m.start()] + ("\n" + foreign + "\n" if foreign else "\n") + text[m.end():]
open(p, "w").write(text.rstrip("\n") + "\n")
PY
  codex_stripped=$((codex_stripped + 1))
  codex_stripped_paths="${codex_stripped_paths}${codex_stripped_paths:+, }$codex_conf"
fi
done

# --- report ------------------------------------------------------------------
echo "Uninstalled."
if [ ${#removed[@]} -gt 0 ]; then
  printf "  removed:\n"; printf "    %s\n" "${removed[@]}"
else
  echo "  no local files to remove (already clean)"
fi
echo "  stripped $hooks_stripped notify-esp32.sh hook entr$([ "$hooks_stripped" = "1" ] && echo "y" || echo "ies") from $SETTINGS"
if [ -n "$desktop_settings" ]; then
  echo "  stripped $desktop_stripped desktop hook entr$([ "$desktop_stripped" = "1" ] && echo "y" || echo "ies") from $desktop_settings"
  echo "  (restart the Claude desktop app for that to take effect)"
fi
if [ "$codex_stripped" -gt 0 ] 2>/dev/null; then
  echo "  stripped Codex hook block from $codex_stripped config$([ "$codex_stripped" = "1" ] || echo "s"): $codex_stripped_paths"
  echo "  (backups saved alongside each)"
fi
if [ -n "$cal_timer_removed" ]; then
  echo "  removed calendar timer ($cal_timer_removed)"
fi
if [ -n "$cal_purged" ]; then
  echo "  purged calendar files: $cal_purged"
elif [ -d "$CAL_CONF_DIR" ] || [ -d "$SCRIPT_DIR/tools/.venv" ]; then
  echo "  calendar conf + venv kept (run ./uninstall.sh --purge-calendar to remove)"
fi
echo
echo "The ESP itself was NOT touched. To unpair it and generate a new code:"
echo "  curl \"http://claude-rlcd.local/unpair?t=<current-code>\""
echo "(or hit /reset-wifi to also reopen the captive portal)"
