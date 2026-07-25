# Verification

In any agent loop the verifier — not the generator — is the bottleneck. Producing a
candidate is cheap; proving it is correct is the work. Treat "how will this be checked?"
as part of the task, not as an afterthought.

## The Verification Ladder

Every claim of correctness sits at one of five levels:

| Level | Kind | Examples |
|---|---|---|
| L1 | Deterministic | exit code, assertion, golden output, byte comparison |
| L2 | Rule over the artifact | linter, type checker, schema, format check |
| L3 | Delayed fact | test suite, build, deploy, real observed behavior |
| L4 | Model judgment | a second model scoring against a rubric |
| L5 | Human checkpoint | a person reviews and approves |

Rules:

- **Stay as low on the ladder as the task allows.** Reach for L4 only when the property
  is genuinely subjective; reach for L5 only when the action is irreversible or outside
  the agreed scope.
- **L1–L2 is the unattended zone.** Anything that runs without a human watching must be
  gated by checks at these levels. L4–L5 means a person is involved somewhere.
- **The verifier must be independent of the generator.** Never accept self-assessment
  from the same context that produced the work — spawn a separate verifier, or run a
  command whose output you did not write.
- **The verifier should be cheaper and more reliable than the action it checks.** If
  verifying costs more than redoing the work, the check is at the wrong level.

## Reporting Verification

- State the level at which each claim was verified. "L1" or "L3" requires the actual
  command output as evidence; without output, the correct answer is "unverified".
- Never promote a claim up the ladder in the report — a rubric judgment is L4 even when
  it agrees with what you believe.
- When a check cannot be run, say which one and why, rather than substituting a lower-
  confidence claim silently.

## Where the Levels Live in This Setup

| Mechanism | Level |
|---|---|
| `lint-changed` hook | L2 |
| `project-checks.sh` (typecheck / lint / test), run by `stop-gate` and by `goal-gate` on every round | L1–L3 |
| `evals/cases/*.md` of `type: command` | L1–L2 |
| `evals/cases/*.md` of `type: rubric`, `goal-gate`'s judge | L4 |
| `verifier` subagent (independent context, runs the commands itself) | reports L1–L4 |
| Gates listed in a project's `LOOP.md` | L5 |

Prefer adding a `type: command` eval case over a `type: rubric` one whenever the
property can be expressed as a command and an expected exit code.
