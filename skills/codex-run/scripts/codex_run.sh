#!/usr/bin/env bash
# Codex companion (openai-codex Claude Code plugin) を 1 コマンドで「起動 → 完了待ち → 本文回収」する。
# Launch a Codex task through the openai-codex plugin's companion runtime, wait for it, and
# collect the final report — in one foreground command so the calling agent needs no polling loop.
#
# usage: codex_run.sh -b BRIEF.md [-m terra|sol|luna|spark|<full-model-id>] [-w] [-c CWD] [-o OUT.md]
#                     [-e low|medium|high] [-r] [-t SECONDS] [--no-usage-check]
#   -b  brief (prompt) file. Passed via --prompt-file, so it may be long.
#   -m  model alias (default: terra). Aliases map to gpt-5.6-* ids; unknown values are passed through.
#   -w  write-capable run (--write). Omit for read-only (review / report-into-/tmp jobs).
#   -c  working directory for the sandbox (e.g. a git worktree). Default: current dir.
#       Job state is keyed by this directory; the script keeps using it for status/log lookup.
#   -o  file to save the final report to (default: stdout only).
#   -e  reasoning effort (default: medium).
#   -r  resume the last thread in CWD (--resume-last) instead of --fresh.
#   -t  overall timeout in seconds (default: 3600).
#   --no-usage-check  skip the rate-limit preflight.
# exit codes: 0 completed / 2 usage limit hit or preflight refused / 3 timeout / 1 other failure
# env: CODEX_COMPANION (path to codex-companion.mjs; auto-detected under ~/.claude/plugins/cache/openai-codex)
set -u
here=$(cd "$(dirname "$0")" && pwd)
brief=""; model="terra"; write=""; cwd="$PWD"; out=""; effort="medium"; resume="--fresh"; timeout_s=3600; usage_check=1
while [ $# -gt 0 ]; do
  case "$1" in
    -b) brief=$2; shift 2;; -m) model=$2; shift 2;; -w) write="--write"; shift;;
    -c) cwd=$2; shift 2;; -o) out=$2; shift 2;; -e) effort=$2; shift 2;;
    -r) resume="--resume-last"; shift;; -t) timeout_s=$2; shift 2;;
    --no-usage-check) usage_check=0; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -f "$brief" ] || { echo "brief file not found: $brief" >&2; exit 1; }
brief=$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")
case "$model" in
  terra) model=gpt-5.6-terra;; sol) model=gpt-5.6-sol;; luna) model=gpt-5.6-luna;; spark) model=gpt-5.3-codex-spark;;
esac
companion=${CODEX_COMPANION:-$(ls -1 "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)}
[ -f "$companion" ] || { echo "codex-companion.mjs not found (install the openai-codex plugin or set CODEX_COMPANION)" >&2; exit 1; }

if [ "$usage_check" = 1 ]; then
  u=$("$here/codex_usage.sh" 2>/dev/null)
  echo "usage: ${u:-unknown}"
  if printf '%s' "$u" | grep -qE '5h: (100|9[5-9])% used'; then
    echo "refusing to launch: 5h window nearly exhausted. Wait for the reset above." >&2; exit 2
  fi
fi

launch=$(node "$companion" task --background $resume $write --json --cwd "$cwd" --model "$model" --effort "$effort" --prompt-file "$brief" 2>&1)
job=$(printf '%s' "$launch" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["jobId"])
except Exception: print("")')
[ -n "$job" ] || { echo "launch failed: $launch" >&2; exit 1; }
echo "job: $job (model $model, $( [ -n "$write" ] && echo write || echo read-only ), cwd $cwd)"

deadline=$(( $(date +%s) + timeout_s )); status=queued
while :; do
  left=$(( deadline - $(date +%s) )); [ $left -le 0 ] && { echo "timeout after ${timeout_s}s; job $job still $status" >&2; exit 3; }
  w=$(( left < 190 ? left : 190 ))
  st=$(node "$companion" status "$job" --cwd "$cwd" --wait --timeout-ms $((w*1000)) --json 2>/dev/null)
  status=$(printf '%s' "$st" | python3 -c 'import sys,json
try: j=json.load(sys.stdin)["job"]; print(j.get("status",""), j.get("logFile",""))
except Exception: print("")')
  log=${status#* }; status=${status%% *}
  case "$status" in completed|failed|cancelled) break;; esac
done

report=""
if [ -n "$log" ] && [ -f "$log" ]; then
  n=$(grep -n "Final output" "$log" | tail -1 | cut -d: -f1)
  [ -n "$n" ] && report=$(tail -n +$((n+1)) "$log")
  spawns=$(grep -c "spawn_agent" "$log"); err=$(grep "Codex error" "$log" | tail -1 | cut -c1-200)
else
  spawns="?"; err=""
fi
hdr="status: $status | subagent spawns in log: $spawns${err:+ | $err}"
echo "$hdr"
[ -n "$out" ] && { mkdir -p "$(dirname "$out")"; printf '%s\n' "$report" > "$out"; echo "report saved: $out ($(wc -l < "$out") lines)"; }
[ -z "$out" ] && printf '%s\n' "$report"
case "$status" in
  completed) exit 0;;
  *) printf '%s' "$err" | grep -q "usage limit" && exit 2; exit 1;;
esac
