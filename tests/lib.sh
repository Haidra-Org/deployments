#!/usr/bin/env bash
# tests/lib.sh — Shared functions for local_deploy.sh scripts.
# Source this from individual deploy scripts after setting REPO_ROOT.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
#   source "$REPO_ROOT/tests/lib.sh"

# ── Colours ──────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
info() { printf "${CYAN}[i]${NC} %s\n" "$*"; }

# ── Prerequisites ───────────────────────────────────────────
# Usage: check_prerequisites [extra_cmd ...]
#   Always checks docker, curl, docker compose.
#   Pass additional commands as arguments (e.g. git, python3).
check_prerequisites() {
  local missing=0
  local extra_cmds=("$@")
  for cmd in docker curl "${extra_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command not found: $cmd"
      missing=$((missing + 1))
    fi
  done
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose V2 plugin is required."
    missing=$((missing + 1))
  fi
  if [ $missing -gt 0 ]; then
    err "$missing prerequisite(s) missing — cannot continue."
    exit 1
  fi
  log "Prerequisites verified."
}

# ── Ansible discovery ────────────────────────────────────────
# Sets ANSIBLE_PLAYBOOK to the best available ansible-playbook binary.
# Requires REPO_ROOT to be set.
find_ansible() {
  if [ -x "$REPO_ROOT/.venv/bin/ansible-playbook" ]; then
    ANSIBLE_PLAYBOOK="$REPO_ROOT/.venv/bin/ansible-playbook"
  else
    ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"
  fi
  if [ -z "${ANSIBLE_PLAYBOOK:-}" ]; then
    err "ansible-playbook not found. Install Ansible or create a venv at $REPO_ROOT/.venv"
    exit 1
  fi
}

# ── URL health probe ────────────────────────────────────────
# Usage: wait_for_url <url> <label> [timeout_secs=60]
wait_for_url() {
  local url="$1" label="$2" timeout="${3:-60}"
  local retries=$(( timeout / 2 ))
  while [ $retries -gt 0 ]; do
    if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
      log "$label is ready."
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  warn "$label did not become ready within ${timeout}s"
  return 1
}

# ── Environment loader ──────────────────────────────────────
# Usage: load_env <env_file>
load_env() {
  local env_file="${1:?load_env requires a file path}"
  if [ ! -f "$env_file" ]; then
    err "Environment file not found at $env_file — did render_configs fail?"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  log "Loaded environment from $env_file"
}

# ── Compose helpers ─────────────────────────────────────────
# These expect a dc() wrapper to be defined by the calling script.

compose_down() {
  local root_dir="${1:?compose_down requires a directory}"
  local project="${2:-}"

  # Prefer dc() if available AND the compose file still exists. Otherwise
  # fall back to a project-name-only invocation so orphan containers can
  # still be cleaned up after a partial / repeated teardown.
  local dc_ran=false
  if type dc &>/dev/null && [ -f "${COMPOSE_DIR:-$root_dir}/docker-compose.yml" ]; then
    if dc down -v --remove-orphans; then
      dc_ran=true
    else
      warn "dc down reported an error; will attempt project-only fallback."
    fi
  fi
  if [ "$dc_ran" = false ] && [ -n "$project" ]; then
    if docker compose --project-name "$project" ps --quiet 2>/dev/null | grep -q .; then
      log "Tearing down compose project '$project' (compose file unavailable) ..."
      docker compose --project-name "$project" down -v --remove-orphans \
        || warn "docker compose down for project '$project' returned non-zero."
    fi
  fi

  if [ -d "$root_dir" ]; then
    log "Removing $root_dir ..."
    sudo rm -rf "$root_dir"
    # Restore any git-tracked files that lived inside the directory.
    git -C "$REPO_ROOT" checkout -- "$root_dir" 2>/dev/null || true
  fi
  log "Local deployment cleaned up."
}

# ── Orphan-name conflict cleanup ────────────────────────────
# Usage: cleanup_known_container_name_conflicts <project> <name1> [name2 ...]
#
# Some compose templates use fixed `container_name:` values (e.g. mimir,
# grafana). When a previous run was associated with a *different* compose
# project (e.g. `horde-monitoring` vs the directory-default `compose`),
# `docker compose up` will fail with a name-collision error before the
# stack starts. Detect such orphans (containers with one of the known
# names whose compose-project label does NOT match <project>) and remove
# them. Set HORDE_AUTO_CLEAN_ORPHANS=false to require manual intervention
# instead.
cleanup_known_container_name_conflicts() {
  local project="${1:?project name required}"
  shift
  local auto_clean="${HORDE_AUTO_CLEAN_ORPHANS:-true}"
  local -a conflicts=()
  local name container_project

  for name in "$@"; do
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
      container_project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)
      if [ "$container_project" != "$project" ]; then
        conflicts+=("$name")
      fi
    fi
  done

  if [ "${#conflicts[@]}" -eq 0 ]; then
    return 0
  fi

  warn "Found containers with names that conflict with project '$project': ${conflicts[*]}"
  if [ "$auto_clean" != "true" ]; then
    err "Auto-clean disabled (HORDE_AUTO_CLEAN_ORPHANS=$auto_clean)."
    err "Remove the conflicting containers manually, or rerun with HORDE_AUTO_CLEAN_ORPHANS=true."
    return 1
  fi

  warn "Removing conflicting containers before startup ..."
  if ! docker rm -f "${conflicts[@]}" >/dev/null 2>&1; then
    err "Failed to remove one or more conflicting containers: ${conflicts[*]}"
    return 1
  fi
  log "Removed conflicting containers: ${conflicts[*]}"
}

compose_status() {
  local compose_file="${1:-docker-compose.yml}"
  if [ ! -f "$compose_file" ]; then
    info "No local deployment found."
    return
  fi
  dc ps
}

compose_logs() {
  local compose_file="${1:-docker-compose.yml}"
  if [ ! -f "$compose_file" ]; then
    err "No local deployment found."
    exit 1
  fi
  dc logs -f --tail=100
}

# ── Source checkout ──────────────────────────────────────────
# Usage: sync_local_source <local_src_dir> <dest_dir> <label>
#
# Mirrors a local working tree into <dest_dir> using rsync, replacing
# any existing checkout there.  Excludes .git, virtualenvs, caches, and
# common build artefacts so the build context stays small.  Used by the
# full-stack local deploy when AI_HORDE_LOCAL_SRC / FRONTPAGE_LOCAL_SRC
# (or --local-* flags) are set, allowing in-progress, unpushed local
# changes to flow into the rebuilt container image.
sync_local_source() {
  local src="$1" dest="$2" label="$3"
  if [ ! -d "$src" ]; then
    err "$label local source path does not exist: $src"
    exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    err "rsync is required for --local-* source overrides; please install it."
    exit 1
  fi
  log "Syncing $label local source from $src -> $dest ..."
  mkdir -p "$dest"
  rsync -a --delete \
    --exclude='.git/' \
    --exclude='.venv/' \
    --exclude='venv/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='.pytest_cache/' \
    --exclude='.mypy_cache/' \
    --exclude='.ruff_cache/' \
    --exclude='node_modules/' \
    --exclude='dist/' \
    --exclude='build/' \
    --exclude='.tox/' \
    "$src"/ "$dest"/
}

# Usage: clone_or_update_source <repo_url> <dest_dir> <ref>
clone_or_update_source() {
  local repo_url="$1" dest_dir="$2" ref="$3"
  local target_ref="$ref"
  if [ -d "$dest_dir/.git" ]; then
    local current_origin
    current_origin="$(git -C "$dest_dir" remote get-url origin 2>/dev/null || true)"
    if [ "$current_origin" != "$repo_url" ]; then
      warn "Source remote changed for $dest_dir"
      warn "  old: ${current_origin:-<none>}"
      warn "  new: $repo_url"
      warn "Recloning to match requested repository."
      rm -rf "$dest_dir"
      log "Cloning $repo_url into $dest_dir (ref: $ref) ..."
      git clone "$repo_url" "$dest_dir"
      git -C "$dest_dir" checkout --quiet "$ref"
      git -C "$dest_dir" submodule update --init --recursive --quiet
      return 0
    fi

    log "Updating source in $dest_dir to ref: $ref ..."
    git -C "$dest_dir" fetch --quiet --tags --prune origin

    if git -C "$dest_dir" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
      # If ref is a branch, track and hard-sync to the latest remote head.
      target_ref="origin/$ref"
      git -C "$dest_dir" checkout --quiet -B "$ref" "$target_ref"
    else
      git -C "$dest_dir" checkout --quiet "$ref"
    fi

    git -C "$dest_dir" reset --hard "$target_ref" >/dev/null
  else
    log "Cloning $repo_url into $dest_dir (ref: $ref) ..."
    git clone "$repo_url" "$dest_dir"
    git -C "$dest_dir" fetch --quiet --tags --prune origin

    if git -C "$dest_dir" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
      target_ref="origin/$ref"
      git -C "$dest_dir" checkout --quiet -B "$ref" "$target_ref"
    else
      git -C "$dest_dir" checkout --quiet "$ref"
    fi
  fi

  # Initialise submodules (no-op for repos without .gitmodules).
  git -C "$dest_dir" submodule update --init --recursive --quiet
}

# ── Dockerfile patching (Docker Desktop workarounds) ────────
# Fixes two known issues when running with USE_LATEST_REF=true:
#   1) Docker Desktop can cache corrupt layers for unqualified slim tags.
#   2) The run stage uses --no-index but needs network for git+https deps.
#
# This function MUTATES the upstream Dockerfile in-place. It is only
# called when the operator opts in via USE_LATEST_REF(S)=true, or when
# an explicit ref/repository is requested by the operator.
_patch_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0

  local patched=0

  # Fix 1: broken base image
  local base_img
  base_img=$(grep -m1 '^FROM.*python.*slim' "$dockerfile" | awk '{print $2}' || true)
  if [ -n "$base_img" ]; then
    if ! docker run --rm "$base_img" true >/dev/null 2>&1; then
      local fixed_img="${base_img}-bookworm"
      warn "Base image $base_img is broken (exec format error). Switching to $fixed_img."
      sed -i "s|FROM ${base_img}|FROM ${fixed_img}|g" "$dockerfile"
      patched=$((patched + 1))
    fi
  fi

  # Fix 2: run-stage pip needs network access for git+https dependencies
  if grep -q '\-\-no-index' "$dockerfile" && grep -q 'git+https' "$(dirname "$dockerfile")/requirements.txt" 2>/dev/null; then
    warn "Removing --no-index from run-stage pip install (git deps need PyPI)."
    sed -i 's/--no-cache-dir --no-index --find-links=\/wheels\//--no-cache-dir --find-links=\/wheels\//' "$dockerfile"
    patched=$((patched + 1))
  fi

  if [ "$patched" -gt 0 ]; then
    warn "──── UPSTREAM SOURCE MODIFIED ────"
    warn "  File:    $dockerfile"
    warn "  Patches: $patched applied"
    warn "  Reason:  Docker Desktop / latest-ref compatibility"
    warn "  To avoid: use pinned refs (omit --latest)"
    warn "─────────────────────────────────"
  fi
}

# ── Embedded Garage bootstrap ───────────────────────────────
# These functions bootstrap an embedded Garage S3 store for local-deploy
# stacks. They are shared by monitoring and AI-Horde local-deploy scripts.
#
# Required env vars (loaded from local-deploy.env):
#   GARAGE_S3_ACCESS_KEY_ID, GARAGE_S3_ACCESS_KEY_NAME,
#   GARAGE_S3_SECRET_KEY_FILE, GARAGE_S3_ADMIN_PORT,
#   GARAGE_S3_CAPACITY_BYTES
# Bucket env vars are optional, but at least one should usually be set:
#   GARAGE_S3_BLOCKS_BUCKET, GARAGE_S3_RULER_BUCKET,
#   GARAGE_S3_ALERTMANAGER_BUCKET, GARAGE_S3_AIHORDE_BUCKET
# Optional: GARAGE_S3_LOKI_BUCKET, GARAGE_S3_TEMPO_BUCKET,
#   GARAGE_S3_PYROSCOPE_BUCKET, GARAGE_S3_ACCESS_KEY_SUFFIX_FILE

garage_exec() {
  docker exec s3-store /garage -c /etc/garage.toml "$@"
}

bootstrap_embedded_garage() {
  local retries=15
  local health_code
  local node_id
  local garage_secret_key
  local output
  local bucket_var bucket
  local -a garage_buckets

  if ! docker ps --format '{{.Names}}' | grep -qx 's3-store'; then
    warn "s3-store container is not running; skipping embedded Garage bootstrap."
    return 0
  fi

  if [[ -z "${GARAGE_S3_ACCESS_KEY_ID:-}" || -z "${GARAGE_S3_ACCESS_KEY_NAME:-}" || -z "${GARAGE_S3_SECRET_KEY_FILE:-}" ]]; then
    err "Missing embedded Garage bootstrap variables (source local-deploy.env first)."
    return 1
  fi

  if [[ ! -f "$GARAGE_S3_SECRET_KEY_FILE" ]]; then
    err "Garage secret key file not found at $GARAGE_S3_SECRET_KEY_FILE. Re-run 'up' to regenerate."
    return 1
  fi

  garage_secret_key="$(tr -d '[:space:]' < "$GARAGE_S3_SECRET_KEY_FILE" | tr '[:upper:]' '[:lower:]')"

  if [[ ! "$GARAGE_S3_ACCESS_KEY_ID" =~ ^GK[0-9a-fA-F]{24}$ ]]; then
    err "GARAGE_S3_ACCESS_KEY_ID must match GK + 24 hex chars."
    return 1
  fi

  if [[ ! "$garage_secret_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    err "Garage secret key in $GARAGE_S3_SECRET_KEY_FILE is invalid (expected 64 hex chars)."
    return 1
  fi

  log "Bootstrapping embedded Garage (layout, key, buckets) ..."
  while [[ $retries -gt 0 ]]; do
    if garage_exec status >/dev/null 2>&1; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done

  if [[ $retries -eq 0 ]]; then
    err "Embedded Garage CLI did not become ready in time."
    return 1
  fi

  health_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GARAGE_S3_ADMIN_PORT}/health" || echo "000")
  if [[ "$health_code" != "200" ]]; then
    node_id="$(garage_exec node id | sed -nE 's/^([0-9a-f]{16,64})@.*$/\1/p' | head -1)"
    if [[ -z "$node_id" ]]; then
      node_id="$(garage_exec status | sed -nE 's/^([0-9a-f]{16,64})[[:space:]].*/\1/p' | head -1)"
    fi
    if [[ -z "$node_id" ]]; then
      err "Could not parse embedded Garage node ID for layout assignment."
      return 1
    fi

    garage_exec layout assign "$node_id" --zone dc1 --capacity "$GARAGE_S3_CAPACITY_BYTES" >/dev/null
    garage_exec layout apply --version 1 >/dev/null
  fi

  if ! output="$(garage_exec key import --yes -n "$GARAGE_S3_ACCESS_KEY_NAME" "$GARAGE_S3_ACCESS_KEY_ID" "$garage_secret_key" 2>&1)"; then
    if [[ "$output" == *"KeyAlreadyExists"* ]]; then
      if ! garage_exec key info "$GARAGE_S3_ACCESS_KEY_ID" >/dev/null 2>&1; then
        if [[ -n "${GARAGE_S3_ACCESS_KEY_SUFFIX_FILE:-}" ]]; then
          rm -f "$GARAGE_S3_ACCESS_KEY_SUFFIX_FILE"
          err "Embedded Garage key ID $GARAGE_S3_ACCESS_KEY_ID cannot be reused (tombstoned)."
          err "Removed $GARAGE_S3_ACCESS_KEY_SUFFIX_FILE to force a new key ID on next render."
          err "Re-run 'up' to regenerate credentials and restart the local stack."
        else
          err "Embedded Garage key ID $GARAGE_S3_ACCESS_KEY_ID cannot be reused (tombstoned)."
          err "Re-run 'up' after regenerating local key ID metadata."
        fi
        return 1
      fi
    else
      err "Failed to import embedded Garage S3 key."
      err "$output"
      return 1
    fi
  fi

  garage_buckets=()
  for bucket_var in \
    GARAGE_S3_BLOCKS_BUCKET \
    GARAGE_S3_RULER_BUCKET \
    GARAGE_S3_ALERTMANAGER_BUCKET \
    GARAGE_S3_LOKI_BUCKET \
    GARAGE_S3_TEMPO_BUCKET \
    GARAGE_S3_PYROSCOPE_BUCKET \
    GARAGE_S3_AIHORDE_BUCKET; do
    bucket="${!bucket_var:-}"
    if [[ -n "$bucket" ]]; then
      garage_buckets+=("$bucket")
    fi
  done

  if [[ ${#garage_buckets[@]} -eq 0 ]]; then
    warn "No GARAGE_S3_*_BUCKET variables are set; skipping bucket bootstrap."
  fi

  for bucket in "${garage_buckets[@]}"; do
    if ! output="$(garage_exec bucket create "$bucket" 2>&1)"; then
      if [[ "$output" != *"BucketAlreadyExists"* ]]; then
        err "Failed to create Garage bucket '$bucket'."
        err "$output"
        return 1
      fi
    fi

    garage_exec bucket allow --read --write --owner "$bucket" --key "$GARAGE_S3_ACCESS_KEY_ID" >/dev/null
  done

  wait_for_url "http://127.0.0.1:${GARAGE_S3_ADMIN_PORT}/health" "Embedded Garage" 60 || return 1
}

# ── Grafana Org-2 bootstrap ─────────────────────────────────
# Two-phase boot: strip Org-2 references before first start, then create
# the org via API, restore provisioning, and restart.
#
# Required env vars: GRAFANA_PORT, GRAFANA_ADMIN_PASSWORD,
#   GRAFANA_PUBLIC_ORG_NAME
# Arguments:
#   $1 — local_root  (e.g. local-deploy/runtime)
#   $2 — dc function name to call for compose commands (e.g. "dc" or "dc_monitoring")

grafana_strip_org2_provisioning() {
  local local_root="${1:?grafana_strip_org2_provisioning requires local_root}"
  local dashboard_cfg="$local_root/grafana/provisioning/dashboards/default.yml"
  local datasource_cfg="$local_root/grafana/provisioning/datasources/mimir.yml"

  if [ -f "$dashboard_cfg" ]; then
    cp -a "$dashboard_cfg" "${dashboard_cfg}.full"
    printf 'apiVersion: 1\nproviders: []\n' > "$dashboard_cfg"
    chown 472:472 "$dashboard_cfg"
  fi
  if [ -f "$datasource_cfg" ]; then
    cp -a "$datasource_cfg" "${datasource_cfg}.full"
    python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
cfg['datasources'] = [d for d in cfg.get('datasources', []) if d.get('orgId', 1) == 1]
with open(sys.argv[1], 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
" "$datasource_cfg"
  fi
  log "Using Org-1-only provisioning for initial boot."
}

grafana_create_org2_and_restore() {
  local local_root="${1:?grafana_create_org2_and_restore requires local_root}"
  local dc_fn="${2:?grafana_create_org2_and_restore requires dc function name}"
  local dashboard_cfg="$local_root/grafana/provisioning/dashboards/default.yml"
  local datasource_cfg="$local_root/grafana/provisioning/datasources/mimir.yml"

  log "Ensuring public Grafana organization exists ..."
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:${GRAFANA_PORT}/api/orgs" \
    -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${GRAFANA_PUBLIC_ORG_NAME}\"}" 2>/dev/null || echo "000")
  case "$http_code" in
    200) log "Created Org 2 (${GRAFANA_PUBLIC_ORG_NAME})." ;;
    409) info "Org 2 already exists." ;;
    *)   warn "Org creation returned HTTP $http_code — anonymous org may not work." ;;
  esac

  local need_restart=false
  if [ -f "${dashboard_cfg}.full" ]; then
    mv "${dashboard_cfg}.full" "$dashboard_cfg"
    need_restart=true
  fi
  if [ -f "${datasource_cfg}.full" ]; then
    mv "${datasource_cfg}.full" "$datasource_cfg"
    need_restart=true
  fi
  if [ "$need_restart" = true ]; then
    log "Restored full provisioning; restarting Grafana ..."
    "$dc_fn" restart grafana
    wait_for_url "http://127.0.0.1:${GRAFANA_PORT}/api/health" "Grafana (post-restart)" 60 || true
  fi
}
