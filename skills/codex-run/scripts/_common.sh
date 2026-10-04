#!/usr/bin/env bash
# Shared helpers for codex_run.sh / codex_review.sh / codex_advise.sh / codex_wait.sh. Source this file; do not execute it.

# Print the path of codex-companion.mjs (CODEX_COMPANION, else newest installed plugin copy).
codex_find_companion() {
  printf '%s' "${CODEX_COMPANION:-$(ls -1 "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)}"
}

# Run the companion: via node for a .mjs/.js script, directly otherwise (lets tests use a
# plain executable stub through CODEX_COMPANION).
codex_companion() {
  local c=$1; shift
  case "$c" in *.mjs|*.js|*.cjs) node "$c" "$@";; *) "$c" "$@";; esac
}

# Extract the job id from the JSON printed by `companion task --background --json`.
codex_job_id() {
  printf '%s' "$1" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["jobId"])
except Exception: print("")'
}

# Parse `companion status --json` output on stdin into "<status> <logFile>".
codex_parse_status() {
  python3 -c 'import sys,json
try: j=json.load(sys.stdin)["job"]; print(j.get("status",""), j.get("logFile",""))
except Exception: print("")'
}

# codex_collect STATUS LOG OUT
# Print the "status:" line, save or print the report (text after the last "Final output"
# line of LOG), and return the script exit code: 0 completed / 2 usage limit / 1 other.
codex_collect() {
  local status=$1 log=$2 out=$3 report="" n spawns err
  if [ -n "$log" ] && [ -f "$log" ]; then
    n=$(grep -n "Final output" "$log" | tail -1 | cut -d: -f1)
    [ -n "$n" ] && report=$(tail -n +$((n+1)) "$log")
    spawns=$(grep -c "spawn_agent" "$log"); err=$(grep "Codex error" "$log" | tail -1 | cut -c1-200)
  else
    spawns="?"; err=""
  fi
  echo "status: $status | subagent spawns in log: $spawns${err:+ | $err}"
  [ -n "$out" ] && { mkdir -p "$(dirname "$out")"; printf '%s\n' "$report" > "$out"; echo "report saved: $out ($(wc -l < "$out") lines)"; }
  [ -z "$out" ] && printf '%s\n' "$report"
  case "$status" in
    completed) return 0;;
    *) printf '%s' "$err" | grep -q "usage limit" && return 2; return 1;;
  esac
}

# Print the fixed runner-constraints block that codex_run.sh / codex_review.sh put in front of the
# prompt, and codex_advise.sh at the top of its own header (no trailing blank line).
codex_guard_header() {
  cat <<'GUARD'
# Runner constraints (added by codex-run; they override anything below that conflicts)
- Single thread. Do NOT spawn subagents or parallel agents (`spawn_agent` and similar tools are forbidden). Do all reading, analysis and writing yourself, in this one session.
- Do not start background processes that outlive your turn.
- No confirmation step: do not ask whether to proceed; do the task and finish with the final report.
GUARD
}
