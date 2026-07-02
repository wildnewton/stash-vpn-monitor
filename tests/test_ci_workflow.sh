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

assert_file_exists "$WORKFLOW"
assert_contains "name: CI"
assert_contains "pull_request:"
assert_contains "push:"
assert_contains "branches: [main]"
assert_contains "runs-on: ubuntu-latest"
assert_contains "actions/checkout@v4"
assert_contains "bash -n vpn_monitor.sh"
assert_contains "bash -n install_vpn_monitor.sh"
assert_contains "python3 -m py_compile stash_switch_config.py stash_dump.py"
assert_contains "bash tests/test_cli_missing_optional_args.sh"
assert_contains "bash tests/test_ci_workflow.sh"

echo "CI workflow test passed"
