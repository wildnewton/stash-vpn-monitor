#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$REPO_ROOT/vpn_monitor.sh"
RUNTIME="$REPO_ROOT/vpn_runtime.sh"
INSTALLER="$REPO_ROOT/install_vpn_monitor.sh"
NODE_TEST="$REPO_ROOT/tests/test_node_ranking_policy.sh"
ROTATION_TEST="$REPO_ROOT/tests/test_log_rotation.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ -f "$RUNTIME" ] || fail "expected runtime implementation to live in vpn_runtime.sh"

grep -Eq '^switch_to_best_node\(\)' "$RUNTIME" \
    || fail "vpn_runtime.sh must own switch_to_best_node()"
grep -Eq '^recover\(\)' "$RUNTIME" \
    || fail "vpn_runtime.sh must own recover()"
if grep -Eq '^switch_to_best_node\(\)|^recover\(\)' "$MONITOR"; then
    fail "vpn_monitor.sh must not retain duplicate runtime/recovery definitions"
fi

# The runtime module is a sourceable function library: loading it must not require
# a user config file or execute monitor behavior.
bash -c 'set -u; source "$1"; declare -F switch_to_best_node >/dev/null; declare -F recover >/dev/null' _ "$RUNTIME" \
    || fail "vpn_runtime.sh must be directly sourceable without side effects"

# The executable must locate siblings from its own file path, source the runtime,
# and remain safe to source from tests without dispatching a command.
grep -Fq 'BASH_SOURCE[0]' "$MONITOR" \
    || fail "vpn_monitor.sh must resolve its own path with BASH_SOURCE[0]"
grep -Fq 'RUNTIME_SCRIPT="$SCRIPT_DIR/vpn_runtime.sh"' "$MONITOR" \
    || fail "vpn_monitor.sh must resolve vpn_runtime.sh next to itself"
grep -Fq 'source "$RUNTIME_SCRIPT"' "$MONITOR" \
    || fail "vpn_monitor.sh must source vpn_runtime.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
log_file="$tmpdir/vpn_monitor.log"
config_file="$tmpdir/config"
cat > "$config_file" <<EOF
API_SECRET="test-secret"
LOG_FILE="$log_file"
CHECK_INTERVAL="300"
MONITOR_REPO="$REPO_ROOT"
PYTHON_BIN="python3"
EOF

VPN_MONITOR_CONFIG="$config_file" bash -c 'source "$1"; declare -F cmd_monitor >/dev/null' _ "$MONITOR" \
    || fail "vpn_monitor.sh must be directly sourceable"
[ ! -s "$log_file" ] \
    || fail "sourcing vpn_monitor.sh must not execute CLI dispatch"

# Existing behavioral tests must consume supported source boundaries rather than
# manufacturing a pseudo-library by truncating production source at a comment.
if grep -Fq "sed '/^# ===================== 入口/,$d'" "$NODE_TEST"; then
    fail "node ranking tests must source vpn_runtime.sh directly"
fi
if grep -Fq "sed '/^# ===================== 入口/,$d'" "$ROTATION_TEST"; then
    fail "log rotation tests must source production source directly"
fi

# Installed, updated, and uninstalled copies must include the new runtime file.
grep -Fq 'RUNTIME_MODULE="vpn_runtime.sh"' "$INSTALLER" \
    || fail "installer must declare vpn_runtime.sh"
grep -Fq 'cp "$SRC_RUNTIME_MODULE" "$INSTALL_RUNTIME_MODULE"' "$INSTALLER" \
    || fail "installer must copy vpn_runtime.sh"
grep -Fq 'cp "$repo/vpn_runtime.sh" "$dest_dir/vpn_runtime.sh"' "$MONITOR" \
    || fail "--update must copy vpn_runtime.sh"
grep -Fq 'for f in vpn_monitor.sh vpn_runtime.sh stash_switch_config.py vpn_report.py; do' "$MONITOR" \
    || fail "uninstall must remove vpn_runtime.sh"

# First-update migration: an old installed updater cannot know about the newly
# introduced runtime file. After it copies the new vpn_monitor.sh, that script
# must be able to source the freshly pulled repo copy via MONITOR_REPO until the
# next update/install places vpn_runtime.sh beside the executable.
mkdir -p "$tmpdir/bin"
cp "$MONITOR" "$tmpdir/bin/vpn_monitor.sh"
chmod +x "$tmpdir/bin/vpn_monitor.sh"
printf '[2026-08-22 08:30:00] 狀態: 正常（Ping + HTTP 均正常）\n' > "$log_file"

migration_output="$(
    VPN_MONITOR_CONFIG="$config_file" \
    VPN_REPORT_NOW="2026-08-22 09:00:00" \
        bash "$tmpdir/bin/vpn_monitor.sh" --report 1h 2>&1
)" || fail "first-update migration must work before vpn_runtime.sh is installed beside vpn_monitor.sh"
[[ "$migration_output" == *"Status: HEALTHY"* ]] \
    || fail "first-update migration did not use repo runtime/report copies"

echo "Runtime module layout tests passed"
