# cc-daily-report

A standup-and-EOD workflow for Claude Code. Automatically capture context summaries before compaction, roll them up across projects, and start each morning with a recap that tees up the day.

[中文文档 (Chinese README)](README.zh-CN.md)

## A day in the life

You sit down in the morning, open Claude Code, and type:

```
/morning-review
```

It reads through the summary cards stashed from yesterday and hands you a recap:

> **🌅 Yesterday's recap**
> - hook: shipped the PostCompact hook — context now persists to disk before compaction
> - daily-summary: rewrote it to roll up across sessions, not just the current one
> - cron: 18:00 daily run, PATH needs an explicit export
>
> **Leftover**: morning-review command isn't done yet
>
> **Today**:
> 1. Ship morning-review today?
> 2. cron first fires tomorrow 18:00 — dry-run it now?

You answer its questions, kick around today's plan, and get to work.

Through the day you bounce between 3 projects and 4 sessions. Every time a session compacts, the hook silently saves the pre-compaction summary to `~/.claude/summaries/` — invisible, but nothing's lost. Mid-afternoon you hit a natural pause and want a checkpoint:

```
/daily-summary
```

It scans every session across every project from the last 24h, writes you a cross-project daily rollup, and files it as a card.

You head out. At 18:00, while you're gone, cron fires and writes a safety-net card — so even if you forgot to run anything manually, the day's still captured.

Next morning, `/morning-review` again. The loop closes.

---

Four pieces make this work. Here's how to set them up.

## Install

### Prerequisites

- [Claude Code](https://claude.com/claude-code) CLI (`claude` on your PATH)
- `jq`
- `bash` 3.2+ (works on macOS system bash; uses `while read` instead of `mapfile`)

```bash
which claude jq
```

### Three steps

**1. Copy the files**

```bash
# from the repo root
cp commands/*.md ~/.claude/commands/
cp hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
mkdir -p ~/.claude/summaries
```

**2. Register the PostCompact hook**

Merge this into the `hooks` field of `~/.claude/settings.json` (don't replace existing hooks):

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

**3. Register the crontab (optional — automated daily safety net)**

```bash
# 18:00 daily — change to whatever fits your schedule
(crontab -l 2>/dev/null; echo "0 18 * * * /bin/bash $HOME/.claude/hooks/daily-summary-cron.sh >> $HOME/.claude/summaries/cron.log 2>&1") | crontab -
```

> ⚠️ cron's PATH is bare. Open `~/.claude/hooks/daily-summary-cron.sh` and edit line 14's `PATH` so it includes wherever `claude` and `jq` live (`which claude jq` to find out).

### Have Claude Code install it for you (recommended)

From inside this repo, launch Claude Code and say:

> Install this repo's commands and hooks into ~/.claude/, register the PostCompact hook in settings.json, and set up the crontab to run daily-summary-cron.sh at 18:00 daily.

It'll read the repo and follow the steps above.

### Activation

- Slash commands work immediately
- PostCompact hook needs a `/hooks` menu open or a Claude Code restart to reload
- cron fires on its schedule

## How it fits together

Four triggers, all writing to `~/.claude/summaries/` with a shared naming scheme and frontmatter.

| Trigger | Scope | Model | Purpose |
|---|---|---|---|
| PostCompact hook | current session | current session's model | snapshot context before compaction |
| `/daily-summary` | last 24h, all sessions | current session's model | manual cross-session rollup |
| crontab (default 18:00) | last 24h, all sessions | `claude -p` | automated daily safety net |
| `/morning-review` | last 36h of cards | current session's model | recap + tee up today's plan |

**Naming**: `<YYYYMMDD-HHMMSS>-<source>-<id>.md`
- `source` ∈ `compact | manual | cron` (also in frontmatter)
- `id` is the first 8 chars of session ID for compact, or `daily` for manual/cron

**Layout**:
```
~/.claude/
├── commands/
│   ├── daily-summary.md
│   └── morning-review.md
├── hooks/
│   ├── compact-summary-card.sh
│   └── daily-summary-cron.sh
├── summaries/
│   ├── 20260626-163208-compact-abc12345.md
│   ├── 20260626-180000-cron-daily.md
│   └── 20260627-093012-manual-daily.md
└── settings.json
```

## Components

### 1. PostCompact hook — snapshot before compaction

**Why PostCompact, not PreCompact**: at PreCompact time the summary doesn't exist yet — you'd have to call the model yourself to make one. PostCompact's input already carries Claude's generated summary, free.

**`hooks/compact-summary-card.sh`**:

```bash
#!/bin/bash
# PostCompact hook: persist the pre-compaction summary to disk
set -euo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace // .current_dir // empty')
trigger=$(printf '%s' "$input" | jq -r '.trigger // .source // "unknown"')

# PostCompact input carries a summary; field name varies, so try a few
summary=$(printf '%s' "$input" | jq -r '
  .summary // .compacted_summary // .compaction_summary
  // .output.summary // .output // .text // empty
' 2>/dev/null || true)

if [ -z "$summary" ] || [ "$summary" = "null" ]; then
  summary="(Couldn't extract summary from hook input — raw payload saved to .raw.json for debugging)"
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
  printf '\n# Context summary card (PostCompact auto)\n\n'
  printf '%s\n' "$summary"
} > "$filename"

# Echo back into the Claude Code UI via systemMessage
jq -n --arg file "$filename" --arg summary "$summary" \
     --arg ts "$ts_human" --arg proj "$project_label" \
  '{systemMessage: ("📝 [compact] summary card saved\n\n📄 file: \($file)\n🕐 time: \($ts)\n📁 project: \($proj)\n\n--- summary ---\n\n" + $summary)}'
```

**Notes**:
- Hook input comes on stdin as JSON — parse with `jq -r`, never `xargs` (paths with spaces break)
- Echo back via the `systemMessage` field, not stdout (stdout may be suppressed)
- Filename carries `source: compact` + session ID for later filtering

### 2. `/daily-summary` — manual cross-session rollup

A slash command is just a prompt template at `~/.claude/commands/<name>.md`. When invoked, Claude Code sends the template body to the current session's model.

**`commands/daily-summary.md`** (frontmatter + prompt; full file in repo):

```markdown
---
description: Roll up the last 24h of sessions across all projects into a daily card
argument-hint: [optional: focus note]
---

Summarize the last 24h of Claude Code sessions across all projects.

## Steps

### 1. Discover sessions
\`\`\`bash
find ~/.claude/projects -name "*.jsonl" -mtime -1 -type f -print0 | xargs -0 ls -lt
\`\`\`
Directory name (e.g. `-Users-foo-Work-bar`) reverse-maps to a project path: leading `-` → `/`, other `-` → `/`.

### 2. Extract per-session content (only messages from the last 24h)
\`\`\`bash
jq -r 'select(.type=="user" or .type=="assistant") | select(.timestamp != null) | select((.timestamp | gsub("\\.\\d+Z$"; "Z") | fromdateiso8601) > (now - 86400)) | .message.content | if type=="string" then . elif type=="array" then (.[] | if .type=="text" then .text elif .type=="tool_use" then "[tool: " + .name + "]" else empty end) else empty end' <file>
\`\`\`
Timestamp filter: each message has a `timestamp` (ISO 8601 with millis); gsub strips millis, fromdateiso8601 parses, compare against now - 86400.
A session spanning many days only contributes its last-24h slice.

### 3–5. Build structured summary → save as *-manual-daily.md → print
```

**Notes**:
- `$ARGUMENTS` is the slash-command argument placeholder — `/daily-summary focus on the hook part` substitutes it in
- This is a **cross-session** rollup, not the current session only — the current session is just one source
- **Only messages from the last 24h** — a session spanning 24 days only contributes what was said in the last 24h

### 3. Crontab — automated daily safety net

Slash commands need a human to fire them. Cron is the safety net: an unattended `claude -p` run that rolls up the day whether you remembered or not.

**`hooks/daily-summary-cron.sh`** (full file in repo; core logic):

```bash
#!/bin/bash
set -euo pipefail
# ⚠️ cron's PATH is bare — export one that includes claude and jq
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECTS_DIR="$HOME/.claude/projects"
SUMMARIES_DIR="$HOME/.claude/summaries"
mkdir -p "$SUMMARIES_DIR"

# find -mtime -1 just DISCOVERS files that might have recent messages (perf)
# while-read instead of mapfile — macOS system bash is 3.2
sessions=()
while IFS= read -r line; do sessions+=("$line"); done < <(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -1 2>/dev/null)

# Concatenate each session's text; on extract, filter again by message timestamp (correctness)
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

# Pipe to claude -p; on failure, still persist (with stderr) so the morning review isn't blank
{ printf '%s' "$prompt"; cat "$context_file"; } | claude -p --output-format=text > "$outfile.body" 2>"$outfile.err" || {
  # ... failure fallback
}
```

**Register**:

```bash
# default 18:00 — change to your liking
(crontab -l 2>/dev/null; echo "0 18 * * * /bin/bash $HOME/.claude/hooks/daily-summary-cron.sh >> $HOME/.claude/summaries/cron.log 2>&1") | crontab -
```

**Notes**:
- `claude -p` is headless — uses whatever model your settings.json configures
- cron's PATH is bare; you must export one or `claude` / `jq` won't be found
- On failure, still persist (with stderr) — otherwise a blank morning review is ambiguous (no activity vs. broken script)
- Time is tunable; pick whatever brackets your day

### 4. `/morning-review` — standup

The consumer side of the loop. Reads the stashed cards, re-distills them into yesterday's recap, and tees up today's plan with concrete questions.

**`commands/morning-review.md`** (core prompt):

```markdown
---
description: Recap the last day's summary cards and tee up today's plan
argument-hint: [optional: today's focus]
---

### 1. Load yesterday's cards
\`\`\`bash
find ~/.claude/summaries -name "*.md" -mtime -1.5 -type f | sort -r
\`\`\`
Read each. Frontmatter carries source (compact/manual/cron), project, timestamp, cwd.

### 2. Produce the recap
- 🌅 What got done (by project)
- Key decisions
- What's unfinished / blocked
- Carried-over risks

### 3. Tee up today
Ask 2-3 concrete, decision-shaped questions, e.g.:
- "X didn't finish yesterday — pick it back up or park it?"
- "Is the Y call landing today?"

### 4–5. Honor the focus note / fallback when there are no cards
```

**Notes**:
- Reads **summary cards** (already distilled once), not raw jsonl — saves a ton of tokens
- 36h window catches cards from late the previous evening
- Must end with questions, not just a recap — the goal is to start today's conversation

## Browsing history

```bash
ls -lt ~/.claude/summaries/*.md              # newest first
cat ~/.claude/summaries/<some-file>.md       # read a card
grep -l "some-project" ~/.claude/summaries/*.md   # by project
grep -l "source: cron" ~/.claude/summaries/*.md   # by source
```

## Gotchas (verified the hard way)

1. **`chmod +x` the hook scripts** — PostCompact silently no-ops otherwise
2. **settings.json needs a reload** after edits — open `/hooks` once or restart Claude Code; the settings watcher doesn't always hot-reload
3. **PostCompact doesn't fire in the session that changed the config** — open a new session or hit `/hooks` to reload
4. **cron's PATH** — cron only gets `/usr/bin:/bin`; `claude` and `jq` are usually elsewhere. Export PATH explicitly
5. **Hook input is on stdin** — don't try to read it from env vars or args
6. **`jq -r` for stdin parsing** — never `xargs` (spaces in paths break it)
7. **`claude -p` auth** — reads env from settings.json; if cron auth fails, check whether you need to manually export `ANTHROPIC_AUTH_TOKEN` etc.
8. **`systemMessage` for UI echo** — not stdout (stdout may be suppressed)
9. **cron script must persist on failure** — otherwise a blank morning review is ambiguous
10. **`$ARGUMENTS`** in slash commands — it's the placeholder for user arguments
11. **Timestamps carry millis** — `fromdateiso8601` only takes whole seconds; `gsub("\\.\\d+Z$"; "Z")` to strip them
12. **Multi-day sessions only contribute their last 24h** — `find -mtime -1` is for discovery (perf); on extract, filter again by message `timestamp` (correctness)
13. **No `mapfile`** — macOS system bash is 3.2 (2007); `mapfile` needs bash 4+. Use `while IFS= read -r line; do arr+=("$line"); done` instead
14. **`${var}` not `$var` before CJK chars** — bash 3.2's locale treats some CJK bytes as valid variable-name bytes, so `$ts_human）` (Chinese paren) parses as `${ts_human）}` → unbound. Always use `${ts_human}`

## Design choices

**PostCompact over PreCompact**: PreCompact fires before the summary exists — you'd burn a model call to make one. PostCompact's input already carries the summary, free.

**`claude -p` for cron, not a hook**: hooks are in-session events; cron is system-level. No active session exists when cron fires, so headless is the only option.

**`/daily-summary` and cron share scope**: cron is the safety net (in case you forget); the slash command is the on-demand trigger (when you want it now). Same scope, distinguished by `source` in the filename — morning review reads both.

**`/morning-review` reads cards, not raw jsonl**: cards are already distilled once — token-cheap and information-dense. Raw jsonl from a day of sessions can run hundreds of thousands of chars.

**Markdown + frontmatter over JSON**: humans read these directly; markdown is legible, frontmatter is still greppable/jq-able.

**Last-24h-of-messages, not last-24h-of-files**: a session can span many days. Summarizing the whole file would drag last week into today. `find -mtime -1` only discovers candidates (perf); the extract step filters by message `timestamp` again (correctness).

## License

MIT
