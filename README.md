# nvim-workfiles

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-blue.svg)](https://neovim.io/)

A home for the files you make while working on a repo but never commit: notes, plans, test scripts,
query snippets, review checklists, experiment output. Each git worktree gets its own folder **outside** the
repo, sorted by repo and worktree, so the files outlive the worktree and never show up in `git status`.

```
~/workfiles/                     <root>
├── myapp/                       <repo>   (folder name of the main checkout)
│   ├── main/                    <worktree> for the main checkout
│   │   └── 20261002-release-checklist.md
│   ├── myapp-fix-login/         <worktree> for ~/code/myapp-fix-login
│   │   ├── 20261014-plan.md
│   │   └── 20261015-repro.sh
│   └── myapp-new-billing/
└── otherrepo/
```

## Why

- **Worktrees are temporary, notes aren't.** Delete a worktree when the branch merges and its notes stay,
  next to the notes from every other branch of the same repo.
- **Nothing to gitignore or forget.** The files live outside the repo, so they never get committed by
  mistake or lost to `git clean`.
- **Still one keystroke away inside the repo.** Each checkout gets a `tmp/` symlink to its folder
  (git-excluded through `info/exclude`, not `.gitignore`), so `tmp/plan.md` works from the shell, from
  scripts and from AI coding agents too. If `tmp/` is already taken, the link is `.git/tmp_workfiles`
  (`.git/worktrees/<name>/tmp_workfiles` for a linked worktree) instead.
- **Files stay in their project.** The panel opens files through that link, so a file tree or anything
  that looks for the git root from the buffer's path finds your repo, not the root's.
- **Sorted by recency.** Files get a `<yyyymmdd>-` prefix, and the panel lists newest first.

## Use cases

**Browse everything you wrote for this repo.** `:WorkFiles` opens a panel at the bottom with the repo's
work files as a folded tree, open at the current worktree's folder with the cursor on the newest file.
In a new worktree it makes that folder (and its `tmp/` link) first, so it's always there to write in.
Folders of worktrees that have since been deleted are marked `(no worktree)`, so old notes are easy to
find again or clean up. `:WorkFiles!` shows every repo under the root.

**Find that snippet from last month.** `:WorkGrep migration` searches the repo's work files with fzf and
ripgrep, with preview. `:WorkGrep!` searches every repo.

**Take notes for the branch you're on.** In the panel, `a` on your worktree's folder asks for a name and
creates `<root>/<repo>/<worktree>/20261019-plan.md`. A name without an extension gets `.md`.

**Give scripts and agents a place to write.** Anything that writes to `tmp/` (a test run's output, a
script, an agent's plan) lands in the work-files folder.

**Share one folder across several worktrees.** If a worktree's `tmp/` already points to some other folder
under the root (say a `myapp/billing-project/` used by three worktrees), that folder is used as the
worktree's folder, and the panel marks it `(tmp of 3 worktrees)`.

**Keep the work files in their own repo.** Point the root at a private git repo (or a synced drive)
to back up and version your notes separately from the code.

## Requirements

- Neovim 0.10+
- git (outside a repo, the cwd's folder name is used as the repo and `main` as the worktree)
- Optional: [fzf.vim](https://github.com/junegunn/fzf.vim) and [ripgrep](https://github.com/BurntSushi/ripgrep) for `:WorkGrep`
- Optional: a `trash` command (built into macOS 15+, or `trash-cli`) for deleting from the panel

## Installation

[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'solomonxie/nvim-workfiles'
```

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'solomonxie/nvim-workfiles' }
```

No `setup()` call is needed; the commands are defined on startup and the code loads the first time you
use one.

## Configuration

Set the root (default `~/workfiles`) in your config, or with `$WORK_FILES_ROOT`:

```vim
let g:workfiles_root = '~/notes/work'
```

```lua
vim.g.workfiles_root = '~/notes/work'
```

It's read every time, so it can be set anywhere, even after the plugin loads.

Suggested mappings:

```vim
nnoremap <Leader>w :WorkFiles<CR>
```

## Commands

| Command | What it does |
|---|---|
| `:WorkFiles` | Toggle the panel with this repo's work files, opened at the current worktree (whose folder and `tmp/` link it makes if needed) |
| `:WorkFiles!` | Same, for every repo under the root |
| `:WorkGrep[!] [query]` | fzf search this repo's work files (`!` every repo) |

"Current worktree" means the one Neovim's cwd is in, not the file you're editing (which may be a work
file of another repo). A cwd inside the root counts as being in that work-files folder.

## Panel keys

| Key | Action |
|---|---|
| `<CR>` | Open the file (closes the panel) / open or close a folder |
| `go` | Open the file, stay in the panel |
| `o` / `<Space>` | Open / close a folder |
| `a` / `A` | New file / new folder in the folder under the cursor (files get the date prefix) |
| `r` / `D` | Rename / delete (to the Trash) |
| `y` | Copy the path |
| `p` | Up to the parent folder |
| `R` | Refresh |
| `q` | Close |
| `?` | Show / hide help |

## How the folders are named

- **repo**: folder name of the repo's main checkout, so every worktree of a repo files under the same name.
  Repos with a bare or separate git dir (`git --git-dir=~/.dotfiles.git`) use the folder that holds it.
- **worktree**: folder name of the linked worktree, or `main` for the main checkout.
- If a checkout already has a `tmp/` that isn't a link to its folder, it's left alone and the link goes in
  its git dir as `tmp_workfiles`.

## Lua API

```lua
local wf = require('workfiles')
wf.root()          -- resolved root path, e.g. to keep another plugin's files next to the work files
wf.toggle(all)     -- :WorkFiles / :WorkFiles!
wf.grep(q, all)    -- :WorkGrep
```

## Highlights

All link to standard groups by default: `WorkFilesDir`, `WorkFilesFile`, `WorkFilesDate`, `WorkFilesNote`,
`WorkFilesHere`, `WorkFilesTitle`, `WorkFilesKey`, `WorkFilesBar`, `WorkFilesFold`.

## License

MIT
