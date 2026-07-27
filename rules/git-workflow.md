# Git Workflow

- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`, `ci:` — with an optional scope, e.g. `feat(auth): ...`.
- One logical change per commit.
- Do not commit directly on `main`/`master`; create a feature branch first.
- Review `git status` and the diff before committing; don't blanket-`git add -A`
  without checking what is staged.
- Never force-push to `main`/`master`. When a force push is genuinely needed on a
  feature branch, prefer `--force-with-lease`.
