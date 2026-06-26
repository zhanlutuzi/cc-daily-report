#!/bin/bash
# PostCompact hook: save a summary card of the pre-compaction context
# and display it back in Claude Code.
# Cross-project storage: ~/.claude/summaries/

set -euo pipefail

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace // .current_dir // empty')
trigger=$(printf '%s' "$input" | jq -r '.trigger // .source // "unknown"')

# PostCompact receives the generated summary. Field name varies by version,
# so try several paths before falling back to the raw payload.
summary=$(printf '%s' "$input" | jq -r '
  .summary
  // .compacted_summary
  // .compaction_summary
  // .output.summary
  // .output
  // .text
  // empty
' 2>/dev/null || true)

if [ -z "$summary" ] || [ "$summary" = "null" ]; then
  summary="(无法从 hook 输入中提取摘要，原始 payload 已保存到 .raw.json 供排查)"
  printf '%s' "$input" > "$HOME/.claude/summaries/last-raw.json"
fi

mkdir -p "$HOME/.claude/summaries"

ts_human=$(date "+%Y-%m-%d %H:%M:%S")
ts_file=$(date "+%Y%m%d-%H%M%S")
sid_short=$(printf '%s' "$session_id" | cut -c1-8)
filename="$HOME/.claude/summaries/${ts_file}-compact-${sid_short}.md"

# Derive a short project label from cwd
project_label="${cwd:-unknown}"
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  project_label=$(basename "$cwd")
fi

{
  printf '%s\n' "---"
  printf 'timestamp: %s\n' "$ts_human"
  printf 'source: compact\n'
  printf 'session_id: %s\n' "$session_id"
  printf 'project: %s\n' "$project_label"
  printf 'cwd: %s\n' "${cwd:-}"
  printf 'trigger: %s\n' "$trigger"
  printf '%s\n' "---"
  printf '\n'
  printf '# 上下文摘要卡片（PostCompact 自动触发）\n\n'
  printf '%s\n' "$summary"
} > "$filename"

# Display the summary card back in Claude Code.
# Using systemMessage so it renders in the UI regardless of stdout handling.
jq -n \
  --arg file "$filename" \
  --arg summary "$summary" \
  --arg ts "$ts_human" \
  --arg proj "$project_label" \
  '{
    systemMessage: ("📝 [compact] 摘要卡片已保存\n\n" +
      "📄 文件: \($file)\n" +
      "🕐 时间: \($ts)\n" +
      "📁 项目: \($proj)\n\n" +
      "--- 摘要内容 ---\n\n" + $summary)
  }'
