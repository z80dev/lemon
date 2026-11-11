# Telemetry window

`WindowIndex` tracks count and integer sum per telemetry key over the interval
`(now - windowMs, now]`. Producers append in timestamp order; idle consumers may
advance the clock without appending. Queries return independent result records.

The optional visit observer measures work on buffered events, not elapsed time.
It must observe all expiry candidates and event scans; new insertions and moving
buffer references are excluded. Querying aggregate state does not visit events.

Use Node 22 and `node --test test/*.test.js`.
