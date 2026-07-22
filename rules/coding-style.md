# Coding Style

## Immutability

Prefer creating new objects over mutating existing ones. Return updated copies
instead of modifying arguments in place. Immutable data prevents hidden side
effects and makes debugging easier.

## Core Principles

- **KISS**: Prefer the simplest solution that actually works. Optimize for
  clarity over cleverness.
- **DRY**: Extract repeated logic into shared functions — but only when the
  repetition is real, not speculative.
- **YAGNI**: Do not build features or abstractions before they are needed.
  Start simple, refactor when the pressure is real.

## File Organization

Many small files over few large files: high cohesion, low coupling.
Aim for 200–400 lines per file; treat 800 lines as a ceiling worth refactoring.
Organize by feature/domain, not by type.

## Error Handling

Never silently swallow errors. Handle them explicitly at every level:
user-friendly messages in UI-facing code, detailed context in server-side logs.

## Definition of Done

Never claim work is complete without verifying it. Before reporting done:
run the project's existing tests/lint/build relevant to the change, and report
failures honestly instead of hiding them.
