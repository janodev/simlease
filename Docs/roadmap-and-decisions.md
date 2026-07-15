---
type: Roadmap
title: Session Safety Roadmap and Decision Log
description: Records implemented session milestones, remaining recovery work, future proposals, and settled safety choices.
tags: [roadmap, decisions, sessions, reliability]
timestamp: 2026-07-15T00:00:00Z
status: active
---

# Status Vocabulary

* **Implemented** - Present in source and covered at an appropriate current test
  layer.
* **Partial** - Useful behavior is implemented, but a named architecture,
  recovery, UI, or evidence gap remains.
* **Future proposal** - Deliberately deferred until the foreground lifecycle is
  stable.

# Delivery Roadmap

| Stage | Status | Deliverable | Remaining exit work |
|---|---|---|---|
| 0. Cooperative leases | Implemented compatibility | `claim`, `renew`, `release`, status, focus, registry UI, and TTL GC. | Keep documented as a lower-safety cooperative model. |
| 1. Reliability foundation | Implemented | Kernel-backed global/per-device locks and strict checked `simctl` APIs. | Add focused close-on-exec inheritance evidence. |
| 2. Foreground sessions | Implemented | `simlease run` and `with`, one disposable simulator per run, boot readiness, child environment, signals, and checked cleanup. | Add concurrent executable-level and automated real-Simulator coverage. |
| 3. Recovery and observability | Partial | Session phases, quarantine, delete-only abandoned-session GC, fail-closed corruption, status/error presentation, and cleanup retry in the app. | Close the create-before-registry window and add per-UDID cancellation and recovery controls. |
| 4. Brokered sessions | Future proposal | Daemon or Unix-domain-socket broker for safe reconnectable ownership across invocations. | Separate design review after foreground recovery is complete. |
| 5. Warm performance | Future proposal | Templates, cloning, or another startup optimization. | Prove disposable isolation and every safety invariant remain intact. |

# Decision Log

## 2026-07-15 - Foreground `run` is the safe workflow primitive

**Implemented.** `simlease run [options] -- <command...>` supervises the whole
lifecycle in one process; `simlease with` is an equivalent alias.

Reason: one supervisor can retain kernel ownership across boot, arbitrary child
work, and cleanup without trusting environment state between invocations.

## 2026-07-15 - Every run uses a unique disposable simulator

**Implemented.** Runs do not reuse warm devices and do not share by worktree.

Reason: disposable state removes ambiguity around installed apps, settings,
partial cleanup, sticky ownership, and same-tree concurrency.

## 2026-07-15 - Kernel lock is ownership authority

**Implemented.** A per-UDID Darwin `flock` spans a published session. Registry,
TTL, names, labels, and workdirs support visibility and recovery but cannot
displace it.

Reason: kernel ownership is not vulnerable to age-based stale-lock theft and is
released automatically when the descriptor or supervisor exits.

## 2026-07-15 - Keep the global lock short

**Partially implemented.** Foreground boot, child work, final shutdown, and final
deletion run outside the global lock. Legacy cleanup and abandoned-session
reconciliation still perform Simulator commands while holding it.

Reason: independent sessions should proceed concurrently on different devices.
A focused test verifies that cleanup can acquire an independent registry-lock
probe while foreground final shutdown runs. Reconciliation needs a separate
per-UDID cleanup transaction before the global-lock rule is complete.

## 2026-07-15 - Never unlink kernel lock files

**Implemented.** Release closes the descriptor and leaves the lock file in
place.

Reason: unlinking can create two lockable inodes for one logical path.

## 2026-07-15 - Cleanup failures quarantine

**Implemented.** Failed cleanup retains lifecycle metadata and makes the device
delete-only. A later reconciliation can retry deletion.

Reason: preserving simulator capacity is less important than preventing shared
or state-contaminated use.

## 2026-07-15 - Registry corruption fails closed

**Implemented.** Existing unreadable paths and undecodable data block lifecycle
mutation. Corrupt bytes are retained and copied for diagnosis.

Reason: losing the ownership view must not make recorded devices appear free.

## 2026-07-15 - Schema 2 fences session ownership from v1

**Implemented.** Schema-1 registries load and migrate on the next save. Every
new write uses schema 2, which v1 readers reject. The fence takes v1's
directory-compatible barrier only for the migration write; normal v2 work uses
a separate persistent `registry.lock` flock that v1 cannot unlink.

Reason: v1 does not decode session lifecycle fields or probe per-UDID locks. It
must fail closed before it can treat a live foreground session as an expired
cooperative lease.

The migration barrier deliberately does not copy v1's age-based lock stealing.
A held directory causes a timeout and fail-closed recovery because an old but
live v1 transaction may still save a schema-1 snapshot.

## 2026-07-15 - Catchable signals are forwarded without escalation

**Implemented with a known limit.** `SIGINT` and `SIGTERM` are forwarded to the
child; the supervisor waits, cleans, and returns a signal-derived status.

Reason: graceful child handling preserves cleanup today. A bounded grace period
and escalation policy require a separate decision because forced termination can
lose child-side evidence.

## 2026-07-15 - Legacy claims remain a separate safety class

**Implemented documentation rule.** `claim`, `renew`, and `release` remain
cooperative and never inherit `run` guarantees.

# Next Recovery Work

1. Persist creation intent before `simctl create`, or design a conservative
   reconciliation token that can identify only SimLease-owned orphans.
2. Add executable-level concurrent session and close-on-exec inheritance tests.
3. Automate a real disposable-Simulator smoke test behind an explicit opt-in.
4. Add per-UDID cancellation, forced recovery, and cleanup history beyond the
   menubar app's current error display and global-GC retry.
5. Decide a grace deadline and escalation sequence for signal-ignoring children.
6. Move legacy and abandoned-session reconciliation commands outside the global
   registry lock while preserving delete-only ownership.

# Future Decisions

The following remain intentionally open:

* broker lifecycle, authentication, stale-client detection, and reconnect rules;
* registry schema evolution for a pre-create intent journal;
* retention and human override policy for repeatedly failing quarantine cleanup;
* compatibility and eventual deprecation policy for sticky legacy claims; and
* warm-device optimization only after recovery evidence is complete.

Use the [testing matrix](testing-strategy.md) as the evidence gate for moving a
stage from partial to implemented.
