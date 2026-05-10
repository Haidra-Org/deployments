# horde_service_alerts

Deploys the **AI Horde service-alerts** FastAPI middleman as a Docker
Compose stack and (optionally) wires it into the host's HAProxy via
`/etc/haproxy/conf.d/`.

## Purpose

The service-alerts middleman keeps the monitoring stack (Alertmanager + Mimir)
isolated from the public internet by exposing two narrow API surfaces:

- **Public, unauthenticated** (`/api/v1/public/*`) — coarse rolled-up status,
  sanitized active-alert summaries, and aggregate silence counts.  All
  responses pass through allowlist-based projection so internal labels such
  as `instance`, `pod`, `__name__`, alert `description`, and `runbook_url`
  never leave the host.
- **Internal, moderator-only** (`/api/v1/internal/*`) — raw Alertmanager
  alerts/silences/status and ad-hoc Mimir instant queries, gated by an
  `apikey` request header validated against the AI Horde
  `GET /v2/find_user` endpoint (`moderator: true`).

A health probe (`/healthz`) and a readiness probe (`/readyz`) are exposed
without authentication for upstream load balancers.

## Deployment shape

| Concern              | Default                                         |
| -------------------- | ----------------------------------------------- |
| Listen address/port  | `127.0.0.1:19810` (loopback)                     |
| Container name       | `horde-service-alerts`                          |
| Filesystem layout    | `/opt/ai-horde-service-alerts/`                 |
| Logging              | `journald` (tagged `ai-horde-service-alerts`)   |
| Upstream Alertmanager | `http://host.docker.internal:9093`             |
| Upstream Mimir       | `http://host.docker.internal:9009`              |
| AI Horde verifier    | `https://aihorde.net/api/`                      |

The role expects the Docker host to provide `host.docker.internal` (the
templates inject `extra_hosts: "host.docker.internal:host-gateway"`); this
is the same pattern used by the `ai_horde` and `aihorde_frontpage` roles.

## Variables

| Variable                                                       | Default                                              | Notes                                                                       |
| -------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------- |
| `horde_service_alerts_start_services`                          | `true`                                               | Set `false` for render-only (CI).                                          |
| `horde_service_alerts_image`                                   | `ghcr.io/haidra-org/ai-horde-service-alerts:main`    | Override per environment.                                                  |
| `horde_service_alerts_image_digest`                            | `""`                                                 | Optional `sha256:...` digest pin appended as `<image>@<digest>`. Validated against `^sha256:[0-9a-f]{64}$`. |
| `horde_service_alerts_listen` / `_port`                        | `127.0.0.1` / `19810`                                 | Bind for the published Docker port mapping.                                |
| `horde_service_alerts_alertmanager_base_url`                   | `http://host.docker.internal:9093`                   | Alertmanager root.                                                         |
| `horde_service_alerts_mimir_base_url`                          | `http://host.docker.internal:9009`                   | Mimir root (NOT `/prometheus`).                                            |
| `horde_service_alerts_mimir_tenant_default`                    | `ai-horde-public`                                    | `X-Scope-OrgID` for curated public queries.                                |
| `horde_service_alerts_mimir_curated_queries`                   | `{}`                                                 | `name -> PromQL` map driving `/api/v1/public/status` component badges.     |
| `horde_service_alerts_upstream_basic_auth_user` / `_password`  | `""` / `""`                                          | Client-side basic-auth pair sent by service-alerts to the monitoring egress frontend; should match `horde_monitoring_service_alerts_egress_auth_*`. |
| `horde_service_alerts_aihorde_base_url`                        | `https://aihorde.net/api/`                           | Trailing `/` required.                                                     |
| `horde_service_alerts_moderator_cache_ttl_seconds`             | `60`                                                 | Positive auth-cache TTL.                                                   |
| `horde_service_alerts_moderator_cache_negative_ttl_seconds`    | `15`                                                 | Negative auth-cache TTL.                                                   |
| `horde_service_alerts_public_alert_label_allowlist`            | `["alertname","severity","component","service"]`     | Labels retained on public projections.                                     |
| `horde_service_alerts_public_annotation_allowlist`             | `["summary"]`                                        | Annotations retained on public projections.                                |
| `horde_service_alerts_request_timeout_seconds`                 | `5.0`                                                | Per-upstream HTTP timeout.                                                 |
| `horde_service_alerts_cors_allow_origins`                      | `[]`                                                 | Blanks means no xsite allowed; ["*"] enables all. See https://fastapi.tiangolo.com/tutorial/cors/ for more info                                          |
| `horde_service_alerts_enable_internal_swagger_docs`            | `true`                                               | Disables `/docs`, `/redoc`, `/openapi.json` when `false`.                  |
| `horde_service_alerts_configure_haproxy_backend`               | `false`                                              | When `true`, drops a conf.d fragment for the public path prefix.           |
| `horde_service_alerts_haproxy_public_path_prefix`              | `/api/service-alerts/`                               | Prefix stripped before forwarding to the FastAPI service.                  |

## HAProxy integration

When `horde_service_alerts_configure_haproxy_backend: true` the role:

1. Includes `_haproxy_confd_bootstrap` to ensure the conf.d directory + the
   systemd override that loads it.
2. Templates a fragment at `/etc/haproxy/conf.d/horde-service-alerts.cfg`
   that defines a backend `horde_service_alerts_backend` with a
   `http-request replace-path` rule stripping
   `horde_service_alerts_haproxy_public_path_prefix` before forwarding.

The fragment intentionally does **not** define a frontend; pair it with the
host's existing public frontend by adding a `use_backend` ACL such as:

```haproxy
acl is_horde_service_alerts path_beg /api/service-alerts/
use_backend horde_service_alerts_backend if is_horde_service_alerts
```

## Reaching off-host Alertmanager + Mimir

For deployments where the monitoring stack lives on a different host, use
the optional egress frontend exposed by the `horde_monitoring` role:

```yaml
horde_monitoring_configure_service_alerts_egress_frontend: true
horde_monitoring_service_alerts_egress_listen: "0.0.0.0"
horde_monitoring_service_alerts_egress_auth_user: "service-alerts"
horde_monitoring_service_alerts_egress_auth_password: "{{ vault_service_alerts_egress_pwd }}"
```

…and on the consumer:

```yaml
horde_service_alerts_alertmanager_base_url: "http://monitoring.example:9494"
horde_service_alerts_mimir_base_url: "http://monitoring.example:9494"
horde_service_alerts_upstream_basic_auth_user: "service-alerts"
horde_service_alerts_upstream_basic_auth_password: "{{ vault_service_alerts_egress_pwd }}"
```

The egress frontend routes `/prometheus/*` to Mimir and `/api/v2/*` + `/-/*`
to Alertmanager behind HAProxy basic auth.

The two variable pairs describe the same credential from opposite sides of
that HAProxy boundary:

- `horde_monitoring_service_alerts_egress_auth_*` is what the monitoring-side
   HAProxy frontend expects.
- `horde_service_alerts_upstream_basic_auth_*` is what the service-alerts
   middleman sends on its upstream requests.

There is no separate permission model behind the names; the distinction is
only server-side credential definition versus client-side credential use.
