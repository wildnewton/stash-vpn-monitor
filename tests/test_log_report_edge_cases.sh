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

echo "Log report edge-case tests passed"
