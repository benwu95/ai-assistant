# Review Report Format

Single source of truth for the structured code-review report, shared by the `code-reviewer` agent and the `python-code-review` skill.

## Location Convention

All `Location` fields use this format: `path/to/file:LINE` (or `:START-END` for ranges).
- **Added or modified code** → use **new-side** line number (post-change).
- **Deleted code** → use **old-side** line number and append ` (deleted)`, e.g., `services/auth.py:42 (deleted)`.
- Multiple locations allowed if the same issue spans several places.

## Report Template

Report **MUST** follow the below format

```
# Report
branch: {currentBranch}
## Summary
[Overall architectural assessment and risk level]

## Changelog
[List changes about object update, function logic, and API flow]

## Critical Issues
> Scope: **Only severe issues that MUST be modified.** Each entry must have a concrete, actionable code change. Do NOT list stylistic concerns, speculative risks, or items already correctly handled. If there are no qualifying issues, write "None" — do not pad this section.
- **[Title]**
  - **Location**: REQUIRED. Follow the **Location Convention**.
  - **Original Logic**: [Describe the current execution/state flow]
  - **Suggested Logic**: [Describe the proposed fix and why it works better]
  - **Suggested Code**: [REQUIRED. Provide the specific, drop-in-applicable corrected code snippet — not pseudocode.]
  - **Impact**: [Security vulnerability, memory leak, or data corruption risk]

## Performance & Optimization
> Scope: Areas in the **current code that can be improved** (not yet implemented). Do NOT list optimizations already present in the code here.
- **[Title]**
  - **Location**: REQUIRED. Follow the **Location Convention**.
  - **Bottleneck**: [Describe the current performance issue and where it occurs, e.g., N+1 query in a data-fetch function.]
  - **Suggested Code**: [Provide the specific, corrected code snippet.]
  - **Optimization Technique**: [Name and explain the high-level strategy, e.g., "Eager Loading to pre-fetch related data."]
  - **Benefit**: [Quantifiable improvement or scalability gain, e.g., "Reduces DB queries from N+1 to 2."]

## Maintainability & Architecture
> Scope: Structural concerns — DRY violations, stringly-typed business logic, parameter sprawl, leaky abstractions, missing Enum types, abstraction-depth violations. NOT bugs, but degrade long-term maintainability. If there are no qualifying items, write "None".
- **[Title]**
  - **Location**: REQUIRED. Follow the **Location Convention**.
  - **Concern**: [Describe the maintainability or architecture issue]
  - **Suggested Refactor**: [Specific code snippet or refactor strategy — not abstract advice]
  - **Rationale**: [Link to code-quality principles — Rule of Three, SRP, Layer Limits, Enums over Literals, etc.]

## Good Practices Observed
> Scope: Good practices **already implemented** in the current code. Do NOT include suggestions or improvements here.
- [List exceptional patterns or clever language/framework usage that exist in the diff]
```

Write the report to `.tasks/{currentBranch}/review.md` unless the caller explicitly specifies a different output path — caller output instructions override this default.
