INSERT INTO plans VALUES (1,'Starter',1000), (2,'Pro',2500), (3,'Community',0);
INSERT INTO accounts VALUES
 (1,'Acme','North'), (2,'Birch','North'), (3,'Cedar','South'),
 (4,'Delta',NULL), (5,'Elm','South');
INSERT INTO subscription_events VALUES
 (101,1,'2025-01-01','active',1,2),
 (102,1,'2025-02-01','paused',2,3),
 (103,1,'2025-02-01','active',2,3),
 (201,2,'2025-01-01','active',1,1),
 (202,2,'2025-02-01','cancelled',1,1),
 (301,3,'2025-03-01','active',2,2),
 (401,4,'2025-02-01','active',3,4);
