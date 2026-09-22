#!/usr/bin/env bash
# Codex plugin 内蔵のレビュアー (git 差分ベース) を 1 コマンドで起動 → 完了待ち → 本文回収する。
# ブリーフ不要の「差分だけ見せる」レビュー用。仕様や過去の裁定を読ませたい本格レビューは
# codex_run.sh + review ブリーフを使う。
# Wrap the plugin's built-in diff reviewer: launch, wait, collect. Use codex_run.sh with a
# review brief when the reviewer must read a spec or earlier verdicts.
#
# usage: codex_review.sh [-a] [-B BASE] [-s auto|working-tree|branch] [-c CWD] [-o OUT.md] [-t SECONDS] [focus text...]
#   -a  adversarial-review (accepts free focus text as the remaining args)
#   -B  base ref for branch scope (e.g. main)
#   -s  scope (default auto)
#   -c  working directory (job state is keyed by it)
#   -o  save the report
set -u
here=$(cd "$(dirname "$0")" && pwd)
kind=review; base=""; scope=auto; cwd="$PWD"; out=""; timeout_s=2400
while [ $# -gt 0 ]; do
  case "$1" in
    -a) kind=adversarial-review; shift;; -B) base=$2; shift 2;; -s) scope=$2; shift 2;;
    -c) cwd=$2; shift 2;; -o) out=$2; shift 2;; -t) timeout_s=$2; shift 2;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) break;;
  esac
done
focus="$*"
companion=${CODEX_COMPANION:-$(ls -1 "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)}
[ -f "$companion" ] || { echo "codex-companion.mjs not found" >&2; exit 1; }
echo "usage: $("$here/codex_usage.sh" 2>/dev/null)"
args=(--background --scope "$scope"); [ -n "$base" ] && args+=(--base "$base")
if [ "$kind" = adversarial-review ] && [ -n "$focus" ]; then
  launch=$(node "$companion" adversarial-review "${args[@]}" --cwd "$cwd" --json "$focus" 2>&1)
else
  launch=$(node "$companion" "$kind" "${args[@]}" --cwd "$cwd" --json 2>&1)
fi
job=$(printf '%s' "$launch" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["jobId"])
except Exception: print("")')
[ -n "$job" ] || { echo "launch failed: $launch" >&2; exit 1; }
echo "job: $job ($kind, scope $scope${base:+, base $base}, cwd $cwd)"
deadline=$(( $(date +%s) + timeout_s )); status=queued; log=""
while :; do
  left=$(( deadline - $(date +%s) )); [ $left -le 0 ] && { echo "timeout; job $job still $status" >&2; exit 3; }
  w=$(( left < 190 ? left : 190 ))
  st=$(node "$companion" status "$job" --cwd "$cwd" --wait --timeout-ms $((w*1000)) --json 2>/dev/null)
  read -r status log <<<"$(printf '%s' "$st" | python3 -c 'import sys,json
try: j=json.load(sys.stdin)["job"]; print(j.get("status",""), j.get("logFile",""))
except Exception: print("")')"
  case "$status" in completed|failed|cancelled) break;; esac
done
report=""; [ -n "$log" ] && [ -f "$log" ] && { n=$(grep -n "Final output" "$log" | tail -1 | cut -d: -f1); [ -n "$n" ] && report=$(tail -n +$((n+1)) "$log"); }
echo "status: $status"
[ -n "$out" ] && { mkdir -p "$(dirname "$out")"; printf '%s\n' "$report" > "$out"; echo "report saved: $out"; } || printf '%s\n' "$report"
[ "$status" = completed ]
