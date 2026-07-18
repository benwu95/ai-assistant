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

**Prerequisites:** `git`; on Windows, creating symlinks requires Developer Mode (Settings > Privacy & security > For developers) or running PowerShell as Administrator.

Run the one-liner for your platform. It clones the repo into `~/.ai-assistant` (override with `AI_ASSISTANT_DIR`) and links each installed CLI's config through it:

```bash
# Unix / macOS
curl -fsSL https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.sh | bash
```

```powershell
# Windows PowerShell
powershell -c "irm https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.ps1 | iex"
```

By default it auto-detects installed CLIs. To link every supported CLI (creating config dirs) or only named ones, pass arguments after `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.sh | bash -s -- --all
curl -fsSL https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.sh | bash -s -- claude codex
```

Supported CLI names: `claude` `antigravity` `codex` `copilot`.

Re-running is safe (idempotent): an existing clone is updated (`git pull --ff-only`), stale symlinks are refreshed, and any existing real file at a link path is backed up to `<name>.bak.<timestamp>` first.

### Already have a local clone?

If you cloned the repo yourself (e.g. to hack on it), run the installer with `--local` (`-Local` on Windows) instead of letting it clone a second copy. This makes `~/.ai-assistant` a symlink pointing at *your* checkout, so your edits are live and relocating the repo later only means repointing that one symlink. Arguments combine as usual:

```bash
git clone git@github.com:benwu95/ai-assistant.git ~/workspace/ai-assistant
cd ~/workspace/ai-assistant

# Unix / macOS
./install.sh --local              # symlink this checkout + auto-detect CLIs
./install.sh --local --all        # ... + link every supported CLI
./install.sh --local claude codex # ... + link only the named CLIs

# Windows PowerShell
.\install.ps1 -Local
.\install.ps1 -Local -All
.\install.ps1 -Local claude codex
```

(Running the installer straight from a checkout — `./install.sh` with no `--local` — links that checkout too; `--local` just makes the intent explicit and refuses to fall back to cloning.)

## Recommended Plugins

[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) — production-grade engineering skills (plan, build, review, ship, TDD, etc.) that complement the skills in this repo.

Division of labor: generic workflows (planning, incremental build, TDD/QA, five-axis review) are delegated to the plugin. This repo keeps only what the plugin does not cover — pipeline-specific tooling (`multi-review`, `review-to-pr`, `multi-review-verifier`, the `code-reviewer` agent that emits the `.tasks/{currentBranch}/review.md` report format) and deep domain knowledge (`python-code-review`, `sqlalchemy-with-postgresql`, `database-architect`).

```bash
# Claude Code
/plugin marketplace add addyosmani/agent-skills
/plugin install agent-skills@addy-agent-skills

# Antigravity CLI (installs to ~/.gemini/antigravity-cli/plugins/agent-skills/)
agy plugin install https://github.com/addyosmani/agent-skills.git

# Other CLIs (universal skills CLI)
npx skills add addyosmani/agent-skills
```
