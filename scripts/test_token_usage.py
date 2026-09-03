#!/usr/bin/env python3
"""
Unit tests for Token Usage Calculator (scripts/token_usage.py)
"""

import unittest
from datetime import datetime, timezone
from token_usage import (
    TokenEntry,
    group_entries,
    filter_entries,
    aggregate_by_model,
    load_pricing_config
)

class TestTokenUsage(unittest.TestCase):

    def setUp(self):
        self.pricing_config = {
            "models": {
                "gemini-3.6-flash": {
                    "input_cost_per_token": 7.5e-8,
                    "cache_read_input_token_cost": 1.875e-8,
                    "output_cost_per_token": 3e-7
                },
                "gemini-3.1-pro-preview": {
                    "input_cost_per_token": 1.25e-6,
                    "cache_read_input_token_cost": 3.125e-7,
                    "output_cost_per_token": 5e-6
                }
            },
            "default": {
                "input_cost_per_token": 7.5e-8,
                "cache_read_input_token_cost": 1.875e-8,
                "output_cost_per_token": 3e-7
            }
        }

    def test_token_entry_cost_calculation(self):
        # 10,000 raw input, 2,000 cached (net input = 8,000), 1,000 output, 500 thoughts
        entry = TokenEntry(
            timestamp=datetime(2026, 8, 6, 12, 0, tzinfo=timezone.utc),
            session_id="session-1",
            model="gemini-3.6-flash",
            raw_input=10000,
            cached_input=2000,
            output=1000,
            thoughts=500
        )
        self.assertEqual(entry.net_input, 8000)
        self.assertEqual(entry.cached_input, 2000)
        self.assertEqual(entry.total_tokens, 11500)

        # Expected cost calculation:
        # Net Input: 8000 * 7.5e-8 = 0.0006
        # Cached Input: 2000 * 1.875e-8 = 0.0000375
        # Output + Thoughts: (1000 + 500) * 3e-7 = 0.00045
        # Total = 0.0010875
        cost = entry.calculate_cost(self.pricing_config)
        self.assertAlmostEqual(cost, 0.0010875, places=7)

    def test_group_entries_daily(self):
        entry1 = TokenEntry(
            timestamp=datetime(2026, 8, 6, 10, 0, tzinfo=timezone.utc),
            session_id="s1",
            model="gemini-3.6-flash",
            raw_input=5000,
            cached_input=1000,
            output=500
        )
        entry2 = TokenEntry(
            timestamp=datetime(2026, 8, 6, 14, 0, tzinfo=timezone.utc),
            session_id="s2",
            model="gemini-3.1-pro-preview",
            raw_input=2000,
            cached_input=0,
            output=200
        )

        grouped = group_entries([entry1, entry2], mode="daily")
        self.assertEqual(len(grouped), 1)
        expected_key = entry1.timestamp.astimezone().strftime("%Y-%m-%d")
        self.assertIn(expected_key, grouped)
        grp = grouped[expected_key]
        self.assertEqual(grp["net_input"], 4000 + 2000)
        self.assertEqual(grp["cached_input"], 1000)
        self.assertEqual(grp["output"], 500 + 200)

    def test_aggregate_by_model_merges_periods(self):
        e1 = TokenEntry(
            timestamp=datetime(2026, 8, 6, 10, 0, tzinfo=timezone.utc),
            session_id="s1",
            model="claude-opus-5",
            raw_input=1000,
            cached_input=4000,
            output=100,
            cache_write=500,
            input_is_net=True
        )
        e2 = TokenEntry(
            timestamp=datetime(2026, 8, 8, 10, 0, tzinfo=timezone.utc),
            session_id="s2",
            model="claude-opus-5",
            raw_input=2000,
            cached_input=6000,
            output=200,
            cache_write=300,
            input_is_net=True
        )
        e3 = TokenEntry(
            timestamp=datetime(2026, 8, 8, 11, 0, tzinfo=timezone.utc),
            session_id="s3",
            model="gemini-3.6-flash",
            raw_input=5000,
            cached_input=0,
            output=50
        )

        grouped = group_entries([e1, e2, e3], mode="daily")
        self.assertEqual(len(grouped), 2)

        totals = aggregate_by_model(grouped)
        self.assertEqual(set(totals.keys()), {"claude-opus-5", "gemini-3.6-flash"})

        opus = totals["claude-opus-5"]
        self.assertEqual(opus["net_input"], 3000)
        self.assertEqual(opus["cached_input"], 10000)
        self.assertEqual(opus["cache_write"], 800)
        self.assertEqual(opus["output"], 300)
        self.assertEqual(opus["total_tokens"], e1.total_tokens + e2.total_tokens)

        # Aggregate cost must equal the sum of the per-period buckets it merged.
        period_cost = sum(grp["cost"] for grp in grouped.values())
        self.assertAlmostEqual(sum(v["cost"] for v in totals.values()), period_cost, places=9)

    def test_filter_entries_by_date(self):
        e1 = TokenEntry(
            timestamp=datetime(2026, 5, 1, 10, 0, tzinfo=timezone.utc),
            session_id="s1",
            model="gemini-3.6-flash",
            raw_input=1000,
            cached_input=0,
            output=100
        )
        e2 = TokenEntry(
            timestamp=datetime(2026, 6, 1, 10, 0, tzinfo=timezone.utc),
            session_id="s2",
            model="gemini-3.6-flash",
            raw_input=2000,
            cached_input=0,
            output=200
        )

        filtered = filter_entries([e1, e2], since="2026-05-15")
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0].session_id, "s2")

    def test_gemini_3_8_flash_pricing(self):
        pricing = load_pricing_config()
        self.assertIn("gemini-3.8-flash", pricing["models"])
        entry = TokenEntry(
            timestamp=datetime(2026, 9, 3, 10, 0, tzinfo=timezone.utc),
            session_id="s-gemini",
            model="gemini-3.8-flash",
            raw_input=10000,
            cached_input=2000,
            output=1000
        )
        # Net input: 8000 * 7.5e-7 = 0.006
        # Cached input: 2000 * 7.5e-8 = 0.00015
        # Output: 1000 * 3.75e-6 = 0.00375
        # Total = 0.0099
        cost = entry.calculate_cost(pricing)
        self.assertAlmostEqual(cost, 0.0099, places=6)

    def test_claude_fable_5_1_vs_fable_5_pricing(self):
        pricing = load_pricing_config()
        self.assertIn("claude-fable-5.1", pricing["models"])
        self.assertIn("claude-fable-5-1", pricing["models"])
        self.assertIn("claude-fable-5", pricing["models"])

        entry_5_1 = TokenEntry(
            timestamp=datetime(2026, 9, 3, 10, 0, tzinfo=timezone.utc),
            session_id="s-claude-5-1",
            model="claude-fable-5-1",
            raw_input=1000,
            cached_input=10000,
            output=100,
            cache_write=500,
            cache_write_1h=200,
            input_is_net=True
        )
        entry_5 = TokenEntry(
            timestamp=datetime(2026, 9, 3, 10, 0, tzinfo=timezone.utc),
            session_id="s-claude-5",
            model="claude-fable-5",
            raw_input=1000,
            cached_input=10000,
            output=100,
            cache_write=500,
            cache_write_1h=200,
            input_is_net=True
        )

        cost_5_1 = entry_5_1.calculate_cost(pricing)
        cost_5 = entry_5.calculate_cost(pricing)

        # Fable 5.1 cache read is $0.25/M (2.5e-7), while Fable 5 is $1.00/M (1e-6)
        # Difference on 10,000 cached read tokens: 10000 * (1e-6 - 2.5e-7) = 0.0075
        self.assertAlmostEqual(cost_5 - cost_5_1, 0.0075, places=6)


if __name__ == "__main__":
    unittest.main()
