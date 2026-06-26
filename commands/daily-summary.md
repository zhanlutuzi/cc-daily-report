---
description: 汇总过去 24 小时所有项目的会话活动，生成每日摘要卡片
argument-hint: [可选：额外备注/关注方向]
---

请对过去 24 小时跨所有项目的 Claude Code 会话做一次完整汇总，生成「每日摘要卡片」。

## 步骤

### 1. 发现会话

用 Bash 找出过去 24h 修改过的会话 jsonl：

```bash
find ~/.claude/projects -name "*.jsonl" -mtime -1 -type f -print0 | xargs -0 ls -lt
```

记录总数和各文件路径。每个 jsonl 所在目录名（如 `-Users-foo-Work-bar`）反推就是项目路径（`/Users/foo/Work/bar`，把开头的 `-` 换成 `/`，其余 `-` 换成 `/`）。

### 2. 提取每个会话的内容

对每个 jsonl 文件，用 Bash + jq 提取用户和助手的文本内容。**关键：只取过去 24h 内的消息，不是整个会话文件**——一个横跨多天的会话，只总结最近 24h 的部分：

```bash
jq -r 'select(.type=="user" or .type=="assistant") | select(.timestamp != null) | select((.timestamp | gsub("\\.\\d+Z$"; "Z") | fromdateiso8601) > (now - 86400)) | .message.content | if type=="string" then . elif type=="array" then (.[] | if .type=="text" then .text elif .type=="tool_use" then "[tool: " + .name + "]" else empty end) else empty end' <文件路径>
```

时间过滤逻辑：每条消息有 `timestamp` 字段（ISO 8601 带毫秒，如 `2026-06-26T09:08:20.762Z`），用 `gsub` 去掉毫秒后 `fromdateiso8601` 解析为 epoch，和 `now - 86400`（24h 前）比较。

如果一个会话过滤后没有消息（最近 24h 没活动），跳过它。按项目分组，把每个会话的内容收集起来。对超长会话（比如超过 3 万字符）只取开头+结尾各一部分，中间用 `... [省略 N 字符] ...` 标注。

### 3. 生成每日摘要

基于所有会话内容，用中文生成结构化摘要：

## 每日摘要

**今日概览**：一句话总结今天做了什么

**各项目进展**：按项目分组，每个项目列出
- 关键进展（要点列表，引用具体文件路径和行号）
- 关键决策与原因
- 未完成/卡住的事项

**未完成/下一步**：跨项目的待办清单

**坑点与注意**：踩过的坑、需要注意的边界

### 4. 保存摘要卡片

把摘要保存为 markdown 文件：
- 路径：`~/.claude/summaries/<YYYYMMDD-HHMMSS>-manual-daily.md`（时间戳用 `date "+%Y%m%d-%H%M%S"`）
- frontmatter：
  ```
  ---
  timestamp: <YYYY-MM-DD HH:MM:SS>
  source: manual
  scope: multi-session
  window: 24h
  sessions: <会话数>
  projects: <项目列表，逗号分隔>
  note: $ARGUMENTS
  ---
  ```
- 然后是 `# 每日摘要（/daily-summary 手动触发）` 标题和摘要正文

### 5. 打印给我看

保存后把摘要完整内容打印出来，并告诉我文件保存路径。

## 注意

- 这是跨会话汇总，不限于当前会话。当前会话只是其中一个来源。
- 如果 `$ARGUMENTS` 非空，作为额外备注写入 frontmatter 的 `note` 字段，并在汇总时也考虑这个方向。
- 不要写客套话，直接给摘要。
- 如果过去 24h 没有任何会话活动，直接告诉我「过去 24h 没有会话记录」。
