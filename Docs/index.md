# SimLease Knowledge Bundle

* [Current architecture and limitations](current-architecture.md) - Implemented foreground sessions, legacy leases, ownership authority, persistence, and recovery boundaries.
* [Session architecture](session-architecture.md) - The implemented `simlease run` lifecycle, safety invariants, failure behavior, and known gaps.
* [Development workflow](development-workflow.md) - Repository map, change discipline, validation commands, and review checklist.
* [Testing strategy and failure matrix](testing-strategy.md) - Current evidence, remaining coverage gaps, and rules for real Simulator tests.
* [Roadmap and decision log](roadmap-and-decisions.md) - Delivery status, settled choices, remaining recovery work, and future proposals.

# Suggested Reading Order

* Start with [current architecture](current-architecture.md) to choose between safe foreground sessions and cooperative legacy leases.
* Read [session architecture](session-architecture.md) before changing locking, lifecycle, signal, cleanup, or recovery behavior.
* Use the [development workflow](development-workflow.md) and [testing strategy](testing-strategy.md) together while making changes.
* Check the [roadmap and decision log](roadmap-and-decisions.md) before reopening a settled design choice.
