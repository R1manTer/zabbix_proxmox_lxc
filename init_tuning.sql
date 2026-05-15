-- =============================================================
--  Zabbix 7.0 LTS — Post-Deploy DB Tuning
--  ФІКСИ:
--    - hk поля типу VARCHAR потребують суфікс 'd' (наприклад '30d')
--    - housekeeping_frequency більше не є колонкою config в 7.0
--  Запуск: ./manage.sh db-tune
-- =============================================================

-- ── 1. Retention policy (VARCHAR поля — обов'язковий суфікс 'd') ──
UPDATE config SET
  hk_history_global    = 1,
  hk_history           = '30d',
  hk_trends_global     = 1,
  hk_trends            = '730d',
  hk_events_mode       = 1,
  hk_events_trigger    = '365d',
  hk_events_internal   = '90d',
  hk_events_discovery  = '7d',
  hk_events_autoreg    = '7d',
  hk_services_mode     = 1,
  hk_services          = '365d',
  hk_audit_mode        = 1,
  hk_audit             = '90d',
  hk_sessions_mode     = 1,
  hk_sessions          = '30d',
  hk_history_mode      = 1,
  hk_trends_mode       = 1
WHERE configid = 1;

-- ── 2. housekeeping_frequency в Zabbix 7.0 — налаштовується через UI ──
-- Administration → Housekeeping → Enable internal housekeeping
-- Frequency: 1 год, Max housekeeper delete: 5000
-- (колонки housekeeping_frequency та max_housekeeper_delete видалено з config)

-- ── 3. Вимкнути невикористовувані items (JMX, VMware) ──
UPDATE items SET status = 1 WHERE type = 16 AND status = 0;
UPDATE items SET status = 1 WHERE type = 13 AND status = 0;

-- ── 4. Виправити інтерфейс агента на Docker DNS ім'я ──
-- (замість 127.0.0.1 використовуємо ім'я контейнера)
UPDATE interface SET
  useip = 0,
  dns   = 'zabbix-agent',
  ip    = ''
WHERE interfaceid = (
  SELECT hi.interfaceid
  FROM hosts h
  JOIN interface hi ON hi.hostid = h.hostid
  WHERE h.host = 'Zabbix server'
  LIMIT 1
);

-- ── 5. Перевірка результату ──
SELECT
  hk_history,
  hk_trends,
  hk_events_trigger,
  hk_audit,
  hk_sessions
FROM config WHERE configid = 1;

SELECT hi.ip, hi.dns, hi.useip, hi.port
FROM hosts h
JOIN interface hi ON hi.hostid = h.hostid
WHERE h.host = 'Zabbix server';
