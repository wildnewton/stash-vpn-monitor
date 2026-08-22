from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import textwrap

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
MONITOR = REPO_ROOT / "vpn_monitor.sh"
ENTRYPOINT_MARKER = "# ===================== 入口 ====================="


@pytest.fixture
def monitor_library(tmp_path):
    source = MONITOR.read_text()
    assert ENTRYPOINT_MARKER in source, "vpn_monitor.sh entrypoint marker changed"
    library = tmp_path / "vpn_monitor_lib.sh"
    library.write_text(source.split(ENTRYPOINT_MARKER, 1)[0])
    return library


def run_library(
    tmp_path: Path,
    monitor_library: Path,
    body: str,
    *,
    extra_env: dict[str, str] | None = None,
    timeout: int = 10,
) -> subprocess.CompletedProcess[str]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    config = tmp_path / "config"
    config.write_text(
        f'API_SECRET="test"\nLOG_FILE="{tmp_path / "monitor.log"}"\n'
        f'STASH_CONFIG_DIR="{tmp_path}"\n'
    )
    (tmp_path / "config.yaml").write_text("mode: rule\n")
    env = os.environ.copy()
    env.update(
        {
            "VPN_MONITOR_CONFIG": str(config),
            "MONITOR_LIBRARY": str(monitor_library),
            "TEST_TMPDIR": str(tmp_path),
        }
    )
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["bash", "-c", 'source "$MONITOR_LIBRARY"\n' + textwrap.dedent(body)],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    assert "syntax error" not in result.stderr.lower(), result.stderr
    return result


def normalized(value: str) -> str:
    return re.sub(r"[ _]", "-", value.strip().lower())


def resolver_case(tmp_path, monitor_library, rules: list[dict]) -> subprocess.CompletedProcess[str]:
    return run_library(
        tmp_path,
        monitor_library,
        r'''
        HTTP_URL="http://example.com/"
        api_get() {
            if [ "$1" = "/rules" ]; then
                printf '%s\n' "$RULES_JSON"
            fi
        }
        diagnostic_probe_route
        ''',
        extra_env={"RULES_JSON": json.dumps({"rules": rules})},
    )


def test_ordered_rule_resolver_uses_first_supported_effective_rule_and_never_match_fallback(
    tmp_path, monitor_library
):
    result = resolver_case(
        tmp_path,
        monitor_library,
        [
            {"type": "DOMAIN-SUFFIX", "payload": "example.com", "proxy": "First Effective"},
            {"type": "DOMAIN", "payload": "example.com", "proxy": "Later Exact"},
            {"type": "MATCH", "proxy": "Fallback"},
        ],
    )
    assert result.returncode == 0, result.stderr
    fields = result.stdout.strip().split("\t")
    assert fields == ["DOMAIN-SUFFIX", "example.com", "First Effective"]


def test_ordered_rule_resolver_stops_unresolved_at_earlier_potentially_applicable_unsupported_rule(
    tmp_path, monitor_library
):
    result = resolver_case(
        tmp_path,
        monitor_library,
        [
            {"type": "DOMAIN-KEYWORD", "payload": "example", "proxy": "Cannot Prove"},
            {"type": "DOMAIN", "payload": "example.com", "proxy": "Would Match Later"},
            {"type": "MATCH", "proxy": "Fallback"},
        ],
    )
    assert result.returncode == 0, result.stderr
    output = normalized(result.stdout)
    assert output.startswith("unresolved")
    assert "would-match-later" not in output
    assert "fallback" not in output


def tri_state_case(
    tmp_path,
    monitor_library,
    *,
    context: str,
    route_group: str = "Intended Group",
    intended_group: str = "Intended Group",
    selected_node: str = "CURRENT-NODE",
    expected_node: str = "",
    http_code: str = "204",
    rules_unresolved: bool = False,
) -> tuple[str, list[str], subprocess.CompletedProcess[str]]:
    if rules_unresolved:
        rules = [
            {"type": "DOMAIN-KEYWORD", "payload": "example", "proxy": route_group},
            {"type": "MATCH", "proxy": intended_group},
        ]
    else:
        rules = [
            {"type": "DOMAIN", "payload": "example.com", "proxy": route_group},
            {"type": "MATCH", "proxy": intended_group},
        ]
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        HTTP_URL="http://example.com/"
        PROBE_CONTEXT="$CASE_CONTEXT"
        CONNECTIVITY_CONTEXT="$CASE_CONTEXT"
        CONNECTIVITY_INTENDED_GROUP="$CASE_INTENDED_GROUP"
        CONNECTIVITY_EXPECTED_NODE="$CASE_EXPECTED_NODE"
        PREVIOUS_NODE="STALE-PRIOR-NODE"
        events="$TEST_TMPDIR/http-events"
        : > "$events"

        api_get() {
            case "$1" in
                /rules) printf '%s\n' "$CASE_RULES_JSON" ;;
                /proxies/*) jq -n --arg node "$CASE_SELECTED_NODE" '{now:$node}' ;;
            esac
        }
        get_routing_group() { echo "$CASE_INTENDED_GROUP"; }
        get_current_node() { echo "$CASE_SELECTED_NODE"; }
        ping() { return 0; }
        curl() {
            echo "http" >> "$events"
            printf '%s' "$CASE_HTTP_CODE"
        }

        status=$(check_connectivity "$CASE_CONTEXT" "$CASE_INTENDED_GROUP" "$CASE_EXPECTED_NODE")
        printf 'RESULT=%s\n' "$status"
        ''',
        extra_env={
            "CASE_CONTEXT": context,
            "CASE_ROUTE_GROUP": route_group,
            "CASE_INTENDED_GROUP": intended_group,
            "CASE_SELECTED_NODE": selected_node,
            "CASE_EXPECTED_NODE": expected_node,
            "CASE_HTTP_CODE": http_code,
            "CASE_RULES_JSON": json.dumps({"rules": rules}),
        },
    )
    status_lines = [line for line in result.stdout.splitlines() if line.startswith("RESULT=")]
    status = normalized(status_lines[-1].split("=", 1)[1]) if status_lines else "missing"
    events_file = tmp_path / "http-events"
    events = events_file.read_text().splitlines() if events_file.exists() else []
    return status, events, result


@pytest.mark.parametrize("context", ["monitor", "status", "reload-follow-up", "remote-update-follow-up"])
@pytest.mark.parametrize("http_code", ["200", "204"])
def test_non_attributed_probe_contexts_require_correlation_but_not_prior_node_equality(
    tmp_path, monitor_library, context, http_code
):
    status, events, result = tri_state_case(
        tmp_path,
        monitor_library,
        context=context,
        selected_node="CURRENT-NODE",
        http_code=http_code,
    )
    assert result.returncode == 0, result.stderr
    assert status == "pass"
    assert events == ["http"]


def test_post_switch_probe_requires_expected_node_equality_before_http(tmp_path, monitor_library):
    matched, matched_events, _ = tri_state_case(
        tmp_path / "matched",
        monitor_library,
        context="post-switch",
        selected_node="JP-TARGET",
        expected_node="JP-TARGET",
    )
    mismatched, mismatched_events, _ = tri_state_case(
        tmp_path / "mismatched",
        monitor_library,
        context="post-switch",
        selected_node="FALLBACK-NODE",
        expected_node="JP-TARGET",
    )
    assert matched == "pass"
    assert matched_events == ["http"]
    assert mismatched == "measurement-unresolved"
    assert mismatched_events == []


def test_route_correlated_http_failure_is_validated_failure(tmp_path, monitor_library):
    status, events, result = tri_state_case(
        tmp_path,
        monitor_library,
        context="monitor",
        http_code="503",
    )
    assert result.returncode == 0, result.stderr
    assert status == "validated-failure"
    assert events == ["http"]


@pytest.mark.parametrize(
    "case",
    ["route-mismatch", "route-unresolved", "empty-readback", "expected-node-mismatch"],
)
def test_invalid_correlation_is_measurement_unresolved_without_issuing_http(
    tmp_path, monitor_library, case
):
    kwargs = {"context": "monitor"}
    if case == "route-mismatch":
        kwargs["route_group"] = "Other Group"
    elif case == "route-unresolved":
        kwargs["rules_unresolved"] = True
    elif case == "empty-readback":
        kwargs["selected_node"] = ""
    else:
        kwargs.update(
            context="post-switch",
            selected_node="OTHER-NODE",
            expected_node="JP-TARGET",
        )
    status, events, result = tri_state_case(tmp_path, monitor_library, **kwargs)
    assert result.returncode == 0, result.stderr
    assert status == "measurement-unresolved"
    assert events == []


def candidate_case(tmp_path, monitor_library, statuses: list[str]) -> subprocess.CompletedProcess[str]:
    return run_library(
        tmp_path,
        monitor_library,
        r'''
        RETRY_MAX=3
        RETRY_INTERVAL=0
        history="$TEST_TMPDIR/switch-history"
        checks="$TEST_TMPDIR/check-history"
        logs="$TEST_TMPDIR/logs"
        notifications="$TEST_TMPDIR/notifications"
        status_file="$TEST_TMPDIR/statuses"
        : > "$history"; : > "$checks"; : > "$logs"; : > "$notifications"

        log() { echo "$1" >> "$logs"; }
        notify() { echo "$1|$2" >> "$notifications"; }
        sleep() { :; }
        get_current_node() { echo CURRENT; }
        get_selectable_nodes() { printf '%s\n' "HK-FAST" "TW-SECOND" "JP-FIRST"; }
        test_node_delay() {
            case "$1" in
                HK-FAST) echo 10 ;;
                TW-SECOND) echo 20 ;;
                JP-FIRST) echo 900 ;;
            esac
        }
        switch_node() {
            echo "$1" >> "$history"
            echo "$1" > "$TEST_TMPDIR/current-candidate"
            return 0
        }
        check_connectivity() {
            local index status
            index=$(wc -l < "$checks" | tr -d ' ')
            echo "$(cat "$TEST_TMPDIR/current-candidate")" >> "$checks"
            status=$(sed -n "$((index + 1))p" "$status_file")
            echo "${status:-pass}"
        }

        switch_to_best_node
        rc=$?
        printf 'RC=%s\n' "$rc"
        printf 'SWITCHES=%s\n' "$(paste -sd, "$history")"
        printf 'CHECKS=%s\n' "$(paste -sd, "$checks")"
        printf '%s\n' '---LOGS---'
        cat "$logs"
        printf '%s\n' '---NOTIFICATIONS---'
        cat "$notifications"
        ''',
        extra_env={"CASE_STATUSES": "\n".join(statuses)},
    )


def write_candidate_statuses(tmp_path: Path, statuses: list[str]) -> None:
    (tmp_path / "statuses").write_text("\n".join(statuses) + "\n")


def test_validated_candidate_failure_consumes_full_window_before_next_ranked_candidate(
    tmp_path, monitor_library
):
    statuses = ["validated-failure"] * 3 + ["pass"]
    write_candidate_statuses(tmp_path, statuses)
    result = candidate_case(tmp_path, monitor_library, statuses)
    assert result.returncode == 0, result.stderr
    assert "RC=0" in result.stdout
    assert "SWITCHES=JP-FIRST,TW-SECOND" in result.stdout
    assert "CHECKS=JP-FIRST,JP-FIRST,JP-FIRST,TW-SECOND" in result.stdout


def test_mid_window_correlation_loss_is_terminal_without_candidate_failure_or_notification(
    tmp_path, monitor_library
):
    statuses = ["validated-failure", "measurement-unresolved", "pass"]
    write_candidate_statuses(tmp_path, statuses)
    result = candidate_case(tmp_path, monitor_library, statuses)
    assert result.returncode == 0, result.stderr
    assert "RC=2" in result.stdout
    assert "SWITCHES=JP-FIRST" in result.stdout
    assert "CHECKS=JP-FIRST,JP-FIRST" in result.stdout
    logs = result.stdout.split("---LOGS---", 1)[1].split("---NOTIFICATIONS---", 1)[0]
    notifications = result.stdout.split("---NOTIFICATIONS---", 1)[1].strip()
    assert "3 次重試後仍不可用" not in logs
    assert "成功切換" not in logs
    assert notifications == ""


def test_restart_group_change_is_terminal_unresolved_against_the_exact_switched_group(
    tmp_path, monitor_library
):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        RETRY_MAX=2
        RETRY_INTERVAL=0
        events="$TEST_TMPDIR/group-change-events"; : > "$events"
        group_file="$TEST_TMPDIR/runtime-group"; echo "Old Group" > "$group_file"
        old_node="$TEST_TMPDIR/old-node"; echo "ORIGINAL" > "$old_node"
        new_node="$TEST_TMPDIR/new-node"; echo "CANDIDATE-C" > "$new_node"
        tmpfile="$TEST_TMPDIR/return-trap-fallback"; : > "$tmpfile"

        eval "$(declare -f check_connectivity | sed '1s/check_connectivity/original_check_connectivity/')"

        log() { echo "LOG:$1" >> "$events"; }
        notify() { echo "NOTIFY:$1:$2" >> "$events"; }
        sleep() { :; }
        close_connections() { :; }
        refresh_config() { echo RUNTIME-RELOAD >> "$events"; return 1; }
        refresh_subscription() { echo REMOTE-UPDATE >> "$events"; return 2; }
        try_alternative_configs() { echo ALTERNATE-CONFIG >> "$events"; return 1; }
        get_routing_group() { cat "$group_file"; }
        urlencode() { echo "$1"; }
        get_selectable_nodes() { printf '%s\n' "CANDIDATE-C" "CANDIDATE-D"; }
        test_node_delay() {
            case "$1" in CANDIDATE-C) echo 10 ;; CANDIDATE-D) echo 20 ;; esac
        }
        api_get() {
            case "$1" in
                /rules) jq -n --arg group "$(cat "$group_file")" '{rules:[{type:"MATCH",proxy:$group}]}' ;;
                "/proxies/Old Group") jq -n --arg node "$(cat "$old_node")" '{now:$node}' ;;
                "/proxies/New Group") jq -n --arg node "$(cat "$new_node")" '{now:$node}' ;;
            esac
        }
        api_put() {
            local node
            node=$(echo "$2" | jq -r .name)
            echo "SWITCH:$1:$node" >> "$events"
            case "$1" in
                "/proxies/Old Group") echo "$node" > "$old_node" ;;
                "/proxies/New Group") echo "$node" > "$new_node" ;;
            esac
        }
        restart_stash() {
            echo RESTART-CHANGED-MATCH-TO-NEW-GROUP >> "$events"
            echo "New Group" > "$group_file"
            echo "CANDIDATE-C" > "$new_node"
            return 0
        }
        ping() { return 0; }
        curl() { echo HTTP-SHOULD-NOT-RUN >> "$events"; echo 204; }
        check_connectivity() {
            if [ "${1:-}" = "reload-follow-up" ]; then
                echo RELOAD-PROBE >> "$events"
                echo validated-failure
            else
                original_check_connectivity "$@"
            fi
        }

        recover
        rc=$?
        printf 'RC=%s\n' "$rc"
        cat "$events"
        ''',
    )
    assert result.returncode == 0, result.stderr
    output = result.stdout
    assert "RC=2" in output
    assert output.count("SWITCH:/proxies/Old Group:CANDIDATE-C") == 1
    assert "SWITCH:/proxies/Old Group:CANDIDATE-D" not in output
    assert "SWITCH:/proxies/New Group:CANDIDATE-D" not in output
    assert "HTTP-SHOULD-NOT-RUN" not in output
    assert "ALTERNATE-CONFIG" not in output
    assert "REMOTE-UPDATE" not in output
    assert "NOTIFY:" not in output
    assert "measurement-unresolved" in output
    assert "次重試後仍不可用" not in output
    assert "成功切換到" not in output


def test_actual_switched_group_keeps_full_retry_window_while_correlation_remains_valid(
    tmp_path, monitor_library
):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        RETRY_MAX=3
        RETRY_INTERVAL=0
        events="$TEST_TMPDIR/valid-group-events"; : > "$events"
        group_file="$TEST_TMPDIR/runtime-group"; echo "Old Group" > "$group_file"
        selected="$TEST_TMPDIR/selected"; echo "ORIGINAL" > "$selected"
        http_count="$TEST_TMPDIR/http-count"; echo 0 > "$http_count"
        tmpfile="$TEST_TMPDIR/return-trap-fallback"; : > "$tmpfile"

        log() { echo "LOG:$1" >> "$events"; }
        notify() { echo "NOTIFY:$1:$2" >> "$events"; }
        sleep() { :; }
        close_connections() { :; }
        get_routing_group() { cat "$group_file"; }
        urlencode() { echo "$1"; }
        get_selectable_nodes() { printf '%s\n' "JP-CANDIDATE-C" "TW-CANDIDATE-D"; }
        test_node_delay() {
            case "$1" in JP-CANDIDATE-C) echo 900 ;; TW-CANDIDATE-D) echo 20 ;; esac
        }
        api_get() {
            case "$1" in
                /rules) jq -n --arg group "$(cat "$group_file")" '{rules:[{type:"MATCH",proxy:$group}]}' ;;
                "/proxies/Old Group") jq -n --arg node "$(cat "$selected")" '{now:$node}' ;;
            esac
        }
        api_put() {
            local node
            node=$(echo "$2" | jq -r .name)
            echo "$node" > "$selected"
            echo "SWITCH:$node" >> "$events"
        }
        restart_stash() { echo RESTART-GROUP-STILL-OLD >> "$events"; return 0; }
        ping() { return 0; }
        curl() {
            local count code
            count=$(cat "$http_count")
            echo $((count + 1)) > "$http_count"
            echo "HTTP:$(cat "$selected")" >> "$events"
            case "$count" in 0|1|2) code=503 ;; *) code=204 ;; esac
            echo "$code"
        }

        switch_to_best_node
        rc=$?
        printf 'RC=%s\n' "$rc"
        cat "$events"
        ''',
    )
    assert result.returncode == 0, result.stderr
    output = result.stdout
    assert "RC=0" in output
    assert output.count("SWITCH:JP-CANDIDATE-C") == 1
    assert output.count("HTTP:JP-CANDIDATE-C") == 3
    assert output.count("SWITCH:TW-CANDIDATE-D") == 1
    assert output.count("HTTP:TW-CANDIDATE-D") == 1
    assert output.count("NOTIFY:") == 1


def test_monitor_exposes_measurement_unresolved_without_starting_recovery(tmp_path, monitor_library):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        events="$TEST_TMPDIR/events"; : > "$events"
        log() { echo "LOG:$1" >> "$events"; }
        notify() { echo "NOTIFY:$1:$2" >> "$events"; }
        rotate_log() { :; }
        check_api() { return 0; }
        check_connectivity() { echo measurement-unresolved; }
        recover() { echo RECOVER >> "$events"; }
        cmd_monitor
        cat "$events"
        ''',
    )
    assert result.returncode == 0, result.stderr
    output = normalized(result.stdout)
    assert "measurement-unresolved" in output
    assert "manual" in output or "人工" in result.stdout
    assert "recover" not in output
    assert "notify:" not in output


def test_status_exposes_measurement_unresolved_distinctly(tmp_path, monitor_library):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        check_api() { return 0; }
        get_routing_group() { echo "Default Proxy"; }
        get_current_node() { echo "JP-NODE"; }
        check_connectivity() { echo measurement-unresolved; }
        has_python() { return 1; }
        CONFIG_SWITCHER="$TEST_TMPDIR/missing-switcher"
        detect_repo() { return 1; }
        cmd_status
        ''',
    )
    assert result.returncode == 0, result.stderr
    assert "measurement-unresolved" in normalized(result.stdout)


def parse_put_result(raw: str) -> dict[str, str]:
    raw = raw.strip()
    try:
        value = json.loads(raw)
        if isinstance(value, dict):
            return {str(key): str(item) for key, item in value.items()}
    except json.JSONDecodeError:
        pass
    fields = raw.split("\t")
    if len(fields) == 3:
        return {"transport": fields[0], "status": fields[1], "body": fields[2]}
    pairs = dict(re.findall(r"(transport|http_status|status|body)=([^\s]+)", raw))
    if "http_status" in pairs and "status" not in pairs:
        pairs["status"] = pairs["http_status"]
    return pairs


@pytest.mark.parametrize(
    ("transport_rc", "http_status", "body", "expected_transport"),
    [
        (0, "405", '{"error":"method not allowed"}', "ok"),
        (0, "503", '{"error":"unavailable"}', "ok"),
        (7, "000", "connection refused", "failed"),
    ],
)
def test_status_aware_put_preserves_transport_status_and_body(
    tmp_path, monitor_library, transport_rc, http_status, body, expected_transport
):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        curl() {
            local output_file="" previous="" arg
            for arg in "$@"; do
                if [ "$previous" = "-o" ]; then output_file="$arg"; fi
                previous="$arg"
            done
            [ -n "$output_file" ] && printf '%s' "$CASE_BODY" > "$output_file"
            printf '%s' "$CASE_HTTP_STATUS"
            return "$CASE_TRANSPORT_RC"
        }
        if declare -F api_put_status >/dev/null; then
            api_put_status "/configs" '{}'
        elif declare -F status_aware_api_put >/dev/null; then
            status_aware_api_put "/configs" '{}'
        else
            diagnostic_api_put "/configs" '{}'
        fi
        ''',
        extra_env={
            "CASE_TRANSPORT_RC": str(transport_rc),
            "CASE_HTTP_STATUS": http_status,
            "CASE_BODY": body,
        },
    )
    assert result.returncode == 0, result.stderr
    parsed = parse_put_result(result.stdout)
    assert normalized(parsed.get("transport", "")) == expected_transport
    assert parsed.get("status") == http_status
    assert parsed.get("body") == body


def test_reload_reconnect_and_remote_update_are_distinct_and_remote_update_guesses_nothing(
    tmp_path, monitor_library
):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        events="$TEST_TMPDIR/operation-events"; : > "$events"
        log() { echo "LOG:$1" >> "$events"; }
        sleep() { :; }
        api_put_status() {
            echo "API:$1" >> "$events"
            printf 'ok\t405\tmethod-not-allowed\n'
        }
        status_aware_api_put() { api_put_status "$@"; }
        diagnostic_api_put() { api_put_status "$@"; }
        api_put() { echo "LEGACY_API:$1" >> "$events"; }
        get_current_node() { echo JP-CURRENT; }
        test_node_delay() { echo "DELAY:$1" >> "$events"; echo 42; }

        call_first() {
            local name
            for name in "$@"; do
                if declare -F "$name" >/dev/null; then
                    "$name"
                    return $?
                fi
            done
            echo "MISSING:$1"
            return 127
        }

        runtime_output=$(call_first runtime_reload_config attempt_runtime_reload reload_runtime_config)
        runtime_rc=$?
        reconnect_output=$(call_first reconnect_current_node probe_current_node_reconnect)
        reconnect_rc=$?
        before_remote=$(wc -l < "$events" | tr -d ' ')
        remote_output=$(call_first remote_whole_config_update update_remote_whole_config)
        remote_rc=$?
        after_remote=$(wc -l < "$events" | tr -d ' ')

        printf 'RUNTIME_RC=%s OUTPUT=%s\n' "$runtime_rc" "$runtime_output"
        printf 'RECONNECT_RC=%s OUTPUT=%s\n' "$reconnect_rc" "$reconnect_output"
        printf 'REMOTE_RC=%s OUTPUT=%s BEFORE=%s AFTER=%s\n' "$remote_rc" "$remote_output" "$before_remote" "$after_remote"
        cat "$events"
        ''',
    )
    assert result.returncode == 0, result.stderr
    output = normalized(result.stdout)
    assert "runtime-rc=0" not in output
    assert "405" in output
    assert "reconnect-rc=0" in output
    assert "delay:jp-current" in output
    assert "remote-update-unavailable" in output
    remote_line = next(line for line in result.stdout.splitlines() if line.startswith("REMOTE_RC="))
    match = re.search(r"BEFORE=(\d+) AFTER=(\d+)", remote_line)
    assert match and match.group(1) == match.group(2), "remote unavailable must not call a guessed endpoint"
    assert not re.search(r"API:.*(provider|subscription|install)", result.stdout, re.IGNORECASE)


def recovery_after_unavailable_case(
    tmp_path, monitor_library, outcome: str
) -> subprocess.CompletedProcess[str]:
    return run_library(
        tmp_path,
        monitor_library,
        r'''
        RETRY_MAX=2
        RETRY_INTERVAL=0
        events="$TEST_TMPDIR/recovery-events"; : > "$events"
        after_remote="$TEST_TMPDIR/after-remote"; : > "$after_remote"

        log() { echo "LOG:$1" >> "$events"; }
        notify() { echo "NOTIFY:$1:$2" >> "$events"; }
        sleep() { :; }
        refresh_config() { echo runtime-reload-and-reconnect >> "$events"; return 1; }
        switch_to_best_node() { echo candidate-pass >> "$events"; return 1; }
        remote_whole_config_update() { echo remote-update-unavailable >> "$events"; echo yes > "$after_remote"; return 2; }
        update_remote_whole_config() { remote_whole_config_update; }
        refresh_subscription() { remote_whole_config_update; }
        check_connectivity() {
            if [ -s "$after_remote" ]; then
                echo "$CASE_REMOTE_OUTCOME"
            else
                echo fail
            fi
        }
        try_alternative_configs() { echo alternative-configs >> "$events"; return 0; }

        recover
        rc=$?
        printf 'RC=%s\n' "$rc"
        cat "$events"
        ''',
        extra_env={"CASE_REMOTE_OUTCOME": outcome},
    )


def test_remote_update_unavailable_with_valid_recovery_is_neutral_not_refresh_attributed(
    tmp_path, monitor_library
):
    result = recovery_after_unavailable_case(tmp_path, monitor_library, "pass")
    assert result.returncode == 0, result.stderr
    output = normalized(result.stdout)
    assert output.count("candidate-pass") == 1
    assert "alternative-configs" not in output
    assert "validated-connectivity-recovered" in output or "中性" in result.stdout
    assert "透過刷新" not in result.stdout
    assert not re.search(r"notify:.*(刷新|refresh|update)", result.stdout, re.IGNORECASE)


def test_remote_update_unavailable_with_valid_failure_skips_unchanged_candidates_for_alternates(
    tmp_path, monitor_library
):
    result = recovery_after_unavailable_case(tmp_path, monitor_library, "validated-failure")
    assert result.returncode == 0, result.stderr
    output = normalized(result.stdout)
    assert output.count("candidate-pass") == 1
    assert "remote-update-unavailable" in output
    assert "alternative-configs" in output
    assert "透過刷新" not in result.stdout


def test_remote_update_unavailable_with_unresolved_measurement_stops_all_automation(
    tmp_path, monitor_library
):
    result = recovery_after_unavailable_case(tmp_path, monitor_library, "measurement-unresolved")
    assert result.returncode == 0, result.stderr
    output = normalized(result.stdout)
    assert "rc=2" in output
    assert output.count("candidate-pass") == 1
    assert "alternative-configs" not in output
    assert "measurement-unresolved" in output
    assert "notify:" not in output


def test_existing_switch_readback_and_gui_restart_synchronization_remain_pinned(tmp_path, monitor_library):
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        events="$TEST_TMPDIR/sync-events"; : > "$events"
        selected="$TEST_TMPDIR/selected"; echo OLD > "$selected"
        log() { :; }
        sleep() { :; }
        close_connections() { :; }
        get_routing_group() { echo "Default Proxy"; }
        urlencode() { echo "$1"; }
        api_put() {
            echo "PUT:$1" >> "$events"
            echo "$2" | jq -r .name > "$selected"
        }
        get_current_node() { cat "$selected"; }
        restart_stash() { echo GUI_RESTART >> "$events"; return 0; }

        switch_node "JP-TARGET" 1
        rc=$?
        printf 'RC=%s NODE=%s\n' "$rc" "$(cat "$selected")"
        cat "$events"
        ''',
    )
    assert result.returncode == 0, result.stderr
    assert "RC=0 NODE=JP-TARGET" in result.stdout
    assert "GUI_RESTART" in result.stdout


def test_existing_config_switch_still_requires_restart_and_api_readback(tmp_path, monitor_library):
    switcher = tmp_path / "fake-switcher"
    switcher.write_text("#!/bin/sh\necho switched:$1\n")
    switcher.chmod(0o755)
    result = run_library(
        tmp_path,
        monitor_library,
        r'''
        events="$TEST_TMPDIR/config-events"; : > "$events"
        PYTHON_BIN="/bin/sh"
        CONFIG_SWITCHER="$CASE_SWITCHER"
        log() { echo "$1" >> "$events"; }
        sleep() { :; }
        wait_for_stash_process() { return 0; }
        restart_stash() { echo GUI_RESTART >> "$events"; return 0; }
        check_api() { echo API_READBACK >> "$events"; return 0; }

        switch_config "backup.yaml"
        rc=$?
        printf 'RC=%s\n' "$rc"
        cat "$events"
        ''',
        extra_env={"CASE_SWITCHER": str(switcher)},
    )
    assert result.returncode == 0, result.stderr
    assert "RC=0" in result.stdout
    assert "GUI_RESTART" in result.stdout
    assert "API_READBACK" in result.stdout
