# Contributing to Haidra Deployments

## Getting started

```bash
git clone https://github.com/Haidra-Org/deployments.git
cd deployments

# Set up the Python virtual environment
python3 -m venv .venv
source .venv/bin/activate
pip install ansible ansible-lint
```

See the [Quick Start guide](QUICKSTART.md) for running local deploys and
tests.

## Making changes

1. **Create a branch** from `main`.
2. **Make your changes** in the relevant role under `roles/`.
3. **Run the render tests** for the role you changed:
   ```bash
   ./tests/run_tests.sh ai_horde         # or: monitoring, frontpage, artbot, etc.
   ```
4. **Run integration tests** if your change affects cross-role behavior:
   ```bash
   ./tests/run_tests.sh integration
   ./tests/run_tests.sh full_stack
   ```
5. **Test locally** if your change affects runtime behavior:
   ```bash
   ./tests/ai_horde/local_deploy.sh up --latest
   # verify your change, then:
   ./tests/ai_horde/local_deploy.sh down
   ```

## Test conventions

- Test playbooks live in `tests/<suite>/` and are named `test_*.yml`.
- Tests must be **idempotent**: zero changed tasks on a second run.
  If intentionally non-idempotent, add `# idempotency: skip` in the first 5
  lines.
- Prefer **render-only** tests (`start_services: false`) that assert file
  content, permissions, and template output.
- Container tests run inside disposable privileged systemd containers and
  connect as root so host-level role behavior is tested without depending on
  the local or CI runner UID.
- Use **runtime tests** only when behavior can't be proven by rendering.
- See the [testing conventions](.github/instructions/ansible-role-testing.instructions.md)
  for the full guide.

## Repository structure

| Path                    | Purpose                                                                |
| ----------------------- | ---------------------------------------------------------------------- |
| `roles/`                | Ansible roles — the source of truth for deployment logic               |
| `examples/`             | Example playbooks and inventory templates                              |
| `tests/`                | Render tests, integration tests, and local deploy scripts              |
| `local-deploy/static/`  | Committed local deploy overlays and HAProxy config                     |
| `local-deploy/runtime/` | Generated configs, source checkouts, and runtime data (safe to delete) |
| `docs/`                 | Operational guides (monitoring, backup, migration, upgrades)           |

See [`README.md`](README.md) for the full role map and documentation index.

## Pull requests

- Run the relevant test suite(s) before opening a PR.
- Keep changes focused (one role or concern per PR when possible).
- Include a brief description of what changed and why.
