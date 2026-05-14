# AI-Horde Deploy Role

- [AI-Horde Deploy Role](#ai-horde-deploy-role)
    - [How It Works](#how-it-works)
    - [Requirements](#requirements)
    - [Required Variables](#required-variables)
    - [Production Deployments](#production-deployments)
        - [Recommended production pattern](#recommended-production-pattern)
        - [Emergency override](#emergency-override)
    - [Reverse Proxy (Bring Your Own)](#reverse-proxy-bring-your-own)
    - [Core Role Variables](#core-role-variables)
    - [Embedded Datastore Variables](#embedded-datastore-variables)
    - [Observability / Telemetry](#observability--telemetry)

Deploys the **AI-Horde backend** (Flask application) as a Docker Compose stack,
managed via the Ansible `community.docker.docker_compose_v2` module.

> **Scope:** This role is purpose-built for the
> [AI-Horde](https://github.com/Haidra-Org/AI-Horde) application. It is not a
> general-purpose Flask, PostgreSQL, or Redis deployment role.
> Schema migrations, backups, replication, and database tuning are explicitly out of scope.

> **Datastores:** By default this role bundles a local PostgreSQL and Redis container
> as a single-host convenience for local development and CI. For production deployments
> PostgreSQL and Redis **must** be deployed and managed independently — see
> [Production Deployments](#production-deployments).

## How It Works

The role pulls the configured backend image and renders a Docker Compose project with:

1. One or more AI-Horde backend containers (replica count from `ai_horde_replicas`).
2. An optional embedded PostgreSQL container (`ai_horde_embedded_postgres_enabled`, default `true`).
3. An optional embedded Redis container (`ai_horde_embedded_redis_enabled`, default `true`).

Embedded datastores default to `true` for backward compatibility and to make
local-deploy and CI work without additional configuration. **They are not the
recommended production model.** See [Production Deployments](#production-deployments).

Container orchestration is handled entirely by **Docker Compose V2**. The role does not
create `systemd` units for the containers, avoiding daemon conflicts on shared hosts.

Replica count is applied via the `scale` parameter of the
`community.docker.docker_compose_v2` module — the compose file does not use
`deploy.replicas`. If you set `ai_horde_replicas: 4`, the role publishes a
host port range (for example `7001-7004`) mapped to container port `7001`.

Container logs are routed to `journald` by default (`ai_horde_log_driver`).
Use `journalctl -t docker` or filter by container name to tail them. Standard
`docker logs` continues to work alongside journald.

When OTEL is enabled (the default), containers send telemetry directly to the
host via Docker's `host.docker.internal` bridge on port `4318`. This expects
a Grafana Alloy instance listening on the host (see the `horde_alloy` role).

## Requirements

- **Docker Compose V2** (V1 is end-of-life).
- **Ansible 2.14+**
- `community.docker` Ansible collection (`ansible-galaxy collection install community.docker`).

## Required Variables

The role will **fail immediately** if any of the following are missing or empty:

| Variable                                       | Description                                       |
| ---------------------------------------------- | ------------------------------------------------- |
| `ai_horde_postgres_password`                   | Password for PostgreSQL (embedded or external)    |
| `ai_horde_secret_key`                          | Flask secret key for session signing              |
| `ai_horde_env_overrides.KUDOS_TRUST_THRESHOLD` | Minimum kudos threshold for trusted worker status |

Store secrets in Ansible Vault. Example:

```yaml
# group_vars/all/vault.yml (encrypted)
ai_horde_postgres_password: "{{ vault_ai_horde_postgres_password }}"
ai_horde_secret_key: "{{ vault_ai_horde_secret_key }}"
ai_horde_env_overrides:
  KUDOS_TRUST_THRESHOLD: "1000"
```

## Production Deployments

For production environments, PostgreSQL and Redis **must** be deployed and
managed independently — not bundled in the same compose file as the application.
Reasoning:

- **Data durability:** compose-managed volumes are co-located with the application
  container. A botched upgrade or a mistyped `docker compose down -v` destroys
  your database.
- **Scaling:** multi-host AI-Horde deployments require a single external
  PostgreSQL endpoint; each replica cannot have its own local Postgres.
- **Backup/recovery, replication, and tuning** are all out of scope for this role.

### Recommended production pattern

Set the embedded datastore flags to `false` and point the host variables at
your externally managed instances:

```yaml
roles:
  - role: ai_horde
    vars:
      ai_horde_embedded_postgres_enabled: false
      ai_horde_embedded_redis_enabled: false
      ai_horde_postgres_host: "db.internal.example.com"
      ai_horde_redis_host: "redis.internal.example.com"
      ai_horde_postgres_password: "{{ vault_ai_horde_pg_password }}"
      ai_horde_secret_key: "{{ vault_ai_horde_secret_key }}"
      ai_horde_env_overrides:
        KUDOS_TRUST_THRESHOLD: "1000"
```

If you are using a managed service (RDS, ElastiCache, etc.), supply the
service endpoint as `ai_horde_postgres_host` / `ai_horde_redis_host`.

### Emergency override

If you are deliberately running a single-node homelab deployment tagged
as `production` and accept the limitations above, set:

```yaml
ai_horde_allow_embedded_datastores_in_production: true
```

This silences the fail-fast guard. It does **not** make the embedded
postgres/redis suitable for multi-host or high-availability deployments.

## Reverse Proxy (Bring Your Own)

This role does not handle SSL/TLS termination, rate limiting, or HTTP routing.
It binds the backend to `127.0.0.1` (by default) and expects you to front it
with a reverse proxy of your choice — HAProxy, Nginx, Caddy, etc.

For HAProxy topology guidance and a worked decision matrix, see
[docs/ai-horde-haproxy-topology.md](../../docs/ai-horde-haproxy-topology.md).

Example Nginx configuration:

```nginx
upstream horde {
  server 127.0.0.1:7001;
  server 127.0.0.1:7002;
}

server {
  listen 80;
  server_name horde.internal;

  location / {
    proxy_pass http://horde;
  }
}
```

> **Telemetry note:** When OTEL is enabled, containers send telemetry
> directly to the host Alloy agent via `host.docker.internal` — no
> proxy configuration is needed for telemetry traffic.

## Core Role Variables

| Variable                             | Default                            | Description                                                                          |
| ------------------------------------ | ---------------------------------- | ------------------------------------------------------------------------------------ |
| `ai_horde_default_image`             | `ghcr.io/haidra-org/ai-horde:main` | Default Docker image, without Pyroscope profiling wheels                             |
| `ai_horde_telemetry_image`           | `ghcr.io/haidra-org/ai-horde:main-telemetry` | Docker image with the `telemetry-profiling` dependency group installed     |
| `ai_horde_image`                     | dynamic                            | Image to deploy; defaults to `ai_horde_telemetry_image` when Pyroscope is enabled    |
| `ai_horde_build_context`             | `""`                              | Optional local Docker build context; empty means pull `ai_horde_image`               |
| `ai_horde_build_dependency_groups`   | `[]`                               | Optional pyproject dependency groups passed to Docker as `AI_HORDE_DEPENDENCY_GROUPS` |
| `ai_horde_port`                      | `7001`                             | Base HTTP port (range start when replicas > 1)                                       |
| `ai_horde_listen`                    | `127.0.0.1`                        | Bind address for host port mapping                                                   |
| `ai_horde_replicas`                  | `1`                                | Number of backend container replicas                                                 |
| `ai_horde_waitress_threads`          | `45`                               | Waitress threads per replica                                                         |
| `ai_horde_waitress_connection_limit` | `1024`                             | Max concurrent connections per replica                                               |
| `ai_horde_log_driver`                | `journald`                         | Docker log driver (`journald`, `json-file`, etc.)                                    |
| `ai_horde_base_dir`                  | `/opt/ai-horde`                    | Directory for compose file and `.env`                                                |
| `ai_horde_data_dir`                  | `/var/lib/ai-horde`                | Persistent data root. Must not be a PostgreSQL system path (`/var/lib/postgresql*`). |

## Embedded Datastore Variables

| Variable                                           | Default       | Description                                                                                      |
| -------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------ |
| `ai_horde_embedded_postgres_enabled`               | `true`        | Render a PostgreSQL container in the compose file. Set `false` for production external DB.       |
| `ai_horde_embedded_redis_enabled`                  | `true`        | Render a Redis container in the compose file. Set `false` for production external Redis.         |
| `ai_horde_allow_embedded_datastores_in_production` | `false`       | Override the production fail-fast guard for single-node homelabs only.                           |
| `ai_horde_postgres_host`                           | `postgres`    | PostgreSQL hostname (compose service name when embedded; external hostname otherwise).           |
| `ai_horde_postgres_port`                           | `5432`        | PostgreSQL port.                                                                                 |
| `ai_horde_postgres_user`                           | `aihorde`     | PostgreSQL username.                                                                             |
| `ai_horde_postgres_db`                             | `aihorde`     | PostgreSQL database name.                                                                        |
| `ai_horde_redis_host`                              | `redis`       | Redis hostname (compose service name when embedded; external hostname otherwise).                |
| `ai_horde_redis_port`                              | `6379`        | Redis port.                                                                                      |
| `ai_horde_postgres_image`                          | pinned digest | Docker image for embedded PostgreSQL (ignored when `ai_horde_embedded_postgres_enabled: false`). |
| `ai_horde_redis_image`                             | pinned digest | Docker image for embedded Redis (ignored when `ai_horde_embedded_redis_enabled: false`).         |

## Observability / Telemetry

Variables governing OpenTelemetry (traces/metrics) and Pyroscope (continuous profiling).
OpenTelemetry is installed in the default image. Pyroscope profiling is optional
because it pulls native profiler wheels; use `ai_horde_pyroscope_enabled: "true"`
to select the published `main-telemetry` image, or use `ai_horde_build_context`
with the `telemetry-profiling` dependency group for local builds.
Do not set `PYROSCOPE_ENABLED` through `ai_horde_env_overrides`; the role rejects
that so image selection and build args cannot drift from the runtime switch.

| Variable                           | Default      | Description                                                                    |
| ---------------------------------- | ------------ | ------------------------------------------------------------------------------ |
| `ai_horde_otel_service_name`       | `ai-horde`   | Service name tag in traces and metrics                                         |
| `ai_horde_otel_sdk_disabled`       | `"false"`    | Set to `"true"` to disable OpenTelemetry entirely                              |
| `ai_horde_otel_instrument_redis`   | `"false"`    | Enable OTel Redis instrumentation (noisy; pair with Alloy-side span filtering) |
| `ai_horde_otel_traces_sampler_arg` | `"1.0"`      | Head sampler ratio (0.0–1.0); lower only under sustained high RPS              |
| `ai_horde_pyroscope_enabled`       | `"false"`    | Enable continuous profiling and select/add the profiling dependency group       |
| `ai_horde_pyroscope_dependency_group` | `telemetry-profiling` | pyproject dependency group used when building a profiling-capable image |
| `ai_horde_deployment_environment`  | `production` | Environment tag for separating dev/staging clusters in dashboards              |
