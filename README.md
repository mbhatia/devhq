# Sivraj

Sivraj is a Lite XL plugin that adds a small repository sidebar to the left of
the core treeview.

The sidebar lists git repositories. Each repository expands to the worktrees
known to git for that repository. Selecting a worktree changes the active Lite
XL project folder, so the normal core treeview becomes the file browser for
that worktree.

## Information Architecture

`plugins/sivraj/init.lua`

Plugin entry point. It owns the sidebar lifecycle, commands, persisted state,
tree model, and project switching.

It does four things on load:

1. Loads `USERDIR/sivraj.lua`.
2. Refreshes worktrees for persisted repositories.
3. Ensures the Sivraj sidebar exists to the left of the core treeview.
4. Restores the selected worktree as the active project when possible.

`plugins/sivraj/git.lua`

Small git boundary. It shells out to `git` and exposes:

- `is_repo(path)`
- `scan_repos(path, found)`
- `worktrees(path)`

`manifest.json`

LPM package manifest. The `sivraj` plugin depends on `generic_treeview`.
`generic_treeview` is vendored in this repo under `libraries/`.

`USERDIR/sivraj.lua`

Runtime state file written by the plugin. It stores:

- Added repositories.
- Worktree data.
- Expanded/collapsed repository state.
- Selected worktree path.

## Commands

- `sivraj:toggle-sidebar`
- `sivraj:open-repo`
- `sivraj:scan-all-repos`

`open-repo` adds one git repository.

`scan-all-repos` walks a directory and adds every git repository it finds.

Top-level repository rows only expand or collapse. Worktree rows change the
active Lite XL project folder.

## Install With LPM

From this repo:

```sh
lpm --repository="$PWD" plugin install sivraj
```

From another directory:

```sh
lpm --repository=/path/to/sivraj plugin install sivraj
```

LPM installs `generic_treeview` from the vendored library declared in
`manifest.json`.

## Run For Development

Use this repo as the Lite XL user directory:

```sh
LITE_USERDIR="$PWD" "/Applications/Lite XL.app/Contents/MacOS/lite-xl"
```

The vendored treeview library is loaded from `libraries/generic_treeview.lua`.
The plugin itself is loaded from `plugins/sivraj`.

The development state file will be written to:

```text
./sivraj.lua
```

## Notes

This plugin does not replace Lite XL's core treeview. It selects a repository
or worktree, then lets the core treeview browse that selected project folder.

Git worktree information is read with:

```sh
git -C <repo> worktree list --porcelain
```
