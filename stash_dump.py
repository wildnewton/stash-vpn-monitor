#!/usr/bin/env python3
"""Dump Stash accessibility tree to find proxy switching UI elements.
Run: python3 stash_dump.py
"""
import Quartz  # for NSWorkspace, NSApplicationActivateIgnoringOtherApps
import ApplicationServices as AX  # for AXUIElement* functions (pyobjc 12.x)
import time
import sys


def ax_get(elem, attr):
    """Get an accessibility attribute, returns value or None."""
    try:
        val = AX.AXUIElementCopyAttributeValue(elem, attr, None)
        return val
    except Exception:
        return None


def ax_get_children(elem):
    """Get children of an element."""
    return ax_get(elem, 'AXChildren') or []


def describe_element(elem, depth=0, max_lines=500, lines_collector=None):
    """Recursively describe an AXUIElement."""
    if lines_collector is None:
        lines_collector = []
    if depth > 12 or len(lines_collector) >= max_lines:
        return lines_collector

    indent = "  " * depth

    # Check if element is valid
    try:
        pid = AX.AXUIElementGetPid(elem)
    except Exception:
        lines_collector.append(indent + "(invalid element)\n")
        return lines_collector

    # Get role
    role = ax_get(elem, 'AXRole') or '?'
    # Get title
    title = ax_get(elem, 'AXTitle')
    title_str = f' title="{title}"' if title else ''
    # Get description
    desc = ax_get(elem, 'AXDescription')
    desc_str = f' desc="{desc}"' if desc else ''
    # Get value
    value = ax_get(elem, 'AXValue')
    value_str = f' value="{value}"' if value is not None and value != '' else ''
    # Get identifier
    identifier = ax_get(elem, 'AXIdentifier')
    id_str = f' id="{identifier}"' if identifier else ''
    # Get enabled state
    enabled = ax_get(elem, 'AXEnabled')
    en_str = '' if enabled in (None, True) else ' DISABLED'
    # Get position/size (useful for clicking)
    pos = ax_get(elem, 'AXPosition')
    size = ax_get(elem, 'AXSize')
    frame_str = ''
    if pos and size:
        x = pos.x if hasattr(pos, 'x') else (pos[0] if isinstance(pos, (tuple, list)) else 0)
        y = pos.y if hasattr(pos, 'y') else (pos[1] if isinstance(pos, (tuple, list)) else 0)
        w = size.width if hasattr(size, 'width') else (size[0] if isinstance(size, (tuple, list)) else 0)
        h = size.height if hasattr(size, 'height') else (size[1] if isinstance(size, (tuple, list)) else 0)
        frame_str = f' frame=({int(x)},{int(y)} {int(w)}x{int(h)})'

    line = f"{indent}{role}{title_str}{desc_str}{value_str}{id_str}{frame_str}{en_str}\n"
    lines_collector.append(line)

    # Get children
    children = ax_get_children(elem)
    for child in children:
        describe_element(child, depth + 1, max_lines, lines_collector)
        if len(lines_collector) >= max_lines:
            lines_collector.append(f"{indent}  ... (truncated)\n")
            return lines_collector

    return lines_collector


def find_elements_by_role(root_elem, target_role, results=None, max_results=50):
    """Find all elements matching a given role."""
    if results is None:
        results = []
    if len(results) >= max_results:
        return results

    role = ax_get(root_elem, 'AXRole') or ''
    if role == target_role:
        results.append(root_elem)

    for child in ax_get_children(root_elem):
        find_elements_by_role(child, target_role, results, max_results)

    return results


def find_elements_by_title(root_elem, keyword, results=None, max_results=30):
    """Find elements whose title contains keyword."""
    if results is None:
        results = []
    if len(results) >= max_results:
        return results

    title = ax_get(root_elem, 'AXTitle') or ''
    if keyword.lower() in title.lower():
        results.append(root_elem)

    for child in ax_get_children(root_elem):
        find_elements_by_title(child, keyword, results, max_results)

    return results


def main():
    # Find Stash process
    ws = Quartz.NSWorkspace.sharedWorkspace()
    apps = ws.runningApplications()

    stash_pid = None
    stash_name = None
    for app in apps:
        name = app.localizedName()
        if name and 'stash' in name.lower():
            stash_pid = app.processIdentifier()
            stash_name = name
            print(f"Found Stash: pid={stash_pid}, name={name}")
            break

    if not stash_pid:
        print("Stash not running!")
        sys.exit(1)

    # Activate Stash (bring to front)
    stash_app = None
    for app in apps:
        if app.processIdentifier() == stash_pid:
            stash_app = app
            break

    if stash_app:
        stash_app.activateWithOptions_(Quartz.NSApplicationActivateIgnoringOtherApps)
        time.sleep(1.5)

    # Get Stash's app element
    app_elem = AX.AXUIElementCreateApplication(stash_pid)

    # ── Part 1: Dump focused/main window ──
    win = ax_get(app_elem, 'AXFocusedWindow')
    if not win:
        win = ax_get(app_elem, 'AXMainWindow')

    if win:
        print("\n=== Focused Window ===\n")
        lines = describe_element(win)
        tree = "".join(lines)
        print(tree[:12000])
    else:
        print("\nNo focused window. Listing all windows:")
        windows = ax_get(app_elem, 'AXWindows') or []
        for i, w in enumerate(windows):
            print(f"\n=== Window {i} ===")
            title = ax_get(w, 'AXTitle')
            print(f"Title: {title}")
            lines = describe_element(w)
            print("".join(lines)[:5000])

    # ── Part 2: Find interactable proxy rows ──
    print("\n\n=== Searching for proxy-related elements ===\n")
    search_root = win or app_elem

    # Look for rows (likely AXRow)
    rows = find_elements_by_role(search_root, 'AXRow', max_results=80)
    print(f"Found {len(rows)} AXRow elements")
    for i, row in enumerate(rows):
        title = ax_get(row, 'AXTitle') or ''
        desc = ax_get(row, 'AXDescription') or ''
        if title or desc:
            print(f"  Row[{i}]: title='{title}' desc='{desc}'")
        else:
            # Try to get the row's children
            children = ax_get_children(row)
            child_summaries = []
            for c in children:
                ct = ax_get(c, 'AXTitle') or ax_get(c, 'AXValue') or ax_get(c, 'AXDescription') or ''
                cr = ax_get(c, 'AXRole') or ''
                if ct:
                    child_summaries.append(f"{cr}:{ct}")
            if child_summaries:
                print(f"  Row[{i}]: {', '.join(child_summaries[:4])}")

    # Also look for buttons
    buttons = find_elements_by_role(search_root, 'AXButton', max_results=50)
    print(f"\nFound {len(buttons)} AXButton elements")
    for i, btn in enumerate(buttons):
        title = ax_get(btn, 'AXTitle') or ''
        desc = ax_get(btn, 'AXDescription') or ''
        pos = ax_get(btn, 'AXPosition')
        size = ax_get(btn, 'AXSize')
        frame_info = ''
        if pos and size:
            x = pos.x if hasattr(pos, 'x') else pos[0]
            y = pos.y if hasattr(pos, 'y') else pos[1]
            w = size.width if hasattr(size, 'width') else size[0]
            h = size.height if hasattr(size, 'height') else size[1]
            frame_info = f' @ ({int(x)},{int(y)} {int(w)}x{int(h)})'
        label = title or desc or '(no title)'
        print(f"  Btn[{i}]: '{label}'{frame_info}")

    # Look for static text that might be proxy names
    texts = find_elements_by_role(search_root, 'AXStaticText', max_results=80)
    print(f"\nFound {len(texts)} AXStaticText elements")
    for i, t in enumerate(texts):
        value = ax_get(t, 'AXValue') or ''
        if value and len(str(value)) > 1:
            print(f"  Text[{i}]: '{value}'")

    # ── Part 3: SystemUIServer menu bar ──
    print("\n\n=== Menu Bar Extras (SystemUIServer) ===\n")
    try:
        for app in apps:
            if app.localizedName() == 'SystemUIServer':
                sys_elem = AX.AXUIElementCreateApplication(app.processIdentifier())
                menubar = ax_get(sys_elem, 'AXExtrasMenuBar')
                if menubar:
                    lines = describe_element(menubar)
                    print("".join(lines)[:10000])
                else:
                    print("No AXExtrasMenuBar found")
                break
    except Exception as e:
        print(f"SystemUIServer error: {e}")

    print("\n=== DONE ===")


if __name__ == '__main__':
    main()
