#!/usr/bin/env bash
# =============================================================
#  Zabbix 7.0 LTS — Load Test Script
#  Всі проблеми враховані:
#    - items створюються окремим item.create (не в host.create)
#    - hostid беруться з БД напряму (не через API search)
#    - токен оновлюється перед кожним API блоком
#    - zabbix_sender використовує -T для timestamp
#    - формат файлу: "hostname key timestamp value"
# =============================================================
set -euo pipefail

ZBX_URL="http://localhost:8080/api_jsonrpc.php"
ZBX_USER="Admin"
ZBX_PASS="zabbix"
HOSTS=500
ITEMS_PER_HOST=10
INTERVAL=5

# ── Кольори для виводу ────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*"; }

# ── Отримати свіжий токен ─────────────────────────────────────
get_token() {
  curl -s -X POST "$ZBX_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",
         \"params\":{\"username\":\"$ZBX_USER\",\"password\":\"$ZBX_PASS\"},
         \"id\":1}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])"
}

# ── Крок 1: Створити тестову групу і хости ────────────────────
cmd_setup() {
  log "Отримуємо токен..."
  TOKEN=$(get_token)
  echo "Token: $TOKEN"

  log "Створюємо групу LoadTest..."
  GROUPID=$(curl -s -X POST "$ZBX_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.create\",
         \"params\":{\"name\":\"LoadTest\"},
         \"auth\":\"$TOKEN\",\"id\":1}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['groupids'][0])")
  echo "GroupID: $GROUPID"

  log "Створюємо $HOSTS хостів..."
  python3 << PYEOF
import urllib.request, json

TOKEN = "$TOKEN"
GROUPID = "$GROUPID"
URL = "$ZBX_URL"
HOSTS = $HOSTS

def api(method, params):
    data = json.dumps({
        "jsonrpc": "2.0", "method": method,
        "params": params, "auth": TOKEN, "id": 1
    }).encode()
    req = urllib.request.Request(URL, data, {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req).read())

created = 0
for i in range(1, HOSTS + 1):
    r = api("host.create", {
        "host": f"test-host-{i:03d}",
        "interfaces": [{"type": 1, "main": 1, "useip": 1,
                        "ip": "127.0.0.1", "dns": "", "port": "10050"}],
        "groups": [{"groupid": GROUPID}]
    })
    if "result" in r:
        created += 1
    if created % 100 == 0:
        print(f"  Хостів створено: {created}/{HOSTS}")

print(f"Готово: {created} хостів")
PYEOF

  log "Отримуємо hostid з БД і створюємо items..."
  sudo docker exec zabbix-postgres psql -U zabbix -d zabbix -t -A -c \
    "SELECT hostid FROM hosts WHERE host LIKE 'test-host-%' AND status != 3" \
    > /tmp/zbx_hostids.txt
  echo "Hostids збережено: $(wc -l < /tmp/zbx_hostids.txt)"

  # Свіжий токен перед масовим створенням items
  TOKEN=$(get_token)

  python3 << PYEOF
import urllib.request, json

TOKEN = "$TOKEN"
URL = "$ZBX_URL"
ITEMS = $ITEMS_PER_HOST

hostids = open("/tmp/zbx_hostids.txt").read().strip().split("\n")
hostids = [h.strip() for h in hostids if h.strip()]
print(f"Хостів для обробки: {len(hostids)}")

def api(method, params):
    data = json.dumps({
        "jsonrpc": "2.0", "method": method,
        "params": params, "auth": TOKEN, "id": 1
    }).encode()
    req = urllib.request.Request(URL, data, {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req).read())

created = 0
errors = 0
for idx, hostid in enumerate(hostids):
    payload = [{
        "hostid": hostid,
        "name": f"Test metric {m}",
        "key_": f"test.metric[{m}]",
        "type": 2,        # trapper
        "value_type": 3,  # numeric unsigned
        "delay": "0"
    } for m in range(1, ITEMS + 1)]

    r = api("item.create", payload)
    if "result" in r:
        created += len(r["result"]["itemids"])
    else:
        errors += 1
        if errors <= 3:
            print(f"  ERROR hostid={hostid}: {r.get('error')}")

    if (idx + 1) % 100 == 0:
        print(f"  {idx+1}/{len(hostids)} хостів | items: {created}")

print(f"\nГотово! Items: {created}, помилок: {errors}")
PYEOF

  log "Перезавантажуємо конфіг кеш..."
  sudo docker exec zabbix-server zabbix_server -R config_cache_reload
  sleep 15

  log "Перевіряємо що items доступні..."
  sudo docker exec zabbix-postgres psql -U zabbix -d zabbix -c \
    "SELECT count(*) as trapper_items FROM items i
     JOIN hosts h ON h.hostid = i.hostid
     WHERE h.host LIKE 'test-host-%' AND i.type = 2;"

  log "Тест підключення одним рядком..."
  sudo docker exec zabbix-server sh -c \
    "echo 'test-host-001 test.metric[1] \$(date +%s) 42' > /tmp/t.txt && \
     zabbix_sender -z zabbix-server -p 10051 -T -i /tmp/t.txt"

  log "Setup завершено! Запустіть: $0 run"
}

# ── Крок 2: Запустити навантажувальний тест ───────────────────
cmd_run() {
  log "Запускаємо навантажувальний тест: $HOSTS хостів × $ITEMS_PER_HOST items = $((HOSTS * ITEMS_PER_HOST)) значень/$INTERVAL сек"
  log "Для зупинки: Ctrl+C"
  log "Паралельно запустіть: watch -n 2 'docker stats --no-stream'"
  echo ""

  CYCLE=0
  while true; do
    CYCLE=$((CYCLE + 1))
    TS=$(date +%s)

    python3 -c "
import random
ts = $TS
hosts = $HOSTS
items = $ITEMS_PER_HOST
for i in range(1, hosts + 1):
    for m in range(1, items + 1):
        print('test-host-{:03d} test.metric[{}] {} {}'.format(i, m, ts, random.randint(1, 1000)))
" > /tmp/zbx_load.txt

    sudo docker cp /tmp/zbx_load.txt zabbix-server:/tmp/zbx_load.txt
    # -T означає що в файлі є колонка timestamp
    sudo docker exec zabbix-server \
      zabbix_sender -z zabbix-server -p 10051 -T -i /tmp/zbx_load.txt

    echo "--- Цикл $CYCLE | $(date) | рядків: $(wc -l < /tmp/zbx_load.txt) ---"
    sleep $INTERVAL
  done
}

# ── Крок 3: Перевірити статистику в БД ───────────────────────
cmd_stats() {
  log "Статистика БД за останні 10 хвилин..."
  sudo docker exec zabbix-postgres psql -U zabbix -d zabbix -c "
SELECT
  round(count(*) / GREATEST(
    extract(epoch from (to_timestamp(max(clock)) - to_timestamp(min(clock)))), 1
  )) AS nvps,
  count(*) AS total_values,
  to_timestamp(min(clock)) AT TIME ZONE 'UTC' AS from_time,
  to_timestamp(max(clock)) AT TIME ZONE 'UTC' AS to_time
FROM history_uint
WHERE clock > extract(epoch from now() - interval '10 minutes')::int;"

  log "Розмір таблиць history..."
  sudo docker exec zabbix-postgres psql -U zabbix -d zabbix -c "
SELECT
  relname AS table,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_catalog.pg_statio_user_tables
WHERE relname LIKE 'history%' OR relname LIKE 'trend%'
ORDER BY pg_total_relation_size(relid) DESC;"
}

# ── Крок 4: Видалити тестові хости ───────────────────────────
cmd_cleanup() {
  log "Видаляємо тестові хости..."
  TOKEN=$(get_token)

  HOSTIDS=$(sudo docker exec zabbix-postgres psql -U zabbix -d zabbix -t -A -c \
    "SELECT hostid FROM hosts WHERE host LIKE 'test-host-%'" \
    | python3 -c "import sys; ids=sys.stdin.read().split(); print(','.join(ids))")

  if [ -z "$HOSTIDS" ]; then
    warn "Тестових хостів не знайдено"
    exit 0
  fi

  COUNT=$(echo "$HOSTIDS" | tr ',' '\n' | wc -l)
  log "Знайдено $COUNT хостів для видалення..."

  curl -s -X POST "$ZBX_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.delete\",
         \"params\":[$HOSTIDS],\"auth\":\"$TOKEN\",\"id\":1}" \
    | python3 -c "
import sys,json
r=json.load(sys.stdin)
if 'result' in r:
    print(f'Видалено: {len(r[\"result\"].get(\"hostids\",[]))} хостів')
else:
    print('ERROR:', r.get('error'))
"

  sudo docker exec zabbix-server zabbix_server -R config_cache_reload
  log "Cleanup завершено"
}

# ── Головне меню ──────────────────────────────────────────────
COMMAND="${1:-help}"
case "$COMMAND" in
  setup)   cmd_setup ;;
  run)     cmd_run ;;
  stats)   cmd_stats ;;
  cleanup) cmd_cleanup ;;
  *)
    echo "Використання: $0 {setup|run|stats|cleanup}"
    echo ""
    echo "  setup   — створити 500 тестових хостів з 10 trapper items кожен"
    echo "  run     — запустити навантажувальний тест (5000 значень кожні 5 сек)"
    echo "  stats   — показати NVPS та розмір таблиць БД"
    echo "  cleanup — видалити всі тестові хости"
    ;;
esac
