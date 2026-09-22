# Brief templates

Copy the constraints block verbatim to the top of every brief, then the job-specific part.

## Constraints block (all jobs)

```markdown
**Constraints (highest priority):** Do not use subagents, spawn_agent, collab, or parallel agents —
work in this single thread. Do not invoke skills. Keep tool calls minimal; do not read the same
file twice; read only the relevant lines of long files. No confirmation step: run to completion
and give a final report. Do not commit. Do not start services or make outbound network calls.
```

## review (read-only, `codex_run.sh` without `-w`)

```markdown
# <bundle> — review round N

<constraints block>
cwd = `<repo or worktree>`. Target = `<file or git range>`. Materials = <list, with "verdicts
from earlier rounds — do not relitigate">. You are not the author: verify every file:line
claim against the code and look for defects.

## Assumptions (out of scope for findings)
<decisions already made>

## Questions to answer (all of them)
1. <specific doubt, with file:line>
2. ...

## Output format
First line `Critical N / Important N / Minor N`. Each finding:
`[severity] title / file:line / failure scenario / evidence / fix direction (1–2 lines)`.
A question with no finding: one line "Q<n>: no finding (<what was checked>)". Mark guesses
as guesses. Do not report rewording, matters of degree, or preferences.
```

If a report file is wanted, add `Write only `<path>/codex-out.md`; put the same content in the
final reply` and launch with `-w` (report-into-file jobs need write access even though they
touch no source).

## revise (edit one document in place, `-w`)

```markdown
# <document> vN → vN+1

<constraints block>
The only file you may write is `<path>`. Inputs: the review `<...>` and the **verdicts `<...>`
(these are final; apply all of them; do not reopen)**.

**Edit in place. Do not rewrite or compress the whole document.** Lines unrelated to a verdict
must not change; the diff should be replacements for the verdicts plus additions only.
<list of sections to touch, per verdict>. Add a changelog row.
Final reply: sections changed, line count before/after, anything in the codebase that
contradicted a verdict (file:line).
```

## implement (`-w`, usually with `-c <worktree>`)

```markdown
# <task> implementation

<constraints block>
cwd = worktree `<path>` (branch `<name>`). Edit only inside this worktree. Do not touch
<real data dirs / config / plugin dirs>. Tests: `uv run --offline pytest ...` (venv already
synced; the sandbox has no network). Do not commit.

Spec = `<path>` sections <...>. Scope = <2–3 items>. Out of scope = <named>.

Per item: failing test → implementation → green; paste the raw pytest output. No process
labels (review round ids, AC numbers, "spec says") in code comments or docstrings — match
the existing comment style. Finally run `<test set>` and paste the output.
Final report: changed files (`git status --short`), per-item test output, a "deviations /
unfinished" section listing every place you departed from the brief.
```
