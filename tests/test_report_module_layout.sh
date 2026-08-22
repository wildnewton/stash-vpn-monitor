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

# Installed, updated, and uninstalled copies must remain complete after extraction.
grep -Fq 'REPORT_SCRIPT="vpn_report.py"' "$INSTALLER" \
    || fail "installer must declare vpn_report.py as an installed dependency"
grep -Fq 'cp "$SRC_REPORT_SCRIPT" "$INSTALL_REPORT_SCRIPT"' "$INSTALLER" \
    || fail "installer must copy vpn_report.py"
grep -Fq 'cp "$repo/vpn_report.py" "$dest_dir/vpn_report.py"' "$MONITOR" \
    || fail "--update must copy vpn_report.py"
grep -Fq 'for f in vpn_monitor.sh stash_switch_config.py vpn_report.py; do' "$MONITOR" \
    || fail "uninstall must remove vpn_report.py"

# The large embedded Python implementation should no longer live in the shell entrypoint.
if grep -Fq 'class Incident:' "$MONITOR"; then
    fail "vpn_monitor.sh still contains the embedded report implementation"
fi

# Upgrade migration: an old installed updater cannot know to copy the newly added
# vpn_report.py on its first update. The new main script must therefore still be
# able to use the freshly pulled repo copy until a later update/install copies it
# next to the installed executable.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"
cp "$MONITOR" "$tmpdir/bin/vpn_monitor.sh"
chmod +x "$tmpdir/bin/vpn_monitor.sh"

log_file="$tmpdir/vpn_monitor.log"
config_file="$tmpdir/config"
printf '[2026-08-22 08:30:00] 狀態: 正常（Ping + HTTP 均正常）\n' > "$log_file"
cat > "$config_file" <<EOF
API_SECRET="test-secret"
LOG_FILE="$log_file"
MONITOR_REPO="$REPO_ROOT"
PYTHON_BIN="python3"
EOF

migration_output="$(
    VPN_MONITOR_CONFIG="$config_file" \
    VPN_REPORT_NOW="2026-08-22 09:00:00" \
        bash "$tmpdir/bin/vpn_monitor.sh" --report 1h 2>&1
)" || fail "first-update migration state must still support --report"
[[ "$migration_output" == *"Status: HEALTHY"* ]] \
    || fail "first-update migration report did not use the repo copy of vpn_report.py"

echo "Report module layout tests passed"
