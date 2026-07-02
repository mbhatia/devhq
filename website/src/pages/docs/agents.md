---
layout: ../../layouts/Docs.astro
title: Agents
description: Launch, supervise, and resume coding agents in context.
---

# Agents

An agent is a process launched from a profile into a terminal scoped to a
worktree. DevHQ keeps the agent list per worktree and tells you which one needs
attention.

## Create an agent

Run `devhq:create-agent`. Name the agent and pick a profile. DevHQ launches it in
a Ghostty-backed terminal tab with repository-aware environment variables,
opened in the active worktree. For remote mirrors, the terminal SSHes to the
host and enters the real remote worktree path before launching the process.

## Profiles

A profile defines the command an agent runs. While this would typically be your agent cli,
it could be any long-running process you want.

`$REPO` resolves to the parent repo, `$PWD` is the active worktree directory.
DevHQ also sets `$REPO_ID`, `$AGENT_ID`, and `$THREAD_ID` when known.

Default ships with a `codex` profile, you can easily add more profiles in Lite XL
settings.

```lua
local claude = "/Users/manujbhatia/.local/bin/claude"
config.plugins.devhq.agents["claude"] = {
  start = claude .. " --add-dir $REPO",
  resume = claude .. " --add-dir $REPO --resume",
  resume_thread = claude .. " --resume $THREAD_ID",
  thread = {
    input = "/status\n",
    pattern = "Session ID:%s*([%w%-]+)",
  },
}
```

`thread.input` is sent once after a newly opened agent terminal starts, and
`thread.pattern` is matched against the visible terminal output. The first match
is stored on the active agent entry as `thread_id` and persisted in DevHQ state.
On the next editor restart, DevHQ uses `resume_thread` instead of `resume` when
that stored id exists. The input can include `$AGENT_ID`, `$AGENT_NAME`, and
`$THREAD_ID`, so profiles can also issue commands like `/rename $AGENT_ID`.

## Attention state

When an agent emits a terminal notification or bell, DevHQ marks it as needing
input in the sidebar. The marker clears when you focus or type into that agent's
terminal. The signal is meant to be glanced at across many concurrent agents.

## Session lifecycle

Pair DevHQ with a session manager such as [shpool](https://github.com/shell-pool/shpool)
or [atch](https://github.com/mobydeck/atch) so agent sessions reattach across
restarts of Lite XL.
