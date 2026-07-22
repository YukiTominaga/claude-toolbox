# Git Workflow

## Commits

- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`, `ci:` — with an optional scope, e.g. `feat(auth): ...`.
- Keep commits small and focused: one logical change per commit.
- Commit or push only when the user asks.

## Branches

- Do not commit directly on `main`/`master`; create a feature branch first.
- Never force-push to `main`/`master`. When a force push is genuinely needed
  on a feature branch, prefer `--force-with-lease`.

## Hygiene

- Review `git status` and the diff before committing; don't blanket-`git add -A`
  without checking what is staged.
- Don't rewrite published history.
