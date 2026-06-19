# DevHQ

**This is an early preview release. Consider this a prototype/Alpha release.**

A unified developer control plane for developers managing parallel coding work
across local repositories, remote worktrees, AI agents, terminals, diffs, and review comments.

<!-- Enter DevHQ, a Development Supervisor built for developers. DevHQ provides a -->
<!-- single pane of glass, a unified environment for developers to track and manage -->
<!-- multiple workstreams through the software development lifecycle. -->

When a developer manages a team of agents, the classic IDEs geared for
managing 1 task/project at a time do not scale. Just like a manager uses Jira/Linear
to track the progress of a team, we need a unified tool for developers to keep
track of all their active tasks and interact with agents working on them.
Agents are just a stepping stone to get the work done. We need to focus on tracking
work and not agents.

DevHQ aims to be a single pane of glass for developers. The goal is to allow
developers to run the full SDLC, from work intake to production deploy through a single UI.

<!-- Charles is an AI agent supervisor and coding management platform for developers. -->
<!-- It provides a helpful interface to organize, streamline, and oversee the coding -->
<!-- efforts of multiple AI agents working on one or many projects. -->
<!-- It enables you to streamline the definition of agents and guardrails for a project, -->
<!-- have organized communications with agents, and complete effective code reviews. -->
<!-- All while overseeing the agent’s coding efforts. Then you can share the resulting -->
<!-- code with your integrated code management platform. -->

## Core Philosohpy

There are 3 main pillars of why we built DevHQ:
1. Code still matters.

  We believe that while AI is abstracting code behind natural language,
  code still matters and developers need to understand the code that the agent is
  writing in context of the broader project.
  This means we need IDE-like features, like code navigation, but don't need the
  full overhead of an IDE context switching. We should be able to switch between project
  contexts with lightning speed.

2. Development work is not linear

  Developers need to quickly jump between agents or sometimes pick up an
  idea after a few weeks without losing their place.
  We need a way to visually see all "open" work. Git worktrees are the backbone for tracking
  the lifecycle of development work.

3. Chat is a bad interface for providing feedback to your agents.

  While prompting is useful for steering an agent in-flight, it is not suitable
  for providing structural feedback on an Agent's output. We can push every change to
  the central code review platform (github, gitlab etc.), but that elongates the
  feedback loop.
  We need tigther feedback loops to work with these agents that can provide local
  code-review capability

## Installation

<!-- Note: Even though DevHQ is compatible with all platforms, `lite-xl-ghostty` only supports Mac/Linux right now. -->

DevHQ is implemented as a custom plugin to [Lite XL](https://lite-xl.com/),
making it highly customizable to match your personal preferences.

It bundles a ghostty based terminal [lite-xl-ghostty](https://github.com/mbhatia/lite-xl-ghostty)
to run agents. It can be paired with terminal sessions managers like
[shpool](https://github.com/shell-pool/shpool), [atch](https://github.com/mobydeck/atch)
to provide simple reattachment across restarts of lite-xl.

Install DevHQ, Lite XL, and the required Lite XL packages with:

```sh
curl -fsSL https://raw.githubusercontent.com/mbhatia/devhq/main/install.sh | sh
```

The installer supports macOS and Linux on `x86_64` and `aarch64`. On macOS it
downloads the official Lite XL DMG and installs the app into `/Applications`.
It also downloads the Lite XL Package Manager (`lpm`) to a temporary directory,
adds the DevHQ package repository, and installs the `devhq` package. On Linux,
`lpm` still installs Lite XL.

Run the same command again to upgrade or refresh an existing DevHQ install.

To install from a fork or another repository:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq \
  sh ./install.sh
```

### Manual Install

On macOS, install [Lite XL](https://github.com/lite-xl/lite-xl/releases/latest)
from the official DMG.

Install [Lite XL Package Manager](https://github.com/lite-xl/lite-xl-plugin-manager#linux--mac) (`lpm`):

```sh
wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.`uname -m | sed 's/arm64/aarch64/'`-`uname | tr '[:upper:]' '[:lower:]'` -O lpm && chmod +x lpm
```

Install Lite XL and DevHQ:

```sh
./lpm repo add https://github.com/mbhatia/devhq
./lpm repo update https://github.com/mbhatia/devhq
./lpm install devhq --assume-yes
./lpm reinstall devhq --assume-yes
```

On Linux, install Lite XL with `./lpm install lite-xl` before installing DevHQ.

Optional: install `shpool` for better agent life-cycle management:

```sh
brew tap shell-pool/shpool
brew install shpool
```

## Review Reply CLI

Agents can reply to an existing DevHQ review comment from the command line:

```sh
./devhq review reply <comment-id> --message "Addressed in the latest changes."
```

The command only appends an `agent` reply to the existing comment. It does not
create comments or resolve them. On success it prints the new reply ID.

Set `DEVHQ_USERDIR` or `LITE_USERDIR` when the script cannot infer the Lite XL
user directory from its own path.

<!-- ## Configuration -->

<!-- ### Commands -->
<!-- Out of the box, DevHQ will give you the following commands that you can run using the command palette (`Cmd+Shift+P`): -->

<!-- - `devhq:toggle-sidebar` -->
<!-- - `devhq:open-repo` -->
<!-- - `devhq:open-remote-repo` -->
<!-- - `devhq:scan-all-repos` -->
<!-- - `devhq:sync-remote-repos` -->

<!-- `open-repo` adds one git repository. -->

<!-- `open-remote-repo` adds one remote git repository. Enter the remote as: -->

<!-- ```text -->
<!-- server:/path/to/repo -->
<!-- ``` -->

<!-- DevHQ connects with `ssh`, reads remote worktree metadata with `/bin/sh`, and -->
<!-- creates a shallow local mirror under `USERDIR/devhq-remote-repos`. Remote -->
<!-- worktree rows open the local mirrored worktree paths so Lite XL can render files -->
<!-- and diffs locally. -->

<!-- Remote uncommitted and staged files are not mirrored. The mirror represents -->
<!-- commits and worktree branch checkouts only. -->

<!-- `scan-all-repos` walks a directory and adds every git repository it finds. -->

<!-- `sync-remote-repos` refreshes every configured remote repository mirror. -->

<!-- Top-level repository rows only expand or collapse. Worktree rows change the -->
<!-- active Lite XL project folder. -->



<!--
## Architecture

DevHQ is a Lite XL plugin that adds a small repository sidebar to the left of
the core treeview.

The sidebar lists git repositories. Each repository expands to the worktrees
known to git for that repository. Selecting a worktree changes the active Lite
XL project folder, so the normal core treeview becomes the file browser for
that worktree.

## Information Architecture

`plugins/devhq/init.lua`

Plugin entry point. It owns the sidebar lifecycle, commands, persisted state,
tree model, and project switching.

It does four things on load:

1. Loads `USERDIR/devhq.lua`.
2. Refreshes worktrees for persisted repositories.
3. Ensures the DevHQ sidebar exists to the left of the core treeview.
4. Restores the selected worktree as the active project when possible.

`plugins/devhq/git.lua`

Small git boundary. It shells out to `git` and exposes:

- `is_repo(path)`
- `scan_repos(path, found)`
- `worktrees(path)`
- `sync_remote_repo(repo)`

`manifest.json`

LPM package manifest. The `devhq` plugin depends on `generic_treeview`.
`generic_treeview` is vendored in this repo under `libraries/`.

`USERDIR/devhq.lua`

Runtime state file written by the plugin. It stores:

- Added repositories.
- Worktree data.
- Expanded/collapsed repository state.
- Selected worktree path.

## Review Reply CLI

Agents can reply to an existing review comment from the command line:

```sh
./devhq review reply <comment-id> --message "Addressed in the latest changes."
```

The command only appends an `agent` reply to the existing comment. It does not
create comments or resolve them. On success it prints the new reply ID.

Set `DEVHQ_USERDIR` or `LITE_USERDIR` when the script cannot infer the Lite XL
user directory from its own path.

## Install With LPM

From this repo:

```sh
lpm --repository="$PWD" plugin install devhq
```

From another directory:

```sh
lpm --repository=/path/to/devhq plugin install devhq
```

LPM installs `generic_treeview` from the vendored library declared in
`manifest.json`.

## Run For Development

Use this repo as the Lite XL user directory:

```sh
LITE_USERDIR="$PWD" "/Applications/Lite XL.app/Contents/MacOS/lite-xl"
```

The vendored treeview library is loaded from `libraries/generic_treeview.lua`.
The plugin itself is loaded from `plugins/devhq`.

The development state file will be written to:

```text
./devhq.lua
```
-->
