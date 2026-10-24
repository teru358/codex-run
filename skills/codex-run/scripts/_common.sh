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

# Release the companion's cwd-scoped app-server broker after the last job ends.  A real
# companion exposes lifecycle/state modules; executable test stubs use the conservative
# process-list fallback instead.
codex_release_broker() {
  local cwd=$1 companion rc normalized pid released=0 out=""
  if [ "${CODEX_RUN_KEEP_BROKER:-}" = 1 ]; then
    echo "broker: kept (CODEX_RUN_KEEP_BROKER)"
    return 0
  fi

  companion=$(codex_find_companion)
  if [ -f "$companion" ] && [[ "$companion" = *.mjs ]] && command -v node >/dev/null 2>&1; then
    local runner=(node)
    command -v timeout >/dev/null 2>&1 && runner=(timeout 5 node)
    out=$(CODEX_RUN_BROKER_COMPANION=$companion CODEX_RUN_BROKER_CWD=$cwd "${runner[@]}" --input-type=module -e "$_CODEX_RELEASE_BROKER_JS"); rc=$?
    [ -n "$out" ] && echo "$out"
    case "$rc" in
      0) ;;
      124) echo "broker: release failed (timed out)" >&2;;
      *) echo "broker: release failed (node exited $rc)" >&2;;
    esac
    # A broker whose session file is gone or whose release was refused is left alone only
    # while a job still runs; otherwise sweep the process list for this cwd as well.
    case "$out" in *"broker: kept"*) return 0;; esac
  fi

  normalized=$cwd
  while [ "$normalized" != / ] && [ "${normalized%/}" != "$normalized" ]; do normalized=${normalized%/}; done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if kill -TERM "$pid" 2>/dev/null; then
      echo "broker: released (pid $pid)"
      released=1
    fi
  done < <(ps -eo pid=,args= | awk -v target="$normalized" '
    function normalize(value) { while (value != "/" && value ~ /\/$/) sub(/\/$/, "", value); return value }
    $0 ~ /app-server-broker\.mjs[[:space:]]+serve([[:space:]]|$)/ {
      for (i = 2; i < NF; i++) {
        if ($i == "--cwd" && normalize($(i + 1)) == target) { print $1; next }
      }
    }
  ')
  if [ "$released" = 1 ]; then return 0; fi
  case "$out" in *"broker: released"*|*"broker: none"*) ;; *) echo "broker: none";; esac
  return 0
}

# The lifecycle route: the companion's own modules shut the broker down, then clear its session.
_CODEX_RELEASE_BROKER_JS='
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const oneLine = (error) => String(error?.message ?? error).replace(/\s+/g, " ").slice(0, 200);
let finished = false;
const deadline = setTimeout(() => {
  if (!finished) {
    process.stderr.write("broker: release failed (timed out)\n");
    process.exit(0);
  }
}, 4900);
deadline.unref();

try {
  const scriptDir = path.dirname(process.env.CODEX_RUN_BROKER_COMPANION);
  const lifecycle = await import(pathToFileURL(path.join(scriptDir, "lib", "broker-lifecycle.mjs")).href);
  const state = await import(pathToFileURL(path.join(scriptDir, "lib", "state.mjs")).href);
  const cwd = process.env.CODEX_RUN_BROKER_CWD;
  const session = lifecycle.loadBrokerSession(cwd);
  if (!session) {
    console.log("broker: none");
  } else {
    const activeJobs = state.listJobs(cwd).filter((job) => job.status === "queued" || job.status === "running");
    if (activeJobs.length) {
      console.log(`broker: kept (${activeJobs.length} jobs running)`);
    } else {
      await lifecycle.sendBrokerShutdown(session.endpoint);
      lifecycle.teardownBrokerSession({
        ...session,
        killProcess: (pid, signal) => process.kill(pid, signal ?? "SIGTERM")
      });
      lifecycle.clearBrokerSession(cwd);
      console.log(`broker: released (pid ${session.pid})`);
    }
  }
} catch (error) {
  process.stderr.write(`broker: release failed (${oneLine(error)})\n`);
} finally {
  finished = true;
  clearTimeout(deadline);
}
'

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
