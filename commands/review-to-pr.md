---
description: Sync a local review.md into the matching GitHub PR as bundled inline review comments (skipping items already covered by existing PR comments); also verifies the user's prior PR threads and offers to resolve those whose underlying issues are now fixed.
argument-hint: [review_path]
allowed-tools: Bash(gh:*), Bash(git:*), Bash(jq:*), Bash(cat:*), Bash(ls:*), Bash(echo:*), Bash(mkdir:*), Read, Write, Edit, AskUserQuestion
---

# Review-to-PR

把一份本地 `review.md`（multi-review / code review 產出的整合報告）裡所抓到、但**目標 PR 既有留言尚未涵蓋**的問題，做成一份 bundled inline review comments 送到 GitHub PR。

同時：**在送出新 comment 之前，先檢視 PR 上由當前使用者（`authUser`）開啟、目前仍 `unresolved` 的 review thread**，逐條對照當前程式碼，把已修正（或經作者 acknowledge 為「刻意不做」）的 thread 詢問使用者後一併 `resolve`。

整體流程強調：
- **不自動修檔**、**不自動送出**——使用者要看過 preview 並明確同意才送
- **不自動 resolve thread**——即使顯示「已修正」，也要使用者最後勾選 / 同意才執行 `resolveReviewThread` mutation
- 每條 comment 以條列式呈現，繁體中文台灣用語，專業術語保留英文
- 引用既有 PR 評論者時：若該 user 為當前 gh CLI auth 帳號，改寫成「我」；其餘維持 `@username`

---

## Inputs

- `review_path`（位置參數，選填）：要讀的 review 報告路徑
  - 若使用者帶引數，直接用該路徑
  - 否則依下列優先序自動找：
    1. `.tasks/{currentBranch}/review-merged.md`
    2. `.tasks/{currentBranch}/review.md`
  - 都找不到 → 提示使用者明確指定路徑後中止
- `currentBranch`：`git rev-parse --abbrev-ref HEAD`
- `prNumber`：用 `gh pr list --head {currentBranch} --state open --json number --jq '.[0].number'` 取得；若無對應 PR → 提示後中止
- `authUser`：`gh api user --jq .login` 取得，作為「我」的替換對象

---

## Execution Flow

### Phase 1 — Context Retrieval

並行執行（單一訊息內多個 Bash tool call）：

1. `git rev-parse --abbrev-ref HEAD` → currentBranch
2. `gh pr list --head {currentBranch} --state open --json number,title,url,headRefOid` → prNumber、headRefOid、PR URL
3. `gh api user --jq .login` → authUser
4. Read review file（依 Inputs 規則決定路徑）

若 PR 不存在 / 找不到 review 檔 → 用一句話告訴使用者並中止，不要硬猜。

### Phase 2 — 抓 PR 既有留言 + Review Threads

並行執行：

1. **Inline review comments**：
   ```
   gh api repos/{owner}/{repo}/pulls/{prNumber}/comments --paginate \
     --jq '[.[] | {id, user: .user.login, path, line, original_line, body}]'
   ```
2. **Issue-level（PR 對話區）comments**：
   ```
   gh api repos/{owner}/{repo}/issues/{prNumber}/comments --paginate \
     --jq '[.[] | {id, user: .user.login, body}]'
   ```
3. **PR reviews**（含 review-level body，例如 approval / changes-requested 的整體留言）：
   ```
   gh api repos/{owner}/{repo}/pulls/{prNumber}/reviews --paginate \
     --jq '[.[] | {id, user: .user.login, state, body}]'
   ```
4. **Review threads（GraphQL，含 resolve 狀態）**：REST API 不曝露 thread node id 與 `isResolved`，但 Phase 3 的 resolve 動作必須拿到 thread node id，所以這裡要打 GraphQL：
   ```bash
   gh api graphql -f query='
     query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
       repository(owner: $owner, name: $name) {
         pullRequest(number: $number) {
           reviewThreads(first: 100, after: $cursor) {
             pageInfo { hasNextPage endCursor }
             nodes {
               id
               isResolved
               path
               line
               originalLine
               comments(first: 20) {
                 nodes {
                   databaseId
                   author { login }
                   body
                   pullRequestReview { databaseId }
                 }
               }
             }
           }
         }
       }
     }' -F owner={owner} -F name={repo} -F number={prNumber} \
       --jq '.data.repository.pullRequest.reviewThreads'
   ```
   - 若 `pageInfo.hasNextPage == true` → 帶 `-F cursor={endCursor}` 續拉
   - 結果寫成 `/tmp/pr-{prNumber}-threads.json`，後續 Phase 3 / Phase 4 都會用

> owner/repo 從 `gh repo view --json owner,name --jq '.owner.login + "/" + .name'` 拿。

### Phase 3 — 驗證 `authUser` 自己既有 thread，互動式 Resolve

> 在貼新 comment 之前，先 close 掉已完成的舊 thread——這比「先洗版新 comment、再回頭 resolve」對 PR 作者更友善（同一通知、同一視野）。

**目的**：找出 PR 上由 `authUser`（你自己）開啟、目前仍 `isResolved=false` 的 review thread，逐條對照當前程式碼，把已修正 / 經作者明確 acknowledge 為「刻意不做」的條目，徵得使用者同意後一次 `resolveReviewThread`。

#### Step 3.1 — 篩選候選

從 Phase 2 拿到的 `/tmp/pr-{prNumber}-threads.json` 過濾：

```bash
jq -r '.nodes[]
  | select(.comments.nodes[0].author.login == "{authUser}"
           and .isResolved == false)
  | "\(.id)\t\(.path)\t\(.line // .originalLine)\t\(.comments.nodes[0].pullRequestReview.databaseId)"' \
  /tmp/pr-{prNumber}-threads.json > /tmp/pr-{prNumber}-resolve-candidates.tsv
```

每行：`thread_id`、`path`、`line`、`root_review_id`。

#### Step 3.2 — 對每條候選分類

逐條判斷當前程式碼狀態。可採以下其中一種策略：

- **小批量（≤ 10 條）**：主 agent 直接讀檔比對，標記每條的 `verdict`
- **大批量（> 10 條）**：丟給 `multi-review-verifier` subagent 批次驗證，回傳每條的 `verdict`

每條的 `verdict` 取四種其中之一：

| Verdict | 定義 | 預設 resolve 候選 |
|---------|------|------------------|
| `[已修正]` | 當前程式碼已直接 / 等價解決原 thread 提出的問題 | **是**（預設勾選） |
| `[刻意未做]` | 程式碼未改，但 thread 後續 reply 顯示作者已說明為何不修，且使用者過去未再追問 | **是**（預設勾選） |
| `[作者異議]` | 作者已 reply 但理由你不接受、或仍需追問——技術上未達共識 | **否**（不勾選；提示人工 follow-up） |
| `[未修]` | 程式碼仍存在原問題，作者也未回覆 | **否**（不勾選；通常代表還沒處理） |

判定輔助規則：
- thread 內所有 comment 都是 `authUser` 自己，沒有作者回覆 → 多半是 `[未修]` 或 `[已修正]`，依程式碼狀態判
- 作者最後一句 reply 含「fixed」/「done」/「removed」/「updated」/「many thanks」之類 → 程式碼確認後可標 `[已修正]`
- 作者 reply 含明確設計取捨理由（「目前 AC 不支援」、「之後支援多檔再說」之類）→ `[刻意未做]`
- 注意排除「使用者剛剛在本次流程才送出、屬於本次 review payload 的 thread」——這些 thread 的 `root_review_id` 會等於 Phase 7 即將送出的 review id（在 Phase 3 階段尚未產生，無需處理；但若有「先前同名 review payload 留下、尚未 resolve」的，仍會被列入候選，由 verdict 決定要不要 resolve）

#### Step 3.3 — Preview 與互動

用 **AskUserQuestion** 提供 4 個選項（每輪保持一致）：

1. **查看分類** — 顯示候選 thread 依 verdict 分組的清單，並標示哪幾條預設勾選
2. **調整勾選** — 詢問編號 + 動作（加入 / 移除 resolve 清單）
3. **執行 Resolve** — 把目前勾選的 thread 批次 `resolveReviewThread`
4. **跳過 Resolve 步驟** — 不 resolve 任何 thread，直接進 Phase 4

不要替使用者擅自 resolve `[作者異議]` / `[未修]`，即使數量少也要使用者明確加入。

#### Step 3.4 — 執行 Resolve（使用者選 3 時）

```bash
while IFS=$'\t' read -r thread_id path line; do
  /opt/homebrew/bin/gh api graphql \
    -f query='mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { id isResolved }
      }
    }' -f id="$thread_id" \
    --jq '.data.resolveReviewThread.thread.isResolved' \
    && echo "✓ $path:$line" \
    || echo "✗ $path:$line"
done < /tmp/pr-{prNumber}-resolve-final.tsv
```

> **注意**：某些 shell 環境 `gh` 不在 `$PATH`（例如 sandboxed subshell）。若直接呼 `gh` 失敗，改用絕對路徑 `/opt/homebrew/bin/gh`（macOS Homebrew 預設）或 `which gh` 取得的路徑。

執行後回報：`resolved=N failed=M`，並列出失敗的 path:line（通常是 thread 被別人提前 resolve、或網路問題）。

#### Step 3.5 — 進下一階段

無論使用者選了哪個分支，最後都會進 **Phase 4**。Resolve 結果（含 verdict 分類與實際 resolved count）保留到最後 summary。

---

### Phase 4 — 比對 Review vs PR

把 review 報告解析成 issue list（每筆有 file、line、標題、問題敘述、建議 fix）。

對每筆 review issue，判斷它是否已被 PR 涵蓋：

**覆蓋判定（任一條件成立即視為已涵蓋）**：
- PR inline comment 落在同一檔案的 ±20 行範圍內，且 body 文字與該 review issue 的標題或核心關鍵詞語意相近
- PR issue-level / review-level body 內提到該 issue 的關鍵 location 或 topic
- **Phase 3 剛剛 resolve 掉的 thread 也算「已涵蓋」** —— 那已經是 closed loop，沒必要再貼新 comment

不確定的，**寧可保守視為「已涵蓋」並列在「skipped」清單**，最後讓使用者過目。不要把 PR 沒提到的硬塞給已覆蓋；也不要把 PR 已說過的再貼一次。

**比對輸出**（內部資料結構，給後續步驟用）：
- `to_post`：review 抓到、PR 沒提到 → 要送的清單
- `skipped`：review 抓到、PR 已用近似方式提到 → 不送，但要在最後 summary 提一句
- `not_in_review`：PR 已提但 review 沒抓到 → 不處理，但可在 summary 點一下「PR 有點到這幾項是 review 沒抓到的補充」

### Phase 5 — 生成 inline comment bodies

每條 `to_post` 產生一段 markdown body，遵守以下風格：

**結構**（固定模板）：
```
**[P{priority}] {標題}**

{視情況加 1-2 句背景，或直接跳到問題}

**問題**：
- 條列點 1
- 條列點 2
- ...

**建議**：
- 條列 or 短段
- 視情況附 `code block`（盡量精簡，只保留關鍵幾行）
```

**字數**：每條 body 控制在 ~150 字內（不含 code block）。code block 抓重點，不貼整段 diff。

**語言**（遵循 `~/.ai-assistant/shared/taiwan-terminology.md` 用語對照與排版規則）：

- 繁體中文 + 台灣用語
- 專業術語保留英文：lock / race / commit / SQS / DB session / identity map / atomic UPDATE / context manager / closure / generator 等
- 行內 code / 路徑 / 識別字用反引號
- **中英文混排時，英文單字前後加半形空格**（例：`獨立 Session 審查機制`、`改用 SELECT FOR UPDATE`）
- 標點使用全形（，。、：；「」），英文專有名詞可混用半形標點

**Cross-link 規則**：
- 若 review 評論需要引用 PR 既有評論者：
  - 若該 user == `authUser` → 改寫成「我」（例如：「呼應我在 `validation:85` 的評論」）
  - 否則保留 `@username`（例如：「呼應 @other-user 在 `validation:85` 的評論」）
- 若 review 評論需要引用 git commit SHA（如 `e2201cfff`），保留原樣

**Priority 標記**：從 review.md 標題 / table 抓 P0/P1/P2，前綴 `[P{level}]`。沒有的就省略。

**Code block 規則**：
- Python code 用 ```` ```python ```` 包
- 縮排正常
- f-string 中的 `}}` 不要用 Python escape，直接寫
- 字串內含中文時注意 JSON escape（之後產 payload 時要處理）

### Phase 6 — Preview 與互動 Loop

進入互動迴圈，**每輪用 AskUserQuestion**，選項固定 4 個：

1. **查看內容** — 把 `to_post` 清單以 `[#N | P{level}] {file}:{line} — {標題}` 一行一個列出；再問使用者要看哪幾條完整 body（可以「全部」、「P0 only」、「指定編號 1,3,5」、「指定編號 1」、「跳過直接送」）。把選的條目用 markdown blockquote 形式 echo 出來。
2. **修改內容** — 詢問要改哪些（編號 + 改什麼）。常見模式：
   - 刪除某幾條
   - 改寫某條 body（請使用者口頭描述方向，由你重寫）
   - 改變落點 line
   - 整體再縮短 / 整體改更白話
   - 合併某幾條 / 拆分某條
   修改完後**回到迴圈開頭**重新顯示主問題（不要自動送）。
3. **發送至 GitHub** — 進 Phase 7。
4. **取消** — 中止。把 JSON payload 保留在 `/tmp/review-to-pr-{prNumber}.json` 並告訴使用者路徑，方便事後手動處理。

迴圈持續直到使用者選「發送」或「取消」。**不要替使用者做決定**；即使所有 P2 都看完了，也要回到主問題等使用者明確下決定。

> **特例：`to_post` 為空** — 若 Phase 4 比對後沒任何要新貼的 comment（review 全部被 PR 既有評論或 Phase 3 剛 resolve 的 thread 涵蓋），直接跳過 Phase 6，告知使用者「沒有新東西要送」並把 Phase 3 的 resolve 結果作為 final summary。

### Phase 7 — 送出

把所有 `to_post` 條目組裝成單一 Review payload：

```json
{
  "commit_id": "{headRefOid}",
  "event": "COMMENT",
  "body": "{overall summary，列 P0/P1/P2 數量與一行 topic 概要}",
  "comments": [
    {"path": "...", "line": N, "body": "..."},
    ...
  ]
}
```

寫到 `/tmp/review-to-pr-{prNumber}.json`，然後：

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{prNumber}/reviews \
  --input /tmp/review-to-pr-{prNumber}.json \
  --jq '{id, state, html_url, submitted_at}'
```

**驗證落地**：

```bash
gh api repos/{owner}/{repo}/pulls/{prNumber}/comments --paginate \
  --jq '[.[] | select(.pull_request_review_id == {review_id})] | length'
```

回報（合併 Phase 3 + Phase 7 結果）：
- **Phase 3**：候選 thread 總數、verdict 分類計數、實際 resolved count、保留未 resolve 的清單摘要
- **Phase 7**：Review URL、inline comment 落地數量、與預期一致 / 不一致（不一致時列出哪幾條沒落地）
- `skipped` 清單摘要（讓使用者知道哪幾條 review 抓到的 PR 已經提了所以沒送）

---

## Taiwan 用語對照（必須遵循）

遵循 `~/.ai-assistant/shared/taiwan-terminology.md` 用語對照與排版規則。

---

## Constraints

- **絕不在送出 / Resolve 前修改 PR 上任何內容**——Phase 1-4 全部 read-only。
- **絕不送出未經使用者明確同意的 review**。即使 `to_post` 為空，也要明確告知使用者「沒有新東西要送」並等待確認。
- **絕不未經使用者明確同意 resolve 任何 thread**。Phase 3 即使 verdict 顯示 `[已修正]` / `[刻意未做]`，也只是「預設勾選」，最後必須使用者點「執行 Resolve」才會打 mutation。
- **不要 resolve 非 `authUser` 開啟的 thread**——本指令只負責使用者自己的舊評論，不替別人 close conversation。
- **不要 resolve 本次流程剛送出的新 thread**（review_id 等於 Phase 7 reply 的 review id）。
- **不要重跑 multi-review**。本指令只負責把現成的 review.md 同步到 PR。
- **不要修改本地 review.md**。如果發現 review 內容有問題，告訴使用者，由使用者決定要不要回去修。
- **不要做 force push、close PR、approve / request changes、unresolve thread**。事件型固定用 `COMMENT`。
- 若 `gh` 未 auth 或無權限 → 不嘗試 workaround，直接報錯誤並提示使用者 `gh auth login`。
- 若 commit_id 在送出時已過時（PR 在我們準備期間有新 push）→ 重新抓 headRefOid 後再送；body 不變。
- 處理大檔案 / 多筆 issue 時，所有 `gh api` 呼叫一律 `--paginate`（GraphQL 用 `pageInfo.hasNextPage` 續拉）。
- JSON payload 用 Write tool 寫到 `/tmp/`，不要嘗試在 shell 內 echo 大量轉義字串。
- 環境 `$PATH` 異常時（subshell 找不到 `gh`），用絕對路徑（macOS Homebrew 預設 `/opt/homebrew/bin/gh`）。

---

## Edge Cases

| 情境 | 處理 |
|------|------|
| review.md 沒有明確 P0/P1/P2 標記 | 不前綴 priority，但仍按 review 內順序排 |
| review issue 缺 file:line | 提示使用者該 issue 跳過、列在 skipped 清單，並說明理由 |
| review issue 的 file 不在 PR diff 內 | 仍嘗試送（GitHub 會以 file-level comment 處理）；若 API 回 422，標為失敗並列出來給使用者 |
| 同一 review issue 跨多檔 | 拆成多條 inline comment（每檔一條，body 內 cross-link） |
| PR 已 closed / merged | 警告使用者並問是否仍要送（通常不送） |
| `to_post` 為空 | 不進入 Phase 5/6 互動迴圈，但仍要先跑 Phase 3 處理舊 thread，最後合併 summary 回報 |
| 沒有 `authUser` 開啟的 unresolved thread | 跳過 Phase 3，提示「沒有自己開啟的舊 thread 要處理」，直接進 Phase 4 |
| Phase 3 候選全部 verdict 為 `[未修]` / `[作者異議]` | 仍呈現分類給使用者看，但「執行 Resolve」清單預設為空；除非使用者手動勾選，否則不送 mutation |
| `resolveReviewThread` mutation 回 `null` / 報錯 | 通常是 thread 已被其他人 resolve、或 thread id 失效（PR 重新 base 後 thread 重生）；列入失敗清單但繼續處理其餘 |
| review 是另一個 reviewer 寫的（非當前 authUser）| 不影響流程；mention 規則仍依「該被 mention 的 user 是不是 authUser」判斷 |
| review.md 內有引用其他評論者（如 `@username`） | 若該 username == authUser，改成「我」；否則保留 |

