#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$REPO_ROOT/vpn_report.py"
TEST_NOW="2026-08-22 08:30:00"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
log_file="$tmpdir/vpn_monitor.log"

cat > "$log_file" <<'EOF'
[2026-08-22 08:00:00] 狀態: 全部檢測失敗 — 將重試 5 次再確認...
[2026-08-22 08:01:00]     警告: 節點切換失敗（目標: SG（Premium）），嘗試下一個
[2026-08-22 08:02:00]     節點切換成功: JP — Tokyo — 同步 GUI（重啟 Stash）
[2026-08-22 08:03:00]     連通性驗證失敗 — SG 在 5 次重試後 Premium 在 5 次重試後仍不可用，嘗試下一個候選
[2026-08-22 08:04:00]     成功切換到: JP ✓ Premium ✓
[2026-08-22 08:05:00] 恢復成功（節點切換後）✓
EOF

output="$(VPN_REPORT_NOW="$TEST_NOW" python3 "$REPORT" "$log_file" 1h)"

assert_contains() {
    local needle="$1"
    if [[ "$output" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        echo "Actual output:" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

# Node names come from subscriptions and may legitimately contain punctuation
# also used by the human-readable log suffixes. Parsing must preserve the full name.
assert_contains "node switch API failed: SG（Premium）"
assert_contains "node switch API success: JP — Tokyo"
assert_contains "connectivity failed after switch: SG 在 5 次重試後 Premium"
assert_contains "connectivity verified: JP ✓ Premium"
assert_contains "SG 在 5 次重試後 Premium — post-switch connectivity failures: 1"

# A syntactically shaped but unrepresentably large period must fail cleanly,
# not expose a Python traceback.
set +e
overflow_output="$(python3 "$REPORT" "$log_file" 1000000000d 2>&1)"
overflow_status=$?
set -e
if [ "$overflow_status" -eq 0 ]; then
    echo "Expected an overflowing report period to fail" >&2
    exit 1
fi
if [[ "$overflow_output" != *"Invalid report period: 1000000000d"* ]]; then
    echo "Expected overflowing period to fail with a clear validation error" >&2
    printf '%s\n' "$overflow_output" >&2
    exit 1
fi
if [[ "$overflow_output" == *"Traceback"* ]]; then
    echo "Overflowing report period must not expose a traceback" >&2
    printf '%s\n' "$overflow_output" >&2
    exit 1
fi

# Production-log patterns: routine retry self-recovery should be aggregated,
# while actual recovery-flow escalation remains individually useful.
cat > "$log_file" <<'EOF'
[2026-08-22 07:01:40] 狀態: Ping 正常，HTTP 代理失敗 — 將重試 5 次再確認...
[2026-08-22 07:02:00]   重試 #1: 已恢復 ✓
[2026-08-22 07:40:00] 狀態: Ping 正常，HTTP 代理失敗 — 將重試 5 次再確認...
[2026-08-22 07:41:00]   5 次重試後仍失敗，啟動恢復流程...
[2026-08-22 07:41:10] === 開始恢復流程 ===
[2026-08-22 07:42:00] 恢復成功（config 刷新後）✓
[2026-08-22 07:50:00] 狀態: 全部檢測失敗 — 將重試 5 次再確認...
[2026-08-22 07:51:00] === 開始恢復流程 ===
[2026-08-22 07:51:40]     測試 27 個節點，25 個可達
[2026-08-22 07:52:00]     節點切換成功: SG-01 — 同步 GUI（重啟 Stash）
[2026-08-22 07:53:00]     連通性驗證失敗 — SG-01 在 5 次重試後仍不可用，嘗試下一個候選
[2026-08-22 07:54:00]     節點切換成功: JP-01 — 同步 GUI（重啟 Stash）
[2026-08-22 07:55:00]     成功切換到: JP-01 ✓
[2026-08-22 07:55:00] 恢復成功（節點切換後）✓
[2026-08-22 08:00:00] 狀態: Ping 正常，HTTP 代理失敗 — 將重試 5 次再確認...
[2026-08-22 08:01:00] === 開始恢復流程 ===
[2026-08-22 08:02:00]     測試 27 個節點，0 個可達
[2026-08-22 08:03:00] >>> Step 3: 強制刷新訂閱（重新從機場拉節點列表）...
[2026-08-22 08:04:00]     刷新後可用節點數: 56
[2026-08-22 08:05:00] 恢復成功（刷新訂閱後）✓
EOF

production_output="$(VPN_REPORT_NOW="$TEST_NOW" python3 "$REPORT" "$log_file" 1h)"

assert_production_contains() {
    local needle="$1"
    if [[ "$production_output" != *"$needle"* ]]; then
        echo "Expected production-pattern output to contain: $needle" >&2
        echo "Actual output:" >&2
        printf '%s\n' "$production_output" >&2
        exit 1
    fi
}

assert_production_not_contains() {
    local needle="$1"
    if [[ "$production_output" == *"$needle"* ]]; then
        echo "Expected production-pattern output not to contain: $needle" >&2
        echo "Actual output:" >&2
        printf '%s\n' "$production_output" >&2
        exit 1
    fi
}

assert_production_contains "Incidents: 4"
assert_production_contains "Recovered: 4"
assert_production_contains "Unresolved: 0"
assert_production_contains "Failure types"
assert_production_contains "HTTP proxy failure with Ping healthy: 3"
assert_production_contains "Total connectivity failure: 1"
assert_production_contains "Recovery depth"
assert_production_contains "Confirmation retry: 1"
assert_production_contains "Config refresh: 1"
assert_production_contains "Node switch: 1"
assert_production_contains "Subscription refresh: 1"
assert_production_contains "Alternate config: 0"
assert_production_contains "Recovery-flow average: 4m 0s"
assert_production_contains "Recovery-flow longest: 5m 0s"
assert_production_contains "Node-switch candidate churn"
assert_production_contains "2 candidates: 1"
assert_production_contains "Severe events"
assert_production_contains "0/27 candidates reachable"
assert_production_contains "subscription refresh -> 56 runtime nodes"
assert_production_contains "Significant incidents / Timeline"

# The routine retry-only incident is aggregated rather than dumped as a separate timeline item.
assert_production_not_contains "07:01:40  connectivity issue detected"
# There must not be a second standalone Timeline section duplicating the significant incidents.
assert_production_not_contains $'\nTimeline\n'

echo "Log report edge-case tests passed"
