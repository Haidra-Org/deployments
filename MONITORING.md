# AI Horde Monitoring Deployment Guide

This guide covers the architecture, quick start, and operational reference for
the AI Horde monitoring infrastructure. Each Ansible role has its own README
with full variable documentation — this document focuses on how the pieces
fit together.

## Roles

| Role                                                | Purpose                                                                         | README                                         |
| --------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------- |
| [horde_monitoring](roles/horde_monitoring/)         | Mimir + Grafana + S3 storage + optional Loki/Tempo/Pyroscope via Docker Compose | [README](roles/horde_monitoring/README.md)     |
| [horde_stats_exporter](roles/horde_stats_exporter/) | AI Horde API → Prometheus metrics exporter (Docker Compose)                     | [README](roles/horde_stats_exporter/README.md) |
| [horde_alloy](roles/horde_alloy/)                   | Grafana Alloy telemetry collector on application hosts                          | [README](roles/horde_alloy/README.md)          |

Prometheus and Alertmanager are deployed directly using the
`prometheus.prometheus` community collection in your playbook. They are not
wrapped by these roles, giving you full control over TLS, scrape targets,
and `remote_write` configuration.

## Architecture

```
                                    ┌──── Monitoring Host ──────────────────────────┐
AI Horde APIs                       │                                               │
     │                              │  Prometheus (native)                          │
     ▼                              │    ├─ scrapes horde-exporter, node, mimir …   │
  horde-exporter (Docker)           │    └─ remote_write ──► Mimir (Docker)         │
     │ /metrics                     │                           │                   │
     └────── scraped by ───────────>|              S3 backend (embedded/external)   │
                                    │                            │                  │
                                    │                       Grafana (Docker)        │
                                    │                           │ queries Mimir     │
                                    └───────────────────────────┘───────────────────┘
┌──── App Hosts ───────────┐                                              ▲
│  Grafana Alloy           ├── logs/traces (and optional host metrics) ───┘
└──────────────────────────┘
```

- All services bind to `127.0.0.1` — use HAProxy for external access
- Mimir runs monolithic mode with multi-tenant retention
- Prometheus splits `remote_write` by job into separate tenants
- For production, prefer `horde_monitoring_s3_deployment_mode: external` with a managed S3-compatible backend; embedded Garage remains supported for local/single-host setups

## Quick Start

### 1. Install Dependencies

```bash
ansible-galaxy collection install -r examples/requirements.yml
```

### 2. Deploy the Full Stack

```bash
cp examples/inventory_monitoring.yml inventory.yml
# Edit inventory.yml — set hosts, passwords (use ansible-vault)

ansible-playbook -i inventory.yml examples/horde_monitoring_stack.yml -K
```

This runs a two-play playbook:

- **Play 1**: `node_exporter` on hosts that resolve to `node_exporter` source
- **Play 2**: Mimir + Grafana + Prometheus + Alertmanager + stats exporter
  on the monitoring host

### Host Metrics Source

- `horde_host_metrics_source: auto` (recommended)
  - If a host has `horde_alloy_enabled: true` or `horde_alloy_collect_metrics: true`,
    the playbook skips `node_exporter` on that host.
  - Otherwise, the playbook installs `node_exporter` on that host.
- `horde_host_metrics_source: node_exporter` forces install on all hosts.
- `horde_host_metrics_source: alloy` forces skip on all hosts.

This decision is made per host from inventory variables in Play 1 of
`examples/horde_monitoring_stack.yml`.

When `horde_monitoring_install_host_disk_alerts: true`, ensure Prometheus
ingests `node_filesystem_*` metrics and set
`horde_monitoring_host_filesystem_metrics_available: true`.

### Node Exporter

Node exporter scrape target wiring is automatic:

- `site_monitoring.yml` and `examples/horde_monitoring_stack.yml` generate
  `/etc/prometheus/file_sd/node_exporter.yml` on the monitoring host from
  inventory hosts.
- For the monitoring host itself, generated targets use `127.0.0.1` to avoid
  public-IP hairpin/NAT issues.
- For remote hosts, target address defaults to `ansible_host` and can be
  overridden per host with `horde_node_exporter_scrape_address`.
- Hosts resolved to Alloy metrics (`horde_host_metrics_source: alloy`, or
  `auto` plus Alloy indicators) are excluded from node_exporter discovery.
- Prometheus `job_name: node` consumes these generated file_sd targets.

For Alloy hosts:

- If Alloy endpoints use this same internal CA, set
  `horde_alloy_tls_ca_cert: "tls/ca.crt"`.
- If Alloy talks to HTTP endpoints or public-CA HTTPS endpoints, no additional
  Alloy CA configuration is required.

### 3. Deploy Stats Exporter Only

If you already have Prometheus and Grafana running elsewhere:

```bash
ansible-playbook -i inventory.yml examples/horde_stats_exporter.yml
```

### 4. Deploy Alloy on Application Hosts

To collect metrics, logs, and traces from application workers:

```bash
ansible-playbook -i inventory.yml examples/alloy_app_host.yml
```

### Minimal Inventory

```yaml
all:
  children:
    mimir:
      hosts:
        monitoring.example.com:
          ansible_host: 192.168.1.100
          horde_monitoring_grafana_admin_password: "{{ vault_grafana_admin_password }}"
          horde_monitoring_s3_secret_key: "{{ vault_s3_secret_key }}"
          horde_monitoring_host_filesystem_metrics_available: true
          horde_monitoring_configure_haproxy: true
          exporter_port: 9150
```

## Data Retention

| Layer                             | Default        | Purpose                                       |
| --------------------------------- | -------------- | --------------------------------------------- |
| Prometheus (local)                | `48h`          | Buffer for `remote_write` — short-lived       |
| Mimir `ai-horde-app` tenant       | Infinite (`0`) | AI Horde application metrics                  |
| Mimir `infrastructure` tenant     | `30d`          | Host and infrastructure metrics               |
| Mimir `ai-horde-telemetry` tenant | `3d`           | Tempo span metrics + OTLP-sourced app metrics |
| Mimir `ai-horde-public` tenant    | `90d`          | Public-facing dashboard metrics               |
| Loki (opt-in)                     | `90d`          | Log retention                                 |
| Tempo (opt-in)                    | `7d`           | Trace retention                               |

Prometheus splits data by job: `horde-exporter` → app tenant, everything else
→ infrastructure tenant. Tempo-generated span metrics and OTLP-sourced metrics
from instrumented applications go to the telemetry tenant. See the
[example playbook](examples/horde_monitoring_stack.yml) for the exact
`write_relabel_configs`.

## Trace Sampling Pyramid

Production trace ingest is shaped by two cooperating samplers — **head** in
the application SDK and **tail** in Alloy — to bound storage cost while
preserving diagnostic value:

1. **App-side head sampler** (`OTEL_TRACES_SAMPLER=parentbased_traceidratio`,
   `OTEL_TRACES_SAMPLER_ARG=1.0` by default — i.e. no head sampling).
   Available as a relief valve: lower it if a single instance ever sustains
   1k+ rps and SDK overhead becomes measurable. Decisions are made _before_
   span creation, so every fractional reduction proportionally erodes the
   tail sampler's view of errors. Use `parentbased_traceidratio` to keep
   trace coherence across services when lowering.
2. **Alloy filter** (`otelcol.processor.filter`, enabled by default) drops
   high-volume / low-signal spans (sub-2ms Redis hits, healthcheck/heartbeat
   probes) regardless of head-sample status. Error spans are always exempt
   (`status.code != STATUS_CODE_ERROR` guard on every expression).
3. **Alloy tail sampler** (`otelcol.processor.tail_sampling`, enabled by
   default) decides per-trace after `decision_wait` (5s):
   - 100% of traces with a span in `STATUS_CODE_ERROR`
   - 100% of traces whose root span exceeded
     `horde_alloy_trace_sampling_latency_ms` (1000 ms default)
   - `horde_alloy_trace_sampling_probability`% (1% default) of everything else

**Effective ingest rates at defaults** (head=1.0, filter on, tail policies as above):

| Trace class           | Head | Filter | Tail | Effective ingest       |
| --------------------- | ---- | ------ | ---- | ---------------------- |
| Healthy + fast        | keep | keep   | 1%   | 1% of healthy traces   |
| Errors                | keep | keep   | 100% | 100% of errors         |
| Slow (>1s)            | keep | keep   | 100% | 100% of slow traces    |
| Sub-2ms Redis hits    | keep | drop   | n/a  | 0% (dropped at filter) |
| Healthcheck/heartbeat | keep | drop   | n/a  | 0% (dropped at filter) |

> **Why head=1.0 by default.** At fleet scale (~10k req/hr ≈ 0.1 rps/instance)
> the SDK CPU cost of full sampling is negligible, and tail-only trimming
> preserves 100% of operationally-meaningful traces. Head sampling is a
> blunt instrument — it cannot distinguish errors from healthy traffic
> because the decision happens before the request even runs. Reach for it
> only if profiling shows OTel SDK in the hot path.

Tunable knobs (in `roles/horde_alloy/defaults/main.yml` unless noted):

- `horde_alloy_trace_tail_sampling_enabled` — master switch
- `horde_alloy_trace_filter_enabled` — master switch for the noise filter
- `horde_alloy_trace_filter_exclude_spans` — list of OTTL drop expressions
- `horde_alloy_trace_sampling_decision_wait` — must exceed p99 trace duration
- `horde_alloy_trace_sampling_num_traces` — buffer cap (memory bound)
- `horde_alloy_trace_sampling_expected_new_per_sec` — sizing hint
- `horde_alloy_trace_sampling_latency_ms` — slow-trace threshold
- `horde_alloy_trace_sampling_probability` — baseline keep % (0-100)
- `ai_horde_otel_traces_sampler_arg` (`roles/ai_horde/defaults/main.yml`) —
  app-side head ratio

## Security

- All services bind to `127.0.0.1` — not exposed without a reverse proxy
- Default passwords are blocked at deploy time (fail-fast assertions)
- Use [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/) for credentials
- HAProxy integration uses backup → validate → promote workflow
- Container images are pinned to immutable version tags

See [docs/monitoring/CREDENTIALS.md](docs/monitoring/CREDENTIALS.md) for credential rotation
procedures.

## Grafana Dashboards

Dashboards are auto-provisioned from the
[horde-exporters](https://github.com/Haidra-Org/horde-exporters) repository.
The role clones the repo, copies dashboard JSON into per-org directories, and
patches datasource UIDs to match the provisioned Mimir datasources.

To add custom dashboards, place JSON files in `grafana_dashboard_dir`
(default: `/etc/grafana/dashboards`) on the target host.

### Public-org dashboard convention

Dashboards in the `horde-exporters/dashboards` directory are only included in the non-public Grafana org by default. AI-Horde application dashbaords
from the `ai-horde-stats-exporter` package are included in both orgs by default. 


### Operations Overview dashboard

A new single-pane operator dashboard, `horde-operations-overview` (Org 1
only), aggregates: Alertmanager firing/pending alerts → app health (API up,
queue drain, generate/pop p95) → submit outcome rates and worker-drop ratios
→ Postgres saturation/long-tx/deadlocks/pool timeouts → host top-N
(CPU/memory/disk) → Loki critical/error log volume with deep-link to Explore.

## Alerts

Application alerts are templated in
`roles/horde_monitoring/templates/alerting-rules.yml.j2` and pushed to the
Mimir ruler API at deploy time. Log-derived alerts are templated in
`templates/loki-rules.yml.j2` and pushed to the Loki ruler API.

### Toggles (defaults/main.yml)

| Variable                                               | Default | Effect                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `horde_monitoring_install_app_alerts`                  | `true`  | App health (HordeExporterDown, HordeAPI*, HordeNoActive*Workers, HordeImage\*, HordeMaintenanceMode, HordeRaidMode).                                                                                                                                                                                |
| `horde_monitoring_install_otlp_app_alerts`             | `true`  | OTLP-derived (HordeGenerateLatencyHigh, HordePopLatencyHigh, HordeWebhookFailureBurst, HordeBackgroundJobFailures, HordeJobFailureBurstPerName, HordeSubmitFaultRate, HordeSubmitCensoredSpike, HordePopSkipDominant, HordeDBPoolTimeouts).                                                         |
| `horde_monitoring_install_postgres_alerts`             | `false` | Postgres health. **The role probes Prometheus targets at deploy time and fails fast if no scrape job matches `horde_monitoring_postgres_job_name`.** Includes HordePostgresPoolNearMax (>90% of max_connections) and HordePostgresLongRunningTx (uses built-in `pg_stat_activity_max_tx_duration`). |
| `horde_monitoring_require_postgres_tx_duration_metric` | `true`  | When postgres alerts are enabled, fail fast unless Prometheus has `pg_stat_activity_max_tx_duration{job="<postgres job>"}`.                                                                                                                                                                         |
| `horde_monitoring_install_loki_app_log_alerts`         | `true`  | Loki ruler alerts on AI-Horde log patterns: maintenance entry, worker suspicion spike, Flask cache failing, Redis unreachable, Redis quorum change, Limiter cache failing.                                                                                                                          |

### Tunables for new OTLP alerts

| Variable                                        | Default | Used by                                             |
| ----------------------------------------------- | ------- | --------------------------------------------------- |
| `horde_monitoring_otlp_submit_fault_ratio`      | `0.05`  | HordeSubmitFaultRate (faulted/total threshold).     |
| `horde_monitoring_otlp_submit_censored_per_sec` | `0.5`   | HordeSubmitCensoredSpike (absolute rate threshold). |

## Troubleshooting

### Quick Health Checks

```bash
curl -sf http://127.0.0.1:9009/ready   && echo "Mimir OK"
curl -sf http://127.0.0.1:3000/api/health && echo "Grafana OK"
# Embedded Garage mode:
curl -sf http://127.0.0.1:3903/health && echo "S3 backend OK"
# External mode: use your provider-specific S3 health/availability checks.
curl -sf http://localhost:9150/metrics | head -5 && echo "Exporter OK"
systemctl status prometheus --no-pager
```

### Prometheus

```bash
journalctl -u prometheus -f
promtool check config /etc/prometheus/prometheus.yml
curl -s http://127.0.0.1:9090/api/v1/status/config | grep -A20 remote_write
```

### Mimir

```bash
docker logs mimir
curl http://127.0.0.1:9009/runtime_config
curl http://127.0.0.1:9009/api/v1/user_limits -H 'X-Scope-OrgID: ai-horde-app'
```

### Grafana

```bash
docker logs grafana
systemctl restart mimir-monitoring   # restarts entire Docker Compose stack
```

### Configuration Drift

```bash
ansible-playbook -i inventory.yml site.yml --check --diff
```

Any `changed` tasks indicate drift from the Ansible-managed state.

## Operational Guides

| Topic                                  | Document                                                             |
| -------------------------------------- | -------------------------------------------------------------------- |
| All monitoring docs (index)            | [docs/monitoring/README.md](docs/monitoring/README.md)               |
| Logs, traces, and Alloy deep-dive      | [docs/monitoring/OBSERVABILITY.md](docs/monitoring/OBSERVABILITY.md) |
| Backup & restore (RPO/RTO, procedures) | [docs/monitoring/BACKUP.md](docs/monitoring/BACKUP.md)               |
| Credential management and rotation     | [docs/monitoring/CREDENTIALS.md](docs/monitoring/CREDENTIALS.md)     |
| Component version upgrades             | [docs/monitoring/UPGRADING.md](docs/monitoring/UPGRADING.md)         |
| Host migration (planned and forced)    | [docs/monitoring/MIGRATION.md](docs/monitoring/MIGRATION.md)         |

## Further Reading

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Mimir Documentation](https://grafana.com/docs/mimir/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [AI Horde API](https://aihorde.net/api/)
