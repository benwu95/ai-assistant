# AI Assistant

Custom agents, skills, commands, and scripts for AI coding assistants.

## Structure

```
agents/          Specialized subagent definitions
commands/        Slash command definitions
scripts/         Supporting shell/Python scripts
shared/          Shared resources (e.g. terminology)
skills/          Skill definitions (branch-diff, python-code-review, sqlalchemy-with-postgresql)
system.md        Global system prompt
```

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

### Gemini CLI

```bash
# System prompt (add to shell profile)
export GEMINI_SYSTEM_MD=~/.ai-assistant/system.md

ln -s ~/.ai-assistant/agents     ~/.gemini/agents
ln -s ~/.ai-assistant/skills     ~/.gemini/skills
```

### Codex CLI

```bash
ln -s ~/.ai-assistant/system.md  ~/.codex/AGENTS.md
ln -s ~/.ai-assistant/skills     ~/.agents/skills
```
