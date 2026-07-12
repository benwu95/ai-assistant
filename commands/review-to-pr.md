---
description: Sync a local review.md into the matching GitHub PR as bundled inline review comments (skipping items already covered by existing PR comments); also verifies the user's prior PR threads and offers to resolve those whose underlying issues are now fixed.
argument-hint: [review_path]
allowed-tools: Bash(gh:*), Bash(git:*), Bash(jq:*), Bash(cat:*), Bash(ls:*), Bash(echo:*), Bash(mkdir:*), Read, Write, Edit, AskUserQuestion
---

# Review-to-PR

Take the issues captured in a local `review.md` (the merged report produced by multi-review / code review) that are **not yet covered by the target PR's existing comments**, and submit them to the GitHub PR as one bundled set of inline review comments.

Additionally: **before posting new comments, inspect the PR's review threads opened by the current user (`authUser`) that are still `unresolved`**, check each against the current code, and — after asking the user — `resolve` the ones already fixed (or acknowledged by the author as intentionally not done).

The flow emphasizes:
- **No auto-fixing files, no auto-submitting** — the user must see a preview and explicitly agree before anything is sent
- **No auto-resolving threads** — even when an item shows as fixed, the user must confirm before the `resolveReviewThread` mutation runs
- Each comment body is bulleted, written in Traditional Chinese (Taiwan) with technical terms kept in English
- When quoting existing PR commenters: if that user is the current gh CLI auth account, rewrite as 「我」; otherwise keep `@username`

---

## Inputs

- `review_path` (positional, optional): path of the review report to read
  - If the user passes an argument, use that path
  - Otherwise auto-discover in this order:
    1. `.tasks/{currentBranch}/review-merged.md`
    2. `.tasks/{currentBranch}/review.md`
  - Neither found → ask the user to specify a path explicitly, then abort
- `currentBranch`: `git rev-parse --abbrev-ref HEAD`
- `prNumber`: from `gh pr list --head {currentBranch} --state open --json number --jq '.[0].number'`; no matching PR → notify and abort
- `authUser`: `gh api user --jq .login`, the identity substituted as 「我」
- `workDir`: `.tasks/{currentBranch}/review-to-pr/`, home of all intermediates and JSON payloads (`mkdir -p` it; follows the `.tasks/` artifact convention — not `/tmp`, which the system may clean)

---

## Execution Flow

### Phase 1 — Context Retrieval

Run in parallel (multiple Bash tool calls in a single message):

1. `git rev-parse --abbrev-ref HEAD` → currentBranch
2. `gh pr list --head {currentBranch} --state open --json number,title,url,headRefOid` → prNumber, headRefOid, PR URL
3. `gh api user --jq .login` → authUser
4. Read the review file (path per the Inputs rules)

If the PR does not exist / the review file cannot be found → tell the user in one sentence and abort; do not guess.

### Phase 2 — Fetch existing PR comments + review threads

Run in parallel:

1. **Inline review comments**:
   ```
   gh api repos/{owner}/{repo}/pulls/{prNumber}/comments --paginate \
     --jq '[.[] | {id, user: .user.login, path, line, original_line, body}]'
   ```
2. **Issue-level (PR conversation) comments**:
   ```
   gh api repos/{owner}/{repo}/issues/{prNumber}/comments --paginate \
     --jq '[.[] | {id, user: .user.login, body}]'
   ```
3. **PR reviews** (including review-level bodies, e.g. the overall message on an approval / changes-requested):
   ```
   gh api repos/{owner}/{repo}/pulls/{prNumber}/reviews --paginate \
     --jq '[.[] | {id, user: .user.login, state, body}]'
   ```
4. **Review threads (GraphQL, with resolve state)**: the REST API exposes neither thread node ids nor `isResolved`, but Phase 3's resolve action requires thread node ids, so hit GraphQL here:
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
   - If `pageInfo.hasNextPage == true` → continue with `-F cursor={endCursor}`
   - Write the result to `{workDir}/pr-{prNumber}-threads.json`; Phases 3 and 4 both use it

> Get owner/repo from `gh repo view --json owner,name --jq '.owner.login + "/" + .name'`.

### Phase 3 — Verify `authUser`'s existing threads; interactive resolve

> Close out finished old threads before posting new comments — kinder to the PR author than flooding new comments first and resolving afterwards (same notification, same view).

**Goal**: find review threads on the PR opened by `authUser` (yourself) that are still `isResolved=false`, check each against the current code, and — with the user's consent — batch-`resolveReviewThread` the ones that are fixed or explicitly acknowledged by the author as won't-do.

#### Step 3.1 — Filter candidates

Filter `{workDir}/pr-{prNumber}-threads.json` from Phase 2:

```bash
jq -r '.nodes[]
  | select(.comments.nodes[0].author.login == "{authUser}"
           and .isResolved == false)
  | "\(.id)\t\(.path)\t\(.line // .originalLine)\t\(.comments.nodes[0].pullRequestReview.databaseId)"' \
  {workDir}/pr-{prNumber}-threads.json > {workDir}/pr-{prNumber}-resolve-candidates.tsv
```

Each line: `thread_id`, `path`, `line`, `root_review_id`.

#### Step 3.2 — Classify each candidate

Judge the current code state per candidate. Either strategy:

- **Small batch (≤ 10)**: the main agent reads and compares directly, tagging each item's `verdict`
- **Large batch (> 10)**: hand off to the `multi-review-verifier` subagent for batch verification, returning each item's `verdict`

Each `verdict` is one of four:

| Verdict | Meaning | Default resolve candidate |
|---------|---------|---------------------------|
| `[FIXED]` | the current code directly / equivalently resolves the issue the thread raised | **yes** (pre-checked) |
| `[WONT-FIX]` | code unchanged, but later replies show the author explained why, and the user did not push back | **yes** (pre-checked) |
| `[DISPUTED]` | the author replied but the reasoning is unconvincing or needs follow-up — no technical consensus yet | **no** (unchecked; flag for manual follow-up) |
| `[UNFIXED]` | the original problem remains in the code and the author has not replied | **no** (unchecked; usually means not yet addressed) |

Judgment aids:
- Every comment in the thread is `authUser`'s own with no author reply → most likely `[UNFIXED]` or `[FIXED]`, decided by the code state
- The author's last reply contains "fixed" / "done" / "removed" / "updated" / "many thanks" or similar → verify the code, then mark `[FIXED]`
- The author's reply gives an explicit design trade-off ("current AC doesn't support it", "revisit when multi-file lands", etc.) → `[WONT-FIX]`
- Exclude threads the user just submitted within this very flow — their `root_review_id` equals the review id Phase 7 is about to create (nonexistent at Phase 3 time, nothing to handle); but leftovers from a previous same-purpose review payload, still unresolved, do become candidates and their verdicts decide

#### Step 3.3 — Preview and interaction

Use **AskUserQuestion** with 4 options (consistent every round):

1. **View classification** — show the candidate threads grouped by verdict, marking which are pre-checked
2. **Adjust selection** — ask for indices + action (add to / remove from the resolve list)
3. **Execute resolve** — batch `resolveReviewThread` on the currently selected threads
4. **Skip resolve step** — resolve nothing, go straight to Phase 4

Never resolve `[DISPUTED]` / `[UNFIXED]` on the user's behalf — even when there are only a few, the user must add them explicitly.

#### Step 3.4 — Execute resolve (user picks 3)

```bash
while IFS=$'\t' read -r thread_id path line; do
  gh api graphql \
    -f query='mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { id isResolved }
      }
    }' -f id="$thread_id" \
    --jq '.data.resolveReviewThread.thread.isResolved' \
    && echo "✓ $path:$line" \
    || echo "✗ $path:$line"
done < {workDir}/pr-{prNumber}-resolve-final.tsv
```

> **Note**: some shell environments lack `gh` on `$PATH` (e.g. sandboxed subshells). If calling `gh` directly fails, resolve its absolute path with `command -v gh` first; never hardcode an install path.

Afterwards report `resolved=N failed=M` and list the failed path:line entries (usually a thread someone else resolved first, or network issues).

#### Step 3.5 — Continue

Whichever branch the user chose, proceed to **Phase 4**. Keep the resolve results (verdict classification and actual resolved count) for the final summary.

---

### Phase 4 — Diff review vs PR

Parse the review report into an issue list (each with file, line, title, problem statement, suggested fix).

For each review issue, decide whether the PR already covers it:

**Coverage test (any one condition suffices)**:
- A PR inline comment within ±20 lines in the same file whose body is semantically close to the issue's title or key terms
- A PR issue-level / review-level body mentions the issue's key location or topic
- **Threads just resolved in Phase 3 also count as covered** — that loop is closed; no need to post again

When uncertain, **err toward "covered" and put the item on the `skipped` list** for the user to eyeball at the end. Don't re-post what the PR already said; don't claim coverage for what it never mentioned.

**Comparison output** (internal data for later steps):
- `to_post`: found by the review, absent from the PR → to be posted
- `skipped`: found by the review, already approximated by the PR → not posted, but mentioned in the final summary
- `not_in_review`: raised on the PR but missed by the review → untouched, though the summary may note "the PR raises these points the review missed"

### Phase 5 — Generate inline comment bodies

Each `to_post` item gets a markdown body in this style:

**Structure** (fixed template; the labels are literal Traditional Chinese output):

```
**[P{priority}] {標題}**

{optionally 1-2 sentences of background, or jump straight to the problem}

**問題**：
- bullet 1
- bullet 2
- ...

**建議**：
- bullets or a short paragraph
- optionally a `code block` (keep it minimal — only the key lines)
```

**Length**: keep each body within ~150 Chinese characters (code blocks excluded). Code blocks show the key lines only, never a whole diff.

**Language** (follow the terminology table and typography rules in `~/.ai-assistant/shared/taiwan-terminology.md`):

- Traditional Chinese, Taiwan usage
- Technical terms stay in English: lock / race / commit / SQS / DB session / identity map / atomic UPDATE / context manager / closure / generator, etc.
- Inline code / paths / identifiers in backticks
- **Half-width spaces around English words in mixed text** (e.g. `獨立 Session 審查機制`, `改用 SELECT FOR UPDATE`)
- Full-width punctuation (，。、：；「」); half-width punctuation is acceptable around English proper nouns

**Cross-link rules**:
- When a comment must reference an existing PR commenter:
  - that user == `authUser` → rewrite as 「我」 (e.g. 「呼應我在 `validation:85` 的評論」)
  - otherwise keep `@username` (e.g. 「呼應 @other-user 在 `validation:85` 的評論」)
- Keep git commit SHAs (e.g. `e2201cfff`) verbatim

**Priority tag**: take P0/P1/P2 from the review.md headings / table and prefix `[P{level}]`. Omit when absent.

**Code block rules**:
- Wrap Python code in ```` ```python ````
- Normal indentation
- Don't Python-escape `}}` inside f-strings; write it as-is
- Mind JSON escaping when strings contain Chinese (handled at payload-generation time)

### Phase 6 — Preview & interaction loop

Enter an interactive loop; **each round uses AskUserQuestion** with a fixed set of 4 options:

1. **View content** — list `to_post` as `[#N | P{level}] {file}:{line} — {title}`, one per line; then ask which full bodies to show ("all", "P0 only", "indices 1,3,5", "index 1", "skip and send"). Echo the chosen items as markdown blockquotes.
2. **Edit content** — ask which items to change (index + what). Common patterns:
   - delete some items
   - rewrite a body (the user describes the direction verbally; you rewrite)
   - change the anchor line
   - shorten everything / make everything plainer
   - merge some items / split one
   After editing, **return to the top of the loop** and re-show the main question (never auto-send).
3. **Send to GitHub** — proceed to Phase 7.
4. **Cancel** — abort. Keep the JSON payload at `{workDir}/review-to-pr-{prNumber}.json` and tell the user the path for manual follow-up.

Loop until the user picks Send or Cancel. **Never decide for the user**; even after every P2 has been viewed, return to the main question and wait for an explicit decision.

> **Special case: `to_post` empty** — if Phase 4 finds nothing new to post (everything covered by existing comments or threads just resolved in Phase 3), skip Phase 6, tell the user "nothing new to send", and use Phase 3's resolve results as the final summary.

### Phase 7 — Submit

Assemble all `to_post` items into a single review payload:

```json
{
  "commit_id": "{headRefOid}",
  "event": "COMMENT",
  "body": "{overall summary: P0/P1/P2 counts and a one-line topic overview}",
  "comments": [
    {"path": "...", "line": N, "body": "..."},
    ...
  ]
}
```

Write it to `{workDir}/review-to-pr-{prNumber}.json`, then:

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{prNumber}/reviews \
  --input {workDir}/review-to-pr-{prNumber}.json \
  --jq '{id, state, html_url, submitted_at}'
```

**Verify landing**:

```bash
gh api repos/{owner}/{repo}/pulls/{prNumber}/comments --paginate \
  --jq '[.[] | select(.pull_request_review_id == {review_id})] | length'
```

Report (merging Phase 3 + Phase 7 results):
- **Phase 3**: candidate thread count, verdict class counts, actual resolved count, summary of threads left unresolved
- **Phase 7**: review URL, number of inline comments landed, whether it matches expectations (if not, list which items didn't land)
- `skipped` summary (so the user knows which review findings were already raised on the PR and thus not sent)

---

## Taiwan Terminology (mandatory)

Follow the terminology table and typography rules in `~/.ai-assistant/shared/taiwan-terminology.md`.

---

## Constraints

- **Never modify anything on the PR before submit / resolve** — Phases 1-4 are strictly read-only.
- **Never submit a review without the user's explicit consent.** Even when `to_post` is empty, explicitly tell the user "nothing new to send" and wait for confirmation.
- **Never resolve any thread without the user's explicit consent.** In Phase 3, `[FIXED]` / `[WONT-FIX]` verdicts only mean "pre-checked"; the mutation fires only after the user picks "Execute resolve".
- **Never resolve threads not opened by `authUser`** — this command only handles the user's own old comments; it does not close other people's conversations.
- **Never resolve threads newly created by this run** (review_id equal to Phase 7's review id).
- **Never re-run multi-review.** This command only syncs an existing review.md to the PR.
- **Never edit the local review.md.** If its content looks wrong, tell the user and let them decide whether to go back and fix it.
- **No force push, no closing the PR, no approve / request changes, no unresolving threads.** The event type is always `COMMENT`.
- If `gh` is unauthenticated or lacks permission → no workarounds; report the error and point the user at `gh auth login`.
- If commit_id is stale at submit time (a new push landed while preparing) → re-fetch headRefOid and resend; bodies unchanged.
- For large files / many issues, always `--paginate` every `gh api` call (GraphQL: follow `pageInfo.hasNextPage`).
- Write JSON payloads to `{workDir}/` with the Write tool; don't echo large escaped strings in the shell.
- If `$PATH` is broken (a subshell can't find `gh`), use the absolute path from `command -v gh`; never hardcode an install path.

---

## Edge Cases

| Situation | Handling |
|------|------|
| review.md has no explicit P0/P1/P2 tags | no priority prefix; keep the review's ordering |
| a review issue lacks file:line | tell the user it's skipped, list it under `skipped` with the reason |
| a review issue's file is not in the PR diff | still try to send (GitHub falls back to a file-level comment); on API 422, mark it failed and list it |
| one review issue spans multiple files | split into one inline comment per file, cross-linked in the bodies |
| the PR is already closed / merged | warn the user and ask whether to send anyway (usually don't) |
| `to_post` empty | skip the Phase 5/6 loop, but still run Phase 3 for old threads and merge into the final summary |
| no unresolved threads opened by `authUser` | skip Phase 3, note "no old threads of your own to handle", go straight to Phase 4 |
| all Phase 3 candidates are `[UNFIXED]` / `[DISPUTED]` | still show the classification, but the "Execute resolve" list defaults to empty; no mutation unless the user opts in |
| `resolveReviewThread` returns `null` / errors | usually already resolved by someone else, or the thread id died (PR rebased and threads regenerated); add to the failure list and continue |
| the review was written by another reviewer (not `authUser`) | flow unaffected; the mention rule still keys on whether the mentioned user is authUser |
| review.md quotes other commenters (`@username`) | if that username == authUser rewrite as 「我」; otherwise keep it |
