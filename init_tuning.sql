-- =============================================================
--  Zabbix 7.0 LTS — Post-Deploy DB & Housekeeping Tuning
--  Run ONCE after first successful start:
--    docker exec -i zabbix-postgres psql -U zabbix -d zabbix < init_tuning.sql
-- =============================================================

-- ── 1. Verify current config columns (Zabbix 7.0 schema) ─────
-- Run this first to see what columns exist:
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'config' ORDER BY column_name;

-- ── 2. Retention policy via housekeeper table ─────────────────
-- In Zabbix 7.0 housekeeping is configured per-item/global via
-- the housekeeper table and Administration > Housekeeping in UI.
-- The config table retains only hk_history/hk_trends globals.

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

-- ── 3. Housekeeping frequency — stored in config_housekeeper ──
-- In Zabbix 7.0 these moved out of config table.
-- Set via UI: Administration → Housekeeping
-- Or directly if the columns exist in your build:
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'config'
      AND column_name = 'housekeeping_frequency'
  ) THEN
    UPDATE config SET
      housekeeping_frequency = 1,
      max_housekeeper_delete = 5000
    WHERE configid = 1;
    RAISE NOTICE 'housekeeping_frequency updated in config';
  ELSE
    RAISE NOTICE 'housekeeping_frequency not in config table (Zabbix 7.0) — set via UI';
  END IF;
END $$;

-- ── 4. Disable unused item types (save history table space) ───
-- Java JMX items (type=16)
UPDATE items SET status = 1
WHERE type = 16 AND status = 0;

-- VMware collector items (type=13)
UPDATE items SET status = 1
WHERE type = 13 AND status = 0;

-- ── 5. Monitoring intervals — Critical hosts (10s) ───────────
-- Template: adjust host names as needed, then uncomment.
-- UPDATE items SET delay = '10s' WHERE hostid IN (
--   SELECT hostid FROM hosts WHERE name IN ('core-switch-01','fw-01')
-- ) AND key_ LIKE 'icmpping%';

-- ── 6. Verify retention was applied ──────────────────────────
SELECT
  hk_history_global,
  hk_history,
  hk_trends_global,
  hk_trends,
  hk_events_mode,
  hk_events_trigger,
  hk_audit_mode,
  hk_audit
FROM config
WHERE configid = 1;
