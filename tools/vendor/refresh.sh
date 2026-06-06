#!/usr/bin/env bash
# Re-download the bundled wheels from PyPI into this directory.
# Run on a machine with internet, then `git add tools/vendor/` and commit.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV="$ROOT/tools/.venv"

if [ ! -x "$VENV/bin/pip" ]; then
  echo "venv not found at $VENV — run ./install.sh first (and answer yes to the calendar prompt)."
  exit 1
fi

echo "Wiping old wheels in $SCRIPT_DIR ..."
rm -f "$SCRIPT_DIR"/*.whl

echo "Downloading current versions from PyPI ..."
"$VENV/bin/pip" download --dest "$SCRIPT_DIR" icalendar recurring_ical_events python-dateutil

echo
echo "Done. New contents:"
ls -lh "$SCRIPT_DIR"/*.whl

echo
echo "Next: git add tools/vendor/ && git commit -m 'vendor: refresh sidecar wheels'"
