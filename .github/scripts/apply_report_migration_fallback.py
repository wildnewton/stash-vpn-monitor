#!/usr/bin/env python3
from pathlib import Path

path = Path("vpn_monitor.sh")
text = path.read_text(encoding="utf-8")

old = '''    if [ ! -f "$REPORT_SCRIPT" ]; then
        echo "Error: report script not found: $REPORT_SCRIPT" >&2
        return 1
    fi

    "$PYTHON_BIN" "$REPORT_SCRIPT" "$LOG_FILE" "$period"
'''
new = '''    local report_script="$REPORT_SCRIPT"
    if [ ! -f "$report_script" ]; then
        local repo
        repo=$(detect_repo 2>/dev/null)
        if [ -n "$repo" ] && [ -f "$repo/vpn_report.py" ]; then
            report_script="$repo/vpn_report.py"
        else
            echo "Error: report script not found: $REPORT_SCRIPT" >&2
            return 1
        fi
    fi

    "$PYTHON_BIN" "$report_script" "$LOG_FILE" "$period"
'''

if old not in text:
    if new in text:
        raise SystemExit(0)
    raise SystemExit("cmd_report helper block not found")

path.write_text(text.replace(old, new, 1), encoding="utf-8")
