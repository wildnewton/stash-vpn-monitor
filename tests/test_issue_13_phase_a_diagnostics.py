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
transport_rc = 0

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
        state["group_selected"]["Default Proxy"] = nodes_after_probe[index]
else:
    event = {"kind": "api", "method": method, "endpoint": endpoint, "data": data}
    if method == "GET" and endpoint == "/configs":
        body = json.dumps({"mode": "rule", "generation": state["runtime_generation"]})
    elif method == "GET" and endpoint == "/rules":
        body = json.dumps({
            "rules": [
                {
                    "type": os.environ.get("FAKE_PROBE_RULE_TYPE", "DOMAIN"),
                    "payload": os.environ.get("FAKE_PROBE_RULE_PAYLOAD", "www.gstatic.com"),
                    "proxy": os.environ.get("FAKE_PROBE_GROUP", "Probe Policy"),
                },
                {"type": "MATCH", "proxy": state.get("match_group", "Default Proxy")},
            ]
        })
    elif method == "GET" and endpoint == "/proxies":
        selectable = [
            item for item in os.environ.get(
                "FAKE_SELECTABLE_NODES", "JP-DIAGNOSTIC,TW-BACKUP,HK-LAST"
            ).split(",") if item
        ]
        proxies = {
            group: {"type": "Selector", "now": selected, "all": selectable}
            for group, selected in state["group_selected"].items()
        }
        for node in sorted(set(selectable) | set(state["group_selected"].values())):
            if node:
                proxies[node] = {"type": "VLESS"}
        body = json.dumps({"proxies": proxies})
    elif method == "GET" and endpoint.startswith("/proxies/") and endpoint.endswith("/delay?url=http://www.gstatic.com/generate_204&timeout=5000"):
        node = endpoint.removeprefix("/proxies/").split("/delay?", 1)[0]
        delays = json.loads(os.environ.get("FAKE_NODE_DELAYS", "{}"))
        delay = int(delays.get(node, 40))
        body = json.dumps({"alive": delay > 0, "delay": delay})
    elif method == "GET" and endpoint.startswith("/proxies/"):
        group = endpoint.removeprefix("/proxies/")
        selected = state["group_selected"].get(group, "")
        if group == os.environ.get("TEST_ORIGINAL_GROUP", "Default Proxy"):
            readbacks = os.environ.get("FAKE_GROUP_READBACKS", "").split(",")
            readbacks = [item for item in readbacks if item]
            read_index = state.get("group_read_index", 0)
            if read_index < len(readbacks):
                selected = "" if readbacks[read_index] == "__EMPTY__" else readbacks[read_index]
                state["group_read_index"] = read_index + 1
        selectable = [
            item for item in os.environ.get(
                "FAKE_SELECTABLE_NODES", "JP-DIAGNOSTIC,TW-BACKUP,HK-LAST"
            ).split(",") if item
        ]
        body = json.dumps({"type": "Selector", "now": selected, "all": selectable})
    elif method == "GET" and endpoint == "/providers/proxies":
        body = json.dumps({"providers": {"airport": {"updatedAt": state["provider_generation"], "proxies": [{"name": "JP-DIAGNOSTIC"}]}}})
    elif method == "PUT" and endpoint.startswith("/proxies/"):
        put_index = state.get("proxy_put_index", 0)
        operation = "switch" if put_index == 0 else "restore"
        state["proxy_put_index"] = put_index + 1
        group = endpoint.removeprefix("/proxies/")
        target = json.loads(data)["name"]
        applies = os.environ.get(
            "FAKE_SWITCH_APPLIES" if operation == "switch" else "FAKE_RESTORE_APPLIES",
            "true",
        ) == "true"
        if applies:
            state["group_selected"][group] = target
            if group == os.environ.get("TEST_ORIGINAL_GROUP", "Default Proxy"):
                state["selected"] = target
        status = int(os.environ.get(
            "FAKE_SWITCH_HTTP_STATUS" if operation == "switch" else "FAKE_RESTORE_HTTP_STATUS",
            "204",
        ))
        transport_rc = int(os.environ.get(
            "FAKE_SWITCH_TRANSPORT_RC" if operation == "switch" else "FAKE_RESTORE_TRANSPORT_RC",
            "0",
        ))
        body = json.dumps({"result": "selected"})
        event.update({"operation": operation, "group": group, "target": target})
    elif method == "PUT" and endpoint == "/configs":
        status = int(os.environ.get("FAKE_RELOAD_HTTP_STATUS", "202"))
        transport_rc = int(os.environ.get("FAKE_RELOAD_TRANSPORT_RC", "0"))
        if os.environ.get("FAKE_RELOAD_CHANGES_RUNTIME", "false") == "true":
            state["runtime_generation"] += 1
        body = json.dumps({"result": "accepted", "forced": False})
    elif method == "PUT" and endpoint == "/configs?force=true":
        state["runtime_generation"] += 1
        status = int(os.environ.get("FAKE_FORCE_HTTP_STATUS", "202"))
        transport_rc = int(os.environ.get("FAKE_FORCE_TRANSPORT_RC", "0"))
        if os.environ.get("FAKE_FORCE_CHANGES_CONFIG", "false") == "true":
            config_path = Path(os.environ["FAKE_STASH_CONFIG"])
            config_path.write_text(config_path.read_text() + "# refreshed\n")
        body = json.dumps({"result": "accepted", "forced": True})
    elif method == "PUT" and endpoint == "/providers/proxies/airport":
        if os.environ.get("FAKE_PROVIDER_CHANGES_FINGERPRINT", "true") == "true":
            state["provider_generation"] += 1
        status = int(os.environ.get("FAKE_PROVIDER_HTTP_STATUS", "204"))
        transport_rc = int(os.environ.get("FAKE_PROVIDER_TRANSPORT_RC", "0"))
        body = os.environ.get("FAKE_PROVIDER_BODY", "provider-updated")
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
sys.exit(transport_rc)
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
    switch_transport_rc: int = 0,
    switch_applies: bool = True,
    restore_http_status: int = 204,
    restore_transport_rc: int = 0,
    restore_applies: bool = True,
    restore_restart_node: str = "ORIGINAL-NODE",
    restore_restart_rc: int = 0,
    match_group_after_restart: str = "Default Proxy",
    match_group_after_restore: str = "Default Proxy",
    selectable_nodes: tuple[str, ...] = ("JP-DIAGNOSTIC", "TW-BACKUP", "HK-LAST"),
    node_delays=None,
    group_readbacks: tuple[str, ...] = (),
    node_after_gui: str = "",
    nodes_after_probe: tuple[str, ...] = (),
    reload_http_status: int = 202,
    reload_transport_rc: int = 0,
    reload_changes_runtime: bool = False,
    force_http_status: int = 202,
    force_transport_rc: int = 0,
    force_changes_config: bool = False,
    provider_http_status: int = 204,
    provider_transport_rc: int = 0,
    provider_changes_fingerprint: bool = True,
    provider_body: str = "provider-updated",
    probe_rule_type: str = "DOMAIN",
    probe_rule_payload: str = "www.gstatic.com",
    diagnostic_probe_route: str = "",
) -> tuple[subprocess.CompletedProcess[str], list[dict]]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    _write_executable(fake_bin / "curl", FAKE_CURL)
    _write_executable(fake_bin / "ping", "#!/bin/sh\nexit 0\n")

    state_path = tmp_path / "stash-state.json"
    state_path.write_text(json.dumps({
        "selected": "ORIGINAL-NODE",
        "group_selected": {
            "Default Proxy": "ORIGINAL-NODE",
            "Probe Policy": "PROBE-POLICY-NODE",
            "Drifted Group": "ORIGINAL-NODE",
        },
        "match_group": "Default Proxy",
        "restart_index": 0,
        "proxy_put_index": 0,
        "group_read_index": 0,
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
            local restart_index node restart_rc match_group api_ready
            restart_index=$(jq -r '.restart_index // 0' "$FAKE_STASH_STATE")
            if [ "$restart_index" -eq 0 ]; then
                node="$TEST_RESTART_NODE"
                restart_rc="$TEST_RESTART_RC"
                match_group="$TEST_MATCH_GROUP_AFTER_RESTART"
            else
                node="$TEST_RESTORE_RESTART_NODE"
                restart_rc="$TEST_RESTORE_RESTART_RC"
                match_group="$TEST_MATCH_GROUP_AFTER_RESTORE"
            fi
            if [ "$restart_rc" -eq 0 ]; then api_ready=true; else api_ready=false; fi
            printf '{"kind":"restart","index":%s,"api_ready":%s,"group":"%s","node":"%s"}\n' \
                "$restart_index" "$api_ready" "$TEST_ORIGINAL_GROUP" "$node" >> "$FAKE_STASH_EVENTS"
            local tmp="$FAKE_STASH_STATE.tmp"
            jq --arg node "$node" --arg group "$TEST_ORIGINAL_GROUP" --arg match "$match_group" \
                '.selected = $node | .group_selected[$group] = $node | .match_group = $match | .restart_index += 1' \
                "$FAKE_STASH_STATE" > "$tmp"
            mv "$tmp" "$FAKE_STASH_STATE"
            return "$restart_rc"
        }

        get_gui_selected_node() {
            printf '%s\n' '{"kind":"gui_readback","node":"GUI-POST-RESTART-NODE"}' >> "$FAKE_STASH_EVENTS"
            if [ -n "$TEST_NODE_AFTER_GUI" ]; then
                local tmp="$FAKE_STASH_STATE.tmp"
                jq --arg node "$TEST_NODE_AFTER_GUI" --arg group "$TEST_ORIGINAL_GROUP" \
                    '.selected = $node | .group_selected[$group] = $node' "$FAKE_STASH_STATE" > "$tmp"
                mv "$tmp" "$FAKE_STASH_STATE"
            fi
            echo "GUI-POST-RESTART-NODE"
        }
        get_gui_current_node() { get_gui_selected_node; }
        read_gui_selected_node() { get_gui_selected_node; }

        if [ -n "$TEST_DIAGNOSTIC_PROBE_ROUTE" ]; then
            diagnostic_probe_route() {
                printf '%s\n' "$TEST_DIAGNOSTIC_PROBE_ROUTE"
            }
        fi

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
        "TEST_ORIGINAL_GROUP": "Default Proxy",
        "TEST_RESTART_NODE": restart_node,
        "TEST_RESTART_RC": "0",
        "TEST_RESTORE_RESTART_NODE": restore_restart_node,
        "TEST_RESTORE_RESTART_RC": str(restore_restart_rc),
        "TEST_MATCH_GROUP_AFTER_RESTART": match_group_after_restart,
        "TEST_MATCH_GROUP_AFTER_RESTORE": match_group_after_restore,
        "TEST_NODE_AFTER_GUI": node_after_gui,
        "FAKE_STASH_STATE": str(state_path),
        "FAKE_STASH_EVENTS": str(events_path),
        "FAKE_PROBE_CODES": probe_codes,
        "FAKE_PROBE_GROUP": probe_group,
        "FAKE_SWITCH_HTTP_STATUS": str(switch_http_status),
        "FAKE_SWITCH_TRANSPORT_RC": str(switch_transport_rc),
        "FAKE_SWITCH_APPLIES": "true" if switch_applies else "false",
        "FAKE_RESTORE_HTTP_STATUS": str(restore_http_status),
        "FAKE_RESTORE_TRANSPORT_RC": str(restore_transport_rc),
        "FAKE_RESTORE_APPLIES": "true" if restore_applies else "false",
        "FAKE_SELECTABLE_NODES": ",".join(selectable_nodes),
        "FAKE_NODE_DELAYS": json.dumps(node_delays or {}),
        "FAKE_GROUP_READBACKS": ",".join(group_readbacks),
        "FAKE_NODES_AFTER_PROBE": ",".join(nodes_after_probe),
        "FAKE_RELOAD_HTTP_STATUS": str(reload_http_status),
        "FAKE_RELOAD_TRANSPORT_RC": str(reload_transport_rc),
        "FAKE_RELOAD_CHANGES_RUNTIME": "true" if reload_changes_runtime else "false",
        "FAKE_FORCE_HTTP_STATUS": str(force_http_status),
        "FAKE_FORCE_TRANSPORT_RC": str(force_transport_rc),
        "FAKE_FORCE_CHANGES_CONFIG": "true" if force_changes_config else "false",
        "FAKE_PROVIDER_HTTP_STATUS": str(provider_http_status),
        "FAKE_PROVIDER_TRANSPORT_RC": str(provider_transport_rc),
        "FAKE_PROVIDER_CHANGES_FINGERPRINT": "true" if provider_changes_fingerprint else "false",
        "FAKE_PROVIDER_BODY": provider_body,
        "FAKE_STASH_CONFIG": str(stash_dir / "config.yaml"),
        "FAKE_PROBE_RULE_TYPE": probe_rule_type,
        "FAKE_PROBE_RULE_PAYLOAD": probe_rule_payload,
        "TEST_DIAGNOSTIC_PROBE_ROUTE": diagnostic_probe_route,
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


def _hypothesis_status(output: str, hypothesis: str) -> str:
    pattern = rf"^DIAG hypothesis={re.escape(hypothesis)} status=(confirmed|rejected|unresolved)$"
    matches = re.findall(pattern, output, re.MULTILINE)
    assert len(matches) == 1, f"expected one {hypothesis} matrix record\n{output}"
    return matches[0]


def _phase_b_probe_status(output: str) -> str:
    matches = re.findall(
        r"^DIAG phase_b_probe_contract=(pass|validated-failure|measurement-unresolved)\b",
        output,
        re.MULTILINE,
    )
    assert len(matches) == 1, f"expected one Phase B probe contract record\n{output}"
    return matches[0]


def _provider_update_record(output: str) -> dict[str, str]:
    lines = [line for line in output.splitlines() if line.startswith("DIAG provider_update=airport ")]
    assert len(lines) == 1, f"expected one provider update record\n{output}"
    line = lines[0]
    record = {}
    for key in (
        "provider_update",
        "transport",
        "http_status",
        "before_fingerprint",
        "after_fingerprint",
    ):
        match = re.search(rf"(?:^| ){key}=(\S+)", line)
        assert match, f"missing structured {key} evidence\n{line}"
        record[key] = match.group(1)
    body = re.search(r"(?:^| )result=(.*?) before_fingerprint=", line)
    assert body, f"missing structured response body evidence\n{line}"
    record["result"] = body.group(1)
    return record


def _restore_record(output: str) -> dict[str, str]:
    lines = [line for line in output.splitlines() if line.startswith("DIAG restore=")]
    assert len(lines) == 1, f"expected one structured restore record\n{output}"
    line = lines[0]
    pattern = re.compile(
        r"^DIAG restore=(?P<restore>success|failure) "
        r"requested_group=(?P<requested_group>.*?) "
        r"requested_node=(?P<requested_node>\S+) "
        r"transport=(?P<transport>ok|failed) "
        r"http_status=(?P<http_status>\S+) "
        r"restart=(?P<restart>api-ready|api-unavailable) "
        r"pre-restart_selection=(?P<pre_restart_selection>\S+) "
        r"post-restart_selection=(?P<post_restart_selection>\S+)"
        r"(?: result=.*)?$"
    )
    match = pattern.fullmatch(line)
    assert match, f"incomplete structured restore evidence\n{line}"
    return match.groupdict()


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
    assert _current_probe_route_records(result.stdout) == [
        {
            "probe_rule": "DOMAIN",
            "probe_payload": "www.gstatic.com",
            "probe_group": "Default Proxy",
            "url": "http://www.gstatic.com/generate_204",
        }
    ]
    assert _reproduction_status(result.stdout) == "confirmed"
    assert _phase_b_probe_status(result.stdout) == "validated-failure"


def test_unresolved_route_cannot_confirm_reproduction_when_its_group_field_matches(
    tmp_path, monitor_library
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="000,000,000",
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
        probe_rule_type="DOMAIN-KEYWORD",
        probe_rule_payload="gstatic",
        diagnostic_probe_route="UNRESOLVED\tunsupported-current-route\tDefault Proxy",
    )
    assert result.returncode == 0, result.stderr
    assert _current_probe_route_records(result.stdout) == [
        {
            "probe_rule": "UNRESOLVED",
            "probe_payload": "unsupported-current-route",
            "probe_group": "Default Proxy",
            "url": "http://www.gstatic.com/generate_204",
        }
    ]
    assert _reproduction_status(result.stdout) == "unresolved"
    assert _phase_b_probe_status(result.stdout) == "measurement-unresolved"


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
    assert _hypothesis_status(result.stdout, "shared_data_path") == "unresolved"

    if case == "restart-node-loss":
        _assert_fields_share_a_line(result.stdout, "post-restart", "selection", "POST-RESTART-NODE")
    elif case == "route-group-mismatch":
        route_records = _current_probe_route_records(result.stdout)
        assert route_records[0]["probe_group"] == "Probe Policy"
        assert "requested_group=Default Proxy" in result.stdout
    elif case == "earlier-probe-node-mismatch":
        diagnostic_probes = [event for event in events if event["kind"] == "http_probe"][:2]
        assert [event["selected"] for event in diagnostic_probes] == ["OTHER-NODE", "JP-DIAGNOSTIC"]


def test_unresolved_probe_route_cannot_confirm_routing_mismatch_or_shared_data_path(
    tmp_path, monitor_library
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="000,000,000",
        probe_group="Unprovable Group",
        probe_rule_type="DOMAIN-KEYWORD",
        probe_rule_payload="gstatic",
        restart_node="JP-DIAGNOSTIC",
    )
    assert result.returncode == 0, result.stderr
    route_records = _current_probe_route_records(result.stdout)
    assert route_records[0]["probe_rule"] == "UNRESOLVED"
    assert "reproduction=unresolved" in result.stdout
    assert "route_correlation=false" in result.stdout
    assert _hypothesis_status(result.stdout, "probe_routing_mismatch") == "unresolved"
    assert _hypothesis_status(result.stdout, "shared_data_path") == "unresolved"


@pytest.mark.parametrize(
    ("case", "run_kwargs", "hypothesis"),
    [
        (
            "runtime-transport-failed-despite-2xx-and-changed-fingerprint",
            {
                "reload_http_status": 202,
                "reload_transport_rc": 7,
                "reload_changes_runtime": True,
            },
            "runtime_config_reload",
        ),
        (
            "runtime-http-405-despite-changed-fingerprint",
            {
                "reload_http_status": 405,
                "reload_transport_rc": 0,
                "reload_changes_runtime": True,
            },
            "runtime_config_reload",
        ),
        (
            "whole-config-transport-failed-despite-2xx-and-changed-fingerprint",
            {
                "config_model": "subscribed_whole_config",
                "force_http_status": 202,
                "force_transport_rc": 7,
                "force_changes_config": True,
            },
            "whole_config_subscription",
        ),
        (
            "whole-config-http-500-despite-changed-fingerprint",
            {
                "config_model": "subscribed_whole_config",
                "force_http_status": 500,
                "force_transport_rc": 0,
                "force_changes_config": True,
            },
            "whole_config_subscription",
        ),
    ],
)
def test_reload_hypotheses_require_transport_success_and_http_2xx_before_fingerprints(
    tmp_path, monitor_library, case, run_kwargs, hypothesis
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="000,000,000",
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
        **run_kwargs,
    )
    assert result.returncode == 0, f"{case}: {result.stderr}"
    assert _hypothesis_status(result.stdout, hypothesis) == "unresolved", f"{case}\n{result.stdout}"


def test_successful_transport_and_2xx_allow_changed_fingerprints_to_confirm(
    tmp_path, monitor_library
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        config_model="subscribed_whole_config",
        probe_codes="000,000,000",
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
        reload_http_status=202,
        reload_transport_rc=0,
        reload_changes_runtime=True,
        force_http_status=202,
        force_transport_rc=0,
        force_changes_config=True,
    )
    assert result.returncode == 0, result.stderr
    assert _hypothesis_status(result.stdout, "runtime_config_reload") == "confirmed"
    assert _hypothesis_status(result.stdout, "whole_config_subscription") == "confirmed"


@pytest.mark.parametrize(
    "run_kwargs",
    [
        {"switch_http_status": 500},
        {"switch_applies": False},
        {
            "node_after_gui": "OTHER-NODE",
            "nodes_after_probe": ("JP-DIAGNOSTIC", "JP-DIAGNOSTIC"),
        },
    ],
)
def test_correlation_invalid_reproduction_has_no_dependent_confirmed_hypothesis(
    tmp_path, monitor_library, run_kwargs
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_codes="000,000,000",
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
        **run_kwargs,
    )
    assert result.returncode == 0, result.stderr
    assert "reproduction=unresolved" in result.stdout
    assert "route_correlation=false" in result.stdout
    for hypothesis in (
        "probe_routing_mismatch",
        "runtime_config_reload",
        "whole_config_subscription",
        "shared_data_path",
    ):
        assert _hypothesis_status(result.stdout, hypothesis) != "confirmed"


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


@pytest.mark.parametrize(
    (
        "case",
        "provider_http_status",
        "provider_transport_rc",
        "provider_body",
        "expected_transport",
        "expected_hypothesis",
    ),
    [
        ("successful-2xx", 204, 0, "provider-updated", "ok", "confirmed"),
        ("http-500", 500, 0, "provider-rejected", "ok", "unresolved"),
        ("transport-failure", 204, 7, "response-before-disconnect", "failed", "unresolved"),
    ],
)
def test_provider_hypothesis_and_record_require_operation_specific_transport_evidence(
    tmp_path,
    monitor_library,
    case,
    provider_http_status,
    provider_transport_rc,
    provider_body,
    expected_transport,
    expected_hypothesis,
):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        config_model="proxy_provider",
        provider_http_status=provider_http_status,
        provider_transport_rc=provider_transport_rc,
        provider_changes_fingerprint=True,
        provider_body=provider_body,
    )
    assert result.returncode == 0, f"{case}: {result.stderr}"
    assert _hypothesis_status(result.stdout, "proxy_provider_state") == expected_hypothesis

    provider_events = [
        event
        for event in events
        if event["kind"] == "api"
        and event["method"] == "PUT"
        and event["endpoint"] == "/providers/proxies/airport"
    ]
    assert len(provider_events) == 1
    assert provider_events[0]["status"] == provider_http_status

    record = _provider_update_record(result.stdout)
    assert record["provider_update"] == "airport"
    assert record["transport"] == expected_transport
    assert record["http_status"] == str(provider_http_status)
    assert record["result"] == provider_body
    assert record["before_fingerprint"] != record["after_fingerprint"]


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


def test_live_diagnostic_reports_success_only_after_complete_exact_group_restoration(
    tmp_path, monitor_library
):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
        restore_http_status=204,
        restore_transport_rc=0,
        restore_applies=True,
        restore_restart_node="ORIGINAL-NODE",
    )
    assert result.returncode == 0, result.stderr
    record = _restore_record(result.stdout)
    assert record == {
        "restore": "success",
        "requested_group": "Default Proxy",
        "requested_node": "ORIGINAL-NODE",
        "transport": "ok",
        "http_status": "204",
        "restart": "api-ready",
        "pre_restart_selection": "ORIGINAL-NODE",
        "post_restart_selection": "ORIGINAL-NODE",
    }
    restore_puts = [event for event in events if event.get("operation") == "restore"]
    assert [(event["group"], event["target"]) for event in restore_puts] == [
        ("Default Proxy", "ORIGINAL-NODE")
    ]


@pytest.mark.parametrize(
    ("case", "run_kwargs", "expected_evidence"),
    [
        (
            "transport-failure",
            {"restore_transport_rc": 7},
            {"transport": "failed", "http_status": "204", "restart": "api-ready"},
        ),
        (
            "http-500",
            {"restore_http_status": 500},
            {"transport": "ok", "http_status": "500", "restart": "api-ready"},
        ),
        (
            "pre-restart-mismatch",
            {"restore_applies": False},
            {"pre_restart_selection": "JP-DIAGNOSTIC"},
        ),
        (
            "restart-api-unavailable",
            {"restore_restart_rc": 1},
            {"restart": "api-unavailable"},
        ),
        (
            "post-restart-mismatch-on-fixed-group",
            {
                "restore_restart_node": "LOST-AFTER-RESTORE",
                "match_group_after_restore": "Drifted Group",
            },
            {"post_restart_selection": "LOST-AFTER-RESTORE"},
        ),
    ],
)
def test_incomplete_exact_group_restoration_is_structured_terminal_failure(
    tmp_path, monitor_library, case, run_kwargs, expected_evidence
):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_group="Default Proxy",
        restart_node="JP-DIAGNOSTIC",
        **run_kwargs,
    )
    assert result.returncode != 0, f"{case}\n{result.stdout}"
    record = _restore_record(result.stdout)
    assert record["restore"] == "failure"
    assert record["requested_group"] == "Default Proxy"
    assert record["requested_node"] == "ORIGINAL-NODE"
    for field, expected in expected_evidence.items():
        assert record[field] == expected

    if case == "post-restart-mismatch-on-fixed-group":
        second_restart = [
            index for index, event in enumerate(events) if event["kind"] == "restart"
        ][1]
        post_restore_reads = [
            event["endpoint"]
            for event in events[second_restart + 1 :]
            if event["kind"] == "api" and event["method"] == "GET"
        ]
        assert "/proxies/Default Proxy" in post_restore_reads


@pytest.mark.parametrize(
    ("case", "run_kwargs"),
    [
        (
            "switch-non-2xx",
            {
                "switch_http_status": 500,
                "switch_applies": True,
                "restart_node": "LOST-AFTER-RESTART",
            },
        ),
        (
            "pre-restart-readback-mismatch",
            {
                "switch_applies": False,
                "restart_node": "LOST-AFTER-RESTART",
            },
        ),
        (
            "exact-group-readback-unavailable",
            {
                "restart_node": "LOST-AFTER-RESTART",
                "group_readbacks": (
                    "ORIGINAL-NODE",
                    "ORIGINAL-NODE",
                    "__EMPTY__",
                    "LOST-AFTER-RESTART",
                ),
            },
        ),
    ],
)
def test_selection_persistence_is_unresolved_without_valid_prerequisite_evidence(
    tmp_path, monitor_library, case, run_kwargs
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_group="Default Proxy",
        **run_kwargs,
    )
    assert result.returncode == 0, f"{case}: {result.stderr}"
    assert _hypothesis_status(result.stdout, "selection_persistence") == "unresolved", (
        f"{case}\n{result.stdout}"
    )


@pytest.mark.parametrize(
    ("restart_node", "expected_status"),
    [
        ("JP-DIAGNOSTIC", "rejected"),
        ("LOST-AFTER-RESTART", "confirmed"),
    ],
)
def test_selection_persistence_classifies_only_complete_valid_evidence(
    tmp_path, monitor_library, restart_node, expected_status
):
    result, _ = _diagnostic_run(
        tmp_path,
        monitor_library,
        probe_group="Default Proxy",
        restart_node=restart_node,
    )
    assert result.returncode == 0, result.stderr
    assert _hypothesis_status(result.stdout, "selection_persistence") == expected_status


@pytest.mark.parametrize(
    ("case", "selectable_nodes", "node_delays"),
    [
        ("only-original-node", ("ORIGINAL-NODE",), {"ORIGINAL-NODE": 40}),
        (
            "all-alternatives-unreachable",
            ("ORIGINAL-NODE", "JP-UNREACHABLE", "TW-UNREACHABLE"),
            {"ORIGINAL-NODE": 40, "JP-UNREACHABLE": 0, "TW-UNREACHABLE": 0},
        ),
    ],
)
def test_no_delay_reachable_alternative_stops_before_reproduction_side_effects(
    tmp_path, monitor_library, case, selectable_nodes, node_delays
):
    result, events = _diagnostic_run(
        tmp_path,
        monitor_library,
        selectable_nodes=selectable_nodes,
        node_delays=node_delays,
    )
    assert result.returncode == 0, f"{case}: {result.stderr}"
    _assert_fields_share_a_line(
        result.stdout,
        "reproduction",
        "unresolved",
        "reason",
        "no_delay_reachable_candidate",
    )
    assert "requested_node=ORIGINAL-NODE" not in result.stdout
    assert not any(event.get("operation") == "switch" for event in events)
    assert not any(event["kind"] == "restart" for event in events)
    assert not any(event["kind"] == "http_probe" for event in events)


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
