---
layout: ../../layouts/Docs.astro
title: Worktrees
description: Track parallel work with local and remote git worktrees.
---

# Worktrees

A worktree is one open task. DevHQ lists the worktrees git knows about under each
repository and lets you switch between them without losing your place.

## Local worktrees

Create a worktree from the sidebar with `devhq:create-worktree`. New worktrees
default to a configurable worktree root. Remove one through the worktree context
menu with `devhq:delete-worktree`.

Selecting a worktree changes the active Lite XL project folder. The file tree
and open tabs follow the selected task.

A lightweight watcher checks git common-dir metadata and refreshes the sidebar
when worktrees are added, removed, or changed outside DevHQ.

## Remote worktrees

Add a remote repository with `devhq:open-remote-repo`, entering the remote as:

```text
server:/path/to/repo
```

DevHQ connects over SSH, reads remote worktree metadata, and creates a shallow
local mirror. The mirror lets Lite XL browse files and render diffs locally,
while terminal commands SSH into the real remote worktree path.

Refresh every configured remote with `devhq:sync-remote-repos`.

> Remote mirrors represent commits and worktree branch checkouts. Remote
> uncommitted and staged files are not mirrored.

## Grouping

Local and remote repositories with the same basename share one top-level group.
Remote worktrees stay clearly labeled with their server, so local and remote
work read as one project without losing their origin.

## State

DevHQ persists the repository list, worktree data, expanded rows, and the
selected worktree under the Lite XL user directory. On startup it refreshes
known worktrees, rebuilds the sidebar, and reopens the last selected worktree
when it still exists.
