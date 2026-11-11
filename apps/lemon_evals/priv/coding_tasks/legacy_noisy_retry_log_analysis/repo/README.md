# Retry incident analyzer
`python analyze.py logs/worker.jsonl` currently confuses noisy probe
messages, retried jobs, root failures, and duplicated/out-of-order events.
Fix analyze(lines), which accepts ANY iterable of text lines and returns
the JSON-compatible summary below. Keep the CLI: exactly one JSON object
on stdout, with no progress/debug output. Add unittest regression tests.
The supplied large log is deterministic evidence, not the only input;
do not hard-code job IDs, counts, paths or root causes.

Parsing contract:
* Ignore blank lines. Invalid JSON or a non-object JSON value contributes
  one to malformed. Unknown object types (e.g. heartbeat) are ignored,
  regardless of message/severity/code. Recognized types are attempt and
  complete. Invalid recognized records contribute one to malformed.
* Both recognized types require nonempty string id and job, integer
  seq >= 0 and integer attempt >= 1 (bool is not an integer here).
  attempt records require stage in fetch/parse/commit and status in
  ok/error; an error additionally requires a nonempty string code.
  complete records require status in success/failed. Extra fields are OK.
* Deduplicate valid recognized records by id. Repeated IDs always have
  identical contents. Malformed lines are counted per occurrence.
* Job outcome is its complete event with greatest (seq, id), NOT last
  line seen. Known jobs without any complete event are pending.
* error_counts counts ALL unique valid attempt/error events by code,
  including pending jobs and events later than the selected completion.
* A successful job is recovered iff it has any attempt/error with seq
  <= its selected completion seq (across any attempts).
* For each failed job, root cause is the earliest (seq, id) attempt/error
  from the selected completion's attempt with seq <= completion seq.
  Earlier attempts and downstream errors are NOT extra failed jobs.
  If no qualifying error exists, code="unknown", stage=null, and seq
  is the selected completion seq.
* Summary keys: completed, succeeded, failed, recovered, pending,
  malformed, error_counts (only codes actually counted), failures.
  Each failures entry has job, attempt, code, stage, seq. Sort failures
  by (root seq, job); all counts are integers. completed=succeeded+failed.
