CREATE TABLE events (
    event_id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL,
    occurred_at TEXT NOT NULL,
    kind TEXT NOT NULL,
    payload TEXT,
    deleted_at TEXT
);
