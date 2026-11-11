SELECT event_id, occurred_at, kind, payload
FROM events
WHERE tenant_id = :tenant_id
  AND deleted_at IS NULL
  AND occurred_at >= :start_at
  AND occurred_at < :end_at
ORDER BY occurred_at DESC, event_id DESC
LIMIT :limit;
