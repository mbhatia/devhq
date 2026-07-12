---
layout: ../../layouts/Docs.astro
title: Installation
description: Install DevHQ on macOS or Linux.
---

# Installation

DevHQ is built on [Lite XL](https://lite-xl.com/). Choose the installer for your
platform.

## macOS

[Download DevHQ for macOS](https://github.com/mbhatia/devhq/releases/latest/download/DevHQ-macos-arm64.dmg)

Open the DMG and drag `DevHQ.app` to Applications. The app includes Lite XL,
DevHQ, the required plugins, and the `devhq`, `lpm`, and `shpool` command-line
tools used by its agent terminals.

The current macOS installer supports Apple silicon (`arm64`). It is signed and
notarized for normal installation outside the Mac App Store.

## Linux

Run the script installer:

```sh
curl -fsSL https://raw.githubusercontent.com/mbhatia/devhq/main/install.sh | sh
```

The installer supports Linux on `x86_64` and `aarch64`. It prompts for a
command-line tool directory, defaulting to `$HOME/.local/bin`, installs `devhq`
and `lpm`, and uses LPM to install Lite XL, DevHQ, language support, and LSP
support. When Cargo is available, it also attempts to install optional
[shpool](https://github.com/shell-pool/shpool). A missing Cargo installation or
shpool build failure produces a warning and does not stop DevHQ installation.

Run the same command again to upgrade or refresh an existing DevHQ install.

<!-- To install from a fork:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq sh ./install.sh
```

For a non-`main` GitHub branch:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq.git:feature-branch sh ./install.sh
```

For a local checkout:

```sh
DEVHQ_REPOSITORY_URL=/path/to/devhq sh ./install.sh
```
-->

## Manual Linux installation

Install `lpm`:

```sh
wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.`uname -m | sed 's/arm64/aarch64/'`-`uname | tr '[:upper:]' '[:lower:]'` -O lpm && chmod +x lpm
```

Install Lite XL and DevHQ:

```sh
./lpm install lite-xl --assume-yes
./lpm repo add https://github.com/mbhatia/devhq
./lpm repo update https://github.com/mbhatia/devhq
./lpm install meta_languages lsp --assume-yes
./lpm install devhq --assume-yes
```

Install `shpool` so agent sessions survive editor restarts:

```sh
cargo install --git https://github.com/shell-pool/shpool --locked shpool
```

## First run

1. Open Lite XL. The DevHQ sidebar appears to the left of the file tree.
2. Run `devhq:open-repo` from the command palette (`Cmd+Shift+P`) and pick a git
   repository.
3. Expand the repository. Select a worktree. The editor switches to it.
4. Run `devhq:create-agent` to launch an agent in a terminal scoped to that
   worktree.
5. As the agent makes changes, you can filter, browse and even edit the changes in
   the editor view.

> Next, read [Concepts](./concepts) to understand the model DevHQ is built
> on.
