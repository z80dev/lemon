SELECT event_id, occurred_at, kind, payload
FROM events
WHERE tenant_id = :tenant_id
  AND date(occurred_at) BETWEEN date(:start_at) AND date(:end_at)
ORDER BY occurred_at DESC
LIMIT :limit;
