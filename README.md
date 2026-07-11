# DevHQ&trade;

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
It prompts for a command-line tool directory, defaulting to `$HOME/.local/bin`,
creates that directory if needed, installs `devhq` and `lpm` there, adds the
DevHQ package repository, and installs the language, LSP, and `devhq` packages.
On macOS, it attempts to install optional
[shpool](https://github.com/shell-pool/shpool) with Homebrew. On Linux, it
attempts to install `shpool` into the selected directory when Cargo is
available. A missing package manager, an untrusted Homebrew tap, or an
installation failure produces a warning and does not stop DevHQ installation.
On Linux, `lpm` still installs Lite XL.

Run the same command again to upgrade or refresh an existing DevHQ install.

To install from a fork or another repository:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq \
  sh ./install.sh
```

For a non-`main` GitHub branch, use the branch suffix accepted by `lpm`:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq.git:feature-branch \
  sh ./install.sh
```

For a local checkout:

```sh
DEVHQ_REPOSITORY_URL=/path/to/devhq sh ./install.sh
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

Install the language and LSP plugins:

```sh
./lpm install meta_languages lsp --assume-yes
```

Install `shpool` for better agent life-cycle management:

```sh
cargo install --git https://github.com/shell-pool/shpool --locked shpool
```

## Review Sidebar

The `devhq:toggle-review-sidebar` command opens a right-hand split that lists one
entry per comment thread in the active worktree. The sidebar appears
automatically when you leave a comment. Clicking an entry opens the commented
file and jumps to the range. When a comment was anchored to a specific commit
that is no longer `HEAD`, DevHQ opens that historical version of the file
(`git show <commit>:<path>`) instead of the working copy.

The sidebar and gutter markers reload automatically when the comment JSONL is
changed on disk (for example by the reply CLI below), so external replies show
up without switching worktrees.

## Review Reply CLI

Agents can reply to an existing DevHQ review comment from the command line:

```sh
./devhq review reply <comment-id> --message "Addressed in the latest changes."
```

The command only appends an `agent` reply to the existing comment. It does not
create comments or resolve them. On success it prints the new reply ID.

Posting comments to an agent includes each thread's id and these usage
instructions, so the agent can reply to the right thread.

Set `DEVHQ_USERDIR` or `LITE_USERDIR` when the script cannot infer the Lite XL
user directory from its own path.

### Build a macOS arm64 DMG

From a macOS arm64 machine:

```sh
./build_installer.sh --dry-run
./build_installer.sh
```

The script runs `install.sh` against a staged copy of the official Lite XL app,
then brands, signs, and repackages it as `dist/DevHQ-macos-arm64.dmg`. LPM
resolves DevHQ's declared web, terminal, widget, font, language, and LSP
dependencies directly into the app bundle. The Lite XL license remains in the
app and is also visible at the DMG root.

Useful overrides:

```sh
LITE_XL_DMG_URL=https://example.invalid/lite-xl.dmg ./build_installer.sh
LPM_PATH=/path/to/lpm ./build_installer.sh
LITE_XL_DMG_PATH=/path/to/lite-xl.dmg ./build_installer.sh --stage-only
```

By default the app is ad-hoc signed for local packaging. For a real Developer
ID signature, set `SIGN_IDENTITY="Developer ID Application: ..."` and
`CODESIGN_OPTIONS="--options runtime --timestamp"`.

GitHub Actions also builds this installer on a macOS arm64 runner. Pull request
and manual (`workflow_dispatch`) runs upload `DevHQ-macos-arm64.dmg` as the
`DevHQ-macos-arm64` workflow artifact for testers. Pushing a `v*` tag builds the
same DMG and publishes it to the matching GitHub Release with the `gh` CLI.

Pull-request and manual builds use ad-hoc signing. On trusted `v*` tags, the
workflow uses the configured Developer ID identity, signs nested native code and
the app with hardened runtime and a timestamp, signs and notarizes the DMG,
staples the ticket, and verifies the result before publishing it.

Required GitHub secrets for Developer ID signing and notarization:

- `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_SIGN_IDENTITY`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

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

## License

Copyright (c) 2026 Manuj Bhatia.

DevHQ is free software, licensed under the **GNU Affero General Public License
v3.0 (AGPL-3.0)**. See the [LICENSE](LICENSE) file for the full text.

Individuals and companies are free to use, modify, and self-host DevHQ. Because
AGPL-3.0 is a network copyleft license, if you modify DevHQ and make it
available to others over a network (for example, as a hosted service), you must
also make the complete corresponding source code of your modified version
available under the AGPL-3.0.

## Trademarks

"DevHQ" and the DevHQ name and logo are trademarks of Manuj Bhatia. The
AGPL-3.0 license covers the source code only and grants no rights to these
trademarks. Forks and derivative products must use a different name. See
[TRADEMARK.md](TRADEMARK.md).

## Contributing

By contributing to DevHQ, you agree to the terms of the
[Contributor License Agreement](CLA.md), which allows the Project to be offered
under both the AGPL-3.0 and, at the Owner's discretion, other license terms
(such as a commercial license). You retain copyright to your contributions.
