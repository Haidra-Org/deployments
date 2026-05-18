# Quick Start

## Fast Paths (TL;DR)

| If you are trying to...                                             | Do this                                                                                                   | Monitoring needed? |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------ |
| Quickly test an AI-Horde backend change (external contributor flow) | [`Test an AI-Horde code change`](#test-an-ai-horde-code-change)                                           | No                 |
| Validate user-facing behavior (backend + frontpage + edge routing)  | [`Run the full stack locally`](#run-the-full-stack-locally)                                               | Optional           |
| Validate observability (Grafana/Prometheus/Mimir/Loki/Tempo)        | [`Run the full stack locally`](#run-the-full-stack-locally) with `--with-monitoring` from a stopped stack | Yes                |
| Roll AI-Horde forward/backward to a specific ref                    | [`Update AI-Horde`](#update-ai-horde)                                                                     | No                 |

---

## Prerequisites

All local workflows require:

- **Docker** with **Compose V2**: `docker compose version` should print `v2.x+`
- **git**

Your user must be able to run Docker commands. Local deploy scripts also touch
generated runtime directories and may use `sudo` during cleanup; production
playbooks use Ansible `become` for host configuration such as packages,
systemd, `/opt`, and `/var/lib` paths.

Local workflows also need **Ansible**, which we suggest installing in a Python virtual environment to avoid polluting your system Python:

```bash
git clone https://github.com/Haidra-Org/deployments.git
cd deployments

# Create the venv and install Ansible (one-time)
python3 -m venv .venv
source .venv/bin/activate
pip install ansible
```

If the `.venv` already exists, just activate it:

```bash
source .venv/bin/activate
```

> **Troubleshooting Windows Docker credential helper**
>
> If `docker build` fails with `fork/exec docker-credential-desktop.exe:
exec format error`, your Docker config references a credential helper
> that doesn't exist on this machine. Fix it:
>
> ```bash
> # Back up and reset
> cp ~/.docker/config.json ~/.docker/config.json.bak
> echo '{}' > ~/.docker/config.json
> ```

## Local Deploy Layout

- `local-deploy/static/` contains git-tracked committed files used by local deploy scripts.
- `local-deploy/runtime/` contains generated configs, cloned sources, and runtime data.

To reset local state safely:

```bash
rm -rf local-deploy/runtime
```

---

## Test an AI-Horde code change

The minimal local stack requires only AI-Horde (Flask API), PostgreSQL, and Redis, and is
enough to verify most backend changes. You do not need frontpage, HAProxy, or
monitoring for this workflow.

### Start the backend

```bash
cd deployments
./tests/ai_horde/local_deploy.sh up --latest
```

This clones the latest AI-Horde source, builds the Docker image, and starts
the three-container stack. When you see the banner, it's ready:

```
AI-Horde API    →  http://localhost:7001/api/
Heartbeat       →  http://localhost:7001/api/v2/status/heartbeat
```

### Verify

```bash
curl -sf http://localhost:7001/api/v2/status/heartbeat && break

# {"message": "OK", "version": "4.48.3", ...}
```

### Iterate on code

The source is cloned to `local-deploy/runtime/ai-horde/src/`. Edit files there,
then rebuild and restart:

```bash
# Edit your code
vim local-deploy/runtime/ai-horde/src/horde/routes.py    # or whatever you changed

# Rebuild the Docker image and restart
docker compose -f local-deploy/runtime/ai-horde/docker-compose.yml build
docker compose -f local-deploy/runtime/ai-horde/docker-compose.yml up -d

# Verify your change (service may take a few seconds to accept traffic)
curl -sf http://localhost:7001/api/v2/status/heartbeat && break
```

### Stop the stack

```bash
./tests/ai_horde/local_deploy.sh down
```

### Use a specific branch

To test a branch other than `main`:

```bash
AI_HORDE_REF=my-feature-branch ./tests/ai_horde/local_deploy.sh up --latest
```

When `AI_HORDE_REF` is set, that explicit ref is used. If `AI_HORDE_REF` is
not set, `--latest` follows `main`.

### Use your fork as the implementation source

To test your own repository fork:

```bash
AI_HORDE_REPO=https://github.com/<your-username>/AI-Horde.git \
AI_HORDE_REF=<branch-or-tag-or-sha> \
./tests/ai_horde/local_deploy.sh up --latest
```

### Use your local checkout

If you want to test uncommitted local changes, copy your checkout into the
local deploy source tree, then rebuild:

```bash
# Copy your working tree (avoid symlinking to avoid unintentional edits during ansible cleanup)
rm -rf local-deploy/runtime/ai-horde/src
cp -a /path/to/your/AI-Horde local-deploy/runtime/ai-horde/src
# or rsync if you want to preserve the local-deploy source as a base and overlay your changes:
rsync -a --exclude='.git' /path/to/your/AI-Horde/ local-deploy/runtime/ai-horde/src/

# Rebuild + restart
docker compose -f local-deploy/runtime/ai-horde/docker-compose.yml build
docker compose -f local-deploy/runtime/ai-horde/docker-compose.yml up -d
```

---

## Update AI-Horde

This section is for "I changed AI-Horde software and need to retest/redeploy"
without changing Ansible role code.

### Local update to latest `main`

```bash
./tests/ai_horde/local_deploy.sh down
./tests/ai_horde/local_deploy.sh up --latest
```

### Local update to a specific ref (branch/tag/SHA)

```bash
AI_HORDE_REF=<branch-or-tag-or-sha> ./tests/ai_horde/local_deploy.sh up
```

### Local update from a fork/source override

```bash
AI_HORDE_REPO=https://github.com/<your-username>/AI-Horde.git \
AI_HORDE_REF=<branch-or-tag-or-sha> \
./tests/ai_horde/local_deploy.sh up --latest
```

### Update a real host to a specific ref

```bash
ansible-playbook -i my_inventory.yml examples/ai_horde.yml \
  -e ai_horde_repo_version=<branch-or-tag-or-sha>
```

To deploy from your fork on a real host:

```bash
ansible-playbook -i my_inventory.yml examples/ai_horde.yml \
  -e ai_horde_repo=https://github.com/<your-username>/AI-Horde.git \
  -e ai_horde_repo_version=<branch-or-tag-or-sha>
```

Then verify:

```bash
curl http://<your-host-or-ingress>/api/v2/status/heartbeat
```

---

## Run the full stack locally

Brings up the complete local development stack — Backend (API + Postgres + Redis),
AiHordeFrontpage, and HAProxy as the edge router — matching the local development topology.
Monitoring is optional and can be enabled as an extra tier.

### Start the stack

```bash
./tests/full_stack/local_deploy.sh up --latest
```

### Port assignments

| Service               | URL                                      | Notes                              |
| --------------------- | ---------------------------------------- | ---------------------------------- |
| HAProxy (edge)        | http://localhost/                        | Routes to frontpage or API by path |
| AI-Horde API          | http://localhost/api/v2/status/heartbeat | Via HAProxy                        |
| AI-Horde API (direct) | http://localhost:7001                    | Bypasses HAProxy                   |
| AiHordeFrontpage      | http://localhost:8006                    | Also served via HAProxy at `/`     |
| HAProxy stats         | http://localhost:8404/stats              | HAProxy dashboard                  |

### Verify

```bash
curl -s http://localhost/ | head -3           # Frontpage HTML
curl http://localhost/api/v2/status/heartbeat  # API via HAProxy
```

### Optional components

```bash
# Start with monitoring from a stopped stack
./tests/full_stack/local_deploy.sh down
./tests/full_stack/local_deploy.sh up --latest --with-monitoring

# Add everything (monitoring + artbot + worker placeholder)
./tests/full_stack/local_deploy.sh down
./tests/full_stack/local_deploy.sh up --latest --all
```

If this is your first startup, you can include flags in the initial `up`
command directly.

### Status and logs

```bash
./tests/full_stack/local_deploy.sh status           # Container health
./tests/full_stack/local_deploy.sh logs backend      # Backend logs
./tests/full_stack/local_deploy.sh logs frontpage    # Frontpage logs
./tests/full_stack/local_deploy.sh logs haproxy      # HAProxy logs
```

### Stop the stack

```bash
./tests/full_stack/local_deploy.sh down
```

### Troubleshooting: container-name conflicts

If startup fails with `... container name ... is already in use`, remove stale
monitoring containers from older runs and retry:

```bash
./tests/full_stack/local_deploy.sh down
./tests/full_stack/local_deploy.sh up --latest --with-monitoring
```

By default, `tests/full_stack/local_deploy.sh` auto-cleans stale known
monitoring container names before starting monitoring.

If you disabled auto-clean with
`HORDE_FULLSTACK_AUTO_CLEAN_MONITORING_CONFLICTS=false`, either re-enable it
or clean conflicts manually with:

```bash
docker rm -f s3-store s3-init memcached mimir grafana loki tempo pyroscope \
  alertmanager prometheus horde-exporter alloy 2>/dev/null || true
```

---

## Run the Ansible test suite

Render tests validate template output, variable defaults, fail-fast guards,
and idempotency. They run inside ephemeral Docker containers — no services
are started.

### List available tests

```bash
./tests/run_tests.sh --list
```

### Run tests for a role

```bash
./tests/run_tests.sh ai_horde
./tests/run_tests.sh monitoring
./tests/run_tests.sh frontpage
./tests/run_tests.sh artbot
./tests/run_tests.sh regen_worker
./tests/run_tests.sh full_stack
./tests/run_tests.sh integration

# A single playbook
./tests/run_tests.sh monitoring/test_full_stack

# Everything
./tests/run_tests.sh
```

### Read the results

The runner prints a summary table at the end:

```
TEST                                        STATUS  DETAILS
────────────────────────────────────────────────────────────
ai_horde/test_ai_horde_render.yml           PASS
ai_horde/test_ai_horde_native_render.yml    PASS
────────────────────────────────────────────────────────────
Results: 5 passed, 0 failed, 0 skipped
```

Full logs are written to `tests/test-results/<YYYYMMDD-HHMMSS>/`:

```bash
# View the latest summary
cat tests/test-results/$(ls -t tests/test-results/ | head -1)/summary.txt

# View a specific test log
cat tests/test-results/$(ls -t tests/test-results/ | head -1)/ai_horde__test_ai_horde_render.log
```

---

## Deploy to a real host

This uses Ansible to deploy to remote hosts over SSH. See the main
[README](README.md#usage) for full details. The short version:

### 1. Install the collection

```bash
pip install ansible
wget https://raw.githubusercontent.com/Haidra-Org/deployments/main/examples/requirements.yml
ansible-galaxy collection install -r requirements.yml
```

### 2. Write an inventory

Start from the template:

```bash
cp examples/inventory.yml my_inventory.yml
# Edit my_inventory.yml — set your hostnames, passwords, and secrets
```

At minimum, set:

```yaml
all:
  children:
    horde_server:
      hosts:
        your-server:
          ansible_host: 1.2.3.4
          ai_horde_postgres_password: "change-me"
          ai_horde_secret_key: "change-me"
```

### 3. Deploy

```bash
# Dry run (no changes, just show what would happen)
ansible-playbook -i my_inventory.yml examples/ai_horde.yml --check --diff

# Deploy for real
ansible-playbook -i my_inventory.yml examples/ai_horde.yml
```

### Adding monitoring

Monitoring is optional and independent — it can be added at any time and
runs on a separate host:

- See [MONITORING.md](MONITORING.md) for architecture and quick start
- Use `examples/horde_monitoring_stack.yml` as the playbook
- Use `examples/inventory_monitoring.yml` as the inventory template

---

## Reference

| I want to...                      | Start here                                                       |
| --------------------------------- | ---------------------------------------------------------------- |
| Test an AI-Horde code change      | [Test a code change](#test-an-ai-horde-code-change)              |
| Run the full stack locally        | [Full stack](#run-the-full-stack-locally)                        |
| Validate Ansible role changes     | [Test suite](#run-the-ansible-test-suite)                        |
| Deploy to a real server           | [Deploy to a host](#deploy-to-a-real-host)                       |
| Set up monitoring                 | [MONITORING.md](MONITORING.md)                                   |
| Understand the project structure  | [README.md](README.md)                                           |
| Contribute to this repo           | [CONTRIBUTING.md](CONTRIBUTING.md)                               |
| Upgrade a deployed component      | [docs/UPGRADING.md](docs/monitoring/UPGRADING.md)                |
| Back up / restore monitoring data | [docs/monitoring/BACKUP.md](docs/monitoring/BACKUP.md)           |
| Manage credentials and rotation   | [docs/monitoring/CREDENTIALS.md](docs/monitoring/CREDENTIALS.md) |
