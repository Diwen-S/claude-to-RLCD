# Claude Code → ESP32-S3-RLCD-4.2 status notifier

A 4.2" 400×300 reflective LCD that lights up with `WORKING` / `DONE` /
`Action required` whenever Claude finishes a response, plus your current
5-hour session %, weekly cost, and per-source breakdowns.

Wired to Claude Code via Stop / UserPromptSubmit / Notification / PreToolUse
hooks. Supports multiple parallel Claude Code sessions with distinct labels.

Single-tap the on-board KEY button to flip the screen into an ambient
**calendar view** of today's events — date header, start + end times, a "now"
divider that walks down the list as the day progresses — sourced from any
ICS-publishing calendar (Google / Outlook / Apple / Fastmail / Nextcloud).
Tap again to flip back. See *Connecting a calendar* below.

## Quick start (recipient)

The firmware is already on the board. To set it up on a new WiFi:

1. **Power the board.** On first boot (or when the saved WiFi is unreachable),
   the screen shows `WiFi setup needed — From your phone, join Claude-RLCD-Setup`.
2. **From your phone**, open WiFi settings and join `Claude-RLCD-Setup`. A
   captive-portal browser tab opens automatically on most phones (if not, visit
   `http://192.168.4.1/`). Pick your home WiFi and enter the password.
3. The board reboots and joins your network. The screen shows the device IP in
   small text in the top-right block (e.g. `ip 192.168.1.42`).
4. **On each computer that runs Claude Code**, clone or copy this folder, then:
   ```bash
   ./install.sh
   ```
   It discovers the ESP at `http://claude-rlcd.local/` (or asks for the IP if
   mDNS isn't available — common on WSL2), prompts you for the pairing token
   the gifter wrote on the sticker (e.g. `20030102`), copies the hook script
   to `~/.claude/`, and merges the hooks into `~/.claude/settings.json`
   without touching your other settings. If the gifter forgot the sticker,
   run `curl http://claude-rlcd.local/show-token` and read the token off the
   LCD.
5. **Start a new Claude Code session.** The screen flips to `WORKING` on your
   first prompt and `DONE` when Claude finishes.

That's it. The rest of this README is reference and troubleshooting.

## Hardware

- **Board:** Waveshare ESP32-S3-RLCD-4.2 (400×300 monochrome reflective LCD, ST7305 controller).
- **GPIOs used:** SCK=11, MOSI=12, DC=5, CS=40, RST=41 (LCD), GPIO18 (KEY button, active-low, internal pull-up).
- **USB:** the single USB-C is both UART (via CH343) and the upload port.

## What's in this folder

```
claude-to-RLCD/
├── README.md                    this file
├── platformio.ini               PlatformIO board + library config
├── src/
│   ├── main.cpp                 firmware
│   └── ST7305_U8g2.cpp/.h       Waveshare ST7305 driver wrapper (vendored)
├── notify-esp32.sh              hook script — installed to ~/.claude/
├── settings-snippet.json        hook config — merged into ~/.claude/settings.json
├── install.sh                   one-shot installer for each driving machine
├── uninstall.sh                 reverse of install.sh on a single machine
└── tools/
    ├── calendar-push.py         ICS sidecar (calendar view); driven by a 5-min timer
    ├── vendor/                  bundled pure-Python wheels for offline install (icalendar etc.)
    └── .venv/                   self-contained Python env (created by install.sh; gitignored)
```

## Session labels

Each Code source on screen carries a label, with a 4-char session suffix
appended so two terminals open in the same folder still land in separate
cells. The suffix is the first 4 chars of `$CLAUDE_CODE_SESSION_ID` (a UUID
Claude exposes per terminal, stable for the life of the session), e.g.
`thesis/9838 (Code)` and `thesis/a1c2 (Code)` for two `claude` sessions in
`~/thesis`. Base-name priority:

1. `~/.claude/session-label` (file, edit anytime — no Claude restart needed)
2. `$CLAUDE_SESSION_LABEL` (env var, set before launching `claude`)
3. PWD basename (so each project folder gets its own cell automatically)
4. `$WSL_DISTRO_NAME` (e.g. `Ubuntu`, `Test`)
5. hostname

Rename the running session on the fly:
```bash
echo "Thesis" > ~/.claude/session-label   # → Thesis (Code) on next ping
rm ~/.claude/session-label                # revert to default
```

Label a fresh session per-shell without affecting others:
```bash
CLAUDE_SESSION_LABEL=Bench claude
```

Up to 4 sources fit on screen; older ones evict. A cell is removed
automatically when its `claude` session ends cleanly (`/exit`, `Ctrl-D`,
closing the terminal window) via the `SessionEnd` hook. Cells whose session
was killed abruptly (`kill -9`, WSL shutdown) stick around until a 5th
session evicts them, or until you clear manually with (where
`T=$(cat ~/.claude/esp32-token)`):
```bash
curl "http://claude-rlcd.local/forget?t=$T&src=Foo%20(Code)"
curl "http://claude-rlcd.local/forget?t=$T&all=1"
```

## Physical KEY button

The on-board KEY button (GPIO18) is the no-laptop, no-network entry point:

| Gesture | Action |
|---|---|
| **Single tap** | Toggle between Claude status view and calendar view. Both persist until tapped again; nothing auto-reverts. |
| **Double tap** (within ~350ms) | Flash pairing token on the LCD for 5s, then return to whichever view was active. Equivalent to `curl /show-token`. |
| Hold 5s, release | Clear all source cells. Equivalent to `curl /forget?all=1`. |
| Hold **15s** | Factory reset — wipes WiFi creds AND pairing token, reboots into the captive portal. |

Notes:

- The single-tap action fires ~350 ms after release (the firmware waits to see
  if a second tap is coming). Slight latency, but the trade-off is unambiguous
  single vs. double detection.
- Push events from Claude hooks (`/notify`) and from the calendar sidecar
  (`/todo`) keep updating quietly in the background — the LCD doesn't flip
  views on you when new data arrives.
- The view choice lives in RAM only. A reboot returns to the Claude status
  view; tap once to flip back.
- While the KEY is held past 1 second, the LCD shows a progress bar and the
  next-tier action so you can release in time. Releasing between 1-5 s aborts.

## What the screen shows

- **Top-left:** Claude burst logo + `Claude Code` title.
- **Top-right, two side-by-side blocks** separated by a thin vertical rule:
  - *Usage* (left): `5h XX%   reset HH:MM` and `week $XX`.
  - *Activity* (right): `last HH:MM:SS` and `resp N` (total DONE count).
- **Below the title strip:** the device IP in small text (`ip 192.168.…`).
  If the device is unpaired, the IP line also shows `PAIR ME` — run
  `install.sh` (or call `/pair?token=…` directly) to set a token.
- **Cell grid** (middle): up to 4 source cells (1 = full, 2 = side-by-side,
  3 = 2-on-top + 1, 4 = 2×2). Each cell has a small label and a big status
  word, plus an `Action required` line when relevant.
- **Bottom strip:** the daily quote (rotates once per UTC day), author
  attribution, and the `A gift from Diwen Si` inscription. See *Daily quote
  pool* below.

### Calendar view (single-tap KEY)

A full-screen ambient view of today's events, pushed by the sidecar
(`tools/calendar-push.py`) on a 5-minute timer:

- **Header band:** bold date (e.g. `Sat  Jun 6`) at left; small de-bold
  `updated Nm ago` right-aligned. The age stamp is for trust — if it reads
  `updated 47m ago` you know something has the sidecar stuck.
- **Now divider:** a horizontal row labelled `now  HH:MM` appears between
  past and upcoming events. Past events sit above it, upcoming below; if
  everything is done for the day, the divider drops to the bottom.
- **Event rows:** start time bold (the eye anchors here), end time after a
  thin dash in a smaller weight, title in regular weight. Up to 8 rows total
  including the divider; events past row 7 are truncated.
- **All-day events:** rendered with `all day` in the start column, sorted to
  the top of the list.
- **No events today:** the row area shows `no events today`.

## HTTP API on the ESP32

- `GET /` — plain-text dump of current state, including the device IP.
- `GET /notify?src=<label>&status=<word>&ts=<HH:MM:SS>&alert=<text>&sp=<%>&r=<HH:MM>&wc=<usd>`
  - `src`: source id. Omit → "main". Up to 4 sources; oldest evicts.
  - `status`: shown as big word. Updates timestamp; increments counter when "DONE".
  - `ts`: caller's local time, displayed as "last HH:MM:SS". Caller's clock
    is authoritative for the displayed timestamp — the ESP only runs NTP to
    decide which daily quote to show, not to format the activity timestamp.
    Timestamps therefore stay correct in any caller's timezone with no
    configuration on the device.
  - `alert`: optional sub-line below status. Pass empty to clear.
  - `sp`, `r`, `wc`: usage stats shown in the top-right block (last value wins across sources).
- `GET /forget?t=<token>&src=<label>` / `GET /forget?t=<token>&all=1` — clear source cells.
- `POST /todo?t=<token>&items=<body>&date=<header>` — replace today's calendar
  list. `items` is a newline-separated body where each line is three
  tab-separated fields: `<start>\t<end>\t<title>`. `<start>` may be `HH:MM`,
  `all day`, or the literal `now` (in which case the row is rendered as a
  divider and `<title>` holds the current HH:MM). `date` is the header label
  (e.g. `Sat  Jun 6`). Token-auth required once the device is paired. Used
  exclusively by `tools/calendar-push.py`; humans don't call this directly.
- `GET /reset-wifi?t=<token>` — wipe stored WiFi creds and reboot back into
  the `Claude-RLCD-Setup` captive portal. Use when moving the device to a
  new network.
- `GET /pair?token=<4-32 alnum>` — set a new pairing token. Allowed without
  auth when the device is unpaired; once paired, must include `&t=<current>`.
- `GET /unpair?t=<token>` — clear the saved token, device returns to open
  mode. Doesn't touch WiFi creds or source cells.
- `GET /show-token` — flash the saved token on the LCD for ~5s. Unauth on
  purpose; needs physical line-of-sight to read.
- `GET /quote-tour` — cycle through every quote in the pool, 5s each
  (~100s total). For visual QA after editing the pool. Unauth; auto-clears.

All write endpoints (`/notify`, `/forget`, `/todo`, `/reset-wifi`, `/unpair`)
require `?t=<token>` once the device is paired. `/`, `/show-token`,
`/quote-tour`, and `/pair` (in open mode) stay public.

## Daily quote pool

The bottom strip rotates through 20 verified quotes (11 English, 9 Chinese,
shuffled so consecutive days alternate languages where possible). Selection
is deterministic per UTC day:

```
index_for_today = (unix_seconds / 86400) % 20
```

so all paired devices on the same firmware show the same quote on the same
day. The strip also carries the gift inscription `A gift from Diwen Si`
right-aligned, separated from the author attribution.


To edit the pool or rotation order, see `QUOTES[]` and `QUOTE_ORDER[]` in
`src/main.cpp`. After any change, rebuild and call `curl
http://claude-rlcd.local/quote-tour` to cycle every entry visually.

## Connecting a calendar

The calendar view is fed by `tools/calendar-push.py`. It reads ICS URLs from
`~/.config/claude-rlcd/calendar.conf`, expands today's recurring events,
formats them, and POSTs the list to the device's `/todo` endpoint. The script
holds the calendar URLs; the device never sees them, never speaks TLS to the
outside world.

Network I/O uses only Python's standard library (`urllib.request`); the three
parsing deps (`icalendar`, `recurring_ical_events`, `python-dateutil`) are
pure-Python and bundled as wheels in `tools/vendor/`, so `install.sh` can
bootstrap the sidecar without hitting PyPI — useful on locked-down corporate
networks or during gift-unboxing without internet.

### Quick setup (via `install.sh`)

`install.sh` walks you through the whole calendar setup at the end of the
ESP-pairing flow. Just answer `y` when it asks "Connect a calendar now?", paste
your ICS URL (the prompt lists where to find it per provider), and answer `y`
again to "Install a 5-minute auto-refresh timer?". The installer:

1. Bootstraps the venv at `tools/.venv` and installs the three Python deps,
   **offline if possible** — `install.sh` first tries the bundled wheels in
   `tools/vendor/`, only falling back to PyPI if the vendor dir is missing
   or stale. So the calendar works even on machines without internet at
   install time (corporate proxies, university firewalls, gift unboxing).
   On Debian/Ubuntu you may first need `sudo apt install python3-venv`.
2. Writes the URL to `~/.config/claude-rlcd/calendar.conf` (mode `0600`).
3. Runs a live `--push` to confirm the LCD picks it up.
4. Installs the right kind of refresh timer for your OS:
   - **systemd-user** unit on regular Linux,
   - **launchd** agent on macOS,
   - **cron** entry otherwise (including WSL2 without systemd).
5. Prints the command for checking the timer's status.

To wire up a second calendar later, add another line to
`~/.config/claude-rlcd/calendar.conf` and the next timer tick picks it up — no
re-run needed. To swap providers entirely, re-run `./install.sh` and answer
through the prompts again.

### Manual setup (skipping `install.sh`)

```bash
# 1. Bootstrap the venv (once). Offline install from the bundled wheels:
python3 -m venv tools/.venv
tools/.venv/bin/pip install --no-index --find-links tools/vendor/ \
    icalendar recurring_ical_events python-dateutil
# (Drop --no-index --find-links to pull current versions from PyPI instead.)

# 2. Drop the URL in the conf (one per line; '#' for comments).
mkdir -p ~/.config/claude-rlcd && chmod 700 ~/.config/claude-rlcd
$EDITOR ~/.config/claude-rlcd/calendar.conf
chmod 600 ~/.config/claude-rlcd/calendar.conf

# 3. Dry-run (prints what would be sent; does not contact the device).
tools/.venv/bin/python tools/calendar-push.py

# 4. Push once to confirm the LCD picks it up.
tools/.venv/bin/python tools/calendar-push.py --push
```

Then install a timer using one of the snippets under *Scheduling the 5-min
refresh* below.

### Where to get the ICS URL

Any calendar provider that exposes ICS works — Google, Apple iCloud,
Microsoft 365 / Outlook.com, Fastmail, Proton, Nextcloud, self-hosted CalDAV
with publish, Zoho. ICS is a standard, not a Google-specific format.

| Provider | Path to the URL |
|---|---|
| **Google Calendar** | Settings → Settings for my calendars → pick calendar → *Integrate calendar* → **Secret address in iCal format** |
| **Apple iCloud Calendar** | Calendar.app → right-click the calendar → *Share* → *Public Calendar* → copy the `webcal://` URL (the sidecar normalizes the scheme) |
| **Outlook / Microsoft 365** | Settings → Calendar → *Shared calendars* → *Publish a calendar* → permission must be at least *Limited details* → copy the **ICS** link |
| **Fastmail / Proton / Nextcloud** | Each calendar has a per-calendar "subscribe link" (ICS) in its settings page |
| **Local file** | `file:///path/to/today.ics` works too, for testing |

Multiple calendars can coexist in the conf file (one URL per line); the
sidecar merges them and sorts by start time.

### Caveats per provider

- **Outlook publishing is cached server-side.** New events can take up to ~24
  hours to appear in the published ICS. Don't conclude the sidecar is broken
  if a freshly-added event isn't showing — check the raw ICS with `curl
  <url> | head -50` first.
- **Outlook publishing may be disabled by your tenant.** Corporate M365
  admins frequently set `PublishingEnabled = $false`. Workaround: subscribe
  the work calendar from a personal Google calendar (Calendar → "Other
  calendars" → "From URL") and publish *that*.
- **Permission level matters on Outlook.** "Availability only" strips event
  titles; you need *Limited details* or *Full details* for the LCD to be
  useful.

### Security

The ICS "secret address" is a long-form bearer credential — anyone holding
the URL can read every event on that calendar until you rotate the link
inside the calendar provider's UI. Keep the conf file at mode `0600`
(default) and avoid pasting the URL into chat logs or commit messages. The
URL stays on the laptop; never reaches the ESP32 over WiFi.

### Scheduling the 5-min refresh

The sidecar is a one-shot CLI; a system timer drives it on a 5-minute cadence.

**Linux / WSL2 (systemd user timer):**

```ini
# ~/.config/systemd/user/claude-calendar.service
[Unit]
Description=Push today's calendar to the RLCD

[Service]
Type=oneshot
ExecStart=%h/path/to/claude-to-RLCD/tools/.venv/bin/python %h/path/to/claude-to-RLCD/tools/calendar-push.py --push
```

```ini
# ~/.config/systemd/user/claude-calendar.timer
[Unit]
Description=Push today's calendar every 5 min

[Timer]
OnBootSec=30
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now claude-calendar.timer
```

**macOS (launchd agent):** create `~/Library/LaunchAgents/sh.diwen.claude-calendar.plist`
with `StartInterval` = 300 and `ProgramArguments` pointing at the venv python +
the script, then `launchctl load -w` it.

**Fallback (cron):**

```cron
*/5 * * * * /path/to/claude-to-RLCD/tools/.venv/bin/python /path/to/claude-to-RLCD/tools/calendar-push.py --push >> /tmp/claude-calendar.log 2>&1
```

The device shows `updated Nm ago` on the calendar view, so any timer failure
is visible from across the room.

## Access control / pairing

The device gates write endpoints behind a shared token (4-32 alphanumeric
characters, e.g. `20030102` or `kitchen42`). Anyone on the LAN can read `/`,
but only callers that send `?t=<token>` can change the screen.

**Pre-pair before gifting** (recommended):
```bash
curl "http://claude-rlcd.local/pair?token=20030102"
```
Write the token on a sticker, hand it over with the device. `install.sh`
prompts the recipient for it on first run.

**Recipient pairs themselves:** if the device boots in open mode (screen shows
`PAIR ME`), `install.sh` asks them to choose a token and calls `/pair`
automatically.

**Change the token** (must include the current one):
```bash
curl "http://claude-rlcd.local/pair?token=NEWTOKEN&t=20030102"
```

**Forgot the token:** any LAN host can call `curl http://claude-rlcd.local/show-token`
to flash it on the LCD for 5s. To wipe and re-pair without the old token,
re-flash the firmware (Preferences NVS gets cleared on a chip erase).

**Unpair entirely** (e.g. before gifting the device to someone else, so they
can pair it fresh):
```bash
curl "http://claude-rlcd.local/unpair?t=<current-token>"
```
The screen will switch back to `PAIR ME` and any LAN host can `/pair` it.

**Detach a single machine** (without touching the device, leaving other
paired machines working):
```bash
./uninstall.sh
```
Removes `~/.claude/{notify-esp32.sh,esp32-ip,esp32-token}` and strips the
notify hooks from `~/.claude/settings.json`, preserving every other setting.

Caveat: this is LAN-level access control, not encryption. Traffic is plain
HTTP, so anyone with the WiFi password who captures the four-way handshake
can read it. Adequate for a home gift; not a security boundary against a
determined attacker on the same network.

---

## Troubleshooting

### Re-flashing the firmware

You only need this if you're building or modifying the firmware yourself.
Recipients of a pre-flashed board do not.

**In Windows VS Code with the PlatformIO IDE extension**: open this folder and
click PlatformIO **Upload** (→).

**From a WSL shell**:
```bash
cd /mnt/d/dev/claude-to-RLCD
/mnt/c/Users/75972/.platformio/penv/Scripts/platformio.exe run --target upload --upload-port COM7
```

**Upload fails / no COM port** — hold BOOT, tap PWR, release BOOT, retry.

### Reading the boot log from WSL (no extra tools)

`HardwareSerial` output is silent on this board (the native-USB serial isn't
broken out). Diagnostics are emitted via `esp_rom_printf`. To capture them
from WSL:

```powershell
powershell.exe -NoProfile -Command "& { \$p = New-Object System.IO.Ports.SerialPort 'COM7',115200,'None',8,'One'; \$p.ReadTimeout = 200; \$p.DtrEnable = \$false; \$p.RtsEnable = \$false; \$p.Open(); \$p.RtsEnable = \$true; Start-Sleep -Milliseconds 100; \$p.RtsEnable = \$false; \$end = (Get-Date).AddSeconds(15); while ((Get-Date) -lt \$end) { Start-Sleep -Milliseconds 100; if (\$p.BytesToRead -gt 0) { Write-Host -NoNewline \$p.ReadExisting() } }; \$p.Close() }"
```

Look for `[wifi] ip=...` and `[mdns] http://claude-rlcd.local/`.

### Manual install (skipping `install.sh`)

```bash
cp notify-esp32.sh ~/.claude/notify-esp32.sh
chmod +x ~/.claude/notify-esp32.sh
echo claude-rlcd.local > ~/.claude/esp32-ip      # or the IP
echo 20030102          > ~/.claude/esp32-token   # pairing token from the sticker
chmod 600                ~/.claude/esp32-token
# then hand-merge settings-snippet.json's "hooks" block into ~/.claude/settings.json
```

Skip the `esp32-token` line only if the device is still in open mode
(`paired = no` in the `/` dump). Once paired, every `/notify` without the
token returns 403 and nothing reaches the screen.

Dependencies: `node` (for `npx`), `python3`, `curl`. `notify-esp32.sh` invokes
`npx ccusage` to fetch the current 5-hour window and weekly spend.

### Other gotchas

- **Screen blank after upload** — wrong panel driver or pin map. This board
  needs `ST7305_U8g2` (vendored) with the pins above; GxEPD2 won't drive it.
- **`Serial.println` silent** — known: HardwareSerial USB CDC isn't wired out
  on this board. Use `esp_rom_printf` instead.
- **mDNS (`claude-rlcd.local`) doesn't resolve from WSL2** — expected; WSL2 has
  no Avahi by default. `install.sh` falls back to asking for the IP, which the
  device prints in the top-right of the screen.
- **Can't reach the ESP** — confirm with `curl http://<ip>/`. WSL2 outbound to
  LAN works by default; if not, allow it in Windows Defender Firewall.
- **Forgot WiFi password / moved house** — `curl "http://<host>/reset-wifi?t=$(cat ~/.claude/esp32-token)"`
  reopens the captive portal; or briefly cut power while holding the device
  reset and the firmware will reopen the portal once it can't connect.
- **Getting `403 Forbidden` from the device** — the device is paired but the
  caller didn't send the token. Check `cat ~/.claude/esp32-token`; if missing
  or wrong, re-run `install.sh` and re-enter it. To read the token off the
  LCD: `curl http://<host>/show-token`.
- **Forgot the pairing token entirely** — `curl http://<host>/show-token`
  flashes it on the LCD for 5s (unauthenticated; you need physical
  line-of-sight). If even the device is lost, re-flash the firmware to wipe
  the NVS and pair fresh.
