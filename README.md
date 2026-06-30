# AGENTS.md / README.md — Stash VPN Monitor

Profile: trader | 用途: VPN 连線檢測 + 自動恢復

## 概述

自動監控 Stash VPN 連線，斷線時自動恢復：刷新 config → 切換節點 → 刷新訂閱 → 輪詢備選 config。

## 功能

1. **連通性檢測** — Ping 8.8.8.8 + HTTP 通過代理雙重驗證（失敗後重試 5 次，間隔 3 秒，避免短暫波動誤觸發恢復流程）
2. **自動恢復鏈** — 7 步逐級升級：
   - 刷新 config（reload + 測速重連當前節點）
   - 切換到最佳非 HK 節點（偏好 SG > JP > TW > US）
   - 嘗試 HK 節點（最後手段）
   - 強制刷新訂閱（重新從機場拉節點列表）
   - 刷新後重試非 HK → HK 節點
   - 輪詢所有備選 config，逐個嘗試節點切換
   - 全部失敗 → 通知手動處理
3. **Config 切換** — 透過 macOS Accessibility API 自動點擊 Stash UI 切換 config
4. **GUI 同步** — 恢復成功後自動重啟 Stash，使 GUI 顯示正確節點
5. **完整日誌** — 所有操作記錄到 `~/Library/Logs/vpn_monitor.log`

## 安裝

```bash
git clone <repo-url> vpn-monitor
cd vpn-monitor
./install_vpn_monitor.sh
```

安裝腳本會自動：
- 從 Stash plist 提取 API secret
- 偵測已安裝 pyobjc 的 Python 環境
- 生成配置檔案 `~/.config/vpn_monitor/config`
- 複製腳本到 `~/.local/bin/`
- 載入 LaunchAgent（每 300 秒 / 5 分鐘檢查一次）

## 配置

配置檔案位於 `~/.config/vpn_monitor/config`，格式為 `KEY=VALUE`：

| Key | 說明 | 預設值 |
|-----|------|--------|
| `API_BASE` | Stash API 地址 | `http://127.0.0.1:9090` |
| `API_SECRET` | Stash API secret（從 plist 獲取） | — |
| `PYTHON_BIN` | Python 路徑（需有 pyobjc） | `python3` |
| `STASH_CONFIG_DIR` | Stash config 目錄 | `~/Library/Group Containers/group.ws.stash.app/stash` |
| `ICLOUD_CONFIG_DIR` | Stash iCloud config 目錄 | `~/Library/Mobile Documents/iCloud~ws~stash~icloud/Documents` |
| `INSTALL_DIR` | 腳本安裝目錄 | `~/.local/bin` |
| `LOG_FILE` | 日誌檔案路徑 | `~/Library/Logs/vpn_monitor.log` |
| `MONITOR_REPO` | Git repo 路徑（版本檢測 / `--update` 用） | 自動偵測 |
| `CHECK_INTERVAL` | 檢查間隔秒數（`--set-interval` 可動態修改） | `300`（5 分鐘） |

可透過環境變數 `VPN_MONITOR_CONFIG` 指定不同的配置檔案路徑。

## 使用

```bash
vpn_monitor.sh                      # 正常監控（LaunchAgent 自動呼叫）
vpn_monitor.sh --status             # 顯示當前狀態（含版本資訊）
vpn_monitor.sh --test               # 測試模式（不切換，只報告）
vpn_monitor.sh --live-test          # 實戰測試（真正切換 + 恢復）
vpn_monitor.sh --change-config <name>   # 切換 config
vpn_monitor.sh --switch-to-best-node    # 自動搜尋並切換最佳節點
vpn_monitor.sh --update             # 用 git pull 更新腳本
vpn_monitor.sh --set-interval <秒>  # 設定檢查間隔（e.g. 300 = 5 分鐘）
vpn_monitor.sh --stop               # 停止監控
vpn_monitor.sh --start              # 啟動監控
vpn_monitor.sh --uninstall [--delete-logs]  # 完全卸載
```

## 依賴

- **Stash**（macOS，Clash 相容 API）
- **Python 3** + pyobjc：
  ```bash
  pip install pyobjc-framework-ApplicationServices pyobjc-framework-Quartz
  ```
- **Accessibility 權限**（System Settings → Privacy & Security → Accessibility）— config 切換功能需要

## 檔案結構

```
├── vpn_monitor.sh              # 主監控腳本
├── stash_switch_config.py      # Config 切換器（AX API）
├── install_vpn_monitor.sh      # 一鍵安裝
├── com.user.vpn-monitor.plist  # LaunchAgent 模板
├── config.example              # 配置檔案模板
├── stash_dump.py               # 開發工具：dump AX tree（除錯用）
└── .gitignore
```

## 技術筆記

- `PUT /proxies` API 只改記憶體狀態，不寫入 `config.yaml` — 重啟 Stash 會丟失 API 切換
- 路由 group 透過 `/rules` API 動態檢測（查 `type=="MATCH"` 的 rule 的 `proxy` 字段）
- 節點選擇只從路由 group 的 `.all` 選項列表中選取（交集過濾），避免選到不可切換的 balancer 成員
- Stash（SwiftUI app）的 `AXWindows` 可能為空，需用 `AXFocusedWindow` 替代
- Config 切換透過 `stash://install-config` URL scheme + AX API 掃描 UI + `AXPress` 點擊
