# Bundled wheels for the calendar sidecar

`install.sh` uses these to set up `tools/.venv` **without an internet
connection**, so the calendar feature works on recipients' locked-down
networks (corporate proxies, university firewalls, offline gift unboxing).

If the vendor dir is missing or doesn't satisfy the resolver, `install.sh`
falls back to PyPI — vendoring is purely an availability shortcut, never a
hard dependency.

## What's in here

Pure-Python wheels (`*-py3-none-any.whl` or `*-py2.py3-none-any.whl`), so the
same files work on Linux, macOS, WSL, and Windows.

- `icalendar` — RFC 5545 ICS parser.
- `recurring_ical_events` — RRULE/EXDATE expansion for today's date range.
- `python_dateutil` — timezone-aware datetime math.
- `six`, `typing_extensions`, `tzdata`, `x_wr_timezone`, `click` — transitives.

Total ≈ 1.5 MB committed to the repo. They version-bump rarely; refreshing
once or twice a year is plenty.

## How to refresh

Run on a machine with internet access:

```bash
./tools/vendor/refresh.sh
git add tools/vendor/
git commit -m "vendor: refresh sidecar wheels"
```

The script downloads the current versions of the three direct deps plus all
transitives `pip` resolves, into this directory. Inspect the diff before
committing — wheel filenames encode the version, so a bumped version shows up
as a paired add/delete.
