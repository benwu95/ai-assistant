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

Clone the repo and symlink into each agent CLI's config directory.

```bash
git clone git@github.com:benwu95/ai-assistant.git ~/workspace/ai-assistant
```

### Claude Code

```bash
ln -s ~/workspace/ai-assistant/system.md  ~/.claude/CLAUDE.md
ln -s ~/workspace/ai-assistant/agents     ~/.claude/agents
ln -s ~/workspace/ai-assistant/commands   ~/.claude/commands
ln -s ~/workspace/ai-assistant/scripts    ~/.claude/scripts
ln -s ~/workspace/ai-assistant/shared     ~/.claude/shared
ln -s ~/workspace/ai-assistant/skills     ~/.claude/skills
```

### Gemini CLI

```bash
# System prompt (add to shell profile)
export GEMINI_SYSTEM_MD=~/workspace/ai-assistant/system.md

ln -s ~/workspace/ai-assistant/agents     ~/.gemini/agents
ln -s ~/workspace/ai-assistant/skills     ~/.gemini/skills
```

### Codex CLI

```bash
ln -s ~/workspace/ai-assistant/system.md  ~/.codex/AGENTS.md
ln -s ~/workspace/ai-assistant/skills     ~/.agents/skills
```
