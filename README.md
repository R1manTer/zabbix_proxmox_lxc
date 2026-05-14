# Zabbix 7.0 LTS — Deployment Guide
**Target:** 500 devices | 4 GB RAM | Large disk array

---

## Quick Start

```bash
chmod +x manage.sh
./manage.sh deploy
```

Web UI opens at `http://<server-ip>:8080` — default login: `Admin / zabbix`.

---

## File Structure

```
zabbix-deploy/
├── .env_all              ← All environment variables
├── docker-compose.yml    ← Service definitions + resource limits
├── init_tuning.sql       ← DB retention & housekeeping SQL
├── manage.sh             ← Deploy/backup/status helper
├── db_data/              ← PostgreSQL data (mount to large disk)
└── zbx_data/             ← Zabbix scripts, certs, MIBs
```

---

## RAM Budget (4 GB total)

| Component      | Limit  | Typical Usage |
|----------------|--------|---------------|
| PostgreSQL 15  | 1.5 GB | ~800 MB       |
| Zabbix Server  | 512 MB | ~300 MB       |
| Zabbix Web     | 256 MB | ~150 MB       |
| Zabbix Agent   | 64 MB  | ~30 MB        |
| **Docker/OS**  | ~700 MB | reserved     |
| **Total**      | **~3.1 GB** | safe margin |

---

## Key Tuning Decisions

### ICMP Pingers
`ZBX_STARTPINGERS=25` — each pinger handles ~20 hosts/cycle.  
At 500 hosts with 15–20s intervals, 25 pingers provide headroom.

### Disabled modules (RAM savings)
- `ZBX_STARTJAVAPOLLERS=0` — no Java/JMX monitoring
- `ZBX_STARTVMWARECOLLECTORS=0` — no VMware vSphere polling
- `ZBX_STARTIPMIPOLLERS=0` — no IPMI/hardware sensors

Re-enable in `.env_all` if needed later.

### PostgreSQL (`postgres:15-alpine`)
| Parameter | Value | Reason |
|-----------|-------|--------|
| `shared_buffers` | 512 MB | ~33% of DB RAM limit |
| `work_mem` | 16 MB | safe for max_connections=100 |
| `effective_cache_size` | 1 GB | tells planner about OS cache |
| `wal_buffers` | 16 MB | reduces WAL flush overhead |

### Retention policy (applied by `init_tuning.sql`)
| Data type | Retention |
|-----------|-----------|
| History (raw values) | 30 days |
| Trends (hourly aggregates) | 730 days (2 years) |
| Events/Triggers | 365 days |
| Audit log | 90 days |

---

## Host Monitoring Configuration

### Critical hosts (10s interval)
In Zabbix UI: `Configuration → Hosts → [host] → Items`  
Filter by `icmpping` → set Update interval to `10s`.  
Or create a Host Group "Critical" and assign a template with 10s intervals.

### Standard hosts (30s interval)
Default template interval. Assign `Template Module ICMP Ping` to all hosts.

### Recommended ICMP template items
| Item | Key | Interval |
|------|-----|----------|
| ICMP ping | `icmpping` | 30s / 10s |
| ICMP ping loss | `icmppingloss` | 60s |
| ICMP response time | `icmppingsec` | 60s |

---

## Operational Commands

```bash
./manage.sh status          # RAM usage per container
./manage.sh logs server     # Zabbix Server logs
./manage.sh logs postgres   # PostgreSQL logs
./manage.sh backup          # Dump DB → ./backups/ (keeps last 7)
./manage.sh update          # Pull new images and recreate
./manage.sh db-tune         # Re-apply init_tuning.sql
```

---

## Storage Notes

- `./db_data` — mount this to your large disk array.  
  With 500 hosts, 30-day history, and 730-day trends: expect **~50–150 GB** depending on item count per host.
- `./zbx_data/export` — scheduled report exports, grows slowly.
- Run `./manage.sh backup` via cron daily:

```cron
0 3 * * * /path/to/zabbix-deploy/manage.sh backup >> /var/log/zabbix-backup.log 2>&1
```

---

## Troubleshooting

**Server won't start — DB not ready**
```bash
docker logs zabbix-postgres --tail 30
docker logs zabbix-server --tail 50
```

**High RAM on PostgreSQL**
Check `shared_buffers` is not exceeding available memory:
```bash
docker exec zabbix-postgres psql -U zabbix -d zabbix \
  -c "SHOW shared_buffers; SHOW work_mem;"
```

**Pinger queue growing**
Increase `ZBX_STARTPINGERS` in `.env_all` and restart:
```bash
docker compose --env-file .env_all restart zabbix-server
```

**Check internal Zabbix queue**
`Administration → Queue` in the Web UI.
