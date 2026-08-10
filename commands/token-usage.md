---
description: "Calculate and summarize token usage & costs for coding agent CLIs (antigravity CLI, etc.). Supports daily, weekly, monthly, and session aggregations with USD cost calculation. Triggers: token usage, token 統計, token 用量, 用量計算, 花費計算, cost report, token report, /token-usage, agy token usage."
argument-hint: [daily|weekly|monthly|session] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--last N] [--json] [--no-cost] [--by-model] [--compact]
allowed-tools: run_command, view_file, write_to_file
---

# Token Usage Report Command

Calculate and aggregate token usage and cost metrics from local CLI conversation logs (`~/.gemini/tmp/*/chats/session-*.jsonl` and `~/.gemini/antigravity-cli/conversations/*.db`).

All Chinese output MUST follow the terminology table and typography rules in `~/.ai-assistant/shared/taiwan-terminology.md`.

---

## Inputs

- `MODE`: aggregation window — `daily` (default), `weekly`, `monthly`, or `session`.
- `OPTIONS`:
  - `--since YYYY-MM-DD`: Filter logs starting from date.
  - `--until YYYY-MM-DD`: Filter logs up to date.
  - `--last N`: Limit output to the last N periods (e.g. `--last 1` for today / this week).
  - `--json`: Format output as JSON data.
  - `--no-cost`: Omit USD cost calculation columns.
  - `--by-model`: Aggregate the whole window into one per-model table (`Model | Input | Cache | Output | Total | Cost`) instead of per-period rows. Rows sort by cost, or by total tokens with `--no-cost`.
  - `--compact`: Collapse each period to a single aggregate row instead of one row per model.

The default report prints one row per model within each period — `Date | Model | Input | Cache | Output | Total | Cost`, where `Cache` sums CacheWrite and CacheRead — with the period label shown once on its first model row.

---

## Execution Flow

### Step 1 — Run Token Usage Script

Run the Python token usage calculator script (`scripts/token_usage.py`):

```bash
python3 "$HOME/.ai-assistant/scripts/token_usage.py" $ARGUMENTS
```

If running within this repository checkout:

```bash
python3 scripts/token_usage.py $ARGUMENTS
```

### Step 2 — Display & Summarize Results

Present the ASCII table report or JSON summary clearly to the user. Highlight total input, cached read, output tokens, and total USD estimated cost.
