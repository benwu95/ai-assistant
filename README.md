# AI Assistant

Custom agents, skills, commands, and scripts for AI coding assistants.

## Structure

```
agents/          Specialized subagent definitions
commands/        Slash command definitions
scripts/         Supporting shell/Python scripts
shared/          Shared resources (e.g. terminology)
skills/          Skill definitions (branch-diff, python-code-review, sqlalchemy-with-postgresql)
statusline/      Status line scripts for CLI harnesses
system.md        Global system prompt
```

## Generated Artifacts

All files produced by skills, commands, and the system workflow are stored under the **`.tasks/{currentBranch}/`** directory of the target repository (resolved per current git branch). This keeps generated artifacts colocated with the branch they describe and isolated from source code.

| Producer | Type | Output Path |
|---|---|---|
| `branch-diff` | skill | `.tasks/{currentBranch}/branch-diff.md` |
| `python-code-review` | skill | `.tasks/{currentBranch}/review.md` |
| `sqlalchemy-with-postgresql` | skill | _(knowledge-only, no file output)_ |
| `multi-review` | command | `.tasks/{currentBranch}/review.md` + `.tasks/{currentBranch}/review/{timestamp}/` |
| `review-to-pr` | command | reads `.tasks/{currentBranch}/review-merged.md` / `review.md`; intermediates in `.tasks/{currentBranch}/review-to-pr/` |
| `system.md` | workflow | `.tasks/{currentBranch}/todo.md`, `.tasks/{currentBranch}/lessons.md` |

When adding a new skill or command that writes files, follow the same convention: resolve `currentBranch` via `git rev-parse --abbrev-ref HEAD` and write to `.tasks/{currentBranch}/<artifact>.md`.

## Setup

Clone the repo and create a CLI-independent symlink. All agents/skills reference `~/.ai-assistant/shared/`, and each CLI's config symlinks also point through `~/.ai-assistant/` — so moving the repo only requires updating one symlink.

```bash
git clone git@github.com:benwu95/ai-assistant.git ~/workspace/ai-assistant
ln -s ~/workspace/ai-assistant ~/.ai-assistant
```

### Claude Code

```bash
ln -s ~/.ai-assistant/system.md  ~/.claude/CLAUDE.md
ln -s ~/.ai-assistant/agents     ~/.claude/agents
ln -s ~/.ai-assistant/commands   ~/.claude/commands
ln -s ~/.ai-assistant/scripts    ~/.claude/scripts
ln -s ~/.ai-assistant/skills     ~/.claude/skills
```

### Antigravity CLI

```bash
ln -s ~/.ai-assistant/system.md  ~/.gemini/GEMINI.md
ln -s ~/.ai-assistant/skills     ~/.gemini/antigravity-cli/skills
```

### Codex CLI

```bash
ln -s ~/.ai-assistant/system.md  ~/.codex/AGENTS.md
ln -s ~/.ai-assistant/skills     ~/.agents/skills
```

### Copilot CLI

```bash
ln -s ~/.ai-assistant/system.md  ~/.copilot/copilot-instructions.md
ln -s ~/.ai-assistant/skills     ~/.agents/skills  # shared with Codex CLI; skip if already linked
```

## Recommended Plugins

[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) — production-grade engineering skills (plan, build, review, ship, TDD, etc.) that complement the skills in this repo.

Division of labor: generic workflows (planning, incremental build, TDD/QA, five-axis review) are delegated to the plugin. This repo keeps only what the plugin does not cover — pipeline-specific tooling (`multi-review`, `review-to-pr`, `multi-review-verifier`, the `code-reviewer` agent that emits the `.tasks/{currentBranch}/review.md` report format) and deep domain knowledge (`python-code-review`, `sqlalchemy-with-postgresql`, `database-architect`).

```bash
# Claude Code
/plugin marketplace add addyosmani/agent-skills
/plugin install agent-skills@addy-agent-skills

# Other CLIs (universal skills CLI)
npx skills add addyosmani/agent-skills
```
