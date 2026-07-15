---
type: Roadmap
title: Session Safety Roadmap and Decision Log
description: Records delivery order, accepted architecture choices, future proposals, and unresolved session details.
tags: [roadmap, decisions, sessions, reliability]
timestamp: 2026-07-15T00:00:00Z
status: active
---

# Status Vocabulary

* **Implemented baseline** - Present at commit `7df4924` and described in
  [current architecture](current-architecture.md).
* **Accepted target** - Settled behavior required for the first safe session
  runner, but not implemented at the baseline.
* **Future proposal** - Deliberately deferred until the accepted target is proven.
* **Open detail** - Requires a focused decision without changing accepted safety
  invariants.

# Delivery Roadmap

| Stage | Status at baseline | Deliverable | Exit criteria |
|---|---|---|---|
| 0. Cooperative leases | Implemented baseline | `claim`, `renew`, `release`, registry UI, TTL GC. | Existing behavior remains accurately documented and tested. |
| 1. Reliability foundation | Accepted target | Kernel-backed global lock and strict checked `simctl` discovery/lifecycle APIs. | Cross-process kill/timeout tests and failed-command tests pass. |
| 2. Foreground sessions | Accepted target | `simlease run [options] -- <command...>` with one unique disposable simulator per run. | Per-UDID lock spans create-to-cleanup, readiness precedes child launch, environment contract passes, same-worktree runs are independent. |
| 3. Recovery and observability | Accepted target | Durable session phases, quarantine, delete-only abandoned-session reconciliation, status/app presentation. | Active locks override TTL; registry corruption and every partial-operation boundary fail safely. |
| 4. Brokered sessions | Future proposal | Daemon or Unix-domain-socket broker for safe ownership across unrelated invocations. | Separate design review after foreground sessions are stable. |
| 5. Warm performance | Future proposal | Templates, cloning, or other startup optimization. | Demonstrably preserves disposable isolation and all safety invariants. |

# Decision Log

## 2026-07-15 - Foreground `run` is the safe workflow primitive

**Accepted target.** The initial session API is `simlease run [options] --
<command...>`. It supervises the complete lifecycle in one process. A `with`
alias is optional, not required.

Reason: one supervisor can retain kernel ownership across boot, arbitrary child
work, and cleanup without relying on environment persistence between shells.

## 2026-07-15 - Every run uses a unique disposable simulator

**Accepted target.** Runs do not reuse a warm simulator and do not share by
worktree. They create, boot, use, shut down, and delete one simulator.

Reason: disposable state removes ambiguity around installed apps, settings,
partial cleanup, sticky worktree ownership, and concurrent sessions in one tree.

## 2026-07-15 - Kernel lock is ownership authority

**Accepted target.** A per-UDID Darwin `flock` is held for the session. Registry,
TTL, labels, names, workdirs, and process metadata support visibility and recovery
but cannot displace a live lock.

Reason: age-based lock stealing can revoke a slow live owner. Kernel ownership is
released automatically when its descriptor closes or process exits.

## 2026-07-15 - Keep the global lock short

**Accepted target.** A kernel-backed global control lock protects selection and
registry transitions. The per-UDID lock, not the global lock, spans the workflow.

Reason: independent sessions should run concurrently on separate simulators.

## 2026-07-15 - Never unlink kernel lock files

**Accepted target.** Release closes the descriptor and leaves the regular lock
file in place.

Reason: unlinking permits one process to retain a lock on an old inode while a
second process locks a new inode at the same path.

## 2026-07-15 - Cleanup failures quarantine

**Accepted target.** Failed shutdown, deletion, persistence, or interrupted
sessions remain quarantined and delete-only. They are never reallocated.

Reason: preserving capacity is less important than preventing simultaneous or
state-contaminated use.

## 2026-07-15 - Simulator failures are explicit

**Accepted target.** Session-critical commands validate exit status and
structured output. Boot includes readiness waiting. Cleanup success is reported
only after checked cleanup succeeds.

Reason: tool failure must not be reinterpreted as an empty inventory or a
successful release.

## 2026-07-15 - Legacy claims remain a separate safety class

**Accepted documentation rule.** While `claim`, `renew`, and `release` remain,
they are described as cooperative leases. Documentation must not apply `run`
guarantees to them.

# Open Details

The following may be decided during implementation without weakening the target:

* whether ArgumentParser can expose `with` as a clean alias;
* precedence when both the child and cleanup fail, while still reporting both;
* signal-forwarding and bounded child-termination policy;
* quarantine retention, retry schedule, and human override commands;
* exact registry schema and migration mechanics for session phases;
* how the menubar app distinguishes active, abandoned, cleaning, and quarantined
  sessions; and
* compatibility and eventual deprecation policy for sticky legacy claims.

# Completion Gate

Do not mark the session architecture implemented until:

1. All invariants in [target session architecture](session-architecture.md) are
   enforced by code.
2. Applicable rows in the [failure matrix](testing-strategy.md) pass, including
   independent subprocess and real disposable-Simulator coverage.
3. README and agent skill examples prefer `simlease run` without overstating
   legacy safety.
4. Quarantine and recovery behavior is visible and actionable.
5. The complete suite passes from a clean worktree.
