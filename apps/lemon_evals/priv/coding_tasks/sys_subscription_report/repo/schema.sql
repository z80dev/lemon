PRAGMA foreign_keys = ON;
CREATE TABLE accounts (
    account_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    region TEXT
);
CREATE TABLE plans (
    plan_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    monthly_price_cents INTEGER NOT NULL CHECK (monthly_price_cents >= 0)
);
CREATE TABLE subscription_events (
    event_id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL REFERENCES accounts(account_id),
    effective_on TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'paused', 'cancelled')),
    plan_id INTEGER NOT NULL REFERENCES plans(plan_id),
    seats INTEGER NOT NULL CHECK (seats >= 0)
);
