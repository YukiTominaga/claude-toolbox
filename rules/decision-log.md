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
