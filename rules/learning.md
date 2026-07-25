# Learning Capture

When a task surfaces a **non-obvious, reusable insight**, append it to the
project's `.claude/learnings.md` (create the file on first use). Capture things
a future session — or a teammate's agent — would otherwise rediscover the hard way:

- Gotchas and pitfalls specific to this project (build quirks, flaky steps,
  hidden coupling, environment traps)
- Decisions with non-obvious rationale ("X looks simpler but breaks Y")
- Commands or procedures that took real effort to figure out

Format: append a short dated entry —

```markdown
## 2026-06-10: <one-line title>
<2–5 lines: what happened, the fix/insight, why it matters>
```

Rules of thumb:

- Only record insights that are likely to recur. Routine work produces no entry.
- Don't duplicate what the repo already documents (README, CLAUDE.md, comments).
- `.claude/learnings.md` is shared via the repository; personal, cross-project
  insights belong in the built-in memory directory instead.
- The `/learn` command runs a deliberate end-of-session retrospective; this rule
  covers capturing insights inline as they happen.

## Findings That Are Not Yet Insights

A **learning** is settled: you know what it means and what to do about it. A
**finding** is not — friction you hit, an assumption that turned out broken, a
gap you noticed while doing something else. Findings belong in `docs/signals/`
(one file per finding, added via `scripts/signal-add.sh`), not here.

The test: can someone act on it alone? If yes and it is work, it belongs in
`docs/backlog.md`. If yes and it is knowledge, it belongs here. If no, it is a
signal — someone has to promote it before it becomes work.

Do not write the same thing to two stores. When a signal turns into a settled
insight, write it here and mark the signal `status: learned`.
