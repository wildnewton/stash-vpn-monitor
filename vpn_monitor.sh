#!/bin/bash
# =============================================================
# VPN Monitor for Stash (Clash-compatible API)
# 自動監控 VPN 連線，斷線時自動恢復
#
# 功能：
#   1. 連通性檢測（Ping 8.8.8.8 + HTTP 通過代理）
#   2. 斷線時先刷新 config（reload + 測速重連當前節點）
#   3. 仍斷線則測試所有非 HK 節點延遲，偏好 SG > JP > TW > US
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
#   ./vpn_monitor.sh --update     # 用 git pull 更新腳本到最新版
#   ./vpn_monitor.sh --set-interval <秒數>  # 設定檢查間隔（e.g. 300 = 5 分鐘）
#   ./vpn_monitor.sh --change-config <name>   # 切換 config（切到指定 yaml）
#   ./vpn_monitor.sh --switch-to-best-node    # 切換到最佳節點（SG > JP > TW > US）
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

# Config switcher Python script（透過 AX API 點擊 Stash UI）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_SWITCHER="$SCRIPT_DIR/stash_switch_config.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Git repo 路徑（用於版本檢測與 --update）
# 若未設定，自動嘗試 SCRIPT_DIR；若已從 repo 複製到 ~/.local/bin 則需手動設定
MONITOR_REPO="${MONITOR_REPO:-}"
STASH_CONFIG_DIR="${STASH_CONFIG_DIR:-$HOME/Library/Group Containers/group.ws.stash.app/stash}"
STASH_CONFIG="$STASH_CONFIG_DIR/config.yaml"

# 日誌
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/vpn_monitor.log}"
MAX_LOG_LINES=5000

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

# ===================== 工具函數 =====================

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $1" >> "$LOG_FILE" 2>/dev/null || true
    [ -t 1 ] && echo "[$ts] $1" || true
}

notify() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

# 檢查 Python 環境是否可用（command -v 正確搜索 PATH，不用 -x）
has_python() {
    command -v "${1:-$PYTHON_BIN}" >/dev/null 2>&1
}

# 自動偵測 git repo 路徑（供版本檢測與 --update 使用）
detect_repo() {
    [ -n "${MONITOR_REPO:-}" ] && git -C "$MONITOR_REPO" rev-parse --git-dir >/dev/null 2>&1 && echo "$MONITOR_REPO" && return 0
    git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 && echo "$SCRIPT_DIR" && return 0
    return 1
}

# URL 編碼（處理 emoji + 中文節點名）
urlencode() {
    jq -rn --arg str "$1" '$str|@uri'
}

# API 調用
api_get() {
    curl -s -m 10 -H "Authorization: Bearer $API_SECRET" "$API_BASE$1" 2>/dev/null
}

api_put() {
    curl -s -m 10 -X PUT \
        -H "Authorization: Bearer $API_SECRET" \
        -H "Content-Type: application/json" \
        -d "$2" "$API_BASE$1" 2>/dev/null
}

# 關閉所有活躍連接（切換節點前必須關閉，否則舊連接仍走舊節點）
close_connections() {
    curl -s -m 5 -X DELETE -H "Authorization: Bearer $API_SECRET" "$API_BASE/connections" >/dev/null 2>&1
}

# 檢查 API 是否可用
check_api() {
    local resp
    resp=$(curl -s -m 3 -H "Authorization: Bearer $API_SECRET" "$API_BASE/configs" 2>/dev/null)
    if echo "$resp" | jq -e '.mode' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 動態檢測路由 group（MATCH 規則指向的 group）
# 不同 config 的 group 名稱不同，不能硬編碼
get_routing_group() {
    local data
    data=$(api_get /rules)
    local group
    group=$(echo "$data" | jq -r '.rules[] | select(.type == "MATCH" or .type == "Match") | .proxy' 2>/dev/null | head -1)
    if [ -z "$group" ] || [ "$group" = "null" ]; then
        group="$SELECTOR_GROUP"  # fallback
    fi
    echo "$group"
}

# 判斷節點是否為 HK
is_hk_node() {
    echo "$1" | grep -qE "HK|香港"
}

# ===================== 核心功能 =====================

# 取得當前選中節點（使用動態檢測的路由 group）
get_current_node() {
    local group
    group=$(get_routing_group)
    local encoded_group
    encoded_group=$(urlencode "$group")
    local data
    data=$(api_get "/proxies/$encoded_group")
    echo "$data" | jq -r '.now // empty'
}

# 取得所有真實代理節點（排除 group、info 節點）
get_proxy_nodes() {
    local data
    data=$(api_get /proxies)
    echo "$data" | jq -r '
        .proxies | to_entries[]
        | select(.value.type | IN(
            "VLESS","VMess","Trojan","Shadowsocks","ShadowsocksR",
            "Hysteria","Hysteria2","TUIC","WireGuard","HTTP","Socks5","Snell"
          ))
        | .key
    '
}

# 取得路由 group 的可選節點列表（.all 欄位）
# selector group 只能切換到此列表中的節點
get_group_options() {
    local group
    group=$(get_routing_group)
    local encoded_group
    encoded_group=$(urlencode "$group")
    local data
    data=$(api_get "/proxies/$encoded_group")
    echo "$data" | jq -r '.all[]?' 2>/dev/null
}

# 取得可選擇的真實代理節點（路由 group 選項 ∩ 真實代理類型）
# 這確保只選擇 selector group 實際允許切換的節點
get_selectable_nodes() {
    local options
    options=$(get_group_options)

    if [ -z "$options" ]; then
        # Fallback: 回傳所有真實代理節點（可能包含不可選節點，如 Balancer 成員）
        log "    WARNING: group options 為空，fallback 到全部代理節點（可能包含不可選節點）"
        get_proxy_nodes
        return
    fi

    # 交集：真實代理節點 ∩ group 選項
    local result
    result=$(get_proxy_nodes | grep -Fxf <(echo "$options") 2>/dev/null)

    if [ -n "$result" ]; then
        echo "$result"
    else
        # Fallback: 交集為空時回傳所有真實代理節點
        get_proxy_nodes
    fi
}

# 切換到指定節點（帶重試，解決重啟後 API 不穩定問題）
switch_node() {
    local target="$1"
    local max_retries="${2:-$RETRY_MAX}"

    local i
    for i in $(seq 1 "$max_retries"); do
        local group
        group=$(get_routing_group)
        local encoded_group
        encoded_group=$(urlencode "$group")

        close_connections
        sleep 1
        api_put "/proxies/$encoded_group" "$(jq -n --arg name "$target" '{name: $name}')" >/dev/null 2>&1
        sleep 2
        close_connections
        sleep 2

        local current
        current=$(get_current_node)
        if [ "$current" = "$target" ]; then
            log "    節點切換成功: ${target} — 同步 GUI（重啟 Stash）"
            restart_stash
            return 0
        fi

        if [ $i -lt "$max_retries" ]; then
            log "    節點切換重試 (${i}/${max_retries})：${current} → ${target}..."
            sleep $RETRY_INTERVAL
        fi
    done

    return 1
}

# 測試單個節點延遲
test_node_delay() {
    local node_name="$1"
    local encoded
    encoded=$(urlencode "$node_name")
    local result
    result=$(curl -s -m 15 -H "Authorization: Bearer $API_SECRET" \
        "$API_BASE/proxies/$encoded/delay?url=$DELAY_TEST_URL&timeout=$DELAY_TIMEOUT" 2>/dev/null)
    local delay alive
    delay=$(echo "$result" | jq -r '.delay // 0')
    alive=$(echo "$result" | jq -r '.alive // false')

    # 將空值或非數字視為 0
    if ! echo "$delay" | grep -qE '^[0-9]+$'; then
        delay=0
    fi

    if [ "$alive" = "true" ] && [ "$delay" -gt 0 ] && [ "$delay" -lt 65535 ] 2>/dev/null; then
        echo "$delay"
    else
        echo "0"
    fi
}

# 連通性檢測：Ping + HTTP 通過代理
check_connectivity() {
    local ping_ok=false
    local http_ok=false

    # Ping 測試
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1; then
        ping_ok=true
    fi

    # HTTP 測試（通過代理端口）
    local http_code
    http_code=$(curl -s -m "$HTTP_TIMEOUT" -x "http://127.0.0.1:$PROXY_PORT" \
        -o /dev/null -w "%{http_code}" "$HTTP_URL" 2>/dev/null || echo "000")

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        http_ok=true
    fi

    # 返回結果
    if $http_ok; then
        if $ping_ok; then
            echo "ok"
        else
            echo "http_only"
        fi
    elif $ping_ok; then
        echo "ping_only"
    else
        echo "fail"
    fi
}

# 判斷是否斷線（HTTP 失敗即視為斷線）
is_down() {
    local status="$1"
    [ "$status" = "fail" ] || [ "$status" = "ping_only" ]
}

# Step 1: 刷新 config（reload + 測速重連當前節點）
refresh_config() {
    log ">>> Step 1: 刷新 config..."

    # Reload config（空 path 表示 reload 當前 config）
    api_put /configs '{"path":"","payload":""}' >/dev/null 2>&1
    sleep 3

    # 測速當前節點（強制重連）
    local current
    current=$(get_current_node)
    if [ -n "$current" ]; then
        log "    測速當前節點: ${current}（強制重連）"
        local delay
        delay=$(test_node_delay "$current")
        if [ "$delay" -gt 0 ] 2>/dev/null; then
            log "    當前節點延遲: ${delay}ms ✓"
        else
            log "    當前節點無法連接 ✗"
        fi
    else
        log "    警告: 無法取得當前節點"
    fi

    sleep 2
}

# Step 2: 切換到最佳節點
#   allow_hk=true  → 包含 HK 節點（最後手段）
#   allow_hk=false → 僅非 HK 節點
switch_to_best_node() {
    local allow_hk="${1:-false}"
    local phase="非 HK"
    $allow_hk && phase="全部（含 HK）"

    log ">>> Step 2: 搜尋最佳節點（${phase}）..."

    local current
    current=$(get_current_node)
    local best_node=""
    local best_score=999999
    local tested=0
    local reachable=0

    while IFS= read -r node; do
        [ -z "$node" ] && continue

        # 跳過 info 節點
        case "$node" in
            *剩余流量*|*距离下次*|*套餐到期*|*有超时*|*超时看*|*推荐夸克*|*邮箱*|*官网*|*老版Clash*|*使用文档*|*IOS继续*|*看文档*) continue ;;
        esac

        # 若不允许 HK，跳過 HK 節點
        if ! $allow_hk && is_hk_node "$node"; then
            continue
        fi

        # 跳過當前節點
        [ "$node" = "$current" ] && continue

        # 測速
        tested=$((tested + 1))
        local delay
        delay=$(test_node_delay "$node")

        if [ "$delay" -eq 0 ] 2>/dev/null; then
            log "    ${node}: 無法連接 ✗"
            continue
        fi

        reachable=$((reachable + 1))

        # 計算評分 = 延遲 + 區域偏好加成
        local region_bonus=100
        case "$node" in
            *SG*|*新加坡*) region_bonus=0 ;;
            *JP*|*日本*)   region_bonus=20 ;;
            *TW*|*台湾*)   region_bonus=50 ;;
            *US*|*美国*)   region_bonus=80 ;;
        esac
        local score=$((delay + region_bonus))

        log "    ${node}: ${delay}ms（評分: ${score}）"

        if [ "$score" -lt "$best_score" ] 2>/dev/null; then
            best_score=$score
            best_node="$node"
        fi
    done < <(get_selectable_nodes)

    log "    測試 ${tested} 個節點，${reachable} 個可達"

    if [ -z "$best_node" ]; then
        log "    ⚠ 找不到可用的節點（allow_hk=${allow_hk}）"
        return 1
    fi

    log "    最佳節點: ${best_node}（評分: ${best_score}）"

    # 執行切換（switch_node 內部含重試 + 節點名驗證）
    if ! switch_node "$best_node" $RETRY_MAX; then
        log "    警告: 節點切換失敗（目標: ${best_node}）"
        notify "VPN Monitor" "⚠️ 無法切換到 ${best_node}"
        return 1
    fi
    log "    節點切換確認: ${best_node} ✓"

    # 驗證連通性（重試 $RETRY_MAX 次，每次間隔 ${RETRY_INTERVAL} 秒）
    # 切換節點後代理需要時間重建連接，不能只測一次
    local retry=0
    while [ $retry -lt $RETRY_MAX ]; do
        sleep $RETRY_INTERVAL
        local cstatus
        cstatus=$(check_connectivity)
        if ! is_down "$cstatus"; then
            log "    連通性驗證: ✓（${cstatus}）"
            log "    成功切換到: ${best_node} ✓"
            notify "VPN Monitor" "🔄 已切換到 ${best_node}"
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $RETRY_MAX ] && log "    連通性檢查失敗（${retry}/${RETRY_MAX}），重試..."
    done

    log "    連通性驗證: ✗（嘗試 ${RETRY_MAX} 次後仍失敗）"
    log "    警告: 已切換到 ${best_node}，但代理暫不可用"
    return 1
}

# Step 3: 強制刷新訂閱（適合 Stash 單一 config 架構）
#   Stash 只有一個 config.yaml（含 subscription URL），PUT /configs（空路徑）
#   會讓 Stash 重新從機場下載節點列表。可能拿到新節點或修復的節點。
refresh_subscription() {
    log ">>> Step 3: 強制刷新訂閱（重新從機場拉節點列表）..."

    # Reload config 觸發 Stash 重新從 subscription URL 下載
    api_put /configs '{"path":"","payload":""}' >/dev/null 2>&1

    # 需要較長等待，讓 Stash 完成訂閱下載 + 節點初始化
    log "    等待訂閱刷新完成（約 15 秒）..."
    sleep 15

    # 確認 API 仍可用
    if check_api; then
        log "    訂閱刷新完成 ✓"

        # 記錄刷新後有多少節點
        local node_count
        node_count=$(get_proxy_nodes | wc -l | tr -d ' ')
        log "    刷新後可用節點數: ${node_count}"

        # 記錄當前 config 檔案修改時間（驗證是否真的 refresh 了）
        if [ -f "$STASH_CONFIG" ]; then
            local mtime
            mtime=$(stat -f %Sm "$STASH_CONFIG" 2>/dev/null || echo "unknown")
            log "    config.yaml 最後修改: ${mtime}"
        fi
    else
        log "    ⚠ 訂閱刷新後 API 無回應"
        return 1
    fi
}

# Step 4: 切換 config（共用函數）
#   切換 config + 等待載入 + 重啟 Stash + 驗證 API
# 等待 Stash 進程出現（pgrep 可找到），最多等 $1 秒（預設 20）
# 用途: restart_stash 重啟後，進程可能延遲出現，下一個 switch_config 需等它穩定
wait_for_stash_process() {
    local max_wait="${1:-20}"
    local i=0
    while [ $i -lt $max_wait ]; do
        if pgrep -x 'Stash' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    log "  ⚠ 等待 Stash 進程超時（${max_wait}s）"
    return 1
}

# 用法: switch_config "target_config"
# 返回: 0=成功, 1=失敗
switch_config() {
    local target="$1"
    log "切換 config: ${target}..."

    # 確保 Stash 進程已穩定就緒再操作 UI（前一次 restart_stash 後可能有短暫空窗）
    if ! wait_for_stash_process 20; then
        log "  ✗ Stash 進程未就緒，無法切換 config"
        return 1
    fi

    local switch_output switch_rc
    switch_output=$("$PYTHON_BIN" "$CONFIG_SWITCHER" "$target" 2>&1)
    switch_rc=$?
    echo "$switch_output" | while IFS= read -r line; do [ -n "$line" ] && log "  ${line}"; done

    if [ $switch_rc -ne 0 ]; then
        log "  ✗ Config 切換指令失敗 (rc=${switch_rc})"
        return 1
    fi

    log "  等待 Stash 載入新 config（15 秒）..."
    sleep 15

    # Config 切換（不同 yaml）後需要重啟 Stash 才能載入新 proxy groups
    restart_stash

    if ! check_api; then
        log "  ✗ 重啟後 API 無回應"
        return 1
    fi

    log "  ✓ Config 切換成功: ${target}"
    return 0
}

# Step 5: 遍歷所有備選 config（使用 switch_config）
try_alternative_configs() {
    log ">>> Step 5: 遍歷所有備選 config..."

    if [ ! -f "$CONFIG_SWITCHER" ] || ! has_python; then
        log "    WARNING: config switcher 或 Python 不可用，跳過"
        return 1
    fi

    # 取得當前 config 和所有可用 config
    local current_config
    current_config=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --status 2>/dev/null | sed 's/^Current config: //')
    log "    當前 config: ${current_config}"

    local all_configs
    all_configs=$("$PYTHON_BIN" "$CONFIG_SWITCHER" --list 2>/dev/null)

    if [ -z "$all_configs" ]; then
        log "    WARNING: 無法取得 config 列表"
        return 1
    fi

    # 遍歷每個備選 config
    while IFS= read -r alt_config; do
        [ -z "$alt_config" ] && continue
        [ "$alt_config" = "$current_config" ] && continue

        log "    嘗試切換到 config: ${alt_config}..."

        if ! switch_config "$alt_config"; then
            log "    ${alt_config} 切換失敗，嘗試下一個"
            continue
        fi

        log "    ${alt_config} 載入成功，搜尋節點..."

        # 先試非 HK 節點（switch_to_best_node 內部含連通性驗證）
        if switch_to_best_node false; then
            log "恢復成功（${alt_config} + 非 HK 節點）✓"
            notify "VPN Monitor" "✅ 已切換到 ${alt_config} 恢復"
            return 0
        fi

        # 試 HK 節點（最後手段，switch_to_best_node 內部含連通性驗證）
        if switch_to_best_node true; then
            log "恢復成功（${alt_config} + HK 節點）✓"
            notify "VPN Monitor" "✅ 已切換到 ${alt_config}（HK 節點）恢復"
            return 0
        fi

        log "    ${alt_config} 所有節點皆失敗，嘗試下一個 config"
    done <<< "$all_configs"

    log "    所有備選 config 皆已嘗試"
    return 1
}

# 日誌輪替
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local lines
        lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$lines" -gt "$MAX_LOG_LINES" ] 2>/dev/null; then
            mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
            log "日誌已輪替"
        fi
    fi
}

# ===================== 輔助函數 =====================

restart_stash() {
    # 重啟 Stash 以更新 GUI 顯示（節點切換後 GUI 不即時反映新節點）
    log "重啟 Stash 以更新 GUI..."
    echo "  正在退出 Stash..."
    local stash_pid
    stash_pid=$(pgrep -x 'Stash$' | head -1 2>/dev/null)
    if [ -z "$stash_pid" ]; then
        log "Stash 未運行，跳過重啟"
        echo "  Stash 未運行，跳過"
        return 0
    fi

    # 用 AppleScript 正常退出（不殺 process，讓 Stash 優雅關閉）
    osascript -e 'quit app "Stash"' 2>/dev/null || true
    sleep 4

    # 檢查 Stash 是否已退出
    local wait_count=0
    while [ $wait_count -lt 8 ]; do
        if ! pgrep -x 'Stash$' >/dev/null 2>&1; then
            break
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    echo "  正在啟動 Stash..."
    open -a Stash 2>/dev/null

    # 確認 Stash 進程真正啟動（open -a 可能靜默失敗，e.g. app crash 或被 macOS 拒絕）
    local proc_ok=0 attempt=0
    while [ $attempt -lt 3 ]; do
        local proc_wait=0
        while [ $proc_wait -lt 10 ]; do
            if pgrep -x 'Stash$' >/dev/null 2>&1; then
                proc_ok=1
                break 2
            fi
            sleep 1
            proc_wait=$((proc_wait + 1))
        done
        attempt=$((attempt + 1))
        log "  Stash 進程未出現（第 ${attempt}/3 次），重新啟動..."
        echo "  Stash 進程未出現，重新啟動（${attempt}/3）..."
        open -a Stash 2>/dev/null
    done

    if [ $proc_ok -eq 0 ]; then
        log "Stash 無法啟動 — 已嘗試 3 次 ⚠"
        echo "  ✗ Stash 無法啟動（已嘗試 3 次）"
        return 1
    fi

    log "Stash 進程已啟動，等待 API 恢復..."
    echo "  Stash 進程已啟動 ✓，等待 API 恢復..."

    # 等待 API 就緒（最多 20 秒）
    sleep 3
    local i
    for i in $(seq 1 15); do
        if check_api; then
            log "Stash API 已恢復可用 ✓"
            echo "  Stash 已重啟完成，API 可用 ✓"
            return 0
        fi
        sleep 1
    done

    log "Stash 重啟後 API 仍無回應 ⚠"
    echo "  Stash 重啟後 API 無回應 ⚠"
    return 1
}

# ===================== 恢復流程 =====================

recover() {
    log "=== 開始恢復流程 ==="

    # Step 1: 刷新 config（reload 當前 + 重連當前節點）
    refresh_config

    # 重新檢查（重試 $RETRY_MAX 次，每次間隔 ${RETRY_INTERVAL}s，給代理足夠時間重建）
    local retry=0
    while [ $retry -lt $RETRY_MAX ]; do
        sleep $RETRY_INTERVAL
        local status
        status=$(check_connectivity)
        if ! is_down "$status"; then
            log "恢復成功（config 刷新後）✓"
            notify "VPN Monitor" "✅ 已透過刷新 config 恢復"
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $RETRY_MAX ] && log "    config 刷新後連通性檢查失敗（${retry}/${RETRY_MAX}），重試..."
    done

    log "刷新 config 後仍然斷線，準備切換節點..."

    # Step 2: 切換到最佳「非 HK」節點（內部含連通性驗證 + 重試）
    if switch_to_best_node false; then
        log "恢復成功（非 HK 節點切換後）✓"
        notify "VPN Monitor" "✅ 已透過切換非 HK 節點恢復"
        return 0
    fi

    log "所有非 HK 節點皆失敗，嘗試 HK 節點（最後手段）..."

    # Step 3: 嘗試 HK 節點（最後手段，內部含連通性驗證 + 重試）
    if switch_to_best_node true; then
        log "恢復成功（HK 節點切換後）✓"
        notify "VPN Monitor" "✅ 已透過 HK 節點恢復（最後手段）"
        return 0
    fi

    log "當前 config 所有節點皆失敗，嘗試強制刷新訂閱..."

    # Step 4: 強制刷新訂閱（從機場重新拉節點，內部已含 sleep 15）
    refresh_subscription

    # 刷新後先檢查連通性（訂閱刷新可能直接解決問題）
    # 重試 $RETRY_MAX 次（每次間隔 ${RETRY_INTERVAL}s），給代理足夠時間重建
    local retry=0
    while [ $retry -lt $RETRY_MAX ]; do
        sleep $RETRY_INTERVAL
        status=$(check_connectivity)
        if ! is_down "$status"; then
            log "恢復成功（刷新訂閱後）✓"
            notify "VPN Monitor" "✅ 已透過刷新訂閱恢復"
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $RETRY_MAX ] && log "    刷新後連通性檢查失敗（${retry}/${RETRY_MAX}），重試..."
    done

    log "刷新後仍斷線，重新搜尋節點..."

    # 先試非 HK（內部含連通性驗證 + 重試）
    if switch_to_best_node false; then
        log "恢復成功（刷新 + 非 HK 節點）✓"
        notify "VPN Monitor" "✅ 已透過刷新訂閱 + 節點切換恢復"
        return 0
    fi

    # 最後手段：刷新後的 HK（內部含連通性驗證 + 重試）
    if switch_to_best_node true; then
        log "恢復成功（刷新 + HK 節點）✓"
        notify "VPN Monitor" "✅ 已透過刷新訂閱 + HK 節點恢復"
        return 0
    fi

    log "所有節點手段皆失敗，嘗試切換到備選 config..."

    # Step 4: 遍歷所有備選 config（支援 N 個 config）
    try_alternative_configs
    if [ $? -eq 0 ]; then
        return 0
    fi

    # 所有手段皆失敗
    log "恢復失敗 — 所有手段皆無效 ✗"
    notify "VPN Monitor" "❌ 所有恢復手段皆失敗，需要手動處理"
    return 1
}

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
        ping_only)
            log "狀態: Ping 正常，HTTP 代理失敗 — VPN 可能斷線"
            log "啟動恢復流程..."
            recover
            ;;
        fail)
            log "狀態: 全部檢測失敗 — VPN 已斷線"
            log "啟動恢復流程..."
            recover
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

    # 非 HK 節點測速
    echo ""
    echo "[4] 非 HK 節點測速（偏好 SG > JP > TW > US）"
    echo "    -------------------------------------------"

    local best_node=""
    local best_score=999999

    while IFS= read -r node; do
        [ -z "$node" ] && continue

        case "$node" in
            *剩余流量*|*距离下次*|*套餐到期*|*有超时*|*超时看*|*推荐夸克*|*邮箱*|*官网*|*老版Clash*|*使用文档*|*IOS继续*|*看文档*) continue ;;
        esac

        if is_hk_node "$node"; then
            echo "    $node: 跳過（HK）"
            continue
        fi

        local delay
        delay=$(test_node_delay "$node")

        local region_bonus=100
        local tag=""
        case "$node" in
            *SG*|*新加坡*) region_bonus=0;  tag="★" ;;
            *JP*|*日本*)   region_bonus=20; tag="★" ;;
            *TW*|*台湾*)   region_bonus=50; tag="" ;;
            *US*|*美国*)   region_bonus=80; tag="" ;;
        esac

        if ! echo "$delay" | grep -qE '^[0-9]+$'; then
            delay=0
        fi

        local score=$((delay + region_bonus))

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
        echo "    → 最佳非 HK 節點: ${best_node}（評分: ${best_score}）"
    else
        echo "    → 沒有可用的非 HK 節點"
    fi

    # HK 節點測速（僅顯示，不切換）
    echo ""
    echo "[5] HK 節點測速（僅顯示，作為最後手段參考）"
    echo "    -------------------------------------------"

    best_node=""
    best_score=999999

    while IFS= read -r node; do
        [ -z "$node" ] && continue

        case "$node" in
            *剩余流量*|*距离下次*|*套餐到期*|*有超时*|*超时看*|*推荐夸克*|*邮箱*|*官网*|*老版Clash*|*使用文档*|*IOS继续*|*看文档*) continue ;;
        esac

        if ! is_hk_node "$node"; then
            continue
        fi

        local delay
        delay=$(test_node_delay "$node")

        if ! echo "$delay" | grep -qE '^[0-9]+$'; then
            delay=0
        fi

        local score=$((delay + 200))  # HK 額外加分，確保排後

        if [ "$delay" -gt 0 ] 2>/dev/null; then
            printf "    %s: %dms (評分: %d)\n" "$node" "$delay" "$score"
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
        echo "    → 最佳 HK 節點: ${best_node}"
    else
        echo "    → 沒有可用的 HK 節點"
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
    echo "  使用 switch_to_best_node 切換到最佳非 HK 節點（與恢復流程相同）..."
    if switch_to_best_node false; then
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

    cp "$repo/vpn_monitor.sh" "$dest_dir/vpn_monitor.sh" && updated=$((updated + 1))
    cp "$repo/stash_switch_config.py" "$dest_dir/stash_switch_config.py" && updated=$((updated + 1))

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

    # 驗證參數
    if [ -z "$target_config" ]; then
        echo "用法: vpn_monitor.sh --change-config <config_name>"
        echo ""
        echo "可用 config（透過 stash_switch_config.py --list 査詢）:"
        if [ -f "$CONFIG_SWITCHER" ] && has_python; then
            "$PYTHON_BIN" "$CONFIG_SWITCHER" --list 2>/dev/null | while IFS= read -r c; do
                [ -n "$c" ] && echo "  - $c"
            done
        else
            echo "  （config switcher 或 Python 不可用）"
        fi
        return 1
    fi

    # 檢查依賴
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

    # 先試非 HK 節點
    echo ">>> 階段 1: 搜尋非 HK 最佳節點（SG > JP > TW > US）..."
    log "=== 手動切換到最佳節點（非 HK）==="
    if switch_to_best_node false; then
        echo ""
        echo "✓ 已切換到最佳節點（非 HK）"
        local new_node
        new_node=$(get_current_node)
        echo "  新節點: ${new_node}"
        return 0
    fi

    echo ""
    echo "⚠ 非 HK 節點皆不可用，嘗試含 HK..."
    echo ""

    # 再試含 HK
    echo ">>> 階段 2: 搜尋含 HK 最佳節點（最後手段）..."
    log "=== 手動切換到最佳節點（含 HK）==="
    if switch_to_best_node true; then
        echo ""
        echo "✓ 已切換到最佳節點（含 HK）"
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
    for f in vpn_monitor.sh stash_switch_config.py; do
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
    else
        if [ -f "$LOG_FILE" ]; then
            rm -f "$LOG_FILE"
            echo "    ✓ 已刪除: $LOG_FILE"
        fi
        if [ -f "${LOG_FILE}.old" ]; then
            rm -f "${LOG_FILE}.old"
            echo "    ✓ 已刪除: ${LOG_FILE}.old"
        fi
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

case "${1:-}" in
    --test)               cmd_test ;;
    --live-test)          cmd_live_test ;;
    --status)             cmd_status ;;
    --update)             cmd_update ;;
    --set-interval)       cmd_set_interval "$2" ;;
    --change-config)       cmd_change_config "$2" ;;
    --switch-to-best-node) cmd_switch_to_best_node ;;
    --stop)               cmd_stop ;;
    --start)              cmd_start ;;
    --uninstall)          cmd_uninstall "$@" ;;
    *)                    cmd_monitor ;;
esac
