#!/bin/bash
# 每天 18:00（北京时间）由 crontab 触发：
# 扫描 ~/.claude/projects/ 下过去 24h 修改过的会话 jsonl，
# 调用 claude -p 做汇总，保存到 ~/.claude/summaries/<YYYYMMDD>-180000-cron-daily.md
#
# 命名规范与 PostCompact hook、/daily-summary 斜杠命令统一：
#   <YYYYMMDD-HHMMSS>-<source>-<id>.md
#   source: compact | manual | cron

set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECTS_DIR="$HOME/.claude/projects"
SUMMARIES_DIR="$HOME/.claude/summaries"
mkdir -p "$SUMMARIES_DIR"

ts_human=$(date "+%Y-%m-%d %H:%M:%S")
ts_file=$(date "+%Y%m%d-%H%M%S")
outfile="$SUMMARIES_DIR/${ts_file}-cron-daily.md"

# 收集过去 24h 修改过的 jsonl
# 注意：用 while-read 而不是 mapfile，兼容 macOS 自带 bash 3.2
sessions=()
while IFS= read -r line; do
  sessions+=("$line")
done < <(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -1 2>/dev/null)

if [ "${#sessions[@]}" -eq 0 ]; then
  {
    printf '%s\n' "---"
    printf 'timestamp: %s\n' "$ts_human"
    printf 'source: cron\n'
    printf 'window: 24h\n'
    printf 'sessions: 0\n'
    printf '%s\n' "---"
    printf '\n# 每日摘要（cron 18:00 触发）\n\n过去 24 小时没有会话活动。\n'
  } > "$outfile"
  exit 0
fi

# 把每个会话的文本提取出来，按项目分组拼接
context_file=$(mktemp)
trap 'rm -f "$context_file"' EXIT

for f in "${sessions[@]}"; do
  proj_dir=$(basename "$(dirname "$f")")
  # 反推项目路径：-Users-foo-Work-bar -> /Users/foo/Work/bar
  proj_path=$(echo "$proj_dir" | sed 's/^-/\//' | sed 's/-/\//g')
  sid=$(basename "$f" .jsonl | cut -c1-8)
  echo "========================================" >> "$context_file"
  echo "项目: $proj_path" >> "$context_file"
  echo "会话: $sid" >> "$context_file"
  echo "========================================" >> "$context_file"
  jq -r '
    select(.type=="user" or .type=="assistant")
    | select(.timestamp != null)
    | select((.timestamp | gsub("\\.\\d+Z$"; "Z") | fromdateiso8601) > (now - 86400))
    | .message.content
    | if type=="string" then .
      elif type=="array" then (
        .[] | if .type=="text" then .text
              elif .type=="tool_use" then "[tool: " + .name + "]"
              else empty end
      )
      else empty end
  ' "$f" 2>/dev/null >> "$context_file" || true
  echo "" >> "$context_file"
done

session_count="${#sessions[@]}"
total_chars=$(wc -c < "$context_file" | tr -d ' ')

# 调用 claude -p 做汇总
prompt="你是会话归档助手。下面是过去 24 小时（${ts_human}）跨多个项目的 Claude Code 会话记录拼接。
共 $session_count 个会话，约 $total_chars 字符。请用中文生成一份每日摘要，结构如下：

## 今日概览
（一句话总结今天做了什么）

## 各项目进展
（按项目分组，每个项目列出关键进展、决策、未完成事项）

## 关键决策与原因
（要点列表）

## 未完成/下一步
（要点列表）

## 坑点与注意
（如有）

要求：简洁、聚焦事实、引用具体文件路径。不要客套话。

----- 会话记录开始 -----
"

{
  printf '%s' "$prompt"
  cat "$context_file"
} | claude -p --output-format=text > "$outfile.body" 2>"$outfile.err" || {
  # claude 调用失败时也落盘，便于排查
  {
    printf '%s\n' "---"
    printf 'timestamp: %s\n' "$ts_human"
    printf 'source: cron\n'
    printf 'window: 24h\n'
    printf 'sessions: %s\n' "$session_count"
    printf 'error: claude -p failed\n'
    printf '%s\n' "---"
    printf '\n# 每日摘要（cron 18:00 触发）—— 调用失败\n\n'
    printf '会话数: %s\n' "$session_count"
    printf '上下文字符数: %s\n\n' "$total_chars"
    printf '## stderr\n\n```\n%s\n```\n' "$(cat "$outfile.err")"
  } > "$outfile"
  rm -f "$outfile.body" "$outfile.err"
  exit 0
}

{
  printf '%s\n' "---"
  printf 'timestamp: %s\n' "$ts_human"
  printf 'source: cron\n'
  printf 'window: 24h\n'
  printf 'sessions: %s\n' "$session_count"
  printf 'total_chars: %s\n' "$total_chars"
  printf '%s\n' "---"
  printf '\n# 每日摘要（cron 18:00 触发）\n\n'
  cat "$outfile.body"
} > "$outfile"

rm -f "$outfile.body" "$outfile.err"
