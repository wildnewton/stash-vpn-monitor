#!/usr/bin/env bash
# Tests for Issue #15: time-based log rotation + 30-day retention.
# Sources only the function section of vpn_monitor.sh (everything before 入口),
# then drives rotate_log / prune_old_logs / cmd_uninstall directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/vpn_monitor.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

lib_file="$tmpdir/lib.sh"
sed '/^# ===================== 入口/,$d' "$SCRIPT" > "$lib_file"

config_file="$tmpdir/config"
: > "$config_file"

# ISO date + N days (portable via python). $1 base YYYY-MM-DD, $2 delta (neg = past).
iso_days() {
    python3 - "$1" "$2" <<'PY'
from datetime import datetime, timedelta
import sys
base = datetime.strptime(sys.argv[1], '%Y-%m-%d')
print((base + timedelta(days=int(sys.argv[2]))).strftime('%Y-%m-%d'))
PY
}

TODAY="${VPN_LOG_DATE_OVERRIDE:-2026-08-23}"

export LOG_FILE="$tmpdir/vpn_monitor.log"
export LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
export VPN_LOG_DATE_OVERRIDE="$TODAY"
VPN_MONITOR_CONFIG="$config_file" source "$lib_file"

pass=0
fail=0
check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        pass=$((pass + 1))
        echo "  ✓ $desc"
    else
        fail=$((fail + 1))
        echo "  ✗ $desc" >&2
    fi
}

# ---- rotate_log ----
echo "rotate_log:"

# A. archive when first-line date != today
: > "$LOG_FILE"
printf '[2026-08-01 09:00:00] 狀態: 正常（Ping + HTTP 均正常）\n' >> "$LOG_FILE"
printf '[2026-08-01 10:00:00] 狀態: 正常\n' >> "$LOG_FILE"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "archives active log to vpn_monitor.log.YYYY-MM-DD" "[ -f "${LOG_FILE}.2026-08-01" ]"
check "archive keeps original content" "grep -q '2026-08-01 09:00:00' "${LOG_FILE}.2026-08-01""
check "active log no longer holds the archived observations" "! grep -q 'Ping + HTTP 均正常' "$LOG_FILE""

# B. no rotation when first-line date == today
: > "$LOG_FILE"
printf '[2026-08-23 09:00:00] 狀態: 正常\n' >> "$LOG_FILE"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "does not rotate when first-line date == today" "[ -f "$LOG_FILE" ] && [ ! -f "${LOG_FILE}.2026-08-23" ]"

# C. no-op when log absent
rm -f "$LOG_FILE" "${LOG_FILE}".*
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "no-op when log file absent" "[ ! -f "$LOG_FILE" ]"

# ---- prune_old_logs ----
echo "prune_old_logs:"

rm -f "$LOG_FILE" "${LOG_FILE}".*
keep1="$TODAY"                                   # today
keep2="$(iso_days "$TODAY" -29)"                 # within window
keep3="$(iso_days "$TODAY" -30)"                 # exactly cutoff (retained)
del1="$(iso_days "$TODAY" -31)"                  # older than window (deleted)
printf 'x\n' > "${LOG_FILE}.${keep1}"
printf 'x\n' > "${LOG_FILE}.${keep2}"
printf 'x\n' > "${LOG_FILE}.${keep3}"
printf 'x\n' > "${LOG_FILE}.${del1}"
printf 'x\n' > "${LOG_FILE}.old"                 # legacy, must survive
printf 'x\n' > "${LOG_FILE}.bak"                 # unrelated suffix, must survive
VPN_LOG_DATE_OVERRIDE="$TODAY" prune_old_logs
check "retains dated logs within 30d window" "[ -f "${LOG_FILE}.${keep1}" ] && [ -f "${LOG_FILE}.${keep2}" ] && [ -f "${LOG_FILE}.${keep3}" ]"
check "deletes dated logs older than retention" "[ ! -f "${LOG_FILE}.${del1}" ]"
check "preserves legacy .old" "[ -f "${LOG_FILE}.old" ]"
check "preserves unrelated suffix (.bak)" "[ -f "${LOG_FILE}.bak" ]"

# ---- cmd_uninstall log handling ----
echo "cmd_uninstall log handling:"

# D. --delete-logs removes dated archives too
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf 'x\n' > "${LOG_FILE}.2026-08-20"
printf 'x\n' > "${LOG_FILE}.old"
VPN_LOG_DATE_OVERRIDE="$TODAY" cmd_uninstall "" --delete-logs >/dev/null 2>&1 || true
check "delete-logs removes active log" "[ ! -f "$LOG_FILE" ]"
check "delete-logs removes legacy .old" "[ ! -f "${LOG_FILE}.old" ]"
check "delete-logs removes dated archives" "[ ! -f "${LOG_FILE}.2026-08-20" ]"

# E. keep_logs (default) preserves dated archives
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf 'x\n' > "${LOG_FILE}.2026-08-20"
VPN_LOG_DATE_OVERRIDE="$TODAY" cmd_uninstall "" >/dev/null 2>&1 || true
check "default keeps dated archives" "[ -f "${LOG_FILE}.2026-08-20" ]"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "All log rotation/retention tests passed ✓ ($pass checks)"
    exit 0
else
    echo "$fail checks FAILED, $pass passed" >&2
    exit 1
fi
