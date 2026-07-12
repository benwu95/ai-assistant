---
name: branch-diff
description: "Generate a structured branch-diff document (繁體中文) that summarizes all changes between the current branch and a target branch (default main). Output to .tasks/{currentBranch}/branch-diff.md. Triggers: branch diff, 分支差異, 分支變更詳解, summarize branch, diff summary, PR summary."
allowed-tools: Read, Write, Grep, Glob, Bash(git:*)
---

# Branch Diff

You are a seasoned **Principal Software Engineer**. Produce a structured change-explainer document covering every difference between the current branch and a given branch (default `main`), so a reviewer can grasp the overall design without reading the full diff.

## Inputs

- `targetBranch` (optional): base branch to compare against; default `main`
- `currentBranch`: from `git rev-parse --abbrev-ref HEAD`
- `outputPath`: default `.tasks/{currentBranch}/branch-diff.md`

If invoked as `/branch-diff <branchName>`, treat `<branchName>` as `targetBranch`.

## Execution Flow

### Phase 1 — Context Retrieval (all mandatory)

Run the following commands in parallel, within a single message where possible:

1. `git rev-parse --abbrev-ref HEAD` — get currentBranch
2. `git merge-base {targetBranch} HEAD` — get the divergence point
3. `git log --oneline {targetBranch}..HEAD` — list commits
4. `git diff --stat {targetBranch}...HEAD` — per-file change stats (+/-)
5. `git diff --name-status {targetBranch}...HEAD` — change types (A/M/D/R)
6. `git diff {targetBranch}...HEAD` — full diff (skippable on large repos; read files selectively instead)

**Note**: use the three-dot `...` syntax to compare "divergence point → HEAD", so the target branch's new commits are not mistaken for this branch's changes.

### Phase 2 — Deep Reading

**Mandatory fresh-read rule**: every factual statement written into the document (fields, method signatures, routes, behavior) must be based on **the latest file content fetched with the `Read` tool at generation time**. Prior conversation, training memory, or cached code is auxiliary reference only — never a source of record; on conflict, the freshly read file wins.

For every "non-trivial" file in the diff, proactively `Read` its **complete, current** content:

- new model / migration / router / service files
- files with more than 50 changed lines
- AI-knowledge documents (e.g. `prospec/ai-knowledge/`; adjust the path per repo)
- test files: reading the descriptions is enough; no need to go line by line

If the diff is huge (> 2000 lines), fan out with Agent (Explore subagent) to preserve main context; subagents must likewise read the latest files from disk.

### Phase 3 — Classification

Bucket every file change into the following layers (emit only sections the branch actually touched; skip the rest):

| Category | Example paths |
|---|---|
| Domain models | `app/models/*.py` |
| New API endpoints | `app/routes/**/*.py` |
| Service layer | `app/services/**/*.py` |
| Repository | `app/repositories/**/*.py` |
| Cross-module integration | services/orchestrators touching other domains |
| Validation & constants | `app/validation/*.py`, `app/lib/constants.py` |
| Database migrations | `migrations/versions/*.py` |
| AI Knowledge | `prospec/ai-knowledge/**/*.md` |
| Test coverage | `tests/**/*.py` |
| Other | config, CI, scripts, etc. |

### Phase 4 — Output

Write the document to `outputPath` per the Output Template below, creating the directory first if needed.

## Output Template

The output language is **Traditional Chinese (Taiwan)** with technical terms kept in English; follow the terminology table and typography rules in `~/.ai-assistant/shared/taiwan-terminology.md`. Follow the structure and tone below exactly — the template is kept in Chinese verbatim because it IS the output specification.

**Important**: apart from 「改動內容」 and 「設計重點總結」 which are always written, every other section (領域模型, 新 API 端點, Service 層, 跨模組整合, 驗證與常數, 資料庫遷移, AI Knowledge, 測試涵蓋, ...) is **conditional** — produce it only when the branch actually has corresponding changes; otherwise omit the entire section including its heading, leaving no empty shells. For example: when no model was added or modified, there must be no 「## 領域模型」 section. Sections are never numbered; headings are plain text.

````markdown
# {currentBranch} 分支變更詳解

> 基準：`{targetBranch}`
> 當前：`{currentBranch}`
> Commits：{N} 個，共 {M} 檔變更（+{adds} / -{dels}）

---

## 改動內容

{先以 1–2 句話點出此分支的整體變動主題與目的，緊接著以**巢狀條列**方式列出 3–6 個關鍵改動主題；每個主題用粗體標題，下面再以 2–4 個子條列拆解該主題的具體細項與設計理由。**不要把細項全部塞在同一句**——主題下方的子條列才是讓 reviewer 能快速掃讀的關鍵。聚焦「做了什麼、為何而做」，不逐一列 commit。}

- **{主題一}**：
  - {子細項 a：具體變動 1 + 動機}
  - {子細項 b：具體變動 2 + 動機}
  - {子細項 c（選填）}
- **{主題二}**：
  - {子細項 a}
  - {子細項 b}
- **{主題三}**：
  - {子細項 a}
  - {子細項 b}
- ...

**反例（不要這樣寫）**：
```
- **主題**：細項 a、細項 b、細項 c，連帶細項 d（理由），同時細項 e
```
這種寫法把所有細節擠在一個長句裡，reviewer 難以區分主從、無法快速掃讀。

**正例**：
```
- **主題**：
  - 細項 a：具體內容 + 動機
  - 細項 b：具體內容 + 動機
  - 細項 c：具體內容 + 動機
```

---

## 領域模型

**{ModelName}** — {一句話說明用途}。

### `{file_path}`

| 欄位 | 型別 | 說明 |
|---|---|---|
| ... | ... | ... |

- **索引**：...
- **關係**：...

---

## 新 API 端點

路徑：`{router_file}`

| Method | Path | 用途 |
|---|---|---|
| ... | ... | ... |

### 修改既有端點
- ...

### Response 形狀重點
- ...

---

## Service 層

路徑：`{service_file}`（{±N} 行變更）

### 新增公開方法
1. **`method_name(...)`** — {用途}
2. ...

### {子主題：互斥邏輯 / 批量持久化最佳化 / ...}
- ...

---

## 跨模組整合

### `{module_file}` ({±N})
- ...

---

## 驗證與常數

### `{validation_file}`
新增：
- ...

### `{constants_file}`
- ...

---

## 資料庫遷移

`{migration_file}`

### `upgrade()`
1. ...

### `downgrade()`
{反向操作描述}

---

## AI Knowledge

`{ai_knowledge_path}` 變更：
- ...

---

## 測試涵蓋

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

- **The latest files are the single source of truth**: re-`Read` the relevant files before writing; never rely on conversation cache or memory; on spotting a stale citation, re-read and correct immediately
- **Focus on design decisions, not line-by-line translation**: explaining "why it changed" beats listing "which lines changed"
- **Cite concrete paths**: wrap every file, module, and method in backticks
- **Quantify**: bring in commit counts, file counts, line counts, query counts wherever possible
- **No auto-dropping sections**: if AI Knowledge / migrations / new models changed, their sections are mandatory; with no changes, omit the whole section
- **Tables first**: fields, endpoints, SHAs and other structured data go in tables, not long bullet lists
- **No emotional language** or marketing copy (e.g. 「全面升級」「強大功能」)
- **Closing 「設計重點總結」**: 3–5 points calling out cross-cutting concerns — mutual exclusion, performance, concurrency, authorization, events
- If the branch has no changes at all, or only merge commits, write 「無實質差異」 to `outputPath` and stop

## Self-Check Before Finalizing

Confirm each item before writing the file:

- [ ] the numbers from `git diff --stat` match the document header
- [ ] 「改動內容」 contains a 1–2 sentence overview plus 3–6 bold themes, each broken into 2–4 **nested sub-bullets** (never cram the details into one long sentence)
- [ ] every new or heavily modified file is mentioned in some section
- [ ] test files are grouped by type with no new test missed
- [ ] 「設計重點總結」 echoes decisions visible in the actual diff — no fabrication
- [ ] the output path is correct: `.tasks/{currentBranch}/branch-diff.md`
