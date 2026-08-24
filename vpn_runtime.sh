#!/usr/bin/env bash
# Runtime/recovery functions for vpn_monitor.sh.
# This file is intentionally source-only: configuration/defaults are owned by
# vpn_monitor.sh (or by tests) and sourcing this module performs no work.

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

# 節點優先級 tier（strict priority，lower tier = higher priority）
# JP/SG(0) > TW(1) > US(2) > other non-HK(3) > HK(9)
node_priority_tier() {
    local node="$1"
    case "$node" in
        *SG*|*新加坡*|*JP*|*日本*) echo 0 ;;
        *TW*|*台湾*) echo 1 ;;
        *US*|*美国*) echo 2 ;;
        *HK*|*香港*) echo 9 ;;
        *) echo 3 ;;
    esac
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

# Step 2: 切換到最佳節點（單一排名通道：JP/SG > TW > US > other non-HK > HK）
# 策略：所有可達節點按分數排序，逐一切換並驗證連通性；
# 切換成功但連通失敗的節點在本輪被跳過，不重複嘗試。
switch_to_best_node() {
    log ">>> Step 2: 搜尋最佳節點（JP/SG > TW > US > other non-HK > HK）..."

    local current
    current=$(get_current_node)
    local tested=0
    local reachable=0

    # 收集所有可達節點及其分數，寫入臨時檔案供排序
    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' RETURN

    while IFS= read -r node; do
        [ -z "$node" ] && continue

        # 跳過 info 節點
        case "$node" in
            *剩余流量*|*距离下次*|*套餐到期*|*有超时*|*超时看*|*推荐夸克*|*邮箱*|*官网*|*老版Clash*|*使用文档*|*IOS继续*|*看文档*) continue ;;
        esac

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

        # Strict priority tiers: JP/SG(0) > TW(1) > US(2) > other(3) > HK(9)
        local tier
        tier=$(node_priority_tier "$node")
        local score=$((tier * 100000 + delay))

        log "    ${node}: ${delay}ms（評分: ${score}）"
        echo "$score $node" >> "$tmpfile"
    done < <(get_selectable_nodes)

    log "    測試 ${tested} 個節點，${reachable} 個可達"

    if [ "$reachable" -eq 0 ]; then
        log "    ⚠ 找不到可用的節點"
        return 1
    fi

    # 按分數升序排列（低分優先），逐一切換並驗證連通性
    local switched=""
    local cstatus=""
    local _conn_tmp
    _conn_tmp=$(mktemp)
    while read -r score node; do
        [ -z "$node" ] && continue

        # 執行切換（switch_node 內部含重試 + 節點名驗證）
        if ! switch_node "$node" $RETRY_MAX; then
            log "    警告: 節點切換失敗（目標: ${node}），嘗試下一個"
            continue
        fi
        switched="$node"
        log "    節點切換確認: ${node} ✓"

        # 切換成功後驗證連通性（最多重試 RETRY_MAX 次）
        # 用 temp file 避免 $(...) 子殼層導致的全域計數器遺失
        local conn_retry=0
        while [ $conn_retry -lt $RETRY_MAX ]; do
            sleep $RETRY_INTERVAL
            check_connectivity > "$_conn_tmp"
            cstatus=$(cat "$_conn_tmp")
            if ! is_down "$cstatus"; then
                break
            fi
            conn_retry=$((conn_retry + 1))
            [ $conn_retry -lt $RETRY_MAX ] && log "    連通性檢查失敗（${conn_retry}/${RETRY_MAX}），重試..."
        done

        if ! is_down "$cstatus"; then
            log "    連通性驗證: ✓（${cstatus}）"
            log "    成功切換到: ${node} ✓"
            notify "VPN Monitor" "🔄 已切換到 ${node}"
            rm -f "$_conn_tmp"
            return 0
        fi
        log "    連通性驗證失敗 — ${node} 在 ${RETRY_MAX} 次重試後仍不可用，嘗試下一個候選"
    done < <(sort -n "$tmpfile")
    rm -f "$_conn_tmp"

    if [ -n "$switched" ]; then
        log "    警告: 已切換到 ${switched}，但代理暫不可用"
    fi
    log "    所有可達節點皆已嘗試，恢復失敗 ✗"
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

        # 搜尋節點（JP/SG > TW > US > other non-HK > HK，內部含連通性驗證）
        if switch_to_best_node; then
            log "恢復成功（${alt_config} + 節點切換）✓"
            notify "VPN Monitor" "✅ 已切換到 ${alt_config} 恢復"
            return 0
        fi

        log "    ${alt_config} 所有節點皆失敗，嘗試下一個 config"
    done <<< "$all_configs"

    log "    所有備選 config 皆已嘗試"
    return 1
}

# 今日日期（可被測試以 VPN_LOG_DATE_OVERRIDE 覆蓋）
today_str() {
    [ -n "${VPN_LOG_DATE_OVERRIDE:-}" ] && echo "${VPN_LOG_DATE_OVERRIDE}" || date '+%Y-%m-%d'
}

# 保留窗口起算日（today - LOG_RETENTION_DAYS），GNU/BSD date 雙平台可移植
log_retention_cutoff() {
    local today; today="$(today_str)"
    if date -v "-${LOG_RETENTION_DAYS}d" "+%Y-%m-%d" >/dev/null 2>&1; then
        # BSD date (macOS)
        date -v "-${LOG_RETENTION_DAYS}d" -j -f '%Y-%m-%d' "$today" '+%Y-%m-%d' 2>/dev/null || echo 0000-00-00
    else
        # GNU date (Linux/CI)
        date -d "${today} - ${LOG_RETENTION_DAYS} days" '+%Y-%m-%d' 2>/dev/null || echo 0000-00-00
    fi
}

# 從日誌內容取第一個／最新有效 timestamp 日期。
first_log_date() {
    local today; today="$(today_str)"
    awk -v today="$today" 'match($0, /^\[(19|20)[0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) /) { d=substr($0, 2, 10); if (d <= today) { print d; exit } }' "$1" 2>/dev/null
}

latest_log_date() {
    local today; today="$(today_str)"
    awk -v today="$today" 'match($0, /^\[(19|20)[0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) /) { d=substr($0, 2, 10); if (d <= today && (latest == "" || d > latest)) latest=d } END { if (latest != "") print latest }' "$1" 2>/dev/null
}

# 日誌輪替：按第一個有效 timestamp 日期歸檔（基於時間，非行數）
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local first_date archive rotated
        first_date="$(first_log_date "$LOG_FILE")"
        if [ -n "$first_date" ] && [ "$first_date" != "$(today_str)" ]; then
            archive="${LOG_FILE}.${first_date}"
            rotated=false
            if [ -f "$archive" ]; then
                # 先原子 detach active log；後續 writer 會寫入新的 active file，
                # 不會被 collision merge 的清理步驟截斷。
                local segment="${LOG_FILE}.rotate.$$.$RANDOM"
                if mv "$LOG_FILE" "$segment" 2>/dev/null; then
                    if cat "$segment" >> "$archive" 2>/dev/null; then
                        rm -f "$segment"
                        rotated=true
                    else
                        # append 失敗時優先保資料；即使造成重複，也不能丟歷史。
                        if [ -e "$LOG_FILE" ]; then
                            if cat "$segment" >> "$LOG_FILE" 2>/dev/null; then
                                rm -f "$segment" 2>/dev/null || true
                            fi
                        else
                            mv "$segment" "$LOG_FILE" 2>/dev/null || true
                        fi
                    fi
                fi
            elif mv "$LOG_FILE" "$archive" 2>/dev/null; then
                rotated=true
            fi

            if $rotated; then
                log "日誌已輪替至 ${archive}"
            else
                log "WARNING: 日誌輪替失敗，保留 active log"
            fi
        fi
    fi

    # 即使 active log 缺失或無法解析，也不能讓 retention cleanup 永久停掉。
    prune_old_logs
}

# 清理超過保留期的 dated 日誌；不動 legacy .old 或其他後綴。
# 正常 archive 只看檔名；只有檔名已過期、準備刪除時才檢查最新 timestamp，
# 避免 migration 形成的跨多日 archive 因第一日檔名而提早刪除。
prune_old_logs() {
    local dir base cutoff f d filename_date
    dir="$(dirname "$LOG_FILE")"
    base="$(basename "$LOG_FILE")"
    cutoff="$(log_retention_cutoff)"
    for f in "$dir"/"$base".????-??-??; do
        [ -e "$f" ] || continue
        filename_date="${f#"$dir"/"$base".}"
        [ "$filename_date" \< "$cutoff" ] || continue
        d="$(latest_log_date "$f")"
        [ -n "$d" ] || d="$filename_date"
        [ "$d" \< "$cutoff" ] && rm -f "$f" 2>/dev/null || true
    done
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

    # Step 2: 切換到最佳節點（JP/SG > TW > US > other non-HK > HK，按分數排序逐一切換並驗證連通性）
    if switch_to_best_node; then
        log "恢復成功（節點切換後）✓"
        notify "VPN Monitor" "✅ 已透過節點切換恢復"
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

    # 重新搜尋節點（JP/SG > TW > US > other non-HK > HK，按分數排序逐一切換並驗證連通性）
    if switch_to_best_node; then
        log "恢復成功（刷新 + 節點切換）✓"
        notify "VPN Monitor" "✅ 已透過刷新訂閱 + 節點切換恢復"
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
