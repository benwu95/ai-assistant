---
description: Iterative code review loop — Claude reviewer (python-code-review skill) ↔ Claude verifier (multi-review-verifier agent), driven entirely inside the Claude Code session (no programmatic billing)
argument-hint: [base_branch=main] [max_iter=3] [reviewer_model=opus|sonnet|haiku] [verifier_model=opus|sonnet|haiku]
allowed-tools: Agent, Read, Bash, Write
---

Run an interactive code review loop between Claude agents. **The loop is driven directly at the command level (main session)**: each round spawns an independent reviewer and verifier sub-agent, and the whole review flow counts toward subscription usage. All Chinese output follows the terminology table and typography rules in `~/.ai-assistant/shared/taiwan-terminology.md`.

Each round spawns two sub-agents:
1. **reviewer**: `Agent(subagent_type=claude)` invokes the `python-code-review` skill to produce a structured report
2. **verifier**: `Agent(subagent_type=multi-review-verifier)` reads the code and validates each issue, annotating `[NEEDS-FIX] / [IGNORABLE] / [NONEXISTENT]`

Loop until the current round has zero `[NEEDS-FIX]` or `max_iter` is reached, **whichever comes first**.

## Constant

- `TOOLS` = `~/.ai-assistant/scripts/multi-review-tools.py`

## EXECUTION RULE

Steps 4-9 form the review loop. Step 9's bash output contains `SIGNAL=CONVERGED`, `SIGNAL=MAX_ITER_REACHED`, or `SIGNAL=CONTINUE NEXT_ROUND=<N>`. **If SIGNAL is CONTINUE, you MUST immediately take the NEXT_ROUND value as the new `i` and go back to Step 4 for the next round. Producing a text-only response (no tool call) before the loop has ended is a BUG.**

---

## Steps

### Step 1: Parse `$ARGUMENTS`

- 1st positional → `BASE` (default `main`)
- 2nd positional → `MAX_ITER` (default `3`, hard cap `5`)
- 3rd positional → `REVIEWER_MODEL` (optional; must be an alias: opus/sonnet/haiku)
- 4th positional → `VERIFIER_MODEL` (optional; must be an alias: opus/sonnet/haiku)

If `MAX_ITER > 5`, refuse and tell the user the cap is 5.
If the user passes a full model id (e.g. `claude-opus-4-8`), refuse and suggest an alias instead.

Tell the user the resolved parameters, then start.

### Step 2: Phase 0 — Setup [Bash]

Replace `<BASE>` with the resolved value, then run:

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

If the output is `NO_DIFF`: tell the user `No diff between $BRANCH and $BASE; nothing to review.` and stop.

**Remember every variable value printed by this step** (`WORKDIR`, `REPO_ROOT`, `BRANCH`, `FINAL_REPORT`, `STATS_TSV`); all later steps reference these values.

### Step 3: Phase 0b — Carry-forward [Bash, conditional]

First check whether `FINAL_REPORT` exists. **Only if it exists**, run:

```bash
set -euo pipefail
TOOLS=~/.ai-assistant/scripts/multi-review-tools.py
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

If `FINAL_REPORT` does not exist, set `PRIOR_N=0` and skip straight to Step 4.

### Step 3c: Pre-validate carry-forward `[NEEDS-FIX]` items [Agent + Write + Bash, conditional]

**Run only when `PRIOR_N > 0`.** Before entering the reviewer loop, verify whether the carried-forward `[NEEDS-FIX]` items still exist in the current code. Items already fixed get marked `[FIXED]`, so the reviewer does not waste a whole round re-reporting solved problems.

1. **Spawn verifier**:

```
Agent({
  subagent_type: "multi-review-verifier",
  description: "carry-forward recheck",
  model: <VERIFIER_MODEL if provided, else omit>,
  prompt: "Re-verify only the [NEEDS-FIX] issues from the carry-forward report against the current code in <REPO_ROOT>.

Review report path: <WORKDIR>/iter-0-verified.md

IMPORTANT: Only verify issues currently annotated as [NEEDS-FIX]. Skip [IGNORABLE] and [NONEXISTENT] items entirely — do NOT emit verdicts for them.

Use these verdicts:
- [FIXED] — the issue existed in a prior review but has been fixed in the current code.
- [NEEDS-FIX] — the issue still exists and needs attention.
- [IGNORABLE] — on re-examination, the issue is acceptable.
Do NOT use [NONEXISTENT] — all items being rechecked were previously validated as real issues.

Your response back to me IS the verdicts list — do NOT preface with meta-commentary, do NOT echo reviewer fields, do NOT write any file.
First line of your response MUST be [FIXED], [NEEDS-FIX], or [IGNORABLE] (each verdict marker at column 1).
Format per issue: exactly three lines (verdict / Location: <path:line> / Evidence: <…>), records separated by a single blank line.
End your response with the ## Verification Summary table."
})
```

2. **Save verifier output** [Write]: write to `<WORKDIR>/iter-0-recheck-verdicts.md`

3. **Process** [Bash]:

```bash
set -euo pipefail
TOOLS=~/.ai-assistant/scripts/multi-review-tools.py
WORKDIR="<WORKDIR>"
ORIG_PRIOR_N=<PRIOR_N>
V_RAW="$WORKDIR/iter-0-recheck-verdicts.md"
RECHECK_ANN="$WORKDIR/iter-0-recheck-annotations.tsv"
ANN_TSV="$WORKDIR/iter-0-annotations.tsv"
TSV="$WORKDIR/iter-0-verdicts.tsv"
SIG="$WORKDIR/iter-0-needsfix.sig"

python3 $TOOLS parse-verifier-raw "$V_RAW" > "$RECHECK_ANN"
RECHECK_COUNT=$(wc -l < "$RECHECK_ANN" | tr -d ' ')

if (( RECHECK_COUNT > 0 )); then
  # Merge: drop old [NEEDS-FIX] rows, replace with recheck results
  awk -F'\t' '$2 !~ /NEEDS-FIX/' "$ANN_TSV" > "$WORKDIR/iter-0-ann-keep.tsv" || true
  cat "$WORKDIR/iter-0-ann-keep.tsv" "$RECHECK_ANN" > "$WORKDIR/iter-0-ann-merged.tsv"
  mv "$WORKDIR/iter-0-ann-merged.tsv" "$ANN_TSV"
  rm -f "$WORKDIR/iter-0-ann-keep.tsv"
  python3 $TOOLS derive-sidecars "$ANN_TSV" "$TSV" "$SIG"
  # Update iter-0-verified.md inline so merge picks up [FIXED] verdicts
  python3 $TOOLS reannotate "$WORKDIR/iter-0-verified.md" "$ANN_TSV" --in-place
fi

PRIOR_N=$(wc -l < "$SIG" | tr -d ' ')
RESOLVED=$((ORIG_PRIOR_N - PRIOR_N))
echo "ORIG_PRIOR_N=$ORIG_PRIOR_N RESOLVED=$RESOLVED PRIOR_N=$PRIOR_N"
```

Tell the user: `Carry-forward recheck: <RESOLVED> of <ORIG_PRIOR_N> previously [NEEDS-FIX] items already resolved; <PRIOR_N> remain.`

If the recheck verifier returns 0 records (format problem or agent failure), skip the merge, keep the original carry-forward, and continue into the loop.

---

### Step 4: Spawn reviewer [Agent] — Round `i` (initially `i=1`)

Compute this round's paths:
- `R` = `<WORKDIR>/iter-<i>-review.md`
- `PREV_V` = `<WORKDIR>/iter-<i-1>-verified.md`

Assemble the carry-forward hint:
- If PREV_V exists:

  ```
  Previous verified report: <PREV_V>.
  Skip any issue already marked [NONEXISTENT] there (reviewer hallucinations).
  Skip any issue already marked [FIXED] there (confirmed fixed in current code).
  Skip any issue already marked [IGNORABLE] (acknowledged but acceptable).
  For items still [NEEDS-FIX], you MAY re-report them if you have new evidence; otherwise omit.
  ```

- If Round 1 and the Step 3c recheck ran: append to the end of the hint above:

  ```
  CARRY-FORWARD RECHECK: <WORKDIR>/iter-0-recheck-verdicts.md contains fresh re-verification of all previously [NEEDS-FIX] items against the current code.
  Read it first. Items marked [FIXED] have been fixed — do NOT re-report them.
  ```

- If PREV_V does not exist: `No previous iteration.`

Call Agent:

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

Run after replacing `<R>`:

```bash
set -euo pipefail
R="<R>"
[[ -s "$R" ]] || { echo "REVIEWER_FAILED"; exit 1; }
grep -qE '^## (Critical Issues|Performance & Optimization|Maintainability & Architecture)' "$R" || { echo "REVIEWER_BAD_FORMAT"; exit 1; }
echo "REVIEWER_OK round <i>"
```

If the output is `REVIEWER_FAILED` or `REVIEWER_BAD_FORMAT`: **stop**, tell the user the reviewer failed at round `<i>`, and provide the `WORKDIR` path for a deep dive. Do not re-run.

### Step 6: Spawn verifier [Agent] — Round `i`

Compute:
- `PREV_ANN_TSV` = `<WORKDIR>/iter-<i-1>-annotations.tsv`

Assemble the verifier consistency hint:
- Round 2+ and PREV_ANN_TSV exists:

  ```
  CONSISTENCY ANCHOR: Read <PREV_ANN_TSV> first (3-col TSV: Location / previous verdict / previous Evidence).
  For each issue, look up by Location:
  - Found + code unchanged → carry previous verdict. Evidence: "Previous: [verdict] (reason); code unchanged."
  - Found + code changed → may flip, but Evidence MUST cite the specific change.
  - Not found → judge from scratch.
  Goal: stable verdicts. Flip without code-level justification is a bug. Do NOT Read prior reviewer report or verified.md.
  ```

- Round 1 or PREV_ANN_TSV missing: leave empty (omit the consistency anchor section).

Call Agent:

```
Agent({
  subagent_type: "multi-review-verifier",
  description: "multi-review verifier round <i>",
  model: <VERIFIER_MODEL if provided, else omit>,
  prompt: "Verify every issue in the review report against the actual code in <REPO_ROOT>.

Review report path: <R>

<VERIFIER_CONSISTENCY_HINT>

Your response back to me IS the verdicts list — do NOT preface with meta-commentary, do NOT echo reviewer fields, do NOT write any file.
First line of your response MUST be [NEEDS-FIX], [IGNORABLE], or [NONEXISTENT] (each verdict marker at column 1).
Format per issue: exactly three lines (verdict / Location: <path:line> / Evidence: <…>), records separated by a single blank line.
End your response with the ## Verification Summary table prescribed in your agent definition."
})
```

### Step 7: Save verifier output [Write]

Write the **complete response text** of the Step 6 verifier agent to `<WORKDIR>/iter-<i>-verdicts.md`:

```
Write(file_path="<WORKDIR>/iter-<i>-verdicts.md", content=<verifier's complete response text>)
```

### Step 8: Post-verifier processing [Bash]

Run after replacing every `<placeholder>`. Note `<i>` and `<i-1>` must be replaced with actual numbers:

```bash
set -euo pipefail
TOOLS=~/.ai-assistant/scripts/multi-review-tools.py
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

If the output is `VERIFIER_FORMAT_VIOLATION`: **stop**, tell the user the verifier violated the format at round `<i>`, and provide the `WORKDIR` path. Do not re-run.

### Step 9: Convergence check

Read Step 8's output and act on `SIGNAL`:

- `SIGNAL=CONVERGED`: tell the user `✓ Converged at round <i>: no [NEEDS-FIX] issues remain.` and **jump to Step 10**
- `SIGNAL=MAX_ITER_REACHED`: tell the user `● Reached max_iter=<MAX_ITER> with <NEEDS_FIX> [NEEDS-FIX] issue(s) remaining.` and **jump to Step 10**
- `SIGNAL=CONTINUE NEXT_ROUND=<N>`: tell the user `Round <i> done. Continuing to round <N>.`, **set `i=<N>` and go back to Step 4**

**CRITICAL**: if SIGNAL is CONTINUE, your next response must contain the Step 4 Agent tool call. Text-only output is not allowed.

---

### Step 10: Phase 2 — Final merge [Bash]

```bash
set -euo pipefail
python3 ~/.ai-assistant/scripts/multi-review-tools.py merge "<WORKDIR>" "<FINAL_REPORT>" "<STATS_TSV>"
echo "Final report: <FINAL_REPORT>"
```

If the merge fails: tell the user the merge phase failed and provide the `WORKDIR` path. Do not re-run.

### Step 11: Phase 3 — Summary + Report

1. **Get the summary table** [Bash]:

```bash
set -euo pipefail
python3 ~/.ai-assistant/scripts/multi-review-tools.py summary-table "<STATS_TSV>"
```

2. **Read the final report** [Read]: open `<FINAL_REPORT>`

3. **Report the results**:
   - The file is **cumulative**: each issue appears once (deduped by Location), with the verdict taken from the last round that judged it; the block content comes from the round where the issue first appeared (tagged `_(origin: iter-N)_`). Earlier rounds' `[IGNORABLE]` / `[NONEXISTENT]` items are preserved in the final report even when later rounds' reviewers skipped them
   - List every `[NEEDS-FIX]` item's **title + Location** (one per line), ordered `## Critical Issues` (P0) → `## Performance & Optimization` (P1) → `## Maintainability & Architecture` (P2); the section itself carries the severity semantics
   - Group by file which files need changes
   - Attach the per-round breakdown table (output of Step 11.1)
   - If the `[NONEXISTENT]` ratio > 30%, warn that the reviewer may be hallucinating and recommend manual spot-checks
   - If any `[IGNORABLE]` items are noteworthy, add one line: "the following are marked ignorable but worth knowing: ..."
   - End by giving the `.tasks/<BRANCH>/review.md` path (continuously updated across runs; used as the iter-0 anchor next run) and this run's timestamped intermediate directory `WORKDIR`

---

## Constraints

- **Never auto-fix files** — the user decides after reading the report
- Never re-run the loop. If the user wants another run, have them invoke the command again with new arguments
- If any step ABORTs: do not try to read `review.md`; do not extrapolate from partial artifacts
- Model parameters **accept aliases only** (`opus` / `sonnet` / `haiku`); if the user passes a full id, refuse and suggest an alias
- `MAX_ITER` is capped at 5 (context safety margin); if the user wants more, refuse and suggest splitting into multiple runs
- The first line of **every** Bash call MUST be `set -euo pipefail`
- Do **not** read `iter-N-review.md` or `iter-N-verified.md` into your own context to "analyze" them — use `count-sections` and `derive-sidecars` for structural checks
