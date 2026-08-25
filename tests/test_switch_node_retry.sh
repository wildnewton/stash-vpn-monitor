#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$REPO_ROOT/vpn_runtime.sh"

# Exercise the real production switch_node() while replacing only its external
# API/process dependencies. State used by get_current_node() lives in files so
# it survives command-substitution subshells.
# shellcheck source=/dev/null
source "$RUNTIME"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
verify_values="$tmpdir/verify-values"
verify_index="$tmpdir/verify-index"

RETRY_INTERVAL=0
API_PUT_CALLS=0
RESTART_CALLS=0

log() { :; }
sleep() { :; }
get_routing_group() { echo "TEST-GROUP"; }
urlencode() { echo "$1"; }
close_connections() { :; }
jq() { echo '{}'; }
api_put() {
    API_PUT_CALLS=$((API_PUT_CALLS + 1))
    return 0
}
restart_stash() {
    RESTART_CALLS=$((RESTART_CALLS + 1))
    return 0
}

set_verifications() {
    : > "$verify_values"
    local value
    for value in "$@"; do
        printf '%s\n' "$value" >> "$verify_values"
    done
    echo 1 > "$verify_index"
}

get_current_node() {
    local index value
    index=$(cat "$verify_index")
    value=$(sed -n "${index}p" "$verify_values")
    echo $((index + 1)) > "$verify_index"
    echo "$value"
}

reset_counts() {
    API_PUT_CALLS=0
    RESTART_CALLS=0
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $message (expected=$expected actual=$actual)" >&2
        exit 1
    fi
}

echo "=== switch_node retry/verification tests ==="

# The selector can report the wrong node transiently. switch_node() must retry
# the API operation and only declare success after reading the requested target.
reset_counts
set_verifications "WRONG-1" "WRONG-2" "TARGET"
if ! switch_node "TARGET" 3; then
    echo "FAIL: switch_node should succeed when target verification passes on retry 3" >&2
    exit 1
fi
assert_eq 3 "$API_PUT_CALLS" "switch_node must retry API PUT until target is verified"
assert_eq 1 "$RESTART_CALLS" "switch_node must restart Stash exactly once after verified success"
assert_eq 4 "$(cat "$verify_index")" "switch_node must perform three target-verification reads"
echo "  ✓ verifies target and succeeds on third attempt"

# If the target never becomes current, all retries must be consumed and Stash
# must not be restarted as though the switch had succeeded.
reset_counts
set_verifications "WRONG-1" "WRONG-2" "WRONG-3"
if switch_node "TARGET" 3; then
    echo "FAIL: switch_node must fail when target is never verified" >&2
    exit 1
fi
assert_eq 3 "$API_PUT_CALLS" "switch_node must consume the configured retry budget"
assert_eq 0 "$RESTART_CALLS" "switch_node must not restart Stash without verified target selection"
assert_eq 4 "$(cat "$verify_index")" "switch_node must verify after every API attempt"
echo "  ✓ fails after full retry budget when target never verifies"

echo "switch_node retry/verification tests passed"
