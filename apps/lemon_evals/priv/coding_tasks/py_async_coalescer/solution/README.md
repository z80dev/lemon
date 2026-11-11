# Flights

`Coalescer.run(key, factory)` collapses overlapping upstream reads by key.
Factories take no arguments and return awaitables. Different keys run
independently; the result is not cached. `pending_count` counts unfinished work.

## Task ownership

The flight registry owns each shared task until completion. Each caller awaits
it through a cancellation shield: cancelling callers, including every caller,
does not cancel upstream work. Later callers may still join that work.
Completion evicts the flight; success, asynchronous failure, synchronous factory
failure, and factory cancellation all permit retry. Orphaned failures are
retrieved to avoid unhandled-task warnings. Use each instance on one event loop.

Run deterministic event-based visible tests:

    python3 -m unittest discover -s tests -v
