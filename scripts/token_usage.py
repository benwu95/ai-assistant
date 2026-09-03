#!/usr/bin/env python3
"""
Token Usage Calculator for AI Coding Assistant CLIs (Antigravity CLI, etc.)
Includes cumulative context window prefill calculation per LLM turn.
"""

import os
import sys
import glob
import json
import sqlite3
import argparse
import re
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Any, Optional, Tuple, Set

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
PRICING_FILE = os.path.join(PROJECT_ROOT, "shared", "token-pricing.json")

# Base system prompt + instructions + default tools context size estimate (~2500 tokens)
BASE_SYSTEM_PROMPT_TOKENS = 2500


def load_pricing_config() -> Dict[str, Any]:
    """Load model pricing map from shared/gemini-pricing.json."""
    if os.path.exists(PRICING_FILE):
        try:
            with open(PRICING_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"Warning: Failed to load pricing config from {PRICING_FILE}: {e}", file=sys.stderr)
    return {
        "models": {
            "gemini-3.8-flash": {"input_cost_per_token": 7.5e-7, "cache_read_input_token_cost": 7.5e-8, "output_cost_per_token": 3.75e-6},
            "gemini-3.7-flash": {"input_cost_per_token": 7.5e-7, "cache_read_input_token_cost": 7.5e-8, "output_cost_per_token": 3.75e-6},
            "gemini-3.6-flash": {"input_cost_per_token": 7.5e-8, "cache_read_input_token_cost": 1.875e-8, "output_cost_per_token": 3e-7},
            "gemini-3.5-flash": {"input_cost_per_token": 7.5e-8, "cache_read_input_token_cost": 1.875e-8, "output_cost_per_token": 3e-7},
            "gemini-3.5-flash-lite": {"input_cost_per_token": 2.5e-8, "cache_read_input_token_cost": 6.25e-9, "output_cost_per_token": 1e-7},
            "gemini-3.1-flash-lite": {"input_cost_per_token": 2.5e-8, "cache_read_input_token_cost": 6.25e-9, "output_cost_per_token": 1e-7},
            "gemini-3.1-pro-preview": {"input_cost_per_token": 1.25e-6, "cache_read_input_token_cost": 3.125e-7, "output_cost_per_token": 5e-6},
            "gemini-2.5-pro": {"input_cost_per_token": 1.25e-6, "cache_read_input_token_cost": 3.125e-7, "output_cost_per_token": 5e-6},
            "gemini-2.5-flash": {"input_cost_per_token": 7.5e-8, "cache_read_input_token_cost": 1.875e-8, "output_cost_per_token": 3e-7},
            "gemini-2.5-flash-lite": {"input_cost_per_token": 2.5e-8, "cache_read_input_token_cost": 6.25e-9, "output_cost_per_token": 1e-7},
        },
        "default": {"input_cost_per_token": 7.5e-8, "cache_read_input_token_cost": 1.875e-8, "output_cost_per_token": 3e-7}
    }


class TokenEntry:

    def __init__(
        self,
        timestamp: datetime,
        session_id: str,
        model: str,
        raw_input: int,
        cached_input: int,
        output: int,
        thoughts: int = 0,
        source: str = "antigravity",
        cache_write: int = 0,
        cache_write_1h: int = 0,
        input_is_net: bool = False
    ):
        self.timestamp = timestamp
        self.session_id = session_id
        self.model = model.strip() if model else "unknown"
        self.raw_input = max(0, raw_input)
        self.cached_input = max(0, cached_input)
        # Anthropic reports input_tokens exclusive of cached tokens; OpenAI/Gemini/OTEL include them.
        if input_is_net:
            self.net_input = self.raw_input
        else:
            self.net_input = max(0, self.raw_input - self.cached_input) if self.raw_input >= self.cached_input else self.raw_input
        self.cache_write = max(0, cache_write)
        self.cache_write_1h = max(0, cache_write_1h)
        self.output = max(0, output)
        self.thoughts = max(0, thoughts)
        self.source = source

    @property
    def total_tokens(self) -> int:
        return self.net_input + self.cached_input + self.cache_write + self.cache_write_1h + self.output + self.thoughts

    def calculate_cost(self, pricing_config: Dict[str, Any]) -> float:
        models_map = pricing_config.get("models", {})
        default_pricing = pricing_config.get("default", {})
        
        matched_rates = None
        model_lower = self.model.lower()
        if model_lower in models_map:
            matched_rates = models_map[model_lower]
        else:
            for k, v in models_map.items():
                if k.lower() == model_lower:
                    matched_rates = v
                    break

        if not matched_rates:
            candidates = []
            for k, v in models_map.items():
                k_lower = k.lower()
                if k_lower in model_lower or model_lower in k_lower:
                    candidates.append((k_lower, v))
            if candidates:
                candidates.sort(key=lambda item: (item[0] in model_lower, len(item[0])), reverse=True)
                matched_rates = candidates[0][1]

        if not matched_rates:
            matched_rates = default_pricing

        input_rate = matched_rates.get("input_cost_per_token", 7.5e-8)
        cache_rate = matched_rates.get("cache_read_input_token_cost", 1.875e-8)
        output_rate = matched_rates.get("output_cost_per_token", 3e-7)
        write_rate = matched_rates.get("cache_creation_input_token_cost", input_rate * 1.25)
        write_1h_rate = matched_rates.get("cache_creation_1h_input_token_cost", input_rate * 2)

        return (
            (self.net_input * input_rate)
            + (self.cached_input * cache_rate)
            + (self.cache_write * write_rate)
            + (self.cache_write_1h * write_1h_rate)
            + ((self.output + self.thoughts) * output_rate)
        )

    @property
    def unique_key(self) -> Tuple[str, str, str, str, int, int, int]:
        ts_str = self.timestamp.isoformat()
        return (self.source, self.session_id, ts_str, self.model, self.raw_input, self.output, self.cached_input)


def parse_antigravity_brain_transcripts(home_dir: str) -> List[TokenEntry]:
    """Parse Antigravity CLI transcript logs calculating cumulative context window prefill per LLM turn."""
    entries: List[TokenEntry] = []
    brain_dir = os.path.join(home_dir, ".gemini", "antigravity-cli", "brain")
    transcripts = glob.glob(os.path.join(brain_dir, "*", ".system_generated", "logs", "transcript.jsonl"))

    model_cache: Dict[str, str] = {}

    def get_model_name(conv_id: str) -> str:
        if conv_id in model_cache:
            return model_cache[conv_id]
        db_path = os.path.join(home_dir, ".gemini", "antigravity-cli", "conversations", f"{conv_id}.db")
        model_name = "gemini-3.8-flash"
        if os.path.exists(db_path):
            conn = None
            try:
                try:
                    conn = sqlite3.connect(f"file:{db_path}?immutable=1", uri=True)
                except Exception:
                    conn = sqlite3.connect(db_path)
                cursor = conn.cursor()
                cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='gen_metadata'")
                if cursor.fetchone():
                    cursor.execute("SELECT data FROM gen_metadata")
                    for row in cursor.fetchall():
                        blob = row[0]
                        if blob and (b"gemini" in blob.lower() or b"claude" in blob.lower() or b"gpt" in blob.lower()):
                            matches = re.findall(rb"(?:gemini|claude|gpt)[a-zA-Z0-9\.\-]+|(?:gemini|claude|gpt)\s+[a-zA-Z0-9\.\-]+\s+[a-zA-Z]+", blob, re.IGNORECASE)
                            if matches:
                                found = False
                                for match in reversed(matches):
                                    raw_name = match.decode("utf-8", errors="ignore").strip()
                                    norm_name = re.sub(r'\s*\([^)]*\)', '', raw_name).strip()
                                    norm_name = re.sub(r'\s+', '-', norm_name).lower()
                                    if re.search(r'\d', norm_name):
                                        model_name = norm_name
                                        found = True
                                        break
                                if not found:
                                    raw_name = matches[-1].decode("utf-8", errors="ignore").strip()
                                    norm_name = re.sub(r'\s*\([^)]*\)', '', raw_name).strip()
                                    model_name = re.sub(r'\s+', '-', norm_name).lower()
                                break
            except Exception:
                pass
            finally:
                if conn:
                    conn.close()
        model_cache[conv_id] = model_name
        return model_name

    for t_path in transcripts:
        conv_id = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(t_path))))
        model_name = get_model_name(conv_id)

        try:
            steps = []
            with open(t_path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or not line.startswith("{"):
                        continue
                    try:
                        data = json.loads(line)
                        steps.append((line, data))
                    except Exception:
                        continue

            session_history_chars = 0

            for line_str, data in steps:
                ts_raw = data.get("created_at")
                if not ts_raw:
                    continue
                ts = parse_iso_timestamp(ts_raw)

                content = data.get("content", "")
                src = data.get("source")
                tool_calls = data.get("tool_calls", [])

                step_len = len(content)
                for tc in tool_calls:
                    step_len += len(json.dumps(tc))

                explicit_in = re.search(r"\"(?:input_tokens|prompt_tokens)\":\s*(\d+)", line_str)
                in_tok = 0
                out_tok = 0
                cached_tok = 0

                if src == "MODEL":
                    if explicit_in:
                        in_tok = int(explicit_in.group(1))
                        m_out = re.search(r"\"(?:output_tokens|completion_tokens)\":\s*(\d+)", line_str)
                        if m_out:
                            out_tok = int(m_out.group(1))
                        m_cache = re.search(r"\"(?:cache_read_input_tokens|cached_tokens)\":\s*(\d+)", line_str)
                        if m_cache:
                            cached_tok = int(m_cache.group(1))
                    else:
                        # Cumulative Context Window calculation for LLM request
                        in_tok = BASE_SYSTEM_PROMPT_TOKENS + max(0, int(session_history_chars / 3.5))
                        out_tok = max(1, int(step_len / 3.5))

                    if in_tok > 0 or out_tok > 0:
                        entries.append(TokenEntry(
                            timestamp=ts,
                            session_id=conv_id,
                            model=model_name,
                            raw_input=in_tok,
                            cached_input=cached_tok,
                            output=out_tok,
                            source="antigravity"
                        ))
                    
                    session_history_chars += step_len
                else:
                    # Accumulate prompt / tool result / system input into history for subsequent LLM turns
                    session_history_chars += step_len
        except Exception:
            pass

    return entries


def parse_claude_transcripts(home_dir: str) -> List[TokenEntry]:
    claude_dir = os.path.join(home_dir, ".claude", "projects")
    if not os.path.exists(claude_dir):
        return []

    # Claude Code writes one JSONL line per content block (thinking / text / tool_use) of the
    # same API response, each repeating the whole usage object with a cumulative output count.
    # Collapse them per (message id, requestId) and keep the line with the largest output.
    best: Dict[Tuple[Optional[str], Optional[str]], Dict[str, Any]] = {}

    for root, _, files in os.walk(claude_dir):
        for file in files:
            if not file.endswith(".jsonl"):
                continue
            t_path = os.path.join(root, file)
            session_id = os.path.splitext(file)[0]
            try:
                with open(t_path, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if not line or '"usage"' not in line:
                            continue
                        try:
                            data = json.loads(line)
                        except Exception:
                            continue
                        message = data.get("message")
                        if not isinstance(message, dict):
                            continue
                        usage = message.get("usage")
                        if not isinstance(usage, dict):
                            continue
                        model = message.get("model") or "unknown"
                        if model.startswith("<"):
                            continue

                        key = (message.get("id"), data.get("requestId"))
                        prev = best.get(key)
                        if prev is not None and prev["usage"].get("output_tokens", 0) >= usage.get("output_tokens", 0):
                            continue
                        best[key] = {
                            "usage": usage,
                            "model": model,
                            "timestamp": data.get("timestamp"),
                            "session_id": data.get("sessionId", session_id),
                        }
            except Exception:
                pass

    entries: List[TokenEntry] = []
    for record in best.values():
        usage = record["usage"]
        creation = usage.get("cache_creation") or {}
        write_5m = creation.get("ephemeral_5m_input_tokens", 0)
        write_1h = creation.get("ephemeral_1h_input_tokens", 0)
        if write_5m == 0 and write_1h == 0:
            write_5m = usage.get("cache_creation_input_tokens", 0)

        entries.append(TokenEntry(
            timestamp=parse_iso_timestamp(record["timestamp"]),
            session_id=record["session_id"],
            model=record["model"],
            raw_input=usage.get("input_tokens", 0),
            cached_input=usage.get("cache_read_input_tokens", 0),
            output=usage.get("output_tokens", 0),
            source="claude",
            cache_write=write_5m,
            cache_write_1h=write_1h,
            input_is_net=True
        ))
    return entries


def parse_codex_transcripts(home_dir: str) -> List[TokenEntry]:
    entries: List[TokenEntry] = []
    for sub in ["sessions", "archived_sessions"]:
        codex_dir = os.path.join(home_dir, ".codex", sub)
        if not os.path.exists(codex_dir):
            continue
        for file in os.listdir(codex_dir):
            if not file.endswith(".jsonl"):
                continue
            t_path = os.path.join(codex_dir, file)
            session_id = os.path.splitext(file)[0]
            
            try:
                with open(t_path, "r", encoding="utf-8", errors="replace") as f:
                    current_model = "unknown"
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            data = json.loads(line)
                            
                            if data.get("type") == "turn_context":
                                payload = data.get("payload", {})
                                if "model" in payload:
                                    current_model = payload["model"]
                                continue
                                
                            if data.get("type") == "event_msg":
                                payload = data.get("payload", {})
                                if payload.get("type") == "token_count":
                                    info = payload.get("info", {})
                                    usage = info.get("last_token_usage")
                                    if not usage:
                                        continue
                                    
                                    in_tok = usage.get("input_tokens", usage.get("prompt_tokens", 0))
                                    out_tok = usage.get("output_tokens", usage.get("completion_tokens", 0))
                                    cache_read = usage.get("cache_read_input_tokens", 0)
                                    
                                    ts_raw = data.get("timestamp")
                                    ts = parse_iso_timestamp(ts_raw)
                                    
                                    entries.append(TokenEntry(
                                        timestamp=ts,
                                        session_id=session_id,
                                        model=current_model,
                                        raw_input=in_tok,
                                        cached_input=cache_read,
                                        output=out_tok,
                                        source="codex"
                                    ))
                                continue
                            
                            usage = data.get("usage") or data.get("data", {}).get("usage") or data.get("result", {}).get("usage")
                            if usage and isinstance(usage, dict):
                                in_tok = usage.get("input_tokens", usage.get("prompt_tokens", 0))
                                out_tok = usage.get("output_tokens", usage.get("completion_tokens", 0))
                                cache_read = usage.get("cache_read_input_tokens", 0)
                                
                                ts_raw = data.get("timestamp")
                                ts = parse_iso_timestamp(ts_raw)
                                model = data.get("model", current_model)
                                
                                entries.append(TokenEntry(
                                    timestamp=ts,
                                    session_id=session_id,
                                    model=model,
                                    raw_input=in_tok,
                                    cached_input=cache_read,
                                    output=out_tok,
                                    source="codex"
                                ))
                        except Exception:
                            pass
            except Exception:
                pass
    return entries


def parse_copilot_transcripts(home_dir: str) -> List[TokenEntry]:
    entries: List[TokenEntry] = []
    copilot_dir = os.path.join(home_dir, ".copilot", "otel")
    if not os.path.exists(copilot_dir):
        return entries
        
    for file in os.listdir(copilot_dir):
        if not file.endswith(".jsonl"):
            continue
        t_path = os.path.join(copilot_dir, file)
        
        try:
            with open(t_path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or '"attributes"' not in line:
                        continue
                    try:
                        data = json.loads(line)
                        attrs = data.get("attributes")
                        if not attrs or not isinstance(attrs, dict):
                            continue
                            
                        in_tok = attrs.get("gen_ai.usage.input_tokens", 0)
                        out_tok = attrs.get("gen_ai.usage.output_tokens", 0)
                        cache_read = attrs.get("gen_ai.usage.cache_read.input_tokens", 0)
                        
                        if in_tok == 0 and out_tok == 0:
                            continue
                            
                        ts_raw = data.get("endTime") or data.get("time") or data.get("timestamp")
                        ts = datetime.now(timezone.utc)
                        if isinstance(ts_raw, list) and len(ts_raw) > 0:
                            ts = datetime.fromtimestamp(ts_raw[0], timezone.utc)
                        elif isinstance(ts_raw, (int, float)):
                            if ts_raw > 1e16: ts = datetime.fromtimestamp(ts_raw/1e9, timezone.utc)
                            elif ts_raw > 1e12: ts = datetime.fromtimestamp(ts_raw/1e3, timezone.utc)
                            else: ts = datetime.fromtimestamp(ts_raw, timezone.utc)
                        elif isinstance(ts_raw, str):
                            ts = parse_iso_timestamp(ts_raw)
                            
                        session_id = attrs.get("gen_ai.conversation.id") or attrs.get("copilot_chat.session_id") or data.get("traceId", "unknown")
                        model = attrs.get("gen_ai.response.model") or attrs.get("gen_ai.request.model", "unknown")
                        
                        entries.append(TokenEntry(
                            timestamp=ts,
                            session_id=str(session_id),
                            model=str(model),
                            raw_input=in_tok,
                            cached_input=cache_read,
                            output=out_tok,
                            source="copilot"
                        ))
                    except Exception:
                        pass
        except Exception:
            pass
    return entries


def parse_iso_timestamp(ts_str: Optional[str]) -> datetime:
    """Parse ISO timestamp string to datetime object."""
    if not ts_str:
        return datetime.now(timezone.utc)
    try:
        ts_str = ts_str.replace("Z", "+00:00")
        return datetime.fromisoformat(ts_str)
    except Exception:
        return datetime.now(timezone.utc)


def format_number(n: int) -> str:
    """Format integer with thousands separator."""
    return f"{n:,}"


def format_currency(amount: float) -> str:
    """Format float currency USD."""
    if amount < 0.001 and amount > 0:
        return f"${amount:.5f}"
    return f"${amount:.4f}"


def group_entries(
    entries: List[TokenEntry], mode: str
) -> Dict[str, Dict[str, Any]]:
    """Group token entries by date/week/month/session."""
    grouped: Dict[str, Dict[str, Any]] = {}
    pricing = load_pricing_config()

    for entry in entries:
        dt = entry.timestamp.astimezone()
        if mode == "weekly":
            key = dt.strftime("%Y-W%W")
        elif mode == "monthly":
            key = dt.strftime("%Y-%m")
        elif mode == "session":
            key = entry.session_id[:12] if entry.session_id else "unknown"
        else:
            key = dt.strftime("%Y-%m-%d")

        if key not in grouped:
            grouped[key] = {
                "period": key,
                "models": set(),
                "net_input": 0,
                "cache_write": 0,
                "cached_input": 0,
                "output": 0,
                "thoughts": 0,
                "total_tokens": 0,
                "cost": 0.0,
                "count": 0,
                "breakdown": {}
            }

        grp = grouped[key]
        grp["models"].add(entry.model)
        grp["net_input"] += entry.net_input
        grp["cache_write"] += entry.cache_write + entry.cache_write_1h
        grp["cached_input"] += entry.cached_input
        grp["output"] += entry.output
        grp["thoughts"] += entry.thoughts
        grp["total_tokens"] += entry.total_tokens

        cost = entry.calculate_cost(pricing)
        grp["cost"] += cost
        grp["count"] += 1

        m = entry.model
        if m not in grp["breakdown"]:
            grp["breakdown"][m] = {
                "net_input": 0,
                "cache_write": 0,
                "cached_input": 0,
                "output": 0,
                "thoughts": 0,
                "total_tokens": 0,
                "cost": 0.0
            }
        grp["breakdown"][m]["net_input"] += entry.net_input
        grp["breakdown"][m]["cache_write"] += entry.cache_write + entry.cache_write_1h
        grp["breakdown"][m]["cached_input"] += entry.cached_input
        grp["breakdown"][m]["output"] += entry.output
        grp["breakdown"][m]["thoughts"] += entry.thoughts
        grp["breakdown"][m]["total_tokens"] += entry.total_tokens
        grp["breakdown"][m]["cost"] += cost

    return grouped


def aggregate_by_model(grouped: Dict[str, Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """Merge the per-period model breakdowns into a single model-keyed aggregate."""
    totals: Dict[str, Dict[str, Any]] = {}

    for grp in grouped.values():
        for m_name, m_data in grp["breakdown"].items():
            if m_name not in totals:
                totals[m_name] = {
                    "net_input": 0,
                    "cache_write": 0,
                    "cached_input": 0,
                    "output": 0,
                    "thoughts": 0,
                    "total_tokens": 0,
                    "cost": 0.0
                }
            agg = totals[m_name]
            for field in ("net_input", "cache_write", "cached_input", "output", "thoughts", "total_tokens", "cost"):
                agg[field] += m_data[field]

    return totals


def filter_entries(
    entries: List[TokenEntry],
    since: Optional[str] = None,
    until: Optional[str] = None,
    last: Optional[int] = None
) -> List[TokenEntry]:
    """Filter token entries by date bounds or last N items."""
    # Bounds are local dates, matching how group_entries() buckets by local time.
    filtered = entries
    if since:
        try:
            since_dt = datetime.fromisoformat(since).astimezone()
            filtered = [e for e in filtered if e.timestamp.astimezone() >= since_dt]
        except Exception:
            pass

    if until:
        try:
            until_dt = datetime.fromisoformat(until).astimezone()
            if until_dt.time() == datetime.min.time():
                until_dt = until_dt + timedelta(days=1)
            filtered = [e for e in filtered if e.timestamp.astimezone() < until_dt]
        except Exception:
            pass

    return filtered


PERIOD_COL_WIDTHS = (14, 24, 13, 15, 12, 15, 11)
MODEL_COL_WIDTHS = (24, 13, 15, 12, 15, 11)


def md_row(cells: List[str], widths: Tuple[int, ...], left_align: int) -> str:
    """Render one Markdown row: the first `left_align` cells are left-aligned, the rest right-aligned."""
    parts = [
        f"{cell:<{w}}" if i < left_align else f"{cell:>{w}}"
        for i, (cell, w) in enumerate(zip(cells, widths))
    ]
    return "| " + " | ".join(parts) + " |"


def md_separator(widths: Tuple[int, ...]) -> str:
    return "| " + " | ".join("-" * w for w in widths) + " |"


def md_total_row(cells: List[str]) -> str:
    return "| **Total** | " + " | ".join(f"**{c}**" for c in cells) + " |"


def sort_models(breakdown: Dict[str, Dict[str, Any]], show_cost: bool) -> List[Tuple[str, Dict[str, Any]]]:
    """Order models by what the report is about: cost, or raw volume when cost is hidden."""
    key = (lambda item: item[1]["cost"]) if show_cost else (lambda item: item[1]["total_tokens"])
    return sorted(breakdown.items(), key=key, reverse=True)


def print_table(
    grouped: Dict[str, Dict[str, Any]],
    mode: str,
    show_cost: bool = True,
    compact: bool = False
):
    """Print Markdown report table, one row per model within each period."""
    if not grouped:
        print("No usage data found.")
        return

    period_label = "Date"
    if mode == "weekly":
        period_label = "Week"
    elif mode == "monthly":
        period_label = "Month"
    elif mode == "session":
        period_label = "Session ID"

    widths = PERIOD_COL_WIDTHS if show_cost else PERIOD_COL_WIDTHS[:-1]

    print(f"\n### 📊 Token Usage Report ({mode.upper()})")
    print("*Context Window Prefill Included · Cache = CacheWrite + CacheRead*\n")

    header = [period_label, "Model", "Input", "Cache", "Output", "Total", "Cost ($)"]
    print(md_row(header[:len(widths)], widths, left_align=2))
    print(md_separator(widths))

    tot_net_in = 0
    tot_cache = 0
    tot_out = 0
    tot_total = 0
    tot_cost = 0.0

    for k in sorted(grouped.keys()):
        grp = grouped[k]

        tot_net_in += grp["net_input"]
        tot_cache += grp["cache_write"] + grp["cached_input"]
        tot_out += grp["output"] + grp["thoughts"]
        tot_total += grp["total_tokens"]
        tot_cost += grp["cost"]

        if compact:
            models_list = sorted(grp["models"])
            label = models_list[0] if len(models_list) == 1 else f"{len(models_list)} models"
            rows = [(label, grp)]
        else:
            rows = sort_models(grp["breakdown"], show_cost)

        for idx, (m_name, m_data) in enumerate(rows):
            cells = [
                grp["period"] if idx == 0 else "",
                m_name,
                format_number(m_data["net_input"]),
                format_number(m_data["cache_write"] + m_data["cached_input"]),
                format_number(m_data["output"] + m_data["thoughts"]),
                format_number(m_data["total_tokens"]),
                format_currency(m_data["cost"]),
            ]
            print(md_row(cells[:len(widths)], widths, left_align=2))

    totals = [
        "-",
        format_number(tot_net_in),
        format_number(tot_cache),
        format_number(tot_out),
        format_number(tot_total),
        format_currency(tot_cost),
    ]
    print(md_total_row(totals[:len(widths) - 1]) + "\n")


def print_model_table(
    grouped: Dict[str, Dict[str, Any]],
    mode: str,
    show_cost: bool = True
):
    """Print Markdown report table aggregated per model across the whole window."""
    model_totals = aggregate_by_model(grouped)
    if not model_totals:
        print("No usage data found.")
        return

    periods = sorted(grouped.keys())
    span = periods[0] if len(periods) == 1 else f"{periods[0]} → {periods[-1]}"
    widths = MODEL_COL_WIDTHS if show_cost else MODEL_COL_WIDTHS[:-1]

    print("\n### 📊 Token Usage by Model")
    print(f"*{mode.upper()} span: {span} · Cache = CacheWrite + CacheRead*\n")

    header = ["Model", "Input", "Cache", "Output", "Total", "Cost ($)"]
    print(md_row(header[:len(widths)], widths, left_align=1))
    print(md_separator(widths))

    tot_net_in = 0
    tot_cache = 0
    tot_out = 0
    tot_total = 0
    tot_cost = 0.0

    for m_name, m_data in sort_models(model_totals, show_cost):
        tot_net_in += m_data["net_input"]
        tot_cache += m_data["cache_write"] + m_data["cached_input"]
        tot_out += m_data["output"] + m_data["thoughts"]
        tot_total += m_data["total_tokens"]
        tot_cost += m_data["cost"]

        cells = [
            m_name,
            format_number(m_data["net_input"]),
            format_number(m_data["cache_write"] + m_data["cached_input"]),
            format_number(m_data["output"] + m_data["thoughts"]),
            format_number(m_data["total_tokens"]),
            format_currency(m_data["cost"]),
        ]
        print(md_row(cells[:len(widths)], widths, left_align=1))

    totals = [
        format_number(tot_net_in),
        format_number(tot_cache),
        format_number(tot_out),
        format_number(tot_total),
        format_currency(tot_cost),
    ]
    print(md_total_row(totals[:len(widths) - 1]) + "\n")


def main():
    parser = argparse.ArgumentParser(description="AI Assistant Token Usage & Cost Calculator")
    parser.add_argument("mode", nargs="?", default="daily", choices=["daily", "weekly", "monthly", "session"], help="Report aggregation mode")
    parser.add_argument("--source", default="all", choices=["antigravity", "claude", "codex", "copilot", "all"], help="Source CLI to calculate token usage for")
    parser.add_argument("--since", help="Start date (YYYY-MM-DD)")
    parser.add_argument("--until", help="End date (YYYY-MM-DD)")
    parser.add_argument("--last", type=int, help="Show last N periods")
    parser.add_argument("--json", action="store_true", help="Output result as JSON")
    parser.add_argument("--no-cost", action="store_true", help="Hide cost calculation")
    parser.add_argument("--compact", action="store_true", help="Collapse each period to a single aggregate row instead of one row per model")
    parser.add_argument("--by-model", action="store_true", help="Aggregate the whole window into one per-model table instead of per-period rows")
    parser.add_argument("--data-dir", help="Custom root directory for data (e.g. ~/.gemini)")

    args = parser.parse_args()
    home_dir = args.data_dir or os.path.expanduser("~")
    
    raw_entries: List[TokenEntry] = []
    if args.source in ("antigravity", "all"):
        raw_entries.extend(parse_antigravity_brain_transcripts(home_dir))
    if args.source in ("claude", "all"):
        raw_entries.extend(parse_claude_transcripts(home_dir))
    if args.source in ("codex", "all"):
        raw_entries.extend(parse_codex_transcripts(home_dir))
    if args.source in ("copilot", "all"):
        raw_entries.extend(parse_copilot_transcripts(home_dir))

    unique_entries: List[TokenEntry] = []
    seen_keys: Set[Tuple[str, str, str, str, int, int, int]] = set()
    for entry in raw_entries:
        k = entry.unique_key
        if k not in seen_keys:
            seen_keys.add(k)
            unique_entries.append(entry)

    filtered_entries = filter_entries(unique_entries, since=args.since, until=args.until)
    grouped = group_entries(filtered_entries, mode=args.mode)

    if args.last and args.last > 0:
        sorted_keys = sorted(grouped.keys())[-args.last:]
        grouped = {k: grouped[k] for k in sorted_keys}

    if args.json and args.by_model:
        model_totals = aggregate_by_model(grouped)
        output_json = [
            {
                "model": m,
                "net_input_tokens": val["net_input"],
                "cache_write_tokens": val["cache_write"],
                "cached_input_tokens": val["cached_input"],
                "output_tokens": val["output"] + val["thoughts"],
                "total_tokens": val["total_tokens"],
                "cost_usd": round(val["cost"], 6) if not args.no_cost else None,
            }
            for m, val in sorted(model_totals.items(), key=lambda item: item[1]["cost"], reverse=True)
        ]
        print(json.dumps(output_json, indent=2, ensure_ascii=False))
    elif args.json:
        output_json = []
        for k in sorted(grouped.keys()):
            item = grouped[k]
            record = {
                "period": item["period"],
                "models": list(item["models"]),
                "net_input_tokens": item["net_input"],
                "cache_write_tokens": item["cache_write"],
                "cached_input_tokens": item["cached_input"],
                "output_tokens": item["output"] + item["thoughts"],
                "total_tokens": item["total_tokens"],
                "cost_usd": round(item["cost"], 6) if not args.no_cost else None,
            }
            record["breakdown"] = {
                m: {
                    "net_input_tokens": val["net_input"],
                    "cache_write_tokens": val["cache_write"],
                    "cached_input_tokens": val["cached_input"],
                    "output_tokens": val["output"] + val["thoughts"],
                    "total_tokens": val["total_tokens"],
                    "cost_usd": round(val["cost"], 6) if not args.no_cost else None
                }
                for m, val in item["breakdown"].items()
            }
            output_json.append(record)
        print(json.dumps(output_json, indent=2, ensure_ascii=False))
    elif args.by_model:
        print_model_table(grouped, mode=args.mode, show_cost=not args.no_cost)
    else:
        print_table(grouped, mode=args.mode, show_cost=not args.no_cost, compact=args.compact)


if __name__ == "__main__":
    main()
