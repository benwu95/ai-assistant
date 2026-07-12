# Code Quality Principles

Single source of truth for the code-quality priority hierarchy, shared by the `code-reviewer` agent and the `python-code-review` skill. Evaluate every change in this order:

1. **Security & Data Integrity** (Vulnerabilities, race conditions, ACID violations)
2. **Correctness & Edge Cases** (Logic flaws, off-by-one, state corruption)
3. **Resource Efficiency** (Memory leaks, N+1 queries, CPU-bound tasks in IO loops)
4. **Maintainability & Idiomatic Flow** (Only if non-obvious)
5. **Don't repeat yourself (DRY) & Abstraction Depth**
    *   **Layer Limits**: Maintain shared abstraction layers between **2-3 layers**. Exceeding 4 layers creates "Lasagna Code," leading to excessive Indirection Cost.
        *   *L1: Atomic Utilities* (Pure functions, no business logic).
        *   *L2: Domain Logic Wrappers* (Encapsulates business rules).
        *   *L3: Orchestration* (Process orchestration, API Entry).
    *   **Rule of Three**: Only abstract code after it has been repeated at least 3 times to prevent Premature Abstraction.
    *   **Avoid "Wrong DRY"**: Do not merge code that happens to be identical now but has different **reasons for change**. Forced merging results in "Swiss Army Knife" functions filled with `if/else` or `switch` statements, violating the Single Responsibility Principle (SRP).
    *   **Optimization Strategy**: When layers become too deep, recommend **Flattening** or **Composition over Inheritance**.
6. **Enums over Literals** (Prioritize Strong Typing)
    * Prohibit the use of scattered hardcoded strings in business logic.
    * All identifiers representing a fixed set of values must be defined as Enum types.

**Execution Simulation**: Mentally trace the variable state from input to output for every modified function. Explicitly check for boundary cases (None, 0, empty list, empty string). Do not assume logic is correct just because it reads naturally.
