#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# Node Ranking Policy Tests — behavioral + structural
#
# Source production functions, mock dependencies, and test runtime ranking.
# Compatible with bash 3.2+ (macOS default).
# =============================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/vpn_monitor.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: vpn_monitor.sh not found at $SCRIPT" >&2
    exit 1
fi

# ── Source production functions with mocks ──

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

config_file="$tmpdir/config"
cat > "$config_file" <<EOF
API_SECRET="***"
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

# Simple delay map using two parallel arrays (bash 3.2 compatible)
NODE_NAMES=()
NODE_DELAYS=()

set_delay() {
    local name="$1" delay="$2"
    NODE_NAMES+=("$name")
    NODE_DELAYS+=("$delay")
}

get_delay() {
    local name="$1"
    local i
    for i in "${!NODE_NAMES[@]}"; do
        if [[ "${NODE_NAMES[$i]}" == "$name" ]]; then
            echo "${NODE_DELAYS[$i]}"
            return 0
        fi
    done
    echo "0"
}

get_selectable_nodes() {
    printf '%s\n' "$SELECTABLE_NODES"
}

test_node_delay() {
    local node_name="$1"
    get_delay "$node_name"
}

switch_node() {
    local target="$1"
    SWITCHED_NODE="$target"
    return 0
}

reset_case() {
    SELECTABLE_NODES=""
    SWITCHED_NODE=""
    NODE_NAMES=()
    NODE_DELAYS=()
}

assert_selected() {
    local expected="$1"
    if [[ "$SWITCHED_NODE" != "$expected" ]]; then
        echo "FAIL: Expected selected node: $expected" >&2
        echo "      Actual selected node:   ${SWITCHED_NODE:-<none>}" >&2
        exit 1
    fi
    echo "  ✓ $expected selected"
}

PASS=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" -eq 0 ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Node Ranking Policy Tests ==="
echo ""

# ════════════════════════════════════════════
# Behavioral tests — actual ranking logic
# ════════════════════════════════════════════
echo "[Behavioral] ranking policy tests"

# Test 1: JP and SG are same priority tier; lower measured delay wins.
echo "  Test 1: JP/SG same tier, lower delay wins"
reset_case
SELECTABLE_NODES=$'SG-slower\nJP-faster'
set_delay "SG-slower" 120
set_delay "JP-faster" 100
switch_to_best_node
assert_selected "JP-faster"

# Test 2: SG can beat JP when SG has better measured delay.
echo "  Test 2: SG beats JP with lower delay"
reset_case
SELECTABLE_NODES=$'JP-slower\nSG-faster'
set_delay "JP-slower" 120
set_delay "SG-faster" 100
switch_to_best_node
assert_selected "SG-faster"

# Test 3: A reachable JP/SG node beats a faster lower-tier node.
echo "  Test 3: reachable JP/SG beats faster lower-tier node"
reset_case
SELECTABLE_NODES=$'TW-fast\nJP-slow'
set_delay "TW-fast" 100
set_delay "JP-slow" 900
switch_to_best_node
assert_selected "JP-slow"

# Test 4: HK is still eligible, but only after all non-HK candidates fail.
echo "  Test 4: HK eligible when non-HK all dead"
reset_case
SELECTABLE_NODES=$'JP-dead\nUS-dead\nHK-live'
set_delay "JP-dead" 0
set_delay "US-dead" 0
set_delay "HK-live" 90
switch_to_best_node
assert_selected "HK-live"

# Test 5: A reachable non-HK beats a much faster HK because HK is last-resort.
echo "  Test 5: Non-HK beats much faster HK (HK last resort)"
reset_case
SELECTABLE_NODES=$'HK-fast\nTW-slow'
set_delay "HK-fast" 20
set_delay "TW-slow" 900
switch_to_best_node
assert_selected "TW-slow"

# Test 6: TW beats US when delays equal.
echo "  Test 6: TW preferred over US at equal delay"
reset_case
SELECTABLE_NODES=$'US-node\nTW-node'
set_delay "US-node" 100
set_delay "TW-node" 100
switch_to_best_node
assert_selected "TW-node"

# Test 7: Other non-HK beats much faster HK.
echo "  Test 7: Other non-HK beats much faster HK"
reset_case
SELECTABLE_NODES=$'HK-fast\nDE-slow'
set_delay "HK-fast" 20
set_delay "DE-slow" 900
switch_to_best_node
assert_selected "DE-slow"

echo ""

# ════════════════════════════════════════════
# Structural tests — function properties
# ════════════════════════════════════════════
echo "[Structural] function property tests"

# Verify no allow_hk parameter in function signature
sig=$(sed -n '/^switch_to_best_node() {/,/^log "/p' "$SCRIPT" | head -5 || true)
if echo "$sig" | grep -q 'allow_hk'; then
    check "No allow_hk parameter in switch_to_best_node()" 1
else
    check "No allow_hk parameter in switch_to_best_node()" 0
fi

# Verify single pass (no switch_to_best_node false/true calls anywhere)
false_calls=$(grep -c 'switch_to_best_node false' "$SCRIPT" || true)
true_calls=$(grep -c 'switch_to_best_node true' "$SCRIPT" || true)
[[ "${false_calls:-0}" -eq 0 ]] && [[ "${true_calls:-0}" -eq 0 ]]
check "No two-pass pattern (switch_to_best_node false/true) in entire script" $?

# Verify correct log message
grep -Fq 'JP/SG > TW > US > other non-HK > HK' "$SCRIPT"
check "Log message says 'JP/SG > TW > US > other non-HK > HK'" $?

# Verify old pattern removed
if grep -Fq 'SG > JP' "$SCRIPT"; then
    check "Old 'SG > JP' ranking pattern removed" 1
else
    check "Old 'SG > JP' ranking pattern removed" 0
fi

# Verify delay=0 exclusion exists in function body
func_body=$(sed -n '/^switch_to_best_node() {/,/^}/p' "$SCRIPT" || true)
echo "$func_body" | grep -q '\[ "\$delay" -eq 0 \]'
check "delay=0 exclusion condition exists in function body" $?

echo ""
echo "==============================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==============================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

echo "All node ranking policy tests passed ✓"
exit 0
