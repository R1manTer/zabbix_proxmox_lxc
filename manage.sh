#!/usr/bin/env bash
# =============================================================
#  Zabbix 7.0 LTS — Deploy & Maintenance Script
#  Всі виправлення включено
# =============================================================
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env_all"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
source "${ENV_FILE}"

check_deps() {
  for cmd in docker curl python3; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
  done
  docker compose version &>/dev/null || { echo "ERROR: Docker Compose V2 not found"; exit 1; }
}

create_dirs() {
  echo "→ Creating data directories..."
  mkdir -p \
    db_data \
    zbx_data/alertscripts \
    zbx_data/externalscripts \
    zbx_data/export \
    zbx_data/modules \
    zbx_data/enc \
    zbx_data/ssh_keys \
    zbx_data/mibs \
    zbx_data/snmptraps \
    zbx_data/ssl/nginx \
    backups
  echo "  ✓ Directories ready"
}

cmd_deploy() {
  check_deps
  create_dirs
  echo "→ Pulling images (platform: linux/amd64)..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull
  echo "→ Starting services..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d

  echo "→ Waiting for PostgreSQL (up to 120s)..."
  for i in $(seq 1 24); do
    if docker exec zabbix-postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; then
      echo "  ✓ PostgreSQL ready"
      break
    fi
    echo "  ... attempt $i/24"
    sleep 5
  done

  echo "→ Waiting for Zabbix Server to initialize (90s)..."
  sleep 90

  echo "→ Applying DB tuning..."
  cmd_db_tune

  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  Zabbix 7.0 LTS deployed!                        ║"
  echo "║  Web UI: http://$(hostname -I | awk '{print $1}'):8080       ║"
  echo "║  Login:  Admin / zabbix  ← ЗМІНІТЬ ПАРОЛЬ!       ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "  Після входу:"
  echo "  1. Змініть пароль Admin"
  echo "  2. Administration → Housekeeping → увімкніть і встановіть частоту 1h"
  echo "  3. Перевірте Monitoring → Hosts → Zabbix server (ZBX має бути зелений)"
}

cmd_db_tune() {
  echo "→ Applying init_tuning.sql..."
  docker exec -i zabbix-postgres \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" < init_tuning.sql
  docker exec zabbix-server zabbix_server -R config_cache_reload 2>/dev/null || true
  echo "  ✓ DB tuning applied"
}

cmd_start() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" start
  echo "✓ Services started"
}

cmd_stop() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" stop
  echo "✓ Services stopped"
}

cmd_status() {
  echo "=== Container Status ==="
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps
  echo ""
  echo "=== Memory Usage ==="
  docker stats --no-stream \
    zabbix-postgres zabbix-server zabbix-web zabbix-agent \
    --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}" 2>/dev/null || true
  echo ""
  echo "=== Host Free Memory ==="
  free -h
}

cmd_backup() {
  mkdir -p "${BACKUP_DIR}"
  BACKUP_FILE="${BACKUP_DIR}/zabbix_${TIMESTAMP}.dump"
  echo "→ Dumping PostgreSQL → ${BACKUP_FILE}..."
  docker exec zabbix-postgres \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -Fc --compress=9 > "${BACKUP_FILE}"
  echo "  ✓ $(du -sh "${BACKUP_FILE}" | cut -f1)"
  ls -t "${BACKUP_DIR}"/zabbix_*.dump 2>/dev/null | tail -n +8 | xargs -r rm --
}

cmd_logs() {
  SVC="${2:-}"
  case "$SVC" in
    server)   docker logs -f zabbix-server ;;
    web)      docker logs -f zabbix-web ;;
    postgres) docker logs -f zabbix-postgres ;;
    agent)    docker logs -f zabbix-agent ;;
    *)        docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" logs -f --tail=50 ;;
  esac
}

cmd_update() {
  echo "→ Pulling latest images..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull
  echo "→ Recreating containers (--no-deps per service to avoid cascade)..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d --remove-orphans
  echo "✓ Update complete"
}

COMMAND="${1:-help}"
case "$COMMAND" in
  deploy)   cmd_deploy ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  db-tune)  cmd_db_tune ;;
  backup)   cmd_backup ;;
  logs)     cmd_logs "$@" ;;
  update)   cmd_update ;;
  *)
    echo "Usage: $0 {deploy|start|stop|status|db-tune|backup|logs [svc]|update}"
    ;;
esac
