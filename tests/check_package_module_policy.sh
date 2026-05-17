#!/usr/bin/env bash
# Enforce the package-manager abstraction policy for role and test code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

module_pattern='^[[:space:]]+((ansible\.builtin\.)?(apt|apt_repository|dnf|yum|yum_repository|pacman)|community\.general\.pacman):'
allowed_path_pattern='^roles/(amd_gpu_drivers/tasks/install_(apt|pacman)|horde_alloy/tasks/install_(apt|dnf|pacman))\.yml:[0-9]+:'

mapfile -t matches < <(git grep -nE "$module_pattern" -- roles tests examples || true)

violations=()
for match in "${matches[@]}"; do
  if [[ ! "$match" =~ $allowed_path_pattern ]]; then
    violations+=("$match")
  fi
done

if [ "${#violations[@]}" -gt 0 ]; then
  cat <<'MSG'
Package-manager-specific Ansible modules are only allowed in dedicated
manager-specific installer files for roles that genuinely need different
package names, repositories, or install procedures.

Prefer ansible.builtin.package for ordinary package installs.

Violations:
MSG
  printf '  %s\n' "${violations[@]}"
  exit 1
fi

echo "Package module policy passed."