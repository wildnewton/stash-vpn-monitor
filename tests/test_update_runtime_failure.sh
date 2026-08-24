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
# real filesystem. Neither live half of the required monitor/runtime pair may
# change unless both new source files can first be copied successfully.
printf 'new-monitor\n' > "$FAKE_REPO/vpn_monitor.sh"
printf 'new-runtime\n' > "$FAKE_REPO/vpn_runtime.sh"
printf 'new-switcher\n' > "$FAKE_REPO/stash_switch_config.py"
printf 'new-report\n' > "$FAKE_REPO/vpn_report.py"

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

FAIL_COPY=""
cp() {
    if [ "$FAIL_COPY" = "runtime" ] && [ "$1" = "$FAKE_REPO/vpn_runtime.sh" ]; then
        return 1
    fi
    if [ "$FAIL_COPY" = "monitor" ] && [ "$1" = "$FAKE_REPO/vpn_monitor.sh" ]; then
        return 1
    fi
    command cp "$1" "$2"
}

run_copy_failure_case() {
    local failure="$1"
    local output="$tmpdir/update-$failure.out"

    printf 'old-monitor\n' > "$dest/vpn_monitor.sh"
    printf 'old-runtime\n' > "$dest/vpn_runtime.sh"
    FAIL_COPY="$failure"

    # vpn_monitor.sh intentionally does not enable errexit, so execute this
    # fixture with the same shell option rather than inheriting the harness -e.
    set +e
    cmd_update >"$output" 2>&1
    local update_rc=$?
    set -e

    if [ "$update_rc" -eq 0 ]; then
        echo "FAIL: --update must fail when $failure source cannot be copied" >&2
        cat "$output" >&2
        return 1
    fi
    if [ "$(cat "$dest/vpn_monitor.sh")" != "old-monitor" ]; then
        echo "FAIL: $failure copy failure must leave installed vpn_monitor.sh unchanged" >&2
        return 1
    fi
    if [ "$(cat "$dest/vpn_runtime.sh")" != "old-runtime" ]; then
        echo "FAIL: $failure copy failure must leave installed vpn_runtime.sh unchanged" >&2
        return 1
    fi
}

fail=0
run_copy_failure_case runtime || fail=1
run_copy_failure_case monitor || fail=1

# Installer must apply the same principle: stage both required files before
# replacing either live file. This is structural because executing the macOS
# installer in Linux CI would require mocking unrelated launchctl/plist behavior.
grep -Fq 'cp "$SRC_RUNTIME_MODULE" "$runtime_stage"' "$INSTALLER" || {
    echo "FAIL: installer must stage vpn_runtime.sh before live replacement" >&2
    fail=1
}
grep -Fq 'cp "$SRC_SCRIPT" "$script_stage"' "$INSTALLER" || {
    echo "FAIL: installer must stage vpn_monitor.sh before live replacement" >&2
    fail=1
}

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "Update runtime failure tests passed"
