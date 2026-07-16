# SimLease Knowledge Bundle

* [Current architecture and limitations](current-architecture.md) - Implemented Simulator sessions, macOS UI exclusion, legacy leases, ownership authority, persistence, and recovery boundaries.
* [Improvements over the original version](original-version-improvements.md) - Side-by-side summary of the shift from cooperative leases to crash-safe foreground sessions.
* [Session architecture](session-architecture.md) - The implemented `simlease run` lifecycle, safety invariants, failure behavior, and known gaps.
* [Exclusive macOS UI automation](macos-ui-lock.md) - Host-wide locking contract for deterministic desktop UI testing across agents.
* [Development workflow](development-workflow.md) - Repository map, change discipline, validation commands, and review checklist.
* [Testing strategy and failure matrix](testing-strategy.md) - Current evidence, remaining coverage gaps, and rules for real Simulator tests.
* [Roadmap and decision log](roadmap-and-decisions.md) - Delivery status, settled choices, remaining recovery work, and future proposals.

# Suggested Reading Order

* Start with [current architecture](current-architecture.md) to choose between safe foreground sessions and cooperative legacy leases.
* Use [improvements over the original version](original-version-improvements.md) for historical context and a concise capability comparison.
* Read [session architecture](session-architecture.md) before changing locking, lifecycle, signal, cleanup, or recovery behavior.
* Use [exclusive macOS UI automation](macos-ui-lock.md) before running focus-sensitive macOS UI tests from multiple agents.
* Use the [development workflow](development-workflow.md) and [testing strategy](testing-strategy.md) together while making changes.
* Check the [roadmap and decision log](roadmap-and-decisions.md) before reopening a settled design choice.
