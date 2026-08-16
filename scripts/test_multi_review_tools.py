#!/usr/bin/env python3
"""Unit tests for multi-review-tools.py."""

import importlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
mrt = importlib.import_module("multi-review-tools")


class TestMultiReviewTools(unittest.TestCase):

    def test_normalize_section_name(self):
        self.assertEqual(mrt.normalize_section_name("Review Summary"), "Summary")
        self.assertEqual(mrt.normalize_section_name("Overview — High Level"), "Summary")
        self.assertEqual(mrt.normalize_section_name("Critical"), "Critical Issues")
        self.assertEqual(mrt.normalize_section_name("Maintainability"), "Maintainability & Architecture")
        self.assertEqual(mrt.normalize_section_name("What's Done Well"), "Good Practices Observed")
        self.assertEqual(mrt.normalize_section_name("Good Practices Observed"), "Good Practices Observed")

    def test_splice_verdict_in_block_dedup(self):
        block = [
            "- **Resource Leak**",
            "[NEEDS-FIX]",
            "Evidence: old evidence 1",
            "[NEEDS-FIX]",
            "Evidence: old evidence 2",
            "  - **Location**: app/db.py:42",
            "  - **Description**: unclosed cursor",
        ]
        spliced = mrt.splice_verdict_in_block(block, "NEEDS-FIX", "Evidence: new evidence")
        self.assertEqual(spliced, [
            "- **Resource Leak**",
            "[NEEDS-FIX]",
            "Evidence: new evidence",
            "  - **Location**: app/db.py:42",
            "  - **Description**: unclosed cursor",
        ])

    def test_splice_verdict_in_block_no_existing(self):
        block = [
            "- **Resource Leak**",
            "  - **Location**: app/db.py:42",
        ]
        spliced = mrt.splice_verdict_in_block(block, "NEEDS-FIX", "Evidence: leak found")
        self.assertEqual(spliced, [
            "- **Resource Leak**",
            "[NEEDS-FIX]",
            "Evidence: leak found",
            "  - **Location**: app/db.py:42",
        ])


if __name__ == "__main__":
    unittest.main()
