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
[session architecture](session-architecture.md) before changing locks,
allocation, Simulator lifecycle, registry persistence, process supervision, or
CLI behavior. Decide whether a change affects safe foreground sessions,
cooperative legacy leases, or both.

# Repository Map

| Path | Purpose |
|---|---|
| [`Sources/SimLeaseCore`](../Sources/SimLeaseCore/) | Kernel locking, registry, session and legacy allocation, Simulator process adapter, and window focus. |
| [`Sources/simlease`](../Sources/simlease/) | ArgumentParser commands, child supervision, signal forwarding, and process-facing output contracts. |
| [`Sources/SimLeaseApp`](../Sources/SimLeaseApp/) | Menubar status, focus, release controls, and automatic GC. |
| [`Tests/SimLeaseCoreTests`](../Tests/SimLeaseCoreTests/) | XCTest, Swift Testing, injected-runner, and real-subprocess coverage. |
| [`skills/simlease`](../skills/simlease/) | Concise agent-facing operational guidance. |
| [`Docs`](./) | Architecture, safety invariants, testing evidence, and decisions. |

The Swift package targets macOS 27 or later and uses Swift Argument Parser.
Treat [`Package.swift`](../Package.swift) as the package source of truth.

# Routine Commands

Run the full local validation sequence from the repository root:

```bash
make lint
make test
make build
make app
```

Use focused tests while iterating:

```bash
swift test --filter FileLockTests
swift test --filter SimulatorSessionTests
swift test --filter SimleaseCLIIntegrationTests
```

`make install` writes the release CLI to `PREFIX`; use it only when installation
is in scope. Do not point tests at the developer's live state. Set
`SIMLEASE_HOME` to a unique temporary directory for CLI or process tests.

# Change Discipline

1. Work in a dedicated Git branch and isolated worktree.
2. Inspect the implementation and relevant tests before editing.
3. Preserve the distinction between session lock authority and legacy metadata.
4. Keep behavior changes narrow and add failure-path evidence with the code.
5. Run focused validation, then lint, the complete suite, and a release build.
6. Review the final diff for compatibility, persistence, cleanup, and
   documentation regressions.
7. Update README and skill examples only after the behavior they recommend is
   implemented and tested.

# Implementation Conventions

* Route injectable subprocess work through `ProcessRunner`.
* Use explicit UDIDs for every Simulator operation; never select by display name.
* Keep machine-consumable stdout stable and send diagnostics to stderr. Preserve
  ordinary child streams under `simlease run`.
* Include command, exit status, and useful stderr in checked Simulator errors.
* Treat failed or malformed discovery as failure, not an empty inventory.
* Use monotonic time for lock deadlines and wall time for persisted diagnostics.
* Keep lock files persistent, close descriptors to release, and use
  close-on-exec unless inheritance is an intentional tested design.
* Persist session transitions before relying on them for recovery. Turn cleanup
  failures into quarantine, never silent success or reuse.
* Sort imports alphabetically and keep source compatibility changes deliberate.

# Registry and Recovery Changes

When changing persistence or recovery:

1. Define the lifecycle and compatibility meaning of every field.
2. Increment schema only when older readers cannot safely consume the data.
3. Test old decoding, round trips, unsupported newer schemas, corruption, and
   persistence failure boundaries.
4. Never interpret `missing` or `cannot decode` as proof that a simulator is
   unowned.
5. Keep live locks authoritative and lockless session records delete-only.
6. Preserve failure details until successful cleanup removes the record.

The create-before-publication gap is documented, not solved: do not add a broad
scan that deletes `🔒` simulators without durable evidence of SimLease ownership.

# Simulator Lifecycle Changes

Classify each operation as one of:

* **Discovery** - Validate process status and structured output.
* **Ownership transition** - Hold the appropriate global or per-UDID lock and
  persist the transition where recovery requires it.
* **Session operation** - Run while the exact UDID's lock is held.
* **Cleanup** - Check the result, retain retry state, and quarantine on failure.
* **Presentation** - Rename and focus may be nonessential, but their outcome
  cannot stand in for ownership.

Use a real Simulator only in an explicitly scoped integration check. Create a
unique disposable device, retain its exact UDID, and clean or quarantine only
that device.

# Review Checklist

Before merging a locking, session, or recovery change, verify:

* TTL, wall-clock movement, worktree deletion, and registry state cannot
  displace a live kernel owner.
* No path unlinks a lock file that another process could have opened.
* Same-worktree sessions remain independent.
* The child starts only after boot readiness.
* Setup, child, signal, cleanup, and persistence failures have deterministic
  state and observable diagnostics.
* Abandoned session devices remain delete-only.
* New crash paths appear in the [failure matrix](testing-strategy.md).
* README, bundled skill, and docs do not apply `run` guarantees to legacy claims.

# Documentation Maintenance

`Docs/index.md` is the progressive-disclosure index and has no frontmatter.
Every other Markdown document in `Docs` requires OKF frontmatter with a nonempty
`type`. Update the relevant concept and the
[decision log](roadmap-and-decisions.md) when an invariant, delivery status, or
accepted choice changes.
