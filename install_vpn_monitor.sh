#!/bin/bash
# =============================================================
# VPN Monitor 安裝腳本
# 一鍵安裝 LaunchAgent，每 2 分鐘自動檢查 VPN 連線
# 自動生成配置檔案（~/.config/vpn_monitor/config）
# =============================================================

set -euo pipefail

SCRIPT_NAME="vpn_monitor.sh"
PLIST_NAME="com.user.vpn-monitor.plist"
CONFIG_SWITCHER="stash_switch_config.py"

# 來源路徑（當前目錄）
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_SCRIPT="$SRC_DIR/$SCRIPT_NAME"
SRC_PLIST="$SRC_DIR/$PLIST_NAME"
SRC_CONFIG_SWITCHER="$SRC_DIR/$CONFIG_SWITCHER"

# 配置檔案路徑
CONFIG_DIR="$HOME/.config/vpn_monitor"
CONFIG_FILE="$CONFIG_DIR/config"

# Stash plist 路徑（用於自動提取 API secret）
STASH_PLIST="$HOME/Library/Group Containers/group.ws.stash.app/Library/Preferences/group.ws.stash.app.plist"

# 安裝目標
INSTALL_DIR="$HOME/.local/bin"
INSTALL_SCRIPT="$INSTALL_DIR/$SCRIPT_NAME"
INSTALL_CONFIG_SWITCHER="$INSTALL_DIR/$CONFIG_SWITCHER"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
INSTALL_PLIST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"

echo "============================================"
echo "  VPN Monitor 安裝"
echo "============================================"
echo ""

# 檢查來源檔案
if [ ! -f "$SRC_SCRIPT" ]; then
    echo "❌ 找不到 $SCRIPT_NAME"
    echo "   請在腳本所在目錄執行此安裝程式"
    exit 1
fi

# 1. 建立目錄
echo "[1/8] 建立目錄..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR"
echo "    ✓ $INSTALL_DIR"
echo "    ✓ $LAUNCH_AGENTS_DIR"
echo "    ✓ $LOG_DIR"
echo "    ✓ $CONFIG_DIR"

# 2. 生成或更新配置檔案
echo ""
echo "[2/8] 生成配置檔案..."
if [ -f "$CONFIG_FILE" ]; then
    echo "    ✓ 配置檔案已存在: $CONFIG_FILE"
    echo "    （如需重新生成，請先刪除它）"
else
    # 自動提取 API secret
    API_SECRET=""
    if [ -f "$STASH_PLIST" ]; then
        API_SECRET=$(defaults read "$STASH_PLIST" stash-device-secret 2>/dev/null || true)
    fi

    if [ -z "$API_SECRET" ]; then
        echo "    ⚠ 無法自動從 Stash plist 提取 API secret"
        echo "      請手動編輯 $CONFIG_FILE 填入 API_SECRET"
        API_SECRET="YOUR_API_SECRET_HERE"
    else
        echo "    ✓ 已自動提取 API secret"
    fi

    # 偵測 Python 路徑（偏好已安裝 pyobjc 的環境）
    DETECTED_PYTHON=""
    for candidate in python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
        if command -v "$candidate" &>/dev/null; then
            if "$candidate" -c "import ApplicationServices" 2>/dev/null; then
                DETECTED_PYTHON="$candidate"
                break
            fi
        fi
    done
    [ -z "$DETECTED_PYTHON" ] && DETECTED_PYTHON="python3"

    cat > "$CONFIG_FILE" << EOF
# VPN Monitor Configuration
# 自動生成於 $(date '+%Y-%m-%d %H:%M:%S')
# 如需修改，直接編輯此檔案
# 所有值必須用雙引號括起，使用 \$HOME 而非 ~

# Stash API
API_BASE="http://127.0.0.1:9090"
API_SECRET="$API_SECRET"

# Python（需安裝 pyobjc-framework-ApplicationServices 和 pyobjc-framework-Quartz）
PYTHON_BIN="$DETECTED_PYTHON"

# Stash 路徑
STASH_CONFIG_DIR="$HOME/Library/Group Containers/group.ws.stash.app/stash"
ICLOUD_CONFIG_DIR="$HOME/Library/Mobile Documents/iCloud~ws~stash~icloud/Documents"

# 安裝與日誌路徑
INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="$LOG_DIR/vpn_monitor.log"
EOF
    chmod 600 "$CONFIG_FILE"
    echo "    ✓ 已生成: $CONFIG_FILE"
fi

# 3. 複製腳本
echo ""
echo "[3/8] 安裝監控腳本..."
cp "$SRC_SCRIPT" "$INSTALL_SCRIPT"
chmod +x "$INSTALL_SCRIPT"
echo "    ✓ $INSTALL_SCRIPT"

# 也複製 config switcher（vpn_monitor.sh 依賴它）
if [ -f "$SRC_CONFIG_SWITCHER" ]; then
    cp "$SRC_CONFIG_SWITCHER" "$INSTALL_CONFIG_SWITCHER"
    chmod +x "$INSTALL_CONFIG_SWITCHER"
    echo "    ✓ $INSTALL_CONFIG_SWITCHER"
else
    echo "    ⚠ $CONFIG_SWITCHER 不存在（config 切換功能不可用）"
fi

# 4. 生成 plist（替換佔位符）
echo ""
echo "[4/8] 生成 LaunchAgent plist..."
sed -e "s|__SCRIPT_PATH__|$INSTALL_SCRIPT|g" \
    -e "s|__HOME__|$HOME|g" \
    "$SRC_PLIST" > "$INSTALL_PLIST"
echo "    ✓ $INSTALL_PLIST"

# 5. 卸載舊版本（如果存在）
echo ""
echo "[5/8] 卸載舊版本（如果存在）..."
if launchctl list | grep -q "com.user.vpn-monitor" 2>/dev/null; then
    launchctl unload "$INSTALL_PLIST" 2>/dev/null || true
    echo "    ✓ 舊版本已卸載"
else
    echo "    - 無舊版本"
fi

# 6. 載入 LaunchAgent
echo ""
echo "[6/8] 載入 LaunchAgent..."
launchctl load "$INSTALL_PLIST"
echo "    ✓ LaunchAgent 已啟動"

# 7. 驗證
echo ""
echo "[7/8] 驗證..."
if launchctl list | grep -q "com.user.vpn-monitor" 2>/dev/null; then
    echo "    ✓ VPN Monitor 正在運行（每 120 秒檢查一次）"
else
    echo "    ⚠️ LaunchAgent 可能未正確載入，請檢查"
fi

# 8. 驗證 config switcher
echo ""
echo "[8/8] 驗證 config switcher..."
if [ -x "$INSTALL_CONFIG_SWITCHER" ]; then
    echo "    ✓ stash_switch_config.py 已安裝"
else
    echo "    ⚠ config 切換功能不可用（僅節點切換有效）"
fi

echo ""
echo "============================================"
echo "  安裝完成！"
echo "============================================"
echo ""
echo "  監控腳本: $INSTALL_SCRIPT"
echo "  配置檔案: $CONFIG_FILE"
echo "  LaunchAgent: $INSTALL_PLIST"
echo "  日誌檔案: $LOG_DIR/vpn_monitor.log"
echo ""
echo "  常用指令:"
echo "    查看狀態:  $INSTALL_SCRIPT --status"
echo "    測試模式:  $INSTALL_SCRIPT --test"
echo "    查看日誌:  tail -f $LOG_DIR/vpn_monitor.log"
echo "    停止監控:  $INSTALL_SCRIPT --stop"
echo "    啟動監控:  $INSTALL_SCRIPT --start"
echo "    完全卸載:  $INSTALL_SCRIPT --uninstall"
echo ""
