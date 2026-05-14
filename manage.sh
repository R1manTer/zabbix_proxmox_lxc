#!/usr/bin/env bash
# =============================================================
#  Zabbix 7.0 LTS — Deploy & Maintenance Script
#  Usage:
#    ./manage.sh deploy        — first-time deploy
#    ./manage.sh start         — start all services
#    ./manage.sh stop          — stop all services
#    ./manage.sh status        — show container + RAM status
#    ./manage.sh db-tune       — apply init_tuning.sql
#    ./manage.sh backup        — dump PostgreSQL to ./backups/
#    ./manage.sh logs [svc]    — tail logs (svc: server|web|postgres)
#    ./manage.sh update        — pull new images and recreate
# =============================================================
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env_all"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Source env for DB creds
# shellcheck disable=SC1090
source "${ENV_FILE}"

check_deps() {
  for cmd in docker curl; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
  done
  docker compose version &>/dev/null || { echo "ERROR: Docker Compose V2 not found"; exit 1; }
}

create_dirs() {
  echo "→ Creating data directories on large disk..."
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
  echo "→ Pulling images..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull
  echo "→ Starting services..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d
  echo ""
  echo "→ Waiting for PostgreSQL to be healthy (up to 90s)..."
  for i in $(seq 1 18); do
    if docker exec zabbix-postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; then
      echo "  ✓ PostgreSQL is ready"
      break
    fi
    echo "  ... attempt $i/18"
    sleep 5
  done
  echo ""
  echo "→ Waiting for Zabbix Server to initialize (60s)..."
  sleep 60
  echo ""
  echo "→ Applying DB tuning & housekeeping settings..."
  cmd_db_tune
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  Zabbix 7.0 LTS deployed successfully!           ║"
  echo "║  Web UI:  http://$(hostname -I | awk '{print $1}'):8080  ║"
  echo "║  Default: Admin / zabbix                         ║"
  echo "╚══════════════════════════════════════════════════╝"
}

cmd_start() {
  check_deps
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
    --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null || true
  echo ""
  echo "=== Host Free Memory ==="
  free -h
}

cmd_db_tune() {
  echo "→ Applying init_tuning.sql..."
  docker exec -i zabbix-postgres \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" < init_tuning.sql
  echo "  ✓ DB tuning applied"
}

cmd_backup() {
  mkdir -p "${BACKUP_DIR}"
  BACKUP_FILE="${BACKUP_DIR}/zabbix_${TIMESTAMP}.dump"
  echo "→ Dumping PostgreSQL to ${BACKUP_FILE}..."
  docker exec zabbix-postgres \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -Fc --compress=9 > "${BACKUP_FILE}"
  BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
  echo "  ✓ Backup complete: ${BACKUP_FILE} (${BACKUP_SIZE})"
  echo ""
  echo "→ Keeping last 7 backups..."
  ls -t "${BACKUP_DIR}"/zabbix_*.dump 2>/dev/null | tail -n +8 | xargs -r rm --
  echo "  ✓ Old backups pruned"
}

cmd_logs() {
  SVC="${2:-}"
  case "$SVC" in
    server)   docker logs -f zabbix-server ;;
    web)      docker logs -f zabbix-web ;;
    postgres) docker logs -f zabbix-postgres ;;
    agent)    docker logs -f zabbix-agent ;;
    *)        docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" logs -f --tail=100 ;;
  esac
}

cmd_update() {
  echo "→ Pulling latest images..."
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull
  echo "→ Recreating containers..."
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
    exit 1
    ;;
esac
