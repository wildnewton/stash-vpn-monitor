#!/usr/bin/env bash
set -euo pipefail

# Test: node ranking policy — validates the unified ranking without a live Stash API.
# Checks vpn_monitor.sh source for the region_bonus case statement, single-pass logic,
# absence of allow_hk parameter, and the correct log message.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/vpn_monitor.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: vpn_monitor.sh not found at $SCRIPT" >&2
    exit 1
fi

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

# Helper: run a command and return its exit code, even if set -e is active.
safe_run() {
    local rc=0
    "$@" || rc=$?
    return "$rc"
}

echo "=== Node Ranking Policy Tests ==="
echo ""

# --- Test 1: JP and SG both get bonus=0 (equal tier-0) ---
echo "[1] Region bonus values"

# Extract the case block inside switch_to_best_node for region_bonus
sg_line=$(grep -n '新加坡\*' "$SCRIPT" | head -1 || true)
jp_line=$(grep -n '日本\*' "$SCRIPT" | head -1 || true)
tw_line=$(grep -n '台湾\*' "$SCRIPT" | head -1 || true)
us_line=$(grep -n '美国\*' "$SCRIPT" | head -1 || true)
hk_line=$(grep -n '香港\*' "$SCRIPT" | head -1 || true)

safe_run echo "$sg_line" | grep -q 'region_bonus=0'
check "SG gets bonus=0" $?

safe_run echo "$jp_line" | grep -q 'region_bonus=0'
check "JP gets bonus=0 (equal tier-0 with SG)" $?

safe_run echo "$tw_line" | grep -q 'region_bonus=50'
check "TW gets bonus=50" $?

safe_run echo "$us_line" | grep -q 'region_bonus=80'
check "US gets bonus=80" $?

safe_run echo "$hk_line" | grep -q 'region_bonus=200'
check "HK gets bonus=200 (highest, last resort)" $?

# Verify default is 100 (other non-HK)
def_count=$(grep -c 'local region_bonus=100' "$SCRIPT" || true)
safe_run test "$def_count" -ge 1
check "Default region_bonus=100 (other non-HK)" $?

echo ""

# --- Test 2: delay=0 nodes are excluded ---
echo "[2] Delay-zero exclusion"

func_body=$(sed -n '/^switch_to_best_node() {/,/^}/p' "$SCRIPT" || true)
safe_run echo "$func_body" | grep -q '\[ "\$delay" -eq 0 \]'
check "delay=0 exclusion condition exists in function body" $?

echo ""

# --- Test 3: No allow_hk parameter ---
echo "[3] No allow_hk parameter"

sig=$(sed -n '/^switch_to_best_node() {/,/^log "/p' "$SCRIPT" | head -5 || true)
if safe_run echo "$sig" | grep -q 'allow_hk'; then
    check "No allow_hk parameter in switch_to_best_node()" 1
else
    check "No allow_hk parameter in switch_to_best_node()" 0
fi

echo ""

# --- Test 4: Single pass (no two-pass pattern) ---
echo "[4] Single pass (no two-pass pattern)"

# switch_to_best_node should NOT call itself
func_body=$(sed -n '/^switch_to_best_node() {/,/^}/p' "$SCRIPT" || true)
two_pass=$(echo "$func_body" | grep -c 'switch_to_best_node' || true)
safe_run test "$two_pass" -le 1
check "switch_to_best_node is self-contained (no recursive calls)" $?

# Check callers in recover() don't do two-pass
recover_body=$(sed -n '/^recover()/,/^}/p' "$SCRIPT" || true)
false_count=$(echo "$recover_body" | grep -c 'switch_to_best_node false' || true)
safe_run test "$false_count" -eq 0
check "recover() has no switch_to_best_node false calls" $?

true_count=$(echo "$recover_body" | grep -c 'switch_to_best_node true' || true)
safe_run test "$true_count" -eq 0
check "recover() has no switch_to_best_node true calls" $?

# Check try_alternative_configs too
alt_body=$(sed -n '/^try_alternative_configs/,/^}/p' "$SCRIPT" || true)
alt_false=$(echo "$alt_body" | grep -c 'switch_to_best_node false' || true)
safe_run test "$alt_false" -eq 0
check "try_alternative_configs() has no two-pass false/true" $?

# Check cmd_switch_to_best_node
cmd_body=$(sed -n '/^cmd_switch_to_best_node/,/^}/p' "$SCRIPT" || true)
cmd_false=$(echo "$cmd_body" | grep -c 'switch_to_best_node false' || true)
safe_run test "$cmd_false" -eq 0
check "cmd_switch_to_best_node() has no two-pass false/true" $?

echo ""

# --- Test 5: Log message says JP/SG > TW > US > other non-HK > HK ---
echo "[5] Log message correctness"

safe_run grep -Fq 'JP/SG > TW > US > other non-HK > HK' "$SCRIPT"
check "Log message says 'JP/SG > TW > US > other non-HK > HK'" $?

if safe_run grep -Fq 'SG > JP' "$SCRIPT"; then
    check "Old 'SG > JP' ranking pattern removed" 1
else
    check "Old 'SG > JP' ranking pattern removed" 0
fi

echo ""

# --- Summary ---
echo "==============================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==============================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

echo "All node ranking policy tests passed ✓"
exit 0