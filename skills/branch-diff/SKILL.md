---
name: branch-diff
description: "Generate a structured branch-diff document (繁體中文) that summarizes all changes between the current branch and a target branch (default main). Output to .tasks/{$currentBranch}/branch-diff.md. Triggers: branch diff, 分支差異, 分支變更詳解, summarize branch, diff summary, PR summary."
allowed-tools: Read, Write, Grep, Glob, Bash(git:*)
---

# Branch Diff

你是一位資深 **Principal Software Engineer**。任務是針對「當前分支」與「指定分支（預設 `main`）」的所有差異，產出一份結構化的變更詳解文件，協助 reviewer 在不讀完整 diff 的情況下掌握整體設計。

## Inputs

- `targetBranch`（選填）：比較的基準分支；預設 `main`
- `currentBranch`：從 `git rev-parse --abbrev-ref HEAD` 取得
- `outputPath`：預設 `.tasks/{$currentBranch}/branch-diff.md`

若使用者以 `/branch-diff <branchName>` 方式呼叫，將 `<branchName>` 視為 `targetBranch`。

## Execution Flow

### Phase 1 — Context Retrieval（必須全部執行）

並行執行以下指令，盡量於單一訊息內：

1. `git rev-parse --abbrev-ref HEAD` — 取得 currentBranch
2. `git merge-base {targetBranch} HEAD` — 取得分歧點
3. `git log --oneline {targetBranch}..HEAD` — 列出 commits
4. `git diff --stat {targetBranch}...HEAD` — 取得檔案變更統計（+/-）
5. `git diff --name-status {targetBranch}...HEAD` — 取得變更類型（A/M/D/R）
6. `git diff {targetBranch}...HEAD` — 取得完整 diff（大 repo 可省略，改為針對性讀檔）

**注意**：使用三點 `...` 語法比較「分歧點 → HEAD」，避免把 target branch 的新 commits 當成自己的變更。

### Phase 2 — Deep Reading

**強制重新讀檔原則**：任何寫入文件的事實描述（欄位、方法簽名、路由、行為）都必須以**當下 `Read` 工具取得的最新檔案內容**為依據。先前對話、訓練記憶、或 cache 中的程式碼資訊僅供輔助參考，不得作為產出依據；若兩者衝突，一律以新讀的檔案為準。

針對 diff 中出現的「非平凡」檔案，主動使用 `Read` 讀取**完整且最新**的內容：

- 新增的 model / migration / router / service 檔
- 修改行數 > 50 的檔案
- 任何 `prospec/ai-knowledge/` 文件
- 測試檔：閱讀描述即可，不需逐行

若 diff 過大（> 2000 行），以 Agent（Explore subagent）分派探索，保留主 context；subagent 同樣需直接讀取磁碟上的最新檔案。

### Phase 3 — Classification

將所有檔案變更歸類到以下層次（只列出「該分支實際有變更」的章節，無的跳過）：

| 分類 | 對應路徑範例 |
|---|---|
| 領域模型 | `app/models/*.py` |
| 新 API 端點 | `app/routes/**/*.py` |
| Service 層 | `app/services/**/*.py` |
| Repository | `app/repositories/**/*.py` |
| 跨模組整合 | 牽動其他 domain 的 service/orchestrator |
| 驗證與常數 | `app/validation/*.py`、`app/lib/constants.py` |
| 資料庫遷移 | `migrations/versions/*.py` |
| AI Knowledge | `prospec/ai-knowledge/**/*.md` |
| 測試涵蓋 | `tests/**/*.py` |
| 其他 | 設定、CI、腳本等 |

### Phase 4 — Output

依據下方「Output Template」撰寫文件，寫入 `outputPath`。若目錄不存在需先建立。

## Output Template

輸出語言為**繁體中文台灣用語**，專業術語保留英文。用語對照與排版規則遵循 `~/.ai-assistant/shared/taiwan-terminology.md`。嚴格遵循以下結構與語氣。

**重要**：除「改動內容」與「設計重點總結」必寫外，其餘編號章節（領域模型、新 API 端點、Service 層、跨模組整合、驗證與常數、資料庫遷移、AI Knowledge、測試涵蓋等）皆為**條件式章節**——僅當該分支實際有對應變更時才產出，無變更則整章（含標題）省略，不留空殼。例如：未新增或修改任何 model 時，不應出現「## 領域模型」章節。章節編號依實際保留的章節重新排序。

````markdown
# {currentBranch} 分支變更詳解

> 基準：`{targetBranch}`
> 當前：`{currentBranch}`
> Commits：{N} 個，共 {M} 檔變更（+{adds} / -{dels}）

---

## 改動內容

{先以 1–2 句話點出此分支的整體變動主題與目的，緊接著以條列方式列出 3–6 個關鍵改動重點。聚焦「做了什麼、為何而做」，不逐一列 commit。}

- **{主題一}**：{一句話說明此項改動的內容與目的}
- **{主題二}**：{一句話說明此項改動的內容與目的}
- **{主題三}**：{一句話說明此項改動的內容與目的}
- ...

---

## 領域模型（僅當有新增／修改 model 時保留此章節，否則整章省略）

**{ModelName}** — {一句話說明用途}。

### `{file_path}`

| 欄位 | 型別 | 說明 |
|---|---|---|
| ... | ... | ... |

- **索引**：...
- **關係**：...

---

## 2. 新 API 端點

路徑：`{router_file}`

| Method | Path | 用途 |
|---|---|---|
| ... | ... | ... |

### 修改既有端點
- ...

### Response 形狀重點
- ...

---

## 3. Service 層

路徑：`{service_file}`（{±N} 行變更）

### 新增公開方法
1. **`method_name(...)`** — {用途}
2. ...

### {子主題：互斥邏輯 / 批量持久化最佳化 / ...}
- ...

---

## 4. 跨模組整合

### `{module_file}` ({±N})
- ...

---

## 5. 驗證與常數

### `{validation_file}`
新增：
- ...

### `{constants_file}`
- ...

---

## 6. 資料庫遷移

`{migration_file}`

### `upgrade()`
1. ...

### `downgrade()`
{反向操作描述}

---

## 7. AI Knowledge

`{ai_knowledge_path}` 變更：
- ...

---

## 8. 測試涵蓋

共 {N} 個新／修改檔：

### Service
- ...

### Route
- ...

### Repository / Factory
- ...

---

## 設計重點總結

1. **{模式名}**：{核心洞察}
2. ...
````

## Writing Guidelines

- **以最新檔案為單一事實來源**：撰寫前重新 `Read` 相關檔案，不得依賴對話 cache 或記憶；發現引用內容過時時，立即重讀並修正
- **聚焦設計決策，非逐行翻譯**：說明「為什麼這樣改」勝過「改了什麼行」
- **引用具體路徑**：所有檔案、模組、方法以 backtick 包裹
- **量化指標**：盡量帶入 commit 數、檔案數、行數、查詢次數等數據
- **不自動刪除章節**：若 AI Knowledge / migration / 新 model 有變更就必寫；沒有則整章省略
- **表格優先**：欄位、端點、SHA 等結構化資料一律用表格，避免冗長項目列表
- **禁止情緒性語言**、行銷文案（例如「全面升級」「強大功能」）
- **尾段「設計重點總結」**：3–5 點，點出互斥、效能、並發、授權、事件等橫切關注點
- 若分支「無任何變更」或僅有 merge commit，直接在 `outputPath` 寫入「無實質差異」並結束

## Self-Check Before Finalizing

在寫入檔案前逐項確認：

- [ ] `git diff --stat` 的數字與文件標頭一致
- [ ] 「改動內容」段落含 1–2 句總述加 3–6 點條列重點，精煉呈現本分支整體變動
- [ ] 每一個新檔或大幅修改的檔案都在某章節中被提及
- [ ] 測試檔按類型分組，未遺漏任何新測試
- [ ] 設計重點總結呼應實際 diff 中可見的決策，不編造
- [ ] 輸出路徑正確：`.tasks/{currentBranch}/branch-diff.md`
