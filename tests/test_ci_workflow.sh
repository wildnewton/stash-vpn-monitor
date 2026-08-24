#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

assert_file_exists() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "Expected file to exist: $path" >&2
        exit 1
    fi
}

assert_contains() {
    local needle="$1"
    if ! grep -Fq -- "$needle" "$WORKFLOW"; then
        echo "Expected CI workflow to contain: $needle" >&2
        echo "Actual workflow:" >&2
        cat "$WORKFLOW" >&2
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1"
    if grep -Fq -- "$needle" "$WORKFLOW"; then
        echo "Expected CI workflow not to contain: $needle" >&2
        echo "Actual workflow:" >&2
        cat "$WORKFLOW" >&2
        exit 1
    fi
}

assert_file_exists "$WORKFLOW"
assert_contains "name: CI"
assert_contains "pull_request:"
assert_contains "push:"
assert_contains "branches: [main]"
assert_contains "runs-on: ubuntu-latest"
assert_contains "actions/checkout@v4"
assert_contains "bash -n vpn_monitor.sh"
assert_contains "bash -n install_vpn_monitor.sh"
assert_contains "bash -n tests/test_log_rotation.sh"
assert_contains "python3 -m py_compile stash_switch_config.py"
assert_not_contains "stash_dump.py"
assert_contains "python3 -m pip install pytest"
assert_contains "python3 -m pytest -q"
assert_contains "bash tests/test_cli_missing_optional_args.sh"
assert_contains "bash tests/test_ci_workflow.sh"
assert_contains "bash tests/test_node_ranking_policy.sh"
assert_contains "bash tests/test_log_rotation.sh"

echo "CI workflow test passed"
