-- =============================================================
--  Zabbix 7.0 LTS — Post-Deploy DB & Housekeeping Tuning
--  Run ONCE after first successful start:
--    docker exec -i zabbix-postgres psql -U zabbix -d zabbix < init_tuning.sql
-- =============================================================

-- ── 1. Retention policy ──────────────────────────────────────
-- History: 30 days (2592000 sec), Trends: 730 days (63072000 sec)
UPDATE config SET
  hk_history_global = 1,
  hk_history        = 30,
  hk_trends_global  = 1,
  hk_trends         = 730,
  hk_events_mode    = 1,
  hk_events_trigger = 365,
  hk_events_internal= 90,
  hk_events_discovery = 7,
  hk_events_autoreg   = 7,
  hk_services_mode    = 1,
  hk_services         = 365,
  hk_audit_mode       = 1,
  hk_audit            = 90,
  hk_sessions_mode    = 1,
  hk_sessions         = 30,
  hk_history_mode     = 1,
  hk_trends_mode      = 1
WHERE configid = 1;

-- ── 2. Housekeeping settings ─────────────────────────────────
UPDATE config SET
  housekeeping_frequency = 1,
  max_housekeeper_delete = 5000
WHERE configid = 1;

-- ── 3. Monitoring intervals — Critical hosts (10s) ───────────
-- Apply to hosts tagged as critical.
-- The SQL below is a template; adjust hostid values as needed.
-- UPDATE items SET delay = 10 WHERE hostid IN (
--   SELECT hostid FROM hosts WHERE name IN ('core-switch-01','fw-01')
-- ) AND key_ LIKE 'icmpping%';

-- ── 4. Default intervals — Standard hosts (30s) ──────────────
-- UPDATE items SET delay = 30 WHERE key_ LIKE 'icmpping%';

-- ── 5. Disable unused value types to shrink history tables ───
-- Java JMX items
UPDATE items SET status = 1
WHERE type = 16
  AND status = 0;

-- VMware collector items
UPDATE items SET status = 1
WHERE type = 13
  AND status = 0;

-- ── 6. PostgreSQL stats views (useful for monitoring DB health)
-- Verify config was applied
SELECT
  hk_history,
  hk_trends,
  housekeeping_frequency,
  max_housekeeper_delete
FROM config
WHERE configid = 1;
