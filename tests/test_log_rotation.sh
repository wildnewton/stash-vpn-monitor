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

# A2. migration: a legacy active log can span many dates. Its archive name is
# based on the first timestamp, but pruning must preserve it while its latest
# timestamp is still within retention.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf '[2026-07-20 09:00:00] old legacy entry\n' > "$LOG_FILE"
printf '[2026-08-20 09:00:00] recent legacy entry\n' >> "$LOG_FILE"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "multi-day legacy archive is not pruned by its old filename" "[ -f \"${LOG_FILE}.2026-07-20\" ]"
check "multi-day legacy archive retains recent entries" "grep -q '2026-08-20 09:00:00' \"${LOG_FILE}.2026-07-20\""

# A3. a malformed leading line must not block rotation if later timestamped
# entries identify the log date.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf 'partial/corrupt line\n' > "$LOG_FILE"
printf '[2026-08-22 09:00:00] valid entry\n' >> "$LOG_FILE"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "finds first valid timestamp past malformed leading line" "[ -f \"${LOG_FILE}.2026-08-22\" ]"
check "archive preserves malformed line rather than discarding it" "grep -q 'partial/corrupt line' \"${LOG_FILE}.2026-08-22\""

# A4. never overwrite an existing same-date archive; preserve both segments.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf '[2026-08-01 08:00:00] earlier archived segment\n' > "${LOG_FILE}.2026-08-01"
printf '[2026-08-01 09:00:00] later active segment\n' > "$LOG_FILE"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "existing same-date archive content survives rotation" "grep -q 'earlier archived segment' \"${LOG_FILE}.2026-08-01\""
check "active same-date segment is preserved too" "grep -q 'later active segment' \"${LOG_FILE}.2026-08-01\""

# B. no rotation when first valid date == today
rm -f "$LOG_FILE" "${LOG_FILE}".*
: > "$LOG_FILE"
printf '[2026-08-23 09:00:00] 狀態: 正常\n' >> "$LOG_FILE"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "does not rotate when first valid date == today" "[ -f "$LOG_FILE" ] && [ ! -f "${LOG_FILE}.2026-08-23" ]"

# C. no active log: do not create one, but retention cleanup must still run.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf '[2026-07-01 09:00:00] expired archive entry\n' > "${LOG_FILE}.2026-07-01"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "does not create active log when absent" "[ ! -f \"$LOG_FILE\" ]"
check "prunes expired archive even when active log is absent" "[ ! -f \"${LOG_FILE}.2026-07-01\" ]"

# C2. even if the active log has no parseable timestamp, retention cleanup
# must still run instead of being permanently disabled by the bad first line.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf 'unparseable active content\n' > "$LOG_FILE"
printf 'old archive\n' > "${LOG_FILE}.2026-07-01"
VPN_LOG_DATE_OVERRIDE=2026-08-23 rotate_log
check "unparseable active log does not block pruning" "[ ! -f \"${LOG_FILE}.2026-07-01\" ]"
check "unparseable active log itself is preserved" "grep -q 'unparseable active content' \"$LOG_FILE\""

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

# Content timestamps, not just archive filename, define safe expiry for a
# multi-day archive created during migration.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf '[2026-07-20 09:00:00] old entry\n' > "${LOG_FILE}.2026-07-20"
printf '[2026-08-20 09:00:00] recent entry\n' >> "${LOG_FILE}.2026-07-20"
VPN_LOG_DATE_OVERRIDE="$TODAY" prune_old_logs
check "pruning keeps old-named archive with recent timestamped content" "[ -f \"${LOG_FILE}.2026-07-20\" ]"

# The latest timestamp is defined by time, not physical line order. Clock/timezone
# changes can make later-written lines older than earlier lines; a recent entry
# anywhere in the archive must protect it from premature pruning.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf '[2026-08-20 09:00:00] recent entry written first\n' > "${LOG_FILE}.2026-07-20"
printf '[2026-07-20 10:00:00] older timestamp written later\n' >> "${LOG_FILE}.2026-07-20"
VPN_LOG_DATE_OVERRIDE="$TODAY" prune_old_logs
check "pruning uses latest timestamp, not last physical timestamp" "[ -f \"${LOG_FILE}.2026-07-20\" ] && grep -q '2026-08-20 09:00:00' \"${LOG_FILE}.2026-07-20\""

# Content-aware protection must not leak expired archives forever: if every
# timestamp in an old-named archive is older than cutoff, it is still deleted.
rm -f "$LOG_FILE" "${LOG_FILE}".*
printf '[2026-07-01 09:00:00] expired entry one\n' > "${LOG_FILE}.2026-07-01"
printf '[2026-07-02 09:00:00] expired entry two\n' >> "${LOG_FILE}.2026-07-01"
VPN_LOG_DATE_OVERRIDE="$TODAY" prune_old_logs
check "deletes timestamped archive when all entries are expired" "[ ! -f \"${LOG_FILE}.2026-07-01\" ]"

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
