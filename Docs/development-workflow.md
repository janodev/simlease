---
type: Development Playbook
title: Development Workflow and Repository Conventions
description: Guides safe changes to SimLease source, tests, documentation, and release artifacts.
tags: [development, workflow, repository, review]
timestamp: 2026-07-15T00:00:00Z
status: current-guidance
---

# Start Here

Read [current architecture](current-architecture.md) and
[target session architecture](session-architecture.md) before changing locks,
allocation, Simulator lifecycle, registry persistence, or CLI behavior. Keep
implemented behavior and target behavior explicit in code comments, tests, and
user documentation.

# Repository Map

| Path | Purpose |
|---|---|
| [`Sources/SimLeaseCore`](../Sources/SimLeaseCore/) | Locking, registry, allocation, Simulator process adapter, and window focus. |
| [`Sources/simlease`](../Sources/simlease/) | ArgumentParser CLI and process-facing output contract. |
| [`Sources/SimLeaseApp`](../Sources/SimLeaseApp/) | Menubar status, focus, release, and automatic GC. |
| [`Tests/SimLeaseCoreTests`](../Tests/SimLeaseCoreTests/) | Current XCTest core tests and fake process runner. |
| [`skills/simlease`](../skills/simlease/) | Agent-facing operational guidance; update only after behavior is implemented. |
| [`Docs`](./) | Architecture, safety invariants, testing expectations, and decisions. |

The Swift package targets macOS 14 or later and uses Swift Argument Parser. Treat
[`Package.swift`](../Package.swift) as the package source of truth.

# Routine Commands

Run commands from the repository root:

```bash
make test
make build
make app
```

Use a focused Swift test while iterating:

```bash
swift test --filter FileLockTests
swift test --filter AllocatorTests
```

`make install` writes the release CLI to `PREFIX` and is not routine validation.
Use it only when installation is explicitly in scope.

# Change Discipline

1. Work in a dedicated Git branch and worktree.
2. Inspect the current implementation and relevant tests before editing.
3. State whether a change affects legacy cooperative claims, the target session
   path, or both.
4. Keep the change narrow and add failure-path tests with the behavior.
5. Run focused tests, then the complete suite.
6. Review the final diff for unintended compatibility, documentation, registry,
   and cleanup changes.
7. Do not update the README or agent skill to promise a target guarantee before
   its implementation and tests land.

# Implementation Conventions

* Route subprocess execution through `ProcessRunner` so unit tests can inject
  results and failures.
* Use explicit UDIDs for every Simulator operation. Never select by a renamed
  display name.
* Keep machine-consumable stdout stable; send diagnostics to stderr. For
  `simlease run`, preserve the child streams rather than wrapping ordinary output.
* Include command, exit status, and useful stderr in checked Simulator errors.
* Treat malformed discovery output as failure, not an empty successful result.
* Use monotonic time for lock deadlines. Wall-clock time remains appropriate for
  human-readable timestamps and persisted expiry metadata.
* Kernel lock files are persistent and must never be unlinked during release.
* Open lock descriptors close-on-exec unless inheritance is a deliberate,
  separately tested ownership design.
* Persist lifecycle state before publishing success. Cleanup failure becomes a
  recoverable quarantine state, not silent success.
* Sort imports alphabetically and keep public compatibility changes deliberate.

# Registry Changes

When changing the registry:

1. Define the lifecycle and compatibility meaning of each new field.
2. Increment schema only when older readers cannot safely consume the data.
3. Test old schema decoding, new schema round trips, unsupported newer schema,
   interrupted writes, and corruption behavior.
4. Never make `missing` or `cannot decode` equivalent to proof that a simulator
   is unowned.
5. Keep session metadata observational; live kernel locks remain authoritative.

# Simulator Lifecycle Changes

Classify every operation as one of:

* **Discovery** - Must validate command success and structured output.
* **Ownership transition** - Must occur under the appropriate global or per-UDID
  lock and be durably represented.
* **Session operation** - Must run while the per-UDID lock is held.
* **Cleanup** - Must be checked, retryable, and quarantine on failure.
* **Presentation** - Rename and focus may be nonessential, but failures must not
  be confused with ownership success.

Use a real Simulator only for an explicitly scoped integration test. Create a
unique disposable target, retain its exact UDID, and clean or quarantine only
that target.

# Review Checklist

Before merging a locking or session change, verify:

* A live owner cannot be displaced by timeout, TTL, worktree deletion, registry
  corruption, or wall-clock movement.
* No path unlinks a lock file that another process could have opened.
* Same-worktree concurrent `run` sessions remain independent.
* Child launch happens only after boot readiness.
* Every setup and cleanup failure has a deterministic state and exit result.
* Registry loss cannot make an abandoned session simulator reusable.
* All new subprocess and crash paths appear in the
  [failure matrix](testing-strategy.md).
* README, skill, and docs still distinguish current and target behavior.

# Documentation Maintenance

`Docs/index.md` is the progressive-disclosure index and has no frontmatter. Every
other Markdown document in `Docs` requires OKF frontmatter with a nonempty `type`.
Update the relevant concept and the [decision log](roadmap-and-decisions.md) when
an invariant, delivery status, or accepted choice changes.
