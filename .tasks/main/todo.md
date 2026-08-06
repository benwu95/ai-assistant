# Token Usage 計算實作計畫 (antigravity CLI 支援)

## 假設與前置條件 (Assumptions)
1. **資料來源**:
   - `~/.gemini/tmp/*/chats/session-*.jsonl`: 包含舊版/歷史 JSONL 對話記錄，欄位包含 `tokens` (`input`, `output`, `cached`, `thoughts`), `model`, `timestamp`, `sessionId`。
   - `~/.gemini/antigravity-cli/conversations/*.db`: SQLite 資料庫，包含對話軌跡與步驟紀錄。
2. **計費模型**:
   - 參照 Gemini API 官方定價（[ai.google.dev/gemini-api/docs/pricing](https://ai.google.dev/gemini-api/docs/pricing)）：
     - `gemini-3.6-flash` / `gemini-3.5-flash`: Input $0.075/1M, Cached $0.01875/1M, Output $0.30/1M
     - `gemini-3.5-flash-lite` / `gemini-3.1-flash-lite`: Input $0.025/1M, Cached $0.00625/1M, Output $0.10/1M
     - `gemini-3.1-pro-preview` / `gemini-2.5-pro`: Input $1.25/1M, Cached $0.3125/1M, Output $5.00/1M (<=128k)
     - `gemini-2.5-flash`: Input $0.075/1M, Cached $0.01875/1M, Output $0.30/1M
   - 價格表採外部 JSON (`shared/gemini-pricing.json`) 維護，便於隨時擴充與更新。
3. **去重機制**:
   - 根據 `sessionId` + `messageId` (或 `timestamp` + `model` 雜湊) 進行訊息去重，避免相同對話重複計算。

## 待辦事項 (Checklist)

- [x] 1. 建立計費設定檔 (`shared/gemini-pricing.json`)
- [x] 2. 實作核心解析與計算模組 (`scripts/token_usage.py`)
  - [x] 2.1 JSONL 對話檔解析器 (`~/.gemini/tmp/*/chats/*.jsonl`)
  - [x] 2.2 SQLite 資料庫解析器 (`~/.gemini/antigravity-cli/conversations/*.db`)
  - [x] 2.3 訊息去重與 Token 統計邏輯 (Input, Cached Read, Output, Reasoning/Thoughts, Net Input)
  - [x] 2.4 價格換算與 Model Breakdown 模組
  - [x] 2.5 報表輸出 (Daily, Weekly, Monthly, Session, JSON, Compact Table)
- [x] 3. 新增 Slash Command 定義 (`commands/token-usage.md`)
- [x] 4. 撰寫單元測試與驗證腳本 (`scripts/test_token_usage.py`)
- [x] 5. 更新 README.md 文件與安裝腳本鏈結說明

## 成果驗證 (Result Review)
- `scripts/token_usage.py` 成功解析本機歷史紀錄與最新對話，輸出包含 `gemini-3.6-flash`, `gemini-3.1-pro-preview` 等多種模型的 Daily, Weekly, Monthly, Session 報表。
- 單元測試 `scripts/test_token_usage.py` 3 項測試全數通過（淨 Prompt Token 計算、快取扣除、金額換算與日期篩選）。
- Slash Command `commands/token-usage.md` 已建立並鏈結至 `~/.ai-assistant/commands/`。
