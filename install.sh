#!/usr/bin/env bash
#
# Install symlinks for the ai-assistant repo (Unix / macOS).
#
# Run from a local checkout:
#   ./install.sh              auto-detect installed CLIs and link them
#   ./install.sh --local      symlink this checkout into ~/.ai-assistant, then link
#   ./install.sh --all        link every supported CLI (creating config dirs)
#   ./install.sh claude codex link only the named CLIs
#
# Or bootstrap directly (clones the repo into ~/.ai-assistant, then links):
#   curl -fsSL https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.sh | bash -s -- --all
#
# Supported CLI names: claude antigravity codex copilot
#
set -euo pipefail

REPO_URL="https://github.com/benwu95/ai-assistant.git"
AIHOME="$HOME/.ai-assistant"

# Resolve the repo root. Running from a local checkout (or with --local) uses
# the script's own directory. Piped from curl (no script file on disk) clones/
# updates the repo into ~/.ai-assistant (override with AI_ASSISTANT_DIR).
resolve_repo_root() {
    local source="${BASH_SOURCE[0]:-}"
    if [ -n "$source" ] && [ -f "$source" ]; then
        REPO_ROOT="$(cd "$(dirname "$source")" && pwd)"
        return
    fi
    if [ "$force_local" -eq 1 ]; then
        echo "--local requires running from a local clone (e.g. ./install.sh --local); nothing to link when piped." >&2
        exit 1
    fi
    local dest="${AI_ASSISTANT_DIR:-$AIHOME}"
    if [ -d "$dest/.git" ]; then
        echo "Updating existing clone at $dest"
        git -C "$dest" pull --ff-only || echo "  (pull failed; using existing checkout)"
    else
        echo "Cloning $REPO_URL -> $dest"
        mkdir -p "$(dirname "$dest")"
        git clone "$REPO_URL" "$dest"
    fi
    REPO_ROOT="$dest"
}

# --- helpers ---------------------------------------------------------------

link() {
    # link <target> <linkpath>
    local target="$1" linkpath="$2"
    mkdir -p "$(dirname "$linkpath")"

    if [ -L "$linkpath" ]; then
        rm -f "$linkpath"                       # replace stale symlink
    elif [ -e "$linkpath" ]; then
        local backup="${linkpath}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$linkpath" "$backup"                # never clobber a real file/dir
        echo "  backed up existing $linkpath -> $backup"
    fi

    ln -s "$target" "$linkpath"
    echo "  linked $linkpath -> $target"
}

cli_installed() {
    # a CLI counts as installed if its base config dir already exists
    [ -d "$1" ]
}

print_recommended_plugins() {
    # echo the "## Recommended Plugins" section straight from the README
    # (single source of truth), stripping code-fence lines for the terminal
    local readme="$REPO_ROOT/README.md"
    [ -f "$readme" ] || return 0
    echo ""
    awk '
        /^## Recommended Plugins/ {f=1}
        f && /^## / && !/Recommended Plugins/ {f=0}
        f && $0 !~ /^```/ {print}
    ' "$readme"
}

# --- per-CLI link sets ------------------------------------------------------

link_claude() {
    echo "Claude Code:"
    link "$AIHOME/system.md" "$HOME/.claude/CLAUDE.md"
    link "$AIHOME/agents"    "$HOME/.claude/agents"
    link "$AIHOME/commands"  "$HOME/.claude/commands"
    link "$AIHOME/scripts"   "$HOME/.claude/scripts"
    link "$AIHOME/skills"    "$HOME/.claude/skills"
}

link_antigravity() {
    echo "Antigravity CLI:"
    link "$AIHOME/system.md" "$HOME/.gemini/GEMINI.md"
    link "$AIHOME/skills"    "$HOME/.gemini/antigravity-cli/skills"
}

link_codex() {
    echo "Codex CLI:"
    link "$AIHOME/system.md" "$HOME/.codex/AGENTS.md"
    link "$AIHOME/skills"    "$HOME/.agents/skills"
}

link_copilot() {
    echo "Copilot CLI:"
    link "$AIHOME/system.md" "$HOME/.copilot/copilot-instructions.md"
    link "$AIHOME/skills"    "$HOME/.agents/skills"   # shared with Codex CLI
}

# base config dir for auto-detection, keyed by CLI name
base_dir() {
    case "$1" in
        claude)      echo "$HOME/.claude" ;;
        antigravity) echo "$HOME/.gemini" ;;
        codex)       echo "$HOME/.codex" ;;
        copilot)     echo "$HOME/.copilot" ;;
    esac
}

# --- argument parsing -------------------------------------------------------

ALL_CLIS="claude antigravity codex copilot"
selected=""
force_all=0
force_local=0

for arg in "$@"; do
    case "$arg" in
        --all)   force_all=1 ;;
        --local) force_local=1 ;;
        claude|antigravity|codex|copilot) selected="$selected $arg" ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ "$force_all" -eq 1 ]; then
    selected="$ALL_CLIS"
elif [ -z "$selected" ]; then
    for cli in $ALL_CLIS; do
        if cli_installed "$(base_dir "$cli")"; then
            selected="$selected $cli"
        fi
    done
    if [ -z "$selected" ]; then
        echo "No installed CLI detected. Use --all to link every CLI, or name them explicitly." >&2
        exit 1
    fi
fi

# --- run --------------------------------------------------------------------

resolve_repo_root
echo "Repo root: $REPO_ROOT"

# core: the single indirection symlink everything else points through.
# Skipped when the repo was bootstrapped directly into ~/.ai-assistant.
if [ "$REPO_ROOT" != "$AIHOME" ]; then
    if [ -L "$AIHOME" ] || [ ! -e "$AIHOME" ]; then
        link "$REPO_ROOT" "$AIHOME"
    else
        echo "  $AIHOME already exists and is not a symlink; leaving as-is" >&2
    fi
fi

for cli in $selected; do
    "link_$cli"
done

echo "Done."
print_recommended_plugins
