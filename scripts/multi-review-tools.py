#!/usr/bin/env python3
"""Multi-review pipeline tools — Python-side helpers for the /multi-review command.

All non-trivial parsing / counting / cross-round comparison logic lives here.
The /multi-review command (commands/multi-review.md) drives the loop from the
main Claude Code session and invokes these subcommands via Bash between the
reviewer and verifier sub-agent turns.

Subcommands:
  merge                 Build cumulative review.md from iter-*-verified.md
  count-sections        Print "CC CP CM" issue counts for one review.md
  extract-annotations   Parse [verdict]/Evidence pairs in a verified.md → TSV
  parse-verifier-raw    Parse V_RAW (verifier stdout) → 3-col annotations TSV
  splice                Insert [verdict]+Evidence above each Location in review.md
  verification-summary  Emit '## Verification Summary' (carry from V_RAW or synthesize)
  derive-sidecars       3-col ann.tsv → 2-col verdicts.tsv + needs-fix sig
  diff-rounds           Compare two rounds: NEW / RESOLVED / CARRIED / FLIPPED
  summary-table         Render per-round breakdown table from stats.tsv
"""
import argparse
import json
import re
import sys
from pathlib import Path


# === Shared constants =======================================================

VERDICTS = ("需修正", "可忽略", "不存在")
VERDICT_FIXED = "已修正"
ALL_VERDICTS = (*VERDICTS, VERDICT_FIXED)

ISSUE_SECTIONS = (
    "Critical Issues",
    "Performance & Optimization",
    "Maintainability & Architecture",
)

SECTIONS_TO_REGENERATE = ("Verification Summary",)

CANONICAL_ORDER = (
    "Summary",
    "Changelog",
    *ISSUE_SECTIONS,
    "Good Practices Observed",
)


# === Shared regexes =========================================================

SECTION_RE = re.compile(r'^## (.+?)\s*$')
# Issue block: canonical bullet `- **Title**` OR deviant h3 `### C1. ...`
BULLET_RE = re.compile(r'^(?:- \*\*|### )')
# Location: bold (canonical) or plain (drift), with or without surrounding backticks
LOCATION_RE = re.compile(r'(?:\*\*Location\*\*:|^Location:)\s*`?([A-Za-z0-9_./\-]+:\d+)')
VERDICT_RE = re.compile(r'^\[(' + '|'.join(ALL_VERDICTS) + r')\]\s*$')
EVIDENCE_RE = re.compile(r'^Evidence:')
TITLE_BULLET_RE = re.compile(r'^(- \*\*[^*]+\*\*)(.*)$')
TITLE_H3_RE = re.compile(r'^### .+$')
PATH_LINE_RE = re.compile(r'[A-Za-z0-9_./\-]+:\d+')


# === Shared parsing primitives ==============================================

def normalize_section_name(name):
    name = re.sub(r'\s+[—\-(].*$', '', name)
    return name.strip()


def parse_file(path):
    """Return (preamble_lines, ordered_section_names, sections_dict)."""
    preamble = []
    order = []
    sections = {}
    current = None
    for line in Path(path).read_text().splitlines():
        m = SECTION_RE.match(line)
        if m:
            current = normalize_section_name(m.group(1))
            if current not in sections:
                sections[current] = []
                order.append(current)
            continue
        if current is None:
            preamble.append(line)
        else:
            sections[current].append(line)
    return preamble, order, sections


def split_blocks(body):
    """Split section body into top-level bullet blocks.

    Returns list of (kind, lines) tuples. Lines before the first bullet form
    a single 'leading' block; subsequent 'issue' blocks start at each bullet.
    """
    blocks = []
    leading = []
    current = None
    for line in body:
        if BULLET_RE.match(line):
            if current is not None:
                blocks.append(('issue', current))
            current = [line]
        else:
            if current is None:
                leading.append(line)
            else:
                current.append(line)
    if current is not None:
        blocks.append(('issue', current))
    if leading:
        blocks.insert(0, ('leading', leading))
    return blocks


def extract_location(block):
    for line in block:
        m = LOCATION_RE.search(line)
        if m:
            return m.group(1)
    return None


def extract_verdict_evidence(block):
    verdict = None
    evidence = None
    for line in block:
        vm = VERDICT_RE.match(line)
        if vm:
            verdict = vm.group(1)
        elif EVIDENCE_RE.match(line):
            evidence = line
    return verdict, evidence


def splice_verdict_in_block(block, verdict, evidence):
    """Insert or replace [verdict] + Evidence line in a block.

    If the block already has a [verdict] marker, replace it and the following
    Evidence: line (original behavior). If the block has NO [verdict] marker
    (e.g. iter-0 anchor copied from a pre-verifier-loop reviewer report), insert
    [verdict] + Evidence right after the title line so the merged body carries
    the latest-iter verdict.
    """
    if not block:
        return block
    has_existing_verdict = any(VERDICT_RE.match(l) for l in block)
    if has_existing_verdict:
        out = []
        state = 'pre'
        for line in block:
            if state == 'pre' and VERDICT_RE.match(line):
                out.append(f"[{verdict}]")
                state = 'await_evidence'
                continue
            if state == 'await_evidence' and EVIDENCE_RE.match(line):
                out.append(evidence)
                state = 'done'
                continue
            out.append(line)
        return out
    return [block[0], f"[{verdict}]", evidence] + block[1:]


def annotate_origin(block, iter_n):
    """Append _(origin: iter-N)_ to the title line (bullet or h3)."""
    if not block:
        return block
    out = list(block)
    line = out[0]
    m = TITLE_BULLET_RE.match(line)
    if m:
        out[0] = f"{m.group(1)} _(origin: iter-{iter_n})_{m.group(2)}"
    elif TITLE_H3_RE.match(line):
        out[0] = f"{line.rstrip()} _(origin: iter-{iter_n})_"
    return out


def read_tsv_2col(path):
    """Read a 2+ col TSV into a dict {col1: col2}. None/missing → {}."""
    if path is None:
        return {}
    p = Path(path)
    if not p.exists():
        return {}
    out = {}
    for line in p.read_text().splitlines():
        cols = line.split('\t')
        if len(cols) >= 2:
            out[cols[0]] = cols[1]
    return out


def read_sig(path):
    """Read a needs-fix sig file (one location per line) into a set.
    Returns None for the missing/None case (distinguishes 'no prev round' from
    'empty prev round')."""
    if path is None:
        return None
    p = Path(path)
    if not p.exists():
        return None
    return set(line for line in p.read_text().splitlines() if line.strip())


# === MergeState (used by `merge` subcommand) ================================

def iter_num(path):
    m = re.search(r'iter-(\d+)-verified', Path(path).stem)
    return int(m.group(1)) if m else -1


def collect_iter_files(workdir):
    # iter-0-verified.md, when present, is the carry-forward anchor (a copy of
    # the prior run's cumulative review.md). Including it preserves issues the
    # current run's reviewer chose to omit — otherwise the prior [需修正] items
    # would vanish from the new cumulative report once carried forward.
    files = [p for p in Path(workdir).glob("iter-*-verified.md") if iter_num(p) >= 0]
    return sorted(files, key=iter_num)


class MergeState:
    def __init__(self):
        self.preamble = None
        self.section_order = []
        self.issues_by_section = {}
        self.location_index = {}
        self.meta_sections = {}
        self.per_round = []

    def absorb(self, path):
        n = iter_num(path)
        preamble, order, sections = parse_file(path)
        if self.preamble is None:
            self.preamble = preamble

        round_counts = dict.fromkeys(VERDICTS, 0)

        for section_name in order:
            if section_name in SECTIONS_TO_REGENERATE:
                continue
            if section_name not in self.section_order:
                self.section_order.append(section_name)
            body = sections[section_name]

            if section_name in ISSUE_SECTIONS:
                self.issues_by_section.setdefault(section_name, [])
                for kind, block in split_blocks(body):
                    if kind == 'issue':
                        self._absorb_issue_block(section_name, block, n, round_counts)
            else:
                self.meta_sections[section_name] = body

        self.per_round.append((n, round_counts))

    def _absorb_issue_block(self, section_name, block, n, round_counts):
        loc = extract_location(block)
        if loc is None:
            return
        verdict, evidence = extract_verdict_evidence(block)
        # iter-0 is the carry-forward anchor (copy of prior run's review.md).
        # Entries without a verdict marker carry no actionable information —
        # they're either pre-verifier reviewer output or remnants of an earlier
        # broken merge. Skip them so they don't pollute the cumulative report
        # with verdict-less blocks and create line-drift duplicates against the
        # current run's verdict-tagged entries.
        if n == 0 and verdict is None:
            sys.stderr.write(
                f"merge: dropping iter-0 anchor entry at {loc} (no verdict marker)\n"
            )
            return
        if verdict in round_counts:
            round_counts[verdict] += 1

        if loc not in self.location_index:
            idx = len(self.issues_by_section[section_name])
            # iter-0 is the carry-forward anchor (copy of prior review.md). Its
            # blocks already carry an `_(origin: iter-N)_` annotation from the
            # prior run's merge — don't double-stamp.
            block_with_origin = block if n == 0 else annotate_origin(block, n)
            self.issues_by_section[section_name].append({
                'loc': loc,
                'block': block_with_origin,
                'verdict': verdict,
            })
            self.location_index[loc] = (section_name, idx)
            return

        sec, idx = self.location_index[loc]
        entry = self.issues_by_section[sec][idx]
        if verdict and evidence:
            entry['block'] = splice_verdict_in_block(entry['block'], verdict, evidence)
            entry['verdict'] = verdict

    def ordered_sections(self):
        canonical = [s for s in CANONICAL_ORDER if s in self.section_order]
        unknown = [s for s in self.section_order if s not in CANONICAL_ORDER]
        return canonical + unknown

    def render(self, stats_tsv):
        out = []
        if self.preamble:
            out.extend(self.preamble)
            if out and out[-1].strip() != "":
                out.append("")

        for section_name in self.ordered_sections():
            out.append(f"## {section_name}")
            out.append("")
            if section_name in ISSUE_SECTIONS:
                for entry in self.issues_by_section.get(section_name, []):
                    block = entry['block']
                    while block and block[-1].strip() == "":
                        block = block[:-1]
                    out.extend(block)
                    out.append("")
            else:
                body = list(self.meta_sections.get(section_name, []))
                while body and body[0].strip() == "":
                    body.pop(0)
                while body and body[-1].strip() == "":
                    body.pop()
                out.extend(body)
                out.append("")

        final_counts = dict.fromkeys(ALL_VERDICTS, 0)
        for entries in self.issues_by_section.values():
            for entry in entries:
                v = entry.get('verdict')
                if v in final_counts:
                    final_counts[v] += 1

        out.append("")
        out.append("## Verification Summary")
        out.append("")
        out.append("Cumulative across all iterations (each issue counted once with its latest verdict).")
        out.append("")
        out.append("| 結論   | 數量 |")
        out.append("| ------ | ---- |")
        show_verdicts = ALL_VERDICTS if final_counts.get(VERDICT_FIXED, 0) > 0 else VERDICTS
        for v in show_verdicts:
            out.append(f"| {v} | {final_counts[v]} |")

        # Skip iter-0 (carry-forward anchor) — stats.tsv only covers current-run
        # iters 1..N; rendering iter-0 with empty Critical/Performance/Maint
        # cells would be misleading. The cumulative count above already
        # reflects iter-0's contribution.
        per_round_current = [(n, rc) for n, rc in self.per_round if n >= 1]
        if per_round_current:
            stats = _read_stats_tsv(stats_tsv)
            out.append("")
            out.append("### Per-round breakdown")
            out.append("")
            header_cells = ["iter", "Critical", "Performance", "Maintainability", *VERDICTS]
            out.append("| " + " | ".join(header_cells) + " |")
            out.append("|" + "|".join("------" for _ in header_cells) + "|")
            for n, rc in per_round_current:
                cc, cp, cm = stats.get(n, (None, None, None))
                cells = [
                    str(n),
                    str(cc) if cc is not None else "-",
                    str(cp) if cp is not None else "-",
                    str(cm) if cm is not None else "-",
                    *(str(rc[v]) for v in VERDICTS),
                ]
                out.append("| " + " | ".join(cells) + " |")

        out.append("")
        return "\n".join(out)


def _read_stats_tsv(path):
    out = {}
    if path is None or not Path(path).exists():
        return out
    for line in Path(path).read_text().splitlines():
        cols = line.split("\t")
        if len(cols) < 4:
            continue
        try:
            out[int(cols[0])] = (int(cols[1]), int(cols[2]), int(cols[3]))
        except ValueError:
            pass
    return out


# === Subcommands ============================================================

def cmd_merge(args):
    iter_files = collect_iter_files(args.workdir)
    if not iter_files:
        sys.exit(f"No iter-*-verified.md files found in {args.workdir}")
    state = MergeState()
    for p in iter_files:
        state.absorb(p)
    Path(args.output).write_text(state.render(args.stats_tsv))
    print(f"Cumulative final report: {args.output} ({len(iter_files)} iter(s) merged)")


def cmd_count_sections(args):
    """Print 'CC CP CM LOC' — issue counts per section plus total Location markers.

    The trailing LOC count lets the bash driver detect format-violation cases
    (verifier emitted zero annotations but reviewer authored issues) without
    needing its own grep.
    """
    counts = dict.fromkeys(ISSUE_SECTIONS, 0)
    loc_count = 0
    p = Path(args.path)
    if p.exists():
        section = None
        for line in p.read_text().splitlines():
            m = SECTION_RE.match(line)
            if m:
                section = normalize_section_name(m.group(1))
                continue
            if section in counts and BULLET_RE.match(line):
                counts[section] += 1
            if LOCATION_RE.search(line):
                loc_count += 1
    print(' '.join(str(counts[s]) for s in ISSUE_SECTIONS) + f' {loc_count}')


def emit_sorted_unique_tsv(records):
    """Print 3-col TSV records sorted unique by column 1 (location key)."""
    seen = set()
    for key, verdict, evidence in sorted(records, key=lambda r: r[0]):
        if key in seen:
            continue
        seen.add(key)
        print(f"{key}\t{verdict}\t{evidence}")


def cmd_extract_annotations(args):
    """Parse [verdict]/Evidence pairs from a verified.md into sorted 3-col TSV.

    Output columns: <path:line> <TAB> <verdict> <TAB> <full Evidence line>
    """
    p = Path(args.path)
    if not p.exists():
        return
    records = []
    current_verdict = None
    for line in p.read_text().splitlines():
        vm = VERDICT_RE.match(line)
        if vm:
            current_verdict = vm.group(1)
            continue
        if current_verdict and EVIDENCE_RE.match(line):
            m = PATH_LINE_RE.search(line)
            key = m.group(0) if m else line
            records.append((key, current_verdict, line))
            current_verdict = None
    emit_sorted_unique_tsv(records)


def cmd_parse_verifier_raw(args):
    """Parse verifier stdout (V_RAW) into 3-col annotations TSV.

    Verifier emits records of form:
        [verdict]
        Location: path:line
        Evidence: path:line — ...

    Location anchors the key (preferred); falls back to path in Evidence.
    """
    p = Path(args.path)
    if not p.exists():
        return
    records = []
    verdict = None
    loc = None
    for line in p.read_text().splitlines():
        vm = VERDICT_RE.match(line)
        if vm:
            verdict = vm.group(1)
            loc = None
            continue
        m = LOCATION_RE.match(line)
        if m:
            loc = m.group(1)
            continue
        if line.startswith('Evidence:'):
            if verdict and loc:
                records.append((loc, verdict, line))
            verdict = None
            loc = None
    emit_sorted_unique_tsv(records)


def cmd_splice(args):
    """Emit review.md with [verdict]+Evidence prepended above each Location line.

    `ann_tsv` is the 3-col TSV produced by parse-verifier-raw (or extract-annotations).
    The first column is the canonical path:line key extracted from each issue's
    Location bullet.
    """
    ann = {}
    p = Path(args.ann_tsv)
    if p.exists():
        for line in p.read_text().splitlines():
            cols = line.split('\t', 2)
            if len(cols) >= 3:
                ann[cols[0]] = (cols[1], cols[2])

    used = set()
    out = sys.stdout
    for line in Path(args.review).read_text().splitlines():
        m = LOCATION_RE.search(line)
        if m and m.group(1) in ann and m.group(1) not in used:
            verdict, evidence = ann[m.group(1)]
            out.write(f"[{verdict}]\n")
            out.write(evidence + "\n")
            used.add(m.group(1))
        out.write(line + "\n")


def cmd_verification_summary(args):
    """Emit a '## Verification Summary' block.

    If V_RAW already contains one, echo from that line to EOF. Otherwise
    synthesize from the count of each verdict in ann.tsv.
    """
    v_raw = Path(args.v_raw)
    if v_raw.exists():
        text = v_raw.read_text()
        m = re.search(r'(?m)^## Verification Summary', text)
        if m:
            sys.stdout.write(text[m.start():])
            if not text.endswith('\n'):
                sys.stdout.write('\n')
            return

    counts = dict.fromkeys(VERDICTS, 0)
    ann = Path(args.ann_tsv)
    if ann.exists():
        for line in ann.read_text().splitlines():
            cols = line.split('\t')
            if len(cols) >= 2 and cols[1] in counts:
                counts[cols[1]] += 1
    print("## Verification Summary")
    print()
    print("| 結論     | 數量 |")
    print("| -------- | ---- |")
    for v in VERDICTS:
        print(f"| {v}   | {counts[v]}    |")


def cmd_reannotate(args):
    """Update inline [verdict]+Evidence in a verified.md from an annotations TSV.

    Walks every issue block in the file. If the block's Location key exists in
    the TSV with a different verdict, the block's [verdict] and Evidence lines
    are replaced in-place. Writes result to stdout (or overwrites in-place when
    --in-place is set).
    """
    ann = {}
    ann_path = Path(args.ann_tsv)
    if ann_path.exists():
        for line in ann_path.read_text().splitlines():
            cols = line.split('\t', 2)
            if len(cols) >= 3:
                ann[cols[0]] = (cols[1], cols[2])

    preamble, order, sections = parse_file(args.path)
    out = list(preamble)

    for section_name in order:
        out.append(f"## {section_name}")
        body = sections[section_name]
        if section_name in ISSUE_SECTIONS:
            for kind, block in split_blocks(body):
                if kind == 'issue':
                    loc = extract_location(block)
                    if loc and loc in ann:
                        verdict, evidence = ann[loc]
                        block = splice_verdict_in_block(block, verdict, evidence)
                out.extend(block)
        else:
            out.extend(body)

    text = '\n'.join(out) + '\n'
    if args.in_place:
        Path(args.path).write_text(text)
    else:
        sys.stdout.write(text)


def cmd_derive_sidecars(args):
    """3-col ann.tsv → 2-col verdicts.tsv (loc, verdict) + needs-fix sig (loc only)."""
    seen = read_tsv_2col(args.ann_tsv)
    sorted_locs = sorted(seen)
    Path(args.verdicts_out).write_text(
        ''.join(f"{loc}\t{seen[loc]}\n" for loc in sorted_locs)
    )
    Path(args.sig_out).write_text(
        ''.join(f"{loc}\n" for loc in sorted_locs if seen[loc] == VERDICTS[0])
    )


def cmd_diff_rounds(args):
    """Compare two rounds and report stop-check numbers.

    Stdout: one `KEY=VALUE` per line, suitable for bash `eval`. Keys:
      NEW RESOLVED CARRIED FLIPPED N_NEEDS_FIX N_IGNORED N_NONEXISTENT

    Adding a field here only requires the bash caller to opt into reading it —
    existing keys keep their value, no positional reshuffle.

    Optionally writes flip details (`  <loc>: [<prev>]→[<curr>]` per line) to
    --flip-detail-out; file is empty when no flips occurred.
    """
    curr_sig = read_sig(args.curr_sig) or set()
    prev_sig = read_sig(args.prev_sig)
    curr = read_tsv_2col(args.curr_tsv)
    prev = read_tsv_2col(args.prev_tsv)

    if prev_sig is None:
        new = len(curr_sig)
        resolved = 0
    else:
        new = len(curr_sig - prev_sig)
        resolved = len(prev_sig - curr_sig)

    common = sorted(set(prev) & set(curr))
    carried = sum(1 for k in common if prev[k] == curr[k])
    flips = [(k, prev[k], curr[k]) for k in common if prev[k] != curr[k]]
    flipped = len(flips)

    curr_counts = dict.fromkeys(VERDICTS, 0)
    for v in curr.values():
        if v in curr_counts:
            curr_counts[v] += 1

    if args.flip_detail_out:
        Path(args.flip_detail_out).write_text(
            ''.join(f"  {k}: [{a}]→[{b}]\n" for k, a, b in flips)
        )

    print(f"NEW={new}")
    print(f"RESOLVED={resolved}")
    print(f"CARRIED={carried}")
    print(f"FLIPPED={flipped}")
    print(f"N_NEEDS_FIX={curr_counts[VERDICTS[0]]}")
    print(f"N_IGNORED={curr_counts[VERDICTS[1]]}")
    print(f"N_NONEXISTENT={curr_counts[VERDICTS[2]]}")


def cmd_summary_table(args):
    """Render the per-round breakdown table from stats.tsv to stdout."""
    print("| round | Critical | Performance | Maintainability | 需修正 | 可忽略 | 不存在 | 新增[需修正] |")
    print("|-------|----------|-------------|-----------------|--------|--------|--------|---------------|")
    p = Path(args.stats_tsv)
    if not p.exists():
        return
    for line in p.read_text().splitlines():
        cols = line.split('\t')
        if len(cols) < 8:
            continue
        n, cc, cp, cm, nf, ig, ne, new = cols[:8]
        print(f"| {n:>5} | {cc:>8} | {cp:>11} | {cm:>15} | {nf:>6} | {ig:>6} | {ne:>6} | {new:>13} |")


# === CLI dispatcher =========================================================

def main():
    parser = argparse.ArgumentParser(prog='multi-review-tools')
    sub = parser.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('merge')
    p.add_argument('workdir')
    p.add_argument('output')
    p.add_argument('stats_tsv', nargs='?')
    p.set_defaults(func=cmd_merge)

    p = sub.add_parser('count-sections')
    p.add_argument('path')
    p.set_defaults(func=cmd_count_sections)

    p = sub.add_parser('extract-annotations')
    p.add_argument('path')
    p.set_defaults(func=cmd_extract_annotations)

    p = sub.add_parser('parse-verifier-raw')
    p.add_argument('path')
    p.set_defaults(func=cmd_parse_verifier_raw)

    p = sub.add_parser('splice')
    p.add_argument('review')
    p.add_argument('ann_tsv')
    p.set_defaults(func=cmd_splice)

    p = sub.add_parser('verification-summary')
    p.add_argument('v_raw')
    p.add_argument('ann_tsv')
    p.set_defaults(func=cmd_verification_summary)

    p = sub.add_parser('reannotate')
    p.add_argument('path')
    p.add_argument('ann_tsv')
    p.add_argument('--in-place', action='store_true')
    p.set_defaults(func=cmd_reannotate)

    p = sub.add_parser('derive-sidecars')
    p.add_argument('ann_tsv')
    p.add_argument('verdicts_out')
    p.add_argument('sig_out')
    p.set_defaults(func=cmd_derive_sidecars)

    p = sub.add_parser('diff-rounds')
    p.add_argument('--prev-tsv', default=None)
    p.add_argument('--curr-tsv', required=True)
    p.add_argument('--prev-sig', default=None)
    p.add_argument('--curr-sig', required=True)
    p.add_argument('--flip-detail-out', default=None)
    p.set_defaults(func=cmd_diff_rounds)

    p = sub.add_parser('summary-table')
    p.add_argument('stats_tsv')
    p.set_defaults(func=cmd_summary_table)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
