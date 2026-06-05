# Claude Code → ESP32-S3-RLCD-4.2 status notifier

A 4.2" 400×300 reflective LCD that lights up with `WORKING` / `DONE` /
`Action required` whenever Claude finishes a response, plus your current
5-hour session %, weekly cost, and per-source breakdowns.

Wired to Claude Code via Stop / UserPromptSubmit / Notification / PreToolUse
hooks. Supports multiple parallel Claude Code sessions with distinct labels.

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
└── uninstall.sh                 reverse of install.sh on a single machine
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

The on-board KEY button (GPIO18) is the no-laptop, no-network recovery path:

| Gesture | Action |
|---|---|
| Tap (<1s) | Flash pairing token on the LCD for 5s. Equivalent to `curl /show-token`. |
| Hold 5s, release | Clear all source cells. Equivalent to `curl /forget?all=1`. |
| Hold **15s** | Factory reset — wipes WiFi creds AND pairing token, reboots into the captive portal. |

While held past 1 second, the LCD shows a progress bar and the next-tier
action so you can release in time. Releasing between 1-5s aborts.

## What the screen shows

- Top-left: Claude burst logo.
- Top-right: `Claude Code` title + `5h XX%   reset HH:MM` + `week $XX` +
  `last HH:MM:SS  resp N` + device IP. If the device is unpaired, the IP
  line also shows `PAIR ME` — run `install.sh` (or call `/pair?token=…`
  directly) to set a token.
- Cells: grid of source cells filling the area below the single divider
  (1 = full, 2 = side-by-side, 3 = 2-on-top + 1, 4 = 2×2). Each cell has a
  small label and a big status word, plus an `Action required` line when
  relevant.

## HTTP API on the ESP32

- `GET /` — plain-text dump of current state, including the device IP.
- `GET /notify?src=<label>&status=<word>&ts=<HH:MM:SS>&alert=<text>&sp=<%>&r=<HH:MM>&wc=<usd>`
  - `src`: source id. Omit → "main". Up to 4 sources; oldest evicts.
  - `status`: shown as big word. Updates timestamp; increments counter when "DONE".
  - `ts`: caller's local time, displayed as "Last update". Caller's clock is
    authoritative — the ESP doesn't run NTP, so timestamps stay correct in
    any timezone with no configuration.
  - `alert`: optional sub-line below status. Pass empty to clear.
  - `sp`, `r`, `wc`: usage stats shown in the top-right block (last value wins across sources).
- `GET /forget?t=<token>&src=<label>` / `GET /forget?t=<token>&all=1` — clear source cells.
- `GET /reset-wifi?t=<token>` — wipe stored WiFi creds and reboot back into
  the `Claude-RLCD-Setup` captive portal. Use when moving the device to a
  new network.
- `GET /pair?token=<4-32 alnum>` — set a new pairing token. Allowed without
  auth when the device is unpaired; once paired, must include `&t=<current>`.
- `GET /unpair?t=<token>` — clear the saved token, device returns to open
  mode. Doesn't touch WiFi creds or source cells.
- `GET /show-token` — flash the saved token on the LCD for ~5s. Unauth on
  purpose; needs physical line-of-sight to read.

All write endpoints (`/notify`, `/forget`, `/reset-wifi`) require
`?t=<token>` once the device is paired. `/` and `/show-token` stay public.

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
