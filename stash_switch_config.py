#!/usr/bin/env python3
"""
Stash Config Switcher — 透過 macOS Accessibility API 點擊 Stash Configs 頁面切換 config。

依賴: pyobjc-framework-ApplicationServices, pyobjc-framework-Quartz
安裝: pip install pyobjc-framework-ApplicationServices pyobjc-framework-Quartz

用法:
  python3 stash_switch_config.py --list           # 列出所有可用 config
  python3 stash_switch_config.py --status         # 顯示當前使用的 config
  python3 stash_switch_config.py <config_name>    # 切換到指定 config
  python3 stash_switch_config.py                  # 自動切到另一個 config

機制:
  1. 從 iCloud 目錄讀取所有 config 名稱（支援 N 個 config）
  2. 透過 API proxy groups 匹配判斷當前 config
  3. stash://install-config URL scheme → 打開 Stash Configs 頁面
  4. AX API 掃描 UI tree → 找到目標 config 行 (AXGroup > AXStaticText)
  5. AXPress 點擊該行 → Stash 載入目標 config
  6. CGEvent 發送 Escape 鍵關閉 Configs 對話窗口
"""
import sys, time, subprocess, os, glob, re
import ApplicationServices as AX


# ═══════════════════════════════════════════════════════════════
#  CONFIG LOADING (shared with vpn_monitor.sh)
# ═══════════════════════════════════════════════════════════════

def load_config():
    """從共享配置檔案讀取設定（與 vpn_monitor.sh 共用同一個檔案）。"""
    config_path = os.environ.get(
        'VPN_MONITOR_CONFIG',
        os.path.expanduser('~/.config/vpn_monitor/config')
    )
    cfg = {}
    if os.path.isfile(config_path):
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    k, v = line.split('=', 1)
                    v = v.strip()
                    # Strip surrounding double quotes
                    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
                        v = v[1:-1]
                    # Expand $HOME and ~ (bash source handles these, Python must too)
                    v = os.path.expandvars(v)
                    v = os.path.expanduser(v)
                    cfg[k.strip()] = v
    return cfg


_CFG = load_config()

# Stash API
API_BASE = _CFG.get('API_BASE', 'http://127.0.0.1:9090')
API_SECRET = _CFG.get('API_SECRET', '')

# Config file locations
ICLOUD_CONFIG_DIR = os.path.expanduser(_CFG.get(
    'ICLOUD_CONFIG_DIR',
    '~/Library/Mobile Documents/iCloud~ws~stash~icloud/Documents'
))


# ═══════════════════════════════════════════════════════════════
#  CONFIG DISCOVERY
# ═══════════════════════════════════════════════════════════════

def get_all_configs():
    """從 iCloud 目錄讀取所有 config 名稱（不含 .yaml 副檔名）。

    支援任意數量的 config，不硬編碼名稱。
    """
    configs = []
    if os.path.isdir(ICLOUD_CONFIG_DIR):
        for f in sorted(glob.glob(os.path.join(ICLOUD_CONFIG_DIR, '*.yaml'))):
            name = os.path.basename(f).replace('.yaml', '')
            configs.append(name)
    return configs


def get_config_groups(filepath):
    """從 config YAML 檔案中提取 proxy-group 名稱（簡單文字解析，不需 PyYAML）。

    支援兩種 YAML 格式：
    - Block style: "  - name: GroupName"
    - Flow style:  "  - {name: GroupName, type: select, ...}"
    """
    groups = set()
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            in_proxy_groups = False
            for line in f:
                stripped = line.rstrip()

                # 進入 proxy-groups 區段
                if stripped.startswith('proxy-groups:'):
                    in_proxy_groups = True
                    continue

                if in_proxy_groups:
                    # Block style: "  - name: GroupName" 或 "    name: GroupName"
                    m = re.match(r'^\s*-?\s*name:\s*(.+)$', stripped)
                    if m:
                        groups.add(m.group(1).strip().strip('"\''))
                    elif '{' in stripped:
                        # Flow style: "  - {name: GroupName, type: ...}"
                        m2 = re.search(r'\{[^}]*name:\s*([^,}]+)', stripped)
                        if m2:
                            groups.add(m2.group(1).strip().strip('"\''))
                    elif re.match(r'^\S', stripped) and not stripped.startswith('#') and not stripped.startswith('-'):
                        # 回到頂層 key（非縮排行），離開 proxy-groups 區段
                        break
    except Exception:
        pass
    return groups


def detect_current_config():
    """透過 API proxy groups 匹配判斷當前使用的 config。

    對每個 config 檔案提取其 proxy-group 名稱，
    與 API /proxies 回傳的 groups 做交集比對，
    重疊最多的即為當前 config。
    """
    import urllib.request, json

    try:
        req = urllib.request.Request(
            f'{API_BASE}/proxies',
            headers={'Authorization': f'Bearer {API_SECRET}'}
        )
        data = json.loads(urllib.request.urlopen(req, timeout=3).read())
        api_groups = set(data.get('proxies', {}).keys())
    except Exception:
        return 'unknown'

    if not api_groups:
        return 'unknown'

    all_configs = get_all_configs()
    if not all_configs:
        return 'unknown'

    best_match = 'unknown'
    best_overlap = 0

    for config_name in all_configs:
        filepath = os.path.join(ICLOUD_CONFIG_DIR, config_name + '.yaml')
        config_groups = get_config_groups(filepath)
        if not config_groups:
            continue

        overlap = len(config_groups & api_groups)
        if overlap > best_overlap:
            best_overlap = overlap
            best_match = config_name

    return best_match if best_overlap > 0 else 'unknown'


# ═══════════════════════════════════════════════════════════════
#  AX HELPERS
# ═══════════════════════════════════════════════════════════════

def ax_val(elem, attr):
    code, val = AX.AXUIElementCopyAttributeValue(elem, attr, None)
    return val

def ax_role(elem):
    return ax_val(elem, 'AXRole') or ''

def ax_children(elem):
    return ax_val(elem, 'AXChildren') or []

def ax_label(elem):
    for attr in ('AXDescription', 'AXValue', 'AXTitle'):
        val = ax_val(elem, attr)
        if val and isinstance(val, str) and val.strip():
            return val.strip()
    return ''

def ax_press(elem):
    return AX.AXUIElementPerformAction(elem, 'AXPress')

def get_stash_pid():
    r = subprocess.run(['pgrep', '-x', 'Stash'], capture_output=True, text=True)
    return int(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else None


def get_stash_window():
    """取得 Stash 的主窗口（多策略 fallback）。

    Stash（SwiftUI app）的 AXUIElementCreateApplication(pid).AXWindows
    可能返回空陣列，因此需要多種策略：

    1. AXFocusedWindow — 最可靠，只要 Stash 有 focus
    2. AXWindows — 原始方式（某些 app 可用）
    3. Activate + retry — 先把 Stash 帶到前台再試
    4. System-wide AXFocusedApplication — 全域搜尋
    """
    pid = get_stash_pid()
    if pid is None:
        raise RuntimeError("Stash is not running")

    app = AX.AXUIElementCreateApplication(pid)

    # Strategy 1: AXFocusedWindow（SwiftUI app 最可靠）
    focused = ax_val(app, 'AXFocusedWindow')
    if focused:
        return focused

    # Strategy 2: AXWindows（傳統 app）
    windows = ax_val(app, 'AXWindows') or []
    if windows:
        return windows[0]

    # Strategy 3: Activate Stash 再重試
    try:
        subprocess.run(['osascript', '-e', 'tell application "Stash" to activate'],
                       capture_output=True, timeout=5)
        time.sleep(2)

        # 重新取得 app element（有時需要重建）
        app = AX.AXUIElementCreateApplication(pid)
        focused = ax_val(app, 'AXFocusedWindow')
        if focused:
            return focused

        windows = ax_val(app, 'AXWindows') or []
        if windows:
            return windows[0]
    except Exception:
        pass

    # Strategy 4: System-wide element → AXFocusedApplication
    try:
        system_wide = AX.AXUIElementCreateSystemWide()
        focused_app = ax_val(system_wide, 'AXFocusedApplication')
        if focused_app:
            # 確認是 Stash
            err, focused_pid = AX.AXUIElementGetPid(focused_app, None)
            if err == 0 and focused_pid == pid:
                focused_win = ax_val(focused_app, 'AXFocusedWindow')
                if focused_win:
                    return focused_win
    except Exception:
        pass

    # 診斷資訊
    app = AX.AXUIElementCreateApplication(pid)
    role = ax_val(app, 'AXRole') or '(unknown)'
    title = ax_val(app, 'AXTitle') or '(none)'
    win_count = len(ax_val(app, 'AXWindows') or [])
    raise RuntimeError(
        f"No Stash windows found "
        f"(pid={pid}, role={role}, title={title}, AXWindows count={win_count})"
    )


# ═══════════════════════════════════════════════════════════════
#  UI NAVIGATION
# ═══════════════════════════════════════════════════════════════

def open_configs_page():
    """用 URL scheme 打開 Stash 的 Configs 管理頁面"""
    subprocess.run(
        ['open', 'stash://install-config?url=http%3A%2F%2Flocalhost%3A19877%2Fplaceholder.yaml'],
        capture_output=True
    )
    time.sleep(1.5)


def get_config_rows(root_elem):
    """在 Stash window 的 UI tree 中找出所有 config 列表行。

    使用動態 config 名稱列表匹配，不再硬編碼關鍵字。
    返回: [(label_text, ax_group_element, ax_static_text_element), ...]
    """
    rows = []

    # 動態取得所有 config 名稱作為匹配關鍵字
    all_configs = get_all_configs()
    config_keywords = [c.lower() for c in all_configs]
    # 通用回退關鍵字（當 iCloud 目錄不可用時）
    config_keywords.extend([
        'airport', 'updated', '@gmail', '@outlook', '@qq',
        'hours ago', 'days ago', 'minutes ago', 'ago',
        'last updated'
    ])

    def walk(elem):
        children = ax_children(elem)
        if not children:
            return

        role = ax_role(elem)
        if role == 'AXGroup':
            sts = [(c, ax_label(c)) for c in children if ax_role(c) == 'AXStaticText']
            if len(sts) == 1:
                st_elem, label = sts[0]
                kw = label.lower()
                if any(tag in kw for tag in config_keywords):
                    rows.append((label, elem, st_elem))

        for child in children:
            walk(child)

    walk(root_elem)
    return rows


def switch_to_config(target_keyword):
    """切換到匹配 target_keyword 的 config。

    在 Configs 頁面的 UI 中找到包含 target_keyword 的行並點擊。
    返回 True 如果成功找到並點擊。
    """
    pid = get_stash_pid()
    if pid is None:
        raise RuntimeError("Stash is not running")

    open_configs_page()

    win = get_stash_window()

    rows = get_config_rows(win)
    if not rows:
        raise RuntimeError("No config rows found in Stash window")

    kw = target_keyword.lower()
    for label, group, st_text in rows:
        if kw in label.lower():
            print(f"  Switching to: {label}")
            err = ax_press(st_text)
            if err == 0:
                return True
            else:
                raise RuntimeError(f"AXPress failed with code {err}")

    available = [l for l, _, _ in rows]
    raise ValueError(f"Config '{target_keyword}' not found. Available: {available}")


def close_config_window():
    """關閉 Stash Configs 對話窗口。

    嘗試兩種方式（由強到弱）：
    1. CGEvent 發送 Escape（不需權限，最可靠）
    2. osascript System Events keystroke（後備）
    """
    time.sleep(2)

    # 方式 1: CGEvent Post Escape（最可靠，不需輔助功能權限）
    try:
        import Quartz.CoreGraphics as CG
        event = CG.CGEventCreateKeyboardEvent(None, 53, True)  # 53 = kVK_Escape
        CG.CGEventSetFlags(event, 0)
        CG.CGEventPost(CG.kCGHIDEventTap, event)
        CG.CGEventRelease(event)
        time.sleep(0.5)
        return
    except Exception:
        pass

    # 方式 2: osascript System Events keystroke（後備）
    try:
        subprocess.run([
            'osascript', '-e',
            'tell application "System Events" to tell process "Stash" to keystroke (character id 27)'
        ], timeout=5, capture_output=True)
    except Exception:
        pass


# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════

def main():
    # --list: 列出所有可用 config
    if len(sys.argv) > 1 and sys.argv[1] == '--list':
        configs = get_all_configs()
        if configs:
            for c in configs:
                print(c)
        else:
            print("(no configs found)")
        return

    # --status: 顯示當前 config
    if len(sys.argv) > 1 and sys.argv[1] == '--status':
        current = detect_current_config()
        print(f"Current config: {current}")
        return

    # 切換到指定 config（或自動選擇另一個）
    target = sys.argv[1] if len(sys.argv) > 1 else None

    if target is None:
        # 自動：切到另一個 config
        current = detect_current_config()
        print(f"Current: {current}")
        all_configs = get_all_configs()

        # 找一個不是當前的 config
        target = None
        for c in all_configs:
            if c.lower() != current.lower():
                target = c
                break

        if target is None:
            print(f"ERROR: No alternative config found (current: {current}, available: {all_configs})")
            sys.exit(1)

    print(f"Switching config -> {target}")
    try:
        switch_to_config(target)
        time.sleep(3)

        # 關閉 Configs 對話窗口
        close_config_window()

        # 驗證
        new_current = detect_current_config()
        if target.lower() in new_current.lower():
            print(f"  Successfully switched to: {new_current}")
        else:
            print(f"  WARNING: API shows: {new_current} (might still be loading)")
    except Exception as e:
        print(f"  FAILED: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
