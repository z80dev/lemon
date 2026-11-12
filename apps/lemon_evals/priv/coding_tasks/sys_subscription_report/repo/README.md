# Regional subscription snapshot

Finance needs one reproducible snapshot rather than a sum of subscription
history. Fix `subscription_report.sql`, which the caller executes as one SELECT
with the named parameter `:as_of`. Keep the public schema and file names intact.
`schema.sql` defines accounts, current plan prices, and account subscription
state-change events. `sample.sql` demonstrates a pause/reactivation tie.

## Snapshot rules

* `:as_of` is a valid canonical `YYYY-MM-DD` date. `effective_on` uses the same
  format and is a whole calendar date, not a timestamp. Include that entire day:
  events are eligible when `effective_on <= :as_of`.
* For each account, first discard future events, then choose the eligible event
  with greatest `effective_on`. Ties on the same date use greatest `event_id`.
  IDs are unique but need not increase with effective date or insertion order.
* That event supplies state, seats, and plan. An account without eligible history
  is not active. Only state `active` contributes to active-account count, seat
  count, and monthly recurring revenue. `paused` and `cancelled` contribute zero,
  even when they retain positive seats and an expensive plan.
* Revenue is the chosen event's seats times its plan's CURRENT
  `monthly_price_cents` from plans, not a historical rate, and not prorated.
  Active accounts with zero seats or a free plan still count as active.
* Every account counts in its region's account_count, even if it has no events
  or only future events. Regions with no active accounts have integer zero
  active_accounts, active_seats, and mrr_cents (not NULL). With no accounts,
  return no rows, even if plans exist.
* Normalize NULL regions to the literal `Unassigned`. That bucket merges with
  accounts whose actual region text is `Unassigned`. Empty-string regions are
  a separate bucket; preserve all other region text exactly, including case.

Return exactly these columns in this order, with these names:
`region, account_count, active_accounts, active_seats, mrr_cents`.
Return one row per normalized region ordered by `region COLLATE BINARY ASC`.
The four aggregates are integers. All monetary values are cents, seats and
prices are nonnegative integers, and inputs/totals fit signed 64-bit integers.
All event references are valid. There is one subscription state per account;
there is no additional subscription-ID grouping or event-type filter.

## Local workflow

```
sqlite3 subscriptions.db < schema.sql
sqlite3 subscriptions.db < sample.sql
python3 -m unittest discover -s tests -v
```
The tests use the SQLite CLI for schema/sample installation and Python sqlite3
named-parameter binding for report execution. No third-party packages or network
services are needed. Window functions are available, but no particular query
implementation is required.
