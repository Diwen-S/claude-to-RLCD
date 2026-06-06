#!/usr/bin/env python3
"""Fetch ICS calendars, format today's events, optionally push to the RLCD."""

import argparse
import os
import pathlib
import sys
from datetime import datetime, timedelta
from urllib.parse import urlparse

import icalendar
import recurring_ical_events
import requests
from dateutil import tz

CONFIG_PATH = pathlib.Path.home() / ".config" / "claude-rlcd" / "calendar.conf"
IP_FILE = pathlib.Path.home() / ".claude" / "esp32-ip"
TOKEN_FILE = pathlib.Path.home() / ".claude" / "esp32-token"

MAX_LINES = 8
TITLE_WIDTH = 28
FETCH_TIMEOUT = 10

# Each line sent to the device is three tab-separated fields: <start>\t<end>\t<title>.
# The firmware renders start bold, end thinner/smaller, and title in regular weight.
#   "HH:MM"  "HH:MM"  "<title>"   timed event with end
#   "HH:MM"  ""       "<title>"   instantaneous / unknown end
#   "all day" ""      "<title>"   VEVENT with a DATE (not DATETIME) DTSTART
#   "now"    ""       "HH:MM"     special "now" divider (title holds the current time)


def read_config(path):
    if not path.exists():
        return []
    urls = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            urls.append(line)
    return urls


def normalize_url(url):
    # Apple iCloud / many calendar clients hand out webcal:// — same wire format as https.
    p = urlparse(url)
    if p.scheme in ("webcal", "webcals"):
        return url.replace(p.scheme + "://", "https://", 1)
    if p.scheme == "file":
        return url
    return url


def load_calendar(url):
    if url.startswith("file://"):
        body = pathlib.Path(url[7:]).read_bytes()
    else:
        r = requests.get(url, timeout=FETCH_TIMEOUT)
        r.raise_for_status()
        body = r.content
    return icalendar.Calendar.from_ical(body)


def today_events(cal, local_tz):
    start = datetime.now(local_tz).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=1)
    return recurring_ical_events.of(cal).between(start, end)


def fmt_hhmm(dt, local_tz):
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=local_tz)
    return dt.astimezone(local_tz).strftime("%H:%M")


def fmt_fields(start, end, local_tz):
    if not hasattr(start, "hour"):
        return ("all day", "")
    s = fmt_hhmm(start, local_tz)
    if end is None or not hasattr(end, "hour"):
        return (s, "")
    e = fmt_hhmm(end, local_tz)
    if e == s:
        return (s, "")
    return (s, e)


def collect_lines(urls, local_tz):
    rows = []
    errors = []
    for url in urls:
        try:
            cal = load_calendar(normalize_url(url))
            for ev in today_events(cal, local_tz):
                start = ev.get("DTSTART").dt
                end_prop = ev.get("DTEND")
                end = end_prop.dt if end_prop is not None else None
                title = str(ev.get("SUMMARY", "(no title)")).strip()
                rows.append((start, end, title))
        except Exception as e:
            errors.append(f"{url}: {e}")
    rows.sort(key=lambda r: (hasattr(r[0], "hour"), r[0]))

    # Materialise normal event rows first (capped so a "now" marker still fits).
    now = datetime.now(local_tz)
    cap = MAX_LINES - 1 if rows else MAX_LINES
    formatted = []
    for start, end, title in rows[:cap]:
        sf, ef = fmt_fields(start, end, local_tz)
        formatted.append((start, f"{sf}\t{ef}\t{title[:TITLE_WIDTH]}"))

    # Decide where to slot the now-divider: before the first event that hasn't
    # started yet. If none have, slot it at the end (everything's done).
    now_line = f"now\t\t{now.strftime('%H:%M')}"
    if not formatted:
        return [], errors
    insert_at = len(formatted)
    for i, (start, _) in enumerate(formatted):
        if hasattr(start, "hour"):
            s_aware = start if start.tzinfo else start.replace(tzinfo=local_tz)
            if s_aware > now:
                insert_at = i
                break
        # all-day rows never displace the marker.
    out = [line for _, line in formatted]
    out.insert(insert_at, now_line)
    return out, errors


def today_date_header(local_tz):
    # Fantastical-style: "Sat  Jun 6". Two spaces between weekday and date for
    # a slight visual gap; the firmware renders it as one big bold string.
    return datetime.now(local_tz).strftime("%a  %b ") + str(datetime.now(local_tz).day)


def push(lines, host, token, date_str):
    body = "\n".join(lines)
    params = {"items": body, "date": date_str}
    if token:
        params["t"] = token
    r = requests.post(f"http://{host}/todo", params=params, timeout=5)
    return r.status_code, r.text.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(CONFIG_PATH))
    ap.add_argument("--push", action="store_true",
                    help="POST to the device (default is dry-run, prints to stdout)")
    ap.add_argument("--host", default=None,
                    help="device host (default: contents of ~/.claude/esp32-ip)")
    args = ap.parse_args()

    urls = read_config(pathlib.Path(args.config))
    if not urls:
        print(f"no calendars configured in {args.config}", file=sys.stderr)
        sys.exit(2)

    local_tz = tz.tzlocal()
    lines, errors = collect_lines(urls, local_tz)
    date_str = today_date_header(local_tz)

    for err in errors:
        print(f"warn: {err}", file=sys.stderr)

    if not args.push:
        print(f"# date: {date_str}")
        if not lines:
            print("(no events today)")
        else:
            print("\n".join(lines))
        return

    host = args.host
    if not host and IP_FILE.exists():
        host = IP_FILE.read_text().strip()
    if not host:
        host = "claude-rlcd.local"
    token = TOKEN_FILE.read_text().strip() if TOKEN_FILE.exists() else ""

    code, body = push(lines, host, token, date_str)
    print(f"{host} → {code} {body}", file=sys.stderr)
    sys.exit(0 if code == 200 else 1)


if __name__ == "__main__":
    main()
