# cc-daily-report

用 Claude Code Hooks + 斜杠命令搭建一套会话摘要工作流。让摘要自动攒着，跨项目统一存档，早上一个命令回顾昨天、定今天。

## 一个普通工作日

早上到工位，打开 Claude Code，输入：

```
/morning-review
```

它读了一遍昨天攒下来的摘要卡片，给你一份回顾：

> **🌅 昨日回顾**
> - hook 项目：写了 PostCompact hook，把压缩前的上下文落盘
> - daily-summary 命令：从单会话总结改成了跨会话汇总
> - cron 脚本：每天 18:00 自动跑，PATH 要显式 export
>
> **未完成**：morning-review 命令还没写完
>
> **下一步**：
> 1. morning-review 命令今天落地吗？
> 2. cron 首次执行是明天 18:00，要不要现在手动验证一次？

你顺着它的问题，跟它讨论今天要做什么，然后开始干活。

白天，你在 3 个项目里跳来跳去，开了 4 个 Claude Code 会话。每次上下文被压缩时，hook 自动把压缩前的摘要落盘到 `~/.claude/summaries/`——你完全无感，但东西都在。下午完成一个阶段，想留个节点，随手跑一下：

```
/daily-summary
```

它扫了所有项目过去 24h 的会话，给你一份跨项目的当日总账，存成一张卡片。

下班走人。18:00 你已经不在电脑前，但 cron 自动跑了一遍，兜底生成一张每日汇总卡片——白天忘了手动跑也没关系。

第二天早上，又是 `/morning-review`。循环。

---

这套流程背后是四个组件。下面讲怎么搭。

## 安装

### 前置依赖

- [Claude Code](https://claude.com/claude-code) CLI（`claude` 命令可用）
- `jq`（解析 hook 输入和会话 jsonl）
- `bash` 4+（cron 脚本用了 `mapfile`）

```bash
which claude jq
```

### 三步安装

**1. 拷贝文件**

```bash
# 在本仓库根目录执行
cp commands/*.md ~/.claude/commands/
cp hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
mkdir -p ~/.claude/summaries
```

**2. 注册 PostCompact hook**

把下面这段加到 `~/.claude/settings.json` 的 `hooks` 字段里（和已有的 hooks 合并，不要替换）：

```json
{
  "hooks": {
    "PostCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/compact-summary-card.sh\"",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

**3. 注册 crontab（可选，自动每日兜底）**

```bash
# 改成你想触发的时间，下面是每天 18:00
(crontab -l 2>/dev/null; echo "0 18 * * * /bin/bash $HOME/.claude/hooks/daily-summary-cron.sh >> $HOME/.claude/summaries/cron.log 2>&1") | crontab -
```

> ⚠️ cron 环境的 PATH 极简，打开 `~/.claude/hooks/daily-summary-cron.sh`，把第 14 行的 `PATH` 改成包含 `claude` 和 `jq` 的路径（用 `which claude jq` 查）。

### 让 Claude Code 帮你装（推荐）

直接在本仓库目录里启动 Claude Code，告诉它：

> 帮我把这个仓库的 commands 和 hooks 安装到 ~/.claude/，注册 PostCompact hook 到 settings.json，再帮我注册 crontab 每天 18:00 跑 daily-summary-cron.sh。

它会读这个仓库的文件，按上面的步骤执行。

### 生效

- 斜杠命令立即生效
- PostCompact hook 需要打开一次 `/hooks` 菜单或重启 Claude Code 重载配置
- cron 按设定时间自动跑

## 整体设计

四种触发方式，全部落到同一个目录 `~/.claude/summaries/`，用统一命名规范和 frontmatter 区分来源。

| 触发方式 | 范围 | 模型 | 干什么 |
|---|---|---|---|
| PostCompact hook | 当前会话 | 当前会话模型 | 上下文压缩前自动落盘快照 |
| `/daily-summary` 斜杠命令 | 过去 24h 所有会话 | 当前会话模型 | 手动跨会话汇总 |
| crontab（默认 18:00） | 过去 24h 所有会话 | `claude -p` | 自动每日汇总兜底 |
| `/morning-review` 斜杠命令 | 读近 36h 的摘要卡片 | 当前会话模型 | 昨日回顾 + 引导讨论下一步 |

**命名规范**：`<YYYYMMDD-HHMMSS>-<source>-<id>.md`
- `source` ∈ `compact | manual | cron`，frontmatter 里也带这个字段
- `id` 对 compact 是 session 前 8 位，对 manual/cron 是 `daily`

**目录结构**：
```
~/.claude/
├── commands/
│   ├── daily-summary.md
│   └── morning-review.md
├── hooks/
│   ├── compact-summary-card.sh
│   └── daily-summary-cron.sh
├── summaries/                # 所有摘要卡片落在这里
│   ├── 20260626-163208-compact-abc12345.md
│   ├── 20260626-180000-cron-daily.md
│   └── 20260627-093012-manual-daily.md
└── settings.json
```

## 各组件实现

### 1. PostCompact Hook：压缩前自动落盘

**为什么用 PostCompact 而不是 PreCompact**：PreCompact 触发时摘要还没生成；PostCompact 触发时 hook 输入里直接带着 Claude 刚生成的上下文摘要，正好是「压缩前的上下文概要」。

**`hooks/compact-summary-card.sh`**：

```bash
#!/bin/bash
# PostCompact hook: 把压缩前的上下文摘要落盘
set -euo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace // .current_dir // empty')
trigger=$(printf '%s' "$input" | jq -r '.trigger // .source // "unknown"')

# PostCompact 输入里带 summary 字段，字段名兼容几种
summary=$(printf '%s' "$input" | jq -r '
  .summary // .compacted_summary // .compaction_summary
  // .output.summary // .output // .text // empty
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

project_label="${cwd:-unknown}"
[ -n "$cwd" ] && [ -d "$cwd" ] && project_label=$(basename "$cwd")

{
  printf '%s\n' "---"
  printf 'timestamp: %s\n' "$ts_human"
  printf 'source: compact\n'
  printf 'session_id: %s\n' "$session_id"
  printf 'project: %s\n' "$project_label"
  printf 'cwd: %s\n' "${cwd:-}"
  printf 'trigger: %s\n' "$trigger"
  printf '%s\n' "---"
  printf '\n# 上下文摘要卡片（PostCompact 自动触发）\n\n'
  printf '%s\n' "$summary"
} > "$filename"

# 通过 systemMessage 把摘要打印回 Claude Code UI
jq -n --arg file "$filename" --arg summary "$summary" \
     --arg ts "$ts_human" --arg proj "$project_label" \
  '{systemMessage: ("📝 [compact] 摘要卡片已保存\n\n📄 文件: \($file)\n🕐 时间: \($ts)\n📁 项目: \($proj)\n\n--- 摘要内容 ---\n\n" + $summary)}'
```

**关键点**：
- hook 输入是 stdin 的 JSON，用 `jq -r` 解析，不要用 `xargs`（路径有空格会炸）
- 用 `systemMessage` 字段回显到 UI，而不是 stdout（stdout 可能被 suppress）
- 文件名带 `source: compact` 和 session id，方便后续按会话筛选

### 2. `/daily-summary` 斜杠命令：手动跨会话汇总

斜杠命令本质是一个 prompt 模板，存在 `~/.claude/commands/<name>.md`，Claude Code 执行时把模板内容当 prompt 发给当前会话的模型。

**`commands/daily-summary.md`**（frontmatter + prompt，完整文件见仓库）：

```markdown
---
description: 汇总过去 24 小时所有项目的会话活动，生成每日摘要卡片
argument-hint: [可选：额外备注/关注方向]
---

请对过去 24 小时跨所有项目的 Claude Code 会话做一次完整汇总。

## 步骤

### 1. 发现会话
\`\`\`bash
find ~/.claude/projects -name "*.jsonl" -mtime -1 -type f -print0 | xargs -0 ls -lt
\`\`\`
目录名（如 `-Users-foo-Work-bar`）反推项目路径：开头的 `-` 换成 `/`，其余 `-` 换成 `/`。

### 2. 提取每个会话内容（只取过去 24h 的消息）
\`\`\`bash
jq -r 'select(.type=="user" or .type=="assistant") | select(.timestamp != null) | select((.timestamp | gsub("\\.\\d+Z$"; "Z") | fromdateiso8601) > (now - 86400)) | .message.content | if type=="string" then . elif type=="array" then (.[] | if .type=="text" then .text elif .type=="tool_use" then "[tool: " + .name + "]" else empty end) else empty end' <文件>
\`\`\`
时间戳过滤：每条消息有 `timestamp`（ISO 8601 带毫秒），gsub 去毫秒后 fromdateiso8601 解析，和 now - 86400 比。
一个横跨多天的会话，只总结最近 24h 的部分。

### 3-5. 生成结构化摘要 → 保存为 *-manual-daily.md → 打印
```

**关键点**：
- `$ARGUMENTS` 是斜杠命令的参数占位符，用户输入 `/daily-summary 重点看 hook` 时会被替换
- 这是**跨会话**汇总，不限于当前会话——当前会话只是其中一个来源
- **只取过去 24h 的消息**，不是整个会话文件——一个横跨 24 天的会话，只总结最近 24h 内说的话

### 3. Crontab：每天自动汇总兜底

斜杠命令需要人主动跑，忘了就没了。加一个 cron 兜底，每天自动跑，调 `claude -p` 用无头模式汇总。

**`hooks/daily-summary-cron.sh`**（完整文件见仓库，核心逻辑）：

```bash
#!/bin/bash
set -euo pipefail
# ⚠️ cron 环境极简，PATH 要显式 export，确保 claude 和 jq 能找到
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECTS_DIR="$HOME/.claude/projects"
SUMMARIES_DIR="$HOME/.claude/summaries"
mkdir -p "$SUMMARIES_DIR"

# 用 find -mtime -1 发现可能包含近 24h 消息的文件（性能优化）
mapfile -r sessions < <(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -1 2>/dev/null)

# 拼接所有会话文本，提取时按消息 timestamp 再过滤一次（只保留真正近 24h 的消息）
for f in "${sessions[@]}"; do
  jq -r '
    select(.type=="user" or .type=="assistant")
    | select(.timestamp != null)
    | select((.timestamp | gsub("\\.\\d+Z$"; "Z") | fromdateiso8601) > (now - 86400))
    | .message.content
    | if type=="string" then .
      elif type=="array" then (.[] | if .type=="text" then .text elif .type=="tool_use" then "[tool: " + .name + "]" else empty end)
      else empty end
  ' "$f" 2>/dev/null >> "$context_file" || true
done

# 调 claude -p 做汇总，失败也要落盘（带 stderr），不然不知道是没活动还是脚本挂了
{ printf '%s' "$prompt"; cat "$context_file"; } | claude -p --output-format=text > "$outfile.body" 2>"$outfile.err" || {
  # ... 失败兜底逻辑
}
```

**注册 crontab**：

```bash
# 默认每天 18:00，改成你想要的时间
(crontab -l 2>/dev/null; echo "0 18 * * * /bin/bash $HOME/.claude/hooks/daily-summary-cron.sh >> $HOME/.claude/summaries/cron.log 2>&1") | crontab -
```

**关键点**：
- `claude -p` 是无头模式，走 settings.json 里配的模型
- cron 环境 PATH 极简，必须显式 export，否则找不到 `claude` / `jq`
- 失败也要落盘（带 stderr），不然第二天早上 review 时一片空白不知道是没活动还是脚本挂了
- 时间可调，选下班前后的时间点都行

### 4. `/morning-review` 斜杠命令：早上回顾

这是整个工作流的「消费端」——把攒下来的摘要卡片读出来，二次提炼成昨日回顾，并引导讨论下一步。

**`commands/morning-review.md`**（核心 prompt）：

```markdown
---
description: 回顾昨天到今天的所有摘要卡片，生成昨日回顾并引导讨论下一步
argument-hint: [可选：今天打算关注的方向]
---

### 1. 加载昨日摘要
\`\`\`bash
find ~/.claude/summaries -name "*.md" -mtime -1.5 -type f | sort -r
\`\`\`
逐个 Read 这些文件。frontmatter 里有 source（compact/manual/cron）、project、timestamp、cwd。

### 2. 生成「昨日回顾」
- 🌅 过做过的事（按项目分组）
- 关键决策
- 未完成/卡住的
- 遗留风险

### 3. 引导讨论下一步
主动提问 2-3 个具体、可决策的问题，比如：
- 「昨天 X 没做完，今天继续还是先放一放？」
- 「Y 这个决策今天要落地吗？」

### 4-5. 处理备注 / 没有摘要时的兜底
```

**关键点**：
- 读的是**摘要卡片**（已经提炼过一次），不是原始 jsonl —— 省很多 token
- 36h 窗口是为了覆盖昨晚晚些时候的 compact 摘要
- 最后必须主动提问，不是给完回顾就结束——目标是启动今天的讨论

## 查看历史摘要

```bash
ls -lt ~/.claude/summaries/*.md            # 按时间倒序
cat ~/.claude/summaries/<某文件>.md         # 看具体卡片
grep -l "某项目" ~/.claude/summaries/*.md   # 按项目找
grep -l "source: cron" ~/.claude/summaries/*.md  # 按来源筛
```

## 验证清单

搭这套东西时踩过的坑，复现时建议逐项验证：

1. **hook 脚本要 `chmod +x`**，不然 PostCompact 静默不执行
2. **settings.json 改完要重载**：打开一次 `/hooks` 菜单或重启 Claude Code，settings watcher 不一定热加载
3. **PostCompact hook 在改配置的当前会话不生效**，要新开会话或 `/hooks` 重载
4. **cron 的 PATH**：cron 环境只有 `/usr/bin:/bin`，`claude` 和 `jq` 都可能不在，要显式 export
5. **hook 输入从 stdin 读**，不要尝试从环境变量或参数拿
6. **`jq -r` 解析 stdin**，不要用 `xargs`（路径有空格会断）
7. **`claude -p` 的认证**：会读 settings.json 的 env，但如果 cron 里认证失败，检查是否需要手动 export `ANTHROPIC_AUTH_TOKEN` 等
8. **hook 用 `systemMessage` 回显**，不是 stdout（stdout 可能被 suppress）
9. **cron 脚本失败也要落盘**，不然不知道是没活动还是脚本挂了
10. **斜杠命令的 `$ARGUMENTS`**：是参数占位符，用户输入会替换进去
11. **时间戳带毫秒**：`fromdateiso8601` 只吃整秒，要 `gsub("\\.\\d+Z$"; "Z")` 去毫秒
12. **跨天会话只取近 24h**：`find -mtime -1` 只用于发现文件，提取时必须按消息 `timestamp` 再过滤一次

## 设计取舍说明

**为什么用 PostCompact 而不是 PreCompact**：PreCompact 触发时摘要还没生成，得自己再调一次 LLM 生成摘要，浪费；PostCompact 输入里直接带 summary 字段，免费拿到。

**为什么 cron 用 `claude -p` 而不是 hook**：hook 是会话内事件，cron 是系统级定时，两者不能互替。cron 跑时没有活跃会话，只能用无头模式。

**为什么 `/daily-summary` 和 cron 范围一样**：cron 是兜底（怕忘），斜杠命令是主动（想随时跑）。范围一样，文件名带 `source` 区分，早上 review 时都能读到。

**为什么 `/morning-review` 读摘要卡片而不是原始 jsonl**：摘要卡片是已经提炼过一次的，token 省、信息密度高。原始 jsonl 太长，每天几个会话可能几十万字符。

**为什么用 markdown + frontmatter 而不是 JSON**：人要直接读，markdown 可读性好；frontmatter 又方便程序化筛选（grep / jq 都行）。

**为什么跨天会话只取近 24h 消息**：一个会话可能横跨很多天，如果整个文件都总结，今天的总结里会混入上周的内容。`find -mtime -1` 只用于发现文件（性能），提取时按消息 `timestamp` 再过滤一次（正确性）。

## License

MIT
