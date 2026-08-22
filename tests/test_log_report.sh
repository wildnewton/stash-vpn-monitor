#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/vpn_monitor.sh"
TEST_NOW="2026-08-22 08:00:00"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env sh
touch "$VPN_REPORT_CURL_SENTINEL"
exit 1
SH
chmod +x "$fakebin/curl"

config_file="$tmpdir/config"
log_file="$tmpdir/vpn_monitor.log"
curl_sentinel="$tmpdir/curl-called"
cat > "$config_file" <<EOF
API_SECRET="test-secret"
CHECK_INTERVAL="300"
LOG_FILE="$log_file"
EOF

stamp_ago() {
    python3 - "$TEST_NOW" "$1" <<'PY'
from datetime import datetime, timedelta
import sys
base = datetime.strptime(sys.argv[1], '%Y-%m-%d %H:%M:%S')
seconds = int(sys.argv[2])
print((base - timedelta(seconds=seconds)).strftime('%Y-%m-%d %H:%M:%S'))
PY
}

write_log() {
    : > "$log_file"
    while [ "$#" -gt 0 ]; do
        printf '[%s] %s\n' "$(stamp_ago "$1")" "$2" >> "$log_file"
        shift 2
    done
}

run_report() {
    PATH="$fakebin:$PATH" \
    VPN_REPORT_CURL_SENTINEL="$curl_sentinel" \
    VPN_REPORT_NOW="$TEST_NOW" \
    VPN_MONITOR_CONFIG="$config_file" \
        bash "$SCRIPT" --report "$@" 2>&1
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

# Missing and invalid periods must fail clearly without falling into monitor mode.
set +e
missing_output="$(run_report)"
missing_status=$?
set -e
if [ "$missing_status" -eq 0 ]; then
    echo "Expected --report without a period to fail" >&2
    exit 1
fi
assert_contains "$missing_output" "Usage: vpn_monitor.sh --report <period>"

set +e
invalid_output="$(run_report 2weeks)"
invalid_status=$?
set -e
if [ "$invalid_status" -eq 0 ]; then
    echo "Expected an invalid report period to fail" >&2
    exit 1
fi
assert_contains "$invalid_output" "Invalid report period"

# Healthy window stays concise and excludes events outside the requested period.
rm -f "$curl_sentinel"
write_log \
    7200 "狀態: 正常（Ping + HTTP 均正常）" \
    3000 "狀態: 正常（Ping + HTTP 均正常）" \
    1200 "狀態: HTTP 正常，Ping 失敗（可接受）"
healthy_output="$(run_report 1h)"
assert_contains "$healthy_output" "VPN Monitor Report — past 1h"
assert_contains "$healthy_output" "Status: HEALTHY"
assert_contains "$healthy_output" "Incidents: 0"
assert_contains "$healthy_output" "Node switches: 0"
assert_contains "$healthy_output" "Subscription refreshes: 0"
assert_contains "$healthy_output" "Config switches: 0"
assert_contains "$healthy_output" "No connectivity incidents detected."
assert_not_contains "$healthy_output" "Uptime:"
if [ -e "$curl_sentinel" ]; then
    echo "Report mode must not call the Stash/API curl path" >&2
    exit 1
fi

# Multiple retries/actions inside one failure->recovery sequence are one incident.
# A node can be API-switched successfully yet still fail post-switch connectivity.
rm -f "$curl_sentinel"
write_log \
    14400 "狀態: 全部檢測失敗 — 將重試 5 次再確認..." \
    14280 "恢復成功（config 刷新後）✓" \
    10800 "狀態: 正常（Ping + HTTP 均正常）" \
    6000 "狀態: 全部檢測失敗 — 將重試 5 次再確認..." \
    5940 "=== 開始恢復流程 ===" \
    5880 "    節點切換成功: SG-02 — 同步 GUI（重啟 Stash）" \
    5820 "    連通性驗證失敗 — SG-02 在 5 次重試後仍不可用，嘗試下一個候選" \
    5760 "    節點切換成功: JP-02 — 同步 GUI（重啟 Stash）" \
    5700 "    成功切換到: JP-02 ✓" \
    5700 "恢復成功（節點切換後）✓" \
    3600 "狀態: Ping 正常，HTTP 代理失敗 — 將重試 5 次再確認..." \
    3540 ">>> Step 3: 強制刷新訂閱（重新從機場拉節點列表）..." \
    3480 "  ✓ Config 切換成功: backup.yaml" \
    3420 "恢復成功（刷新訂閱後）✓" \
    1200 "狀態: 全部檢測失敗 — 將重試 5 次再確認..." \
    1140 "  5 次重試後仍失敗，啟動恢復流程..."
incident_output="$(run_report 2h)"
assert_contains "$incident_output" "Status: ATTENTION"
assert_contains "$incident_output" "Incidents: 3"
assert_contains "$incident_output" "Recovered: 2"
assert_contains "$incident_output" "Unresolved: 1"
assert_contains "$incident_output" "Node switches: 2"
assert_contains "$incident_output" "Subscription refreshes: 1"
assert_contains "$incident_output" "Config switches: 1"
assert_contains "$incident_output" "Average recovery: 4m 0s"
assert_contains "$incident_output" "Longest recovery: 5m 0s"
assert_contains "$incident_output" "SG-02"
assert_contains "$incident_output" "post-switch connectivity failures: 1"
assert_contains "$incident_output" "Incident 1"
assert_contains "$incident_output" "Incident 2"
assert_contains "$incident_output" "Incident 3"
assert_contains "$incident_output" "unresolved"
assert_contains "$incident_output" "Timeline"
assert_not_contains "$incident_output" "Uptime:"
if [ -e "$curl_sentinel" ]; then
    echo "Report mode must remain log-only even for incident reports" >&2
    exit 1
fi

# Later healthy observation closes an incident even if no explicit recover() success line exists.
write_log \
    7200 "狀態: 正常（Ping + HTTP 均正常）" \
    1800 "狀態: 全部檢測失敗 — 將重試 5 次再確認..." \
    1200 "狀態: 正常（Ping + HTTP 均正常）"
observed_recovery_output="$(run_report 1h)"
assert_contains "$observed_recovery_output" "Incidents: 1"
assert_contains "$observed_recovery_output" "Recovered: 1"
assert_contains "$observed_recovery_output" "Unresolved: 0"
assert_contains "$observed_recovery_output" "Average recovery: 10m 0s"

# If the log itself starts after the requested cutoff, disclose partial coverage.
write_log \
    172800 "狀態: 正常（Ping + HTTP 均正常）" \
    3600 "狀態: 正常（Ping + HTTP 均正常）"
partial_output="$(run_report 7d)"
assert_contains "$partial_output" "Log coverage: PARTIAL"
assert_contains "$partial_output" "Available log begins:"
assert_contains "$partial_output" "Incidents: 0"

echo "Log report tests passed"
