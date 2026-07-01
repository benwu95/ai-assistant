#!/bin/bash
# Read JSON payload from stdin
read -r payload




# Helper function to format numbers into human readable strings (e.g. 1.2k, 1.5M, 2G, 1.8T)
format_number() {
  local num=$1
  if [ -z "$num" ] || [ "$num" = "null" ] || [ "$num" -eq 0 ] 2>/dev/null; then
    echo "0"
    return
  fi
  
  if [ "$num" -lt 1000 ]; then
    echo "$num"
  elif [ "$num" -lt 1000000 ]; then
    awk -v n="$num" 'BEGIN { printf "%.1fk", n/1000 }' | sed 's/\.0k$/k/'
  elif [ "$num" -lt 1000000000 ]; then
    awk -v n="$num" 'BEGIN { printf "%.1fM", n/1000000 }' | sed 's/\.0M$/M/'
  elif [ "$num" -lt 1000000000000 ]; then
    awk -v n="$num" 'BEGIN { printf "%.1fG", n/1000000000 }' | sed 's/\.0G$/G/'
  else
    awk -v n="$num" 'BEGIN { printf "%.1fT", n/1000000000000 }' | sed 's/\.0T$/T/'
  fi
}

# Extract fields with jq (with safe fallbacks)
agent_state=$(echo "$payload" | jq -r '.agent_state // .state // "idle"')
cwd=$(echo "$payload" | jq -r '.cwd // .workspace.current_dir // ""')
branch=$(echo "$payload" | jq -r '.vcs.branch // .workspace.branch // ""')
dirty=$(echo "$payload" | jq -r '.vcs.dirty // .workspace.dirty // "false"')
model=$(echo "$payload" | jq -r '.model.display_name // .model.id // ""')
subagents_count=$(echo "$payload" | jq -r 'if .subagents | type == "array" then .subagents | length else 0 end')
sandbox_val=$(echo "$payload" | jq -r '.sandbox // .terminal_sandbox // .enableTerminalSandbox // "false"')

# Token extraction (including cache and thinking/reasoning tokens)
tokens_in=$(echo "$payload" | jq -r '.tokens.input // .context_window.total_input_tokens // .tokens_in // 0')
tokens_out=$(echo "$payload" | jq -r '.tokens.output // .context_window.total_output_tokens // .tokens_out // 0')
tokens_cached=$(echo "$payload" | jq -r '.tokens.cached // .tokens.cache_read // .context_window.current_usage.cache_read_input_tokens // .context_window.cache_read_input_tokens // .tokens.cached_content // 0')
tokens_thinking=$(echo "$payload" | jq -r '.tokens.thinking // .tokens.reasoning // .context_window.current_usage.thinking_output_tokens // .context_window.thinking_output_tokens // 0')

credits_rem=$(echo "$payload" | jq -r '.credits.remaining // .credits // .cost.total_cost_usd // ""')

# Extract rate limits
# Get colorScheme from settings.json
color_scheme=$(jq -r '.colorScheme // "default"' ~/.gemini/antigravity-cli/settings.json 2>/dev/null || echo "default")

# Default / Fallback Colors (Standard ANSI Colors)
COLOR_MODEL="\033[1;36m"    # Bold Cyan
COLOR_USAGE="\033[1;33m"    # Bold Yellow
COLOR_CONTEXT="\033[1;32m"  # Bold Green
COLOR_TOKENS="\033[1;35m"   # Bold Magenta
COLOR_CREDITS="\033[1;34m"  # Bold Blue
COLOR_LABEL="\033[0m"    # Normal Foreground
COLOR_RESET="\033[0m"

# Theme definitions
case "$color_scheme" in
  "tokyo night")
    COLOR_MODEL="\033[38;5;111m"    # Soft Blue
    COLOR_USAGE="\033[38;5;215m"    # Soft Orange
    COLOR_CONTEXT="\033[38;5;120m"  # Soft Green
    COLOR_TOKENS="\033[38;5;176m"   # Soft Purple
    COLOR_CREDITS="\033[38;5;73m"    # Soft Teal
    COLOR_LABEL="\033[38;5;250m"    # Tokyo Night Foreground (亮灰/軟白)
    ;;
  "catppuccin"*)
    COLOR_MODEL="\033[38;5;117m"    # Sky
    COLOR_USAGE="\033[38;5;216m"    # Peach
    COLOR_CONTEXT="\033[38;5;150m"  # Green
    COLOR_TOKENS="\033[38;5;183m"   # Lavender
    COLOR_CREDITS="\033[38;5;115m"  # Teal
    COLOR_LABEL="\033[38;5;253m"    # Catppuccin Foreground
    ;;
  "nord")
    COLOR_MODEL="\033[38;5;109m"    # Frost Blue-Green
    COLOR_USAGE="\033[38;5;179m"    # Yellow
    COLOR_CONTEXT="\033[38;5;151m"  # Green
    COLOR_TOKENS="\033[38;5;139m"   # Purple
    COLOR_CREDITS="\033[38;5;110m"  # Frost Blue
    COLOR_LABEL="\033[38;5;253m"    # Dark Gray
    ;;
esac

# Extract quota and rate limits
model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
quota_key="gemini-5h"
weekly_quota_key="gemini-weekly"
if [[ "$model_lower" == *"claude"* ]] || [[ "$model_lower" == *"fable"* ]] || [[ "$model_lower" == *"mythos"* ]] || [[ "$model_lower" == *"opus"* ]] || [[ "$model_lower" == *"sonnet"* ]] || [[ "$model_lower" == *"haiku"* ]]; then
  quota_key="3p-5h"
  weekly_quota_key="3p-weekly"
fi

remaining_fraction=$(echo "$payload" | jq -r ".quota[\"${quota_key}\"].remaining_fraction // \"\"")
reset_in_seconds=$(echo "$payload" | jq -r ".quota[\"${quota_key}\"].reset_in_seconds // \"\"")
weekly_remaining_fraction=$(echo "$payload" | jq -r ".quota[\"${weekly_quota_key}\"].remaining_fraction // \"\"")
weekly_reset_in_seconds=$(echo "$payload" | jq -r ".quota[\"${weekly_quota_key}\"].reset_in_seconds // \"\"")

format_reset_time() {
  local val=$1
  if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "" ]; then
    echo ""
    return
  fi
  # If it contains "T", assume ISO string
  if [[ "$val" == *"T"* ]]; then
    echo "$val" | cut -d'T' -f2 | cut -d':' -f1,2
  elif [[ "$val" =~ ^[0-9]+$ ]]; then
    local sec=$val
    if [ "${#val}" -eq 13 ]; then
      sec=$((val / 1000))
    fi
    date -r "$sec" "+%H:%M" 2>/dev/null || date -d "@$sec" "+%H:%M" 2>/dev/null || echo "$sec"
  else
    echo "$val"
  fi
}

usage_fmt=""
if [ -n "$remaining_fraction" ] && [ "$remaining_fraction" != "null" ] && [ "$remaining_fraction" != "" ]; then
  used_val=$(awk -v r="$remaining_fraction" 'BEGIN { printf "%.1f%%", (1 - r) * 100 }' 2>/dev/null || echo "0.0%")
  reset_fmt=""
  if [ -n "$reset_in_seconds" ] && [ "$reset_in_seconds" != "null" ] && [ "$reset_in_seconds" -gt 0 ] 2>/dev/null; then
    current_epoch=$(date +%s)
    reset_epoch=$((current_epoch + reset_in_seconds))
    reset_fmt=$(date -r "$reset_epoch" "+%H:%M" 2>/dev/null || date -d "@$reset_epoch" "+%H:%M" 2>/dev/null || echo "")
  fi
  
  weekly_used_val=""
  weekly_reset_fmt=""
  if [ -n "$weekly_remaining_fraction" ] && [ "$weekly_remaining_fraction" != "null" ] && [ "$weekly_remaining_fraction" != "" ]; then
    weekly_used_val=$(awk -v r="$weekly_remaining_fraction" 'BEGIN { printf "%.1f%%", (1 - r) * 100 }' 2>/dev/null || echo "0.0%")
    
    if [ -n "$weekly_reset_in_seconds" ] && [ "$weekly_reset_in_seconds" != "null" ] && [ "$weekly_reset_in_seconds" -gt 0 ] 2>/dev/null; then
      current_epoch=$(date +%s)
      weekly_reset_epoch=$((current_epoch + weekly_reset_in_seconds))
      weekly_reset_fmt=$(date -r "$weekly_reset_epoch" "+%m/%d %H:%M" 2>/dev/null || date -d "@$weekly_reset_epoch" "+%m/%d %H:%M" 2>/dev/null || echo "")
    fi
  fi
  
  usage_fmt="${COLOR_LABEL}5h: ${COLOR_RESET}${COLOR_USAGE}${used_val}${COLOR_RESET}"
  if [ -n "$reset_fmt" ]; then
    usage_fmt="${usage_fmt} ${COLOR_LABEL}(${reset_fmt})${COLOR_RESET}"
  fi
  if [ -n "$weekly_used_val" ]; then
    if [ -n "$weekly_reset_fmt" ]; then
      usage_fmt="${usage_fmt} ${COLOR_LABEL}· 7d: ${COLOR_RESET}${COLOR_USAGE}${weekly_used_val}${COLOR_RESET} ${COLOR_LABEL}(${weekly_reset_fmt})${COLOR_RESET}"
    else
      usage_fmt="${usage_fmt} ${COLOR_LABEL}· 7d: ${COLOR_RESET}${COLOR_USAGE}${weekly_used_val}${COLOR_RESET}"
    fi
  fi
else
  # Fallback to old 'rate_limits' object
  rate_limits_used=$(echo "$payload" | jq -r '.rate_limits.five_hour.used_percentage // ""')
  rate_limits_reset=$(echo "$payload" | jq -r '.rate_limits.five_hour.resets_at // ""')
  rate_limits_weekly_used=$(echo "$payload" | jq -r '.rate_limits.seven_day.used_percentage // ""')
  rate_limits_weekly_reset=$(echo "$payload" | jq -r '.rate_limits.seven_day.resets_at // ""')

  if [ -n "$rate_limits_used" ] && [ "$rate_limits_used" != "null" ] && [ "$rate_limits_used" != "" ]; then
    used_val=$(awk -v p="$rate_limits_used" 'BEGIN { printf "%.1f%%", p }' 2>/dev/null || echo "${rate_limits_used}%")
    reset_fmt=$(format_reset_time "$rate_limits_reset")
    
    weekly_used_val=""
    weekly_reset_fmt=""
    if [ -n "$rate_limits_weekly_used" ] && [ "$rate_limits_weekly_used" != "null" ] && [ "$rate_limits_weekly_used" != "" ]; then
      weekly_used_val=$(awk -v p="$rate_limits_weekly_used" 'BEGIN { printf "%.1f%%", p }' 2>/dev/null || echo "${rate_limits_weekly_used}%")
      
      if [ -n "$rate_limits_weekly_reset" ] && [ "$rate_limits_weekly_reset" != "null" ] && [ "$rate_limits_weekly_reset" != "" ]; then
        if [[ "$rate_limits_weekly_reset" == *"T"* ]]; then
          date_part=$(echo "$rate_limits_weekly_reset" | cut -d'T' -f1 | cut -d'-' -f2,3 | tr '-' '/')
          time_part=$(echo "$rate_limits_weekly_reset" | cut -d'T' -f2 | cut -d':' -f1,2)
          weekly_reset_fmt="${date_part} ${time_part}"
        elif [[ "$rate_limits_weekly_reset" =~ ^[0-9]+$ ]]; then
          local sec=$rate_limits_weekly_reset
          if [ "${#rate_limits_weekly_reset}" -eq 13 ]; then
            sec=$((rate_limits_weekly_reset / 1000))
          fi
          weekly_reset_fmt=$(date -r "$sec" "+%m/%d %H:%M" 2>/dev/null || date -d "@$sec" "+%m/%d %H:%M" 2>/dev/null || echo "")
        fi
      fi
    fi
    
    usage_fmt="${COLOR_LABEL}5h: ${COLOR_RESET}${COLOR_USAGE}${used_val}${COLOR_RESET}"
    if [ -n "$reset_fmt" ]; then
      usage_fmt="${usage_fmt} ${COLOR_LABEL}(${reset_fmt})${COLOR_RESET}"
    fi
    if [ -n "$weekly_used_val" ]; then
      if [ -n "$weekly_reset_fmt" ]; then
        usage_fmt="${usage_fmt} ${COLOR_LABEL}· 7d: ${COLOR_RESET}${COLOR_USAGE}${weekly_used_val}${COLOR_RESET} ${COLOR_LABEL}(${weekly_reset_fmt})${COLOR_RESET}"
      else
        usage_fmt="${usage_fmt} ${COLOR_LABEL}· 7d: ${COLOR_RESET}${COLOR_USAGE}${weekly_used_val}${COLOR_RESET}"
      fi
    fi
  else
    usage_fmt="${COLOR_LABEL}5h: ${COLOR_RESET}${COLOR_USAGE}--${COLOR_RESET}"
  fi
fi

# Extract context window usage percentage
used_pct=$(echo "$payload" | jq -r '.context_window.used_percentage // ""')
context_fmt=""
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ] && [ "$used_pct" != "" ]; then
  context_fmt=$(awk -v p="$used_pct" 'BEGIN { printf "%.1f%%", p }')
fi

# Fallback CWD to current directory of the process if empty
if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
  cwd=$(pwd)
fi

# Resolve local Git state
is_git="false"
is_worktree="false"
git_dir=""
git_op=""

if [ -n "$cwd" ] && [ "$cwd" != "null" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  is_git="true"
  git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  
  # Determine branch or detached HEAD
  if git -C "$cwd" symbolic-ref -q HEAD >/dev/null 2>&1; then
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  else
    short_sha=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    branch="@$short_sha"
  fi

  # Determine dirty state
  if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
    dirty="true"
  else
    dirty="false"
  fi

  # Detect if it is a secondary git worktree
  if [ -f "$cwd/.git" ] || [[ "$git_dir" == *"/worktrees/"* ]]; then
    is_worktree="true"
  fi

  # Detect ongoing Git operations
  if [ -n "$git_dir" ]; then
    if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
      git_op="REBASE"
    elif [ -f "$git_dir/MERGE_HEAD" ]; then
      git_op="MERGE"
    elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
      git_op="CHERRY-PICK"
    elif [ -f "$git_dir/REVERT_HEAD" ]; then
      git_op="REVERT"
    elif [ -f "$git_dir/BISECT_LOG" ]; then
      git_op="BISECT"
    fi
  fi
else
  # If not a local git repo, fallback to payload if available (safety measure)
  if [ -z "$branch" ] || [ "$branch" = "null" ]; then
    branch=""
  fi
fi

# Arrays to store status line segments
line1_segments=()
line2_segments=()

# --- LINE 1 ---
# 0. Version (Far left of Line 1)
cli_version=$(echo "$payload" | jq -r '.version // ""')
if [ -n "$cli_version" ] && [ "$cli_version" != "null" ] && [ "$cli_version" != "" ]; then
  line1_segments+=("agy v${cli_version}")
fi

# 1. Agent State
state_upper=$(echo "$agent_state" | tr '[:lower:]' '[:upper:]')
case "$agent_state" in
  "idle")
    line1_segments+=("\033[1;32m● $state_upper\033[0m")
    ;;
  "thinking")
    line1_segments+=("\033[1;33m● $state_upper\033[0m")
    ;;
  "working"|"tool_use")
    line1_segments+=("\033[1;31m● $state_upper\033[0m")
    ;;
  *)
    line1_segments+=("\033[1;36m● $state_upper\033[0m")
    ;;
esac

# 2. CWD & VCS
cwd_fmt=""
if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
  cwd_short=$(echo "$cwd" | sed "s|$HOME|~|")
  cwd_fmt="📂 $cwd_short"
fi
if [ -n "$branch" ] && [ "$branch" != "null" ]; then
  branch_display="$branch"
  if [ "$is_worktree" = "true" ]; then
    branch_display="$branch (worktree)"
  fi
  
  if [ -n "$git_op" ]; then
    branch_display="$branch_display (\033[1;31m$git_op\033[1;36m)"
  fi
  
  if [ "$dirty" = "true" ]; then
    cwd_fmt="$cwd_fmt \033[1;36m $branch_display\033[0m \033[1;33m*\033[0m"
  else
    cwd_fmt="$cwd_fmt \033[1;36m $branch_display\033[0m"
  fi
fi
if [ -n "$cwd_fmt" ]; then
  line1_segments+=("$cwd_fmt")
fi

# 3. Session Git Stats (Third section of Line 1)
if [ "$is_git" = "true" ]; then
  # Determine base branch (main or master)
  base_branch="main"
  if ! git -C "$cwd" show-ref --verify --quiet refs/heads/main; then
    if git -C "$cwd" show-ref --verify --quiet refs/heads/master; then
      base_branch="master"
    fi
  fi

  # Determine target for diff (divergence from base branch, or HEAD changes if on base branch)
  current_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  if [ "$current_branch" = "$base_branch" ] || [ -z "$current_branch" ]; then
    diff_target="HEAD"
  else
    # Feature branch: compare from merge-base to work tree
    merge_base=$(git -C "$cwd" merge-base "$base_branch" HEAD 2>/dev/null)
    if [ -n "$merge_base" ]; then
      diff_target="$merge_base"
    else
      diff_target="$base_branch"
    fi
  fi

  # 1. Calculate cumulative line changes
  lines_stat=$(git -C "$cwd" diff "$diff_target" --numstat 2>/dev/null | awk '{
    if ($1 != "-") add+=$1;
    if ($2 != "-") del+=$2;
  } END {
    printf "+%d/-%d", add, del
  }')

  # 2. Calculate cumulative file change counts (excluding untracked files)
  file_stat=$(git -C "$cwd" diff "$diff_target" --name-status 2>/dev/null | awk '
    BEGIN { mod=0; add=0; del=0; ren=0 }
    {
      char = substr($1, 1, 1)
      if (char == "M" || char == "T") {
        mod++
      } else if (char == "A") {
        add++
      } else if (char == "D") {
        del++
      } else if (char == "R") {
        ren++
      }
    }
    END {
      printf "M:%d A:%d D:%d R:%d", mod, add, del, ren
    }
  ')
  
  lines_add=$(echo "$lines_stat" | cut -d'/' -f1)
  lines_del=$(echo "$lines_stat" | cut -d'/' -f2)
  
  line1_segments+=("📝 \033[1;32m$lines_add\033[0m/\033[1;31m$lines_del\033[0m, $file_stat")
fi



# 4. Sandbox
if [ "$sandbox_val" = "true" ]; then
  line1_segments+=("Sandbox: On")
else
  line1_segments+=("Sandbox: Off")
fi

# 5. Subagents (Robot icon)
if [ "$subagents_count" -gt 0 ]; then
  line1_segments+=("🤖 $subagents_count")
fi


# --- LINE 2 ---
# Format numbers to be human readable
in_fmt=$(format_number "$tokens_in")
out_fmt=$(format_number "$tokens_out")
cached_fmt=$(format_number "$tokens_cached")
thinking_fmt=$(format_number "$tokens_thinking")

show_tokens=false
if [ "$tokens_in" -gt 0 ] || [ "$tokens_out" -gt 0 ]; then
  show_tokens=true
fi

show_context=false
if [ -n "$context_fmt" ]; then
  show_context=true
fi

show_credits=false
if [ -n "$credits_rem" ] && [ "$credits_rem" != "null" ] && [ "$credits_rem" != "" ] && [ "$credits_rem" != "0" ]; then
  show_credits=true
fi

# 1. Model (Prepend to line2_segments if present)
if [ -n "$model" ] && [ "$model" != "null" ] && [ "$model" != "" ]; then
  line2_segments+=("${COLOR_MODEL}${model}${COLOR_RESET}")
fi

# 1.5. Usage (between Model and Context)
if [ -n "$usage_fmt" ]; then
  line2_segments+=("$usage_fmt")
fi

# Build Line 2 segments if there is any data
if [ "$show_tokens" = "true" ] || [ "$show_context" = "true" ] || [ "$show_credits" = "true" ]; then
  # 1. Context (1st Column)
  if [ "$show_context" = "true" ]; then
    line2_segments+=("${COLOR_LABEL}context: ${COLOR_RESET}${COLOR_CONTEXT}${context_fmt}${COLOR_RESET}")
  elif [ "$show_tokens" = "true" ] || [ "$show_credits" = "true" ]; then
    # Place a fallback Context to keep column alignment
    line2_segments+=("${COLOR_LABEL}context: ${COLOR_RESET}${COLOR_CONTEXT}--${COLOR_RESET}")
  fi

  # 2. Tokens (2nd Column)
  if [ "$show_tokens" = "true" ]; then
    tokens_str="${COLOR_LABEL}token: ${COLOR_RESET}${COLOR_TOKENS}${in_fmt}/${out_fmt}${COLOR_RESET}"
    extra_info=""
    if [ "$tokens_cached" -gt 0 ]; then
      extra_info="${COLOR_LABEL}cache: ${COLOR_RESET}${COLOR_TOKENS}${cached_fmt}${COLOR_RESET}"
    fi
    if [ "$tokens_thinking" -gt 0 ]; then
      if [ -n "$extra_info" ]; then
        extra_info="${extra_info}${COLOR_LABEL} · thinking: ${COLOR_RESET}${COLOR_TOKENS}${thinking_fmt}${COLOR_RESET}"
      else
        extra_info="${COLOR_LABEL}thinking: ${COLOR_RESET}${COLOR_TOKENS}${thinking_fmt}${COLOR_RESET}"
      fi
    fi
    if [ -n "$extra_info" ]; then
      tokens_str="${tokens_str} ${COLOR_LABEL}(${COLOR_RESET}${extra_info}${COLOR_LABEL})${COLOR_RESET}"
    fi
    line2_segments+=("$tokens_str")
  elif [ "$show_credits" = "true" ]; then
    line2_segments+=("${COLOR_LABEL}token: ${COLOR_RESET}${COLOR_TOKENS}--${COLOR_RESET}")
  fi

  # 3. Credits (3rd Column)
  if [ "$show_credits" = "true" ]; then
    credits_display="$credits_rem"
    if [[ "$credits_display" != \$* ]]; then
      credits_display="\$${credits_display}"
    fi
    line2_segments+=("${COLOR_LABEL}$: ${COLOR_RESET}${COLOR_CREDITS}${credits_display}${COLOR_RESET}")
  fi
fi


# Join Line 1 segments with " | "
line1_output=""
for i in "${!line1_segments[@]}"; do
  if [ "$i" -eq 0 ]; then
    line1_output="${line1_segments[$i]}"
  else
    line1_output="$line1_output | ${line1_segments[$i]}"
  fi
done

# Join Line 2 segments with " | "
line2_output=""
for i in "${!line2_segments[@]}"; do
  if [ "$i" -eq 0 ]; then
    line2_output="${line2_segments[$i]}"
  else
    line2_output="$line2_output | ${line2_segments[$i]}"
  fi
done

# Print final status line output
if [ -n "$line2_output" ]; then
  echo -e "$line1_output\n$line2_output"
else
  echo -e "$line1_output"
fi
