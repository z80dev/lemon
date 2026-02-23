---
id: IDEA-20260224-oh-my-pi-job-delivery-acknowledgment
title: Job delivery acknowledgment mechanism for async jobs
source: oh-my-pi
source_commit: 35cf65bc
discovered: 2026-02-24
status: proposed
---

# Description

Oh-My-Pi added a mechanism to suppress future delivery attempts for acknowledged jobs. The AwaitTool acknowledges deliveries for jobs it finished awaiting, preventing unnecessary retries and clearing the delivery queue for handled jobs.

Key features:
- Job delivery acknowledgment mechanism
- AwaitTool acknowledges deliveries for completed jobs
- Prevents unnecessary retries
- Clears delivery queue for handled jobs

# Lemon Status

- Current state: Lemon has basic outbox delivery acknowledgment mentioned in code
- Gap: No comprehensive job delivery acknowledgment system
- Location: `apps/lemon_channels/lib/lemon_channels/outbound_payload.ex` (basic mention)

# Investigation Notes

- Complexity estimate: M
- Value estimate: M
- Open questions:
  - How does Lemon currently handle async job delivery retries?
  - Is there a job manager that tracks delivery state?
  - How does this relate to the existing await tool?

# Recommendation

**investigating** - Need to understand current async job handling in Lemon before determining if this is needed.

# References

- Oh-My-Pi commit: 35cf65bc27383f8505ca08a3b6cbf76391155891
