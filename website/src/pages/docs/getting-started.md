---
layout: ../../layouts/Docs.astro
title: Getting started
description: Install DevHQ and open your first worktree.
---

# Getting started

DevHQ is built as a set of plugins for [Lite XL](https://lite-xl.com/). The installer sets up the
editor and the plugin together. macOS and Linux, `x86_64` and `aarch64`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mbhatia/devhq/main/install.sh | sh
```

The script downloads the Lite XL Package Manager (`lpm`) to a temporary
directory, installs Lite XL, adds the DevHQ package repository, and installs the
`devhq` package.

<!-- To install from a fork:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq sh ./install.sh
```
-->

## Manual install

Install `lpm`:

```sh
wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.`uname -m | sed 's/arm64/aarch64/'`-`uname | tr '[:upper:]' '[:lower:]'` -O lpm && chmod +x lpm
```

Install Lite XL and DevHQ:

```sh
./lpm install lite-xl
./lpm repo add https://github.com/mbhatia/devhq
./lpm install devhq
```

Optional — install `shpool` so agent sessions survive editor restarts:

```sh
brew tap shell-pool/shpool
brew install shpool
```

## First run

1. Open Lite XL. The DevHQ sidebar appears to the left of the file tree.
2. Run `devhq:open-repo` from the command palette (`Cmd+Shift+P`) and pick a git
   repository.
3. Expand the repository. Select a worktree. The editor switches to it.
4. Run `devhq:create-agent` to launch an agent in a terminal scoped to that
   worktree.
5. As the agent makes changes, you can filer, browse and even edit the changes in
   the editor view.

> Next, read [Concepts](./concepts) to understand the model DevHQ is built
> on.
