#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$REPO_ROOT/vpn_monitor.sh"
INSTALLER="$REPO_ROOT/install_vpn_monitor.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
FAKE_REPO="$tmpdir/repo"
dest="$tmpdir/bin"
mkdir -p "$FAKE_REPO" "$dest"

# Fake repo/install payloads exercise cmd_update without touching git or the
# real filesystem. The installed entrypoint must stay old when the new runtime
# cannot be copied.
printf 'new-monitor\n' > "$FAKE_REPO/vpn_monitor.sh"
printf 'new-runtime\n' > "$FAKE_REPO/vpn_runtime.sh"
printf 'new-switcher\n' > "$FAKE_REPO/stash_switch_config.py"
printf 'new-report\n' > "$FAKE_REPO/vpn_report.py"
printf 'old-monitor\n' > "$dest/vpn_monitor.sh"
printf 'old-runtime\n' > "$dest/vpn_runtime.sh"

config_file="$tmpdir/config"
cat > "$config_file" <<EOF
API_SECRET="test-secret"
LOG_FILE="$tmpdir/vpn_monitor.log"
CHECK_INTERVAL="300"
MONITOR_REPO="$FAKE_REPO"
INSTALL_DIR="$dest"
PYTHON_BIN="python3"
EOF

VPN_MONITOR_CONFIG="$config_file" source "$MONITOR"

detect_repo() { echo "$FAKE_REPO"; }
git() {
    case " $* " in
        *" pull "*) echo "Already up to date." ;;
        *" rev-parse "*) echo "deadbee" ;;
        *" log "*) echo "test update" ;;
        *) return 0 ;;
    esac
}
stat() { echo "fake-time"; return 0; }
cp() {
    if [ "$1" = "$FAKE_REPO/vpn_runtime.sh" ]; then
        return 1
    fi
    command cp "$1" "$2"
}

# vpn_monitor.sh itself intentionally does not enable errexit, so execute this
# fixture with the same shell option rather than inheriting the test harness -e.
output="$tmpdir/update.out"
set +e
cmd_update >"$output" 2>&1
update_rc=$?
set -e

fail=0
if [ "$update_rc" -eq 0 ]; then
    echo "FAIL: --update must fail when vpn_runtime.sh cannot be copied" >&2
    cat "$output" >&2
    fail=1
fi

if [ "$(cat "$dest/vpn_monitor.sh")" != "old-monitor" ]; then
    echo "FAIL: --update must not replace vpn_monitor.sh before required runtime copy succeeds" >&2
    fail=1
fi

# The installer has set -e, so ordering is sufficient for the same first-split
# safety property: install the new runtime before replacing the old entrypoint.
monitor_line=$(grep -nF 'cp "$SRC_SCRIPT" "$INSTALL_SCRIPT"' "$INSTALLER" | head -1 | cut -d: -f1)
runtime_line=$(grep -nF 'cp "$SRC_RUNTIME_MODULE" "$INSTALL_RUNTIME_MODULE"' "$INSTALLER" | head -1 | cut -d: -f1)
if [ -z "$monitor_line" ] || [ -z "$runtime_line" ] || [ "$runtime_line" -ge "$monitor_line" ]; then
    echo "FAIL: installer must copy vpn_runtime.sh before replacing vpn_monitor.sh" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "Update runtime failure tests passed"
