#!/usr/bin/env bash
# Codex の残使用量 (5 時間枠 / 7 日枠) を `codex app-server` の JSON-RPC で読む。
# Read Codex rate limits (5h / 7d windows) via `codex app-server` JSON-RPC.
# usage: codex_usage.sh [--json]
set -u
raw=$( { printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-run-skill","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
    sleep "${CODEX_USAGE_WAIT_SEC:-6}"
  } | codex app-server 2>/dev/null | grep '"id":2' | head -1 )
[ -z "$raw" ] && { echo "no response from codex app-server (is codex CLI logged in?)"; exit 1; }
if [ "${1:-}" = "--json" ]; then
  python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin).get("result",{}).get("rateLimits"),indent=1))' <<<"$raw"; exit
fi
python3 - "$raw" <<'PY'
import sys, json, datetime as dt
r = json.loads(sys.argv[1]).get("result", {}).get("rateLimits") or {}
def fmt(k, label):
    w = r.get(k) or {}
    if not w: return f"{label}: n/a"
    rs = w.get("resetsAt")
    t = dt.datetime.fromtimestamp(rs).astimezone().strftime("%m/%d %H:%M %Z") if rs else "?"
    return f"{label}: {w.get('usedPercent')}% used (reset {t})"
print(fmt("primary", "5h"), "|", fmt("secondary", "7d"), "|", "plan:", r.get("planType"))
PY
