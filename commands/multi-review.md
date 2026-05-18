---
description: Iterative code review loop — Claude reviewer (python-code-review skill) ↔ Claude verifier (multi-review-verifier agent), driven entirely inside the Claude Code session (no programmatic billing)
argument-hint: [base_branch=main] [max_iter=3] [reviewer_model=opus|sonnet|haiku] [verifier_model=opus|sonnet|haiku]
allowed-tools: Agent, Read, Bash, Write
---

執行 Claude agents 互動式 code review 迴圈。**迴圈由 command 層級（主 session）直接驅動**，每輪 spawn 獨立的 reviewer 和 verifier sub-agent，整個 review 流程計入訂閱用量。所有中文輸出遵循 `~/.ai-assistant/shared/taiwan-terminology.md` 用語對照與排版規則。

每輪兩個 sub-agent：
1. **reviewer**：`Agent(subagent_type=claude)` 內呼叫 `python-code-review` skill 產出結構化報告
2. **verifier**：`Agent(subagent_type=multi-review-verifier)` 讀程式碼逐項驗證、標註 `[需修正] / [可忽略] / [不存在]`

迴圈直到本輪 `[需修正]` = 0 或達 `max_iter`，**先到先停**。

## Constant

- `TOOLS` = `~/.claude/scripts/multi-review-tools.py`

## EXECUTION RULE

Steps 4-9 構成 review 迴圈。Step 9 的 bash 輸出會包含 `SIGNAL=CONVERGED` 或 `SIGNAL=MAX_ITER_REACHED` 或 `SIGNAL=CONTINUE NEXT_ROUND=<N>`。**若 SIGNAL 為 CONTINUE，你必須立刻用 NEXT_ROUND 的值作為新的 `i`，回到 Step 4 執行下一輪。在迴圈未結束前產出 text-only response（沒有 tool call）是一個 BUG。**

---

## Steps

### Step 1: Parse `$ARGUMENTS`

- 第 1 個位置 → `BASE`（預設 `main`）
- 第 2 個位置 → `MAX_ITER`（預設 `3`，hard cap `5`）
- 第 3 個位置 → `REVIEWER_MODEL`（可選，必須是 alias: opus/sonnet/haiku）
- 第 4 個位置 → `VERIFIER_MODEL`（可選，必須是 alias: opus/sonnet/haiku）

若 `MAX_ITER > 5`，拒絕並告知使用者上限為 5。
若使用者傳 full model id（如 `claude-opus-4-6[1m]`），拒絕並建議改用 alias。

告知使用者本次參數，然後開始執行。

### Step 2: Phase 0 — Setup [Bash]

替換 `<BASE>` 為解析後的值，執行：

```bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
TS=$(date +%Y%m%d_%H%M%S)
WORKDIR="$REPO_ROOT/.tasks/$BRANCH/review/$TS"
FINAL_REPORT="$REPO_ROOT/.tasks/$BRANCH/review.md"
STATS_TSV="$WORKDIR/.round-stats.tsv"

if git -C "$REPO_ROOT" diff --quiet "<BASE>...HEAD"; then
  echo "NO_DIFF"; exit 0
fi

mkdir -p "$WORKDIR"
: > "$STATS_TSV"
git -C "$REPO_ROOT" diff "<BASE>...HEAD" > "$WORKDIR/full-diff.patch"
git -C "$REPO_ROOT" diff --stat "<BASE>...HEAD" > "$WORKDIR/diff-stat.txt"
awk '/^diff --git / { sub(/^b\//, "", $4); print $4 }' "$WORKDIR/full-diff.patch" \
  | sort -u > "$WORKDIR/changed-files.txt"

echo "WORKDIR=$WORKDIR"
echo "REPO_ROOT=$REPO_ROOT"
echo "BRANCH=$BRANCH"
echo "FINAL_REPORT=$FINAL_REPORT"
echo "STATS_TSV=$STATS_TSV"
echo "FILES=$(wc -l < $WORKDIR/changed-files.txt | tr -d ' ')"
```

若輸出 `NO_DIFF`：告知使用者 `No diff between $BRANCH and $BASE; nothing to review.` 然後停止。

**記住此步驟輸出的所有變數值**（`WORKDIR`, `REPO_ROOT`, `BRANCH`, `FINAL_REPORT`, `STATS_TSV`），後續步驟全部引用這些值。

### Step 3: Phase 0b — Carry-forward [Bash, conditional]

先檢查 `FINAL_REPORT` 是否存在。**只在存在時**執行以下 Bash：

```bash
set -euo pipefail
TOOLS=~/.claude/scripts/multi-review-tools.py
cp "<FINAL_REPORT>" "<WORKDIR>/iter-0-verified.md"
python3 $TOOLS extract-annotations "<WORKDIR>/iter-0-verified.md" \
  > "<WORKDIR>/iter-0-annotations.tsv"
python3 $TOOLS derive-sidecars \
  "<WORKDIR>/iter-0-annotations.tsv" \
  "<WORKDIR>/iter-0-verdicts.tsv" \
  "<WORKDIR>/iter-0-needsfix.sig"
PRIOR_N=$(wc -l < "<WORKDIR>/iter-0-needsfix.sig" | tr -d ' ')
echo "PRIOR_N=$PRIOR_N"
```

若 `FINAL_REPORT` 不存在，設 `PRIOR_N=0`，跳過此步驟直接進入 Step 4。

---

### Step 4: Spawn reviewer [Agent] — Round `i`（初始 `i=1`）

計算本輪路徑：
- `R` = `<WORKDIR>/iter-<i>-review.md`
- `PREV_V` = `<WORKDIR>/iter-<i-1>-verified.md`

組裝 carry-forward hint：
- Round 2+ 且 PREV_V 存在：

  ```
  Previous verified report: <PREV_V>.
  Skip any issue already marked [不存在] there (reviewer hallucinations).
  Skip any issue already marked [可忽略] (acknowledged but acceptable).
  For items still [需修正], you MAY re-report them if you have new evidence; otherwise omit.
  ```

- Round 1 或 PREV_V 不存在：`No previous iteration.`

呼叫 Agent：

```
Agent({
  subagent_type: "claude",
  description: "multi-review reviewer round <i>",
  model: <REVIEWER_MODEL if provided, else omit>,
  prompt: "Use the python-code-review skill to review the diff between <BASE> and HEAD on branch <BRANCH>.
The full unified diff is at: <WORKDIR>/full-diff.patch
Changed files list:         <WORKDIR>/changed-files.txt
Working directory (read code from here): <REPO_ROOT>

<CARRY_HINT>

OUTPUT INSTRUCTIONS (override the skill default):
- Write your final report to <R> via the Write tool. DO NOT write to .tasks/<BRANCH>/review.md or any other path.
- Your text response back to me MUST be exactly one line in the form:
    wrote to <R> (Critical=N Performance=N Maintainability=N)
  Do NOT echo the report body or any other prose.
- Follow the skill's Report Format with sections: Summary / Changelog / Critical Issues / Performance & Optimization / Maintainability & Architecture / Good Practices Observed.
- STRICT issue format inside Critical / Performance / Maintainability sections — the downstream verifier+splicer parses these by regex; ANY deviation breaks splice:
  * Each issue starts with a top-level bullet at column 0: `- **Issue Title**`. DO NOT use `### C1.` / `### P1.` / `### M1.` h3 headers; DO NOT prefix with C1./P1./M1. codes.
  * The first sub-bullet of every issue MUST be exactly `  - **Location**: path/to/file.py:LINE` (bold **Location**, no surrounding backticks around the path).
  * Range form `path:START-END` is allowed; ` (deleted)` suffix is allowed; nothing else may wrap the path."
})
```

### Step 5: Post-reviewer check [Bash]

替換 `<R>`, `<FINAL_REPORT>`, `<WORKDIR>` 後執行：

```bash
set -euo pipefail
R="<R>"
FINAL_REPORT="<FINAL_REPORT>"
WORKDIR="<WORKDIR>"
if [[ ! -s "$R" ]] && [[ -f "$FINAL_REPORT" ]]; then
  SETUP_MTIME=$(stat -f %m "$WORKDIR/full-diff.patch" 2>/dev/null || stat -c %Y "$WORKDIR/full-diff.patch" 2>/dev/null || echo 0)
  FR_MTIME=$(stat -f %m "$FINAL_REPORT" 2>/dev/null || stat -c %Y "$FINAL_REPORT" 2>/dev/null || echo 0)
  if (( FR_MTIME > SETUP_MTIME )); then
    cp "$FINAL_REPORT" "$R"; rm -f "$FINAL_REPORT"; echo "RECOVERED from FINAL_REPORT stomp"
  fi
fi
[[ -s "$R" ]] || { echo "REVIEWER_FAILED"; exit 1; }
grep -qE '^## (Critical Issues|Performance & Optimization|Maintainability & Architecture)' "$R" || { echo "REVIEWER_BAD_FORMAT"; exit 1; }
echo "REVIEWER_OK round <i>"
```

若輸出 `REVIEWER_FAILED` 或 `REVIEWER_BAD_FORMAT`：**停止**，告知使用者 reviewer 在 round `<i>` 失敗，提供 `WORKDIR` 路徑供 deep dive。不要重跑。

### Step 6: Spawn verifier [Agent] — Round `i`

計算：
- `PREV_ANN_TSV` = `<WORKDIR>/iter-<i-1>-annotations.tsv`

組裝 verifier consistency hint：
- Round 2+ 且 PREV_ANN_TSV 存在：

  ```
  CONSISTENCY ANCHOR: Read <PREV_ANN_TSV> first (3-col TSV: Location / previous verdict / previous Evidence).
  For each issue, look up by Location:
  - Found + code unchanged → carry previous verdict. Evidence: "Previous: [verdict] (reason); code unchanged."
  - Found + code changed → may flip, but Evidence MUST cite the specific change.
  - Not found → judge from scratch.
  Goal: stable verdicts. Flip without code-level justification is a bug. Do NOT Read prior reviewer report or verified.md.
  ```

- Round 1 或 PREV_ANN_TSV 不存在：留空（不包含 consistency anchor 段落）。

呼叫 Agent：

```
Agent({
  subagent_type: "multi-review-verifier",
  description: "multi-review verifier round <i>",
  model: <VERIFIER_MODEL if provided, else omit>,
  prompt: "Verify every issue in the review report against the actual code in <REPO_ROOT>.

Review report path: <R>

<VERIFIER_CONSISTENCY_HINT>

Your response back to me IS the verdicts list — do NOT preface with meta-commentary, do NOT echo reviewer fields, do NOT write any file.
First line of your response MUST be [需修正], [可忽略], or [不存在] (each verdict marker at column 1).
Format per issue: exactly three lines (verdict / Location: <path:line> / Evidence: <…>), records separated by a single blank line.
End your response with the ## Verification Summary table prescribed in your agent definition."
})
```

### Step 7: Save verifier output [Write]

將 Step 6 verifier agent 的**完整回應文字**寫入 `<WORKDIR>/iter-<i>-verdicts.md`：

```
Write(file_path="<WORKDIR>/iter-<i>-verdicts.md", content=<verifier 的完整回應文字>)
```

### Step 8: Post-verifier processing [Bash]

替換所有 `<placeholder>` 後執行。注意 `<i>` 和 `<i-1>` 需替換為實際數字：

```bash
set -euo pipefail
TOOLS=~/.claude/scripts/multi-review-tools.py
R="<R>"
V_RAW="<WORKDIR>/iter-<i>-verdicts.md"
V="<WORKDIR>/iter-<i>-verified.md"
ANN_TSV="<WORKDIR>/iter-<i>-annotations.tsv"
TSV="<WORKDIR>/iter-<i>-verdicts.tsv"
SIG="<WORKDIR>/iter-<i>-needsfix.sig"
FLIPS="<WORKDIR>/iter-<i>-flips.txt"
PREV_TSV="<WORKDIR>/iter-<i-1>-verdicts.tsv"
PREV_SIG="<WORKDIR>/iter-<i-1>-needsfix.sig"
STATS_TSV="<STATS_TSV>"
MAX_ITER=<MAX_ITER>
ROUND=<i>

read -r CC CP CM REVIEWER_LOC_COUNT < <(python3 $TOOLS count-sections "$R")
python3 $TOOLS parse-verifier-raw "$V_RAW" > "$ANN_TSV"
RAW=$(wc -l < "$ANN_TSV" | tr -d ' ')
(( RAW == 0 )) && (( REVIEWER_LOC_COUNT > 0 )) && { echo "VERIFIER_FORMAT_VIOLATION"; exit 1; }
python3 $TOOLS splice "$R" "$ANN_TSV" > "$V"
echo "" >> "$V"
python3 $TOOLS verification-summary "$V_RAW" "$ANN_TSV" >> "$V"
python3 $TOOLS derive-sidecars "$ANN_TSV" "$TSV" "$SIG"
DIFF_PREV=()
[[ -f "$PREV_TSV" ]] && DIFF_PREV+=(--prev-tsv "$PREV_TSV")
[[ -f "$PREV_SIG" ]] && DIFF_PREV+=(--prev-sig "$PREV_SIG")
DIFF_OUT=$(python3 $TOOLS diff-rounds ${DIFF_PREV[@]+"${DIFF_PREV[@]}"} --curr-tsv "$TSV" --curr-sig "$SIG" --flip-detail-out "$FLIPS")
eval "$DIFF_OUT"
printf '%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n' "$ROUND" "$CC" "$CP" "$CM" "$N_NEEDS_FIX" "$N_IGNORED" "$N_NONEXISTENT" "$NEW" >> "$STATS_TSV"

echo "ROUND=$ROUND CC=$CC CP=$CP CM=$CM NEEDS_FIX=$N_NEEDS_FIX IGNORED=$N_IGNORED NONEXISTENT=$N_NONEXISTENT NEW=$NEW"
if (( N_NEEDS_FIX == 0 )); then
  echo "SIGNAL=CONVERGED"
elif (( ROUND >= MAX_ITER )); then
  echo "SIGNAL=MAX_ITER_REACHED NEEDS_FIX=$N_NEEDS_FIX"
else
  echo "SIGNAL=CONTINUE NEXT_ROUND=$((ROUND + 1))"
fi
```

若輸出 `VERIFIER_FORMAT_VIOLATION`：**停止**，告知使用者 verifier 在 round `<i>` 格式違規，提供 `WORKDIR` 路徑。不要重跑。

### Step 9: Convergence check

讀取 Step 8 的輸出，根據 `SIGNAL` 決定：

- `SIGNAL=CONVERGED`：告知使用者 `✓ Converged at round <i>: no [需修正] issues remain.`，**跳到 Step 10**
- `SIGNAL=MAX_ITER_REACHED`：告知使用者 `● Reached max_iter=<MAX_ITER> with <NEEDS_FIX> [需修正] issue(s) remaining.`，**跳到 Step 10**
- `SIGNAL=CONTINUE NEXT_ROUND=<N>`：告知使用者 `Round <i> done. Continuing to round <N>.`，**設 `i=<N>`，回到 Step 4**

**CRITICAL**：若 SIGNAL 為 CONTINUE，你的下一個 response 必須包含 Step 4 的 Agent tool call。不可以只輸出文字。

---

### Step 10: Phase 2 — Final merge [Bash]

```bash
set -euo pipefail
python3 ~/.claude/scripts/multi-review-tools.py merge "<WORKDIR>" "<FINAL_REPORT>" "<STATS_TSV>"
echo "Final report: <FINAL_REPORT>"
```

若 merge 失敗：告知使用者 merge 階段失敗，提供 `WORKDIR` 路徑。不要重跑。

### Step 11: Phase 3 — Summary + Report

1. **取得 summary table** [Bash]：

```bash
set -euo pipefail
python3 ~/.claude/scripts/multi-review-tools.py summary-table "<STATS_TSV>"
```

2. **讀取最終報告** [Read]：開啟 `<FINAL_REPORT>`

3. **報告結果**：
   - 該檔是 **cumulative**：每個 issue 依 Location 去重後只出現一次，verdict 取最後一輪判定；block 內容來自首次出現該 issue 的那輪（標註 `_(origin: iter-N)_`）。前面輪次的 `[可忽略]` / `[不存在]` 即使後續輪次的 reviewer 跳過了也會保留在最終報告
   - 依序按 `## Critical Issues`（P0）→ `## Performance & Optimization`（P1）→ `## Maintainability & Architecture`（P2）列出所有 `[需修正]` 項目的**標題 + Location**（一行一個）；section 本身就承擔嚴重程度語意
   - 依檔案歸納要動哪幾個檔案
   - 附上 per-round breakdown 表格（Step 11.1 的輸出）
   - 若 `[不存在]` 比例 > 30%，提醒「reviewer 可能有幻覺、建議人工抽檢」
   - 若 `[可忽略]` 有重要項目，提一句「下列雖標為可忽略但值得知道：...」
   - 結尾告知 `.tasks/<BRANCH>/review.md` 路徑（跨 run 持續更新，會被下次執行當 iter-0 anchor）以及這次的 timestamped 中間檔位置 `WORKDIR`

---

## Constraints

- **不要自動修檔**——使用者要看完報告再決定
- 不要重跑迴圈。若使用者要再跑，請他自行加新參數
- 若任何步驟 ABORT：不要嘗試讀 `review.md`、不要從部分產物推測
- Model 參數**只接受 alias**（`opus` / `sonnet` / `haiku`）；若使用者傳 full id，拒絕並建議改用 alias
- `MAX_ITER` 上限為 5（context 安全邊界）；若使用者要更高請拒絕並建議拆多次跑
- 每一個 Bash 呼叫的第一行**必須**是 `set -euo pipefail`
- **不要**讀取 `iter-N-review.md` 或 `iter-N-verified.md` 進你自己的 context 來「分析」——用 `count-sections` 和 `derive-sidecars` 做結構性檢查
