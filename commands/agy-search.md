---
description: Run a headless web-research query through the Antigravity CLI (`agy` → Gemini) as a second search engine — for when Claude's own WebSearch/WebFetch is blocked by anti-bot / Cloudflare walls, or when you want an independent engine to cross-verify a finding. Applies a research-method prefix and runs from a clean temp dir so project-local rules don't contaminate the query. Triggers: agy search, 用 agy 查, Gemini search / Gemini 搜尋, second search engine / 第二搜尋引擎, second opinion, cross-verify / 交叉驗證, anti-bot / Cloudflare blocked, 搜尋被擋 / 搜不到, search the web, 上網搜尋, 查資料, look up, latest / 最新, docs, research.
argument-hint: <research question> [name a model, e.g. "use Flash"]
allowed-tools: Bash, Write
---

# Agy Search

Delegate a web-research query to the **Antigravity CLI** (`agy`, Google's subscription CLI for Gemini and other models) and relay its findings. The value: when a page blocks Claude's built-in search behind anti-bot / Cloudflare, Gemini's search stack often gets through; and even when both work, a second independent engine is useful for cross-verification.

**When to reach for this** — prefer Claude's built-in `WebSearch` / `WebFetch` first. Escalate to `/agy-search` when those return anti-bot / Cloudflare walls, come back empty on a query you know should have hits, or when the user explicitly wants a Gemini second opinion. This call spends the user's Gemini subscription quota and can take minutes — do not use it for lookups Claude's own tools already answered.

All Chinese output follows the terminology table and typography rules in `~/.ai-assistant/shared/taiwan-terminology.md`.

---

## Inputs

- `QUERY`: the research question — `$ARGUMENTS` **minus any model directive**. A phrase like "use flash" / "用 opus" configures `MODEL`; it is not part of the question and must NOT be sent to agy. **Required**; if empty (or empty after stripping the directive), ask the user what to research and stop.
- `MODEL`: default `Gemini 3.1 Pro (High)` (strongest Gemini reasoning model, best for research). Override only if the user names one:
  - "flash" / "fast" / "cheap" → `Gemini 3.5 Flash (High)`
  - "opus" → `Claude Opus 4.6 (Thinking)`, "sonnet" → `Claude Sonnet 4.6 (Thinking)`
  - an exact model string → pass through verbatim
  - Whatever is chosen is validated against the Step 1 `agy models` output before the long call.
- `PREFIX`: `~/.ai-assistant/shared/research-prefix.md` — the research-method prompt prepended to every query.

---

## Execution Flow

### Step 1 — Preflight [Bash]

```bash
set -euo pipefail
PREFIX="$HOME/.ai-assistant/shared/research-prefix.md"
command -v agy >/dev/null 2>&1 || { echo "AGY_MISSING"; exit 0; }
[ -f "$PREFIX" ] || { echo "PREFIX_MISSING"; exit 0; }
WORKDIR="$(mktemp -d)"
echo "WORKDIR=$WORKDIR"
echo "---MODELS---"
agy models
echo "OK"
```

- `AGY_MISSING`: tell the user the Antigravity CLI is not on `PATH`; point them at its install (`agy` is normally at `~/.local/bin/agy`) and abort. Do not attempt a fallback.
- `PREFIX_MISSING`: the research prefix is missing — the repo is likely not installed to `~/.ai-assistant`. Tell the user and abort.
- Otherwise remember `WORKDIR`, and **validate `MODEL` against the `---MODELS---` list** (exact line match) before the long call:
  - user-named model not in the list → show the list, confirm the intended one, do not run yet.
  - the default `Gemini 3.1 Pro (High)` not in the list (agy changed its lineup) → pick the closest Gemini Pro tier from the list, tell the user which one you picked, and continue.

### Step 2 — Write the query [Write]

Write the **raw `QUERY` text verbatim** (no shell escaping, no edits) to `<WORKDIR>/query.txt` using the Write tool. Writing to a file — rather than interpolating into the shell — is deliberate: it keeps arbitrary quotes, `$`, and backticks in the query from breaking the Step 3 command.

### Step 3 — Run agy from a clean dir [Bash — set the tool `timeout` to 600000 (10 min)]

Replace `<WORKDIR>` and `<MODEL>`, then run. The `cd` into a fresh temp dir is what isolates the query: any project-local `AGENTS.md` / `GEMINI.md` in the real working tree is skipped, so only the global system prompt and the research prefix shape the answer.

```bash
set -euo pipefail
PREFIX="$HOME/.ai-assistant/shared/research-prefix.md"
WORKDIR="<WORKDIR>"
trap 'cd /; rm -rf "$WORKDIR"' EXIT
{ cat "$PREFIX"; printf '\n\n'; cat "$WORKDIR/query.txt"; } > "$WORKDIR/prompt.txt"
cd "$WORKDIR"
STATUS=0
agy -p "$(cat "$WORKDIR/prompt.txt")" --model "<MODEL>" --print-timeout 9m || STATUS=$?
echo "===AGY_EXIT=$STATUS==="
```

`--print-timeout 9m` sits just under the 10-min Bash timeout, leaving room for cleanup. The `trap … EXIT` cleans the temp dir on any exit path — success, `set -e` abort, or agy failure. agy prints its full response to stdout; that response is agy's answer to relay — everything before the `===AGY_EXIT=N===` trailer.

### Step 4 — Report

- **`AGY_EXIT=0`**: relay agy's findings to the user. It is already conclusion-first and source-attributed (the prefix enforces that) — do **not** rewrite or re-summarize it away; preserve every source name and information date. Prefix your relay with one line naming the engine, e.g. `> 來源：agy（<MODEL>）`. If the answer is thin or sourceless, say so plainly rather than dressing it up. You may add a short cross-check against Claude's own knowledge, clearly separated and labelled as Claude's view vs. Gemini's.
- **Nonzero exit**: relay the error and act on the likely cause:
  - auth / sign-in expired → have the user re-authenticate the Antigravity CLI (sign in via the Antigravity app / `agy` login flow), then retry.
  - timeout (hit `--print-timeout`) → suggest narrowing the query or rerunning with `Gemini 3.5 Flash (High)`.

---

## Constraints

- **Relay, don't invent**: report only what agy returned. Never fabricate sources or fill gaps from memory to make the answer look complete.
- **One query per invocation**: for a follow-up, invoke the command again with the refined question. (Interactive `agy --continue` sessions are out of scope.)
- **Always run from the temp dir** and always `rm -rf` it afterward — never run agy from the project root (project rules would contaminate a pure-research query).
- **Quota-aware**: each run consumes the user's Gemini subscription quota and may take minutes. Don't invoke it speculatively or loop it.
- **Never write the query into the shell string directly** — it goes through `<WORKDIR>/query.txt` (Step 2) to stay quoting-safe.

---

## Edge Cases

| Situation | Handling |
|---|---|
| `$ARGUMENTS` empty | Ask what to research; do not run agy. |
| `agy` not on PATH | Report `AGY_MISSING`; point at the Antigravity CLI install; abort. |
| research prefix missing | Report `PREFIX_MISSING`; the repo isn't installed to `~/.ai-assistant`; abort. |
| query contains quotes / `$` / backticks | Handled — it lives in `query.txt`, never inlined into the shell. |
| auth / subscription expired | Relay the error; user re-authenticates the Antigravity CLI, then retry. |
| run exceeds `--print-timeout` | Relay timeout; suggest a narrower query or `Gemini 3.5 Flash (High)`. |
| user names an unknown model | Caught at Step 1 preflight (`agy models`); show valid names; confirm before running. |
| default model missing from `agy models` (lineup changed) | Pick the closest Gemini Pro tier from the list; tell the user; continue. |
| agy returns an empty / low-signal answer | Say so directly; suggest reframing the query or trying Claude's own tools. |
