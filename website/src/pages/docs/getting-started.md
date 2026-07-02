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

On macOS the script downloads the official Lite XL DMG and installs the app into
`/Applications`. It also downloads the Lite XL Package Manager (`lpm`) to a
temporary directory, adds the DevHQ package repository, and installs the `devhq`
package. On Linux, `lpm` still installs Lite XL.

Run the same command again to upgrade or refresh an existing DevHQ install.

<!-- To install from a fork:

```sh
DEVHQ_REPOSITORY_URL=https://github.com/example/devhq sh ./install.sh
```
-->

## Manual install

On macOS, install [Lite XL](https://github.com/lite-xl/lite-xl/releases/latest)
from the official DMG.

Install `lpm`:

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
