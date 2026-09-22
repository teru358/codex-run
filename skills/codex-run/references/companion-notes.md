# Companion runtime notes (openai-codex plugin, observed with codex-cli 0.155 / plugin 1.0.6)

- Script: `~/.claude/plugins/cache/openai-codex/codex/<ver>/scripts/codex-companion.mjs`.
  `codex_run.sh` picks the highest version; override with `CODEX_COMPANION`.
- `task --background --json` returns `{jobId, logFile, ...}` immediately. `status <id> --wait
  --timeout-ms N --json` blocks up to N ms and returns `job.status` in
  `queued | running | completed | failed | cancelled`.
- Job state lives under `~/.claude/plugins/data/codex-openai-codex/state/<dirname>-<hash>/jobs/`
  and is keyed by the launch directory. Query `status` with the same `--cwd` or you get
  "No job found".
- The final report is everything after the last `Final output` line in the job log. Progress
  lines such as `Command completed: ...` also contain the word "completed" — never grep the
  log for completion; use the JSON status.
- `--resume-last` continues the last thread in that directory. Resumed jobs tend to do less
  per turn; prefer a fresh job with a 2–3 item brief.
- Usage limits: the log shows `Codex error: You've hit your usage limit ... try again at
  HH:MM`. `codex_usage.sh` reads the same limits via `codex app-server` JSON-RPC
  (`initialize` → `account/rateLimits/read`): `primary` = 5-hour window, `secondary` =
  7-day window, `resetsAt` in epoch seconds. It needs ~6 s because stdin must stay open until
  the response arrives.
- Sandbox: read-only unless `--write`; cannot write outside the launch directory (a sibling
  worktree is outside); no DNS, so dependency resolution fails — pre-sync and run offline.
- Prompt size: every turn resends the whole context. Give Codex an excerpt (a few thousand
  tokens) rather than a 10k-line document; split reviews of large plans by task group.
