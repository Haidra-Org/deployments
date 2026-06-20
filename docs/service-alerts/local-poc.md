# Service-alerts local PoC / e2e runbook

Bring up the **ai-horde-service-alerts** stack — the FastAPI service, an
embedded Postgres sidecar, and the co-located **horde-status-prober** — on a
single Docker host and verify the full pipeline end to end:

```
prober → POST /internal/probe-results → status evaluator → component_status_history → public API
```

This is a self-contained subset of the full local stack. It does **not** need
Mimir/Alertmanager (so `/readyz` will report those upstreams as unavailable —
expected); the probe-driven path works without them.

## Prerequisites

- Docker (Engine + Compose v2) and the `community.docker` Ansible collection.
- This repo checked out, plus the sibling `horde-exporters` repo (the images
  are built from there). The monorepo layout assumes both are siblings under
  the same parent directory.
- Run all `ansible-playbook` commands from this repo's root.

## 1. Build the images

The PoC defaults to locally-built images so it exercises your working tree.
From the `horde-exporters` checkout:

```bash
cd ../horde-exporters/packages/ai-horde-service-alerts
docker build -f Dockerfile -t ai-horde-service-alerts:local .

cd ../horde-status-prober
docker build -f Dockerfile -t horde-status-prober:local .
```

> To test the published images instead, skip this step and pass
> `-e sa_poc_image=ghcr.io/haidra-org/ai-horde-service-alerts:main`
> `-e sa_poc_prober_image=ghcr.io/haidra-org/horde-status-prober:main` in step 2.

## 2. Render the stack

From the `deployments` repo root:

```bash
ANSIBLE_ROLES_PATH="$PWD/roles" \
  ansible-playbook -i "localhost," -c local tests/service_alerts/local_poc.yml
```

This renders `/tmp/service-alerts-poc/{.env,docker-compose.yml}` (render only —
`start_services=false`). Override defaults with `-e`, e.g.
`-e sa_poc_base_dir=/tmp/sa` or `-e sa_poc_pg_password=…`. The default dev
secrets are fine for a throwaway stack — **never** use them in production.

## 3. Bring it up

```bash
cd /tmp/service-alerts-poc
docker compose up -d
```

Compose starts Postgres, waits for it to be healthy, then the service (whose
entrypoint runs `alembic upgrade head`), then the prober once the service is
healthy. Confirm:

```bash
docker compose ps
docker logs horde-service-alerts | grep -i 'running upgrade\|Application startup'
```

## 4. Verify the pipeline

```bash
PGEXEC="docker exec horde-service-alerts-postgres psql -U horde_status -d horde_status -tAc"

# Prober pushed samples (expect 6 once the first probes fire, ~within 15s):
$PGEXEC "select probe_name, component_id, outcome from probe_results order by observed_at desc;"

# Service liveness:
curl -fsS http://127.0.0.1:19810/healthz        # {"status":"ok",...}

# Public status reflects live signal:
curl -fsS http://127.0.0.1:19810/api/v1/public/components | python3 -m json.tool

# Prober is healthy and pushing (0 consecutive failures):
docker exec horde-status-prober \
  python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8081/healthz',timeout=5).read().decode())"

# /readyz is 503 here because Alertmanager/Mimir are intentionally absent:
curl -s -o /dev/null -w "readyz: %{http_code}\n" http://127.0.0.1:19810/readyz
```

### Confirm Postgres data isolation (required)

The embedded Postgres must keep its data in a dedicated, stack-namespaced
Docker named volume — never a well-known host Postgres path:

```bash
docker volume inspect horde-service-alerts-pgdata --format '{{.Mountpoint}}'
# => /var/lib/docker/volumes/horde-service-alerts-pgdata/_data   (NOT /var/lib/postgresql*)
```

## 5. Tear down

```bash
cd /tmp/service-alerts-poc
docker compose down -v        # -v removes the named Postgres volume too
rm -rf /tmp/service-alerts-poc
```

## Related checks

- **Alembic migration parity** (schema ↔ ORM models) against a real Postgres:
  see `horde-exporters/packages/ai-horde-service-alerts/README.md` → *Tests*.
- **Role render / policy / data-path-isolation contracts**:
  `./tests/run_tests.sh service_alerts` (or run the playbooks under
  `tests/service_alerts/` directly).
