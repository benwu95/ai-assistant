---
name: review-to-pr
description: Sync an existing local review report to its GitHub PR as one bundled inline review, skipping findings already covered by PR comments. Verify the authenticated user's unresolved review threads and offer to resolve completed discussions. Use when asked to publish or sync review findings to a PR or reconcile old review threads; does not generate a new code review.
---

# Review to PR

Use this workflow in Claude Code, Codex, or Antigravity (agy) with the host's available tools.

## Inputs and requirements

- Optional `review_path`: accept a path supplied in the user's message or skill arguments. Otherwise look for `.tasks/{currentBranch}/review-merged.md`, then `.tasks/{currentBranch}/review.md`.
- Require a Git checkout, `git`, authenticated `gh` with access to the target repository, and `jq` for the command examples.
- Store intermediate files and draft payloads in `.tasks/{currentBranch}/review-to-pr/`.
- If a required input or capability is missing, explain what is missing and pause dependent work.

## Host adaptation

- Use available shell and file tools; do not depend on tool names such as Bash, Read, Write, or AskUserQuestion.
- Use a supported question tool for interaction when appropriate. If unavailable or unsuitable for approval, present a numbered text prompt and wait for the user's reply. A default selection, timeout, or lack of reply is not consent.
- Parallelize independent reads only after resolving their inputs. Sequential execution is valid.
- Subagents are optional for large verification batches. Without delegation, perform the same checks in the main agent. Do not require a particular installed agent definition.
- This skill grants no extra filesystem, network, or account permissions; use the host's normal permission mechanism.

## Workflow

Read [the execution workflow](references/workflow.md) before starting. Read [Taiwan terminology](references/taiwan-terminology.md) when composing user-facing comments.

1. Resolve the branch, target PR, head commit, authenticated account, and review report.
2. Fetch all existing PR comments, review bodies, and review threads, including pagination.
3. Verify unresolved threads opened by the authenticated account against the PR head. Show classifications and the proposed selection; resolve only the explicitly approved threads.
4. Compare report findings with existing discussion and record covered or unanchorable items as skipped.
5. Prepare Traditional Chinese inline comments and a single `COMMENT` review payload. Show a concrete preview and allow viewing, editing, sending, or cancellation.
6. After explicit approval, submit the approved payload once, verify the result, and report the review URL, posted/skipped counts, and resolve results.

## Invariants

- GitHub writes are limited to approved thread resolution and review submission. Prepare all drafts before requesting approval for those writes.
- Do not edit source code or the input report, rerun a review workflow, push commits, close the PR, approve it, or request changes.
- Resolve only threads opened by the authenticated account. Never resolve threads created by this run.
- Keep fixed/won't-fix classifications as proposed selections; they do not authorize resolution. Disputed or unfixed threads require explicit user selection.
- When there is nothing new to post, finish with the skipped and resolve summary without a submission confirmation loop.
- On cancellation, retain the draft payload and report its path.
