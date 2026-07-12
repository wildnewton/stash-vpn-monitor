#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/vpn_monitor.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

config_file="$tmpdir/config"
cat > "$config_file" <<EOF
API_SECRET="test-secret"
LOG_FILE="$tmpdir/vpn_monitor.log"
CHECK_INTERVAL="300"
EOF

# Source the production functions without running the script entrypoint.
lib_file="$tmpdir/vpn_monitor_lib.sh"
sed '/^# ===================== 入口/,$d' "$SCRIPT" > "$lib_file"
# shellcheck source=/dev/null
VPN_MONITOR_CONFIG="$config_file" source "$lib_file"

# Keep tests fast and deterministic.
RETRY_MAX=1
RETRY_INTERVAL=0

log() { :; }
notify() { :; }
get_current_node() { echo "CURRENT"; }
check_connectivity() { echo "ok"; }

SELECTABLE_NODES=""
SWITCHED_NODE=""
declare -A NODE_DELAYS=()

get_selectable_nodes() {
    printf '%s\n' "$SELECTABLE_NODES"
}

test_node_delay() {
    local node_name="$1"
    echo "${NODE_DELAYS[$node_name]:-0}"
}

switch_node() {
    local target="$1"
    SWITCHED_NODE="$target"
    return 0
}

reset_case() {
    SELECTABLE_NODES=""
    SWITCHED_NODE=""
    NODE_DELAYS=()
}

assert_selected() {
    local expected="$1"
    if [[ "$SWITCHED_NODE" != "$expected" ]]; then
        echo "Expected selected node: $expected" >&2
        echo "Actual selected node:   ${SWITCHED_NODE:-<none>}" >&2
        exit 1
    fi
}

# JP and SG are the same priority tier, so lower measured delay wins.
reset_case
SELECTABLE_NODES=$'SG-slower\nJP-faster'
NODE_DELAYS[SG-slower]=120
NODE_DELAYS[JP-faster]=100
switch_to_best_node
assert_selected "JP-faster"

# Symmetric case: SG can beat JP when SG has better measured delay.
reset_case
SELECTABLE_NODES=$'JP-slower\nSG-faster'
NODE_DELAYS[JP-slower]=120
NODE_DELAYS[SG-faster]=100
switch_to_best_node
assert_selected "SG-faster"

# HK is still eligible, but only after all non-HK candidates fail.
reset_case
SELECTABLE_NODES=$'JP-dead\nUS-dead\nHK-live'
NODE_DELAYS[JP-dead]=0
NODE_DELAYS[US-dead]=0
NODE_DELAYS[HK-live]=90
switch_to_best_node
assert_selected "HK-live"

# A reachable non-HK node beats a faster HK node because HK is last-resort only.
reset_case
SELECTABLE_NODES=$'HK-fast\nTW-ok'
NODE_DELAYS[HK-fast]=20
NODE_DELAYS[TW-ok]=100
switch_to_best_node
assert_selected "TW-ok"

echo "Node ranking policy tests passed"
