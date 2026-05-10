# horde_stats_exporter

Deploys the [AI Horde Prometheus exporter](https://github.com/Haidra-Org/horde-exporters)
as a Docker Compose stack. The exporter polls the AI Horde public API and exposes
metrics at a `/metrics` endpoint for Prometheus to scrape.

> **Scope:** This exporter is specific to the AI Horde API. It is not a
> general-purpose Prometheus exporter framework.

## What This Role Deploys

- A Docker Compose project under `/opt/horde-stats-exporter/` that runs the
  `ghcr.io/haidra-org/ai-horde-stats-exporter` image. The container publishes
  `/metrics` on `127.0.0.1:9150` by default and uses journald logging with the
  standard `horde.logs` / `horde.app` / `horde.component` labels.
- A rendered `exporter_config.yaml` mounted read-only at
  `/etc/horde-stats-exporter/exporter_config.yaml` inside the container.

The stack runs `docker_compose_v2` against a single-service compose file. The
in-container listener is fixed at `9150` (matches the image's `EXPOSE`); the
host-side bind is controlled by the role's `listen` / `port` variables.

## Requirements

- Docker Engine and the Compose v2 plugin (`docker compose`) on the target host
- The `community.docker` collection (provided by `requirements.yml`)
- Network access to `https://aihorde.net` (or the configured API base URL) and
  to `ghcr.io` for image pulls

## Quick Start

```yaml
- hosts: monitoring
  become: true
  roles:
    - role: haidra.deployments.horde_stats_exporter
```

Then configure Prometheus to scrape it:

```yaml
prometheus_scrape_configs:
  - job_name: horde-exporter
    static_configs:
      - targets: ["localhost:9150"]
```

See [examples/horde_stats_exporter.yml](../../examples/horde_stats_exporter.yml) for a
standalone example, or [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml)
for the full integrated stack.

## Role Variables

### Image and Container

| Variable                              | Default                                                  | Description                                                      |
| ------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------- |
| `horde_stats_exporter_image`          | `ghcr.io/haidra-org/ai-horde-stats-exporter:main`        | Container image reference                                        |
| `horde_stats_exporter_image_digest`   | `""`                                                     | Optional `sha256:...` digest pin appended as `<image>@<digest>`  |
| `horde_stats_exporter_container_name` | `horde-stats-exporter`                                   | Container name                                                   |
| `horde_stats_exporter_base_dir`       | `/opt/horde-stats-exporter`                              | Compose project directory                                        |
| `horde_stats_exporter_listen`         | `127.0.0.1`                                              | Host bind address for the published port                         |
| `horde_stats_exporter_port`           | `9150`                                                   | Host port (mapped to container `9150`)                           |
| `horde_stats_exporter_log_driver`     | `journald`                                               | Compose logging driver                                           |
| `horde_stats_exporter_log_tag`        | `horde-stats-exporter`                                   | Journald tag (when driver is `journald`)                         |
| `horde_stats_exporter_start_services` | `true`                                                   | When `false`, render templates only (used by render tests)       |

For reproducible deployments, pin `horde_stats_exporter_image_digest` to the
digest emitted by the GHCR release manifest. The role rejects any value that
does not match `^sha256:[0-9a-f]{64}$`.

### API Configuration

| Variable                            | Default                      | Description                   |
| ----------------------------------- | ---------------------------- | ----------------------------- |
| `horde_stats_exporter_api_base_url` | `https://aihorde.net/api/v2` | AI Horde API base URL         |
| `horde_stats_exporter_api_timeout`  | `10`                         | API request timeout (seconds) |
| `horde_stats_exporter_user_agent`   | `horde_prometheus_exporter`  | HTTP User-Agent header        |
| `horde_stats_exporter_log_level`    | `INFO`                       | Exporter log level            |

### Scrape Intervals

Each metric group is polled on its own interval (seconds):

| Variable                                  | Default | What It Collects                      |
| ----------------------------------------- | ------- | ------------------------------------- |
| `horde_stats_exporter_scrape_models`      | `8`     | Model queue depths and worker counts  |
| `horde_stats_exporter_scrape_workers`     | `300`   | Individual worker stats               |
| `horde_stats_exporter_scrape_performance` | `2`     | Global queue and performance counters |
| `horde_stats_exporter_scrape_stats`       | `120`   | Historical generation statistics      |
| `horde_stats_exporter_scrape_modes`       | `30`    | Heartbeat and maintenance mode flags  |
| `horde_stats_exporter_scrape_teams`       | `300`   | Team-level statistics                 |

## Metrics Exposed

### Models

- `horde_models_queued_total{type}` — Total requests queued
- `horde_model_queued{model, type}` — Per-model queue depth
- `horde_model_workers_count{model, type}` — Workers supporting each model

### Workers

- `horde_workers_active_total{type}` — Total active workers
- `horde_worker_requests_fulfilled_total{worker, type}` — Completed requests
- `horde_worker_kudos_rewards{worker, type}` — Kudos earned

### Performance

- `horde_performance_queued_requests{type}` — Global queue depth
- `horde_performance_worker_count{type}` — Workers by type (image/text/interrogator)

All metrics use consistent `type=image|text|interrogator` labels.

## Verification

```bash
# Container status
sudo docker ps --filter name=horde-stats-exporter

# Logs (journald via the journald log driver)
sudo journalctl CONTAINER_NAME=horde-stats-exporter -f

# Test metrics endpoint
curl -s http://localhost:9150/metrics | head -20
```

## Migration From the Legacy systemd Service

Earlier revisions of this role installed the exporter as a uv-managed
systemd service. See [DEPLOY_NOTES.md](../../DEPLOY_NOTES.md) for the one-off
cleanup steps (`systemctl disable --now horde-exporter.service`, removal of
the unit and `/opt/horde-exporter`) that must be run on existing monitoring
hosts before re-applying this role. Prometheus scrape configuration does not
change — the new container publishes the same `localhost:9150/metrics`.

## Related Documentation

- [Monitoring Deployment Guide](../../MONITORING.md) — Full stack architecture and quick start
- [horde_monitoring role](../horde_monitoring/README.md) — Mimir + Grafana stack
- [Full stack example](../../examples/horde_monitoring_stack.yml) — Complete playbook

## License

AGPL-3.0
