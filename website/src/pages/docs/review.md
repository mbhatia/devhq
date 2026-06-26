---
layout: ../../layouts/Docs.astro
title: Review
description: Diffs, inline comments, and the agent reply loop.
---

# Review

DevHQ closes the feedback loop inside the editor. Read the diff, comment on the
code, and send it to the agent.

## Filter the tree

The treeview gains four git filters, backed by cached status refreshes:

| Filter | Shows |
| --- | --- |
| `Full` | The full file tree |
| `Uncomm` | Uncommitted changes |
| `Staged` | Staged changes |
| `HEAD` | HEAD vs upstream |

File rows include status codes and change counts where git can provide them.

## Read diffs

Changed lines are marked in the editor gutter as additions, modifications, or
deletions. Click a marker to open a scrollable diff hunk overlay. Toggle the
overlay with `devhq:toggle-git-diff-overlay`.

Single-click opens a file in an ephemeral preview tab. Editing or
double-clicking promotes it to a persistent tab.

## Comment

Select code and run `devhq:add-comment` to draft a comment. Save or cancel it,
reopen it from the gutter marker, reply to existing threads, and resolve open
ones with `devhq:resolve-comment`. Threads persist as JSONL under the Lite XL
user directory, which keeps agent replies scriptable.

## Send to the agent

Run `devhq:post-all-comments` to bundle draft comments into a review blob and
send it to the active agent terminal for the worktree. The agent acts on the
review.
No round trip to GitHub or GitLab — the loop stays local and tight.
