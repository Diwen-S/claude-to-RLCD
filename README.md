# Claude Code → ESP32-S3-RLCD-4.2 status notifier

A 4.2" 400×300 reflective LCD that lights up with `WORKING` / `DONE` /
`Action required` whenever Claude finishes a response, plus your current
5-hour session %, weekly cost, and per-source breakdowns.

Wired to Claude Code via Stop / UserPromptSubmit / Notification / PreToolUse
hooks. Supports multiple parallel sessions with distinct labels.

Four agent installs can drive the same device at once, each claiming its own
cell:

| Driver | Cell tag | Config it reads |
|---|---|---|
| Claude Code CLI (Linux / macOS / WSL) | `(Code)` | `~/.claude/settings.json` |
| Claude Code desktop (Windows) | `(Code W)` | `%USERPROFILE%\.claude\settings.json` |
| Codex CLI (Linux / macOS / WSL) | `(Codex)` | `~/.codex/config.toml` |
| Codex (Windows) | `(Codex W)` | `%USERPROFILE%\.codex\config.toml` |

The trailing `W` marks a session living on the Windows side. Nothing in the
firmware knows about any of this: `/notify` is provider-agnostic and simply
renders whatever label it is handed. See *Claude Code desktop (Windows)* and
*Codex support* below.

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

   > **Pick a 2.4GHz network.** The ESP32-S3 has no 5GHz radio at all, so an
   > SSID like `myrouter 5G` can never be joined; the board reports
   > `Reason: 201 NO_AP_FOUND` and drops straight back into the portal, which
   > looks exactly like the setup screen never responding. Most dual-band
   > routers publish the 2.4GHz network as the same name without the `5G`
   > suffix. The list the portal shows you is scanned by the board itself, so
   > **whatever appears in that list is joinable**; if your network is missing
   > from it, the router's 2.4GHz radio is off or hidden.
   >
   > Your computer may stay on the 5GHz SSID. That is fine as long as both
   > bands bridge to the same LAN, which is the default on a single router.
   > Check with `ping claude-rlcd.local` after setup; if it fails, move the
   > computer to the 2.4GHz SSID too.
3. The board reboots and joins your network. The screen shows the device IP in
   small text in the top-right block (e.g. `ip 192.168.1.42`).
4. **On each computer that runs Claude Code**, clone or copy this folder, then:
   ```bash
   ./install.sh
   ```
   It discovers the ESP at `http://claude-rlcd.local/` (or asks for the IP if
   mDNS isn't available — common on WSL2), prompts you for the pairing token
   the gifter wrote on the sticker (e.g. `20030102`), then asks a yes/no
   question per agent: **"Set up Claude Code?"**, **"Set up Claude Code
   desktop for Windows?"** (WSL only, see step 6), and **"Set up Codex?"**.
   Answer each to wire that agent; you can pick any combination, or none. For
   Claude it copies the hook script to `~/.claude/` and merges hooks into
   `~/.claude/settings.json` without touching your other settings; for Codex
   see *Codex support* below. If the gifter forgot the sticker, run `curl
   http://claude-rlcd.local/show-token` and read the token off the LCD.
5. **Start a new Claude Code (or Codex) session.** The screen flips to
   `WORKING` on your first prompt and `DONE` when the agent finishes.

6. **Using the Claude Code desktop app on Windows?** Run `./install.sh` from a
   WSL shell and answer `y` to **"Set up Claude Code desktop for Windows?"**.
   It finds `%USERPROFILE%\.claude\`, merges the hooks in (backing the file up
   first, leaving your other settings alone), and applies the mandatory
   `MSYS_NO_PATHCONV=1` prefix. Then **quit the desktop app completely and
   relaunch it**. The prompt only appears under WSL, since the desktop hooks
   reach the notifier through `wsl.exe`. See *Claude Code desktop (Windows)*
   below for what it configures and why.

That's it. The rest of this README is reference and troubleshooting.

## Hardware

- **Board:** Waveshare ESP32-S3-RLCD-4.2 (400×300 monochrome reflective LCD, ST7305 controller).
- **GPIOs used:** SCK=11, MOSI=12, DC=5, CS=40, RST=41 (LCD), GPIO18 (KEY button, active-low, internal pull-up).
- **USB:** the single USB-C is both console and upload port. It enumerates as
  the ESP32-S3's **native USB-Serial/JTAG** peripheral, VID:PID `303A:1001`,
  not through a CH343 bridge. On Windows it appears as `USB Serial Device
  (COMn)`; the COM number is assigned by Windows and **changes between
  machines and re-plugs**, so look it up rather than assuming (see
  *Re-flashing the firmware*).

## What's in this folder

```
claude-to-RLCD/
├── README.md                    this file
├── platformio.ini               PlatformIO board + library config
├── src/
│   ├── main.cpp                 firmware
│   └── ST7305_U8g2.cpp/.h       Waveshare ST7305 driver wrapper (vendored)
├── notify-esp32.sh              Claude hook script — installed to ~/.claude/
├── notify-esp32-codex.sh        Codex hook script — installed to ~/.claude/
├── settings-snippet.json        Claude CLI hook config — merged into ~/.claude/settings.json
├── settings-snippet-desktop-windows.json
│                                Claude DESKTOP hook config — merged into
│                                %USERPROFILE%\.claude\settings.json (see below)
├── install.sh                   one-shot installer for each driving machine
├── uninstall.sh                 reverse of install.sh on a single machine
└── tools/
    ├── calendar-push.py         ICS sidecar (calendar view); driven by a 5-min timer
    ├── codex-hooks-status.py    asks Codex which hooks it loaded and whether they
    │                            are trusted — the only way to diagnose a Codex
    │                            hook that is "enabled" but silently never fires
    ├── vendor/                  bundled pure-Python wheels for offline install (icalendar etc.)
    └── .venv/                   self-contained Python env (created by install.sh; gitignored)
```

## Session labels

Each Code source on screen carries a label, with a 4-char session suffix
appended so two terminals open in the same folder still land in separate
cells, e.g. `thesis/9838 (Code)` and `thesis/a1c2 (Code)` for two `claude`
sessions in `~/thesis`.

The suffix is the first 4 chars of the `session_id` field in the JSON payload
Claude pipes to the hook on stdin. It is **not** read from an environment
variable: `$CLAUDE_CODE_SESSION_ID` exists in the `claude` process but is not
exported to hook subprocesses, so anything relying on it silently produces an
empty suffix. Base-name priority:

1. `~/.claude/session-label` (file, edit anytime, no Claude restart needed)
2. `$CLAUDE_SESSION_LABEL` (env var, set before launching `claude`)
3. basename of the hook payload's `cwd` (so each project folder gets its own
   cell automatically; handles Windows paths and spaces)
4. PWD basename, local CLI sessions only
5. `$WSL_DISTRO_NAME` (e.g. `Ubuntu`, `Test`)
6. hostname

(3) outranks (4) because a hook bridged in from Windows sees `$PWD` as
wherever `wsl.exe` landed, typically `/mnt/c`, which would label every desktop
session `c`. For that reason `$PWD` is skipped entirely when the hook was
invoked with the `win` argument.

A session on the Windows side additionally carries a ` W` in its tag, giving
`(Code W)` and `(Codex W)`. The separator is a plain ASCII space: labels are
drawn with u8g2's `drawStr`, which walks raw bytes rather than decoding UTF-8,
so a multi-byte character such as `·` renders as garbage glyphs.

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

## Claude Code desktop (Windows)

The Windows desktop app drives the same device as the CLI. It has no notifier
of its own: its hooks call into WSL and reuse the very same
`~/.claude/notify-esp32.sh`, passing a second argument `win` so the cell is
tagged `(Code W)` and usage stats are suppressed.

**Prerequisites.** WSL must be installed, and the CLI side must already be set
up inside your distro (`./install.sh` from a WSL shell). The desktop app does
not carry its own copy of the script; it borrows the one in your WSL home.
Confirm it is there before going further:

```bash
wsl.exe -e ls -l /home/<you>/.claude/notify-esp32.sh
```

**The easy path** is `./install.sh` from a WSL shell, answering `y` to "Set up
Claude Code desktop for Windows?". Everything below documents what it writes,
for hand-configuration or debugging.

**Config location.** The desktop app reads the same `settings.json` schema as
the CLI, from your Windows profile, not your WSL home:

```
C:\Users\<you>\.claude\settings.json
```

Create it if absent (a fresh install has only `backups\` and `sessions\`). If
the file already exists, merge the `hooks` key in rather than overwriting, the
same way `install.sh` does on the CLI side.

`settings-snippet-desktop-windows.json` in this repo is the same content ready
to copy, with the reasoning inlined as comments; delete its `_comment` key
after merging.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "MSYS_NO_PATHCONV=1 wsl.exe -e /home/<you>/.claude/notify-esp32.sh working win" } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "MSYS_NO_PATHCONV=1 wsl.exe -e /home/<you>/.claude/notify-esp32.sh done win" } ] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "MSYS_NO_PATHCONV=1 wsl.exe -e /home/<you>/.claude/notify-esp32.sh action win" } ] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "MSYS_NO_PATHCONV=1 wsl.exe -e /home/<you>/.claude/notify-esp32.sh clear win" } ] }
    ],
    "SessionEnd": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "MSYS_NO_PATHCONV=1 wsl.exe -e /home/<you>/.claude/notify-esp32.sh closed win" } ] }
    ]
  }
}
```

Replace `<you>` with your WSL username (the path is a Linux path, not a
Windows one). Then **quit the desktop app completely and relaunch it**;
`settings.json` is read once at startup, and a running instance will not pick
up your edits. Check the tray as well as the window.

### Two things that will bite you

**1. `MSYS_NO_PATHCONV=1` is mandatory.** The desktop app runs hook commands
through **Git Bash**, not `cmd.exe`. MSYS2 rewrites any argument that looks
like an absolute POSIX path, so a bare `/home/you/.claude/notify-esp32.sh`
arrives at `wsl.exe` as `C:/Program Files/Git/home/you/.claude/notify-esp32.sh`
and dies with:

```
WSL ERROR: CreateProcessCommon:818:
execvpe(C:/Program Files/Git/home/you/.claude/notify-esp32.sh)
failed: No such file or directory
```

The prefix disables that rewriting. Nothing else about the command changes.

**2. Do not wrap the command in `cmd.exe /c`.** It is a natural instinct on
Windows and it fails in a way that hides itself: under Git Bash the nested
invocation becomes an *interactive* `cmd`, which reads the hook's JSON payload
off stdin and echoes it at its own prompt as though you had typed it, then
exits 0. Claude records the hook as **successful**, no error appears anywhere,
and the device is never contacted. If you ever see a Windows banner and a
`D:\...>` prompt in a hook's captured stdout, this is what happened.

### Behaviour differences from the CLI

- **Usage stats are blank by design.** `ccusage` runs inside WSL and reads
  WSL's `~/.claude/projects`; the desktop app keeps its own history in its
  MSIX container, so any figure reported against a desktop cell would be the
  CLI's numbers. Blank is honest. Desktop pings leave the `5h% / reset / week$`
  block untouched rather than clearing it, so a CLI session's figures keep
  showing.
- **Expect roughly a 2 second pause when you press send.** The hook runs
  synchronously, because a job backgrounded inside `wsl.exe -e` is killed the
  moment the command returns (WSL reaps the whole session; `setsid` and
  `nohup` do not escape it). Most of that 2s is the firmware repainting the
  panel before it answers the HTTP request.
- **Labels come from the hook payload's `cwd`**, so a desktop session in
  `D:\Research\My Project` shows as `My Project/1a2b (Code W)`. Windows paths
  and spaces are both handled.

### If nothing appears on the screen

Do not guess at shells; the app writes down exactly what happened. Open the
session transcript:

```
C:\Users\<you>\.claude\projects\<slugified-cwd>\<session-id>.jsonl
```

Every hook leaves a record there. Look for `"type": "hook_non_blocking_error"`
(carries the raw `stderr`), `"type": "hook_success"` (carries the captured
`stdout`), and `"subtype": "stop_hook_summary"` (lists each command with its
`durationMs`). Two greps that answer most questions:

```bash
grep -o '"stderr":"[^"]*"'  <session-id>.jsonl
grep -o '"command":"[^"]*"' <session-id>.jsonl
```

Common outcomes:

| What you see | Cause |
|---|---|
| `execvpe(C:/Program Files/Git/...)` | missing `MSYS_NO_PATHCONV=1` |
| stdout contains a `Microsoft Windows [Version ...]` banner | command wrapped in `cmd.exe /c` |
| No hook records at all | app not restarted, or `settings.json` is in the wrong place / malformed JSON |
| Hook succeeds, still no cell | device unreachable: check `ping claude-rlcd.local` and that `~/.claude/esp32-ip` and `esp32-token` exist **inside WSL** |

## Codex support

Codex (OpenAI's CLI) drives the same device through its own lifecycle hooks.
Nothing changes on the firmware: `/notify` is provider-agnostic, so a Codex
session simply claims its own cell, labelled `(Codex)`, next to any `(Code)`
cells. The event mapping mirrors the Claude one:

| Codex hook | Device state |
|---|---|
| `UserPromptSubmit` | `WORKING` |
| `Stop` | `DONE` |
| `PermissionRequest` | `Action required` flash |
| `PreToolUse` | clears the alert |

`install.sh` wires this when you answer `y` to "Set up Codex?". It:

1. Copies `notify-esp32-codex.sh` to `~/.claude/`.
2. Locates the Codex home (`$CODEX_HOME`, else `~/.codex`, else on WSL the
   Windows-side `/mnt/c/Users/*/.codex`).
3. Writes the four hook blocks into that `config.toml`, inside a
   `# >>> claude-rlcd codex hooks >>>` ... `<<<` marker block so re-running the
   installer replaces rather than duplicates them. The existing `config.toml`
   is backed up alongside first.

Codex on Windows and Codex inside WSL are **two separate installs with two
separate `config.toml` files**, and you can run both. They differ only in how
the hook command reaches the script:

```toml
# ~/.codex/config.toml  — Codex running natively in WSL/Linux/macOS. Cells: (Codex)
command = '/home/<you>/.claude/notify-esp32-codex.sh working'

# %USERPROFILE%\.codex\config.toml  — Codex on Windows. Cells: (Codex W)
command = 'wsl.exe -e /home/<you>/.claude/notify-esp32-codex.sh working win'
```

The trailing `win` is what earns the `(Codex W)` tag. As with the desktop app,
a Windows-bridged hook runs **synchronously**: a job backgrounded inside
`wsl.exe -e` is killed when the command returns, because WSL reaps the entire
session (`setsid` and `nohup` do not escape it either).

> **If the Windows Codex hooks fire but no cell appears**, check whether Codex
> spawns hooks through Git Bash. If it does, the bare `/home/...` argument is
> being rewritten to `C:/Program Files/Git/home/...` and you need the
> `MSYS_NO_PATHCONV=1` prefix described under *Claude Code desktop (Windows)*.
> If Codex uses `cmd.exe`, the bare path is correct and the prefix would break
> it. The two cases are distinguished by the error text, so read the log
> before changing anything.

**Codex session labels** work like the Claude ones but read from their own
sources, in priority order:

1. `~/.claude/session-label-codex` (file, edit anytime)
2. `$CODEX_SESSION_LABEL` (env var, set before launching `codex`)
3. the `cwd` field from the hook's JSON payload (so each project folder gets
   its own cell; `$PWD` is not used, since a WSL-bridged hook would see the
   WSL landing dir rather than the Codex project)
4. hostname

The 4-char suffix comes from the hook payload's `session_id`. Codex cells
carry no usage stats: `ccusage` reports Claude usage, which would be
misleading under a `(Codex)` label, so `sp` / `r` / `wc` are left blank.

**Caveats:**

- **Trust gating — this is the one that will catch you.** Codex will not run a
  hook until you trust it, and an untrusted hook reports `enabled: true` while
  silently never firing. There is no error anywhere; it just does nothing.
  - **Codex CLI:** run `codex` interactively once. It shows "Hooks need
    review" at startup — choose *Trust all and continue*. (`codex exec` never
    shows that prompt, so it can never grant trust.)
  - **Codex desktop: there is no hooks UI at all.** The GUI never calls any
    `hooks/*` method, so the approval dialog that fixes this does not exist.
    Trust has to be written into `config.toml` by hand — see below.
  - The hash covers the **whole hook entry**, not just the command string —
    adding or changing a field like `timeout` re-arms the gate too (it then
    reports `trust=modified` rather than `untrusted`). Re-running `install.sh`
    without changing a hook keeps that hook's existing trust; only the entries
    you actually changed need re-approving.
  - `codex doctor` does not mention hooks and will not diagnose this. Use
    `tools/codex-hooks-status.py`, which asks Codex itself and prints every
    hook's `enabled` state and `trustStatus` in one call.
- **Granting trust by hand** (needed on Codex desktop). `trusted_hash` is not a
  plain sha256 of the command, so it cannot be computed — you have to read it
  from Codex, and from the *same binary* that will run the hooks, since the
  hashes differ per install. Point the status tool at the desktop build with
  `CODEX_BIN`:

  ```bash
  CODEX_BIN='/mnt/c/Users/<you>/AppData/Local/OpenAI/Codex/bin/<hash>/codex.exe' \
    python3 tools/codex-hooks-status.py --json
  ```

  Take each hook's `key` and `currentHash` and add one sibling table per hook
  (note: a sibling table, not a field inside the hook entry — nesting it is
  silently ignored):

  ```toml
  [hooks.state."/home/you/.codex/config.toml:pre_tool_use:0:0"]
  trusted_hash = "sha256:..."
  ```

  The key is `<sourcePath>:<snake_case_event>:<group_idx>:<hook_idx>`. Use a
  single-quoted TOML literal key for Windows paths so the backslashes survive.
  Re-run the status tool afterwards and confirm `trustStatus` flipped to
  `trusted`.
- **One Codex home per run.** `install.sh` wires the first Codex install it
  finds (`$CODEX_HOME`, then `~/.codex`, then a Windows `.codex` under
  `/mnt/c/Users/*`). If you run Codex both natively *and* on Windows, only the
  first is configured — set up the second by hand, or re-run with `CODEX_HOME`
  pointed at it. `uninstall.sh` has the same one-home limitation.
- **Auto-forget works.** Codex gained a `SessionEnd` event in 0.147.0 (0.142
  alpha did not have it), and `install.sh` now wires it to `notify-esp32-codex.sh
  closed`, so a `(Codex)` cell removes itself when the session ends instead of
  lingering until something evicts it. Requires 0.147.0 or newer; on an older
  Codex the hook is simply never called and the cell lingers as before, which
  you can still clear by hand with
  `curl "http://claude-rlcd.local/forget?t=$T&src=<label>%20(Codex)"`.
- **Hooks get one second, and Codex enforces it.** Hook execution is capped at
  `timeout` seconds — default 1, and it really does kill the process partway
  (a deliberate 3s sleep was cut off mid-run during testing). Two consequences:
  - The notifier only fits because it talks to a **cached IP** (~0.2s round
    trip). If `~/.claude/esp32-ip` ever falls back to holding the mDNS name,
    resolution alone costs 1.2-1.6s and every Codex hook is killed first.
  - The `SessionEnd` hook is the exception and gets `timeout = 3`, the largest
    value Codex accepts (it silently clamps anything higher). It needs the
    headroom because it waits ~1s before calling `/forget`: Codex fires `Stop`
    and `SessionEnd` in the same second and `Stop` self-backgrounds, so without
    the pause the backgrounded `done` lands *after* the forget and immediately
    recreates the cell that was just removed.
- **Alpha surface.** Codex hooks are recent and the schema may shift. Verified
  on `codex-cli` 0.147.0 (WSL) and 0.148.0-alpha.9 (the Windows desktop
  bundle) — behaviour does not always transfer between the two, so check the
  version before porting a fix.
- **Teardown.** `uninstall.sh` removes the Codex pieces too: it deletes
  `~/.claude/notify-esp32-codex.sh` and strips the marked block from the Codex
  `config.toml` (backing it up first), alongside the Claude cleanup.

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
ESP-pairing flow. Answer `y` when it asks "Connect a calendar now?", paste an
ICS URL (the prompt lists where to find it per provider), and keep answering
`y` to "Add another calendar?" until you've added all of them — events from
every listed calendar get merged into one view. Then answer `y` to "Install a
5-minute auto-refresh timer?". The installer:

1. Bootstraps the venv at `tools/.venv` and installs the three Python deps,
   **offline if possible** — `install.sh` first tries the bundled wheels in
   `tools/vendor/`, only falling back to PyPI if the vendor dir is missing
   or stale. So the calendar works even on machines without internet at
   install time (corporate proxies, university firewalls, gift unboxing).
   On Debian/Ubuntu you may first need `sudo apt install python3-venv`.
2. Writes the URLs to `~/.config/claude-rlcd/calendar.conf` (mode `0600`).
3. Runs a live `--push` to confirm the LCD picks it up.
4. Installs the right kind of refresh timer for your OS:
   - **systemd-user** unit on regular Linux,
   - **launchd** agent on macOS,
   - **cron** entry otherwise (including WSL2 without systemd).
5. Prints the command for checking the timer's status.

To wire up another calendar later, either re-run `./install.sh` (it keeps the
existing URLs and asks "Add another calendar?") or just add a line to
`~/.config/claude-rlcd/calendar.conf` by hand — the next timer tick picks it
up either way. To swap providers entirely, edit the conf and remove the old
line.

### Manual setup (skipping `install.sh`)

```bash
# 1. Bootstrap the venv (once). Offline install from the bundled wheels:
python3 -m venv tools/.venv
tools/.venv/bin/pip install --no-index --find-links tools/vendor/ \
    icalendar recurring_ical_events python-dateutil certifi
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
./uninstall.sh                    # keep tools/.venv and calendar.conf
./uninstall.sh --purge-calendar   # also wipe tools/.venv and ~/.config/claude-rlcd/
```
Removes `~/.claude/{notify-esp32.sh,notify-esp32-codex.sh,esp32-ip,esp32-token}`,
strips the notify hooks from `~/.claude/settings.json` and the marked Codex
block from the Codex `config.toml`, and tears down the calendar auto-refresh
timer (systemd-user / launchd / cron) if `install.sh` set one up. Every other
setting in `settings.json` is preserved.

Under WSL it also strips the desktop app's hooks from
`%USERPROFILE%\.claude\settings.json`, backing that file up alongside first.
Restart the desktop app afterwards for the change to take effect.

**Then deleting the cloned repo folder:** if you're on WSL/Linux/macOS, plain
`rm -rf` works. If you're deleting from **Windows Explorer**, run
`./uninstall.sh --purge-calendar` first — without it, `tools/.venv/` survives
and its nested wheel paths exceed Windows' 260-char `MAX_PATH` limit, leaving
Explorer to throw error `0x80070780` ("file cannot be accessed by the
system"). After the purge, the folder is just text + small wheels and
Explorer can delete it normally.

Caveat: this is LAN-level access control, not encryption. Traffic is plain
HTTP, so anyone with the WiFi password who captures the four-way handshake
can read it. Adequate for a home gift; not a security boundary against a
determined attacker on the same network.

---

## Troubleshooting

### Calendar fetch fails on macOS with CERTIFICATE_VERIFY_FAILED

`certificate verify failed: unable to get local issuer certificate` from
`calendar-push.py` means the Python you're running doesn't trust any root CAs.
python.org and pyenv builds of CPython on macOS ship their own OpenSSL and do
**not** read the system Keychain, so their trust store starts empty. Current
versions of this repo handle it automatically (`certifi` is bundled in
`tools/vendor/` and loaded on top of the system store); if you're seeing the
error on an older clone, `git pull` and re-run `./install.sh`, or patch the
existing venv directly:

```bash
tools/.venv/bin/pip install certifi
```

Linux/WSL (system `/etc/ssl/certs`) and Windows (system cert store) are
unaffected either way.

### Re-flashing the firmware

You only need this if you're building or modifying the firmware yourself.
Recipients of a pre-flashed board do not.

#### Updating over WiFi

Firmware 1.0.0 introduces an A/B OTA layout and a token-protected browser
uploader. The **first** installation of this version must still use USB and
PlatformIO, because the flash also needs the new partition table. After that,
future firmware updates can be installed without a cable:

1. Build with PlatformIO. The uploadable image is
   `.pio/build/esp32s3-eink/firmware.bin`.
2. Open `http://claude-rlcd.local/update?t=PAIRING_TOKEN` on the same LAN.
3. Select `firmware.bin` and install it. The device writes the inactive OTA
   slot, validates the complete ESP image, and only then reboots into it.

The update endpoint is deliberately unavailable while the device is in open
(unpaired) mode. A rejected or interrupted upload leaves the running slot
untouched. WiFi credentials and the pairing token live in NVS at `0x9000`,
outside both application slots, so normal OTA updates preserve them.

The current endpoint is the recovery-safe OTA foundation, not unattended
Internet updating. Do not publish an automatic release poller until release
artifacts have cryptographic signature verification; HTTPS or a checksum
listed beside the binary is not, by itself, firmware authenticity.

#### Ask-first automatic updates

Firmware 1.1.0 checks the latest GitHub Release once daily after the device is
paired. A newer release is offered on the LCD and is never installed silently:

- tap **KEY** to install;
- hold **KEY** for 1 second to dismiss it until the next check.

The release carries `latest.json` and `firmware.bin`. The manifest contains the
version, download URL, SHA-256 digest, and an ECDSA P-256 signature. The board
verifies the manifest with the embedded public key, downloads into the inactive
OTA slot, verifies the complete image digest, and only then selects it for the
next boot. A failed or interrupted check leaves the running firmware untouched.

Create a signed manifest locally with:

```bash
tools/make-release-manifest.sh 1.1.0 .pio/build/esp32s3-eink/firmware.bin \
  https://github.com/Diwen-S/claude-to-RLCD/releases/download/v1.1.0/firmware.bin \
  > latest.json
```

The signing key defaults to
`~/.config/claude-rlcd/firmware-signing-key.pem`; keep it offline and never
commit it. The public key in `src/update_public_key.h` is safe to publish.

**In Windows VS Code with the PlatformIO IDE extension**: open this folder and
click PlatformIO **Upload** (→).

**From a WSL shell**. Find the port first; it is not stable across machines or
re-plugs. The board is the one with hardware ID `VID:PID=303A:1001`:

```bash
PIO=/mnt/c/Users/<you>/.platformio/penv/Scripts
"$PIO/pio.exe" device list                     # note the COMn for 303A:1001
cd /mnt/d/dev/claude-to-RLCD
"$PIO/pio.exe" run --target upload --upload-port COM3
```

**Upload fails / no COM port**: hold BOOT, tap PWR, release BOOT, retry.

**What a re-flash does and does not erase.** The NVS partition sits at the
same `0x9000` offset in both the Arduino and factory layouts, so **stored WiFi
credentials survive** a re-flash and the board will rejoin its old network.
The pairing token does **not** survive, because it lives in the firmware's own
Preferences namespace; the board comes back up in open mode showing `PAIR ME`,
and you re-pair with:

```bash
curl "http://claude-rlcd.local/pair?token=$(cat ~/.claude/esp32-token)"
```

**Backing up first.** If the board is carrying firmware you might want back
(for example the Waveshare `03_Fac` factory demo it ships with), dump the
whole chip before overwriting. It takes about 3 minutes:

```bash
ESPTOOL=/mnt/c/Users/<you>/.platformio/packages/tool-esptoolpy/esptool.py
python "$ESPTOOL" --port COM3 --baud 921600 read_flash 0 0x1000000 factory-backup.bin
# restore with:
python "$ESPTOOL" --port COM3 --baud 921600 write_flash 0 factory-backup.bin
```

### Reading the boot log from WSL (no extra tools)

Arduino's `Serial` is silent on this board. `platformio.ini` builds with
`-DARDUINO_USB_CDC_ON_BOOT=0`, which points `Serial` at UART0 (GPIO43/44),
and that UART is not wired to the USB-C socket. Diagnostics therefore go out
via `esp_rom_printf`, which writes to the ROM console, i.e. the native
USB-Serial/JTAG interface you are already plugged into.

Save this once as `listen.ps1` somewhere on the Windows side:

```powershell
param([string]$Port = 'COM3', [int]$Seconds = 15, [switch]$Reset)
$p = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$p.ReadTimeout = 200; $p.DtrEnable = $false; $p.RtsEnable = $false
$p.Open()
if ($Reset) { $p.RtsEnable = $true; Start-Sleep -Milliseconds 100; $p.RtsEnable = $false }
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  Start-Sleep -Milliseconds 100
  if ($p.BytesToRead -gt 0) { Write-Host -NoNewline $p.ReadExisting() }
}
$p.Close()
```

Then, from WSL:

```bash
# listen only (does not disturb a running board)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\path\listen.ps1' -Port COM3

# reset the board and capture the boot log from the first line
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\path\listen.ps1' -Port COM3 -Reset
```

`-Reset` pulses RTS, which drives EN low and reboots the board; with DTR held
false it boots the application normally rather than into the bootloader.

A healthy boot ends with:

```
[boot] Claude RLCD notifier
[boot] LCD ok
[boot] BOOT painted
[wifi] ip=192.168.1.42
[mdns] http://claude-rlcd.local/
[boot] READY
```

If instead you see `STA Disconnected: SSID: <name>, Reason: 201 - NO_AP_FOUND`
followed by `[wifi] portal open`, the board cannot see that network. The usual
cause is a 5GHz SSID; see the warning in *Quick start*.

### Manual install (skipping `install.sh`)

```bash
cp notify-esp32.sh ~/.claude/notify-esp32.sh
chmod +x ~/.claude/notify-esp32.sh
echo 192.168.1.42      > ~/.claude/esp32-ip      # the board's IP, from its screen.
                                                 # Prefer a literal IP over
                                                 # claude-rlcd.local: hooks run on
                                                 # every prompt and mDNS costs
                                                 # ~1.4s a call. The script falls
                                                 # back to the name if this dies.
echo 20030102          > ~/.claude/esp32-token   # pairing token from the sticker
chmod 600                ~/.claude/esp32-token
# then hand-merge settings-snippet.json's "hooks" block into ~/.claude/settings.json
```

Skip the `esp32-token` line only if the device is still in open mode
(`paired = no` in the `/` dump). Once paired, every `/notify` without the
token returns 403 and nothing reaches the screen.

Dependencies: `node` (for `npx`), `python3`, `curl`. `notify-esp32.sh` invokes
`npx ccusage` to fetch the current 5-hour window and weekly spend.

For **Codex**, copy the script and add the hooks to the Codex `config.toml`
(`~/.codex/`, or the Windows-side `.codex` if Codex runs on Windows):

```bash
cp notify-esp32-codex.sh ~/.claude/notify-esp32-codex.sh
chmod +x ~/.claude/notify-esp32-codex.sh
```

```toml
# in config.toml. Two forms, one per install:
#   native Linux/macOS/WSL Codex -> '/home/you/.claude/notify-esp32-codex.sh working'
#   Codex on Windows             -> 'wsl.exe -e /home/you/.claude/... working win'
# The trailing "win" tags the cell (Codex W) and makes the script run
# synchronously, which a wsl.exe-bridged hook requires.
[[hooks.UserPromptSubmit]]
matcher = ""
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = 'wsl.exe -e /home/you/.claude/notify-esp32-codex.sh working win'

[[hooks.Stop]]
matcher = ""
[[hooks.Stop.hooks]]
type = "command"
command = 'wsl.exe -e /home/you/.claude/notify-esp32-codex.sh done win'

[[hooks.PermissionRequest]]
matcher = ""
[[hooks.PermissionRequest.hooks]]
type = "command"
command = 'wsl.exe -e /home/you/.claude/notify-esp32-codex.sh action win'

[[hooks.PreToolUse]]
matcher = ""
[[hooks.PreToolUse.hooks]]
type = "command"
command = 'wsl.exe -e /home/you/.claude/notify-esp32-codex.sh clear win'
```

`notify-esp32-codex.sh` needs only `python3` and `curl` (no `ccusage`). It
reads the same `~/.claude/esp32-ip` and `~/.claude/esp32-token` files.

### Other gotchas

- **Screen blank after upload** — wrong panel driver or pin map. This board
  needs `ST7305_U8g2` (vendored) with the pins above; GxEPD2 won't drive it.
- **`Serial.println` silent** — expected. `platformio.ini` sets
  `-DARDUINO_USB_CDC_ON_BOOT=0`, so `Serial` is UART0 on GPIO43/44, which is
  not wired to the USB-C socket. Use `esp_rom_printf`, which reaches the ROM
  console on the native USB-Serial/JTAG interface.
- **Device IP changed on its own** — normal DHCP lease churn, and more likely
  if your WiFi has several APs broadcasting one SSID. `~/.claude/esp32-ip`
  should hold a **literal IP**, not `claude-rlcd.local`: hooks fire on every
  prompt and tool call, and mDNS resolution from WSL2 costs 1.2-1.6s each time
  against a device that answers in about 0.17s. Storing the name is also why
  hooks used to drop updates silently and strand a cell on screen — a failed
  lookup returns curl rc=6 and the hook exits without reaching the device.
  You do not have to maintain this by hand: if the cached IP stops answering,
  the notifier retries once over mDNS and rewrites the file with the board's
  new address, so a lease change costs one slow hook and then self-heals.
- **Hooks report success but the screen never updates** — the hook ran
  something that exited 0 without reaching the device. On Windows this is
  almost always the `cmd.exe /c` wrapping trap; see *Claude Code desktop
  (Windows)*. Confirm the device is reachable independently with
  `curl http://claude-rlcd.local/`.
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
  line-of-sight), or tap the KEY button, which does the same with no network
  at all. If you cannot see the screen either, hold KEY for 15s to factory
  reset (clears the token and the WiFi credentials, then reboots).

  Note that **re-flashing the firmware does not clear the token**. NVS lives
  at `0x9000` outside the application image and survives an upload, which is
  also why the board rejoins its old WiFi after a re-flash. To wipe it from a
  host, erase the chip explicitly:

  ```bash
  python "$ESPTOOL" --port COM3 erase_flash   # destroys WiFi creds + token + app
  ```
