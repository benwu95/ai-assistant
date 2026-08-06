#!/usr/bin/env python3
"""
Unit tests for Token Usage Calculator (scripts/token_usage.py)
"""

import unittest
from datetime import datetime, timezone
from token_usage import (
    TokenEntry,
    group_entries,
    filter_entries
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
        today_key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        self.assertIn(today_key, grouped)
        grp = grouped[today_key]
        self.assertEqual(grp["net_input"], 4000 + 2000)
        self.assertEqual(grp["cached_input"], 1000)
        self.assertEqual(grp["output"], 500 + 200)

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


if __name__ == "__main__":
    unittest.main()
