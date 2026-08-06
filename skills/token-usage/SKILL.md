---
name: token-usage
description: "Calculate and aggregate token usage and cost metrics for coding agent CLIs (antigravity CLI, etc.). Supports daily, weekly, monthly, and session aggregations with USD cost calculation. Activate when asked for token usage, token 統計, token 用量, 用量計算, 花費計算, cost report, token report, or agy token usage."
allowed-tools: run_command, view_file
---

# Token Usage Skill

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
  - `--breakdown`: Include per-model breakdown rows.

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
