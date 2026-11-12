SELECT a.region AS region,
       count(*) AS account_count,
       sum(e.state = 'active') AS active_accounts,
       sum(e.seats) AS active_seats,
       sum(e.seats * p.monthly_price_cents) AS mrr_cents
FROM accounts a
JOIN subscription_events e ON e.account_id = a.account_id
JOIN plans p ON p.plan_id = e.plan_id
WHERE e.effective_on <= :as_of
GROUP BY a.region
ORDER BY a.region;
