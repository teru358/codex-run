---
name: codex-run
description: Run OpenAI Codex as a cost-free (for Claude quota) reviewer, design drafter, or implementer through the openai-codex Claude Code plugin — in one foreground command that launches, waits, and returns the final report, with a rate-limit preflight. Use this whenever you want to delegate a design review, a spec/plan revision, an implementation task, or a second-opinion diagnosis to Codex; whenever the user mentions codex, "codex に投げて", "second opinion", "レビューを codex で", or asks how much Codex quota is left. Prefer this over the plugin's built-in `codex:rescue` subagent when you need to control the model, write access, working directory, or need the report back reliably.
---

# codex-run

Delegate work to Codex from a Claude Code session without spending Claude's own quota on
polling or forwarding. The skill wraps the `openai-codex` plugin's companion runtime
(`codex-companion.mjs`) so that a single Bash call does everything: preflight the Codex
rate limit, launch the job, wait for completion, and hand back the final report.

Why not `codex:rescue`? That built-in subagent is a one-shot forwarder: it costs a Claude
subagent turn, decides `--write` from the wording of your request, does not poll, and if the
job runs longer than ten minutes the report is left in a log file you must dig out yourself.
The scripts here make those choices explicit and keep the orchestrating session cheap.

## Quick use

```bash
S=<path-to-this-skill>/scripts
$S/codex_usage.sh                                   # 5h / 7d windows + reset times
$S/codex_run.sh -b brief.md -m sol -o out/review.md # read-only review, wait, save report
$S/codex_run.sh -b brief.md -m terra -w -c tmp/wt/x # write-capable implementation in a worktree
```

`codex_run.sh` prints the rate limit, the job id, then `status | subagent spawns in log: N`,
then the report (or saves it with `-o`). Exit codes: 0 done, 2 quota exhausted / preflight
refused, 3 timeout, 1 other. Run it in the foreground; a 190-second `status --wait` loop is
inside, so a 10-minute Bash timeout covers a typical review and the script keeps going for
longer jobs up to `-t` seconds.

## Writing the brief

Codex reads a prompt file (`--prompt-file`), so put the whole brief in a Markdown file. Start
it with the constraints block from `references/brief-templates.md` — every one of those lines
exists because of an observed failure mode:

- **No subagents.** Left alone, the larger Codex models spawn helper agents and a single job
  can consume tens of millions of tokens. Say "single thread, no spawn_agent" at the top.
- **No confirmation step.** A brief that contains a design tends to end with "shall I proceed?"
  and the job finishes with zero output. Say "no confirmation needed, run to completion".
- **Name the writable paths.** Write access is a launch flag (`-w`), not a promise in prose;
  but the brief should still list which files may change, so the sandbox refusal (writing
  outside the project) does not silently end the job.
- **Tests inside the sandbox have no network.** `uv`/`pip` resolution fails on DNS. Sync the
  virtualenv in the target directory yourself first, then tell Codex to use
  `uv run --offline pytest` (or the equivalent) and to paste raw test output, not a summary.
- **Ask for deviations explicitly.** Codex will quietly work around a blocked step. Ask for a
  "deviations / unfinished" section in the final report and read it first.

Pick the template that matches the job: `review` (read-only, report only), `revise` (edit one
document in place, no compression), `implement` (2–3 items per job — a single job rarely
finishes more, and `-r` resume adds little).

## Choosing the model

| alias | when |
|---|---|
| `terra` | default: drafts, in-place revisions, acceptance-check review rounds, mechanical implementation |
| `sol` | first rounds of a new design review, the round right after a Critical finding, changes touching locks / transactions / process boundaries |
| `luna` | cheap probes |

Both windows matter: the 5-hour window refills quickly, the 7-day window does not. Check
`codex_usage.sh` before a `sol` job. When the 5h window is exhausted the runtime returns
"usage limit" and the script exits 2 — wait for the reset instead of substituting Claude.

## Reading the result

Read the first line of a review (`Critical N / Important N / Minor N`) and the Critical items
before anything else; leave Important/Minor for when you write the verdicts. For a revision
job, check `git diff` deleted lines and grep for the terms you asked to remove — Codex's
rewrites are prone to dropping contracts when they "clean up". For implementation, re-run
the tests yourself outside the sandbox: reported green inside it has been wrong before.

The log line `subagent spawns in log: N` should read 0. If it does not, the brief's
constraint block was ignored — tighten it and relaunch.

## Working directory and job state

The companion keys its job state by the launch directory. `codex_run.sh` passes the same
`-c` directory to `status`, so you do not have to remember; but if you query
`codex-companion.mjs status` by hand, pass `--cwd` with the directory you launched from.
For work in a git worktree, launch with `-c <worktree>`; Codex cannot write to sibling
directories of its sandbox root.

See `references/brief-templates.md` for the three brief skeletons and
`references/companion-notes.md` for runtime quirks (status keys, log locations, resume).
