#!/usr/bin/env python3
"""Ask Codex what it thinks our hooks are.

Codex parses hooks from config.toml but gates *execution* behind a per-hook
trust record hashed from the command, and it reports none of that on the
console: a hook that is parsed, enabled and untrusted simply never fires. The
logs are no help either (they show the hooks/list request and no execution
rows), and `codex doctor` does not mention hooks at all.

This drives `codex app-server` over stdio JSON-RPC and calls hooks/list, which
answers in one shot. Untrusted hooks are fixed by running `codex` interactively
once and answering "Trust all and continue" at the "Hooks need review" prompt;
editing a hook command changes its hash and re-arms that prompt.

A hook's `trusted_hash` covers its whole entry, not just the command string,
so adding or changing a field such as `timeout` also re-arms the prompt (it
then reports trust=modified rather than untrusted). Hashes are specific to the
binary and CODEX_HOME that produced them, so to fix an install that has no
interactive gate — the Codex desktop app has no hooks UI at all — you must read
the hash from *that* install:

    CODEX_BIN=/mnt/c/Users/you/AppData/Local/OpenAI/Codex/bin/<hash>/codex.exe \
      python3 tools/codex-hooks-status.py --json

then write one `[hooks.state."<key>"] trusted_hash = "<currentHash>"` per hook.

Usage:  python3 tools/codex-hooks-status.py [--json]
Env:    CODEX_BIN   path to the codex binary to interrogate (default: `codex`)
        CODEX_HOME  passed through to that binary, as Codex normally reads it
"""

import json
import os
import subprocess
import sys
import threading
import time

TIMEOUT_S = 15
CODEX_BIN = os.environ.get("CODEX_BIN") or "codex"


def hooks_list():
    p = subprocess.Popen(
        [CODEX_BIN, "app-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )

    def send(obj):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

    result = {}

    def reader():
        for line in p.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == 2:
                result["data"] = msg.get("result", {})
                break

    threading.Thread(target=reader, daemon=True).start()
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"clientInfo": {"name": "rlcd-hook-probe",
                                    "title": "rlcd-hook-probe",
                                    "version": "1.0.0"}}})
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send({"jsonrpc": "2.0", "id": 2, "method": "hooks/list", "params": {}})

    deadline = time.time() + TIMEOUT_S
    while "data" not in result and time.time() < deadline:
        time.sleep(0.1)
    p.terminate()
    if "data" not in result:
        sys.exit(f"no hooks/list response within {TIMEOUT_S}s")
    return result["data"]


def main():
    data = hooks_list()
    if "--json" in sys.argv:
        print(json.dumps(data, indent=2))
        return

    untrusted = 0
    for group in data.get("data", []):
        print(f"cwd: {group.get('cwd')}")
        hooks = group.get("hooks", [])
        if not hooks:
            print("  (no hooks parsed — check the config.toml Codex actually reads)")
        for h in hooks:
            trust = h.get("trustStatus")
            untrusted += trust != "trusted"
            print(f"  {h.get('eventName'):<18} enabled={str(h.get('enabled')):<5} "
                  f"trust={trust:<9} {h.get('command')}")
            print(f"    from {h.get('sourcePath')}")
        for key in ("warnings", "errors"):
            if group.get(key):
                print(f"  {key}: {group[key]}")

    if untrusted:
        print(f"\n{untrusted} hook(s) untrusted — they will NOT fire.")
        print("Fix: run `codex` interactively and choose 'Trust all and continue'.")
        print("Diagnose only: `codex exec --dangerously-bypass-hook-trust \"...\"`.")


if __name__ == "__main__":
    main()
