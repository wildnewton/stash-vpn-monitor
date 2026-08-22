#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$REPO_ROOT/vpn_monitor.sh"
INSTALLER="$REPO_ROOT/install_vpn_monitor.sh"
REPORT="$REPO_ROOT/vpn_report.py"

fail() {
    echo "$1" >&2
    exit 1
}

[ -f "$REPORT" ] || fail "Expected report implementation to live in vpn_report.py"

grep -Fq 'REPORT_SCRIPT="$SCRIPT_DIR/vpn_report.py"' "$MONITOR" \
    || fail "vpn_monitor.sh must resolve vpn_report.py next to itself"
grep -Fq '"$PYTHON_BIN" "$REPORT_SCRIPT" "$LOG_FILE" "$period"' "$MONITOR" \
    || fail "cmd_report must delegate to vpn_report.py"

# Installed and updated copies must remain runnable after the extraction.
grep -Fq 'REPORT_SCRIPT="vpn_report.py"' "$INSTALLER" \
    || fail "installer must declare vpn_report.py as an installed dependency"
grep -Fq 'cp "$SRC_REPORT_SCRIPT" "$INSTALL_REPORT_SCRIPT"' "$INSTALLER" \
    || fail "installer must copy vpn_report.py"
grep -Fq 'cp "$repo/vpn_report.py" "$dest_dir/vpn_report.py"' "$MONITOR" \
    || fail "--update must copy vpn_report.py"
grep -Fq 'vpn_report.py' "$MONITOR" \
    || fail "uninstall/update paths must know about vpn_report.py"

# The large embedded Python implementation should no longer live in the shell entrypoint.
if grep -Fq 'class Incident:' "$MONITOR"; then
    fail "vpn_monitor.sh still contains the embedded report implementation"
fi

echo "Report module layout tests passed"
