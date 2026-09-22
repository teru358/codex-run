# codex-run — a Claude Code skill for delegating work to OpenAI Codex

One foreground command to launch a Codex job through the [openai-codex Claude Code plugin],
wait for it, and get the final report back — plus a rate-limit checker. Built for sessions
where Claude is the conductor and Codex does the reading, reviewing, and heavy editing, so the
Claude quota is spent on decisions rather than on polling.

```
$ skills/codex-run/scripts/codex_usage.sh
5h: 0% used (reset 09/22 18:48 JST) | 7d: 61% used (reset 09/26 19:29 JST) | plan: plus

$ skills/codex-run/scripts/codex_run.sh -b review-brief.md -m sol -c tmp/wt/a21a -o out/review.md
usage: 5h: 0% used (reset 09/22 18:48 JST) | 7d: 61% used (reset 09/26 19:29 JST) | plan: plus
job: task-muc725cy-ihk62r (model gpt-5.6-sol, read-only, cwd tmp/wt/a21a)
status: completed | subagent spawns in log: 0
report saved: out/review.md (40 lines)
```

## Install

Requirements: Claude Code with the `openai-codex` plugin installed and `codex login` done;
`node`, `python3`, `bash`.

Copy the skill into your personal or project skills directory:

```bash
git clone https://github.com/<you>/codex-run-skill
cp -r codex-run-skill/skills/codex-run ~/.claude/skills/        # personal
cp codex-run-skill/agents/codex-run.md ~/.claude/agents/       # optional subagent wrapper
# or: cp -r codex-run-skill/skills/codex-run <repo>/.claude/skills/   # per project
```

Claude then sees `codex-run` in its skill list and reads `SKILL.md` when the task calls for
Codex. The scripts also work on their own from any shell.

## What is in the box

| path | purpose |
|---|---|
| `skills/codex-run/SKILL.md` | when and how Claude should use it: brief rules, model choice, reading results |
| `scripts/codex_run.sh` | launch → wait → collect, with usage preflight; exit 2 on quota exhaustion |
| `scripts/codex_usage.sh` | 5h / 7d rate limits via `codex app-server` JSON-RPC |
| `scripts/codex_review.sh` | the plugin's built-in diff reviewer (`review` / `adversarial-review`), same launch → wait → collect |
| `agents/codex-run.md` | optional haiku subagent that runs the scripts and returns only the report (separate task line in the UI) |
| `references/brief-templates.md` | review / revise / implement brief skeletons with the constraint block |
| `references/companion-notes.md` | runtime quirks: state keyed by cwd, log format, sandbox limits |

## Why the constraint block matters

Every line in the brief template comes from a failure seen in practice: Codex spawning helper
agents that burned ~18M tokens in one job; briefs that ended in "shall I proceed?" with no
output; sandbox DNS failures that made `uv run pytest` report nothing; rewrites that silently
dropped contracts from a document. The skill encodes those lessons so the next session does
not relearn them.

## License

MIT

[openai-codex Claude Code plugin]: https://github.com/openai/codex
