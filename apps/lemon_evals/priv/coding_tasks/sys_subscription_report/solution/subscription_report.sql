WITH ranked AS (
    SELECT account_id, state, plan_id, seats,
           row_number() OVER (
               PARTITION BY account_id
               ORDER BY effective_on DESC, event_id DESC
           ) AS position
    FROM subscription_events
    WHERE effective_on <= :as_of
), current_state AS (
    SELECT account_id, state, plan_id, seats
    FROM ranked
    WHERE position = 1
)
SELECT coalesce(a.region, 'Unassigned') AS region,
       count(*) AS account_count,
       sum(CASE WHEN e.state = 'active' THEN 1 ELSE 0 END) AS active_accounts,
       sum(CASE WHEN e.state = 'active' THEN e.seats ELSE 0 END) AS active_seats,
       sum(CASE WHEN e.state = 'active' THEN e.seats * p.monthly_price_cents ELSE 0 END) AS mrr_cents
FROM accounts a
LEFT JOIN current_state e ON e.account_id = a.account_id
LEFT JOIN plans p ON p.plan_id = e.plan_id
GROUP BY coalesce(a.region, 'Unassigned')
ORDER BY region COLLATE BINARY ASC;
