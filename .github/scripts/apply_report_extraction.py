#!/usr/bin/env python3
from pathlib import Path

path = Path("vpn_monitor.sh")
text = path.read_text(encoding="utf-8")

config_line = 'CONFIG_SWITCHER="$SCRIPT_DIR/stash_switch_config.py"\n'
report_line = 'REPORT_SCRIPT="$SCRIPT_DIR/vpn_report.py"\n'
if report_line not in text:
    if config_line not in text:
        raise SystemExit("CONFIG_SWITCHER anchor not found")
    text = text.replace(config_line, config_line + report_line, 1)

start_marker = "cmd_report() {\n"
end_marker = "\ncmd_status() {"
start = text.find(start_marker)
if start < 0:
    raise SystemExit("cmd_report anchor not found")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("cmd_status anchor not found")

new_cmd_report = '''cmd_report() {
    local period="${1:-}"
    if [ -z "$period" ]; then
        echo "Usage: vpn_monitor.sh --report <period>" >&2
        echo "Examples: 1h, 24h, 1d, 7d" >&2
        return 2
    fi
    if ! [[ "$period" =~ ^[1-9][0-9]*[hd]$ ]]; then
        echo "Invalid report period: $period" >&2
        echo "Usage: vpn_monitor.sh --report <period>" >&2
        echo "Examples: 1h, 24h, 1d, 7d" >&2
        return 2
    fi
    if ! has_python; then
        echo "Error: Python is required for --report ($PYTHON_BIN)" >&2
        return 1
    fi
    if [ ! -f "$REPORT_SCRIPT" ]; then
        echo "Error: report script not found: $REPORT_SCRIPT" >&2
        return 1
    fi

    "$PYTHON_BIN" "$REPORT_SCRIPT" "$LOG_FILE" "$period"
}
'''
text = text[:start] + new_cmd_report + text[end:]

update_anchor = '    cp "$repo/stash_switch_config.py" "$dest_dir/stash_switch_config.py" && updated=$((updated + 1))\n'
update_report = '    cp "$repo/vpn_report.py" "$dest_dir/vpn_report.py" && updated=$((updated + 1))\n'
if update_report not in text:
    if update_anchor not in text:
        raise SystemExit("--update copy anchor not found")
    text = text.replace(update_anchor, update_anchor + update_report, 1)

old_uninstall = "    for f in vpn_monitor.sh stash_switch_config.py; do"
new_uninstall = "    for f in vpn_monitor.sh stash_switch_config.py vpn_report.py; do"
if old_uninstall in text:
    text = text.replace(old_uninstall, new_uninstall, 1)
elif new_uninstall not in text:
    raise SystemExit("uninstall file-list anchor not found")

path.write_text(text, encoding="utf-8")
