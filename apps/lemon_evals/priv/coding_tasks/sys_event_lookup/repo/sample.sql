INSERT INTO events VALUES
 (1, 10, '2025-03-10T09:00:00Z', 'login', '{"user":"Ada"}', NULL),
 (2, 10, '2025-03-10T12:30:00Z', 'purchase', '{"cents":500}', NULL),
 (3, 10, '2025-03-10T12:30:00Z', 'logout', NULL, NULL),
 (4, 10, '2025-03-10T13:00:00Z', 'login', 'deleted', '2025-03-11T00:00:00Z'),
 (5, 20, '2025-03-10T12:00:00Z', 'login', 'other tenant', NULL),
 (6, 10, '2025-03-11T00:00:00Z', 'login', 'next day', NULL);
