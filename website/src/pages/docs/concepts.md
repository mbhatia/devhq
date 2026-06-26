---
layout: ../../layouts/Docs.astro
title: Concepts
description: The model DevHQ is built on — repositories, worktrees, agents, and review.
---

# Concepts

DevHQ adds one layer above the editor. Four ideas hold it together.

## Repository

A git repository you have added to DevHQ. Add one with `devhq:open-repo`, scan a
directory for many with `devhq:scan-all-repos`, or add a remote with
`devhq:open-remote-repo`. Repositories group the local and remote worktrees
beneath them.

## Worktree

A git worktree is a checked-out branch with its own directory. DevHQ treats
worktrees as the unit of work: each open task is a worktree. Selecting a
worktree row changes the active project, so the file tree and editor
focus on that task.

Local and remote repositories sharing a basename collapse into one group.
Remote worktrees are labeled with their server.

## Agent

A named process launched from a profile into a terminal scoped to a worktree.
When an agent rings its bell or emits a notification, DevHQ marks it as needing
input. Agents are remembered till they are closed, even after a system restart.

## Review

A local code-review loop. Filter the file tree by git state, read diffs in the
editor, and attach inline comments to code. Comments can be sent directly to the
agent working the branch.

## What DevHQ does not do

DevHQ does not try to be your AI agent. You can bring your own agent TUI, codex,
claude, Pi, Hermes, cursor, or anything else you like. If it can run in a terminal,
DevHQ can manage it.
