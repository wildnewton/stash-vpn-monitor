#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$REPO_ROOT/vpn_runtime.sh"

# shellcheck source=/dev/null
source "$RUNTIME"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
trace="$tmpdir/trace"
: > "$trace"

RETRY_MAX=2
RETRY_INTERVAL=0

log() { :; }
notify() { :; }
sleep() { :; }
refresh_config() { echo "refresh_config" >> "$trace"; }
check_connectivity() { echo "connectivity" >> "$trace"; echo "fail"; }
switch_to_best_node() { echo "switch_to_best_node" >> "$trace"; return 1; }
refresh_subscription() { echo "refresh_subscription" >> "$trace"; return 0; }
try_alternative_configs() { echo "try_alternative_configs" >> "$trace"; return 1; }

if recover; then
    echo "FAIL: full recovery escalation fixture should end in failure" >&2
    exit 1
fi

expected="$tmpdir/expected"
cat > "$expected" <<'EOF'
refresh_config
connectivity
connectivity
switch_to_best_node
refresh_subscription
connectivity
connectivity
switch_to_best_node
try_alternative_configs
EOF

if ! diff -u "$expected" "$trace"; then
    echo "FAIL: recover() escalation order/retry count changed" >&2
    exit 1
fi

echo "Recovery orchestration tests passed"
