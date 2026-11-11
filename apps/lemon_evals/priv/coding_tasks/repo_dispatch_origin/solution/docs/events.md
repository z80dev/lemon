# Event import format

An event has Account, DispatchID, Kind, Hub, At, Sequence. At is a time.Time;
Sequence is unique within a dispatch. Accepted is a handoff into the network,
moved is a subsequent scan, and audit is metadata. Imports may arrive out of
order, including an accepted scan imported after later scans. Account and
DispatchID together identify the owning stream. Replay must not mutate rows.

Origin reconstruction selects the minimum (At instant, Sequence) among accepted
rows. Latest location selects the maximum tuple among accepted and moved rows.
Neither selection depends on import order, and the adapter creates a fresh
checkpoint value for every lookup. Audit-only streams have no origin/location.
