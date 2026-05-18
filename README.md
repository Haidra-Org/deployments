# Haidra Deployments

Ansible collection for deploying Haidra authored services, AI Horde workers, monitoring
infrastructure, and supporting applications.

> **New here?** Start with the [Quick Start guide](QUICKSTART.md) — test an
> AI-Horde code change in ~4 minutes or run the full stack locally in ~6.
> **Want to contribute?** See [CONTRIBUTING.md](CONTRIBUTING.md).

- [Haidra Deployments](#haidra-deployments)
    - [Scope and Audience](#scope-and-audience)
        - [Non-goals](#non-goals)
    - [Usage](#usage)
    - [Privilege Model](#privilege-model)
    - [Included Roles](#included-roles)
        - [Application Roles](#application-roles)
        - [Monitoring Roles](#monitoring-roles)
    - [Documentation](#documentation)
    - [Role Testing](#role-testing)
        - [Render tests (fast, no services started)](#render-tests-fast-no-services-started)
            - [Test output and logs](#test-output-and-logs)
            - [Playbook markers](#playbook-markers)
        - [Integration tests (requires Docker)](#integration-tests-requires-docker)
        - [Test coverage by role](#test-coverage-by-role)
    - [Full-stack local deploy](#full-stack-local-deploy)



## Scope and Audience

This collection is intentionally opinionated and is not a general-purpose
Ansible toolkit. It targets three audiences:

1. The AI Horde team operating the stack.
2. Developers contributing to AI Horde services.
3. External groups adopting or vendoring the AI Horde stack and seeking reference deployment patterns.

### Non-goals

- Generic, vendor-neutral deployment abstractions for arbitrary software.
- Replacing mature community roles for broad infrastructure concerns.
- Hiding stack assumptions required by AI Horde topology and workflows.

In short, if you are looking for a general Ansible collection for deploying the software therein, this is not it. If you are looking for a reference deployment for the AI Horde stack, this is exactly it.

## Usage

Install [Ansible](https://www.ansible.com/) (Linux only):

```bash
python -m pip install ansible
```

Ensure your control host can SSH to targets using key-based authentication via
an ssh-agent. If the remote user requires a sudo password, append `-K` to all
`ansible-playbook` commands.

Install this collection and its dependencies:

```bash
wget https://raw.githubusercontent.com/Haidra-Org/deployments/main/examples/requirements.yml
ansible-galaxy collection install -r requirements.yml
```

## Privilege Model

Most roles in this collection are host-configuration roles. They create system
users, write files under `/opt`, `/var/lib`, `/etc/systemd/system`, and
`/etc/logrotate.d`, install packages, and in Docker-backed roles manage Compose
projects through the host Docker daemon. Run deployment playbooks with
`become: true` or an equivalent privileged remote account.

That elevated access is for host bootstrap and service management, not for the
application processes themselves. Roles should run long-lived services as
dedicated unprivileged users or containers wherever the underlying service
allows it, keep secrets in root-readable files when bind-mounted by Docker, and
avoid granting service users sudo access unless a role documents a specific
reason.

The test harness follows the same model inside disposable containers. Container
tests connect as `root` to privileged systemd test containers so Ansible can
exercise package, systemd, ownership, and Docker-rendering behavior without
depending on the user or UID running the tests on the control machine.

## Included Roles

Each role provides its own README with full variable documentation and examples.
Adjust an [example inventory](examples/) with your hostnames, then run the
corresponding example playbook — or build your own `site.yml`.

### Application Roles

| Role                                                           | Description                                  |
| -------------------------------------------------------------- | -------------------------------------------- |
| [ai_horde](roles/ai_horde/README.md)                           | AI Horde backend (Flask + Postgres + Redis)  |
| [aihorde_frontpage](roles/aihorde_frontpage/README.md)         | AiHordeFrontpage (Angular SSR website)       |
| [horde_model_reference](roles/horde_model_reference/README.md) | FastAPI service for AI Horde model metadata  |
| [artbot](roles/artbot/README.md)                               | Web frontend for AI Horde                    |
| [artbot_revproxy](roles/artbot_revproxy/README.md)             | HAProxy reverse proxy for Artbot             |
| [horde_regen_worker](roles/horde_regen_worker/README.md)       | AI Horde worker (Dreamer, Scribe, Alchemist) |
| [amd_gpu_drivers](roles/amd_gpu_drivers/README.md)             | AMD GPU driver and ROCm setup                |

### Monitoring Roles

| Role                                                         | Description                                                    |
| ------------------------------------------------------------ | -------------------------------------------------------------- |
| [horde_monitoring](roles/horde_monitoring/README.md)         | Mimir + Grafana + S3 storage monitoring stack (Docker Compose) |
| [horde_stats_exporter](roles/horde_stats_exporter/README.md) | AI Horde API → Prometheus metrics exporter                     |
| [horde_alloy](roles/horde_alloy/README.md)                   | Grafana Alloy telemetry collector for app hosts                |

See [MONITORING.md](MONITORING.md) for the architecture overview, quick start,
and how the monitoring roles work together.

## Documentation

| Document                                                | Contents                                                        |
| ------------------------------------------------------- | --------------------------------------------------------------- |
| [Quick Start](QUICKSTART.md)                            | Get running in minutes — 4 tiers from code change to production |
| [Contributing](CONTRIBUTING.md)                         | Dev setup, test conventions, PR guidelines                      |
| [Monitoring Guide](MONITORING.md)                       | Architecture, quick start, troubleshooting                      |
| [Observability Stack](docs/monitoring/OBSERVABILITY.md) | Loki, Tempo, and Alloy deep-dive                                |
| [Backup & Restore](docs/monitoring/BACKUP.md)           | RPO/RTO, backup configuration, restore procedures               |
| [Credentials](docs/monitoring/CREDENTIALS.md)           | Credential management and rotation                              |
| [Upgrading](docs/monitoring/UPGRADING.md)               | Component version upgrade procedures                            |
| [Migration](docs/monitoring/MIGRATION.md)               | Host migration runbook (planned and forced)                     |

## Role Testing

The collection ships a two-tier test suite under `tests/`.

### Render tests (fast, no services started)

Validate Ansible template rendering, variable defaults, and negative
(expected-failure) cases. These tests run against disposable privileged systemd
containers and write files inside those containers, but they do not start the
rendered application services. A Docker daemon is not required inside the target
container unless the playbook declares `# requires: docker-daemon`.

```bash
# All render tests (builds a Docker systemd container per test):
./tests/run_tests.sh

# List all discoverable tests without running them:
./tests/run_tests.sh --list

# By role:
./tests/run_tests.sh monitoring
./tests/run_tests.sh ai_horde
./tests/run_tests.sh regen_worker
./tests/run_tests.sh artbot
./tests/run_tests.sh frontpage
./tests/run_tests.sh full_stack

# Specific test:
./tests/run_tests.sh monitoring/test_full_stack
```

#### Test output and logs

Every `run_tests.sh` invocation writes per-test log files and a structured
summary under `tests/test-results/<YYYYMMDD-HHMMSS>/`:

```
tests/test-results/20260325-143012/
├── monitoring__test_full_stack.log               # full Ansible output
├── monitoring__test_full_stack__idempotency.log   # idempotency re-run
├── monitoring__test_runtime_services.log
├── ai_horde__test_deploy.log
└── summary.txt                                   # machine-readable results
```

The runner prints a colour-coded summary table at the end with one-line
failure reasons extracted from the Ansible output:

```
TEST                                                STATUS  DETAILS
────────────────────────────────────────────────────────────────────────────
monitoring/test_full_stack                          PASS
ai_horde/test_deploy                                FAIL    {"msg": "No package matching 'python3-venv'"}
────────────────────────────────────────────────────────────────────────────
```

`summary.txt` is pipe-delimited for scripted analysis:

```
# FORMAT: STATUS | LABEL | LOG_FILE | REASON
PASS | monitoring/test_full_stack | monitoring__test_full_stack.log |
FAIL | ai_horde/test_deploy | ai_horde__test_deploy.log | {"msg": "No package matching..."}
```

Every playbook (except runtime and local_deploy tests) is automatically
re-run after the first pass; the idempotency check fails the test if any
task reports `changed` on the second run.

#### Playbook markers

Test playbooks support YAML comment markers near the top of the file
(within the first 5 lines) to control runner behaviour:

| Marker                      | Effect                                                              |
| --------------------------- | ------------------------------------------------------------------- |
| `# idempotency: skip`       | Skip the idempotency re-run for this test                           |
| `# requires: docker-daemon` | Skip the entire test when the target container has no Docker daemon |

Multi-play tests that intentionally overwrite the same files with different
variable sets (e.g. `test_alloy_role.yml`) should declare `# idempotency: skip`.

### Integration tests (requires Docker)

Exercise cross-role coherence and optionally spin up live services.

```bash
# Smoke test — config-only, CI-friendly:
./tests/run_tests.sh integration

# Local deploy — starts AI-Horde in Docker:
./tests/integration/local_deploy.sh up
./tests/integration/local_deploy.sh down

# With GPU worker (requires NVIDIA GPU + nvidia-container-toolkit):
./tests/integration/local_deploy.sh up --with-worker
```

### Test coverage by role

| Role                 | Render | Negative | Integration | Full-stack |
| -------------------- | :----: | :------: | :---------: | :--------: |
| horde_monitoring     |   ✅   |    ✅    |      —      |     ✅     |
| ai_horde             |   ✅   |    ✅    |     ✅      |     ✅     |
| aihorde_frontpage    |   ✅   |    —     |      —      |     ✅     |
| horde_regen_worker   |   ✅   |    —     |     ✅      |     —      |
| artbot / revproxy    |   ✅   |    —     |      —      |     —      |
| horde_stats_exporter |   —    |    —     |      —      |     ✅     |
| horde_alloy          |   —    |    —     |      —      |     —      |


## Full-stack local deploy

> See also the [Quick Start](QUICKSTART.md#full-stack-local-deploy) for a use-case driven introduction.

Spins up the complete Horde business stack on one machine: Backend (AI-Horde +
Postgres + Redis), Frontend (AiHordeFrontpage), Stats Exporter, and HAProxy as
the unified edge router. Monitoring and the GPU worker are optional tiers.

```bash
# Core stack (backend + frontpage + exporter + HAProxy):
./tests/full_stack/local_deploy.sh up

# With monitoring (Grafana, Mimir, Prometheus, Alertmanager, Alloy):
./tests/full_stack/local_deploy.sh up --with-monitoring

# With GPU worker (requires NVIDIA GPU):
./tests/full_stack/local_deploy.sh up --with-worker

# With Artbot on a separate port (8080):
./tests/full_stack/local_deploy.sh up --with-artbot

# Everything:
./tests/full_stack/local_deploy.sh up --all

# Tear down (unconditional — stops all tiers):
./tests/full_stack/local_deploy.sh down

# Status:
./tests/full_stack/local_deploy.sh status

# Logs for a specific tier:
./tests/full_stack/local_deploy.sh logs backend
./tests/full_stack/local_deploy.sh logs frontpage
./tests/full_stack/local_deploy.sh logs haproxy
./tests/full_stack/local_deploy.sh logs monitoring
./tests/full_stack/local_deploy.sh logs artbot
```

**Local-deploy layout:**

- `local-deploy/static/` contains committed overlays/config files used by local deploy scripts.
- `local-deploy/runtime/` contains generated configs, cloned sources, and runtime data.

Reset local deploy state safely:

```bash
rm -rf local-deploy/runtime
```

**Port assignments (full-stack local deploy):**

| Service          | Port | Notes                                |
| ---------------- | ---- | ------------------------------------ |
| HAProxy (main)   | 80   | Unified edge router                  |
| HAProxy stats    | 8404 | http://localhost:8404/stats          |
| AiHordeFrontpage | 8006 | Angular SSR (also via HAProxy on 80) |
| AI-Horde API     | 7001 | Direct; also via /api on port 80     |
| Stats Exporter   | 9109 | Prometheus metrics                   |
| Grafana          | 3000 | Monitoring dashboards                |
| Prometheus       | 9090 | Metrics collection                   |
| Artbot HAProxy   | 8080 | Artbot site (`--with-artbot`)        |

