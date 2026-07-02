#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/vpn_monitor.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_python="$tmpdir/fake-python"
cat > "$fake_python" <<'SH'
#!/usr/bin/env sh
case "$*" in
  *"--status"*)
    echo "Current config: primary.yaml"
    ;;
  *"--list"*)
    echo "primary.yaml"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$fake_python"

config_file="$tmpdir/config"
cat > "$config_file" <<EOF
API_SECRET="test-secret"
PYTHON_BIN="$fake_python"
CHECK_INTERVAL="300"
LOG_FILE="$tmpdir/vpn_monitor.log"
EOF

run_monitor() {
    local output status
    set +e
    output="$(VPN_MONITOR_CONFIG="$config_file" bash "$SCRIPT" "$@" 2>&1)"
    status=$?
    set -e
    printf '%s\n' "$output"
    return "$status"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        echo "Actual output:" >&2
        printf '%s\n' "$haystack" >&2
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected output not to contain: $needle" >&2
        echo "Actual output:" >&2
        printf '%s\n' "$haystack" >&2
        exit 1
    fi
}

set +e
set_interval_output="$(run_monitor --set-interval)"
set_interval_status=$?
set -e
if [[ "$set_interval_status" -eq 0 ]]; then
    echo "Expected --set-interval without a value to fail with usage" >&2
    exit 1
fi
assert_contains "$set_interval_output" "用法: vpn_monitor.sh --set-interval <秒數>"
assert_not_contains "$set_interval_output" "unbound variable"

set +e
change_config_output="$(run_monitor --change-config)"
change_config_status=$?
set -e
if [[ "$change_config_status" -eq 0 ]]; then
    echo "Expected --change-config without alternatives to fail gracefully" >&2
    exit 1
fi
assert_contains "$change_config_output" "未指定 config，自動選擇"
assert_contains "$change_config_output" "沒有其他 config 可切換"
assert_not_contains "$change_config_output" "unbound variable"

echo "CLI missing optional argument tests passed"
