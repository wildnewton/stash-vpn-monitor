#!/usr/bin/env python3
"""Issue #15 — time-based log retention: report-side behavior tests.

These tests exercise the public interface of vpn_report.py:
  - read_events enumerates every retained log file (active, legacy .old,
    and dated vpn_monitor.log.YYYY-MM-DD) and returns chronologically sorted
    events;
  - an incident whose events straddle a rotation boundary is rebuilt as a
    single continuous incident;
  - when the requested lookback predates retained data the report reports
    PARTIAL coverage and surfaces the actual earliest retained timestamp.

Run with: python3 -m pytest -q
"""

import importlib.util
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import vpn_report as vr  # noqa: E402


def _stamp(base: datetime, seconds_ago: int) -> str:
    return (base - timedelta(seconds=seconds_ago)).strftime(vr.TS_FORMAT)


def _write(path: Path, lines):
    with path.open("w", encoding="utf-8") as handle:
        for ts, msg in lines:
            handle.write("[%s] %s\n" % (ts, msg))


def _healthy(ts):
    return (ts, "狀態: 正常（Ping + HTTP 均正常）")


def _incident_start(ts):
    # Matches is_incident_start: 狀態: ... 將重試 ... 全部檢測失敗
    return (ts, "狀態: 斷線（全部檢測失敗），將重試恢復流程")


def _recovered(ts):
    return (ts, "恢復成功（手動/自動）✓")


def test_read_events_loads_active_old_and_dated_files(tmp_path):
    base = datetime(2026, 8, 22, 8, 0, 0)
    log = tmp_path / "vpn_monitor.log"
    old = tmp_path / "vpn_monitor.log.old"
    d20 = tmp_path / "vpn_monitor.log.2026-08-20"
    d21 = tmp_path / "vpn_monitor.log.2026-08-21"

    _write(d20, [_healthy(_stamp(base, 3600 * 50)), _healthy(_stamp(base, 3600 * 49))])
    _write(d21, [_healthy(_stamp(base, 3600 * 30)), _healthy(_stamp(base, 3600 * 29))])
    _write(old, [_healthy(_stamp(base, 3600 * 10))])
    _write(log, [_healthy(_stamp(base, 100)), _healthy(_stamp(base, 50))])

    events = vr.read_events(str(log))
    # 2 + 2 + 1 + 2 = 7 events
    assert len(events) == 7
    # chronological order across all files
    timestamps = [e.ts for e in events]
    assert timestamps == sorted(timestamps)
    # the earliest event comes from the oldest dated file
    assert timestamps[0] == datetime(2026, 8, 20, 6, 0, 0)


def test_read_events_ignores_unrelated_dotfiles(tmp_path):
    log = tmp_path / "vpn_monitor.log"
    _write(log, [_healthy(_stamp(datetime(2026, 8, 22, 8, 0, 0), 10))])
    # a stray file that must NOT be picked up
    (tmp_path / "vpn_monitor.log.bak").write_text("[2026-08-22 07:00:00] noise\n")
    (tmp_path / "vpn_monitor.log.2026-13-99").write_text("[2026-08-22 07:00:00] noise\n")

    events = vr.read_events(str(log))
    assert len(events) == 1


def test_incident_spanning_rotation_boundary_rebuilt_as_one(tmp_path):
    base = datetime(2026, 8, 22, 8, 0, 0)
    log = tmp_path / "vpn_monitor.log"
    d21 = tmp_path / "vpn_monitor.log.2026-08-21"

    # Day 21: connectivity loss begins (incident start) but no recovery recorded.
    _write(d21, [
        _healthy(_stamp(base, 3600 * 26)),
        _incident_start(_stamp(base, 3600 * 25)),
    ])
    # Day 22 (active): the recovery finally lands the next day, after rotation.
    _write(log, [
        _recovered(_stamp(base, 60)),
        _healthy(_stamp(base, 30)),
    ])

    events = vr.read_events(str(log))
    incidents = vr.build_incidents(events)
    # The unresolved incident from day 21 and the recovery on day 22 must
    # reconstruct as ONE continuous incident, not two.
    assert len(incidents) == 1
    inc = incidents[0]
    assert inc.start == datetime(2026, 8, 21, 7, 0, 0)
    assert inc.recovered is True
    assert inc.end == datetime(2026, 8, 22, 7, 59, 0)


def test_report_partial_coverage_when_lookback_predates_retained(tmp_path):
    base = datetime(2026, 8, 22, 8, 0, 0)
    log = tmp_path / "vpn_monitor.log"
    d21 = tmp_path / "vpn_monitor.log.2026-08-21"

    _write(d21, [_healthy(_stamp(base, 3600 * 25))])
    _write(log, [_healthy(_stamp(base, 100)), _healthy(_stamp(base, 50))])

    # Ask for a 30d window; retained data only goes back to day 21.
    os.environ["VPN_REPORT_NOW"] = base.strftime(vr.TS_FORMAT)
    try:
        result = vr.report(str(log), "30d")
    finally:
        os.environ.pop("VPN_REPORT_NOW", None)

    assert result["coverage"] == "PARTIAL"
    assert result["earliest"] == datetime(2026, 8, 21, 7, 0, 0)


def test_report_full_coverage_within_retained(tmp_path):
    base = datetime(2026, 8, 22, 8, 0, 0)
    log = tmp_path / "vpn_monitor.log"
    d21 = tmp_path / "vpn_monitor.log.2026-08-21"

    _write(d21, [_healthy(_stamp(base, 3600 * 25))])
    _write(log, [_healthy(_stamp(base, 100)), _healthy(_stamp(base, 50))])

    os.environ["VPN_REPORT_NOW"] = base.strftime(vr.TS_FORMAT)
    try:
        result = vr.report(str(log), "1d")
    finally:
        os.environ.pop("VPN_REPORT_NOW", None)

    # cutoff = day21 08:00; retained history reaches day21 07:00 (<= cutoff)
    assert result["coverage"] == "FULL"
