#!/usr/bin/env bash
# Wait ONCE (default 190 s) for a Codex job started with `codex_run.sh -d`, and collect the
# report if it has finished. Call it again while it exits 4. It never starts a background
# process, so the calling agent needs no polling loop of its own.
#
# usage: codex_wait.sh JOB_ID [-c CWD] [-o OUT.md] [-t SECONDS]
#   -c  working directory the job was launched with (job state is keyed by it). Default: current dir.
#   -o  file to save the final report to (default: stdout).
#   -t  how long this single wait may block (default 190, max 540; stay under the 10-minute
#       limit of Claude Code's Bash tool).
# exit codes: 0 completed / 2 usage limit hit / 1 other failure or bad usage / 4 still running (call again)
# env: CODEX_COMPANION (path to codex-companion.mjs; auto-detected under ~/.claude/plugins/cache/openai-codex)
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/_common.sh"
job=""; cwd="$PWD"; out=""; t=190
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cwd=$2; shift 2;; -o) out=$2; shift 2;; -t) t=$2; shift 2;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 1;;
    *) [ -z "$job" ] || { echo "unexpected extra arg: $1" >&2; exit 1; }; job=$1; shift;;
  esac
done
[ -n "$job" ] || { echo "usage: codex_wait.sh JOB_ID [-c CWD] [-o OUT.md] [-t SECONDS]" >&2; exit 1; }
case "$t" in ''|*[!0-9]*) echo "-t must be a non-negative integer" >&2; exit 1;; esac
[ "$t" -gt 540 ] && t=540
companion=$(codex_find_companion)
[ -f "$companion" ] || { echo "codex-companion.mjs not found (install the openai-codex plugin or set CODEX_COMPANION)" >&2; exit 1; }

st=$(codex_companion "$companion" status "$job" --cwd "$cwd" --wait --timeout-ms $((t*1000)) --json 2>/dev/null)
parsed=$(printf '%s' "$st" | codex_parse_status)
log=${parsed#* }; status=${parsed%% *}
case "$status" in
  completed|failed|cancelled) codex_collect "$status" "$log" "$out"; exit $?;;
  *) echo "status: ${status:-unknown} (still running; call codex_wait.sh again)"; exit 4;;
esac
