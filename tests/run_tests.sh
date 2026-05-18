#!/usr/bin/env bash
# Local Docker-based test runner for horde deployment roles.
# Builds a systemd+Docker container, runs Ansible test playbooks against it.
#
# Usage:
#   ./tests/run_tests.sh                              # run ALL test_*.yml across all subfolders
#   ./tests/run_tests.sh monitoring                   # run tests/monitoring/test_*.yml
#   ./tests/run_tests.sh ai_horde                     # run tests/ai_horde/test_*.yml
#   ./tests/run_tests.sh monitoring/test_full_stack   # run a specific test (without .yml)
#   ./tests/run_tests.sh --list                       # list discoverable tests
#   ./tests/run_tests.sh --jobs 4                     # run tests in parallel (max 4 concurrent)
#   ./tests/run_tests.sh --jobs 3 monitoring          # parallel within a suite
#   ./tests/run_tests.sh --distro fedora monitoring   # run container tests in a Fedora systemd image
#   ./tests/run_tests.sh --base-image fedora:40 --distro fedora monitoring
#   ./tests/run_tests.sh --docker-daemon-tests monitoring/test_runtime_services
#                                                   # opt-in mode: build daemon-enabled
#                                                   # container image for tests marked
#                                                   # "# requires: docker-daemon"
#
# Logs are written to tests/test-results/<timestamp>/ with one file per
# playbook, plus a summary.txt for scripted analysis.
#
# Failure semantics (parallel mode):
#   - Each background worker writes a placeholder result file at job start.
#   - The placeholder is atomically replaced on completion with actual status.
#   - After all jobs finish, expected result count is compared to collected count.
#   - The run exits non-zero if: any test fails, any worker process exits
#     non-zero, or collected results do not match the expected count.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME_BASE="horde-test-systemd"
IMAGE_NAME="$IMAGE_NAME_BASE"
TEMP_DOCKER_CONFIG=""
LOG_DIR=""
MAX_JOBS=1
ENABLE_DOCKER_DAEMON_TESTS=0
HORDE_TEST_DISTRO="${HORDE_TEST_DISTRO:-ubuntu}"
HORDE_TEST_BASE_IMAGE="${HORDE_TEST_BASE_IMAGE:-}"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$SCRIPT_DIR/ansible.cfg}"

# Colours (disabled when not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*"; }


init_log_dir() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  LOG_DIR="$SCRIPT_DIR/test-results/${ts}"
  mkdir -p "$LOG_DIR"
  log "Logs will be saved to ${LOG_DIR}"
}

# Convert a playbook label (e.g. "monitoring/test_full_stack.yml") into
# a flat, safe filename for its log (e.g. "monitoring--test_full_stack.log").
log_filename() {
  local label="$1"
  echo "${label//\//__}" | sed 's/\.yml$//' | sed 's/[^a-zA-Z0-9_-]/_/g'
}

# Check whether a playbook uses only localhost/local connections and therefore
# does not need a Docker container.  Returns 0 (true) when every play in the
# file targets localhost with connection: local.
is_localhost_only() {
  local playbook_path="$1"
  # Count total plays and plays that declare connection: local on localhost
  local total_plays local_plays
  total_plays=$(grep -cE '^\s*hosts:\s' "$playbook_path" || true)
  local_plays=$(grep -cE '^\s*connection:\s*local' "$playbook_path" || true)
  [ "$total_plays" -gt 0 ] && [ "$total_plays" -eq "$local_plays" ]
}

playbook_requires_docker_daemon() {
  local playbook_path="$1"
  head -5 "$playbook_path" | grep -qi '# requires: docker-daemon'
}

# Extract a one-line failure reason from an Ansible log file.
# Handles both single-line fatal messages and multi-line JSON blocks.
extract_failure_reason() {
  local logfile="$1"
  local reason
  local stripped
  stripped=$(sed 's/\x1b\[[0-9;]*m//g' "$logfile")

  # Multi-line fatal block: join lines between "fatal:" and the next
  # "PLAY RECAP" or blank line, then extract the "msg" field.
  reason=$(echo "$stripped" \
    | awk '/fatal:.*FAILED/{found=1; buf=$0; next}
           found && /^[[:space:]]*$/{found=0; next}
           found && /^PLAY|^TASK/{found=0; next}
           found{buf=buf " " $0}
           END{print buf}' \
    | grep -oP '"msg":\s*"\K[^"]+' \
    | tail -1 \
    | head -c 200)

  if [ -n "$reason" ]; then
    echo "$reason"
    return
  fi

  # Fallback: single-line fatal with inline message
  reason=$(echo "$stripped" \
    | grep -i 'fatal:' \
    | tail -1 \
    | sed 's/.*fatal: *\[.*\]: *//; s/^FAILED! *=> *//' \
    | head -c 200)

  if [ -n "$reason" ]; then
    echo "$reason"
    return
  fi

  # Last resort: any "msg" in the file
  reason=$(echo "$stripped" \
    | grep -oP '"msg":\s*"\K[^"]+' \
    | tail -1 \
    | head -c 200)

  if [ -n "$reason" ]; then
    echo "$reason"
    return
  fi

  echo "(no failure detail extracted — see full log)"
}


# Parallel arrays to accumulate results for the final summary.
declare -a RESULT_LABELS=()
declare -a RESULT_STATUSES=()
declare -a RESULT_REASONS=()
declare -a RESULT_LOGFILES=()

record_result() {
  local label="$1" status="$2" reason="${3:-}" logfile="${4:-}"
  RESULT_LABELS+=("$label")
  RESULT_STATUSES+=("$status")
  RESULT_REASONS+=("$reason")
  RESULT_LOGFILES+=("$logfile")
}

record_docker_daemon_skip() {
  local label="$1"
  local reason="Docker daemon tests disabled (re-run with --docker-daemon-tests)"
  log "SKIP ${label}: requires a Docker daemon"
  record_result "$label" "SKIP" "$reason" ""
}

# Print a structured summary table and write summary.txt.
print_summary() {
  local passed=0 failed=0 skipped=0 total=${#RESULT_LABELS[@]}

  echo ""
  printf "${BOLD}%-50s  %-6s  %s${NC}\n" "TEST" "STATUS" "DETAILS"
  printf '%.0s─' {1..100}; echo ""

  for i in "${!RESULT_LABELS[@]}"; do
    local label="${RESULT_LABELS[$i]}"
    local status="${RESULT_STATUSES[$i]}"
    local reason="${RESULT_REASONS[$i]}"
    local logfile="${RESULT_LOGFILES[$i]}"

    if [ "$status" = "PASS" ]; then
      printf "${GREEN}%-50s  %-6s${NC}\n" "$label" "PASS"
      passed=$((passed + 1))
    elif [ "$status" = "SKIP" ]; then
      printf "${YELLOW}%-50s  %-6s${NC}  %s\n" "$label" "SKIP" "$reason"
      skipped=$((skipped + 1))
    else
      printf "${RED}%-50s  %-6s${NC}  %s\n" "$label" "FAIL" "$reason"
      failed=$((failed + 1))
    fi
  done

  printf '%.0s─' {1..100}; echo ""
  log "Results: ${passed} passed, ${failed} failed, ${skipped} skipped out of ${total} playbook(s)"

  if [ -n "$LOG_DIR" ]; then
    # Write machine-readable summary
    {
      echo "# test-runner summary $(date -Iseconds)"
      echo "# total=${total} passed=${passed} failed=${failed} skipped=${skipped}"
      echo "#"
      echo "# FORMAT: STATUS | LABEL | LOG_FILE | REASON"
      for i in "${!RESULT_LABELS[@]}"; do
        local rel_log=""
        if [ -n "${RESULT_LOGFILES[$i]}" ]; then
          rel_log="$(basename "${RESULT_LOGFILES[$i]}")"
        fi
        printf '%s | %s | %s | %s\n' \
          "${RESULT_STATUSES[$i]}" \
          "${RESULT_LABELS[$i]}" \
          "$rel_log" \
          "${RESULT_REASONS[$i]}"
      done
    } > "$LOG_DIR/summary.txt"

    echo ""
    log "Full logs:  ${LOG_DIR}/"
    log "Summary:    ${LOG_DIR}/summary.txt"
  fi

  [ "$failed" -eq 0 ]
}

cleanup() {
  log "Cleaning up test containers..."
  # Remove any containers created by this run (test-container-*)
  local containers
  containers=$(docker ps -a --filter "name=test-container-" --format '{{.Names}}' 2>/dev/null || true)
  for c in $containers; do
    docker rm -f "$c" 2>/dev/null || true
  done
  # Also remove the legacy single container name
  docker rm -f "test-container" 2>/dev/null || true
  if [ -n "$TEMP_DOCKER_CONFIG" ] && [ -d "$TEMP_DOCKER_CONFIG" ]; then
    rm -rf "$TEMP_DOCKER_CONFIG"
  fi
}


# Some environments inject a desktop-only credential helper into
# ~/.docker/config.json (e.g. docker-credential-desktop.exe), which is
# not executable on Linux CI/containers. Use a minimal, isolated config
# for this test runner so docker build/pull works reliably.
configure_docker_cli() {
  TEMP_DOCKER_CONFIG="$(mktemp -d)"
  printf '{}' > "$TEMP_DOCKER_CONFIG/config.json"
  export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
  log "Using isolated Docker CLI config at ${DOCKER_CONFIG}"
}


resolve_test_image_settings() {
  case "$HORDE_TEST_DISTRO" in
    ubuntu)
      HORDE_TEST_BASE_IMAGE="${HORDE_TEST_BASE_IMAGE:-ubuntu:22.04}"
      ;;
    fedora)
      HORDE_TEST_BASE_IMAGE="${HORDE_TEST_BASE_IMAGE:-fedora:40}"
      ;;
    *)
      err "Unsupported test distro: ${HORDE_TEST_DISTRO} (expected: ubuntu or fedora)"
      exit 1
      ;;
  esac

  IMAGE_NAME="${IMAGE_NAME_BASE}-${HORDE_TEST_DISTRO}"
  if [ "$ENABLE_DOCKER_DAEMON_TESTS" -eq 1 ]; then
    IMAGE_NAME="${IMAGE_NAME}-dind"
    log "Runtime daemon mode enabled: using daemon-capable image tag ${IMAGE_NAME}"
  fi
}


build_image() {
  local docker_daemon_arg="0"
  if [ "$ENABLE_DOCKER_DAEMON_TESTS" -eq 1 ]; then
    docker_daemon_arg="1"
  fi

  log "Building test image ${IMAGE_NAME} (${HORDE_TEST_DISTRO}, ${HORDE_TEST_BASE_IMAGE}, docker-daemon=${docker_daemon_arg})..."
  docker build \
    --build-arg HORDE_TEST_BASE_IMAGE="$HORDE_TEST_BASE_IMAGE" \
    --build-arg HORDE_TEST_DISTRO="$HORDE_TEST_DISTRO" \
    --build-arg HORDE_TEST_ENABLE_DOCKER_DAEMON="$docker_daemon_arg" \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Dockerfile.systemd" \
    "$SCRIPT_DIR"
}


start_container() {
  local container_name="${1:-test-container}"
  # Remove stale container
  docker rm -f "$container_name" 2>/dev/null || true

  log "Starting container ${container_name}..."
  docker run -d \
    --name "$container_name" \
    --hostname "$container_name" \
    --privileged \
    --cgroupns=host \
    --memory=2g \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    "$IMAGE_NAME"

  # Wait for systemd to finish booting
  log "Waiting for systemd to initialise..."
  local retries=30
  while [ $retries -gt 0 ]; do
    local state
    state="$(docker exec "$container_name" systemctl is-system-running 2>/dev/null || true)"
    if echo "$state" | grep -qE "running|degraded"; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done

  if [ $retries -eq 0 ]; then
    warn "systemd did not reach 'running' — continuing anyway (may be 'degraded' in container)"
  fi

  if [ "$ENABLE_DOCKER_DAEMON_TESTS" -eq 1 ]; then
    log "Configuring Docker daemon storage driver for nested runtime tests..."
    docker exec "$container_name" sh -lc "mkdir -p /etc/docker && printf '%s\n' '{\"storage-driver\":\"vfs\"}' > /etc/docker/daemon.json"

    log "Starting Docker daemon inside ${container_name} (opt-in runtime mode)..."
    docker exec "$container_name" systemctl start docker >/dev/null 2>&1 || true

    local docker_retries=30
    while [ $docker_retries -gt 0 ]; do
      if docker exec "$container_name" docker info >/dev/null 2>&1; then
        break
      fi
      docker_retries=$((docker_retries - 1))
      sleep 2
    done

    if [ $docker_retries -eq 0 ]; then
      warn "Docker daemon did not become ready inside ${container_name}; daemon-required tests may skip"
    else
      log "Docker daemon ready inside ${container_name}"
    fi
  fi

  log "Container ready: ${container_name}"
}


# Prefer the repo venv, fall back to PATH
if [ -x "$REPO_ROOT/.venv/bin/ansible-playbook" ]; then
  ANSIBLE_PLAYBOOK="$REPO_ROOT/.venv/bin/ansible-playbook"
else
  ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"
fi

if [ -z "$ANSIBLE_PLAYBOOK" ]; then
  err "ansible-playbook not found. Install it or create a venv at ${REPO_ROOT}/.venv"
  exit 1
fi


run_playbook() {
  local playbook_path="$1"
  local pb_label="$2"
  local container_name="${3:-}"        # empty for localhost-only tests
  local is_local="${4:-false}"         # "true" when running without a container

  if [ ! -f "$playbook_path" ]; then
    err "Playbook not found: ${playbook_path}"
    return 1
  fi

  local playbook_name
  playbook_name="$(basename "$playbook_path")"

  # Docker-daemon tests are opt-in so the default suite path stays render-only.
  if playbook_requires_docker_daemon "$playbook_path"; then
    if [ "$ENABLE_DOCKER_DAEMON_TESTS" -ne 1 ]; then
      record_docker_daemon_skip "$pb_label"
      return 0
    fi

    if [ "$is_local" != "true" ] && ! docker exec "$container_name" docker info >/dev/null 2>&1; then
      local skip_reason="Docker daemon unavailable in container"
      log "SKIP ${playbook_name}: requires a Docker daemon inside ${container_name}"
      record_result "$pb_label" "SKIP" "$skip_reason" ""
      return 0
    fi
  fi

  # Per-test log file
  local logfile=""
  if [ -n "$LOG_DIR" ]; then
    logfile="${LOG_DIR}/$(log_filename "$pb_label").log"
  fi

  log "Running playbook: ${playbook_name}"

  # Build inventory/connection args
  local inv_args=()
  if [ "$is_local" = "true" ]; then
    inv_args=(-i "localhost," -c local)
  else
    inv_args=(-i "$SCRIPT_DIR/inventory_docker.ini")
    # Override container target for parallel execution (inventory
    # defaults to "test-container"; ansible_host tells the docker
    # connection plugin which container to exec into).
    if [ -n "$container_name" ]; then
      inv_args+=(-e "ansible_host=${container_name}")
    fi
  fi

  # Run the playbook, teeing to both console and log file
  local rc=0
  if [ -n "$logfile" ]; then
    set +e
    "$ANSIBLE_PLAYBOOK" \
      "${inv_args[@]}" \
      "$playbook_path" \
      -v 2>&1 | tee "$logfile"
    rc="${PIPESTATUS[0]}"
    set -e
  else
    "$ANSIBLE_PLAYBOOK" \
      "${inv_args[@]}" \
      "$playbook_path" \
      -v || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    local reason=""
    [ -n "$logfile" ] && reason="$(extract_failure_reason "$logfile")"
    record_result "$pb_label" "FAIL" "$reason" "$logfile"
    return 1
  fi

  
  # Skip for runtime tests (services aren't idempotent on a fresh
  # container), local_deploy playbooks, and any playbook that declares
  # "# idempotency: skip" near the top (multi-play tests that
  # intentionally overwrite the same files with different variable sets).
  if echo "$playbook_name" | grep -qE 'runtime|local_deploy'; then
    log "Skipping idempotency check for ${playbook_name}"
    record_result "$pb_label" "PASS" "" "$logfile"
    return 0
  fi
  if head -5 "$playbook_path" | grep -qi '# idempotency: skip'; then
    log "Skipping idempotency check for ${playbook_name} (opted out via marker)"
    record_result "$pb_label" "PASS" "" "$logfile"
    return 0
  fi

  log "Idempotency check: re-running ${playbook_name}..."
  local idem_logfile=""
  [ -n "$LOG_DIR" ] && idem_logfile="${LOG_DIR}/$(log_filename "$pb_label")__idempotency.log"

  local idem_rc=0
  local idem_output
  set +e
  idem_output=$("$ANSIBLE_PLAYBOOK" \
    "${inv_args[@]}" \
    "$playbook_path" \
    -v 2>&1)
  idem_rc=$?
  set -e
  if [ -n "$idem_logfile" ]; then
    echo "$idem_output" > "$idem_logfile"
  fi

  if [ "$idem_rc" -ne 0 ]; then
    err "Idempotency re-run failed for ${playbook_name}"
    local reason="Idempotency re-run crashed"
    [ -n "$idem_logfile" ] && reason="$(extract_failure_reason "$idem_logfile")"
    record_result "$pb_label" "FAIL" "IDEMPOTENCY: $reason" "$idem_logfile"
    return 1
  fi

  local changed_count
  changed_count=$(echo "$idem_output" | grep -oP 'changed=\K[0-9]+' | awk '{s+=$1} END {print s+0}')
  if [ "$changed_count" -gt 0 ]; then
    local changed_tasks
    changed_tasks=$(echo "$idem_output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'changed:' | head -3 | tr '\n' '; ')
    warn "Idempotency violation: ${changed_count} changed task(s) on re-run of ${playbook_name}"
    echo "$idem_output" | grep -E 'changed:' || true
    record_result "$pb_label" "FAIL" "IDEMPOTENCY: ${changed_count} changed — ${changed_tasks}" "${idem_logfile}"
    return 1
  fi
  log "Idempotency check passed (0 changed)"
  record_result "$pb_label" "PASS" "" "$logfile"
}


# Run a single container-based test.  Designed to be called as a background
# job in parallel mode.  Writes a small result file instead of appending to
# in-memory arrays (which don't survive subshells).
run_container_test() {
  local pb="$1" pb_label="$2" container_name="$3"
  local result_file="${LOG_DIR}/.result_$(log_filename "$pb_label")"
  # Write placeholder so a crash before completion is detectable.
  printf '%s\n' "${pb_label}|INCOMPLETE|Worker did not finish|" > "$result_file"
  start_container "$container_name"
  local rc=0
  run_playbook "$pb" "$pb_label" "$container_name" "false" || rc=$?
  docker rm -f "$container_name" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    log "PASSED: ${pb_label}"
  else
    err "FAILED: ${pb_label}"
  fi
  # Atomically replace placeholder with actual result.
  local tmp_result="${result_file}.tmp"
  if [ ${#RESULT_LABELS[@]} -gt 0 ]; then
    printf '%s\n' "${RESULT_LABELS[-1]}|${RESULT_STATUSES[-1]}|${RESULT_REASONS[-1]}|${RESULT_LOGFILES[-1]}" > "$tmp_result"
  else
    printf '%s\n' "${pb_label}|FAIL|Playbook setup failed|" > "$tmp_result"
  fi
  mv -f "$tmp_result" "$result_file"
  return $rc
}

# Collect result files written by parallel jobs into the RESULT_* arrays.
# Returns non-zero if any result is INCOMPLETE (worker crashed before finishing).
collect_parallel_results() {
  local result_files incomplete=0
  result_files=$(find "$LOG_DIR" -name '.result_*' -type f 2>/dev/null | sort || true)
  for rf in $result_files; do
    local line
    line="$(cat "$rf")"
    local label status reason logfile
    IFS='|' read -r label status reason logfile <<< "$line"
    if [ "$status" = "INCOMPLETE" ]; then
      err "INCOMPLETE: ${label} — worker did not finish (likely crashed)"
      status="FAIL"
      reason="Worker process did not complete — ${reason}"
      incomplete=1
    fi
    RESULT_LABELS+=("$label")
    RESULT_STATUSES+=("$status")
    RESULT_REASONS+=("$reason")
    RESULT_LOGFILES+=("$logfile")
    rm -f "$rf"
  done
  return $incomplete
}


main() {
  # Parse flags
  local suite_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --list)
        while IFS= read -r -d '' f; do
          printf '%s\n' "$(realpath --relative-to="$SCRIPT_DIR" "$f")"
        done < <(find "$SCRIPT_DIR" -name 'test_*.yml' -type f -print0 | sort -z)
        exit 0
        ;;
      --jobs|-j)
        MAX_JOBS="${2:?--jobs requires a number}"
        shift 2
        ;;
      --distro)
        HORDE_TEST_DISTRO="${2:?--distro requires ubuntu or fedora}"
        shift 2
        ;;
      --base-image)
        HORDE_TEST_BASE_IMAGE="${2:?--base-image requires an image reference}"
        shift 2
        ;;
      --docker-daemon-tests)
        ENABLE_DOCKER_DAEMON_TESTS=1
        shift
        ;;
      *)
        suite_args+=("$1")
        shift
        ;;
    esac
  done

  resolve_test_image_settings

  trap cleanup EXIT

  configure_docker_cli

  init_log_dir

  # Install Galaxy role dependencies (idempotent; skips already-installed roles)
  if [ -f "$REPO_ROOT/requirements.yml" ]; then
    log "Installing Galaxy role dependencies ..."
    ansible-galaxy role install -r "$REPO_ROOT/requirements.yml" \
      --roles-path "$REPO_ROOT/roles" -p "$REPO_ROOT/roles" 2>&1 \
      | grep -v '^$' || true
  fi

  # Determine which playbooks to run
  local playbooks=()
  if [ ${#suite_args[@]} -gt 0 ]; then
    local arg="${suite_args[0]}"
    if [[ "$arg" == *"/"* ]]; then
      # Specific test: e.g. "monitoring/test_full_stack"
      playbooks+=("$SCRIPT_DIR/${arg}.yml")
    elif [ -d "$SCRIPT_DIR/$arg" ]; then
      # Subfolder name: e.g. "monitoring"
      while IFS= read -r -d '' f; do
        playbooks+=("$f")
      done < <(find "$SCRIPT_DIR/$arg" -name 'test_*.yml' -type f -print0 | sort -z)
    else
      # Bare test name for backward compat: e.g. "test_full_stack"
      # Search subfolders for it
      while IFS= read -r -d '' f; do
        playbooks+=("$f")
      done < <(find "$SCRIPT_DIR" -name "${arg}.yml" -type f -print0)
      if [ ${#playbooks[@]} -eq 0 ]; then
        err "No test found matching: ${arg}"
        exit 1
      fi
    fi
  else
    # No arguments: discover all test_*.yml recursively
    while IFS= read -r -d '' f; do
      playbooks+=("$f")
    done < <(find "$SCRIPT_DIR" -name 'test_*.yml' -type f -print0 | sort -z)
  fi

  if [ ${#playbooks[@]} -eq 0 ]; then
    warn "No test playbooks found."
    exit 0
  fi

  log "Found ${#playbooks[@]} test playbook(s)"

  # Partition playbooks into localhost-only and container-based
  local local_playbooks=()
  local container_playbooks=()
  for pb in "${playbooks[@]}"; do
    if is_localhost_only "$pb"; then
      local_playbooks+=("$pb")
    else
      container_playbooks+=("$pb")
    fi
  done

  if [ ${#local_playbooks[@]} -gt 0 ]; then
    log "Localhost-only tests (no container needed): ${#local_playbooks[@]}"
  fi
  if [ ${#container_playbooks[@]} -gt 0 ]; then
    log "Container-based tests: ${#container_playbooks[@]}"
  fi

  # ── Phase 1: Run localhost-only tests (fast, no Docker image needed) ──
  local any_failed=0
  for pb in "${local_playbooks[@]}"; do
    local pb_label
    pb_label="$(realpath --relative-to="$SCRIPT_DIR" "$pb")"
    log "Running localhost test: ${pb_label}"
    if run_playbook "$pb" "$pb_label" "" "true"; then
      log "PASSED: ${pb_label}"
    else
      err "FAILED: ${pb_label}"
      any_failed=1
    fi
  done

  # ── Phase 2: Run container-based tests ──
  if [ ${#container_playbooks[@]} -gt 0 ]; then
    build_image

    if [ "$MAX_JOBS" -gt 1 ] && [ ${#container_playbooks[@]} -gt 1 ]; then
      # Parallel execution
      log "Running ${#container_playbooks[@]} container tests with --jobs ${MAX_JOBS}"
      local running_jobs=0
      local pids=()
      local pid_labels=()
      local idx=0
      local launched_container_tests=0
      local daemon_skipped_in_parallel=0

      for pb in "${container_playbooks[@]}"; do
        local pb_label
        pb_label="$(realpath --relative-to="$SCRIPT_DIR" "$pb")"

        if playbook_requires_docker_daemon "$pb" && [ "$ENABLE_DOCKER_DAEMON_TESTS" -ne 1 ]; then
          record_docker_daemon_skip "$pb_label"
          daemon_skipped_in_parallel=$((daemon_skipped_in_parallel + 1))
          continue
        fi

        local container_name="test-container-${idx}"

        # Wait for a slot to open if at max capacity
        while [ "$running_jobs" -ge "$MAX_JOBS" ]; do
          # Wait for any child to finish
          local waited_pid=""
          for pi in "${!pids[@]}"; do
            if ! kill -0 "${pids[$pi]}" 2>/dev/null; then
              wait "${pids[$pi]}" || any_failed=1
              waited_pid="$pi"
              break
            fi
          done
          if [ -n "$waited_pid" ]; then
            unset 'pids['"$waited_pid"']'
            running_jobs=$((running_jobs - 1))
          else
            sleep 1
          fi
        done

        # Launch test in background
        run_container_test "$pb" "$pb_label" "$container_name" &
        pids+=($!)
        pid_labels+=("$pb_label")
        running_jobs=$((running_jobs + 1))
        launched_container_tests=$((launched_container_tests + 1))
        idx=$((idx + 1))
      done

      # Wait for remaining jobs
      for pid in "${pids[@]}"; do
        wait "$pid" || any_failed=1
      done

      # Collect results from files written by background jobs
      collect_parallel_results || any_failed=1

      # Validate expected vs collected result count
      local expected_count=$(( launched_container_tests + daemon_skipped_in_parallel ))
      local collected_count
      collected_count=$(( ${#RESULT_LABELS[@]} - ${#local_playbooks[@]} ))
      if [ "$collected_count" -ne "$expected_count" ]; then
        err "Result count mismatch: expected ${expected_count} container results, collected ${collected_count}"
        any_failed=1
      fi
    else
      # Sequential execution (default)
      for pb in "${container_playbooks[@]}"; do
        local pb_label
        pb_label="$(realpath --relative-to="$SCRIPT_DIR" "$pb")"

        if playbook_requires_docker_daemon "$pb" && [ "$ENABLE_DOCKER_DAEMON_TESTS" -ne 1 ]; then
          record_docker_daemon_skip "$pb_label"
          continue
        fi

        local container_name="test-container-0"
        # Each test gets a fresh container to avoid state leaking between runs
        start_container "$container_name"
        if run_playbook "$pb" "$pb_label" "$container_name" "false"; then
          log "PASSED: ${pb_label}"
        else
          err "FAILED: ${pb_label}"
          any_failed=1
        fi
        docker rm -f "$container_name" 2>/dev/null || true
      done
    fi
  fi

  # Exit non-zero if any test failed, any worker crashed, or result
  # accounting detected missing results — regardless of what print_summary
  # reports from the RESULT arrays alone.
  print_summary
  if [ "$any_failed" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
