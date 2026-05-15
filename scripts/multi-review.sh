#!/usr/bin/env bash
# multi-review.sh — Iterative Claude-only code review loop.
#
# Usage:
#   bash ~/.claude/scripts/multi-review.sh \
#        [base_branch=main] [max_iter=3] \
#        [reviewer_model=claude-opus-4-6[1m]] [verifier_model=claude-opus-4-6[1m]]
#
# Model can be an alias (opus / sonnet / haiku) or a full id
# (e.g. claude-opus-4-7, claude-sonnet-4-6, claude-opus-4-6[1m]).
#
# Env vars REVIEWER_MODEL / VERIFIER_MODEL override the positional args,
# so wrappers (alias / slash command) can preset without editing args:
#   REVIEWER_MODEL=opus VERIFIER_MODEL=sonnet bash multi-review.sh main 3
#
# Flow per iteration (two Claude agents interacting):
#   1a. Claude reviewer (python-code-review skill) → iter-N-review.md
#   1b. Claude verifier (multi-review-verifier agent, read-only) → iter-N-verified.md
#       Annotates each issue with [需修正] / [可忽略] / [不存在] + Evidence.
#   1c. Stop when needs-fix count hits 0 OR max_iter is reached.
#
# Produces:
#   .tasks/{branch}/review.md            — cumulative final report (path
#                                          matches python-code-review skill).
#                                          Each issue appears once with its
#                                          latest verdict; [可忽略]/[不存在]
#                                          from earlier rounds are preserved.
#   .tasks/{branch}/review/iter-N-*.md   — per-round intermediates (raw)

set -euo pipefail

BASE="${1:-main}"
MAX_ITER="${2:-3}"

# Env vars override positional args so wrappers can pre-pin without rewriting
# the call site. Defaults: both reviewer and verifier on the 1M-context Opus
# variant — full diff + carry-forward anchor + prior verified.md easily
# exceeds 200k tokens on larger PRs.
REVIEWER_MODEL="${REVIEWER_MODEL:-${3:-claude-opus-4-6[1m]}}"
VERIFIER_MODEL="${VERIFIER_MODEL:-${4:-claude-opus-4-6[1m]}}"

# Heartbeat: emits "[HH:MM:SS] still <label>..." every 60s during long waits.
# Keeps Monitor / TTY users from thinking the script has hung.
HEARTBEAT_PID=""
start_heartbeat() {
  ( while :; do sleep 60; echo "[$(date +%H:%M:%S)] still $1..."; done ) &
  HEARTBEAT_PID=$!
}
stop_heartbeat() {
  if [[ -n "$HEARTBEAT_PID" ]] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  HEARTBEAT_PID=""
}
trap 'stop_heartbeat' EXIT INT TERM

# Script self-location (for resolving sibling agent definition + python tools).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER_AGENT_FILE="$SCRIPT_DIR/../agents/multi-review-verifier.md"
TOOLS="$SCRIPT_DIR/multi-review-tools.py"

[[ -f "$VERIFIER_AGENT_FILE" ]] || {
  echo "ERROR: verifier agent definition not found at $VERIFIER_AGENT_FILE" >&2
  exit 1
}
[[ -f "$TOOLS" ]] || {
  echo "ERROR: multi-review-tools.py not found at $TOOLS" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required (tools, merge, parsing all dispatch through it)." >&2
  exit 1
}

# Inline the verifier agent definition into the JSON shape `claude --agents`
# expects. Inlining lets the script run from any CWD without depending on the
# agent being installed globally.
AGENTS_JSON=$(python3 "$TOOLS" inline-agent "$VERIFIER_AGENT_FILE" \
  --name multi-review-verifier \
  --description 'Verify whether each issue in a code review report actually exists in the working tree.')

# --- Phase 0: Setup ---------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "ERROR: not inside a git repository." >&2
  exit 1
}
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Fail-fast before mkdir so the no-diff path leaves no empty folder behind.
if git -C "$REPO_ROOT" diff --quiet "${BASE}...HEAD"; then
  echo "No diff between $BRANCH and $BASE. Nothing to review."
  exit 0
fi

# Per-run subfolder so successive runs don't clobber each other's artifacts.
# The canonical final report path (used by python-code-review skill) is NOT
# per-run; we keep overwriting it on convergence and read it back next time
# as the carry-forward anchor.
RUN_TS=$(date +%Y%m%d_%H%M%S)
WORKDIR="$REPO_ROOT/.tasks/$BRANCH/review/$RUN_TS"
STATS_TSV="$WORKDIR/.round-stats.tsv"
FINAL_REPORT="$REPO_ROOT/.tasks/$BRANCH/review.md"
mkdir -p "$WORKDIR"
: > "$STATS_TSV"

# One git invocation, derive changed-files from the patch headers.
git -C "$REPO_ROOT" diff "${BASE}...HEAD" > "$WORKDIR/full-diff.patch"
git -C "$REPO_ROOT" diff --stat "${BASE}...HEAD" > "$WORKDIR/diff-stat.txt"
awk '/^diff --git / { sub(/^b\//, "", $4); print $4 }' "$WORKDIR/full-diff.patch" \
  | sort -u > "$WORKDIR/changed-files.txt"

echo "Repo:    $REPO_ROOT"
echo "Branch:  $BRANCH vs $BASE"
echo "Workdir: $WORKDIR"
echo "Files:   $(wc -l < "$WORKDIR/changed-files.txt" | tr -d ' ') changed"
echo "Models:  reviewer=$REVIEWER_MODEL  verifier=$VERIFIER_MODEL"
echo

# Read-only tool whitelist for reviewer and verifier sessions.
RO_TOOLS="Read,Bash(git:*),Bash(grep:*),Bash(rg:*),Bash(cat:*),Bash(find:*),Bash(wc:*),Bash(head:*),Bash(tail:*)"

# --- Helpers ---------------------------------------------------------------

# Abort the script with a clear error message + tail of the failing stage's stderr.
fail_stage() {
  local who="$1" rc="$2" errf="$3" round="$4"
  echo >&2
  echo "════════════════════════════════════════════════════════════" >&2
  echo "  ✗ ABORT: $who failed (exit=$rc) at Round $round" >&2
  echo "════════════════════════════════════════════════════════════" >&2
  if [[ -s "$errf" ]]; then
    echo "--- last 30 lines of $errf ---" >&2
    tail -30 "$errf" >&2
  else
    echo "(stderr file '$errf' is empty)" >&2
  fi
  echo >&2
  echo "Fix the issue and re-run. Partial artifacts left in: $WORKDIR" >&2
  exit 2
}

get_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# --- Shared prompt directive for both Claude agents ------------------------
# Both agents must NOT write files and must NOT prefix meta-commentary; their
# stdout response IS the captured report.
NO_FILE_NO_PREAMBLE='- Your stdout response IS the captured report.
- DO NOT add meta-commentary, preamble, status notes, or epilogue (no "outputting inline", no "Here is the report:", no "as instructed I have read...").
- DO NOT call Write/Edit/Save tools. DO NOT create or modify any file.
- Start your response with the report content itself (first line = top-level heading or first issue).'

REVIEWER_OUTPUT_DIRECTIVE="OUTPUT INSTRUCTIONS (override the skill default):
$NO_FILE_NO_PREAMBLE
- Ignore the skill text that says \"Write report to .tasks/{currentBranch}/review.md\". Treat stdout AS the report.
- If you previously wrote a review.md, treat that file as nonexistent for this run.
- Follow the skill Report Format with sections: Summary / Changelog / Critical Issues / Performance & Optimization / Maintainability & Architecture / Good Practices Observed.
- STRICT issue format inside Critical / Performance / Maintainability sections — the downstream verifier+splicer parses these by regex, ANY deviation breaks splice:
  * Start each issue with a top-level bullet: \`- **Issue Title**\` at column 0. DO NOT use \`### C1.\` / \`### P1.\` / \`### M1.\` h3 headers; DO NOT prefix with C1./P1./M1. codes.
  * The first sub-bullet of every issue MUST be exactly: \`  - **Location**: path/to/file.py:LINE\` (bold \`**Location**\`, NO surrounding backticks around the path).
  * Range form \`path:START-END\` is allowed; \` (deleted)\` suffix is allowed; nothing else may wrap the path."

VERIFIER_OUTPUT_DIRECTIVE="OUTPUT INSTRUCTIONS:
$NO_FILE_NO_PREAMBLE
- Do not attempt to write a verified.md — the script already captures your response.
- Output format (records + Verification Summary) is owned by your agent prompt; follow it.
- Each record's Location MUST match the corresponding reviewer issue's '**Location**:' field — the script uses it as splice key."

# --- Phase 0b: Carry-forward prior review.md as iter-0 anchor --------------
# Materialize iter-0 artifacts from the canonical FINAL_REPORT so Round 1 can
# reference prior judgments without recomputing them.
if [[ -f "$FINAL_REPORT" ]]; then
  cp "$FINAL_REPORT" "$WORKDIR/iter-0-verified.md"
  python3 "$TOOLS" extract-annotations "$WORKDIR/iter-0-verified.md" \
    > "$WORKDIR/iter-0-annotations.tsv"
  python3 "$TOOLS" derive-sidecars \
    "$WORKDIR/iter-0-annotations.tsv" \
    "$WORKDIR/iter-0-verdicts.tsv" \
    "$WORKDIR/iter-0-needsfix.sig"
  PRIOR_N=$(wc -l < "$WORKDIR/iter-0-needsfix.sig" | tr -d ' ')
  echo "Carry-forward: prior review.md found (PRIOR_N=$PRIOR_N [需修正]) → iter-0-verified.md"
  echo
fi

# --- Phase 1: Iteration loop ------------------------------------------------
for ((i=1; i<=MAX_ITER; i++)); do
  R="$WORKDIR/iter-${i}-review.md"
  V="$WORKDIR/iter-${i}-verified.md"
  V_RAW="$WORKDIR/iter-${i}-verdicts.md"
  ANN_TSV="$WORKDIR/iter-${i}-annotations.tsv"
  RE="$WORKDIR/iter-${i}-reviewer.err"
  VE="$WORKDIR/iter-${i}-verifier.err"
  SIG="$WORKDIR/iter-${i}-needsfix.sig"
  TSV="$WORKDIR/iter-${i}-verdicts.tsv"
  PREV_V="$WORKDIR/iter-$((i-1))-verified.md"
  PREV_ANN_TSV="$WORKDIR/iter-$((i-1))-annotations.tsv"
  PREV_SIG="$WORKDIR/iter-$((i-1))-needsfix.sig"
  PREV_TSV="$WORKDIR/iter-$((i-1))-verdicts.tsv"
  ITER_START=$(date +%s)

  echo
  echo "════════════════════════════════════════════════════════════"
  echo "  ▶ Round $i of $MAX_ITER"
  echo "════════════════════════════════════════════════════════════"

  # Asymmetry note: reviewer reads the full verified.md (needs prose context to
  # judge skip/re-report); verifier reads only $PREV_ANN_TSV. Do NOT "fix" this
  # asymmetry by also demoting reviewer — reviewer skips on text understanding,
  # verifier anchors purely by location.
  CARRY_HINT="No previous iteration."
  if [[ -f "$PREV_V" ]]; then
    CARRY_HINT="Previous verified report: $PREV_V.
Skip any issue already marked [不存在] there (reviewer hallucinations).
Skip any issue already marked [可忽略] (acknowledged but acceptable).
For items still [需修正], you MAY re-report them if you have new evidence; otherwise omit."
  fi

  # 1a. Claude reviewer ----------------------------------------------------
  echo "[$(date +%H:%M:%S)] launching claude reviewer (model=$REVIEWER_MODEL)..."
  start_heartbeat "claude reviewer (round $i)"
  set +e
  claude -p --model "$REVIEWER_MODEL" --add-dir="$REPO_ROOT" \
    --allowedTools="$RO_TOOLS" \
    "Use the python-code-review skill to review the diff between $BASE and HEAD on branch $BRANCH.
The full unified diff has been saved to: $WORKDIR/full-diff.patch
Changed files list: $WORKDIR/changed-files.txt
Working directory (read code from here): $REPO_ROOT

$CARRY_HINT

$REVIEWER_OUTPUT_DIRECTIVE" > "$R" 2>"$RE"
  RRC=$?
  set -e
  stop_heartbeat
  echo "[$(date +%H:%M:%S)] claude reviewer finished (exit=$RRC)"

  (( RRC != 0 )) && fail_stage "claude reviewer" "$RRC" "$RE" "$i"

  # Defensive recovery: if reviewer ignored the directive and wrote to the
  # skill's default path (also FINAL_REPORT) within this round, lift it back
  # to $R. Only rm the stray write — never the prior-run report.
  if ! grep -qE '^## (Critical Issues|Performance & Optimization|Maintainability & Architecture)' "$R" 2>/dev/null; then
    if [[ -f "$FINAL_REPORT" ]] && (( $(get_mtime "$FINAL_REPORT") > ITER_START )); then
      echo "  ⚠ reviewer wrote report to $FINAL_REPORT instead of stdout — recovering"
      cp "$FINAL_REPORT" "$R"
      rm -f "$FINAL_REPORT" 2>/dev/null || true
    fi
  fi

  [[ -s "$R" ]] || fail_stage "claude reviewer" 0 "$RE" "$i"

  read -r CC CP CM REVIEWER_LOC_COUNT < <(python3 "$TOOLS" count-sections "$R")

  echo
  echo "  Round $i reviewer findings:"
  printf '    Critical=%s  Performance=%s  Maintainability=%s\n' "$CC" "$CP" "$CM"

  # Carry-forward for the verifier: stabilize judgments across rounds.
  # Anchor is a compact 3-col TSV (loc / verdict / Evidence) so verifier input
  # doesn't carry the full prior reviewer report — anchoring is purely
  # location-keyed, prior reviewer body is not used in flip decisions.
  VERIFIER_CONSISTENCY_HINT=""
  if [[ -s "$PREV_ANN_TSV" ]]; then
    VERIFIER_CONSISTENCY_HINT="CONSISTENCY ANCHOR (previous round's verdicts):
Path: $PREV_ANN_TSV
Format: tab-separated, one row per previously-judged issue. Columns:
  1) Location  (e.g. services/cache.py:88)
  2) Previous verdict  (one of: 需修正 / 可忽略 / 不存在)
  3) Previous Evidence line  (the verifier's prior 'Evidence: …' wording)

Process:
1. Read $PREV_ANN_TSV FIRST. Build an internal map of {Location → (previous verdict, previous Evidence)}.
2. For each issue in the current review report, look up by 'Location: path:line':
   - If found AND the code at that Location is substantively unchanged since previous verification:
       → Carry the previous verdict forward. Do NOT flip.
       → Your Evidence line MUST reference the previous decision, e.g.:
         'Evidence: <file:line> — Previous: [可忽略] (<reason from column 3>); code unchanged, still applies.'
   - If found BUT the code at that Location has changed (issue fixed, refactored, or context shifted):
       → You MAY flip the verdict, but your Evidence MUST cite the specific change you observed:
         'Evidence: <file:line> — Previous: [需修正]; now <observed change>, therefore [不存在/可忽略].'
   - If NOT found in previous (new issue): judge from scratch as usual.
3. Goal: **stable verdicts across rounds**. A flip without code-level justification is a bug; prefer carry-forward when ambiguous.
4. Do NOT change a verdict based purely on re-thinking. Only evidence in the code allows flipping.
5. Do NOT Read the prior reviewer report or verified.md — the TSV has everything you need."
  fi

  # 1b. Claude verifier ----------------------------------------------------
  # The agent's own system prompt (agents/multi-review-verifier.md) owns the
  # protocol (markers, placement, Evidence format, summary table). The user
  # prompt below only injects per-run wiring (paths, consistency anchor).
  echo "[$(date +%H:%M:%S)] launching claude verifier (model=$VERIFIER_MODEL, read-only, emits verdicts only)..."
  start_heartbeat "claude verifier (round $i)"
  set +e
  claude -p --model "$VERIFIER_MODEL" --agents "$AGENTS_JSON" --agent multi-review-verifier --add-dir="$REPO_ROOT" \
    --allowedTools="$RO_TOOLS" \
    "Verify every issue in the review report against the actual code in $REPO_ROOT.

Review report path: $R

$VERIFIER_CONSISTENCY_HINT

$VERIFIER_OUTPUT_DIRECTIVE

Reminder: each verdict marker MUST begin at column 1 (no leading whitespace)." > "$V_RAW" 2>"$VE"
  VRC=$?
  set -e
  stop_heartbeat
  echo "[$(date +%H:%M:%S)] claude verifier finished (exit=$VRC)"

  if (( VRC != 0 )) || [[ ! -s "$V_RAW" ]]; then
    fail_stage "claude verifier" "$VRC" "$VE" "$i"
  fi

  # 1b'. Splice verdicts into reviewer report → $V ------------------------
  # Verifier emits annotation records only; we merge them mechanically here
  # to avoid the LLM round-tripping the entire reviewer report (incl. all
  # Suggested Code blocks) just to add 2 lines per issue.
  python3 "$TOOLS" parse-verifier-raw "$V_RAW" > "$ANN_TSV"

  RAW_ANN_COUNT=$(wc -l < "$ANN_TSV" | tr -d ' ')
  if (( RAW_ANN_COUNT == 0 )) && (( REVIEWER_LOC_COUNT > 0 )); then
    echo "verifier emitted 0 annotations but reviewer had $REVIEWER_LOC_COUNT issues — likely format violation" > "$VE"
    fail_stage "claude verifier" 0 "$VE" "$i"
  fi

  python3 "$TOOLS" splice "$R" "$ANN_TSV" > "$V"

  # Append Verification Summary (carry V_RAW's if present, else synthesize).
  echo "" >> "$V"
  python3 "$TOOLS" verification-summary "$V_RAW" "$ANN_TSV" >> "$V"

  # 1c. Stop check ---------------------------------------------------------
  # Project current round's ANN_TSV into the 2-col verdicts TSV + needs-fix sig
  # that downstream diff-rounds consumes.
  python3 "$TOOLS" derive-sidecars "$ANN_TSV" "$TSV" "$SIG"

  # diff-rounds emits one KEY=VAL line per metric (NEW/RESOLVED/CARRIED/FLIPPED
  # + N_NEEDS_FIX/N_IGNORED/N_NONEXISTENT). Capture stdout first so a failure
  # produces a clear ABORT instead of an empty eval that leaves the downstream
  # printf to die on set -u with the real error lost in stderr.
  FLIPS_FILE="$WORKDIR/iter-${i}-flips.txt"
  DIFF_PREV_ARGS=()
  [[ -f "$PREV_TSV" ]] && DIFF_PREV_ARGS+=(--prev-tsv "$PREV_TSV")
  [[ -f "$PREV_SIG" ]] && DIFF_PREV_ARGS+=(--prev-sig "$PREV_SIG")
  DE="$WORKDIR/iter-${i}-diff-rounds.err"
  set +e
  # bash 3.2 (macOS /bin/bash) raises "unbound variable" under set -u when an
  # empty array is expanded as "${arr[@]}"; the ${arr[@]+…} guard keeps the
  # expansion silent in that case and behaves identically on bash 4.4+.
  DIFF_OUT=$(python3 "$TOOLS" diff-rounds \
    ${DIFF_PREV_ARGS[@]+"${DIFF_PREV_ARGS[@]}"} \
    --curr-tsv "$TSV" --curr-sig "$SIG" \
    --flip-detail-out "$FLIPS_FILE" 2>"$DE")
  DRC=$?
  set -e
  (( DRC != 0 )) && fail_stage "diff-rounds" "$DRC" "$DE" "$i"
  while IFS='=' read -r _key _val; do
    declare "$_key=$_val"
  done <<< "$DIFF_OUT"
  FLIP_DETAIL=""
  [[ -s "$FLIPS_FILE" ]] && FLIP_DETAIL=$(cat "$FLIPS_FILE")

  echo
  echo "  Round $i verification:"
  printf '    需修正=%s  可忽略=%s  不存在=%s\n' "$N_NEEDS_FIX" "$N_IGNORED" "$N_NONEXISTENT"
  printf '    新增[需修正]=%s   上輪→本輪已消解=%s\n' "$NEW" "$RESOLVED"
  if [[ -f "$PREV_V" ]]; then
    printf '    一致性: 沿用=%s  翻盤=%s\n' "$CARRIED" "$FLIPPED"
    if [[ -n "$FLIP_DETAIL" ]]; then
      echo "    Flipped judgments (should each have code-evidence in verified.md):"
      echo "$FLIP_DETAIL"
    fi
  fi

  # Persist per-round stats. Phase 2 replays this TSV instead of re-counting
  # so the live numbers above and the final table can't drift.
  printf '%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n' \
    "$i" "$CC" "$CP" "$CM" "$N_NEEDS_FIX" "$N_IGNORED" "$N_NONEXISTENT" "$NEW" >> "$STATS_TSV"

  # Stop on convergence (no needs-fix remaining) OR max_iter exhausted.
  if (( N_NEEDS_FIX == 0 || i == MAX_ITER )); then
    echo
    if (( N_NEEDS_FIX == 0 )); then
      echo "✓ Converged at iter $i: no [需修正] issues remain."
    else
      echo "● Reached max_iter=$MAX_ITER with $N_NEEDS_FIX [需修正] issue(s) remaining."
    fi
    break
  fi

  echo
done

# --- Phase 1d: Build cumulative final report --------------------------------
# Merge all iter-N-verified.md (N >= 1) into a single review.md where each
# issue (keyed by Location) appears once with its LATEST verdict and the
# block content from the iter that first introduced it. Preserves [可忽略]
# items from earlier rounds that subsequent rounds' reviewer would skip.
if ! python3 "$TOOLS" merge "$WORKDIR" "$FINAL_REPORT" "$STATS_TSV" 2>"$WORKDIR/merge.err"; then
  echo >&2
  echo "════════════════════════════════════════════════════════════" >&2
  echo "  ✗ ABORT: cumulative merge failed" >&2
  echo "════════════════════════════════════════════════════════════" >&2
  [[ -s "$WORKDIR/merge.err" ]] && { echo "--- merge stderr ---" >&2; cat "$WORKDIR/merge.err" >&2; }
  echo "Partial artifacts left in: $WORKDIR" >&2
  exit 3
fi
echo "Final report: $FINAL_REPORT"

# --- Phase 2: Summary table -------------------------------------------------
# Pure replay of the Phase 1 TSV — no re-counting, no path re-derivation.
echo
echo "Per-round breakdown:"
python3 "$TOOLS" summary-table "$STATS_TSV"
echo
echo "Artifacts in: $WORKDIR"
