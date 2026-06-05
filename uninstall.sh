#!/usr/bin/env bash
# Remove the Claude Code -> ESP32 RLCD notifier from THIS machine.
# Leaves the device itself alone (other paired machines keep working).
# To wipe the device's pairing token entirely, hit GET /unpair on the device.
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# --- remove the local files we put down --------------------------------------
removed=()
for f in notify-esp32.sh esp32-ip esp32-token; do
  if [ -e "$CLAUDE_DIR/$f" ]; then
    rm -f "$CLAUDE_DIR/$f"
    removed+=("$CLAUDE_DIR/$f")
  fi
done

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
echo
echo "The ESP itself was NOT touched. To wipe its pairing token too:"
echo "  curl \"http://claude-rlcd.local/unpair?t=<current-token>\""
echo "(or hit /reset-wifi to also reopen the captive portal)"
