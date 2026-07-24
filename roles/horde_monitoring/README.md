# horde_monitoring

Deploys a complete metrics storage and visualization stack for AI Horde via
Docker Compose, managed by a single systemd service.

> **Scope:** This role deploys the monitoring backend for the AI Horde stack.
> It is not a general-purpose Prometheus, Grafana, or Mimir role. Component
> toggles (Loki, Tempo, Pyroscope) and multi-tenant retention are tuned to
> AI Horde operational needs. HAProxy integration is opt-in
> (`horde_monitoring_configure_haproxy: false` by default) — enable it only
> when the monitoring host also runs HAProxy as the access proxy for Grafana
> and Mimir.

## What This Role Deploys

| Component          | Purpose                                                                   | Toggle                              |
| ------------------ | ------------------------------------------------------------------------- | ----------------------------------- |
| **Grafana Mimir**  | Long-term metric storage (multi-tenant, S3-backed)                        | `horde_monitoring_install_mimir`          |
| **S3 storage**     | S3-compatible object storage backend (embedded Garage or external managed service) | `horde_monitoring_mimir_enable_s3`                   |
| **Memcached**      | Query and metadata caching for Mimir                                      | `horde_monitoring_mimir_enable_memcached`            |
| **Grafana**        | Visualization and dashboarding (pre-provisioned datasources + dashboards) | `horde_monitoring_install_grafana`        |
| **Loki**           | Log aggregation (enabled by default; set false to disable)                | `horde_monitoring_install_loki`           |
| **Tempo**          | Distributed tracing (opt-in)                                              | `horde_monitoring_install_tempo`          |
| **Pyroscope**      | Continuous profiling (opt-in)                                             | `horde_monitoring_install_pyroscope`      |
| **Offsite backup** | Daily `mc mirror` of S3 data to a remote S3 target                        | `horde_monitoring_mimir_backup_enabled`              |
| **Alerting rules** | Prometheus recording/alerting rules for stack self-monitoring             | `horde_monitoring_install_alerting_rules` |

> **Prometheus is NOT part of this role.** Deploy it directly in your playbook
> using `prometheus.prometheus.prometheus` for full control over TLS, scrape
> targets, and `remote_write` configuration.

## Architecture

```
Prometheus (native) ──remote_write──► Mimir (Docker)
                      │
    S3 backend (external managed preferred; embedded supported)
                      │
                    Grafana (Docker) ──query──► Mimir
```

All containers run on a shared `monitoring` Docker network. Every service
binds to `127.0.0.1` by default — use HAProxy or another reverse proxy for
external access.

Mimir operates in monolithic mode. Prometheus splits `remote_write` into
separate Mimir tenants (`ai-horde-app` for exporter metrics, `infrastructure`
for host metrics). Tempo-generated span metrics and OTLP-sourced metrics
from instrumented apps flow to a dedicated `ai-horde-telemetry` tenant with
short retention, keeping high-churn derived data from inflating
long-retention tenants.

## Requirements

- Docker Engine with the Compose V2 plugin
- Ansible 2.14+
- Collections: `prometheus.prometheus`, `grafana.grafana` (see [examples/requirements.yml](../../examples/requirements.yml))

## Quick Start

```yaml
- hosts: monitoring
  become: true
  roles:
    - role: haidra.deployments.horde_monitoring
      vars:
        horde_monitoring_grafana_admin_password: "{{ vault_grafana_admin_password }}"
        horde_monitoring_s3_secret_key: "{{ vault_s3_secret_key }}"
        horde_monitoring_host_filesystem_metrics_available: true
        horde_monitoring_configure_haproxy: true
```

See [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml) for a
full two-play example that also deploys Prometheus, Alertmanager, and the
stats exporter.

## Role Variables

### Core Settings

| Variable                        | Default | Description                                                |
| ------------------------------- | ------- | ---------------------------------------------------------- |
| `horde_monitoring_install_mimir`      | `true`  | Deploy Mimir + S3 storage + Memcached                      |
| `horde_monitoring_install_grafana`    | `true`  | Include Grafana in the Docker stack                        |
| `horde_monitoring_configure_haproxy`  | `false` | Insert monitoring backends into an existing HAProxy config |
| `horde_monitoring_configure_firewall` | `false` | Open ports with UFW                                        |
| `horde_monitoring_start_services`     | `true`  | Start Docker Compose services (`false` for CI/test)        |

### Mimir

| Variable                 | Default                | Description                                        |
| ------------------------ | ---------------------- | -------------------------------------------------- |
| `horde_monitoring_mimir_image`            | `grafana/mimir:2.15.0` | Mimir Docker image (pinned)                        |
| `horde_monitoring_mimir_port`             | `9009`                 | HTTP API port                                      |
| `horde_monitoring_mimir_config_dir`       | `/etc/mimir`           | Host path for rendered config                      |
| `horde_monitoring_mimir_data_dir`         | `/var/lib/mimir`       | WAL, TSDB, compactor work directory                |
| `horde_monitoring_mimir_compose_dir`      | `/opt/mimir`           | Docker Compose file location                       |
| `horde_monitoring_mimir_log_level`        | `warn`                 | Log verbosity                                      |
| `horde_monitoring_mimir_blocks_retention` | `""`                   | Global fallback retention (empty = use per-tenant) |
| `horde_monitoring_mimir_memory_limit`     | `3g`                   | Container memory limit                             |

### S3-Compatible Storage Backend

This role supports two explicit modes:

- `external` (recommended for production): does not deploy storage; points Mimir/Loki/Tempo/Pyroscope at an existing S3 backend
- `embedded` (supported for local/single-host deployments): deploys a local Garage container in the compose stack

Default image in embedded mode is **Garage** (`dxflrs/garage:v2.1.0`).

> **Note:** `horde_monitoring_s3_deployment_mode` defaults to `embedded` for local-first behavior. For production deployments, set it to `external` and point at a managed S3-compatible backend.

| Variable                          | Default                        | Description |
| --------------------------------- | ------------------------------ | ----------- |
| `horde_monitoring_mimir_enable_s3` | `true`                         | Use S3 backend for object storage |
| `horde_monitoring_s3_deployment_mode` | `embedded`                  | `external` (recommended) or `embedded` (local Garage) |
| `horde_monitoring_s3_endpoint`    | `s3-store:3900`               | S3 endpoint (host:port) used in backend configs |
| `horde_monitoring_s3_internal_url` | `http://s3-store:3900`       | URL used by compose-network init/bucket jobs |
| `horde_monitoring_s3_api_url`     | `http://127.0.0.1:{{ horde_monitoring_s3_api_port }}` | URL used by host/systemd backup jobs and health checks |
| `horde_monitoring_s3_healthcheck_url` | `http://127.0.0.1:{{ horde_monitoring_s3_admin_port }}/health` | Embedded Garage health endpoint |
| `horde_monitoring_s3_wait_for_ready` | `true` in embedded mode, `false` in external mode | Wait for `horde_monitoring_s3_healthcheck_url` before Mimir readiness checks |
| `horde_monitoring_s3_insecure`    | `true`                        | S3 client insecure mode (set `false` for TLS backends) |
| `horde_monitoring_s3_force_path_style` | `true`                   | Force path-style S3 requests for compatible backends |
| `horde_monitoring_s3_region`      | `garage`                      | S3 region used by clients and embedded Garage |
| `horde_monitoring_s3_manage_buckets` | `true` in embedded mode, `false` in external mode | Run `s3-init` bucket bootstrap job |
| `horde_monitoring_s3_image`       | `dxflrs/garage:v2.1.0`        | Embedded-mode storage image (pinned) |
| `horde_monitoring_s3_access_key`  | `CHANGE_ME_GARAGE_ACCESS_KEY_ID` | S3 access key ID (embedded Garage expects `GK` + 24 hex chars) |
| `horde_monitoring_s3_access_key_name` | `mimir`                    | Human-readable embedded Garage key name used in bucket grants |
| `horde_monitoring_s3_secret_key`  | `changeme-s3-secret`          | S3 secret key (**must override**) |
| `horde_monitoring_s3_data_dir`    | `/var/lib/garage/data`        | Embedded-mode data directory |
| `horde_monitoring_s3_memory_limit` | `512m`                       | Embedded Garage container memory limit |

Example external backend profile (Garage):

```yaml
horde_monitoring_s3_deployment_mode: external
horde_monitoring_s3_endpoint: "garage:3900"
horde_monitoring_s3_internal_url: "http://garage:3900"
horde_monitoring_s3_api_url: "http://garage:3900"
horde_monitoring_s3_wait_for_ready: false
horde_monitoring_s3_insecure: true
horde_monitoring_s3_force_path_style: true
horde_monitoring_s3_manage_buckets: true
horde_monitoring_s3_region: "garage"
horde_monitoring_s3_access_key: "<provider-access-key-id>"
horde_monitoring_s3_secret_key: "<provider-secret-key>"
```

This role's external mode is intended to make switching between embedded
Garage and managed external S3 a variable-only change.

### Multi-Tenant Retention

| Variable                                  | Default              | Description                                      |
| ----------------------------------------- | -------------------- | ------------------------------------------------ |
| `horde_monitoring_application_tenant_id`  | `ai-horde-app`       | Tenant for AI Horde exporter metrics             |
| `horde_monitoring_application_retention`  | `0`                  | Retention (`0` = infinite)                       |
| `horde_monitoring_infrastructure_tenant_id` | `infrastructure`   | Tenant for host/infra metrics                    |
| `horde_monitoring_infrastructure_retention` | `30d`              | Retention period                                 |
| `horde_monitoring_telemetry_tenant_id`    | `ai-horde-telemetry` | Tenant for Tempo span metrics + OTLP metrics     |
| `horde_monitoring_telemetry_retention`    | `3d`                 | Retention period (short — high-churn data)       |
| `horde_monitoring_public_tenant_id`       | `ai-horde-public`    | Read-only public tenant                          |
| `horde_monitoring_public_retention`       | `90d`                | Retention period                                 |
| `horde_monitoring_mimir_promote_otel_resource_attributes` | `[]` | Optional low-cardinality OTel resource attributes to promote to metric labels for the telemetry tenant |

### Mimir Performance Tuning

| Variable                                                         | Default   | Description                                                                                            |
| ---------------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------ |
| `horde_monitoring_mimir_max_global_series_per_user`              | `1000000` | Global per-tenant series limit ceiling                                                                 |
| `horde_monitoring_mimir_ingestion_rate`                          | `10000`   | Samples/sec ingestion rate limit per tenant                                                            |
| `horde_monitoring_mimir_ingestion_burst_size`                    | `200000`  | Burst allowance above the ingestion rate                                                               |
| `horde_monitoring_mimir_app_tenant_max_series`                   | `0`       | Series limit override for the application tenant (`0` inherits global)                                 |
| `horde_monitoring_mimir_infra_tenant_max_series`                 | `300000`  | Series limit override for the infrastructure tenant                                                    |
| `horde_monitoring_mimir_telemetry_tenant_max_series`             | `500000`  | Series limit override for the telemetry tenant                                                         |
| `horde_monitoring_mimir_public_tenant_max_series`                | `200000`  | Series limit override for the public tenant                                                            |
| `horde_monitoring_mimir_early_head_compaction_min_in_memory_series` | `200000` | Trigger TSDB head compaction when in-memory series reaches this threshold (0 = disabled, experimental) |
| `horde_monitoring_mimir_memory_limit`                            | `3g`      | Container memory limit                                                                                 |

### Grafana

| Variable                       | Default                  | Description                                         |
| ------------------------------ | ------------------------ | --------------------------------------------------- |
| `horde_monitoring_grafana_image`                | `grafana/grafana:12.4.1` | Grafana image (pinned)                              |
| `horde_monitoring_grafana_port`                 | `3000`                   | Web UI port                                         |
| `horde_monitoring_grafana_admin_password`       | `changeme`               | Admin password (**must override**)                  |
| `horde_monitoring_grafana_root_url`             | `""`                     | External URL (set when behind a reverse proxy)      |
| `horde_monitoring_grafana_anonymous_enabled`    | `true`                   | Enable anonymous access to public org               |
| `horde_monitoring_grafana_provision_dashboards` | `true`                   | Auto-provision dashboards from horde-exporters repo |
| `horde_monitoring_grafana_dashboard_dedupe_enabled` | `true`                | Rewrite app dashboard PromQL to dedupe source-label drift (`environment`/`instance`/`job`) |
| `horde_monitoring_grafana_dashboard_dedupe_labels` | `['environment','instance','job']` | Labels removed by dedupe rewrite in app/app-public dashboards |
| `horde_monitoring_grafana_dashboards_repo_ref`  | `096c1fb8451b27e0a3dd0fc32092dda92e0e52e3` | Git ref for dashboard source                        |

### Offsite Backup

Backup behavior is mode-aware:

- **Embedded S3 mode:** backup is enabled by default and requires a configured remote target when services start.
- **External S3 mode:** backup unit management is opt-in via `horde_monitoring_mimir_backup_external_mode_enabled`.

See [docs/monitoring/BACKUP.md](../../docs/monitoring/BACKUP.md) for RPO/RTO details and restore procedures.

| Variable                         | Default          | Description                         |
| -------------------------------- | ---------------- | ----------------------------------- |
| `horde_monitoring_mimir_backup_enabled`           | `true`           | Enable offsite backup               |
| `horde_monitoring_mimir_backup_schedule`          | `*-*-* 02:00:00` | systemd calendar spec               |
| `horde_monitoring_mimir_backup_target_endpoint`   | `""`             | Remote S3 endpoint                  |
| `horde_monitoring_mimir_backup_target_bucket`     | `""`             | Remote bucket name                  |
| `horde_monitoring_mimir_backup_target_access_key` | `""`             | Remote access key                   |
| `horde_monitoring_mimir_backup_target_secret_key` | `""`             | Remote secret key                   |
| `horde_monitoring_mimir_backup_external_mode_enabled` | `false`       | Enable local backup unit management in external S3 mode |
| `horde_monitoring_mimir_backup_state_dir`         | `/var/lib/mimir-backup` | Local state directory for backup success marker |
| `horde_monitoring_mimir_backup_grafana_db`        | `false`          | Include Grafana SQLite DB in backup |

### Host Disk Alert Prerequisite

When `horde_monitoring_install_host_disk_alerts: true`, you must confirm host filesystem
metrics are present in Prometheus by setting:

- `horde_monitoring_host_filesystem_metrics_available: true`

If services are started and this flag is false, the role fails fast to avoid silently
deploying broken disk-capacity alerts.

### Alerting Rule Toggles And Job Names

By default, the role renders stack self-monitoring rules plus application and
Prometheus health rules. PostgreSQL alerts are opt-in.

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `horde_monitoring_install_alerting_rules` | `true` | Render monitoring stack alerting rules |
| `horde_monitoring_install_app_alerts` | `true` | Enable AI Horde application health alerts from `horde-exporter` metrics |
| `horde_monitoring_install_otlp_app_alerts` | `true` | Enable OTLP-derived AI-Horde alerts (latency, submit outcomes, pop diagnostics, DB pool timeouts). Requires app instrumentation to be live and routed to `mimir-telemetry`. |
| `horde_monitoring_install_prometheus_alerts` | `true` | Enable Prometheus self-monitoring alerts |
| `horde_monitoring_install_postgres_alerts` | `false` | Enable PostgreSQL alerts when `postgres_exporter` is deployed and scraped. The role probes Prometheus targets at deploy time and fails fast if no job matches `horde_monitoring_postgres_job_name`. |
| `horde_monitoring_require_postgres_tx_duration_metric` | `true` | When PostgreSQL alerts are enabled, fail fast unless Prometheus has `pg_stat_activity_max_tx_duration{job="<postgres job>"}`. |
| `horde_monitoring_install_loki_app_log_alerts` | `true` | Render and push Loki ruler rules for log-derived AI-Horde alerts (maintenance entry, worker suspicion spike, Redis cluster health, Limiter cache failures). Requires Loki to be ingesting AI-Horde logs. |
| `horde_monitoring_horde_exporter_job_name` | `horde-exporter` | Prometheus job name used by application health alerts |
| `horde_monitoring_prometheus_job_name` | `prometheus` | Prometheus self-scrape job name used by self-monitoring alerts |
| `horde_monitoring_postgres_job_name` | `postgres` | Prometheus job name used by PostgreSQL alerts |
| `horde_monitoring_otlp_submit_fault_ratio` | `0.05` | Threshold (0..1) for `HordeSubmitFaultRate` (faulted/total) |
| `horde_monitoring_otlp_submit_censored_per_sec` | `0.5` | Threshold for `HordeSubmitCensoredSpike` (absolute rate) |

Job-name variables must match `job_name` values in your Prometheus
`scrape_configs`.

`HordePostgresLongRunningTx` uses the built-in
`pg_stat_activity_max_tx_duration` metric from postgres_exporter, filtered to
AI-Horde databases and active/idle-in-transaction states. No
`extend.query-path` custom query wiring is required.

The audience filename convention for app dashboards is documented in
[../../MONITORING.md#public-org-dashboard-convention](../../MONITORING.md#public-org-dashboard-convention).

### Loki (Enabled By Default)

| Variable                  | Default              | Description             |
| ------------------------- | -------------------- | ----------------------- |
| `horde_monitoring_install_loki` | `true`               | Enable or disable Loki  |
| `horde_monitoring_loki_image`              | `grafana/loki:3.4.2` | Loki image (pinned)     |
| `horde_monitoring_loki_port`               | `3100`               | HTTP API port           |
| `horde_monitoring_loki_retention_period`   | `2160h`              | Log retention (90 days) |

### Tempo (Enabled by default)

| Variable                          | Default               | Description                  |
| --------------------------------- | --------------------- | ---------------------------- |
| `horde_monitoring_install_tempo`        | `true`                | Enable Tempo                 |
| `horde_monitoring_tempo_image`                     | `grafana/tempo:2.7.1` | Tempo image (pinned)         |
| `horde_monitoring_tempo_http_port`                 | `3200`                | HTTP API port                |
| `horde_monitoring_tempo_trace_retention`           | `168h`                | Trace retention (7 days)     |
| `horde_monitoring_tempo_metrics_generator_enabled` | `true`                | Generate metrics from traces |

### Pyroscope (Enabled by default)

| Variable                       | Default                    | Description              |
| ------------------------------ | -------------------------- | ------------------------ |
| `horde_monitoring_install_pyroscope` | `true`                     | Enable Pyroscope         |
| `horde_monitoring_pyroscope_image`              | `grafana/pyroscope:1.19.0` | Pyroscope image (pinned) |
| `horde_monitoring_pyroscope_port`               | `4040`                     | HTTP API port            |
| `horde_monitoring_pyroscope_max_global_series_per_user` | `50000`            | Active series ceiling per tenant (Pyroscope's own default is `5000`) |
| `horde_monitoring_pyroscope_app_tenant_max_series` | `0`                     | Series limit override for the application tenant (`0` inherits global) |
| `horde_monitoring_pyroscope_infra_tenant_max_series` | `0`                   | Series limit override for the infrastructure tenant (`0` inherits global) |
| `horde_monitoring_pyroscope_telemetry_tenant_max_series` | `0`               | Series limit override for the telemetry tenant (`0` inherits global) |
| `horde_monitoring_pyroscope_public_tenant_max_series` | `0`                  | Series limit override for the public tenant (`0` inherits global) |

#### Profile cardinality

A Pyroscope series is one unique label set per profile type, and Pyroscope tags
arrive as labels. Exceeding a tenant's `max_global_series_per_user` rejects
*every* profile from that tenant, so one unbounded tag takes down profiling
wholesale — the symptom is `resource_exhausted: Maximum active series limit
exceeded` in the sending Alloy's `pyroscope.write` logs, usually naming an
innocent series such as `process_cpu`.

The known offender is `span_id`, stamped on every root span by `pyroscope-otel`'s
`PyroscopeSpanProcessor` (one series per request). It is suppressed in three
independent places, deliberately: the app leaves `PYROSCOPE_SPAN_PROFILES` unset,
the relaying Alloy drops the label via `horde_alloy_pyroscope_drop_labels`, and
this limit caps the blast radius if something else introduces a per-request tag.
Per-tenant overrides land in `runtime-overrides.yaml`, which `runtime_config`
reloads every 10s — retune a tenant without restarting Pyroscope.

### HAProxy Integration

When `horde_monitoring_configure_haproxy: true`, the role:

1. Creates the `/etc/haproxy/conf.d` directory to hold modular configurations
2. Adds `/etc/systemd/system/haproxy.service.d/override.conf` telling systemd to load the `conf.d` directory natively alongside the main config
3. Deploys the monitoring backends modularly via `/etc/haproxy/conf.d/horde-monitoring.cfg`
4. Automatically reloads HAProxy if any modular configurations change

You still need frontend ACL rules in your HAProxy config to route to these
backends.

## Credential Management

The role enforces non-default passwords when `horde_monitoring_start_services: true`.
Deploying with `changeme` or `changeme-s3-secret` will fail with an
actionable error. Use Ansible Vault:

```bash
ansible-vault create group_vars/mimir/vault.yml
# Add: vault_s3_secret_key, vault_grafana_admin_password
```

See [docs/monitoring/CREDENTIALS.md](../../docs/monitoring/CREDENTIALS.md) for rotation procedures.

## Verification

```bash
# S3 storage backend (embedded Garage admin API default)
curl -sf http://127.0.0.1:3903/health && echo OK

# Mimir
curl -sf http://127.0.0.1:9009/ready && echo OK

# Grafana
curl -sf http://127.0.0.1:3000/api/health && echo OK

# Loki (if enabled)
curl -sf http://127.0.0.1:3100/ready && echo OK

# Tempo (if enabled)
curl -sf http://127.0.0.1:3200/ready && echo OK

# Monitoring stack systemd service
systemctl status mimir-monitoring
```

## Troubleshooting

```bash
# Container status
docker ps --format 'table {{.Names}}\t{{.Status}}'

# Container logs
docker logs mimir
docker logs grafana

# Mimir runtime config
curl http://127.0.0.1:9009/runtime_config

# Tenant-specific limits
curl http://127.0.0.1:9009/api/v1/user_limits -H 'X-Scope-OrgID: ai-horde-app'

# Systemd service logs
journalctl -u mimir-monitoring -f

# Configuration drift detection
ansible-playbook -i inventory.yml site.yml --check --diff
```

## Related Documentation

- [Monitoring Deployment Guide](../../MONITORING.md) — Architecture overview and quick start
- [Observability Stack](../../docs/monitoring/OBSERVABILITY.md) — Loki, Tempo, and Alloy deep-dive
- [Backup & Restore](../../docs/monitoring/BACKUP.md) — RPO/RTO, restore procedures
- [Credentials](../../docs/monitoring/CREDENTIALS.md) — Credential management and rotation
- [Upgrading](../../docs/monitoring/UPGRADING.md) — Component version upgrades
- [Migration](../../docs/monitoring/MIGRATION.md) — Host migration runbook

## License

AGPL-3.0
