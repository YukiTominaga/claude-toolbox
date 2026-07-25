# Git Workflow

## Commits

- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`, `ci:` — with an optional scope, e.g. `feat(auth): ...`.
- Keep commits small and focused: one logical change per commit.
- Commit freely on feature branches — an unrecorded change is a change that can
  be lost. The `auto-commit` hook does this automatically at the end of a turn.
- Work-in-progress commits are expected; amend or squash them into intentional
  changes before asking for review.

## Branches and Pushing

- Do not commit directly on `main`/`master`; create a feature branch first.
- Push feature branches freely — an unpushed commit is lost when the machine or
  container goes away, and pushing to a feature branch is reversible.
- Pushing to `main`/`master`, and creating or merging a pull request, require
  the user's instruction. Those are the irreversible steps.
- Never force-push to `main`/`master`. When a force push is genuinely needed
  on a feature branch, prefer `--force-with-lease`.

## Hygiene

- Staging everything (`git add -A`) is fine; check the diff for accidentally
  included secrets first (see `security.md`). The `auto-commit` hook enforces
  this with a secret-path check that aborts the commit.
- Don't rewrite published history.
