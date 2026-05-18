#!/usr/bin/env bash

# Local deployment of the AI-Horde backend for manual validation.
# Renders configs via Ansible, clones source, builds Docker image,
# then starts the stack via Docker Compose.
#
# Usage:
#   ./tests/ai_horde/local_deploy.sh up       # render + clone + build + start
#   ./tests/ai_horde/local_deploy.sh up --latest  # follow branch head instead of pinned SHA
#   ./tests/ai_horde/local_deploy.sh down     # tear down stack + remove files
#   ./tests/ai_horde/local_deploy.sh status   # show running containers
#   ./tests/ai_horde/local_deploy.sh logs     # tail compose logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_ROOT="$REPO_ROOT/local-deploy/runtime/ai-horde"

# shellcheck source=../lib.sh
source "$REPO_ROOT/tests/lib.sh"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
ENV_FILE="$LOCAL_ROOT/local-deploy.env"
USE_LATEST_REF=false
INSTANCES=3
AI_HORDE_REPO_DEFAULT="https://github.com/Haidra-Org/AI-Horde.git"
if [ -z "${AI_HORDE_REPO+x}" ]; then
  AI_HORDE_REPO="$AI_HORDE_REPO_DEFAULT"
else
  AI_HORDE_REPO="$AI_HORDE_REPO"
fi

AI_HORDE_REF_DEFAULT="f40ae696acd0f23f6484db7f3d2408884185e960"
if [ -z "${AI_HORDE_REF+x}" ]; then
  AI_HORDE_REF="$AI_HORDE_REF_DEFAULT"
  AI_HORDE_REF_EXPLICIT=false
else
  AI_HORDE_REF="$AI_HORDE_REF"
  AI_HORDE_REF_EXPLICIT=true
fi

# Docker compose wrapper
dc() {
  local args=(-f "$LOCAL_ROOT/docker-compose.yml")
  if [ -f "$LOCAL_ROOT/docker-compose.garage.yml" ]; then
    args+=(-f "$LOCAL_ROOT/docker-compose.garage.yml")
  fi
  docker compose "${args[@]}" "$@"
}


render_configs() {
  find_ansible
  log "Rendering AI-Horde configs into $LOCAL_ROOT ..."
  "$ANSIBLE_PLAYBOOK" \
      -i "localhost," \
      "$SCRIPT_DIR/local_deploy.yml" \
      -e "ai_horde_replicas=$INSTANCES" \
      --become \
      -v
  log "Config rendering complete."
}


clone_source() {
  local ref="$AI_HORDE_REF"
  if [ "$USE_LATEST_REF" = true ] && [ "$AI_HORDE_REF_EXPLICIT" = false ]; then
    ref="main"
  fi

  clone_or_update_source \
    "$AI_HORDE_REPO" \
    "$LOCAL_ROOT/src" \
    "$ref"

  if [ "$USE_LATEST_REF" = true ] || [ "$AI_HORDE_REF_EXPLICIT" = true ]; then
    _patch_dockerfile "$LOCAL_ROOT/src/Dockerfile"
  fi
}


compose_up() {
  if [ ! -f "$LOCAL_ROOT/docker-compose.yml" ]; then
    err "No docker-compose.yml found — did render fail?"
    exit 1
  fi

  log "Building AI-Horde Docker image (this may take a few minutes) ..."
  dc build

  log "Starting local Garage for AI-Horde R2/source-image storage ..."
  cleanup_known_container_name_conflicts ai-horde s3-store
  dc up -d s3-store
  bootstrap_embedded_garage

  log "Starting Docker Compose stack ..."
  dc up -d --scale aihorde="$INSTANCES"

  wait_for_url "http://127.0.0.1:8080/api/v2/status/heartbeat" "AI-Horde heartbeat (load balanced)" 120 || true
}

print_banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "AI-Horde API      →  http://localhost:8080"
  info "Heartbeat         →  http://localhost:8080/api/v2/status/heartbeat"
  info "Registration      →  http://localhost:8080/register"
  echo ""
  info "Test user setup:"
  info "  curl -X POST --data-raw 'username=test_user' http://localhost:8080/register"
  echo ""
  info "Direct Replica Access (Bypass Proxy):"
  if [ "$INSTANCES" -gt 1 ]; then
    local port_end=$(( AI_HORDE_PORT + INSTANCES - 1 ))
    info "  Ports: ${AI_HORDE_PORT}–${port_end}  (${INSTANCES} instances)"
  else
    info "  http://localhost:${AI_HORDE_PORT}"
  fi
  echo ""
  info "Tear down:  $0 down"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}



main() {
  local cmd="${1:-up}"
  shift || true

  for arg in "$@"; do
    case "$arg" in
      --latest) USE_LATEST_REF=true ;;
      --instances=*) INSTANCES="${arg#--instances=}" ;;
      -*) warn "Unknown flag: $arg" ;;
    esac
  done

  case "$cmd" in
    up)
      check_prerequisites git
      render_configs
      clone_source
      load_env "$ENV_FILE"
      compose_up
      print_banner
      ;;
    down)
      compose_down "$LOCAL_ROOT"
      ;;
    status)
      compose_status "$LOCAL_ROOT/docker-compose.yml"
      ;;
    logs)
      compose_logs "$LOCAL_ROOT/docker-compose.yml"
      ;;
    *)
      echo "Usage: $0 {up|down|status|logs} [--latest] [--instances=N]"
      exit 1
      ;;
  esac
}

main "$@"
