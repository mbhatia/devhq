---
layout: ../../layouts/Docs.astro
title: Commands
description: Every DevHQ command and the review reply CLI.
---

# Commands

Run commands from the Lite XL command palette (`Cmd+Shift+P`).

## Repositories

| Command | Behavior |
| --- | --- |
| `devhq:toggle-sidebar` | Show or hide the DevHQ sidebar |
| `devhq:open-repo` | Add one git repository |
| `devhq:open-remote-repo` | Add a remote repo as `server:/path/to/repo` |
| `devhq:scan-all-repos` | Walk a directory and add every repo found |
| `devhq:sync-remote-repos` | Refresh every configured remote mirror |

## Worktrees

| Command | Behavior |
| --- | --- |
| `devhq:create-worktree` | Create a local worktree |
| `devhq:delete-worktree` | Delete a local worktree |

Remote repositories do not support local worktree creation or deletion.

## Agents

| Command | Behavior |
| --- | --- |
| `devhq:create-agent` | Create a named agent from a profile and launch it |

## Git review UI

| Command | Behavior |
| --- | --- |
| `treeview-filter:full` | Show the full tree |
| `treeview-filter:uncommitted` | Show uncommitted changes |
| `treeview-filter:staged` | Show staged changes |
| `treeview-filter:head` | Show HEAD vs upstream |
| `devhq:toggle-git-diff-overlay` | Toggle the diff hunk overlay |

## Review comments

| Command | Behavior |
| --- | --- |
| `devhq:add-comment` | Draft an inline comment on selected code |
| `devhq:resolve-comment` | Resolve an open thread |
| `devhq:post-all-comments` | Send draft comments to the active agent |

Overlay-local commands save, cancel, backspace, and resolve comment input.

<!-- ## Review CLI

Agents reply to an existing comment thread from the command line:

```sh
./devhq review reply <comment-id> --message "Addressed in the latest changes."
```

The command only appends an `agent` reply to an existing comment. It does not
create comments or resolve them. On success it prints the new reply ID.

Set `DEVHQ_USERDIR` or `LITE_USERDIR` when the script cannot infer the Lite XL
user directory from its own path.
-->
