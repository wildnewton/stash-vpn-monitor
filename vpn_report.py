#!/usr/bin/env python3
"""Historical, log-only status reporting for VPN Monitor."""

import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional, Tuple

TS_FORMAT = "%Y-%m-%d %H:%M:%S"
LINE_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s?(.*)$")
PERIOD_RE = re.compile(r"^([1-9]\d*)([hd])$")
NODE_SWITCH_RE = re.compile(r"節點切換成功:\s*(.+)\s+—\s+同步 GUI（重啟 Stash）\s*$")
NODE_SWITCH_FAILURE_RE = re.compile(r"節點切換失敗（目標:\s*(.+)），嘗試下一個\s*$")
NODE_FAILED_RE = re.compile(
    r"連通性驗證失敗\s*—\s*(.+)\s+在\s+\d+\s+次重試後仍不可用，嘗試下一個候選\s*$"
)
NODE_VERIFIED_RE = re.compile(r"成功切換到:\s*(.+)\s+✓\s*$")
CONFIG_SWITCH_RE = re.compile(r"Config 切換成功:\s*(.+?)\s*$")


@dataclass
class Event:
    ts: datetime
    message: str


@dataclass
class Incident:
    start: datetime
    start_message: str
    end: Optional[datetime] = None
    recovery_message: Optional[str] = None
    actions: List[Tuple[datetime, str]] = field(default_factory=list)

    @property
    def recovered(self):
        return self.end is not None

    @property
    def duration_seconds(self):
        if self.end is None:
            return None
        return max(0, int((self.end - self.start).total_seconds()))


def parse_period(value):
    match = PERIOD_RE.fullmatch(value)
    if not match:
        raise ValueError(value)
    amount = int(match.group(1))
    return timedelta(hours=amount) if match.group(2) == "h" else timedelta(days=amount)


def parse_now():
    override = os.environ.get("VPN_REPORT_NOW")
    if override:
        return datetime.strptime(override, TS_FORMAT)
    return datetime.now().replace(microsecond=0)


def read_events(log_file):
    events = []
    for path in (Path(log_file + ".old"), Path(log_file)):
        if not path.is_file():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                match = LINE_RE.match(raw.rstrip("\n"))
                if not match:
                    continue
                try:
                    ts = datetime.strptime(match.group(1), TS_FORMAT)
                except ValueError:
                    continue
                events.append(Event(ts=ts, message=match.group(2)))
    events.sort(key=lambda event: event.ts)
    return events


def is_incident_start(message):
    return message.startswith("狀態:") and "將重試" in message and (
        "全部檢測失敗" in message or "HTTP 代理失敗" in message
    )


def is_healthy_observation(message):
    return message.startswith("狀態: 正常") or message.startswith("狀態: HTTP 正常")


def is_connectivity_observation(message):
    return is_incident_start(message) or is_healthy_observation(message)


def explicit_recovery(message):
    return ("重試 #" in message and "已恢復 ✓" in message) or message.startswith("恢復成功（")


def action_for(message):
    if message.strip() == "=== 開始恢復流程 ===":
        return "recovery flow started"
    match = NODE_SWITCH_FAILURE_RE.search(message)
    if match:
        return "node switch API failed: " + match.group(1).strip()
    match = NODE_SWITCH_RE.search(message)
    if match:
        return "node switch API success: " + match.group(1).strip()
    match = NODE_FAILED_RE.search(message)
    if match:
        return "connectivity failed after switch: " + match.group(1).strip()
    match = NODE_VERIFIED_RE.search(message)
    if match:
        return "connectivity verified: " + match.group(1).strip()
    if "強制刷新訂閱" in message and message.lstrip().startswith(">>> Step"):
        return "subscription refresh"
    match = CONFIG_SWITCH_RE.search(message)
    if match:
        return "config switch: " + match.group(1).strip()
    if "恢復失敗" in message:
        return "recovery exhausted"
    return None


def build_incidents(events):
    incidents = []
    current = None
    for event in events:
        message = event.message
        if is_incident_start(message):
            if current is None:
                current = Incident(start=event.ts, start_message=message)
                incidents.append(current)
            continue
        if current is None:
            continue
        action = action_for(message)
        if action and (not current.actions or current.actions[-1][1] != action):
            current.actions.append((event.ts, action))
        if explicit_recovery(message) or is_healthy_observation(message):
            current.end = event.ts
            current.recovery_message = message
            current = None
    return incidents


def format_duration(seconds):
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return "%dh %dm %ds" % (hours, minutes, secs)
    return "%dm %ds" % (minutes, secs)


def short_time(ts):
    return ts.strftime(TS_FORMAT)


def report(log_file, period_text):
    delta = parse_period(period_text)
    now = parse_now()
    cutoff = now - delta
    all_events = read_events(log_file)
    observed_events = [event for event in all_events if event.ts <= now]
    window_events = [event for event in observed_events if event.ts >= cutoff]

    earliest = all_events[0].ts if all_events else None
    if earliest is None:
        coverage = "NONE"
    elif earliest > cutoff:
        coverage = "PARTIAL"
    else:
        coverage = "FULL"

    all_incidents = build_incidents(observed_events)
    incidents = [
        incident
        for incident in all_incidents
        if incident.start <= now and (incident.end is None or incident.end >= cutoff)
    ]
    recovered = [incident for incident in incidents if incident.recovered]
    unresolved = [incident for incident in incidents if not incident.recovered]
    has_window_observation = any(is_connectivity_observation(event.message) for event in window_events)

    node_switch_attempts = 0
    api_confirmed_switches = 0
    connectivity_verified_switches = 0
    post_switch_failures = 0
    subscription_refreshes = 0
    config_switches = 0
    problematic_nodes = Counter()
    for event in window_events:
        api_success = NODE_SWITCH_RE.search(event.message)
        api_failure = NODE_SWITCH_FAILURE_RE.search(event.message)
        verified = NODE_VERIFIED_RE.search(event.message)
        failed = NODE_FAILED_RE.search(event.message)
        if api_success:
            node_switch_attempts += 1
            api_confirmed_switches += 1
        elif api_failure:
            node_switch_attempts += 1
        if verified:
            connectivity_verified_switches += 1
        if failed:
            post_switch_failures += 1
            problematic_nodes[failed.group(1).strip()] += 1
        if "強制刷新訂閱" in event.message and event.message.lstrip().startswith(">>> Step"):
            subscription_refreshes += 1
        if CONFIG_SWITCH_RE.search(event.message):
            config_switches += 1

    if unresolved:
        status = "ATTENTION"
    elif incidents:
        status = "RECOVERED"
    elif not has_window_observation:
        status = "NO DATA"
    else:
        status = "HEALTHY"

    print("VPN Monitor Report — past %s" % period_text)
    print("Period: %s → %s" % (short_time(cutoff), short_time(now)))
    print("Log coverage: %s" % coverage)
    if coverage == "PARTIAL" and earliest is not None:
        print("Available log begins: %s" % short_time(earliest))
    elif coverage == "NONE":
        print("Available log begins: no timestamped log entries")
    print()
    print("Status: %s" % status)
    print("Incidents: %d" % len(incidents))
    print("Recovered: %d" % len(recovered))
    print("Unresolved: %d" % len(unresolved))
    print("Node switch attempts: %d" % node_switch_attempts)
    print("API-confirmed node switches: %d" % api_confirmed_switches)
    print("Connectivity-verified node switches: %d" % connectivity_verified_switches)
    print("Post-switch connectivity failures: %d" % post_switch_failures)
    print("Subscription refreshes: %d" % subscription_refreshes)
    print("Config switches: %d" % config_switches)

    durations = [incident.duration_seconds for incident in recovered if incident.duration_seconds is not None]
    if durations:
        average = int(round(float(sum(durations)) / len(durations)))
        print("Average recovery: %s" % format_duration(average))
        print("Longest recovery: %s" % format_duration(max(durations)))

    if not incidents:
        print()
        if coverage == "NONE":
            print("No timestamped log data available for this report.")
        elif not has_window_observation:
            print("No connectivity observations in the requested period.")
        else:
            print("No connectivity incidents detected.")
        return

    print()
    print("Incidents")
    for index, incident in enumerate(incidents, start=1):
        boundary_note = "; started before period" if incident.start < cutoff else ""
        visible_actions = [(action_ts, action) for action_ts, action in incident.actions if action_ts >= cutoff]
        if incident.recovered:
            print(
                "Incident %d: %s → %s (%s, recovered%s)" % (
                    index,
                    short_time(incident.start),
                    short_time(incident.end),
                    format_duration(incident.duration_seconds or 0),
                    boundary_note,
                )
            )
        else:
            print("Incident %d: %s → unresolved%s" % (index, short_time(incident.start), boundary_note))
        if visible_actions:
            print("  " + " → ".join(action for _, action in visible_actions))

    if problematic_nodes:
        print()
        print("Problematic nodes")
        for node, count in problematic_nodes.most_common():
            print("  %s — post-switch connectivity failures: %d" % (node, count))

    print()
    print("Timeline")
    for incident in incidents:
        if incident.start >= cutoff:
            print("  %s  connectivity issue detected" % incident.start.strftime("%m-%d %H:%M:%S"))
        else:
            print("  %s  incident already in progress at period start" % cutoff.strftime("%m-%d %H:%M:%S"))
        for action_ts, action in incident.actions:
            if action_ts >= cutoff:
                print("  %s  %s" % (action_ts.strftime("%m-%d %H:%M:%S"), action))
        if incident.end is not None:
            print("  %s  connectivity recovered" % incident.end.strftime("%m-%d %H:%M:%S"))
        else:
            print("  %s  no recovery observed by report time" % now.strftime("%m-%d %H:%M:%S"))


def main(argv):
    if len(argv) != 3:
        print("Usage: vpn_report.py <log-file> <period>", file=sys.stderr)
        return 2
    try:
        report(argv[1], argv[2])
    except (ValueError, OverflowError):
        print("Invalid report period: %s" % argv[2], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
