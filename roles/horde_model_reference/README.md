# horde_model_reference Role

Deploys **horde-model-reference** — a FastAPI service that serves AI Horde model
metadata — as a Docker Compose stack managed by Ansible's
`community.docker.docker_compose_v2` module.

> **Scope:** This role targets the
> [horde-model-reference](https://github.com/Haidra-Org/horde-model-reference)
> service only.  It manages the FastAPI container, an optional Redis sidecar
> for multi-worker deployments, and an optional HAProxy conf.d fragment consistent with the other roles.

## How It Works

The role renders a `.env` file and a `docker-compose.yml` under
`horde_model_reference_base_dir` and optionally brings the stack up.

Service data (model JSON files) is persisted in
`horde_model_reference_data_dir` which is bind-mounted to `/data` inside the
container.

## Service Modes

| Mode | Description |
|---|---|
| `PRIMARY` | Authoritative source. Reads and writes model JSON from `/data`. Supports multi-worker with Redis. |
| `REPLICA` | Read-only mirror. If `horde_model_reference_primary_api_url` is set, fetches from PRIMARY and falls back to GitHub when unreachable. If unset, runs in GitHub-only mode (fetching directly from raw.githubusercontent.com). |

## Quick Start

```yaml
- hosts: horde_server
  become: true
  roles:
    - role: horde_model_reference
      vars:
        horde_model_reference_image: "ghcr.io/haidra-org/horde-model-reference:main"
        horde_model_reference_replicate_mode: PRIMARY
        horde_model_reference_github_seed_enabled: true   # first boot only
```

See `examples/horde_model_reference.yml` for a more complete example.

## Multi-Worker + Redis

In PRIMARY mode, workers > 1 requires Redis for distributed pub/sub cache invalidation:

```yaml
horde_model_reference_workers: 4
horde_model_reference_redis_enabled: true
```

The role enforces this constraint as a fail-fast guard for PRIMARY mode.

## REPLICA Without PRIMARY URL

REPLICA mode does not require a PRIMARY URL. Leaving
`horde_model_reference_primary_api_url` empty is valid and runs the service in
GitHub-only read mode.

## HAProxy conf.d

Set `horde_model_reference_haproxy_enabled: true` to drop an HAProxy
frontend/backend fragment into `/etc/haproxy/conf.d/`.  The fragment routes
requests to the configured `horde_model_reference_haproxy_hostnames` to the
local service.

## GitHub Sync (PRIMARY only)

Set `horde_model_reference_github_sync_enabled: true` to run the GitHub sync service as a
sidecar container (`scripts/sync/sync_github_references.py --watch`). It reads the PRIMARY
v1 API and opens pull requests against the legacy GitHub repos so clients that still read
GitHub stay in sync.

Requirements:

- **PRIMARY mode** (the role fails fast otherwise).
- **GitHub auth** — either a PAT (`horde_model_reference_github_sync_github_token`) **or**
  GitHub App installation auth (`horde_model_reference_github_app_id` +
  `_github_app_installation_id` + `_github_app_private_key`, all required). A GitHub App
  `client_id`/`client_secret` are **not** usable by the sync script.
- The sidecar reuses the API image, which now bundles the `sync` extra
  (PyGithub/GitPython). If you pin a custom image, ensure it includes that extra.

For safe testing, point the sync at a fork by overriding
`horde_model_reference_github_sync_image_repo_owner` (and the `_text_repo_owner`). The
PRIMARY URL **must** include the `/api` suffix.

## Variable Reference

| Variable | Default | Description |
|---|---|---|
| `horde_model_reference_image` | `ghcr.io/haidra-org/horde-model-reference:main` | Docker image to pull |
| `horde_model_reference_port` | `19800` | Host-side bind port |
| `horde_model_reference_listen` | `127.0.0.1` | Host-side bind address |
| `horde_model_reference_base_dir` | `/opt/horde-model-reference` | Compose project root |
| `horde_model_reference_data_dir` | `/var/lib/horde-model-reference` | Model data volume |
| `horde_model_reference_replicate_mode` | `PRIMARY` | `PRIMARY` or `REPLICA` |
| `horde_model_reference_primary_api_url` | `""` | PRIMARY URL (optional in REPLICA; empty = GitHub-only mode) |
| `horde_model_reference_canonical_format` | `v2` | `v2` or `LEGACY` |
| `horde_model_reference_cache_ttl_seconds` | `60` | In-memory cache TTL |
| `horde_model_reference_primary_api_timeout` | `10` | REPLICA fetch timeout to PRIMARY API |
| `horde_model_reference_horde_api_timeout` | `30` | Horde API timeout |
| `horde_model_reference_horde_api_cache_ttl` | `60` | Horde API cache TTL |
| `horde_model_reference_statistics_cache_ttl` | `300` | Statistics cache TTL |
| `horde_model_reference_deletion_risk_cache_ttl` | `300` | Deletion-risk cache TTL |
| `horde_model_reference_preferred_file_hosts` | `[huggingface.co]` | Preferred hosts for deletion-risk analysis |
| `horde_model_reference_workers` | `1` | uvicorn worker count |
| `horde_model_reference_redis_enabled` | `false` | Enable Redis sidecar |
| `horde_model_reference_redis_image` | `redis:7-alpine` | Redis image |
| `horde_model_reference_redis_url` | `redis://redis:6379/0` | Redis URL for the service |
| `horde_model_reference_redis_pool_size` | `10` | Redis connection pool size |
| `horde_model_reference_redis_socket_timeout` | `5` | Redis socket timeout (seconds) |
| `horde_model_reference_redis_socket_connect_timeout` | `5` | Redis connect timeout (seconds) |
| `horde_model_reference_redis_retry_max_attempts` | `3` | Redis retry attempts |
| `horde_model_reference_redis_retry_backoff_seconds` | `0.5` | Redis retry backoff |
| `horde_model_reference_redis_key_prefix` | `horde:model_ref` | Redis key namespace prefix |
| `horde_model_reference_redis_ttl_seconds` | `""` | Optional Redis TTL override (empty = inherit cache_ttl_seconds) |
| `horde_model_reference_github_seed_enabled` | `false` | Seed `/data` from GitHub on first boot |
| `horde_model_reference_make_folders` | `true` | Create `/data` hierarchy on startup |
| `horde_model_reference_enable_github_fallback` | `true` | REPLICA: fall back to GitHub |
| `horde_model_reference_cors_allowed_origins` | `[]` | CORS allowed origins list |
| `horde_model_reference_pending_queue_enabled` | `true` | PRIMARY write-pending queue enable flag (`HORDE_MODEL_REFERENCE_PENDING_QUEUE__ENABLED`) |
| `horde_model_reference_pending_queue_requestor_ids` | `[]` | Allowed requestor Horde user IDs |
| `horde_model_reference_pending_queue_approver_ids` | `[]` | Allowed approver Horde user IDs |
| `horde_model_reference_pending_queue_relative_subdir` | `pending_queue` | Pending queue storage subdirectory |
| `horde_model_reference_pending_queue_root_path_override` | `""` | Optional absolute pending queue storage path |
| `horde_model_reference_pending_queue_max_segment_bytes` | `5242880` | Pending queue segment size limit |
| `horde_model_reference_audit_enabled` | `true` | Enable audit trail writes |
| `horde_model_reference_audit_relative_subdir` | `audit` | Audit storage subdirectory |
| `horde_model_reference_audit_root_path_override` | `""` | Optional absolute audit storage path |
| `horde_model_reference_audit_max_segment_bytes` | `5242880` | Audit segment size limit |
| `horde_model_reference_cache_hydration_enabled` | `false` | Enable cache hydration background task |
| `horde_model_reference_cache_hydration_interval_seconds` | `240` | Cache hydration interval |
| `horde_model_reference_cache_hydration_stale_ttl_seconds` | `3600` | Stale cache max age |
| `horde_model_reference_cache_hydration_startup_delay_seconds` | `5` | Delay before first hydration run |
| `horde_model_reference_haproxy_enabled` | `false` | Enable HAProxy conf.d fragment |
| `horde_model_reference_haproxy_hostnames` | `[models.aihorde.net, models.stablehorde.net]` | Routed hostnames |
| `horde_model_reference_haproxy_frontend_port` | `80` | HAProxy frontend bind port |
| `horde_model_reference_github_sync_enabled` | `false` | Run the GitHub sync sidecar (PRIMARY only) |
| `horde_model_reference_github_sync_image` | `{{ horde_model_reference_image }}` | Sidecar image (must include the `sync` extra) |
| `horde_model_reference_github_sync_primary_api_url` | `http://model-reference:19800/api` | PRIMARY v1 API URL the sync reads (must end in `/api`) |
| `horde_model_reference_github_sync_categories` | `image_generation,text_generation` | Categories to sync (comma-separated; empty = all) |
| `horde_model_reference_github_sync_watch` | `true` | Run in continuous watch mode |
| `horde_model_reference_github_sync_watch_startup_sync` | `true` | Run one sync immediately on startup |
| `horde_model_reference_github_sync_watch_interval_seconds` | `60` | Watch-mode poll interval |
| `horde_model_reference_github_sync_min_changes_threshold` | `1` | Minimum changes before opening a PR |
| `horde_model_reference_github_sync_pr_labels` | `automated,sync,ready-for-review` | PR labels (comma-separated) |
| `horde_model_reference_github_sync_pr_reviewers` | `""` | PR reviewers (comma-separated) |
| `horde_model_reference_github_sync_image_repo_owner` | `Haidra-Org` | Image repo owner (override for fork testing) |
| `horde_model_reference_github_sync_image_repo_name` | `AI-Horde-image-model-reference` | Image repo name |
| `horde_model_reference_github_sync_image_repo_branch` | `main` | Image repo base branch |
| `horde_model_reference_github_sync_text_repo_owner` | `Haidra-Org` | Text repo owner (override for fork testing) |
| `horde_model_reference_github_sync_text_repo_name` | `AI-Horde-text-model-reference` | Text repo name |
| `horde_model_reference_github_sync_text_repo_branch` | `main` | Text repo base branch |
| `horde_model_reference_github_sync_github_token` | `""` | GitHub PAT (Contents + PRs R/W) |
| `horde_model_reference_github_app_id` | `""` | GitHub App ID (App auth) |
| `horde_model_reference_github_app_installation_id` | `""` | GitHub App installation ID (App auth) |
| `horde_model_reference_github_app_private_key` | `""` | GitHub App private key PEM (written to `github-app-key.pem`) |
| `horde_model_reference_otel_sdk_disabled` | `"true"` | OTel SDK disabled flag |
| `horde_model_reference_log_driver` | `journald` | Docker log driver |
| `horde_model_reference_start_services` | `true` | Pull and start stack |
| `horde_model_reference_extra_env_files` | `[]` | Extra env files to load |
| `horde_model_reference_env_overrides` | `{}` | Freeform env var overrides |

## Health Check

The role (and Docker Compose healthcheck) polls:

```
GET http://<listen>:<port>/api/heartbeat
→ {"status": "ok", "ai_horde": {"degraded": false, ...}}
```

The Ansible readiness check retries 30 times with a 5-second delay (150 s total).
