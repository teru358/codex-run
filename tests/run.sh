#!/usr/bin/env bash
# Offline test for codex_run.sh -d + codex_wait.sh using a fake companion (no Codex quota used).
# usage: tests/run.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
S=$root/skills/codex-run/scripts
tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-run-test.XXXXXX")
broker_pids=()
cleanup() {
  local pid
  for pid in "${broker_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
fail=0
check() { # check NAME CONDITION-EXIT-CODE
  if [ "$2" = 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi
}

cat > "$tmp/log.txt" <<'LOG'
[..] working
Final output
Hello report line 1
Hello report line 2
LOG

# Fake companion: `task` returns a job id; `status` says running on the 1st call, completed after.
cat > "$tmp/fake-companion" <<EOF2
#!/bin/bash
cnt="$tmp/count"
case "\$1" in
  task)
    while [ \$# -gt 0 ]; do [ "\$1" = --prompt-file ] && cp "\$2" "$tmp/prompt.seen"; shift; done
    echo '{"jobId":"task-fake"}';;
  status)
    n=\$(cat "\$cnt" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "\$cnt"
    if [ \$n -lt 2 ]; then echo '{"job":{"status":"running"}}'
    else echo '{"job":{"status":"completed","logFile":"$tmp/log.txt"}}'; fi;;
esac
EOF2
chmod +x "$tmp/fake-companion"
export CODEX_COMPANION="$tmp/fake-companion"
echo "brief" > "$tmp/brief.md"

# 1. detach: returns immediately with usage/job/out lines, exit 0, no status call made
out1=$("$S/codex_run.sh" -d -b "$tmp/brief.md" -c "$tmp" -o "$tmp/out/r.md" --no-usage-check 2>&1); rc=$?
check "detach exits 0" $([ $rc = 0 ]; echo $?)
check "detach prints job line" $(printf '%s' "$out1" | grep -q '^job: task-fake '; echo $?)
check "detach prints out line" $(printf '%s' "$out1" | grep -qx "out: $tmp/out/r.md"; echo $?)
check "detach did not poll" $([ ! -f "$tmp/count" ]; echo $?)
check "detach did not write -o" $([ ! -e "$tmp/out/r.md" ]; echo $?)

# 2. wait #1: still running -> exit 4
out2=$("$S/codex_wait.sh" task-fake -c "$tmp" -o "$tmp/out/r.md" -t 1 2>&1); rc=$?
check "wait 1 exits 4" $([ $rc = 4 ]; echo $?)
check "wait 1 says still running" $(printf '%s' "$out2" | grep -q 'still running; call codex_wait.sh again'; echo $?)

# 3. wait #2: completed -> exit 0, report collected
out3=$("$S/codex_wait.sh" task-fake -c "$tmp" -o "$tmp/out/r.md" -t 1 2>&1); rc=$?
check "wait 2 exits 0" $([ $rc = 0 ]; echo $?)
check "wait 2 status line" $(printf '%s' "$out3" | grep -q '^status: completed | subagent spawns in log: 0'; echo $?)
check "report saved with body" $(grep -q 'Hello report line 2' "$tmp/out/r.md" && ! grep -q 'working' "$tmp/out/r.md"; echo $?)

# 4. without -o the body goes to stdout
out4=$("$S/codex_wait.sh" task-fake -c "$tmp" 2>&1)
check "stdout report" $(printf '%s' "$out4" | grep -q 'Hello report line 1'; echo $?)

# 5. failed with usage limit -> exit 2
echo 'Codex error: usage limit reached' >> "$tmp/log.txt"
sed -i 's/"completed"/"failed"/' "$tmp/fake-companion"
"$S/codex_wait.sh" task-fake -c "$tmp" >/dev/null 2>&1; rc=$?
check "failed + usage limit exits 2" $([ $rc = 2 ]; echo $?)

# 6. foreground (no -d) still waits and collects
rm -f "$tmp/count"; sed -i 's/"failed"/"completed"/' "$tmp/fake-companion"
"$S/codex_run.sh" -b "$tmp/brief.md" -c "$tmp" --no-usage-check 2>&1 | grep -q 'Hello report line 1'
check "foreground run still collects" $([ "${PIPESTATUS[1]}" = 0 ]; echo $?)

# 7. guard: default prepends the constraints block before the original brief
printf 'line A\nline B\n' > "$tmp/brief2.md"
rm -f "$tmp/prompt.seen"
"$S/codex_run.sh" -b "$tmp/brief2.md" -c "$tmp" --no-usage-check >/dev/null 2>&1
check "guard: starts with Runner constraints" $(head -1 "$tmp/prompt.seen" | grep -q '^# Runner constraints'; echo $?)
check "guard: forbids subagents" $(grep -q 'Do NOT spawn subagents' "$tmp/prompt.seen"; echo $?)
check "guard: original brief follows" $(tail -2 "$tmp/prompt.seen" | cmp -s - "$tmp/brief2.md"; echo $?)
check "guard: brief file untouched" $([ "$(cat "$tmp/brief2.md")" = "$(printf 'line A\nline B')" ]; echo $?)
check "guard: foreground temp file removed" $([ -z "$(ls "$tmp"/codex-run.* 2>/dev/null)" ]; echo $?)
# 8. --no-guard passes the brief unchanged
rm -f "$tmp/prompt.seen"
"$S/codex_run.sh" --no-guard -b "$tmp/brief2.md" -c "$tmp" --no-usage-check >/dev/null 2>&1
check "no-guard: prompt identical to brief" $(cmp -s "$tmp/prompt.seen" "$tmp/brief2.md"; echo $?)
# 9. detach keeps the guarded temp file
TMPDIR=$tmp "$S/codex_run.sh" -d -b "$tmp/brief2.md" -c "$tmp" --no-usage-check >/dev/null 2>&1
check "guard: detach keeps temp file" $([ -n "$(ls "$tmp"/codex-run.* 2>/dev/null)" ]; echo $?)

# 10. Broker cleanup uses the fallback for the executable fake companion.  Its command line
# deliberately matches the real broker shape so this also proves cwd-scoped PID matching.
cat > "$tmp/app-server-broker.mjs" <<'BROKER'
setInterval(() => {}, 1000)
BROKER
start_broker() { # CWD
  node "$tmp/app-server-broker.mjs" serve --endpoint "unix:$1/b.sock" --cwd "$1" --pid-file "$1/b.pid" >/dev/null 2>&1 &
  broker_pid=$!
  broker_pids+=("$broker_pid")
}
mkdir -p "$tmp/other"

start_broker "$tmp"; pid_release=$broker_pid
out10=$("$S/codex_wait.sh" task-fake -c "$tmp" -t 1 2>&1); rc=$?
check "completed wait releases matching broker" $([ $rc = 0 ] && printf '%s' "$out10" | grep -qx "broker: released (pid $pid_release)"; echo $?)
sleep 0.1
check "released broker has exited" $(kill -0 "$pid_release" 2>/dev/null; test $? -ne 0; echo $?)

start_broker "$tmp"; pid_keep=$broker_pid
out11=$("$S/codex_wait.sh" task-fake -c "$tmp" -t 1 --keep-broker 2>&1); rc=$?
check "--keep-broker keeps matching broker" $([ $rc = 0 ] && printf '%s' "$out11" | grep -qx 'broker: kept (CODEX_RUN_KEEP_BROKER)' && kill -0 "$pid_keep" 2>/dev/null; echo $?)

start_broker "$tmp"; pid_env_keep=$broker_pid
out12=$(CODEX_RUN_KEEP_BROKER=1 "$S/codex_wait.sh" task-fake -c "$tmp" -t 1 2>&1); rc=$?
check "CODEX_RUN_KEEP_BROKER keeps matching broker" $([ $rc = 0 ] && printf '%s' "$out12" | grep -qx 'broker: kept (CODEX_RUN_KEEP_BROKER)' && kill -0 "$pid_env_keep" 2>/dev/null; echo $?)

start_broker "$tmp/other"; pid_other=$broker_pid
start_broker "$tmp"; pid_scoped=$broker_pid
out13=$("$S/codex_wait.sh" task-fake -c "$tmp/" -t 1 2>&1); rc=$?
check "release normalizes cwd and spares another broker" $([ $rc = 0 ] && printf '%s' "$out13" | grep -qx "broker: released (pid $pid_scoped)" && kill -0 "$pid_other" 2>/dev/null; echo $?)

start_broker "$tmp"; pid_detach=$broker_pid
out14=$("$S/codex_run.sh" -d -b "$tmp/brief.md" -c "$tmp" --no-usage-check 2>&1); rc=$?
check "detach does not release broker" $([ $rc = 0 ] && ! printf '%s' "$out14" | grep -q '^broker:' && kill -0 "$pid_detach" 2>/dev/null; echo $?)

# 11. A .mjs companion takes the lifecycle API route.  The small modules below expose the
# same public functions as the plugin and record the required shutdown/teardown/clear order.
mkdir -p "$tmp/mjs/scripts/lib"
: > "$tmp/mjs/scripts/codex-companion.mjs"
cat > "$tmp/mjs/scripts/lib/broker-lifecycle.mjs" <<'LIFECYCLE'
import fs from "node:fs";
const mark = (name) => fs.appendFileSync(process.env.TEST_BROKER_MARKER, `${name}\n`);
export const loadBrokerSession = () => ({ endpoint: "unix:test", pid: Number(process.env.TEST_BROKER_PID) });
export const sendBrokerShutdown = async () => mark("shutdown");
export const teardownBrokerSession = ({ pid, killProcess }) => { mark("teardown"); killProcess(pid); };
export const clearBrokerSession = () => mark("clear");
LIFECYCLE
cat > "$tmp/mjs/scripts/lib/state.mjs" <<'STATE'
export const listJobs = () => process.env.TEST_BROKER_ACTIVE ? [{ status: process.env.TEST_BROKER_ACTIVE }] : [];
STATE

start_broker "$tmp"; pid_api=$broker_pid
marker="$tmp/api-marker"
out15=$(TEST_BROKER_PID="$pid_api" TEST_BROKER_MARKER="$marker" CODEX_COMPANION="$tmp/mjs/scripts/codex-companion.mjs" bash -c '. "$1"; codex_release_broker "$2"' _ "$S/_common.sh" "$tmp" 2>&1); rc=$?
check "mjs companion releases through lifecycle API" $([ $rc = 0 ] && printf '%s' "$out15" | grep -qx "broker: released (pid $pid_api)" && [ "$(cat "$marker")" = "$(printf 'shutdown\nteardown\nclear')" ]; echo $?)
sleep 0.1
check "lifecycle API kills broker by pid" $(kill -0 "$pid_api" 2>/dev/null; test $? -ne 0; echo $?)

start_broker "$tmp"; pid_api_running=$broker_pid
out16=$(TEST_BROKER_PID="$pid_api_running" TEST_BROKER_MARKER="$marker" TEST_BROKER_ACTIVE=running CODEX_COMPANION="$tmp/mjs/scripts/codex-companion.mjs" bash -c '. "$1"; codex_release_broker "$2"' _ "$S/_common.sh" "$tmp" 2>&1); rc=$?
check "lifecycle API keeps broker with a running job" $([ $rc = 0 ] && printf '%s' "$out16" | grep -qx 'broker: kept (1 jobs running)' && kill -0 "$pid_api_running" 2>/dev/null; echo $?)

# 12. Advice defers release to its own foreground completion path, avoiding a duplicate line.
start_broker "$tmp"; pid_advise=$broker_pid
out17=$(CODEX_COMPANION="$tmp/fake-companion" "$S/codex_advise.sh" -q 'test question' -c "$tmp" -t 1 --no-usage-check 2>&1); rc=$?
check "advise releases broker once after foreground completion" $([ $rc = 0 ] && [ "$(printf '%s' "$out17" | grep -cx "broker: released (pid $pid_advise)")" = 1 ]; echo $?)
sleep 0.1
check "advice release stops its broker" $(kill -0 "$pid_advise" 2>/dev/null; test $? -ne 0; echo $?)

[ $fail = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
