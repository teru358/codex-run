#!/usr/bin/env bash
# Codex companion (openai-codex Claude Code plugin) を 1 コマンドで「起動 → 完了待ち → 本文回収」する。
# Launch a Codex task through the openai-codex plugin's companion runtime, wait for it, and
# collect the final report — in one foreground command so the calling agent needs no polling loop.
#
# usage: codex_run.sh -b BRIEF.md [-m terra|sol|luna|spark|<full-model-id>] [-w] [-c CWD] [-o OUT.md]
#                     [-e low|medium|high] [-r] [-t SECONDS] [-d] [--no-guard] [--no-usage-check]
#   -b  brief (prompt) file. Passed via --prompt-file, so it may be long.
#   -m  model alias (default: terra). Aliases map to gpt-5.6-* ids; unknown values are passed through.
#   -w  write-capable run (--write). Omit for read-only (review / report-into-/tmp jobs).
#   -c  working directory for the sandbox (e.g. a git worktree). Default: current dir.
#       Job state is keyed by this directory; the script keeps using it for status/log lookup.
#   -o  file to save the final report to (default: stdout only).
#   -e  reasoning effort (default: medium).
#   -r  resume the last thread in CWD (--resume-last) instead of --fresh.
#   -t  overall timeout in seconds (default: 3600).
#   -d  detach: preflight + launch, print the `usage:` and `job:` lines (plus `out: <path>` if -o
#       was given), and exit 0 at once without waiting. Collect later with
#       `codex_wait.sh <jobId> -c CWD [-o OUT.md]` (one bounded foreground wait per call), so the
#       caller never needs a background process or a polling loop of its own.
#   --no-guard  do not prepend the runner-constraints block (single thread, no subagents, no
#       background processes, no confirmation step). By default it is put in front of the brief
#       in a temp copy; the original brief file is never modified.
#   --no-usage-check  skip the rate-limit preflight.
# exit codes: 0 completed / 2 usage limit hit or preflight refused / 3 timeout / 1 other failure
# env: CODEX_COMPANION (path to codex-companion.mjs; auto-detected under ~/.claude/plugins/cache/openai-codex)
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/_common.sh"
brief=""; model="terra"; write=""; cwd="$PWD"; out=""; effort="medium"; resume="--fresh"; timeout_s=3600; usage_check=1; detach=0; guard=1
while [ $# -gt 0 ]; do
  case "$1" in
    -b) brief=$2; shift 2;; -m) model=$2; shift 2;; -w) write="--write"; shift;;
    -c) cwd=$2; shift 2;; -o) out=$2; shift 2;; -e) effort=$2; shift 2;;
    -r) resume="--resume-last"; shift;; -t) timeout_s=$2; shift 2;;
    -d) detach=1; shift;;
    --no-guard) guard=0; shift;;
    --no-usage-check) usage_check=0; shift;;
    -h|--help) sed -n '2,29p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -f "$brief" ] || { echo "brief file not found: $brief" >&2; exit 1; }
brief=$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")
case "$model" in
  terra) model=gpt-5.6-terra;; sol) model=gpt-5.6-sol;; luna) model=gpt-5.6-luna;; spark) model=gpt-5.3-codex-spark;;
esac
companion=$(codex_find_companion)
[ -f "$companion" ] || { echo "codex-companion.mjs not found (install the openai-codex plugin or set CODEX_COMPANION)" >&2; exit 1; }

if [ "$usage_check" = 1 ]; then
  u=$("$here/codex_usage.sh" 2>/dev/null)
  echo "usage: ${u:-unknown}"
  if printf '%s' "$u" | grep -qE '5h: (100|9[5-9])% used'; then
    echo "refusing to launch: 5h window nearly exhausted. Wait for the reset above." >&2; exit 2
  fi
fi

prompt_file=$brief
if [ "$guard" = 1 ]; then
  prompt_file=$(mktemp "${TMPDIR:-/tmp}/codex-run.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
  { codex_guard_header; printf '\n'; cat "$brief"; } > "$prompt_file"
  # Foreground: remove on exit. Detached: the companion may read the file after we exit, so keep it.
  [ "$detach" = 1 ] || trap 'rm -f "$prompt_file"' EXIT
fi

launch=$(codex_companion "$companion" task --background $resume $write --json --cwd "$cwd" --model "$model" --effort "$effort" --prompt-file "$prompt_file" 2>&1)
job=$(codex_job_id "$launch")
[ -n "$job" ] || { echo "launch failed: $launch" >&2; exit 1; }
echo "job: $job (model $model, $( [ -n "$write" ] && echo write || echo read-only ), cwd $cwd)"
if [ "$detach" = 1 ]; then
  [ -n "$out" ] && echo "out: $out"
  exit 0
fi

deadline=$(( $(date +%s) + timeout_s )); status=queued
while :; do
  left=$(( deadline - $(date +%s) )); [ $left -le 0 ] && { echo "timeout after ${timeout_s}s; job $job still $status" >&2; exit 3; }
  w=$(( left < 190 ? left : 190 ))
  st=$(codex_companion "$companion" status "$job" --cwd "$cwd" --wait --timeout-ms $((w*1000)) --json 2>/dev/null)
  status=$(printf '%s' "$st" | codex_parse_status)
  log=${status#* }; status=${status%% *}
  case "$status" in completed|failed|cancelled) break;; esac
done

codex_collect "$status" "$log" "$out"
exit $?
