## Problem / motivation

Why is this needed, and for whom?

## Desired behaviour

What should happen — user stories or a description.

## Failure behaviour

What happens when something this FR depends on fails — what the user sees,
retries, what is logged. A fallback not described here is a finding in the
review of `/fr-workflow:ship`.

## Scope

- In scope:
- Out of scope:

## Spec delta

Specs: capability-a, capability-b

### ADDED capability-a: Requirement name
The system SHALL … — the full requirement text.

#### Scenario: name
- GIVEN a precondition, if any
- WHEN something happens
- THEN the observable result
- Evidence: unit test

### MODIFIED capability-b: Requirement name
The complete new text of the requirement, its scenarios included — `start` pins
the base version with a `Base:` line.

#### Scenario: name
- WHEN …
- THEN …
- Evidence: check on test

<!-- also: ### REMOVED <capability>: <name> with a Reason: line, and
### RENAMED <capability>: <old> -> <new>. Infrastructure or refactoring without a
spec: `Specs: none` and scenarios only. Evidence is one of unit test, eval,
check on test — details after a dash. -->

## Technical notes

How it fits into the existing code: the places to change, dependencies, the
invariants of new or reshaped data types.

## Open questions

None.

## Planning

- Areas: src/example
- Size: M
- Model: opus
- Effort: high
- Based on: 0000000
- Requests: none
