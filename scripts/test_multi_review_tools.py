#!/usr/bin/env python3
"""Unit tests for multi-review-tools.py."""

import argparse
import contextlib
import importlib
import io
import sys
import tempfile
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


def _issue(title, loc, verdict, evidence, concern, origin=""):
    return "\n".join([
        f"- **{title}**{origin}",
        f"[{verdict}]",
        f"Evidence: {evidence}",
        f"  - **Location**: {loc}",
        f"  - **Concern**: {concern}",
    ])


class TestMerge(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workdir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, n, body):
        (self.workdir / f"iter-{n}-verified.md").write_text(body)

    def _merge(self):
        state = mrt.MergeState()
        for p in mrt.collect_iter_files(self.workdir):
            state.absorb(p)
        return state.render(None)

    def test_same_issue_keeps_first_block_and_takes_latest_verdict(self):
        self._write(1, "## Maintainability & Architecture\n\n"
                    + _issue("Leak", "app/db.py:42", "NEEDS-FIX", "e1", "first wording"))
        self._write(2, "## Maintainability & Architecture\n\n"
                    + _issue("Leak", "app/db.py:42", "IGNORABLE", "e2", "second wording"))
        out = self._merge()
        self.assertIn("- **Leak** _(origin: iter-1)_", out)
        self.assertIn("first wording", out)
        self.assertNotIn("second wording", out)
        self.assertIn("[IGNORABLE]\nEvidence: e2", out)

    def test_different_issue_at_same_location_replaces_block(self):
        self._write(0, "## Maintainability & Architecture\n\n"
                    + _issue("Old issue", "system.md:161", "FIXED", "old", "old concern",
                           origin=" _(origin: iter-1)_"))
        self._write(1, "## Critical Issues\n\n"
                    + _issue("New issue", "system.md:161", "NEEDS-FIX", "new", "new concern"))
        out = self._merge()
        self.assertNotIn("Old issue", out)
        self.assertNotIn("old concern", out)
        critical = out.split("## Critical Issues", 1)[1].split("## Maintainability", 1)[0]
        self.assertIn("- **New issue** _(origin: iter-1)_\n[NEEDS-FIX]\nEvidence: new", critical)
        self.assertIn("new concern", critical)
        self.assertIn("| NEEDS-FIX | 1 |", out)
        self.assertNotIn("| FIXED |", out)

    def test_prior_per_round_breakdown_is_not_carried_forward(self):
        self._write(0, "## Maintainability & Architecture\n\n"
                    + _issue("Leak", "app/db.py:42", "NEEDS-FIX", "e1", "c")
                    + "\n\n## Verification Summary\n\n| Verdict | Count |\n\n"
                    + "### Per-round breakdown\n\n| iter | stale |\n")
        self._write(1, "## Maintainability & Architecture\n\n"
                    + _issue("Leak", "app/db.py:42", "NEEDS-FIX", "e2", "c"))
        out = self._merge()
        self.assertNotIn("stale", out)
        self.assertEqual(out.count("Per-round breakdown"), 1)

    def test_verdictless_block_does_not_replace_judged_issue(self):
        self._write(1, "## Maintainability & Architecture\n\n"
                    + _issue("Judged", "app/db.py:42", "NEEDS-FIX", "e1", "c") + "\n"
                    + "- **Unjudged**\n  - **Location**: app/db.py:42-60\n")
        out = self._merge()
        self.assertIn("- **Judged** _(origin: iter-1)_", out)
        self.assertNotIn("Unjudged", out)
        self.assertIn("| NEEDS-FIX | 1 |", out)

    def test_replacement_keeps_other_entries_in_section(self):
        self._write(1, "## Maintainability & Architecture\n\n"
                    + _issue("First", "app/a.py:1", "NEEDS-FIX", "e1", "c") + "\n"
                    + _issue("Second", "app/b.py:2", "NEEDS-FIX", "e2", "c"))
        self._write(2, "## Maintainability & Architecture\n\n"
                    + _issue("Replacement", "app/a.py:1", "NONEXISTENT", "e3", "c") + "\n"
                    + _issue("Second", "app/b.py:2", "IGNORABLE", "e4", "c"))
        out = self._merge()
        self.assertNotIn("First", out)
        self.assertEqual(out.count("- **Replacement**"), 1)
        self.assertEqual(out.count("- **Second**"), 1)
        self.assertIn("[IGNORABLE]\nEvidence: e4", out)
        self.assertIn("| NEEDS-FIX | 0 |", out)
        self.assertIn("| IGNORABLE | 1 |", out)
        self.assertIn("| NONEXISTENT | 1 |", out)

    def test_anchor_block_keeps_its_origin_tag(self):
        self._write(0, "## Maintainability & Architecture\n\n"
                    + _issue("Leak", "app/db.py:42", "IGNORABLE", "e0", "c",
                             origin=" _(origin: iter-2)_"))
        self._write(1, "## Maintainability & Architecture\n\n"
                    + _issue("Other", "app/x.py:7", "NEEDS-FIX", "e1", "c"))
        out = self._merge()
        self.assertIn("- **Leak** _(origin: iter-2)_\n[IGNORABLE]\nEvidence: e0", out)
        self.assertNotIn("origin: iter-0", out)

    def test_verdict_without_evidence_leaves_entry_unchanged(self):
        loc = "app/db.py:42"
        self._write(1, "## Maintainability & Architecture\n\n"
                    + _issue("Leak", loc, "NEEDS-FIX", "e1", "c"))
        self._write(2, "## Maintainability & Architecture\n\n"
                    + f"- **Leak**\n[IGNORABLE]\n  - **Location**: {loc}\n")
        out = self._merge()
        self.assertIn("[NEEDS-FIX]\nEvidence: e1", out)
        self.assertIn("| NEEDS-FIX | 1 |", out)


class TestExtractAnnotations(unittest.TestCase):

    def test_keys_by_location_not_evidence_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "verified.md"
            path.write_text("## Critical Issues\n\n"
                            + _issue("X", "a.py:10", "IGNORABLE", "a.py:20 — cites another line", "c") + "\n"
                            + "## Maintainability & Architecture\n\n"
                            + _issue("Y", "a.py:20", "NONEXISTENT", "a.py:20 — own line", "c") + "\n"
                            + _issue("Z", "b.py:5", "NEEDS-FIX", "a.py:20 — cites another file", "c") + "\n"
                            + "- **No evidence**\n[NEEDS-FIX]\n  - **Location**: c.py:1\n")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                mrt.cmd_extract_annotations(argparse.Namespace(path=str(path)))
        rows = [line.split("\t")[:2] for line in buf.getvalue().splitlines()]
        self.assertEqual(rows, [
            ["a.py:10", "IGNORABLE"],
            ["a.py:20", "NONEXISTENT"],
            ["b.py:5", "NEEDS-FIX"],
        ])


if __name__ == "__main__":
    unittest.main()
