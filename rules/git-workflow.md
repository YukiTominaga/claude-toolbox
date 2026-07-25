# Git Workflow

## Commits

- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`, `ci:` — with an optional scope, e.g. `feat(auth): ...`.
- Keep commits small and focused: one logical change per commit.
- Commit or push only when the user asks. Exception: the `auto-commit` Stop
  hook commits work-in-progress on feature branches so nothing is lost — those
  commits are expected to be amended or squashed before review.

## Branches

- Do not commit directly on `main`/`master`; create a feature branch first.
- Never force-push to `main`/`master`. When a force push is genuinely needed
  on a feature branch, prefer `--force-with-lease`.

## Hygiene

- Review `git status` and the diff before committing; don't blanket-`git add -A`
  without checking what is staged. Exception: the `auto-commit` hook stages
  everything by design, guarded by a secret-path check that aborts the commit.
- Don't rewrite published history.
