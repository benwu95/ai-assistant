#Requires -Version 5.1
<#
.SYNOPSIS
    Install symlinks for the ai-assistant repo (Windows PowerShell).

.DESCRIPTION
    Creating symbolic links on Windows requires either Developer Mode
    (Settings > Privacy & security > For developers) or an elevated
    (Run as Administrator) PowerShell session. If neither is available
    the script stops with an explanatory message.

.EXAMPLE
    .\install.ps1                 # auto-detect installed CLIs and link them
    .\install.ps1 -Local          # symlink this checkout into ~/.ai-assistant, then link
    .\install.ps1 -All            # link every supported CLI (creating config dirs)
    .\install.ps1 claude codex    # link only the named CLIs

    Supported CLI names: claude antigravity codex copilot

.EXAMPLE
    powershell -c "irm https://raw.githubusercontent.com/benwu95/ai-assistant/main/install.ps1 | iex"

    Bootstrap directly: clones the repo (into ~/.ai-assistant by default,
    override with $env:AI_ASSISTANT_DIR), then links installed CLIs.
#>
[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Local,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Clis
)

$ErrorActionPreference = 'Stop'

$RepoUrl  = 'https://github.com/benwu95/ai-assistant.git'
$AiHome   = Join-Path $HOME '.ai-assistant'

# Resolve the repo root. Running from a local checkout (or with -Local) uses
# the script's own directory ($PSScriptRoot). Piped from irm (no script file on
# disk) clones/updates the repo into ~/.ai-assistant (override with
# $env:AI_ASSISTANT_DIR).
function Resolve-RepoRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($Local) {
        Write-Error '-Local requires running from a local clone (e.g. .\install.ps1 -Local); nothing to link when piped.'
        exit 1
    }
    $dest = if ($env:AI_ASSISTANT_DIR) { $env:AI_ASSISTANT_DIR } else { $AiHome }
    if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
        Write-Host "Updating existing clone at $dest"
        git -C $dest pull --ff-only
    }
    else {
        Write-Host "Cloning $RepoUrl -> $dest"
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        git clone $RepoUrl $dest
    }
    return $dest
}
$RepoRoot = Resolve-RepoRoot

# --- helpers ---------------------------------------------------------------

function New-Link {
    param([string]$Target, [string]$LinkPath)

    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $LinkPath) {
        $item = Get-Item -LiteralPath $LinkPath -Force
        if ($item.LinkType -eq 'SymbolicLink') {
            $item.Delete()                          # replace stale symlink
        }
        else {
            $stamp  = Get-Date -Format 'yyyyMMddHHmmss'
            $backup = "$LinkPath.bak.$stamp"
            Move-Item -LiteralPath $LinkPath -Destination $backup   # never clobber a real file/dir
            Write-Host "  backed up existing $LinkPath -> $backup"
        }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error @"
Failed to create symbolic link:
    $LinkPath -> $Target

Windows requires elevated privileges for symlinks. Fix by either:
  * Enabling Developer Mode: Settings > Privacy & security > For developers
  * Running this script from an elevated (Run as Administrator) PowerShell

Original error: $($_.Exception.Message)
"@
        exit 1
    }
    Write-Host "  linked $LinkPath -> $Target"
}

# --- per-CLI link sets ------------------------------------------------------

function Link-Claude {
    Write-Host 'Claude Code:'
    New-Link (Join-Path $AiHome 'system.md') (Join-Path $HOME '.claude\CLAUDE.md')
    New-Link (Join-Path $AiHome 'agents')    (Join-Path $HOME '.claude\agents')
    New-Link (Join-Path $AiHome 'commands')  (Join-Path $HOME '.claude\commands')
    New-Link (Join-Path $AiHome 'scripts')   (Join-Path $HOME '.claude\scripts')
    New-Link (Join-Path $AiHome 'skills')    (Join-Path $HOME '.claude\skills')
}

function Link-Antigravity {
    Write-Host 'Antigravity CLI:'
    New-Link (Join-Path $AiHome 'system.md') (Join-Path $HOME '.gemini\GEMINI.md')
    New-Link (Join-Path $AiHome 'skills')    (Join-Path $HOME '.gemini\antigravity-cli\skills')
}

function Link-Codex {
    Write-Host 'Codex CLI:'
    New-Link (Join-Path $AiHome 'system.md') (Join-Path $HOME '.codex\AGENTS.md')
    New-Link (Join-Path $AiHome 'skills')    (Join-Path $HOME '.agents\skills')
}

function Link-Copilot {
    Write-Host 'Copilot CLI:'
    New-Link (Join-Path $AiHome 'system.md') (Join-Path $HOME '.copilot\copilot-instructions.md')
    New-Link (Join-Path $AiHome 'skills')    (Join-Path $HOME '.agents\skills')   # shared with Codex CLI
}

function Show-RecommendedPlugins {
    # echo the "## Recommended Plugins" section straight from the README
    # (single source of truth), stripping code-fence lines for the terminal
    $readme = Join-Path $RepoRoot 'README.md'
    if (-not (Test-Path -LiteralPath $readme)) { return }
    Write-Host ''
    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $readme)) {
        if ($line -match '^## Recommended Plugins') { $inSection = $true }
        elseif ($inSection -and $line -match '^## ') { break }
        if ($inSection -and $line -notmatch '^```') { Write-Host $line }
    }
}

$BaseDir = @{
    claude      = Join-Path $HOME '.claude'
    antigravity = Join-Path $HOME '.gemini'
    codex       = Join-Path $HOME '.codex'
    copilot     = Join-Path $HOME '.copilot'
}
$LinkFn = @{
    claude      = ${function:Link-Claude}
    antigravity = ${function:Link-Antigravity}
    codex       = ${function:Link-Codex}
    copilot     = ${function:Link-Copilot}
}
$AllClis = @('claude', 'antigravity', 'codex', 'copilot')

# --- argument parsing -------------------------------------------------------

$selected = @()
if ($All) {
    $selected = $AllClis
}
elseif ($Clis) {
    foreach ($c in $Clis) {
        if ($AllClis -notcontains $c) { Write-Error "Unknown argument: $c"; exit 1 }
        $selected += $c
    }
}
else {
    foreach ($c in $AllClis) {
        if (Test-Path -LiteralPath $BaseDir[$c]) { $selected += $c }
    }
    if (-not $selected) {
        Write-Error 'No installed CLI detected. Use -All to link every CLI, or name them explicitly.'
        exit 1
    }
}

# --- run --------------------------------------------------------------------

Write-Host "Repo root: $RepoRoot"

# core: the single indirection symlink everything else points through.
# Skipped when the repo was bootstrapped directly into ~/.ai-assistant.
if ($RepoRoot -ne $AiHome) {
    if ((-not (Test-Path -LiteralPath $AiHome)) -or ((Get-Item -LiteralPath $AiHome -Force).LinkType -eq 'SymbolicLink')) {
        New-Link $RepoRoot $AiHome
    }
    else {
        Write-Warning "$AiHome already exists and is not a symlink; leaving as-is"
    }
}

foreach ($c in ($selected | Select-Object -Unique)) {
    & $LinkFn[$c]
}

Write-Host 'Done.'
Show-RecommendedPlugins
