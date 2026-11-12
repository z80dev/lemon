DROP INDEX IF EXISTS events_live_lookup;
CREATE INDEX events_live_lookup
ON events(tenant_id, occurred_at DESC, event_id DESC)
WHERE deleted_at IS NULL;
