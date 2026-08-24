#!/bin/bash
# =============================================================
# VPN Monitor for Stash (Clash-compatible API)
# 自動監控 VPN 連線，斷線時自動恢復
#
# 功能：
#   1. 連通性檢測（Ping 8.8.8.8 + HTTP 通過代理）
#   2. 斷線時先刷新 config（reload + 測速重連當前節點）
#   3. 仍斷線則測試所有節點延遲，按分數排序逐一切換並驗證連通性
#      偏好 JP/SG > TW > US > other non-HK > HK
#   4. 若所有非 HK 節點皆失敗，才嘗試 HK 節點（最後手段）
#   5. 若所有節點皆失敗，強制刷新訂閱（重新從機場拉節點列表）再重試
#   6. 若仍斷線，切換到備份 config（透過 AX API 自動點擊 Stash UI）
#   7. 在新 config 中重試節點切換
#   8. 完整日誌記錄 + macOS 系統通知
#
# 用法：
#   ./vpn_monitor.sh              # 正常監控
#   ./vpn_monitor.sh --test       # 測試模式（不切換節點，只報告）
#   ./vpn_monitor.sh --live-test  # 實戰測試（真正切換節點 + 刷新訂閱，事後恢復）
#   ./vpn_monitor.sh --status     # 顯示當前狀態
#   ./vpn_monitor.sh --report <period>  # 分析過去一段時間的日誌（e.g. 24h, 7d）
#   ./vpn_monitor.sh --update     # 用 git pull 更新腳本到最新版
#   ./vpn_monitor.sh --set-interval <秒數>  # 設定檢查間隔（e.g. 300 = 5 分鐘）
#   ./vpn_monitor.sh --change-config [<name>]  # 切換 config（無參數=自動換一個不同 config）
#   ./vpn_monitor.sh --switch-to-best-node    # 切換到最佳節點（JP/SG > TW > US > other non-HK > HK）
#   ./vpn_monitor.sh --stop       # 停止監控（卸載 LaunchAgent）
#   ./vpn_monitor.sh --start      # 啟動監控（載入 LaunchAgent）
#   ./vpn_monitor.sh --uninstall [--delete-logs]  # 卸載（預設保留日誌）
# =============================================================

set -uo pipefail

# ===================== 配置載入 =====================
# 從外部 config 檔案讀取本地設定（API secret、路徑等）
# 避免將敏感資訊硬編碼到腳本中

VPN_MONITOR_CONFIG="${VPN_MONITOR_CONFIG:-$HOME/.config/vpn_monitor/config}"
if [ -f "$VPN_MONITOR_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$VPN_MONITOR_CONFIG"
else
    echo "錯誤: 找不到配置檔案 $VPN_MONITOR_CONFIG" >&2
    echo "請執行 install_vpn_monitor.sh 自動生成，或參考 config.example 手動建立" >&2
    exit 1
fi

# ===================== 配置區（預設值） =====================

# Stash API
API_BASE="${API_BASE:-http://127.0.0.1:9090}"
PROXY_PORT="${PROXY_PORT:-7890}"

# 預設路由 group（僅作 fallback，實際透過 /rules API 動態檢測）
SELECTOR_GROUP="${SELECTOR_GROUP:-SsdAirport}"

# Runtime/config/report scripts live next to this executable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SCRIPT="$SCRIPT_DIR/vpn_runtime.sh"
CONFIG_SWITCHER="$SCRIPT_DIR/stash_switch_config.py"
REPORT_SCRIPT="$SCRIPT_DIR/vpn_report.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Git repo 路徑（用於版本檢測與 --update）
# 若未設定，自動嘗試 SCRIPT_DIR；若已從 repo 複製到 ~/.local/bin 則需手動設定
MONITOR_REPO="${MONITOR_REPO:-}"
STASH_CONFIG_DIR="${STASH_CONFIG_DIR:-$HOME/Library/Group Containers/group.ws.stash.app/stash}"
STASH_CONFIG="$STASH_CONFIG_DIR/config.yaml"

# 日誌
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/vpn_monitor.log}"
LOG_RETENTION_DAYS=30

# 連通性檢測
PING_TARGET="8.8.8.8"
PING_COUNT=5
PING_TIMEOUT=3        # 每包超時（秒）
HTTP_URL="http://www.gstatic.com/generate_204"
HTTP_TIMEOUT=10       # 秒
DELAY_TEST_URL="http://www.gstatic.com/generate_204"
DELAY_TIMEOUT=5000    # 毫秒

# Retry / interval constants (shared across program)
RETRY_MAX=5
RETRY_INTERVAL=3

# LaunchAgent 檢查間隔（秒），可透過 --set-interval 修改
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"

# First-update migration: an old installed updater does not know about the newly
# added runtime file. After pulling/copying this new entrypoint, use the repo copy
# until a later --update/install places vpn_runtime.sh beside the executable.
if [ ! -f "$RUNTIME_SCRIPT" ] && [ -n "$MONITOR_REPO" ] && [ -f "$MONITOR_REPO/vpn_runtime.sh" ]; then
    RUNTIME_SCRIPT="$MONITOR_REPO/vpn_runtime.sh"
fi
if [ ! -f "$RUNTIME_SCRIPT" ]; then
    echo "錯誤: 找不到 runtime module $RUNTIME_SCRIPT" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "$RUNTIME_SCRIPT"

# ===================== 命令模式 =====================

cmd_monitor() {
    rotate_log
    log "=== VPN Monitor 定期檢查 ==="

    # 檢查 API 是否可用
    if ! check_api; then
        log "ERROR: Stash API 無法連接（Stash 可能未運行）"
        notify "VPN Monitor" "❌ Stash API 無法連接"
        log "---"
        return 1
    fi

    # 檢查連通性
    local status
    status=$(check_connectivity)

    case "$status" in
        ok)
            log "狀態: 正常（Ping + HTTP 均正常）"
            ;;
        http_only)
            log "狀態: HTTP 正常，Ping 失敗（可接受）"
            ;;
        ping_only|fail)
            local reason
            if [ "$status" = "ping_only" ]; then
                reason="Ping 正常，HTTP 代理失敗"
            else
                reason="全部檢測失敗"
            fi
            log "狀態: ${reason} — 將重試 ${RETRY_MAX} 次再確認..."

            # 重試確認（避免因短暫波動誤觸發整個恢復流程）
            local retry=0 final_status=$status
            while [ $retry -lt $RETRY_MAX ]; do
                sleep $RETRY_INTERVAL
                final_status=$(check_connectivity)
                case "$final_status" in
                    ok|http_only)
                        log "  重試 #$((retry+1)): 已恢復 ✓"
                        break
                        ;;
                esac
                retry=$((retry + 1))
            done

            if [ "$final_status" = "ping_only" ] || [ "$final_status" = "fail" ]; then
                log "  ${RETRY_MAX} 次重試後仍失敗，啟動恢復流程..."
                recover
            fi
            ;;
    esac

    log "---"
}

cmd_test() {
    echo "========================================="
    echo " VPN Monitor — 測試模式"
    echo "========================================="
    echo ""

    # API 檢查
    echo "[1] Stash API 連接測試"
    if check_api; then
        echo "    ✓ API 可連接"
    else
        echo "    ✗ API 無法連接（Stash 未運行？）"
        return 1
    fi

    # 當前節點
    echo ""
    echo "[2] 當前節點"
    local routing_group
    routing_group=$(get_routing_group)
    local current
    current=$(get_current_node)
    echo "    路由 group: ${routing_group}（動態檢測）"
    echo "    當前節點: $current"

    # 連通性（使用與定期監控相同的 check_connectivity 函數）
    echo ""
    echo "[3] 連通性檢測"
    local test_status
    test_status=$(check_connectivity)
    case "$test_status" in
        ok)         echo "    Ping $PING_TARGET: ✓" ; echo "    HTTP 通過代理: ✓" ; echo "    結果: 正常 ✓" ;;
        http_only)  echo "    Ping $PING_TARGET: ✗" ; echo "    HTTP 通過代理: ✓" ; echo "    結果: HTTP 正常（Ping 失敗，可接受）" ;;
        ping_only)  echo "    Ping $PING_TARGET: ✓" ; echo "    HTTP 通過代理: ✗" ; echo "    結果: ⚠ VPN 代理可能斷線" ;;
        fail)       echo "    Ping $PING_TARGET: ✗" ; echo "    HTTP 通過代理: ✗" ; echo "    結果: ❌ 完全斷線" ;;
    esac

    # 統一節點測速（JP/SG > TW > US > other non-HK > HK）
    echo ""
    echo "[4] 節點測速（JP/SG > TW > US > other non-HK > HK）"
    echo "    -------------------------------------------"

    local best_node=""
    local best_score=999999

    while IFS= read -r node; do
        [ -z "$node" ] && continue

        case "$node" in
            *剩余流量*|*距离下次*|*套餐到期*|*有超时*|*超时看*|*推荐夸克*|*邮箱*|*官网*|*老版Clash*|*使用文档*|*IOS继续*|*看文档*) continue ;;
        esac

        local delay
        delay=$(test_node_delay "$node")

        if ! echo "$delay" | grep -qE '^[0-9]+$'; then
            delay=0
        fi

        # Strict priority tiers: JP/SG(0) > TW(1) > US(2) > other(3) > HK(9)
        local tier
        tier=$(node_priority_tier "$node")
        local score=$((tier * 100000 + delay))
        local tag=""
        case "$tier" in
            0) tag="★" ;;
        esac

        if [ "$delay" -gt 0 ] 2>/dev/null; then
            printf "    %s: %dms (評分: %d) %s\n" "$node" "$delay" "$score" "$tag"
            if [ "$score" -lt "$best_score" ] 2>/dev/null; then
                best_score=$score
                best_node="$node"
            fi
        else
            printf "    %s: 無法連接 ✗\n" "$node"
        fi
    done < <(get_proxy_nodes)

    echo "    -------------------------------------------"
    if [ -n "${best_node}" ]; then
        echo "    → 最佳節點: ${best_node}（評分: ${best_score}）"
    else
        echo "    → 沒有可用的節點"
    fi

    echo ""
    echo "（測試模式不會執行任何切換操作）"
}

cmd_live_test() {
    echo "========================================="
    echo " VPN Monitor — 實戰測試（3 項測試）"
    echo "========================================="
    echo ""
    echo "⚠️  警告：此模式會真正切換節點、刷新訂閱、切換 config！"
    echo "    測試完成後會恢復原始狀態。"
    echo ""
    echo "  Test 1: 節點切換 + 連線驗證"
    echo "  Test 2: 強制刷新訂閱 + 驗證"
    echo "  Test 3: Config 切換 + 驗證 API"
    echo ""

    # ── 檢查前置條件 ──
    if ! check_api; then
        echo "✗ Stash API 無法連接，無法執行實戰測試"
        return 1
    fi
    echo "[前置] Stash API: ✓"

    # ── 動態檢測路由 group 和原始狀態（適用任何 config） ──
    local routing_group
    routing_group=$(get_routing_group)
    echo "[前置] 路由 group: ${routing_group}"

    local original_node
    original_node=$(get_current_node)
    echo "[前置] 原始節點: ${original_node:-（空）}"

    local original_config=""
    if [ -f "$CONFIG_SWITCHER" ] && has_python; then
        original_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
        echo "[前置] 原始配置: ${original_config:-unknown}"
    fi

    local overall_pass=true
    local passed=0
    local failed=0

    # ════════════════════════════════════════════
    # Test 1: 節點切換（使用動態檢測的路由 group）
    # ════════════════════════════════════════════
    echo ""
    echo "─────────────────────────────────────────"
    echo " [TEST 1] 切換到最佳非 HK 節點 + 驗證連線"
    echo "─────────────────────────────────────────"

    local encoded_group
    encoded_group=$(urlencode "$routing_group")

    # 使用 switch_to_best_node（與恢復流程相同策略，測試真實路徑）
    # 內部含節點名驗證 + 連通性重試驗證
    echo "  使用 switch_to_best_node 切換到最佳節點（與恢復流程相同）..."
    if switch_to_best_node; then
        echo "  → TEST 1 PASSED"
        passed=$((passed + 1))
    else
        echo "  → TEST 1 FAILED"
        failed=$((failed + 1))
        overall_pass=false
    fi

    # ── 恢復原始節點 ──
    echo ""
    if [ -z "$original_node" ]; then
        echo "  [恢復] ⚠ 原始節點為空，跳過節點恢復"
    else
        echo "  [恢復] 切回原始節點: ${original_node}（帶重試）..."
        switch_node "$original_node" 5

        # 驗證恢復
        local restored_node
        restored_node=$(get_current_node)
        if [ "$restored_node" = "$original_node" ]; then
            echo "  [恢復] ✓ 已回到原始節點: ${restored_node}"
        else
            echo "  [恢復] ⚠ 當前節點為「${restored_node:-empty}」，未正確恢復"
            overall_pass=false
        fi
    fi

    # ════════════════════════════════════════════
    # Test 2: 訂閱刷新
    # ════════════════════════════════════════════
    echo ""
    echo "─────────────────────────────────────────"
    echo " [TEST 2] 強制刷新訂閱 + 驗證節點可用"
    echo "─────────────────────────────────────────"

    local nodes_before
    nodes_before=$(get_proxy_nodes | wc -l | tr -d ' ')
    echo "  刷新前節點數: ${nodes_before}"

    local mtime_before=""
    if [ -f "$STASH_CONFIG" ]; then
        mtime_before=$(stat -f %m "$STASH_CONFIG" 2>/dev/null || echo "0")
    fi

    echo "  正在觸發訂閱刷新（PUT /configs）..."
    api_put "/configs" '{"path":"","payload":""}' >/dev/null 2>&1
    echo "  等待刷新完成（15 秒）..."
    sleep 15

    if ! check_api; then
        echo "  ✗ 刷新後 API 無回應"
        echo "  → TEST 2 FAILED"
        failed=$((failed + 1))
        overall_pass=false
    else
        echo "  API: ✓ 仍可用"

        if [ -f "$STASH_CONFIG" ] && [ -n "$mtime_before" ]; then
            local mtime_after
            mtime_after=$(stat -f %m "$STASH_CONFIG" 2>/dev/null || echo "0")
            if [ "$mtime_after" != "$mtime_before" ]; then
                echo "  Config 修改時間: 已變更 ✓（刷新生效）"
            else
                echo "  Config 修改時間: 未變更 ⚠（可能無新內容）"
            fi
        fi

        local nodes_after
        nodes_after=$(get_proxy_nodes | wc -l | tr -d ' ')
        echo "  刷新後節點數: ${nodes_after}"

        local status2
        status2=$(check_connectivity)
        if ! is_down "$status2"; then
            echo "  連通性: ✓（${status2}）"
            echo "  → TEST 2 PASSED"
            passed=$((passed + 1))
        else
            echo "  連通性: ✗（${status2}）"
            echo "  → TEST 2 FAILED"
            failed=$((failed + 1))
            overall_pass=false
        fi
    fi

    # ── 確保節點恢復 ──
    sleep 2
    routing_group=$(get_routing_group)
    encoded_group=$(urlencode "$routing_group")
    local mid_node
    mid_node=$(get_current_node)
    if [ "$mid_node" != "$original_node" ] && [ -n "$original_node" ]; then
        echo ""
        echo "  [恢復] 節點變更為「${mid_node}」，切回「${original_node}」"
        switch_node "$original_node" 5
    fi

    # ════════════════════════════════════════════
    # Test 3: Config 切換（動態選擇不同的 config）
    # ════════════════════════════════════════════
    echo ""
    echo "─────────────────────────────────────────"
    echo " [TEST 3] Config 切換 + 驗證 API"
    echo "─────────────────────────────────────────"

    if [ ! -f "$CONFIG_SWITCHER" ]; then
        echo "  ✗ stash_switch_config.py 不存在，跳過"
        echo "  → TEST 3 SKIPPED"
    elif ! has_python; then
        echo "  ✗ Python 環境不存在（command -v 失敗），跳過"
        echo "  → TEST 3 SKIPPED"
    else
        # 動態檢測當前 config
        local test3_original_config
        test3_original_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
        echo "  當前 config: ${test3_original_config:-unknown}"

        # 動態取得所有可用 config
        local all_configs
        all_configs=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --list 2>/dev/null)
        echo "  可用 config: $(echo "$all_configs" | tr '\n' ' ')"

        if [ -z "$test3_original_config" ] || [ "$test3_original_config" = "unknown" ]; then
            echo "  ✗ 無法檢測當前 config"
            echo "  → TEST 3 FAILED"
            failed=$((failed + 1))
            overall_pass=false
        elif [ -z "$all_configs" ]; then
            echo "  ✗ 無法取得 config 列表"
            echo "  → TEST 3 FAILED"
            failed=$((failed + 1))
            overall_pass=false
        else
            # 從列表中找一個不同的 config 作為目標
            local target_config=""
            while IFS= read -r cfg; do
                [ -z "$cfg" ] && continue
                if [ "$cfg" != "$test3_original_config" ]; then
                    target_config="$cfg"
                    break
                fi
            done <<< "$all_configs"

            if [ -z "$target_config" ]; then
                echo "  ✗ 沒有其他可切換的 config"
                echo "  → TEST 3 SKIPPED（只有一個 config）"
            else
                echo "  目標 config: ${target_config}"

                # 執行切換（使用共用函數）
                echo "  正在切換到 ${target_config}..."
                if switch_config "$target_config"; then
                    # 驗證 config 是否切換
                    local new_config
                    new_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
                    if [ "$new_config" = "$target_config" ]; then
                        echo "  Config 切換確認: ✓（當前: ${new_config}）"
                    else
                        echo "  Config 切換確認: ⚠ API 顯示「${new_config}」（目標: ${target_config}）"
                    fi

                    # 驗證連通性
                    sleep 3
                    local status3
                    status3=$(check_connectivity)
                    if ! is_down "$status3"; then
                        echo "  連通性: ✓（${status3}）"
                        echo "  → TEST 3 PASSED"
                        passed=$((passed + 1))
                    else
                        echo "  連通性: ✗（${status3}，可能新 config 需要手動選節點）"
                        echo "  → TEST 3 PARTIAL（切換成功但連線需手動）"
                        passed=$((passed + 1))
                    fi

                    # ── 恢復原始 config ──
                    echo ""
                    echo "  [恢復] 切回原始 config: ${test3_original_config}"
                    if switch_config "$test3_original_config"; then
                        echo "  [恢復] Config ✓"
                    else
                        echo "  [恢復] ⚠ 切換回原始 config 失敗"
                        echo "  → TEST 3 FAILED（未恢復到原始配置）"
                        if [ $passed -gt 0 ] 2>/dev/null; then
                            passed=$((passed - 1))
                        fi
                        failed=$((failed + 1))
                        overall_pass=false
                    fi
                else
                    echo "  ✗ Config 切換失敗"
                    echo "  → TEST 3 FAILED"
                    failed=$((failed + 1))
                    overall_pass=false
                fi

                # 恢復節點（config 切換後 group 可能變化）
                if [ -n "$original_node" ]; then
                    switch_node "$original_node" 5

                    local restored_node
                    restored_node=$(get_current_node)
                    if [ "$restored_node" = "$original_node" ]; then
                        echo "  [恢復] 節點 ✓（${restored_node}）"
                    elif [ -z "$restored_node" ]; then
                        echo "  [恢復] 節點 ⚠ 為空（可能配置不匹配）"
                    else
                        echo "  [恢復] 節點 ⚠「${restored_node}」≠ 目標「${original_node}」"
                    fi
                fi
            fi
        fi
    fi

    # ════════════════════════════════════════════
    # 最終驗證
    # ════════════════════════════════════════════
    echo ""
    echo "─────────────────────────────────────────"
    echo " 最終狀態驗證"
    echo "─────────────────────────────────────────"

    local final_group final_node final_status
    final_group=$(get_routing_group)
    final_node=$(get_current_node)
    final_status=$(check_connectivity)

    echo "  路由 group: ${final_group}"
    echo "  當前節點: ${final_node}"
    echo "  連通性: ${final_status}"

    if [ -f "$CONFIG_SWITCHER" ] && has_python; then
        local final_config
        final_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
        echo "  當前配置: ${final_config:-unknown}"
    fi

    # 總結
    echo ""
    echo "========================================="
    echo " 測試結果總結"
    echo "========================================="
    echo "  PASS: ${passed}"
    echo "  FAIL: ${failed}"

    if $overall_pass; then
        echo "  狀態: ✅ 全部通過"
    else
        echo "  狀態: ❌ 有 ${failed} 項失敗"
    fi
    echo ""
}

cmd_report() {
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
    local report_script="$REPORT_SCRIPT"
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
}

cmd_status() {
    echo "=== VPN 狀態 ==="

    if ! check_api; then
        echo "Stash API: ✗ 無法連接"
        return 1
    fi
    echo "Stash API: ✓ 正常"

    local routing_group
    routing_group=$(get_routing_group)
    echo "路由 group: ${routing_group}（動態檢測）"

    local current
    current=$(get_current_node)
    echo "當前節點: $current"

    # 顯示當前 config（如果 config switcher 可用）
    if [ -f "$CONFIG_SWITCHER" ] && has_python; then
        local current_config
        current_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
        echo "當前配置: ${current_config:-unknown}"
    fi

    local status
    status=$(check_connectivity)
    case "$status" in
        ok)         echo "連通性: ✓ 正常" ;;
        http_only)  echo "連通性: ~ HTTP 正常，Ping 失敗" ;;
        ping_only)  echo "連通性: ✗ HTTP 代理失敗" ;;
        fail)       echo "連通性: ✗ 全部失敗" ;;
    esac

    # 腳本版本資訊
    echo ""
    echo "=== 腳本版本 ==="
    local script_mtime
    script_mtime=$(stat -f "%Sm" "$0" 2>/dev/null || echo "unknown")
    echo "檔案修改時間: ${script_mtime}"

    local repo
    repo=$(detect_repo 2>/dev/null)
    if [ -n "$repo" ]; then
        local local_hash remote_hash
        local_hash=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
        local_subject=$(git -C "$repo" log -1 --format=%s 2>/dev/null)
        echo "本地 commit:   ${local_hash:-unknown} — ${local_subject:-}"

        # 檢查遠端是否有更新（帶 timeout 避免卡住）
        git -C "$repo" fetch origin --quiet 2>/dev/null
        remote_hash=$(git -C "$repo" rev-parse --short origin/main 2>/dev/null)
        if [ -n "$remote_hash" ] && [ -n "$local_hash" ]; then
            if [ "$remote_hash" = "$local_hash" ]; then
                echo "遠端狀態:     ✓ 已是最新版"
            else
                local behind
                behind=$(git -C "$repo" rev-list --count "$local_hash..origin/main" 2>/dev/null || echo "?")
                echo "遠端狀態:     ⚠ 落後 ${behind} 個 commit（最新: ${remote_hash}）"
                echo "執行更新:     vpn_monitor.sh --update"
            fi
        fi
    else
        echo "Git repo:     ✗ 未偵測到（設定 MONITOR_REPO 或從 repo 目錄執行）"
    fi

    # LaunchAgent 狀態
    echo ""
    echo "=== LaunchAgent ==="
    local plist_file="$HOME/Library/LaunchAgents/com.user.vpn-monitor.plist"
    if [ -f "$plist_file" ]; then
        if launchctl print "gui/$(id -u)/com.user.vpn-monitor" >/dev/null 2>&1; then
            local interval_min=$(( CHECK_INTERVAL >= 60 ? CHECK_INTERVAL / 60 : CHECK_INTERVAL ))
            local interval_unit=$([ $CHECK_INTERVAL -ge 60 ] && echo "分鐘" || echo "秒")
            echo "狀態: ✓ 已載入（每 ${interval_min} ${interval_unit}檢查）"
        else
            echo "狀態: ⚠ plist 存在但未載入"
        fi
    else
        echo "狀態: ✗ 未安裝"
    fi

    # 最近 10 條日誌
    echo ""
    echo "=== 最近日誌 ==="
    if [ -f "$LOG_FILE" ]; then
        tail -10 "$LOG_FILE"
    else
        echo "（無日誌）"
    fi
}

cmd_update() {
    echo "========================================="
    echo " 更新 VPN Monitor 腳本"
    echo "========================================="
    echo ""

    local repo
    repo=$(detect_repo 2>/dev/null)
    if [ -z "$repo" ]; then
        echo "✗ 無法偵測 git repo"
        echo "  請設定 MONITOR_REPO 環境變數，或直接從 repo 目錄執行"
        return 1
    fi
    echo "Git repo: ${repo}"
    echo ""

    # git pull
    echo "[1/3] 拉取最新代碼..."
    local pull_out pull_rc
    pull_out=$(git -C "$repo" pull 2>&1)
    pull_rc=$?
    echo "$pull_out" | sed 's/^/  /'

    if [ $pull_rc -ne 0 ]; then
        echo ""
        echo "✗ git pull 失敗，請檢查網路或 repo 狀態"
        return 1
    fi

    # 取得最新 commit
    local new_hash new_subject
    new_hash=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
    new_subject=$(git -C "$repo" log -1 --format=%s 2>/dev/null)
    echo ""
    echo "[2/3] 複製腳本到 ~/.local/bin/..."

    local dest_dir="${INSTALL_DIR:-$HOME/.local/bin}"
    local updated=0
    local runtime_stage="$dest_dir/.vpn_runtime.sh.new.$$"
    local monitor_stage="$dest_dir/.vpn_monitor.sh.new.$$"

    # Stage the required pair first. Copy failures leave both live files intact.
    rm -f "$runtime_stage" "$monitor_stage"
    if ! cp "$repo/vpn_runtime.sh" "$runtime_stage"; then
        echo "✗ 更新失敗: 無法準備 vpn_runtime.sh"
        rm -f "$runtime_stage" "$monitor_stage"
        return 1
    fi
    if ! cp "$repo/vpn_monitor.sh" "$monitor_stage"; then
        echo "✗ 更新失敗: 無法準備 vpn_monitor.sh"
        rm -f "$runtime_stage" "$monitor_stage"
        return 1
    fi

    # Preserve the existing optional-copy behavior for these independent tools.
    cp "$repo/stash_switch_config.py" "$dest_dir/stash_switch_config.py" && updated=$((updated + 1))
    cp "$repo/vpn_report.py" "$dest_dir/vpn_report.py" && updated=$((updated + 1))

    # Both required files are now staged in the destination directory. Same-dir
    # renames avoid the realistic partial-copy failures that caused version skew.
    if ! mv "$runtime_stage" "$dest_dir/vpn_runtime.sh"; then
        echo "✗ 更新失敗: 無法安裝 vpn_runtime.sh"
        rm -f "$runtime_stage" "$monitor_stage"
        return 1
    fi
    updated=$((updated + 1))
    if ! mv "$monitor_stage" "$dest_dir/vpn_monitor.sh"; then
        echo "✗ 更新失敗: 無法安裝 vpn_monitor.sh"
        rm -f "$monitor_stage"
        return 1
    fi
    updated=$((updated + 1))

    echo "  已更新 ${updated} 個檔案"
    echo ""
    echo "[3/3] 更新完成！"
    echo ""
    echo "  新版本: ${new_hash:-unknown} — ${new_subject:-}"
    echo "  檔案時間: $(stat -f '%Sm' "$dest_dir/vpn_monitor.sh" 2>/dev/null)"
    echo ""
    echo "  LaunchAgent 將在下個週期（最多 120 秒）自動使用新代碼"
    echo "  無需重啟服務 — 每次運行時都會重新讀取腳本檔案"
}

cmd_set_interval() {
    local new_interval="$1"

    # 驗證參數
    if [ -z "$new_interval" ]; then
        echo "用法: vpn_monitor.sh --set-interval <秒數>"
        echo "  目前設定: ${CHECK_INTERVAL} 秒（$( (($CHECK_INTERVAL >= 60)) && echo "$((CHECK_INTERVAL/60)) 分鐘" || echo "${CHECK_INTERVAL} 秒")）"
        echo ""
        echo "範例:"
        echo "  vpn_monitor.sh --set-interval 120    # 每 2 分鐘"
        echo "  vpn_monitor.sh --set-interval 300    # 每 5 分鐘（預設）"
        echo "  vpn_monitor.sh --set-interval 600    # 每 10 分鐘"
        return 1
    fi

    if ! echo "$new_interval" | grep -Eq '^[0-9]+$'; then
        echo "錯誤: 間隔必須是正整數（秒）"
        return 1
    fi

    if [ "$new_interval" -lt 30 ]; then
        echo "錯誤: 間隔不能少於 30 秒（目前: ${CHECK_INTERVAL}）"
        return 1
    fi

    # 1. 更新 config 檔案
    local config_file="${VPN_MONITOR_CONFIG:-$HOME/.config/vpn_monitor/config}"
    if [ ! -f "$config_file" ]; then
        echo "錯誤: 找不到設定檔 $config_file"
        return 1
    fi

    echo "========================================="
    echo " 設定檢查間隔"
    echo "========================================="
    echo ""
    echo "[1/4] 更新設定檔: $config_file"

    # 更新或新增 CHECK_INTERVAL
    if grep -q '^CHECK_INTERVAL=' "$config_file" 2>/dev/null; then
        sed -i '' "s/^CHECK_INTERVAL=.*/CHECK_INTERVAL=\"$new_interval\"/" "$config_file"
    else
        echo "CHECK_INTERVAL=\"$new_interval\"" >> "$config_file"
    fi
    echo "  ✓ CHECK_INTERVAL = $new_interval （$( (($new_interval >= 60)) && echo "$((new_interval/60)) 分鐘" || echo "${new_interval} 秒")）"

    # 2. 重新載入 config（讓目前程序也能讀到新值）
    set -a; source "$config_file"; set +a

    # 3. 重生 plist
    echo ""
    echo "[2/4] 重生 LaunchAgent plist..."

    local repo_dir
    repo_dir=$(detect_repo)
    local src_plist
    if [ -n "$repo_dir" ] && [ -f "$repo_dir/com.user.vpn-monitor.plist" ]; then
        src_plist="$repo_dir/com.user.vpn-monitor.plist"
    else
        echo "  錯誤: 找不到 plist 模板（repo: $repo_dir）"
        return 1
    fi

    local install_plist="$HOME/Library/LaunchAgents/com.user.vpn-monitor.plist"
    sed -e "s|__SCRIPT_PATH__|$SCRIPT_DIR/vpn_monitor.sh|g" \
         -e "s|__HOME__|$HOME|g" \
         -e "s|__CHECK_INTERVAL__|$new_interval|g" \
         "$src_plist" > "$install_plist"

    if [ $? -eq 0 ]; then
        echo "  ✓ $install_plist"
    else
        echo "  ✗ 生成 plist 失敗"
        return 1
    fi

    # 4. 重載 LaunchAgent
    echo ""
    echo "[3/4] 重載 LaunchAgent..."
    launchctl bootout "gui/$(id -u)/com.user.vpn-monitor" 2>/dev/null || true
    sleep 1
    if launchctl bootstrap "gui/$(id -u)" "$install_plist" 2>&1; then
        echo "  ✓ LaunchAgent 已重載"
    else
        echo "  ✗ 重載失敗（請嘗試手動: launchctl bootstrap gui/$(id -u) $install_plist）"
        return 1
    fi

    # 5. 驗證
    echo ""
    echo "[4/4] 驗證..."
    sleep 2
    if launchctl list | grep -q com.user.vpn-monitor; then
        echo "  ✓ LaunchAgent 運行中"
    else
        echo "  ⚠ LaunchAgent 未出現在列表中（可能仍在啟動）"
    fi

    echo ""
    echo "========================================="
    echo " 完成！新的檢查間隔: $new_interval 秒"
    echo "========================================="
    echo ""
    echo "下次執行將在約 $((new_interval/60)) 分鐘後（或開機時立即執行）"
}

cmd_change_config() {
    local target_config="$1"

    echo "========================================="
    echo " 切換 Config"
    echo "========================================="
    echo ""

    # 檢查依賴（參數有無都需檢查）
    if [ ! -f "$CONFIG_SWITCHER" ]; then
        echo "✗ 錯誤: $CONFIG_SWITCHER 不存在"
        echo "  無法切換 config（config switcher 功能不可用）"
        return 1
    fi
    if ! has_python; then
        echo "✗ 錯誤: Python 不可用（$PYTHON_BIN）"
        echo "  請安裝 pyobjc: $PYTHON_BIN -m pip install pyobjc-framework-ApplicationServices pyobjc-framework-Quartz"
        return 1
    fi

    # 若未指定參數，自動選一個不同的 config
    if [ -z "$target_config" ]; then
        echo "未指定 config，自動選擇..."
        echo ""

        # 取得當前 config
        local auto_current
        auto_current=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
        echo "當前 config: ${auto_current:-unknown}"

        # 取得所有可用 config 並排除當前
        local all_configs
        local -a alternatives
        all_configs=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --list 2>/dev/null)
        alternatives=()
        while IFS= read -r c; do
            [ -n "$c" ] && [ "$c" != "$auto_current" ] && alternatives+=("$c")
        done <<< "$all_configs"

        if [ ${#alternatives[@]} -eq 0 ]; then
            echo "✗ 沒有其他 config 可切換"
            return 1
        fi

        # 若只有 1 個備選直接用，多個則隨機選
        if [ ${#alternatives[@]} -eq 1 ]; then
            target_config="${alternatives[0]}"
            echo "只有 1 個備選: ${target_config}"
        else
            local idx
            idx=$(( RANDOM % ${#alternatives[@]} ))
            target_config="${alternatives[$idx]}"
            echo "備選清單 (${#alternatives[@]} 個): ${alternatives[*]}"
            echo "隨機選取 → ${target_config}"
        fi
        echo ""
    fi

    # 檢查 Stash API
    if ! check_api; then
        echo "✗ 錯誤: Stash API 無回應（${API_BASE}）"
        echo "  請確認 Stash 正在執行"
        return 1
    fi

    # 顯示當前 config
    local current_config
    current_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
    echo "當前 config: ${current_config:-unknown}"
    echo "目標 config: ${target_config}"
    echo ""

    # 執行切換（switch_config 內含: 切換 + sleep 15 + restart_stash + check_api）
    log "=== 手動切換 config: ${target_config} ==="
    if switch_config "$target_config"; then
        echo "✓ Config 切換成功: ${target_config}"
        log "=== Config 切換完成: ${target_config} ==="

        # 顯示切換後狀態
        echo ""
        echo "--- 切換後狀態 ---"
        local new_config new_group new_node
        new_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
        new_group=$(get_routing_group)
        new_node=$(get_current_node)
        echo "  Config: ${new_config:-unknown}"
        echo "  路由 group: ${new_group}"
        echo "  當前節點: ${new_node:-unknown}"

        # 驗證連通性
        echo ""
        local cstatus
        cstatus=$(check_connectivity)
        case "$cstatus" in
            ok)         echo "  連通性: ✓ 正常" ;;
            http_only)   echo "  連通性: ~ HTTP 正常，Ping 失敗" ;;
            ping_only)   echo "  連通性: ✗ HTTP 代理失敗" ;;
            fail)        echo "  連通性: ✗ 全部失敗" ;;
        esac
        return 0
    else
        echo "✗ Config 切換失敗: ${target_config}"
        log "=== Config 切換失敗: ${target_config} ==="
        return 1
    fi
}

cmd_switch_to_best_node() {
    echo "========================================="
    echo " 切換到最佳節點"
    echo "========================================="
    echo ""

    # 檢查 Stash API
    if ! check_api; then
        echo "✗ 錯誤: Stash API 無回應（${API_BASE}）"
        echo "  請確認 Stash 正在執行"
        return 1
    fi

    # 顯示當前狀態
    local current_node current_config
    current_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
    current_node=$(get_current_node)
    local current_group
    current_group=$(get_routing_group)
    echo "當前 config: ${current_config:-unknown}"
    echo "路由 group: ${current_group}"
    echo "當前節點: ${current_node:-unknown}"
    echo ""

    echo ">>> 搜尋最佳節點（JP/SG > TW > US > other non-HK > HK）..."
    log "=== 手動切換到最佳節點 ==="
    if switch_to_best_node; then
        echo ""
        echo "✓ 已切換到最佳節點"
        local new_node
        new_node=$(get_current_node)
        echo "  新節點: ${new_node}"
        return 0
    fi

    echo ""
    echo "✗ 所有節點皆不可用"
    echo "  建議: 嘗試切換 config（vpn_monitor.sh --change-config <name>）或刷新訂閱"
    log "=== 切換到最佳節點失敗: 所有節點皆不可用 ==="
    return 1
}

cmd_stop() {
    echo "========================================="
    echo " 停止 VPN 監控"
    echo "========================================="
    echo ""

    local plist_file="$HOME/Library/LaunchAgents/com.user.vpn-monitor.plist"

    if [ ! -f "$plist_file" ]; then
        echo "  LaunchAgent 未安裝，無需停止"
        return 0
    fi

    if launchctl print "gui/$(id -u)/com.user.vpn-monitor" >/dev/null 2>&1; then
        launchctl unload "$plist_file" 2>/dev/null
        if launchctl print "gui/$(id -u)/com.user.vpn-monitor" >/dev/null 2>&1; then
            echo "  ✗ 停止失敗，請手動執行:"
            echo "    launchctl unload $plist_file"
            return 1
        else
            echo "  ✓ VPN 監控已停止"
            echo ""
            echo "  plist 檔案仍保留: $plist_file"
            echo "  重新啟動: $(basename "$0") --start"
        fi
    else
        echo "  VPN 監控目前未在運行"
    fi
}

cmd_start() {
    echo "========================================="
    echo " 啟動 VPN 監控"
    echo "========================================="
    echo ""

    local plist_file="$HOME/Library/LaunchAgents/com.user.vpn-monitor.plist"

    if [ ! -f "$plist_file" ]; then
        echo "  ✗ LaunchAgent 未安裝"
        echo "  請先執行安裝: bash install_vpn_monitor.sh"
        return 1
    fi

    if launchctl print "gui/$(id -u)/com.user.vpn-monitor" >/dev/null 2>&1; then
        echo "  VPN 監控已在運行中"
        return 0
    fi

    launchctl load "$plist_file" 2>/dev/null
    if launchctl print "gui/$(id -u)/com.user.vpn-monitor" >/dev/null 2>&1; then
        echo "  ✓ VPN 監控已啟動（每 120 秒檢查）"
    else
        echo "  ✗ 啟動失敗，請手動執行:"
        echo "    launchctl load $plist_file"
        return 1
    fi
}

cmd_uninstall() {
    echo "========================================="
    echo " 卸載 VPN 監控"
    echo "========================================="
    echo ""

    local plist_file="$HOME/Library/LaunchAgents/com.user.vpn-monitor.plist"
    local install_dir="${INSTALL_DIR:-$HOME/.local/bin}"
    local keep_logs=true

    # 處理 --delete-logs 參數
    if [ "${2:-}" = "--delete-logs" ]; then
        keep_logs=false
    fi

    # 1. 停止 LaunchAgent
    echo "[1/4] 停止 LaunchAgent..."
    if [ -f "$plist_file" ]; then
        launchctl unload "$plist_file" 2>/dev/null || true
        echo "    ✓ 已停止"
    else
        echo "    - LaunchAgent 未安裝"
    fi

    # 2. 移除 plist
    echo ""
    echo "[2/4] 移除 LaunchAgent plist..."
    if [ -f "$plist_file" ]; then
        rm -f "$plist_file"
        echo "    ✓ 已移除: $plist_file"
    else
        echo "    - 無需移除"
    fi

    # 3. 移除腳本
    echo ""
    echo "[3/4] 移除監控腳本..."
    local removed_files=0
    for f in vpn_monitor.sh vpn_runtime.sh stash_switch_config.py vpn_report.py; do
        if [ -f "$install_dir/$f" ]; then
            rm -f "$install_dir/$f"
            echo "    ✓ 已移除: $install_dir/$f"
            removed_files=$((removed_files + 1))
        fi
    done
    if [ $removed_files -eq 0 ]; then
        echo "    - 無需移除"
    fi

    # 4. 處理日誌
    echo ""
    echo "[4/4] 處理日誌..."
    if $keep_logs; then
        echo "    ✓ 日誌已保留:"
        echo "      $LOG_FILE"
        if [ -f "${LOG_FILE}.old" ]; then
            echo "      ${LOG_FILE}.old"
        fi
        # 列出保留的 dated 歸檔
        for f in "$LOG_FILE".????-??-??; do
            [ -e "$f" ] || continue
            echo "      $f"
        done
    else
        if [ -f "$LOG_FILE" ]; then
            rm -f "$LOG_FILE"
            echo "    ✓ 已刪除: $LOG_FILE"
        fi
        if [ -f "${LOG_FILE}.old" ]; then
            rm -f "${LOG_FILE}.old"
            echo "    ✓ 已刪除: ${LOG_FILE}.old"
        fi
        for f in "$LOG_FILE".????-??-??; do
            [ -e "$f" ] || continue
            rm -f "$f"
            echo "    ✓ 已刪除: $f"
        done
    fi

    echo ""
    echo "========================================="
    echo " 卸載完成！"
    echo "========================================="
    echo ""
    echo "  日誌: $($keep_logs && echo '已保留' || echo '已刪除')"
    echo "  重新安裝: bash install_vpn_monitor.sh"
    echo ""
}

# ===================== 入口 =====================

main() {
    case "${1:-}" in
        --test)               cmd_test ;;
        --live-test)          cmd_live_test ;;
        --status)             cmd_status ;;
        --report)             cmd_report "${2:-}" ;;
        --update)             cmd_update ;;
        --set-interval)       cmd_set_interval "${2:-}" ;;
        --change-config)       cmd_change_config "${2:-}" ;;
        --switch-to-best-node) cmd_switch_to_best_node ;;
        --stop)               cmd_stop ;;
        --start)              cmd_start ;;
        --uninstall)          cmd_uninstall "$@" ;;
        *)                    cmd_monitor ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
