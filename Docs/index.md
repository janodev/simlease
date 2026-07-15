# SimLease Knowledge Bundle

* [Current architecture and limitations](current-architecture.md) - Implemented behavior at the documented baseline, including concurrency and recovery limits.
* [Target session architecture](session-architecture.md) - Accepted design for workflow-wide isolation through `simlease run`; not implemented at the baseline.
* [Development workflow](development-workflow.md) - Repository map, change discipline, validation commands, and review checklist.
* [Testing strategy and failure matrix](testing-strategy.md) - Required unit, subprocess, CLI, fault-injection, and Simulator coverage.
* [Roadmap and decision log](roadmap-and-decisions.md) - Delivery order, accepted decisions, future work, and unresolved details.

# Suggested Reading Order

* Start with [current architecture](current-architecture.md) before changing existing allocation or cleanup behavior.
* Read [target session architecture](session-architecture.md) before implementing `simlease run`, locking, lifecycle, or recovery work.
* Use the [development workflow](development-workflow.md) and [testing strategy](testing-strategy.md) together while making changes.
* Check the [roadmap and decision log](roadmap-and-decisions.md) before reopening a settled design choice.
