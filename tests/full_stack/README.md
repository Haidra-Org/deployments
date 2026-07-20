# Full-stack local deploy — load-test rig

This directory drives the complete local Horde business stack via
[`local_deploy.sh`](local_deploy.sh): the AI-Horde API behind HAProxy, the
frontpage, model-reference, service-alerts, and (optionally) the full
monitoring stack. Ordinary usage is documented in the top-level
[QUICKSTART.md](../../QUICKSTART.md) and [MONITORING.md](../../MONITORING.md).

This README covers **load-test mode** (`--loadtest`): a production-shaped
substrate for aiming a load generator (e.g. the AI-Horde repo's
`tests/stress/` locust harness) at a realistic multi-instance edge. Scenario
and load generation are a separate workstream — this mode only stands up the
target.

## What load-test mode adds

`up --loadtest` layers production shape onto the normal local stack. Nothing
below is active without the flag; a plain `up` is unchanged.

- **N app instances behind HAProxy** (default 4, `-n`/`--instances`), each
  running 25 waitress threads with `SQLALCHEMY_POOL_SIZE=25` /
  `SQLALCHEMY_MAX_OVERFLOW=15`, mirroring the prod app tier.
- **A dedicated quorum instance** (`aihorde-quorum`, published on `:7300`)
  running `--quorum --reload_all_caches`. It holds the background-job quorum
  and runs the shared-DB maintenance off the worker-serving pool. Because it
  has a distinct compose service name it is **absent from the `aihorde`
  Docker-DNS record HAProxy resolves**, so it is excluded from rotation.
- **A prod-shaped HAProxy edge** rendered from
  [`templates/haproxy.loadtest.cfg.j2`](templates/haproxy.loadtest.cfg.j2):
  the same worker/client backend split as the default edge, plus `leastconn`,
  a server pool sized from `N` (+ headroom), per-server `maxconn`, a bounded
  `timeout queue`, priority classes favouring generative pop/submit over
  status polling, and a 1s micro-cache on status/check. The default-mode edge
  (`local-deploy/static/haproxy/haproxy.cfg`) is untouched and still used by a
  plain `up`.
- **Prod-mirrored embedded postgres (pg15)**:
  `shared_preload_libraries=auto_explain,pg_stat_statements,pg_cron`,
  `log_lock_waits=on`, configurable `log_min_duration_statement` (default
  1000ms), `auto_explain` active, `autovacuum_vacuum_scale_factor=0.05`,
  `work_mem=16MB`, `max_connections=500` (all configurable, see below).
- **postgres_exporter** on the tuned DB, scraped by Prometheus under
  `job="postgres"` and surfaced in Grafana, with the monitoring role's
  postgres alert rules enabled.
- **Monitoring forced on** (needed for the exporter + Mimir); the app pushes
  OTLP to Alloy → Mimir as it does in the normal `--with-monitoring` path.

The AI-Horde stats-compile procedures and their every-minute pg_cron schedule
install themselves at app boot (the local stack boots with `TESTING` unset).
Their production cost comes from table volume, which an empty DB never
reproduces — use the **seeder** to populate it.

## Usage

```bash
# Stand up the rig (4 instances + quorum + prod edge + tuned pg + monitoring)
./tests/full_stack/local_deploy.sh up --loadtest

# Different instance count
./tests/full_stack/local_deploy.sh up --loadtest -n 8

# Populate gen-stats so the compile pg_cron jobs have real volume to scan
# (default 5M image + 2M text rows; run AFTER the stack is up)
./tests/full_stack/local_deploy.sh seed
./tests/full_stack/local_deploy.sh seed --images 2000000 --text 1000000

# Tear everything down
./tests/full_stack/local_deploy.sh down
```

### Endpoints

| Service           | URL                                   |
|-------------------|---------------------------------------|
| Edge (HAProxy)    | `http://localhost/`                   |
| API via edge      | `http://localhost/api/v2/status/heartbeat` |
| HAProxy stats     | `http://localhost:8404/stats`         |
| App instances     | `http://localhost:7001..700N`         |
| Quorum instance   | `http://localhost:7300` (out of rotation) |
| postgres_exporter | `http://localhost:9187/metrics`       |
| Grafana           | `http://localhost:3000/`              |
| Prometheus        | `http://localhost:9090/`              |
| Mimir             | `http://localhost:9009/`              |

Point the load generator at `http://localhost/` (the edge), not the direct
instance ports.

## Parameters

Instance count is a script flag; the rest are ansible extra-vars passed with
`-e` (they flow through to the render). Examples:

```bash
# 6 instances, keep only 4 months of log noise, smaller pool
./tests/full_stack/local_deploy.sh up --loadtest -n 6 \
  -e loadtest_pg_log_min_duration_ms=500 \
  -e loadtest_pg_max_connections=300
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-n N` / `--instances=N` | 4 (loadtest) | App instances behind HAProxy |
| `loadtest_pg_log_min_duration_ms` | 1000 | postgres `log_min_duration_statement` |
| `loadtest_pg_max_connections` | 500 | postgres `max_connections` |
| `loadtest_pg_work_mem` | 16MB | postgres `work_mem` |
| `loadtest_haproxy_maxconn_per_server` | 35 | per-server `maxconn` at the edge |
| `loadtest_haproxy_server_headroom` | 4 | extra idle server-template slots above N |
| `loadtest_haproxy_timeout_queue` | 30s | edge `timeout queue` |
| `seed --images N` | 5000000 | image_gen_stats rows to seed |
| `seed --text N` | 2000000 | text_gen_stats rows to seed |
| `seed --batch B` | 500000 | rows per insert batch |

## Verifying the rig

```bash
# All N instances + quorum healthy, quorum excluded from the edge:
curl -s localhost:8404/stats | grep -o 'horde_client_api,aihorde[0-9]*'   # rotation members
curl -s localhost:7300/api/v2/status/heartbeat                            # quorum reachable

# pg_cron schedule + compile jobs running:
docker exec aihorde-postgres psql -U aihorde -d aihorde \
  -c "SELECT jobname, schedule FROM cron.job;" \
  -c "SELECT command, status FROM cron.job_run_details ORDER BY end_time DESC LIMIT 5;"

# postgres_exporter scraped:
curl -s 'http://localhost:9090/api/v1/targets?state=active' | grep -o '"job":"postgres"'

# Compile cost grows with volume (run before and after `seed`):
docker exec aihorde-postgres psql -U aihorde -d aihorde \
  -c "\timing on" -c "CALL compile_imagegen_stats_totals();"
```

## Teardown

`./tests/full_stack/local_deploy.sh down` stops and removes every tier
(including the quorum instance and postgres_exporter) and the shared
`horde-stack` network. The embedded postgres data directory under
`local-deploy/runtime/ai-horde/data/postgres` persists across runs; remove it
manually to reset seeded volume.
