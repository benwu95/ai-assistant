#!/bin/bash
# Set defaults
agent_state="idle"
model=""
cwd=""
branch=""
dirty="false"
subagents_count="0"
sandbox_val="false"
tokens_in="0"
tokens_out="0"
tokens_cached="0"
credits_rem=""
quota_mode="single"
remaining_fraction=""
reset_in_seconds=""
weekly_remaining_fraction=""
weekly_reset_in_seconds=""
tp_remaining_fraction=""
tp_reset_in_seconds=""
tp_weekly_remaining_fraction=""
tp_weekly_reset_in_seconds=""
used_pct=""
cli_version=""
cycle_mode="default"
color_scheme="default"
orch_planner=""
orch_executor=""

settings_file="${ANTIGRAVITY_SETTINGS_FILE:-$HOME/.gemini/antigravity-cli/settings.json}"
if [ -f "$settings_file" ]; then
  eval "$(jq -r '
    "color_scheme=" + ((.colorScheme // "default") | tostring | @sh) + "\n" +
    "orch_planner=" + ((.orchestrator.planner // "") | tostring | @sh) + "\n" +
    "orch_executor=" + ((.orchestrator.executor // "") | tostring | @sh)
  ' "$settings_file" 2>/dev/null)"
fi

parse_payload() {
  jq -r --arg orch_planner "$orch_planner" --arg orch_executor "$orch_executor" '
  def pool_for_model($s):
    (($s // "") | ascii_downcase) as $l |
    if ($l | test("^[[:space:]]*$")) then null
    elif ($l | test("(^|[^a-z])(claude|gpt|opus|sonnet|oss)([^a-z]|$)")) then "3p"
    elif ($l | test("(^|[^a-z])(gemini|neon|carbon|argon|hydrogen)([^a-z]|$)")) then "gemini"
    else "3p"
    end;
  def orchestrator_fallback_pool($id; $name):
    ($name | ascii_downcase) as $n_lower |
    (try ($n_lower | capture("orchestrator[[:space:]]*\\((?<inner>[^)]+)\\)").inner) catch null) as $inner |
    if $inner != null then
      pool_for_model($inner)
    else
      pool_for_model($id + " " + $name)
    end;
  def resolve_pools($id; $name; $planner; $executor):
    if (($id + " " + $name) | ascii_downcase | test("(^|[^a-z])orchestrator([^a-z]|$)")) then
      ([$planner, $executor] | map(pool_for_model(.)) | map(select(. != null)) | unique) as $cfg |
      if ($cfg | length) > 0 then $cfg
      else [orchestrator_fallback_pool($id; $name) // "gemini"]
      end
    else
      [pool_for_model($id + " " + $name) // "gemini"]
    end;
  def get_single_pool($pool; $win):
    if $pool == "3p" then
      (.quota["3p-" + $win] // .quota["gemini-" + $win] // {})
    else
      (.quota["gemini-" + $win] // .quota["3p-" + $win] // {})
    end;
  ((.agent_state // .state // "idle")) as $st |
  (.model.id // "") as $m_id |
  (.model.display_name // "") as $m_name |
  ($m_name | if . == "" then $m_id else . end) as $m |
  (.orchestrator.planner // $orch_planner // "") as $eff_planner |
  (.orchestrator.executor // $orch_executor // "") as $eff_executor |
  resolve_pools($m_id; $m_name; $eff_planner; $eff_executor) as $pools |
  (($pools | index("gemini") != null) and ($pools | index("3p") != null)) as $is_dual |
  (if $is_dual then (.quota["gemini-5h"] // {}) else get_single_pool(($pools[0] // "gemini"); "5h") end) as $q5 |
  (if $is_dual then (.quota["gemini-weekly"] // {}) else get_single_pool(($pools[0] // "gemini"); "weekly") end) as $qw |
  (if $is_dual then (.quota["3p-5h"] // {}) else {} end) as $tp5 |
  (if $is_dual then (.quota["3p-weekly"] // {}) else {} end) as $tpw |
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
  "credits_rem=" + ((.credits.remaining // .credits // .cost.total_cost_usd // "") | tostring | @sh) + "\n" +
  "quota_mode=" + ((if $is_dual then "dual" else "single" end) | @sh) + "\n" +
  "remaining_fraction=" + (($q5.remaining_fraction // $q5.remainingFraction // "") | tostring | @sh) + "\n" +
  "reset_in_seconds=" + (($q5.reset_in_seconds // $q5.resetInSeconds // $q5.resets_at // $q5.reset_time // $q5.resetTime // "") | tostring | @sh) + "\n" +
  "weekly_remaining_fraction=" + (($qw.remaining_fraction // $qw.remainingFraction // "") | tostring | @sh) + "\n" +
  "weekly_reset_in_seconds=" + (($qw.reset_in_seconds // $qw.resetInSeconds // $qw.resets_at // $qw.reset_time // $qw.resetTime // "") | tostring | @sh) + "\n" +
  "tp_remaining_fraction=" + (($tp5.remaining_fraction // $tp5.remainingFraction // "") | tostring | @sh) + "\n" +
  "tp_reset_in_seconds=" + (($tp5.reset_in_seconds // $tp5.resetInSeconds // $tp5.resets_at // $tp5.reset_time // $tp5.resetTime // "") | tostring | @sh) + "\n" +
  "tp_weekly_remaining_fraction=" + (($tpw.remaining_fraction // $tpw.remainingFraction // "") | tostring | @sh) + "\n" +
  "tp_weekly_reset_in_seconds=" + (($tpw.reset_in_seconds // $tpw.resetInSeconds // $tpw.resets_at // $tpw.reset_time // $tpw.resetTime // "") | tostring | @sh) + "\n" +
  "used_pct=" + ((.context_window.used_percentage // .context_window.current_usage.used_percentage // .used_percentage // "") | tostring | @sh) + "\n" +
  "cli_version=" + ((.version // "") | tostring | @sh) + "\n" +
  "cycle_mode=" + ((.cycle_mode // .agent_mode // .mode // "default") | tostring | @sh)
' 2>/dev/null
}

if [ -t 0 ]; then
  eval "$(echo "{}" | parse_payload)"
else
  eval "$(parse_payload)"
fi

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

# Theme definitions

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

format_quota_pool() {
  local prefix=$1
  local rem=$2
  local reset=$3
  local w_rem=$4
  local w_reset=$5
  local out=""
  local used_val reset_fmt weekly_used_val weekly_reset_fmt weekly_part

  if [ -n "$rem" ] && [ "$rem" != "null" ]; then
    used_val=$(awk -v r="$rem" 'BEGIN { printf "%.1f%%", (1 - r) * 100 }' 2>/dev/null || echo "0.0%")
    reset_fmt=$(format_reset_time "$reset")
    out="${COLOR_LABEL}${prefix}5h: ${COLOR_RESET}${COLOR_USAGE}${used_val}${COLOR_RESET}"
    if [ -n "$reset_fmt" ]; then
      out="${out} ${COLOR_LABEL}(${reset_fmt})${COLOR_RESET}"
    fi
  fi

  if [ -n "$w_rem" ] && [ "$w_rem" != "null" ]; then
    weekly_used_val=$(awk -v r="$w_rem" 'BEGIN { printf "%.1f%%", (1 - r) * 100 }' 2>/dev/null || echo "0.0%")
    weekly_reset_fmt=$(format_reset_time "$w_reset" "true")
    if [ -n "$out" ]; then
      weekly_part="${COLOR_LABEL}7d: ${COLOR_RESET}${COLOR_USAGE}${weekly_used_val}${COLOR_RESET}"
    else
      weekly_part="${COLOR_LABEL}${prefix}7d: ${COLOR_RESET}${COLOR_USAGE}${weekly_used_val}${COLOR_RESET}"
    fi
    if [ -n "$weekly_reset_fmt" ]; then
      weekly_part="${weekly_part} ${COLOR_LABEL}(${weekly_reset_fmt})${COLOR_RESET}"
    fi
    if [ -n "$out" ]; then
      out="${out} ${COLOR_LABEL}· ${COLOR_RESET}${weekly_part}"
    else
      out="$weekly_part"
    fi
  fi

  echo "$out"
}

# Quota Formatting
usage_segments=()
if [ "$quota_mode" = "dual" ]; then
  g_fmt=$(format_quota_pool "G " "$remaining_fraction" "$reset_in_seconds" "$weekly_remaining_fraction" "$weekly_reset_in_seconds")
  tp_fmt=$(format_quota_pool "3P " "$tp_remaining_fraction" "$tp_reset_in_seconds" "$tp_weekly_remaining_fraction" "$tp_weekly_reset_in_seconds")
  [ -n "$g_fmt" ] && usage_segments+=("$g_fmt")
  [ -n "$tp_fmt" ] && usage_segments+=("$tp_fmt")
else
  single_fmt=$(format_quota_pool "" "$remaining_fraction" "$reset_in_seconds" "$weekly_remaining_fraction" "$weekly_reset_in_seconds")
  [ -n "$single_fmt" ] && usage_segments+=("$single_fmt")
fi

if [ "${#usage_segments[@]}" -eq 0 ]; then
  usage_segments+=("${COLOR_LABEL}5h: ${COLOR_RESET}${COLOR_USAGE}--${COLOR_RESET}")
fi

context_fmt=""
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
  context_fmt=$(awk -v p="$used_pct" 'BEGIN { printf "%.1f%%", p }')
fi

# Fallback CWD to current directory of process if empty
if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
  cwd=$(pwd)
fi

# Wrap git commands with a 1-second timeout to prevent statusline hanging (signal: killed)
git_cmd() {
  perl -e 'alarm shift; exec @ARGV' 1 git "$@"
}

# Resolve Git state
is_git="false"
is_worktree="false"
git_dir=""
git_op=""

git_info=$(git_cmd -C "$cwd" rev-parse --is-inside-work-tree --absolute-git-dir 2>/dev/null)
if [ -n "$git_info" ]; then
  is_git="true"
  git_dir=$(echo "$git_info" | sed -n '2p')

  # Fallback to manual resolution if CLI payload did not provide a branch
  if [ -z "$branch" ] || [ "$branch" = "null" ]; then
    short_sha=$(git_cmd -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    local_branch=$(git_cmd -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$local_branch" ]; then
      branch="$local_branch"
    elif [ -n "$short_sha" ]; then
      branch="@$short_sha"
    fi
  fi

  # Fallback to manual resolution if CLI payload did not provide dirty status
  if [ -z "$dirty" ] || [ "$dirty" = "null" ]; then
    if [ -n "$(git_cmd -C "$cwd" status --porcelain -unormal 2>/dev/null)" ]; then
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

# Line 1 segments (System)
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

if [ "$sandbox_val" = "true" ]; then
  line1_segments+=("Sandbox: On")
else
  line1_segments+=("Sandbox: Off")
fi

if [[ "$subagents_count" =~ ^[0-9]+$ ]] && [ "$subagents_count" -gt 0 ]; then
  line1_segments+=("🤖 $subagents_count")
fi

in_fmt=$(format_number "$tokens_in")
out_fmt=$(format_number "$tokens_out")
cached_fmt=$(format_number "$tokens_cached")

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

if [ "$show_tokens" = "true" ] || [ "$show_context" = "true" ] || [ "$show_credits" = "true" ]; then
  if [ "$show_context" = "true" ]; then
    line1_segments+=("${COLOR_LABEL}context: ${COLOR_RESET}${COLOR_CONTEXT}${context_fmt}${COLOR_RESET}")
  elif [ "$show_tokens" = "true" ] || [ "$show_credits" = "true" ]; then
    line1_segments+=("${COLOR_LABEL}context: ${COLOR_RESET}${COLOR_CONTEXT}--${COLOR_RESET}")
  fi

  if [ "$show_tokens" = "true" ]; then
    tokens_str="${COLOR_LABEL}token: ${COLOR_RESET}${COLOR_TOKENS}${in_fmt}/${out_fmt}${COLOR_RESET}"
    if [[ "$tokens_cached" =~ ^[0-9]+$ ]] && [ "$tokens_cached" -gt 0 ]; then
      tokens_str="${tokens_str} ${COLOR_LABEL}(cache: ${COLOR_RESET}${COLOR_TOKENS}${cached_fmt}${COLOR_LABEL})${COLOR_RESET}"
    fi
    line1_segments+=("$tokens_str")
  elif [ "$show_credits" = "true" ]; then
    line1_segments+=("${COLOR_LABEL}token: ${COLOR_RESET}${COLOR_TOKENS}--${COLOR_RESET}")
  fi

  if [ "$show_credits" = "true" ]; then
    credits_display="$credits_rem"
    if [[ "$credits_display" != \$* ]]; then
      credits_display="\$${credits_display}"
    fi
    line1_segments+=("${COLOR_LABEL}$: ${COLOR_RESET}${COLOR_CREDITS}${credits_display}${COLOR_RESET}")
  fi
fi

# Line 2 segments (Workspace & Git)
line2_segments=()

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
  line2_segments+=("$cwd_fmt")
fi

if [ "$is_git" = "true" ]; then
  git_stat=$(git_cmd -C "$cwd" diff HEAD --raw --numstat 2>/dev/null | awk '
    BEGIN { mod=0; add=0; del=0; ren=0; add_lines=0; del_lines=0 }
    /^:[0-9]{6}/ {
      status = substr($5, 1, 1)
      if (status == "M" || status == "T") mod++
      else if (status == "A") add++
      else if (status == "D") del++
      else if (status == "R") ren++
      next
    }
    /^[0-9-]+\t[0-9-]+\t/ {
      if ($1 != "-") add_lines += $1
      if ($2 != "-") del_lines += $2
      next
    }
    END {
      printf "+%d/-%d M:%d A:%d D:%d R:%d", add_lines, del_lines, mod, add, del, ren
    }')

  lines_stat=$(echo "$git_stat" | cut -d' ' -f1)
  file_stat=$(echo "$git_stat" | cut -d' ' -f2-)
  lines_add=$(echo "$lines_stat" | cut -d'/' -f1)
  lines_del=$(echo "$lines_stat" | cut -d'/' -f2)

  line2_segments+=("📝 \033[1;32m$lines_add\033[0m/\033[1;31m$lines_del\033[0m, $file_stat")
fi

# Line 3 segments (Model & Quota)
line3_segments=()

if [ -n "$model" ] && [ "$model" != "null" ]; then
  line3_segments+=("${COLOR_MODEL}${model}${COLOR_RESET}")
fi

if [ "${#usage_segments[@]}" -gt 0 ]; then
  for seg in "${usage_segments[@]}"; do
    line3_segments+=("$seg")
  done
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

line3_output=""
for i in "${!line3_segments[@]}"; do
  if [ "$i" -eq 0 ]; then
    line3_output="${line3_segments[$i]}"
  else
    line3_output="$line3_output | ${line3_segments[$i]}"
  fi
done

output=""
[ -n "$line2_output" ] && output="$line2_output"

if [ -n "$line1_output" ]; then
  [ -n "$output" ] && output="$output\n$line1_output" || output="$line1_output"
fi

if [ -n "$line3_output" ]; then
  [ -n "$output" ] && output="$output\n$line3_output" || output="$line3_output"
fi

echo -e "$output"
