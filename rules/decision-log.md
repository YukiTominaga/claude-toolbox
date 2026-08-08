# Decision Log

When a task settles a **non-obvious technical choice** — one where a reasonable
engineer would ask "why this and not X?" six months later — append a short dated
entry to the project's `.claude/decisions.md` (create the file on first use),
**at the moment it is decided**, not at the end of the task:

```markdown
## 2026-06-10: <one-line title>
- 決めたこと: <what was chosen>
- 理由: <why — the constraint or evidence that drove it>
- 採らなかった案: <what was rejected, and why>
- 影響範囲: <files / components affected>
```

Prose is fine; this is raw material, not a deliverable. The rejected options and
their reasons are the part nobody can reconstruct later — record them even when
the choice feels obvious right now.

Only record decisions, not activity: routine implementation, renames, and
mechanical refactors produce no entry. Trivially reversible choices don't either.

`/crystal:adr` reads this file as its primary source when writing an ADR into
`docs/adr/`. Nothing else consumes it, so an unwritten decision is simply lost —
by the time the ADR is written, memory has already faded.

**Commit the file.** It is shared material like `.claude/learnings.md`, not local
scratch like `.claude/goal.md` — a decision log that lives on one machine cannot
back a team's ADRs. Leaving it untracked and un-ignored is the one wrong answer:
it pollutes `stop-gate.sh`'s "nothing changed" check. Nothing executes from this
file, so tracking it carries none of the risk that keeps `goal.md` ignored.

Append only; never rewrite past entries. When `/crystal:adr` promotes one into an
ADR it appends a `→ ADR-NNNN` marker to the original — that marks it as harvested,
it does not replace it. Past 32KB, split by year into `.claude/decisions/YYYY.md`.
