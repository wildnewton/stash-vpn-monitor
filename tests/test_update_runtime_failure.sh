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

reset_installed_files() {
    printf 'old-monitor\n' > "$dest/vpn_monitor.sh"
    printf 'old-runtime\n' > "$dest/vpn_runtime.sh"
    printf 'old-switcher\n' > "$dest/stash_switch_config.py"
    printf 'old-report\n' > "$dest/vpn_report.py"
    chmod 755 "$dest/vpn_monitor.sh" "$dest/stash_switch_config.py"
    chmod 644 "$dest/vpn_runtime.sh" "$dest/vpn_report.py"
}

run_copy_failure_case() {
    local failure="$1"
    local output="$tmpdir/update-$failure.out"

    reset_installed_files
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

run_success_case() {
    local output="$tmpdir/update-success.out"
    local old_umask

    reset_installed_files
    FAIL_COPY=""

    # Staged files are newly created, unlike the pre-refactor direct copy into
    # existing destinations. A restrictive umask must not make the installed
    # monitor unreadable/unexecutable or the runtime unreadable.
    old_umask=$(umask)
    umask 0777
    set +e
    cmd_update >"$output" 2>&1
    local update_rc=$?
    set -e
    umask "$old_umask"

    if [ "$update_rc" -ne 0 ]; then
        echo "FAIL: --update success path returned $update_rc" >&2
        cat "$output" >&2
        return 1
    fi

    local case_failed=0
    if [ ! -r "$dest/vpn_monitor.sh" ] || [ ! -x "$dest/vpn_monitor.sh" ]; then
        echo "FAIL: updated vpn_monitor.sh must remain owner-readable/executable under restrictive umask" >&2
        case_failed=1
    fi
    if [ ! -r "$dest/vpn_runtime.sh" ]; then
        echo "FAIL: updated vpn_runtime.sh must remain owner-readable under restrictive umask" >&2
        case_failed=1
    fi

    # Restore read permission only for content assertions if the permission
    # checks above intentionally failed on the RED implementation.
    chmod u+r "$dest/vpn_monitor.sh" "$dest/vpn_runtime.sh" 2>/dev/null || true
    if [ "$(cat "$dest/vpn_monitor.sh")" != "new-monitor" ]; then
        echo "FAIL: successful --update must install the new vpn_monitor.sh" >&2
        case_failed=1
    fi
    if [ "$(cat "$dest/vpn_runtime.sh")" != "new-runtime" ]; then
        echo "FAIL: successful --update must install the new vpn_runtime.sh" >&2
        case_failed=1
    fi
    if find "$dest" -maxdepth 1 -name '.vpn_*.new.*' -print -quit | grep -q .; then
        echo "FAIL: successful --update must not leave staged monitor/runtime files behind" >&2
        case_failed=1
    fi

    [ "$case_failed" -eq 0 ]
}

fail=0
run_copy_failure_case runtime || fail=1
run_copy_failure_case monitor || fail=1
run_success_case || fail=1

# Installer must apply the same staging and permission guarantees. This remains
# structural because executing the macOS installer in Linux CI would require
# mocking unrelated launchctl/plist behavior.
grep -Fq 'cp "$SRC_RUNTIME_MODULE" "$runtime_stage"' "$INSTALLER" || {
    echo "FAIL: installer must stage vpn_runtime.sh before live replacement" >&2
    fail=1
}
grep -Fq 'cp "$SRC_SCRIPT" "$script_stage"' "$INSTALLER" || {
    echo "FAIL: installer must stage vpn_monitor.sh before live replacement" >&2
    fail=1
}
grep -Fq 'chmod u+r "$runtime_stage"' "$INSTALLER" || {
    echo "FAIL: installer must guarantee owner-read permission on staged vpn_runtime.sh" >&2
    fail=1
}
grep -Fq 'chmod u+rx "$script_stage"' "$INSTALLER" || {
    echo "FAIL: installer must guarantee owner read/execute permission on staged vpn_monitor.sh" >&2
    fail=1
}

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "Update runtime failure/success tests passed"
