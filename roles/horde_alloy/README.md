# horde_alloy

Deploys [Grafana Alloy](https://grafana.com/docs/alloy/) on application hosts
as a unified telemetry collector for metrics, logs, and traces.

Use `horde_alloy_collect_metrics: false` when host metrics are sourced from
standalone `node_exporter`.

> **Scope:** This role configures Alloy with pipelines tuned for the AI Horde
> monitoring stack (Mimir, Loki, Tempo). It is not a general-purpose Alloy
> role. If you need Alloy for non-Horde workloads, the upstream Grafana
> collection is a better starting point.

## What This Role Deploys

- **Grafana Alloy** as a native systemd package (APT or DNF)
- A fully templated Alloy River configuration with three pipelines:
  - **Metrics** — `prometheus.exporter.unix` host metrics + optional extra scrape targets → Mimir
  - **Logs** — systemd journal, file globs, and/or Docker container logs → Loki
  - **Traces** — OTLP gRPC/HTTP receiver for application-emitted traces → Tempo
- TLS CA certificate deployment for secure communication with the central stack

## Architecture

```
┌──── Application Host ────────────────────────────────┐
│                                                      │
│  Your App ─── OTLP ──► Grafana Alloy                │
│                          ├─ host metrics  ──► Mimir  │
│                          ├─ journal logs  ──► Loki   │
│                          └─ traces        ──► Tempo  │
└──────────────────────────────────────────────────────┘
```

Each pipeline is independently toggleable. Alloy binds its health/UI
endpoint to `127.0.0.1` by default.

## Requirements

- Debian/Ubuntu or RHEL/CentOS 8+ target
- Ansible 2.14+
- A running monitoring stack with reachable Mimir, Loki, and/or Tempo endpoints
  (see [horde_monitoring role](../horde_monitoring/README.md))

## Quick Start

```yaml
- hosts: app_workers
  become: true
  roles:
    - role: haidra.deployments.horde_alloy
      vars:
        horde_alloy_mimir_endpoint: "https://mimir.example.com/api/v1/push"
        horde_alloy_loki_endpoint: "https://loki.example.com/loki/api/v1/push"
        horde_alloy_tempo_endpoint: "https://tempo.example.com:4318"
        horde_alloy_tenant_id: "infrastructure"
        horde_alloy_basic_auth_username: "alloy"
        horde_alloy_basic_auth_password: "{{ vault_horde_alloy_basic_auth_password }}"
        horde_alloy_tls_ca_cert: "tls/ca.crt"
```

See [examples/alloy_app_host.yml](../../examples/alloy_app_host.yml) for a
complete example playbook.

## Host Metrics Source

- Use standalone `node_exporter`: set `horde_alloy_collect_metrics: false`
- Use Alloy host metrics (`prometheus.exporter.unix`): set `horde_alloy_collect_metrics: true`

## Role Variables

### General

| Variable                    | Default          | Description                             |
| --------------------------- | ---------------- | --------------------------------------- |
| `horde_alloy_version`             | `1.8.1`          | Pinned Alloy package version            |
| `horde_alloy_config_dir`          | `/etc/alloy`     | Configuration directory                 |
| `horde_alloy_data_dir`            | `/var/lib/alloy` | Persistent data (WAL, positions)        |
| `horde_alloy_log_level`           | `warn`           | Log verbosity                           |
| `horde_alloy_http_listen_address` | `127.0.0.1`      | Health/UI bind address                  |
| `horde_alloy_http_port`           | `12345`          | Health/UI port                          |
| `horde_alloy_start_service`       | `true`           | Start the service (`false` for CI/test) |

### Authentication

| Variable                    | Default          | Description                                                  |
| --------------------------- | ---------------- | ------------------------------------------------------------ |
| `horde_alloy_tenant_id`           | `infrastructure` | Mimir/Loki tenant ID                                         |
| `horde_alloy_basic_auth_username` | `alloy`          | Basic auth username for all endpoints                        |
| `horde_alloy_basic_auth_password` | `changeme-alloy` | Basic auth password (**must override**)                      |
| `horde_alloy_tls_ca_cert`         | `""`             | Path to CA cert on the Ansible controller (empty = skip TLS) |

### Metrics Pipeline

| Variable                     | Default | Description                                          |
| ---------------------------- | ------- | ---------------------------------------------------- |
| `horde_alloy_mimir_endpoint`       | `""`    | Mimir remote_write URL (required if metrics enabled) |
| `horde_alloy_collect_metrics`      | `true`  | Enable host metrics collection                       |
| `horde_alloy_scrape_interval`      | `15s`   | Metrics scrape interval                              |
| `horde_alloy_external_labels`      | `{}`    | Extra labels added to all metrics                    |
| `horde_alloy_extra_scrape_targets` | `[]`    | Additional scrape targets (list of `{job, targets}`) |
| `horde_alloy_unix_exporter_set_collectors` | `[]` | Replace default collector set with an explicit list |
| `horde_alloy_unix_exporter_enable_collectors` | `[]` | Enable additional collectors (for example `systemd`) |
| `horde_alloy_unix_exporter_disable_collectors` | `[]` | Disable selected collectors |
| `horde_alloy_unix_exporter_include_exporter_metrics` | `false` | Include exporter self-metrics |
| `horde_alloy_unix_exporter_textfile_directory` | `""` | Enable `textfile` collector from a directory of `*.prom` files |
| `horde_alloy_unix_exporter_filesystem_fs_types_exclude` | `""` | Override filesystem type exclude regex |
| `horde_alloy_unix_exporter_filesystem_mount_points_exclude` | `""` | Override mount-point exclude regex |
| `horde_alloy_unix_exporter_filesystem_mount_timeout` | `5s` | Filesystem collector mount timeout override |

### Logs Pipeline

| Variable                    | Default | Description                                 |
| --------------------------- | ------- | ------------------------------------------- |
| `horde_alloy_loki_endpoint`       | `""`    | Loki push URL (required if logs enabled)    |
| `horde_alloy_collect_logs`        | `true`  | Enable log collection                       |
| `horde_alloy_collect_journal`     | `true`  | Collect systemd journal                     |
| `horde_alloy_journal_max_age`     | `24h`   | Max journal entry age on first start        |
| `horde_alloy_collect_log_files`   | `[]`    | Glob patterns for file-based log collection |
| `horde_alloy_collect_docker_logs` | `false` | Collect Docker container logs               |
| `horde_alloy_docker_logs_tenant_id` | `""` | Optional Loki tenant override for Docker logs; empty uses `horde_alloy_tenant_id` |
| `horde_alloy_log_labels`          | `{}`    | Extra labels on all log streams             |

### Traces Pipeline

| Variable                     | Default     | Description                                      |
| ---------------------------- | ----------- | ------------------------------------------------ |
| `horde_alloy_tempo_endpoint`       | `""`        | Tempo OTLP endpoint (required if traces enabled) |
| `horde_alloy_collect_traces`       | `true`      | Enable OTLP trace receiver                       |
| `horde_alloy_otlp_listen_address`  | `0.0.0.0`   | OTLP receiver bind address                       |
| `horde_alloy_otlp_grpc_port`       | `4317`      | OTLP gRPC port                                   |
| `horde_alloy_otlp_http_port`       | `4318`      | OTLP HTTP port                                   |
| `horde_alloy_trace_batch_timeout`  | `5s`                   | Batch flush interval                                                                                                     |
| `horde_alloy_trace_batch_size`     | `8192`                 | Max batch size (spans)                                                                                                   |
| `horde_alloy_forward_otlp_metrics` | `true`                 | Forward OTLP metrics to Mimir via OTLP HTTP endpoint                                                                     |
| `horde_alloy_mimir_otlp_endpoint`  | `""`                   | Mimir OTLP ingest endpoint (required when `horde_alloy_forward_otlp_metrics: true`; e.g. `https://mimir.example.com/otlp`) |
| `horde_alloy_otlp_metrics_tenant_id` | `ai-horde-telemetry` | Mimir tenant for OTLP-sourced metrics; defaults to the dedicated telemetry tenant with short retention (3d) to contain high-churn derived metric cardinality |
| `horde_alloy_otlp_metric_resource_label_attributes` | `[]` | Low-cardinality OTLP resource attributes to copy into metric labels before export, as `{ resource_attribute, label }` items |

### Trace Filtering and Sampling

Pre-sampling span filtering (drops matching spans before sampling decisions):

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `horde_alloy_trace_filter_enabled` | `true` | Enable pre-sampling span filter |
| `horde_alloy_trace_filter_exclude_spans` | `[]` | List of filter expressions to drop spans (see defaults/main.yml for syntax) |

Tail-based sampling (probabilistic with latency overrides):

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `horde_alloy_trace_tail_sampling_enabled` | `true` | Enable tail sampling |
| `horde_alloy_trace_sampling_decision_wait` | `10s` | How long to wait before making a sampling decision |
| `horde_alloy_trace_sampling_num_traces` | `50000` | Max number of traces held in memory |
| `horde_alloy_trace_sampling_expected_new_per_sec` | `100` | Expected new traces/sec (used for memory sizing) |
| `horde_alloy_trace_sampling_latency_ms` | `1000` | Always-sample threshold: traces with any span over this ms are kept |
| `horde_alloy_trace_sampling_probability` | `0.1` | Probability for traces that don't meet latency threshold (0.0–1.0) |
| `horde_alloy_trace_sampling_extra_policies` | `[]` | Additional otelcol.processor.tail_sampling policy blocks |

## Validation

The role asserts at the start of execution that:

- Endpoint URLs are configured for each enabled pipeline
- `horde_alloy_basic_auth_password` is not the insecure default

## Instrumenting Applications

Applications on Alloy hosts can send traces via OTLP to the local receiver:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_SERVICE_NAME="my-service"
```

See [docs/monitoring/OBSERVABILITY.md](../../docs/monitoring/OBSERVABILITY.md) for Python and
Node.js instrumentation examples and trace-log correlation setup.

## Verification

```bash
# Service status
systemctl status alloy

# Logs
journalctl -u alloy -f

# Health check
curl -s http://127.0.0.1:12345/-/healthy

# Alloy UI (if accessible)
# http://127.0.0.1:12345
```

## Related Documentation

- [Observability Stack](../../docs/monitoring/OBSERVABILITY.md) — Loki, Tempo, Alloy architecture and OTLP instrumentation
- [horde_monitoring role](../horde_monitoring/README.md) — Central Mimir + Grafana stack
- [Alloy example playbook](../../examples/alloy_app_host.yml)

## License

AGPL-3.0
