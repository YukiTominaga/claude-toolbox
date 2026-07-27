# Testing

## When to Write Tests

- When implementing application code (new features, behavior changes, bug
  fixes), write or update tests in the same change — not as a separate
  follow-up task.
- Bug fixes must include a regression test that fails before the fix and
  passes after it.
- Exempt: documentation/config-only changes, throwaway scripts or prototypes
  explicitly framed as disposable, and pure refactors already covered by
  existing tests (run those instead).

## What to Test

- When docs/spec/ defines acceptance criteria, map each testable criterion
  to at least one test case.
- Prioritize business logic, utilities, and data transformations. UI glue or
  trivial wiring may stay untested when the cost outweighs the value — say so
  in the completion report.
- Cover at least one boundary or failure-path case, not only the happy path.

## How

- Follow the project's existing test framework, directory layout, and naming
  conventions. Never introduce a second framework into a project that has one.
- If the project has no test infrastructure, propose a suitable setup and get
  the user's approval before adding it. Do not silently skip tests, and do not
  set up infrastructure unasked.
- Tests must fail when the behavior they cover breaks — avoid tautological
  tests (e.g., mocking the unit under test).
