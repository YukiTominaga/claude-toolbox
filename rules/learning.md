# Learning Capture

When a task surfaces a **non-obvious, reusable insight** — a project-specific
gotcha, a decision with non-obvious rationale, or a procedure that took real
effort to figure out — append a short dated entry to the project's
`.claude/learnings.md` (create the file on first use):

```markdown
## 2026-06-10: <one-line title>
<2–5 lines: what happened, the fix/insight, why it matters>
```

Only record insights likely to recur; routine work produces no entry. The file is
injected back into context at session start (`session-learnings.sh`), so write it
for that reader. `/crystal:learn` covers the deliberate end-of-session
retrospective; this rule covers capturing insights inline as they happen.
