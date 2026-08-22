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


FAKE_CURL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


state_path = Path(os.environ["FAKE_STASH_STATE"])
events_path = Path(os.environ["FAKE_STASH_EVENTS"])
state = json.loads(state_path.read_text())

args = sys.argv[1:]
method = "GET"
data = ""
output_path = None
write_format = None
url = ""
i = 0
while i < len(args):
    arg = args[i]
    if arg == "-X":
        method = args[i + 1]
        i += 2
    elif arg in ("-d", "--data", "--data-raw"):
        data = args[i + 1]
        i += 2
    elif arg == "-o":
        output_path = args[i + 1]
        i += 2
    elif arg == "-w":
        write_format = args[i + 1]
        i += 2
    elif arg in ("-m", "-H", "-x", "--connect-timeout", "--max-time"):
        i += 2
    elif arg.startswith("-"):
        i += 1
    else:
        url = arg
        i += 1

parts = urlsplit(url)
endpoint = unquote(parts.path)
if parts.query:
    endpoint += "?" + parts.query

status = 200
body = ""

if parts.hostname == "www.gstatic.com":
    codes = [item for item in os.environ.get("FAKE_PROBE_CODES", "204").split(",") if item]
    index = state.get("probe_index", 0)
    status = int(codes[min(index, len(codes) - 1)])
    state["probe_index"] = index + 1
    event = {
        "kind": "http_probe",
        "attempt": index + 1,
        "selected": state["selected"],
        "status": status,
        "url": url,
    }
    nodes_after_probe = [
        item for item in os.environ.get("FAKE_NODES_AFTER_PROBE", "").split(",")
    ]
    if index < len(nodes_after_probe) and nodes_after_probe[index]:
        state["selected"] = nodes_after_probe[index]
else:
    event = {"kind": "api", "method": method, "endpoint": endpoint, "data": data}
    if method == "GET" and endpoint == "/configs":
        body = json.dumps({"mode": "rule", "generation": state["runtime_generation"]})
    elif method == "GET" and endpoint == "/rules":
        body = json.dumps({
            "rules": [
                {"type": "DOMAIN", "payload": "www.gstatic.com", "proxy": os.environ.get("FAKE_PROBE_GROUP", "Probe Policy")},
                {"type": "MATCH", "proxy": "Default Proxy"},
            ]
        })
    elif method == "GET" and endpoint == "/proxies":
        body = json.dumps({"proxies": {
            "Default Proxy": {"type": "Selector", "now": state["selected"], "all": ["JP-DIAGNOSTIC", "TW-BACKUP", "HK-LAST"]},
            "Probe Policy": {"type": "Selector", "now": "PROBE-POLICY-NODE", "all": ["PROBE-POLICY-NODE"]},
            "JP-DIAGNOSTIC": {"type": "VLESS"},
            "TW-BACKUP": {"type": "Trojan"},
            "HK-LAST": {"type": "Shadowsocks"},
            "PROBE-POLICY-NODE": {"type": "VLESS"},
        }})
    elif method == "GET" and endpoint.startswith("/proxies/") and endpoint.endswith("/delay?url=http://www.gstatic.com/generate_204&timeout=5000"):
        body = json.dumps({"alive": True, "delay": 40})
    elif method == "GET" and endpoint == "/proxies/Default Proxy":
        body = json.dumps({"type": "Selector", "now": state["selected"], "all": ["JP-DIAGNOSTIC", "TW-BACKUP", "HK-LAST"]})
    elif method == "GET" and endpoint == "/proxies/Probe Policy":
        body = json.dumps({"type": "Selector", "now": "PROBE-POLICY-NODE", "all": ["PROBE-POLICY-NODE"]})
    elif method == "GET" and endpoint == "/providers/proxies":
        body = json.dumps({"providers": {"airport": {"updatedAt": state["provider_generation"], "proxies": [{"name": "JP-DIAGNOSTIC"}]}}})
    elif method == "PUT" and endpoint.startswith("/proxies/"):
        if os.environ.get("FAKE_SWITCH_APPLIES", "true") == "true":
            state["selected"] = json.loads(data)["name"]
        status = int(os.environ.get("FAKE_SWITCH_HTTP_STATUS", "204"))
        body = json.dumps({"result": "selected"})
    elif method == "PUT" and endpoint == "/configs":
        status = 202
        body = json.dumps({"result": "accepted", "forced": False})
    elif method == "PUT" and endpoint == "/configs?force=true":
        state["runtime_generation"] += 1
        status = 202
        body = json.dumps({"result": "accepted", "forced": True})
    elif method == "PUT" and endpoint == "/providers/proxies/airport":
        state["provider_generation"] += 1
        status = 204
        body = json.dumps({"result": "provider-updated"})
    elif method == "DELETE" and endpoint == "/connections":
        status = 204

event["status"] = status
with events_path.open("a") as stream:
    stream.write(json.dumps(event, sort_keys=True) + "\n")
state_path.write_text(json.dumps(state))

if output_path and output_path != "/dev/null":
    Path(output_path).write_text(body)
elif not output_path:
    sys.stdout.write(body)
if write_format:
    sys.stdout.write(write_format.replace("%{http_code}", str(status)))
'''


CONFIGS = {
    "inline": """\
mode: rule
proxies:
  - name: JP-DIAGNOSTIC
    type: vless
rules:
  - MATCH,Default Proxy
""",
    "subscribed_whole_config": """\
#SUBSCRIBED https://subscription.example/config.yaml
mode: rule
proxies:
  - name: JP-DIAGNOSTIC
    type: vless
""",
    "proxy_provider": """\
proxy-providers:
  airport:
    type: http
    url: https://subscription.example/provider.yaml
proxy-groups:
  - name: Default Proxy
    type: select
    use: [airport]
""",
    "use_url": """\
proxy-groups:
  - name: Default Proxy
    type: select
    use-url: https://subscription.example/nodes.yaml
""",
    "combination": """\
#SUBSCRIBED https://subscription.example/config.yaml
proxy-providers:
  airport:
    type: http
    url: https://subscription.example/provider.yaml
proxy-groups:
  - name: Default Proxy
    type: select
    use: [airport]
""",
}


@pytest.fixture
def monitor_library(tmp_path):
    source = MONITOR.read_text()
    assert ENTRYPOINT_MARKER in source, "vpn_monitor.sh entrypoint marker changed"
    library = tmp_path / "vpn_monitor_lib.sh"
    library.write_text(source.split(ENTRYPOINT_MARKER, 1)[0])
    return library


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(0o755)


def _diagnostic_run(
    tmp_path: Path,
    monitor_library: Path,
    *,
    config_model: str = "inline",
    probe_codes: str = "000,000,000,000,000,000,204",
    max_attempts: int = 2,
    probe_group: str = "Probe Policy",
    restart_node: str = "POST-RESTART-NODE",
    switch_http_status: int = 204,
    switch_applies: bool = True,
    node_after_gui: str = "",
    nodes_after_probe: tuple[str, ...] = (),
) -> tuple[subprocess.CompletedProcess[str], list[dict]]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    _write_executable(fake_bin / "curl", FAKE_CURL)
    _write_executable(fake_bin / "ping", "#!/bin/sh\nexit 0\n")

    state_path = tmp_path / "stash-state.json"
    state_path.write_text(json.dumps({
        "selected": "ORIGINAL-NODE",
        "runtime_generation": 0,
        "provider_generation": 0,
        "probe_index": 0,
    }))
    events_path = tmp_path / "events.jsonl"
    events_path.write_text("")

    stash_dir = tmp_path / "stash"
    stash_dir.mkdir()
    (stash_dir / "config.yaml").write_text(CONFIGS[config_model])
    config_path = tmp_path / "vpn-monitor.config"
    config_path.write_text(textwrap.dedent(f"""\
        API_SECRET="test-secret"
        API_BASE="http://fake.stash"
        PROXY_PORT="7890"
        LOG_FILE="{tmp_path / 'vpn-monitor.log'}"
        STASH_CONFIG_DIR="{stash_dir}"
    """))

    harness = textwrap.dedent(r'''
        source "$MONITOR_LIBRARY"

        RETRY_MAX=2
        RETRY_INTERVAL=0
        CONFIG_SWITCHER="$TEST_TMPDIR/does-not-exist.py"
        # switch_to_best_node installs a RETURN trap that outlives its local
        # tmpfile under `set -u`; keep a harmless global fallback for later
        # function returns in this sourced-library harness.
        tmpfile="$TEST_TMPDIR/return-trap-fallback"
        : > "$tmpfile"

        sleep() { :; }
        notify() { :; }

        restart_stash() {
            printf '%s\n' '{"kind":"restart","api_ready":true}' >> "$FAKE_STASH_EVENTS"
            local tmp="$FAKE_STASH_STATE.tmp"
            jq --arg node "$TEST_RESTART_NODE" '.selected = $node' "$FAKE_STASH_STATE" > "$tmp"
            mv "$tmp" "$FAKE_STASH_STATE"
            return 0
        }

        get_gui_selected_node() {
            printf '%s\n' '{"kind":"gui_readback","node":"GUI-POST-RESTART-NODE"}' >> "$FAKE_STASH_EVENTS"
            if [ -n "$TEST_NODE_AFTER_GUI" ]; then
                local tmp="$FAKE_STASH_STATE.tmp"
                jq --arg node "$TEST_NODE_AFTER_GUI" '.selected = $node' "$FAKE_STASH_STATE" > "$tmp"
                mv "$tmp" "$FAKE_STASH_STATE"
            fi
            echo "GUI-POST-RESTART-NODE"
        }
        get_gui_current_node() { get_gui_selected_node; }
        read_gui_selected_node() { get_gui_selected_node; }

        export PHASE_A_MAX_ATTEMPTS="$TEST_MAX_ATTEMPTS"
        export DIAGNOSTIC_MAX_ATTEMPTS="$TEST_MAX_ATTEMPTS"
        cmd_live_test
    ''')
    env = os.environ.copy()
    env.update({
        "PATH": f"{fake_bin}:{env['PATH']}",
        "VPN_MONITOR_CONFIG": str(config_path),
        "MONITOR_LIBRARY": str(monitor_library),
        "TEST_TMPDIR": str(tmp_path),
        "TEST_MAX_ATTEMPTS": str(max_attempts),
        "TEST_RESTART_NODE": restart_node,
        "TEST_NODE_AFTER_GUI": node_after_gui,
        "FAKE_STASH_STATE": str(state_path),
        "FAKE_STASH_EVENTS": str(events_path),
        "FAKE_PROBE_CODES": probe_codes,
        "FAKE_PROBE_GROUP": probe_group,
        "FAKE_SWITCH_HTTP_STATUS": str(switch_http_status),
        "FAKE_SWITCH_APPLIES": "true" if switch_applies else "false",
        "FAKE_NODES_AFTER_PROBE": ",".join(nodes_after_probe),
        "HTTP_URL": "http://www.gstatic.com/generate_204",
    })
    result = subprocess.run(
        ["bash", "-c", harness],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    events = [json.loads(line) for line in events_path.read_text().splitlines() if line]
    assert "command not found" not in result.stderr.lower(), result.stderr
    assert "syntax error" not in result.stderr.lower(), result.stderr
    return result, events


def _normalized(text: str) -> str:
    return re.sub(r"[ _]", "-", text.lower())


def _assert_fields_share_a_line(output: str, *fields: str) -> None:
    normalized_fields = [_normalized(field) for field in fields]
    lines = [_normalized(line) for line in output.splitlines()]
    for line in lines:
        match = True
        for field in normalized_fields:
            # Match field as exact key or value, not substring of another key
            # After normalization, spaces/underscores become '-', so check for
            # word boundaries: field must be preceded by start/space/=/- and
            # followed by space/=/-/end
            pattern = rf'(?:^|[\s=\-]){re.escape(field)}(?:[\s=\-]|$)'
            if not re.search(pattern, line):
                match = False
                break
        if match:
            return
    assert False, f"expected one diagnostic record containing {fields!r}\noutput:\n{output}"


CURRENT_PROBE_ROUTE_PATTERN = re.compile(
    r"^DIAG probe_rule=(?P<probe_rule>\S+) "
    r"probe_payload=(?P<probe_payload>\S+) "
    r"probe_group=(?P<probe_group>.*?) "
    r"url=(?P<url>\S+)$"
)


def _current_probe_route_records(output: str) -> list[dict[str, str]]:
    return [
        match.groupdict()
        for line in output.splitlines()
        if (match := CURRENT_PROBE_ROUTE_PATTERN.fullmatch(line))
    ]


def _reproduction_status(output: str) -> str:
    matches = re.findall(r"^DIAG reproduction=(confirmed|unresolved)\b", output, re.MULTILINE)
    assert len(matches) == 1, f"expected exactly one structured reproduction record\n{output}"
    return matches[0]


def test_live_diagnostic_distinguishes_restart_and_every_probe_readback(tmp_path, monitor_library):
    result, events = _diagnostic_run(tmp_path, monitor_library)
    assert result.returncode == 0, result.stderr

    _assert_fields_share_a_line(result.stdout, "requested_group", "Default Proxy", "requested_node", "JP-DIAGNOSTIC")
    _assert_fields_share_a_line(result.stdout, "pre-restart", "selection", "JP-DIAGNOSTIC")
    _assert_fields_share_a_line(result.stdout, "post-restart", "api-ready", "selection", "POST-RESTART-NODE")
    _assert_fields_share_a_line(result.stdout, "probe-time", "attempt=1", "selection", "POST-RESTART-NODE")
    _assert_fields_share_a_line(result.stdout, "probe-time", "attempt=2", "selection", "POST-RESTART-NODE")
    _assert_fields_share_a_line(result.stdout, "gui-readback", "GUI-POST-RESTART-NODE")

    gui_events = [event for event in events if event["kind"] == "gui_readback"]
    assert gui_events, "the controlled GUI readback boundary was never exercised"
    assert _normalized(result.stdout).find("pre-restart") < _normalized(result.stdout).find("post-restart")


def test_live_diagnostic_correlates_actual_probe_rule_group_and_probe_time_node(tmp_path, monitor_library):
    result, _ = _diagnostic_run(tmp_path, monitor_library)
    assert result.returncode == 0, result.stderr

    route_records = _current_probe_route_records(result.stdout)
    assert route_records == [
        {
            "probe_rule": "DOMAIN",
            "probe_payload": "www.gstatic.com",
            "probe_group": "Probe Policy",
            "url": "http://www.gstatic.com/generate_204",
        }
    ]

    correlation_pattern = re.compile(
        r"^DIAG probe_group=(?P<probe_group>.*?) "
        r"switched_group=(?P<switched_group>.*?) "
        r"probe_time_selection=(?P<probe_time_selection>\S+) "
        r"probe_group_selection=(?P<probe_group_selection>\S+)$"
    )
    correlation_records = [
        match.groupdict()
        for line in result.stdout.splitlines()
        if (match := correlation_pattern.fullmatch(line))
    ]
    assert correlation_records
    assert all(record["probe_group"] == "Probe Policy" for record in correlation_records)
    assert all(record["switched_group"] == "Default Proxy" for record in correlation_records)
    assert all(record["probe_time_selection"] == "POST-RESTART-NODE" for record in correlation_records)


def test_current_probe_route_parser_rejects_legacy_prefixed_evidence_fields():
    legacy_only = (
        "DIAG legacy_probe_rule=DOMAIN legacy_probe_payload=www.gstatic.com "
        "legacy_probe_group=Probe Policy url=http://www.gstatic.com/generate_204\n"
    )
    assert _current_probe_route_records(legacy_only) == []


def test_reproduction_is_confirmed_only_when_every_correlation_gate_is_valid(tmp_path, monitor_library):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="000,000,000",
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
    )
    assert result.returncode == 0, result.stderr
    _assert_fields_share_a_line(result.stdout, "requested_node", "JP-DIAGNOSTIC", "http_status", "204")
    _assert_fields_share_a_line(result.stdout, "pre-restart", "selection", "JP-DIAGNOSTIC")
    _assert_fields_share_a_line(result.stdout, "post-restart", "selection", "JP-DIAGNOSTIC")
    diagnostic_probes = [event for event in events if event["kind"] == "http_probe"][:2]
    assert [event["selected"] for event in diagnostic_probes] == ["JP-DIAGNOSTIC", "JP-DIAGNOSTIC"]
    assert _reproduction_status(result.stdout) == "confirmed"


@pytest.mark.parametrize(
    ("case", "run_kwargs"),
    [
        (
            "switch-http-failure",
            {
                "switch_http_status": 500,
                "probe_group": "Default Proxy",
                "restart_node": "JP-DIAGNOSTIC",
            },
        ),
        (
            "pre-restart-readback-mismatch",
            {
                "switch_applies": False,
                "probe_group": "Default Proxy",
                "restart_node": "JP-DIAGNOSTIC",
            },
        ),
        (
            "restart-node-loss",
            {
                "probe_group": "Default Proxy",
                "restart_node": "POST-RESTART-NODE",
            },
        ),
        (
            "route-group-mismatch",
            {
                "probe_group": "Probe Policy",
                "restart_node": "JP-DIAGNOSTIC",
            },
        ),
        (
            "earlier-probe-node-mismatch",
            {
                "probe_group": "Default Proxy",
                "restart_node": "JP-DIAGNOSTIC",
                "node_after_gui": "OTHER-NODE",
                "nodes_after_probe": ("JP-DIAGNOSTIC", "JP-DIAGNOSTIC"),
            },
        ),
    ],
)
def test_any_failed_reproduction_correlation_gate_is_unresolved(
    tmp_path, monitor_library, case, run_kwargs
):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="000,000,000",
        **run_kwargs,
    )
    assert result.returncode == 0, f"{case}: {result.stderr}"
    assert _reproduction_status(result.stdout) == "unresolved", f"{case}\n{result.stdout}"

    if case == "restart-node-loss":
        _assert_fields_share_a_line(result.stdout, "post-restart", "selection", "POST-RESTART-NODE")
    elif case == "route-group-mismatch":
        route_records = _current_probe_route_records(result.stdout)
        assert route_records[0]["probe_group"] == "Probe Policy"
        assert "requested_group=Default Proxy" in result.stdout
    elif case == "earlier-probe-node-mismatch":
        diagnostic_probes = [event for event in events if event["kind"] == "http_probe"][:2]
        assert [event["selected"] for event in diagnostic_probes] == ["OTHER-NODE", "JP-DIAGNOSTIC"]


def test_live_diagnostic_compares_exact_config_reload_endpoints_and_evidence(tmp_path, monitor_library):
    result, events = _diagnostic_run(tmp_path, monitor_library)
    assert result.returncode == 0, result.stderr

    config_puts = [
        event["endpoint"]
        for event in events
        if event["kind"] == "api" and event["method"] == "PUT" and event["endpoint"].startswith("/configs")
    ]
    assert "/configs" in config_puts
    assert "/configs?force=true" in config_puts
    assert config_puts.index("/configs") < config_puts.index("/configs?force=true")

    for endpoint in ("/configs", "/configs?force=true"):
        _assert_fields_share_a_line(result.stdout, endpoint, "http_status", "result")
        _assert_fields_share_a_line(result.stdout, endpoint, "before_runtime_fingerprint", "after_runtime_fingerprint")
        _assert_fields_share_a_line(result.stdout, endpoint, "before_config_fingerprint", "after_config_fingerprint")


@pytest.mark.parametrize(
    ("fixture_model", "reported_model"),
    [
        ("inline", "inline"),
        ("subscribed_whole_config", "subscribed-whole-config"),
        ("proxy_provider", "proxy-provider"),
        ("use_url", "use-url"),
        ("combination", "combination"),
    ],
)
def test_live_diagnostic_identifies_active_config_model(tmp_path, monitor_library, fixture_model, reported_model):
    result, _ = _diagnostic_run(tmp_path, monitor_library, config_model=fixture_model)
    assert result.returncode == 0, result.stderr
    _assert_fields_share_a_line(result.stdout, "active_config_model", reported_model)


def test_provider_update_is_exercised_only_for_an_applicable_model(tmp_path, monitor_library):
    provider_result, provider_events = _diagnostic_run(
        tmp_path / "provider",
        monitor_library,
        config_model="proxy_provider",
    )
    assert provider_result.returncode == 0, provider_result.stderr
    provider_puts = [
        event["endpoint"]
        for event in provider_events
        if event["kind"] == "api" and event["method"] == "PUT"
    ]
    assert "/providers/proxies/airport" in provider_puts
    _assert_fields_share_a_line(provider_result.stdout, "provider_update", "airport", "http_status", "result")
    _assert_fields_share_a_line(provider_result.stdout, "provider_update", "before_fingerprint", "after_fingerprint")


def test_remote_updates_are_skipped_when_the_inline_model_is_not_applicable(tmp_path, monitor_library):
    result, events = _diagnostic_run(tmp_path, monitor_library, config_model="inline")
    assert result.returncode == 0, result.stderr
    provider_puts = [
        event for event in events
        if event["kind"] == "api" and event["method"] == "PUT" and event["endpoint"].startswith("/providers/proxies/")
    ]
    assert provider_puts == []
    _assert_fields_share_a_line(result.stdout, "whole_config_update", "not_applicable")
    _assert_fields_share_a_line(result.stdout, "provider_update", "not_applicable")


def test_subscribed_whole_config_runs_only_its_applicable_remote_update_diagnostic(tmp_path, monitor_library):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        config_model="subscribed_whole_config",
    )
    assert result.returncode == 0, result.stderr
    provider_puts = [
        event for event in events
        if event["kind"] == "api" and event["method"] == "PUT" and event["endpoint"].startswith("/providers/proxies/")
    ]
    assert provider_puts == []
    _assert_fields_share_a_line(result.stdout, "whole_config_update", "applicable", "before_fingerprint", "after_fingerprint")
    _assert_fields_share_a_line(result.stdout, "provider_update", "not_applicable")


def test_non_reproduction_stops_at_the_attempt_bound_and_reports_unresolved(tmp_path, monitor_library):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="204,204,204,204",
        max_attempts=2,
    )
    assert result.returncode == 0, result.stderr
    normalized = _normalized(result.stdout)
    diagnostic_probe_records = [line for line in normalized.splitlines() if "probe-time" in line and "attempt=" in line]
    assert 1 <= len(diagnostic_probe_records) <= 2
    assert all("attempt=3" not in line for line in diagnostic_probe_records)
    _assert_fields_share_a_line(result.stdout, "reproduction", "unresolved", "attempt_bound", "2")


def test_diagnostic_emits_inputs_for_each_hypothesis_status(tmp_path, monitor_library):
    result, _ = _diagnostic_run(tmp_path, monitor_library)
    assert result.returncode == 0, result.stderr
    for hypothesis in (
        "selection_persistence",
        "probe_routing_mismatch",
        "runtime_config_reload",
        "whole_config_subscription",
        "proxy_provider_state",
        "shared_data_path",
    ):
        _assert_fields_share_a_line(result.stdout, "hypothesis", hypothesis, "status")
        matching = [line for line in _normalized(result.stdout).splitlines() if _normalized(hypothesis) in line]
        assert any(re.search(r"status[=:](confirmed|rejected|unresolved)", line) for line in matching)


def _run_library_case(tmp_path: Path, monitor_library: Path, body: str) -> subprocess.CompletedProcess[str]:
    config = tmp_path / "config"
    config.write_text(f'API_SECRET="test"\nLOG_FILE="{tmp_path / "monitor.log"}"\n')
    env = os.environ.copy()
    env.update({"VPN_MONITOR_CONFIG": str(config), "MONITOR_LIBRARY": str(monitor_library)})
    result = subprocess.run(
        ["bash", "-c", 'source "$MONITOR_LIBRARY"\n' + textwrap.dedent(body)],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert "command not found" not in result.stderr.lower(), result.stderr
    assert "syntax error" not in result.stderr.lower(), result.stderr
    return result


def test_ordinary_candidate_ranking_and_each_full_retry_window_are_unchanged(tmp_path, monitor_library):
    result = _run_library_case(
        tmp_path,
        monitor_library,
        r'''
        RETRY_MAX=3
        RETRY_INTERVAL=0
        history="$VPN_MONITOR_CONFIG.history"
        checks="$VPN_MONITOR_CONFIG.checks"
        : > "$history"
        : > "$checks"

        log() { :; }
        notify() { :; }
        sleep() { :; }
        get_current_node() { echo "CURRENT"; }
        get_selectable_nodes() { printf '%s\n' "HK-FAST" "TW-FAST" "JP-SLOW"; }
        test_node_delay() {
            case "$1" in
                HK-FAST) echo 10 ;;
                TW-FAST) echo 20 ;;
                JP-SLOW) echo 900 ;;
            esac
        }
        switch_node() {
            echo "$1" >> "$history"
            echo "$1" > "$VPN_MONITOR_CONFIG.current"
            return 0
        }
        check_connectivity() {
            local count node
            count=$(wc -l < "$checks" | tr -d ' ')
            node=$(cat "$VPN_MONITOR_CONFIG.current")
            echo "$node" >> "$checks"
            case "$count" in
                0|1|2|3) echo fail ;;
                *) echo ok ;;
            esac
        }

        switch_to_best_node
        rc=$?
        test "$rc" -eq 0
        test "$(paste -sd, "$history")" = "JP-SLOW,TW-FAST"
        test "$(paste -sd, "$checks")" = "JP-SLOW,JP-SLOW,JP-SLOW,TW-FAST,TW-FAST"
        echo ORDINARY_CANDIDATE_SEMANTICS_OK
        ''',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ORDINARY_CANDIDATE_SEMANTICS_OK" in result.stdout


def test_ordinary_recovery_order_and_retry_counts_are_unchanged(tmp_path, monitor_library):
    result = _run_library_case(
        tmp_path,
        monitor_library,
        r'''
        RETRY_MAX=2
        RETRY_INTERVAL=0
        events="$VPN_MONITOR_CONFIG.events"
        : > "$events"

        log() { :; }
        notify() { :; }
        sleep() { :; }
        refresh_config() { echo refresh_config >> "$events"; }
        check_connectivity() { echo connectivity >> "$events"; echo fail; }
        switch_to_best_node() { echo ranked_candidates >> "$events"; return 1; }
        refresh_subscription() { echo refresh_subscription >> "$events"; }
        try_alternative_configs() { echo alternative_configs >> "$events"; return 1; }

        if recover; then
            exit 91
        fi
        expected="refresh_config,connectivity,connectivity,ranked_candidates,refresh_subscription,connectivity,connectivity,ranked_candidates,alternative_configs"
        test "$(paste -sd, "$events")" = "$expected"
        echo ORDINARY_RECOVERY_ORDER_OK
        ''',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ORDINARY_RECOVERY_ORDER_OK" in result.stdout
