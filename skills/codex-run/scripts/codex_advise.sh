#!/usr/bin/env bash
# Ask Codex for advice (read-only second opinion) — like an "advisor" call from the
# orchestrating model. Builds a brief from a question plus optional context files, then runs
# codex_run.sh read-only and prints the answer.
#
# usage: codex_advise.sh (-q "question text" | -f QUESTION.md) [-C FILE]... [-m terra|sol|luna|spark]
#                        [-c CWD] [-o OUT.md] [-e low|medium|high] [-t SECONDS] [--no-usage-check]
#   -q  the question (short text). Use -f for a longer one.
#   -f  file holding the question (Markdown).
#   -C  context file to append verbatim (repeatable): a diff, a spec excerpt, a plan, earlier
#       verdicts. Keep the total small — the whole thing is one prompt. Codex can also read
#       the repository under -c itself, so prefer naming paths in the question over pasting.
#   -m  model alias (default: terra; sol for design-level questions).
#   -c  working directory the sandbox may read (default: current dir).
#   -o  save the answer to this file as well as printing it.
#   -e  reasoning effort (default: medium).  -t  overall timeout seconds (default: 1200).
# The answer is always read-only: Codex is told not to edit files, spawn agents, or ask for
# confirmation, and to answer with a recommendation + reasons + what it would check first.
set -u
here=$(cd "$(dirname "$0")" && pwd)
q=""; qfile=""; ctx=(); model="terra"; cwd="$PWD"; out=""; effort="medium"; timeout_s=1200; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    -q) q=$2; shift 2;; -f) qfile=$2; shift 2;; -C) ctx+=("$2"); shift 2;;
    -m) model=$2; shift 2;; -c) cwd=$2; shift 2;; -o) out=$2; shift 2;;
    -e) effort=$2; shift 2;; -t) timeout_s=$2; shift 2;;
    --no-usage-check) extra+=("--no-usage-check"); shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
if [ -n "$qfile" ]; then [ -f "$qfile" ] || { echo "question file not found: $qfile" >&2; exit 1; }; q=$(cat "$qfile"); fi
[ -n "$q" ] || { echo "no question (-q or -f)" >&2; exit 1; }
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/codex-advise.XXXXXX")
brief="$tmpd/brief.md"
{
  cat <<'HDR'
# Advice request (read-only)

Constraints — follow every line:
- Single thread. Do NOT spawn subagents (`spawn_agent` is forbidden).
- Read-only. Do not edit, create, or delete any file. Do not run commands that change state.
- No confirmation step. Do not ask whether to proceed; answer and finish.
- You may read the repository under the working directory to ground your answer. Cite paths
  and line numbers you actually opened.
- Answer format, in this order, in the language of the question:
  1. **Recommendation** — one or two sentences.
  2. **Why** — the strongest reasons, each tied to something concrete (a file, a contract, a
     failure mode). Say plainly if the premise of the question looks wrong.
  3. **What I would check first** — the cheapest observation or test that would confirm or
     refute the recommendation.
  4. **Risks / what this does not cover** — short.
  Keep it under ~60 lines. No preamble, no restating the question.

## Question

HDR
  printf '%s\n' "$q"
  for f in "${ctx[@]}"; do
    [ -f "$f" ] || { echo "context file not found: $f" >&2; exit 1; }
    printf '\n## Context: %s\n\n```\n' "$(basename "$f")"; cat "$f"; printf '\n```\n'
  done
} > "$brief"
args=(-b "$brief" -m "$model" -c "$cwd" -e "$effort" -t "$timeout_s" "${extra[@]}")
[ -n "$out" ] && args+=(-o "$out")
"$here/codex_run.sh" "${args[@]}"
rc=$?
rm -rf "$tmpd"
exit $rc
