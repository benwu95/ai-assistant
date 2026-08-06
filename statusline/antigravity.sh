#!/bin/bash
# Read JSON payload from stdin
payload=$(cat)
if [ -z "$payload" ]; then
  payload="{}"
fi

eval "$(echo "$payload" | jq -r '
  ((.agent_state // .state // "idle")) as $st |
  ((.model.display_name // .model.id // "")) as $m |
  ($m | ascii_downcase) as $m_lower |
  (if ($m_lower | contains("gemini") | not) or ($m_lower | contains("claude")) or ($m_lower | contains("fable")) or ($m_lower | contains("mythos")) or ($m_lower | contains("opus")) or ($m_lower | contains("sonnet")) or ($m_lower | contains("haiku"))
   then (.quota["3p-5h"] // .quota["gemini-5h"] // {})
   else (.quota["gemini-5h"] // .quota["3p-5h"] // {}) end) as $q5 |
  (if ($m_lower | contains("gemini") | not) or ($m_lower | contains("claude")) or ($m_lower | contains("fable")) or ($m_lower | contains("mythos")) or ($m_lower | contains("opus")) or ($m_lower | contains("sonnet")) or ($m_lower | contains("haiku"))
   then (.quota["3p-weekly"] // .quota["gemini-weekly"] // {})
   else (.quota["gemini-weekly"] // .quota["3p-weekly"] // {}) end) as $qw |
  "agent_state=" + ($st | @sh) + "\n" +
  "cwd=" + ((.cwd // .workspace.current_dir // "") | @sh) + "\n" +
  "branch=" + ((.vcs.branch // .workspace.branch // "") | @sh) + "\n" +
  "dirty=" + ((.vcs.dirty // .workspace.dirty // "false") | tostring | @sh) + "\n" +
  "model=" + ($m | @sh) + "\n" +
  "subagents_count=" + ((if .subagents | type == "array" then .subagents | length else 0 end) | tostring | @sh) + "\n" +
  "sandbox_val=" + ((.sandbox // .terminal_sandbox // .enableTerminalSandbox // "false") | tostring | @sh) + "\n" +
  "tokens_in=" + ((.context_window.current_usage.input_tokens // .context_window.total_input_tokens // .tokens.input // .tokens_in // .usage.input_tokens // 0) | tostring | @sh) + "\n" +
  "tokens_out=" + ((.context_window.current_usage.output_tokens // .context_window.total_output_tokens // .tokens.output // .tokens_out // .usage.output_tokens // 0) | tostring | @sh) + "\n" +
  "tokens_cached=" + ((.tokens.cached // .tokens.cache_read // .context_window.current_usage.cache_read_input_tokens // .context_window.cache_read_input_tokens // .tokens.cached_content // 0) | tostring | @sh) + "\n" +
  "tokens_thinking=" + ((.tokens.thinking // .tokens.reasoning // .context_window.current_usage.thinking_output_tokens // .context_window.thinking_output_tokens // 0) | tostring | @sh) + "\n" +
  "credits_rem=" + ((.credits.remaining // .credits // .cost.total_cost_usd // "") | tostring | @sh) + "\n" +
  "remaining_fraction=" + (($q5.remaining_fraction // $q5.remainingFraction // "") | tostring | @sh) + "\n" +
  "reset_in_seconds=" + (($q5.reset_in_seconds // $q5.resetInSeconds // $q5.resets_at // "") | tostring | @sh) + "\n" +
  "weekly_remaining_fraction=" + (($qw.remaining_fraction // $qw.remainingFraction // "") | tostring | @sh) + "\n" +
  "weekly_reset_in_seconds=" + (($qw.reset_in_seconds // $qw.resetInSeconds // $qw.resets_at // "") | tostring | @sh) + "\n" +
  "rate_limits_used=" + ((.rate_limits.five_hour.used_percentage // "") | tostring | @sh) + "\n" +
  "rate_limits_reset=" + ((.rate_limits.five_hour.resets_at // "") | tostring | @sh) + "\n" +
  "rate_limits_weekly_used=" + ((.rate_limits.seven_day.used_percentage // "") | tostring | @sh) + "\n" +
  "rate_limits_weekly_reset=" + ((.rate_limits.seven_day.resets_at // "") | tostring | @sh) + "\n" +
  "used_pct=" + ((.context_window.used_percentage // .context_window.current_usage.used_percentage // .used_percentage // "") | tostring | @sh) + "\n" +
  "cli_version=" + ((.version // "") | tostring | @sh) + "\n" +
  "cycle_mode=" + ((.cycle_mode // .agent_mode // .mode // "default") | tostring | @sh)
' 2>/dev/null)"

format_number() {
  local num=$1
  if [ -z "$num" ] || [ "$num" = "null" ] || ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ]; then
    echo "0"
    return
  fi
  if [ "$num" -lt 1000 ]; then
    echo "$num"
  elif [ "$num" -lt 1000000 ]; then
    local int=$((num / 1000))
    local dec=$(((num % 1000) / 100))
    if [ "$dec" -eq 0 ]; then echo "${int}k"; else echo "${int}.${dec}k"; fi
  elif [ "$num" -lt 1000000000 ]; then
    local int=$((num / 1000000))
    local dec=$(((num % 1000000) / 100000))
    if [ "$dec" -eq 0 ]; then echo "${int}M"; else echo "${int}.${dec}M"; fi
  elif [ "$num" -lt 1000000000000 ]; then
    local int=$((num / 1000000000))
    local dec=$(((num % 1000000000) / 100000000))
    if [ "$dec" -eq 0 ]; then echo "${int}G"; else echo "${int}.${dec}G"; fi
  else
    local int=$((num / 1000000000000))
    local dec=$(((num % 1000000000000) / 100000000000))
    if [ "$dec" -eq 0 ]; then echo "${int}T"; else echo "${int}.${dec}T"; fi
  fi
}

format_reset_time() {
  local val=$1
  local include_date=$2
  if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "" ]; then
    echo ""
    return
  fi
  if [[ "$val" == *"T"* ]]; then
    local date_part=""
    if [ "$include_date" = "true" ]; then
      date_part="$(echo "$val" | cut -d'T' -f1 | cut -d'-' -f2,3 | tr '-' '/') "
    fi
    local time_part="${val#*T}"
    echo "${date_part}${time_part:0:5}"
  elif [[ "$val" =~ ^[0-9]+$ ]]; then
    local sec=$val
    if [ "${#val}" -eq 13 ]; then
      sec=$((val / 1000))
    fi
    if [ "$sec" -lt 31536000 ]; then
      sec=$(( $(date +%s) + sec ))
    fi
    local fmt="+%H:%M"
    if [ "$include_date" = "true" ]; then
      fmt="+%m/%d %H:%M"
    fi
    date -r "$sec" "$fmt" 2>/dev/null || date -d "@$sec" "$fmt" 2>/dev/null || echo "$sec"
  else
    echo "$val"
  fi
}

# Theme definitions & color scheme extraction
color_scheme="default"
if [ -f "$HOME/.gemini/antigravity-cli/settings.json" ]; then
  cs_line=$(grep '"colorScheme"' "$HOME/.gemini/antigravity-cli/settings.json" 2>/dev/null)
  if [ -n "$cs_line" ]; then
    color_scheme=$(echo "$cs_line" | sed -n 's/.*"colorScheme":[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
fi

COLOR_MODEL="\033[1;36m"    # Bold Cyan
COLOR_USAGE="\033[1;33m"    # Bold Yellow
COLOR_CONTEXT="\033[1;32m"  # Bold Green
COLOR_TOKENS="\033[1;35m"   # Bold Magenta
COLOR_CREDITS="\033[1;34m"  # Bold Blue
COLOR_LABEL="\033[0m"       # Normal Foreground
COLOR_RESET="\033[0m"

case "$color_scheme" in
  "tokyo night")
    COLOR_MODEL="\033[38;5;111m"    # Soft Blue
    COLOR_USAGE="\033[38;5;215m"    # Soft Orange
    COLOR_CONTEXT="\033[38;5;120m"  # Soft Green
    COLOR_TOKENS="\033[38;5;176m"   # Soft Purple
    COLOR_CREDITS="\033[38;5;73m"   # Soft Teal
    COLOR_LABEL="\033[38;5;250m"    # Tokyo Night Foreground
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

# Quota & Rate Limit Formatting
usage_fmt=""
if [ -n "$remaining_fraction" ] && [ "$remaining_fraction" != "null" ]; then
  used_val=$(awk -v r="$remaining_fraction" 'BEGIN { printf "%.1f%%", (1 - r) * 100 }' 2>/dev/null || echo "0.0%")
  reset_fmt=$(format_reset_time "$reset_in_seconds")

  weekly_used_val=""
  weekly_reset_fmt=""
  if [ -n "$weekly_remaining_fraction" ] && [ "$weekly_remaining_fraction" != "null" ]; then
    weekly_used_val=$(awk -v r="$weekly_remaining_fraction" 'BEGIN { printf "%.1f%%", (1 - r) * 100 }' 2>/dev/null || echo "0.0%")
    weekly_reset_fmt=$(format_reset_time "$weekly_reset_in_seconds" "true")
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
elif [ -n "$rate_limits_used" ] && [ "$rate_limits_used" != "null" ]; then
  used_val=$(awk -v p="$rate_limits_used" 'BEGIN { printf "%.1f%%", p }' 2>/dev/null || echo "${rate_limits_used}%")
  reset_fmt=$(format_reset_time "$rate_limits_reset")

  weekly_used_val=""
  weekly_reset_fmt=""
  if [ -n "$rate_limits_weekly_used" ] && [ "$rate_limits_weekly_used" != "null" ]; then
    weekly_used_val=$(awk -v p="$rate_limits_weekly_used" 'BEGIN { printf "%.1f%%", p }' 2>/dev/null || echo "${rate_limits_weekly_used}%")
    weekly_reset_fmt=$(format_reset_time "$rate_limits_weekly_reset" "true")
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

context_fmt=""
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
  context_fmt=$(awk -v p="$used_pct" 'BEGIN { printf "%.1f%%", p }')
fi

# Fallback CWD to current directory of process if empty
if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
  cwd=$(pwd)
fi

# Resolve Git state
is_git="false"
is_worktree="false"
git_dir=""
git_op=""

git_info=$(git -C "$cwd" rev-parse --is-inside-work-tree --absolute-git-dir 2>/dev/null)
if [ -n "$git_info" ]; then
  is_git="true"
  git_dir=$(echo "$git_info" | sed -n '2p')

  # Fallback to manual resolution if CLI payload did not provide a branch
  if [ -z "$branch" ] || [ "$branch" = "null" ]; then
    short_sha=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    local_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$local_branch" ]; then
      branch="$local_branch"
    elif [ -n "$short_sha" ]; then
      branch="@$short_sha"
    fi
  fi

  # Fallback to manual resolution if CLI payload did not provide dirty status
  if [ -z "$dirty" ] || [ "$dirty" = "null" ]; then
    if [ -n "$(git -C "$cwd" status --porcelain -unormal 2>/dev/null)" ]; then
      dirty="true"
    else
      dirty="false"
    fi
  fi

  if [ -f "$cwd/.git" ] || [[ "$git_dir" == *"/worktrees/"* ]]; then
    is_worktree="true"
  fi

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
  if [ -z "$branch" ] || [ "$branch" = "null" ]; then
    branch=""
  fi
fi

# Line 1 segments
line1_segments=()

if [ -n "$cli_version" ] && [ "$cli_version" != "null" ]; then
  line1_segments+=("agy v${cli_version}")
fi

if [ -z "$cycle_mode" ] || [ "$cycle_mode" = "null" ]; then
  cycle_mode="default"
fi
line1_segments+=("Mode: ${cycle_mode}")

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

cwd_fmt=""
if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
  cwd_short="${cwd/#$HOME/~}"
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

if [ "$sandbox_val" = "true" ]; then
  line1_segments+=("Sandbox: On")
else
  line1_segments+=("Sandbox: Off")
fi

if [[ "$subagents_count" =~ ^[0-9]+$ ]] && [ "$subagents_count" -gt 0 ]; then
  line1_segments+=("🤖 $subagents_count")
fi

# Line 2 segments
line2_segments=()

in_fmt=$(format_number "$tokens_in")
out_fmt=$(format_number "$tokens_out")
cached_fmt=$(format_number "$tokens_cached")
thinking_fmt=$(format_number "$tokens_thinking")

show_tokens=false
if [[ "$tokens_in" =~ ^[0-9]+$ ]] && [[ "$tokens_out" =~ ^[0-9]+$ ]]; then
  if [ "$tokens_in" -gt 0 ] || [ "$tokens_out" -gt 0 ]; then
    show_tokens=true
  fi
fi

show_context=false
if [ -n "$context_fmt" ]; then
  show_context=true
fi

show_credits=false
if [ -n "$credits_rem" ] && [ "$credits_rem" != "null" ] && [ "$credits_rem" != "" ] && [ "$credits_rem" != "0" ]; then
  show_credits=true
fi

if [ -n "$model" ] && [ "$model" != "null" ]; then
  line2_segments+=("${COLOR_MODEL}${model}${COLOR_RESET}")
fi

if [ -n "$usage_fmt" ]; then
  line2_segments+=("$usage_fmt")
fi

if [ "$show_tokens" = "true" ] || [ "$show_context" = "true" ] || [ "$show_credits" = "true" ]; then
  if [ "$show_context" = "true" ]; then
    line2_segments+=("${COLOR_LABEL}context: ${COLOR_RESET}${COLOR_CONTEXT}${context_fmt}${COLOR_RESET}")
  elif [ "$show_tokens" = "true" ] || [ "$show_credits" = "true" ]; then
    line2_segments+=("${COLOR_LABEL}context: ${COLOR_RESET}${COLOR_CONTEXT}--${COLOR_RESET}")
  fi

  if [ "$show_tokens" = "true" ]; then
    tokens_str="${COLOR_LABEL}token: ${COLOR_RESET}${COLOR_TOKENS}${in_fmt}/${out_fmt}${COLOR_RESET}"
    extra_info=""
    if [[ "$tokens_cached" =~ ^[0-9]+$ ]] && [ "$tokens_cached" -gt 0 ]; then
      extra_info="${COLOR_LABEL}cache: ${COLOR_RESET}${COLOR_TOKENS}${cached_fmt}${COLOR_RESET}"
    fi
    if [[ "$tokens_thinking" =~ ^[0-9]+$ ]] && [ "$tokens_thinking" -gt 0 ]; then
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

  if [ "$show_credits" = "true" ]; then
    credits_display="$credits_rem"
    if [[ "$credits_display" != \$* ]]; then
      credits_display="\$${credits_display}"
    fi
    line2_segments+=("${COLOR_LABEL}$: ${COLOR_RESET}${COLOR_CREDITS}${credits_display}${COLOR_RESET}")
  fi
fi

line1_output=""
for i in "${!line1_segments[@]}"; do
  if [ "$i" -eq 0 ]; then
    line1_output="${line1_segments[$i]}"
  else
    line1_output="$line1_output | ${line1_segments[$i]}"
  fi
done

line2_output=""
for i in "${!line2_segments[@]}"; do
  if [ "$i" -eq 0 ]; then
    line2_output="${line2_segments[$i]}"
  else
    line2_output="$line2_output | ${line2_segments[$i]}"
  fi
done

if [ -n "$line2_output" ]; then
  echo -e "$line1_output\n$line2_output"
else
  echo -e "$line1_output"
fi
