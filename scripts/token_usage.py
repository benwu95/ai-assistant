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
from datetime import datetime, timezone
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
        source: str = "antigravity"
    ):
        self.timestamp = timestamp
        self.session_id = session_id
        self.model = model.strip() if model else "unknown"
        self.raw_input = max(0, raw_input)
        self.cached_input = max(0, cached_input)
        self.net_input = max(0, self.raw_input - self.cached_input) if self.raw_input >= self.cached_input else self.raw_input
        self.output = max(0, output)
        self.thoughts = max(0, thoughts)
        self.source = source

    @property
    def total_tokens(self) -> int:
        return self.net_input + self.cached_input + self.output + self.thoughts

    def calculate_cost(self, pricing_config: Dict[str, Any]) -> float:
        models_map = pricing_config.get("models", {})
        default_pricing = pricing_config.get("default", {})
        
        matched_rates = None
        model_lower = self.model.lower()
        for k, v in models_map.items():
            if k.lower() in model_lower or model_lower in k.lower():
                matched_rates = v
                break
        if not matched_rates:
            matched_rates = default_pricing

        input_rate = matched_rates.get("input_cost_per_token", 7.5e-8)
        cache_rate = matched_rates.get("cache_read_input_token_cost", 1.875e-8)
        output_rate = matched_rates.get("output_cost_per_token", 3e-7)

        return (self.net_input * input_rate) + (self.cached_input * cache_rate) + ((self.output + self.thoughts) * output_rate)

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
        model_name = "gemini-3.6-flash"
        if os.path.exists(db_path):
            try:
                conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
                cursor = conn.cursor()
                cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='gen_metadata'")
                if cursor.fetchone():
                    cursor.execute("SELECT data FROM gen_metadata")
                    for row in cursor.fetchall():
                        blob = row[0]
                        if blob and b"gemini" in blob.lower():
                            m = re.search(rb"(gemini-[a-zA-Z0-9\.\-]+)", blob, re.IGNORECASE)
                            if m:
                                model_name = m.group(1).decode("utf-8", errors="ignore")
                                break
                conn.close()
            except Exception:
                pass
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
    entries: List[TokenEntry] = []
    claude_dir = os.path.join(home_dir, ".claude", "projects")
    if not os.path.exists(claude_dir):
        return entries
        
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
                        if not line or '"usage":{' not in line:
                            continue
                        try:
                            data = json.loads(line)
                            if "message" in data and "usage" in data["message"]:
                                usage = data["message"]["usage"]
                                in_tok = usage.get("input_tokens", 0)
                                out_tok = usage.get("output_tokens", 0)
                                cache_read = usage.get("cache_read_input_tokens", 0)
                                
                                ts_raw = data.get("timestamp")
                                ts = parse_iso_timestamp(ts_raw)
                                
                                model = data["message"].get("model", "unknown")
                                sess_id = data.get("sessionId", session_id)
                                
                                entries.append(TokenEntry(
                                    timestamp=ts,
                                    session_id=sess_id,
                                    model=model,
                                    raw_input=in_tok,
                                    cached_input=cache_read,
                                    output=out_tok,
                                    source="claude"
                                ))
                        except Exception:
                            continue
            except Exception:
                pass
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
        grp["cached_input"] += entry.cached_input
        grp["output"] += entry.output
        grp["thoughts"] += entry.thoughts
        grp["total_tokens"] += entry.total_tokens
        
        pricing = load_pricing_config()
        cost = entry.calculate_cost(pricing)
        grp["cost"] += cost
        grp["count"] += 1

        m = entry.model
        if m not in grp["breakdown"]:
            grp["breakdown"][m] = {
                "net_input": 0,
                "cached_input": 0,
                "output": 0,
                "thoughts": 0,
                "total_tokens": 0,
                "cost": 0.0
            }
        grp["breakdown"][m]["net_input"] += entry.net_input
        grp["breakdown"][m]["cached_input"] += entry.cached_input
        grp["breakdown"][m]["output"] += entry.output
        grp["breakdown"][m]["thoughts"] += entry.thoughts
        grp["breakdown"][m]["total_tokens"] += entry.total_tokens
        grp["breakdown"][m]["cost"] += cost

    return grouped


def filter_entries(
    entries: List[TokenEntry],
    since: Optional[str] = None,
    until: Optional[str] = None,
    last: Optional[int] = None
) -> List[TokenEntry]:
    """Filter token entries by date bounds or last N items."""
    filtered = entries
    if since:
        try:
            since_dt = datetime.fromisoformat(since).replace(tzinfo=timezone.utc)
            filtered = [e for e in filtered if e.timestamp >= since_dt]
        except Exception:
            pass
            
    if until:
        try:
            until_dt = datetime.fromisoformat(until).replace(tzinfo=timezone.utc)
            filtered = [e for e in filtered if e.timestamp <= until_dt]
        except Exception:
            pass

    return filtered


def print_table(
    grouped: Dict[str, Dict[str, Any]],
    mode: str,
    show_cost: bool = True,
    compact: bool = False,
    show_breakdown: bool = False
):
    """Print Markdown report table."""
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

    print(f"\n### 📊 Token Usage Report ({mode.upper()})")
    print("*Context Window Prefill Included*\n")

    if show_cost:
        header = f"| {period_label:<14} | {'Models':<24} | {'Input':<10} | {'Cached':<10} | {'Output':<10} | {'Total':<11} | {'Cost ($)':<9} |"
        separator = f"| {'-'*14} | {'-'*24} | {'-'*10} | {'-'*10} | {'-'*10} | {'-'*11} | {'-'*9} |"
    else:
        header = f"| {period_label:<14} | {'Models':<24} | {'Input':<10} | {'Cached':<10} | {'Output':<10} | {'Total':<11} |"
        separator = f"| {'-'*14} | {'-'*24} | {'-'*10} | {'-'*10} | {'-'*10} | {'-'*11} |"

    print(header)
    print(separator)

    tot_net_in = 0
    tot_cached_in = 0
    tot_out = 0
    tot_total = 0
    tot_cost = 0.0

    sorted_keys = sorted(grouped.keys())

    for k in sorted_keys:
        grp = grouped[k]
        
        models_list = sorted(grp["models"])
        providers = {}
        for m in models_list:
            m_lower = m.lower()
            if m_lower.startswith("gemini"):
                p = "gemini"
            elif m_lower.startswith("claude"):
                p = "claude"
            elif m_lower.startswith("gpt") or m_lower.startswith("o1"):
                p = "openai"
            elif m_lower == "<synthetic>":
                p = "system"
            else:
                p = "other"
            if p not in providers:
                providers[p] = []
            providers[p].append(m)

        model_lines = []
        for p in sorted(providers.keys()):
            model_lines.append(p)
            for m in providers[p]:
                model_lines.append(f"  - {m}")
                    
        if compact and len(model_lines) > 5:
            model_lines = [f"{len(models_list)} models"]

        net_in = format_number(grp["net_input"])
        cached_in = format_number(grp["cached_input"])
        out = format_number(grp["output"] + grp["thoughts"])
        total = format_number(grp["total_tokens"])
        cost_str = format_currency(grp["cost"])

        tot_net_in += grp["net_input"]
        tot_cached_in += grp["cached_input"]
        tot_out += (grp["output"] + grp["thoughts"])
        tot_total += grp["total_tokens"]
        tot_cost += grp["cost"]

        first_model = model_lines[0] if model_lines else ""
        if show_cost:
            print(f"| {grp['period']:<14} | {first_model:<24} | {net_in:>10} | {cached_in:>10} | {out:>10} | {total:>11} | {cost_str:>9} |")
        else:
            print(f"| {grp['period']:<14} | {first_model:<24} | {net_in:>10} | {cached_in:>10} | {out:>10} | {total:>11} |")
            
        for line in model_lines[1:]:
            if show_cost:
                print(f"| {'':<14} | {line:<24} | {'':>10} | {'':>10} | {'':>10} | {'':>11} | {'':>9} |")
            else:
                print(f"| {'':<14} | {line:<24} | {'':>10} | {'':>10} | {'':>10} | {'':>11} |")

        if show_breakdown and len(grp["breakdown"]) > 1:
            for m_name, m_data in grp["breakdown"].items():
                m_net = format_number(m_data["net_input"])
                m_cached = format_number(m_data["cached_input"])
                m_out = format_number(m_data["output"] + m_data["thoughts"])
                m_tot = format_number(m_data["total_tokens"])
                m_cost = format_currency(m_data["cost"])
                if show_cost:
                    print(f"| {'':<14} | └─ {m_name:<21} | {m_net:>10} | {m_cached:>10} | {m_out:>10} | {m_tot:>11} | {m_cost:>9} |")
                else:
                    print(f"| {'':<14} | └─ {m_name:<21} | {m_net:>10} | {m_cached:>10} | {m_out:>10} | {m_tot:>11} |")

    tot_net_in_str = format_number(tot_net_in)
    tot_cached_in_str = format_number(tot_cached_in)
    tot_out_str = format_number(tot_out)
    tot_total_str = format_number(tot_total)
    tot_cost_str = format_currency(tot_cost)

    if show_cost:
        print(f"| **Total** | - | **{tot_net_in_str}** | **{tot_cached_in_str}** | **{tot_out_str}** | **{tot_total_str}** | **{tot_cost_str}** |\n")
    else:
        print(f"| **Total** | - | **{tot_net_in_str}** | **{tot_cached_in_str}** | **{tot_out_str}** | **{tot_total_str}** |\n")


def main():
    parser = argparse.ArgumentParser(description="AI Assistant Token Usage & Cost Calculator")
    parser.add_argument("mode", nargs="?", default="daily", choices=["daily", "weekly", "monthly", "session"], help="Report aggregation mode")
    parser.add_argument("--source", default="all", choices=["antigravity", "claude", "codex", "copilot", "all"], help="Source CLI to calculate token usage for")
    parser.add_argument("--since", help="Start date (YYYY-MM-DD)")
    parser.add_argument("--until", help="End date (YYYY-MM-DD)")
    parser.add_argument("--last", type=int, help="Show last N periods")
    parser.add_argument("--json", action="store_true", help="Output result as JSON")
    parser.add_argument("--no-cost", action="store_true", help="Hide cost calculation")
    parser.add_argument("--compact", action="store_true", help="Format compact output")
    parser.add_argument("--breakdown", action="store_true", help="Show breakdown per model")
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

    if args.json:
        output_json = []
        for k in sorted(grouped.keys()):
            item = grouped[k]
            record = {
                "period": item["period"],
                "models": list(item["models"]),
                "net_input_tokens": item["net_input"],
                "cached_input_tokens": item["cached_input"],
                "output_tokens": item["output"] + item["thoughts"],
                "total_tokens": item["total_tokens"],
                "cost_usd": round(item["cost"], 6) if not args.no_cost else None,
            }
            if args.breakdown:
                record["breakdown"] = {
                    m: {
                        "net_input_tokens": val["net_input"],
                        "cached_input_tokens": val["cached_input"],
                        "output_tokens": val["output"] + val["thoughts"],
                        "total_tokens": val["total_tokens"],
                        "cost_usd": round(val["cost"], 6) if not args.no_cost else None
                    }
                    for m, val in item["breakdown"].items()
                }
            output_json.append(record)
        print(json.dumps(output_json, indent=2, ensure_ascii=False))
    else:
        print_table(grouped, mode=args.mode, show_cost=not args.no_cost, compact=args.compact, show_breakdown=args.breakdown)


if __name__ == "__main__":
    main()
