-- Local work files (notes, plans, test scripts, experiments) per worktree, kept out of the repo's git.
--
--   :WorkFiles          toggle the panel: this repo's work files as a folded tree, opened at the current worktree
--                       (the one nvim's cwd is in, not the file you're editing), whose folder and link
--                       are made if they don't exist yet
--   :WorkFiles!         same, for every repo under the root
--   :WorkGrep [query]   fzf search through this repo's work files (! for every repo)
--
-- Files live in <root>/<repo>/<worktree>/:
--   root      g:workfiles_root, else $WORK_FILES_ROOT, else ~/workfiles.
--   repo      folder name of the repo's main checkout (e.g. myapp)
--   worktree  folder name of the worktree (e.g. myapp-fix-login), 'main' in the main checkout
-- Outside git, every folder shares <root>/misc/ (no link: nothing to keep it out of).
-- Every checkout links to its folder, git-ignored: tmp/workfiles (with /tmp/workfiles in info/exclude unless git
-- already ignores it), so `tmp/workfiles/x.md` in any worktree is that worktree's work file. If tmp is a file or a
-- link to somewhere else, the link is tmp/workfiles in the checkout's git dir (.git/tmp/workfiles,
-- .git/worktrees/<name>/tmp/workfiles), which git never lists. A tmp that is itself a link to the folder (the older
-- layout) is used as it is, and so is a link to another folder under the root (e.g. one project folder shared by
-- several worktrees). The panel opens files through the link, so their buffers belong to the checkout (a file
-- tree or git-root lookup going by the buffer's path finds the repo, not the root's).
--
-- In the panel:
--   <CR>       open the file (closing the panel) / open or close a folder
--   go         open the file, stay in the panel
--   o / <Space>  open / close a folder
--   a / A      new file / new folder in the folder under the cursor (a file gets a <yyyymmdd>- prefix)
--   r / D      rename / delete (to the macOS Trash)
--   y          copy the path
--   p          up to the parent folder
--   R          refresh
--   q          close;  ? help

local M = {}

-- The work-files root, resolved; other plugins can use it to keep their files next to the work files.
function M.root()
    local r = vim.g.workfiles_root or vim.env.WORK_FILES_ROOT or '~/workfiles'
    -- resolved, so it matches buffer names through symlinks (e.g. /tmp -> /private/tmp)
    return (vim.fn.resolve(vim.fn.fnamemodify(vim.fn.expand(r), ':p')):gsub('/$', ''))
end
local root = M.root

local function inside(path, dir)
    return path == dir or vim.startswith(path, dir .. '/')
end

local function is_dir(path)
    local st = vim.uv.fs_stat(path)
    return st ~= nil and st.type == 'directory'
end

---------------------------------------------------------------------------
-- where we are
---------------------------------------------------------------------------

-- Git dir of a checkout: its .git folder, the one a worktree's .git file points to, else `common`
-- (a checkout with a separate git dir, e.g. ~/dot with --git-dir=~/.dot.git).
local function git_dir_of(top, common)
    local st = vim.uv.fs_stat(top .. '/.git')
    if st and st.type == 'directory' then return top .. '/.git' end
    if st then
        local d = (vim.fn.readfile(top .. '/.git', '', 1)[1] or ''):match('^gitdir: (.+)')
        if d then return vim.startswith(d, '/') and d or vim.fs.normalize(top .. '/' .. d) end
    end
    return common
end

-- { repo, name = worktree folder name, top = checkout root, gitdir, main,
--   worktrees = { name -> path }, gitdirs = { name -> git dir } }
local function where(path)
    local dir = is_dir(path) and path or vim.fn.fnamemodify(path, ':h')
    local git = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-toplevel', '--git-dir', '--git-common-dir' })
    if vim.v.shell_error ~= 0 or #git < 3 then
        return { repo = 'misc', top = dir, main = true, worktrees = {}, nogit = true }
    end
    local top = git[1]
    local abs = function(d)
        if not vim.startswith(d, '/') then d = vim.fs.joinpath(top, d) end
        return (vim.fn.fnamemodify(d, ':p'):gsub('/$', ''))
    end
    -- The main checkout is the one whose git dir is the common one. Its folder is the first worktree
    -- git lists, unless that's a bare or separate git dir (e.g. ~/dot with --git-dir=~/.dot.git),
    -- which has no checkout of its own: then it's the folder holding .git (or this checkout).
    local main = abs(git[2]) == abs(git[3])
    local listed = {}
    for _, l in ipairs(vim.fn.systemlist({ 'git', '-C', top, 'worktree', 'list', '--porcelain' })) do
        local wt = l:match('^worktree (.+)')
        if wt then listed[#listed + 1] = wt end
    end
    local main_top = top
    if not main then
        main_top = listed[1] ~= abs(git[3]) and listed[1] or vim.fn.fnamemodify(abs(git[3]), ':h')
    end
    local loc = { repo = vim.fn.fnamemodify(main_top, ':t'), top = top, gitdir = abs(git[2]), main = main, worktrees = {}, gitdirs = {} }
    loc.name = main and 'main' or vim.fn.fnamemodify(top, ':t')
    for _, wt in ipairs(listed) do
        if wt == main_top then
            loc.worktrees.main = wt
        elseif wt ~= abs(git[3]) then
            loc.worktrees[vim.fn.fnamemodify(wt, ':t')] = wt
        end
    end
    loc.worktrees.main = loc.worktrees.main or main_top
    for name, wt in pairs(loc.worktrees) do loc.gitdirs[name] = git_dir_of(wt, abs(git[3])) end
    return loc
end

-- Where a checkout's link to its folder can be, in order: tmp/workfiles, tmp itself (older layout), tmp/workfiles
-- in its git dir.
local function link_spots(top, gitdir)
    return { top .. '/tmp/workfiles', top .. '/tmp', gitdir and (gitdir .. '/tmp/workfiles') }
end

-- Folder a checkout links to, if it's under the root, and the link.
local function linked_dir(top, gitdir)
    for _, link in ipairs(link_spots(top, gitdir)) do
        if vim.uv.fs_readlink(link) then
            local target = vim.fn.resolve(link)
            if inside(target, root()) then return target, link end
        end
    end
end

-- The work-files folder of a location (it may not exist yet).
local function folder_of(loc)
    if loc.nogit then return root() .. '/misc' end
    return linked_dir(loc.top, loc.gitdir) or table.concat({ root(), loc.repo, loc.name }, '/')
end

-- Where you are: the cwd (the file you're editing may be anywhere, e.g. a work file of another repo).
-- A cwd inside the root counts as being in that work-files folder.
local function current()
    local path = vim.fn.resolve(vim.fn.getcwd())
    local r = root()
    if inside(path, r) then
        local repo, sub = path:sub(#r + 2):match('^([^/]+)/([^/]+)')
        if repo then
            return { repo = repo, dir = table.concat({ r, repo, sub }, '/'), loc = nil }
        end
    end
    local loc = where(path)
    return { repo = loc.repo, dir = folder_of(loc), loc = loc }
end

local function ignored(top, rel)
    vim.fn.system({ 'git', '-C', top, 'check-ignore', '-q', '--no-index', rel })
    return vim.v.shell_error == 0
end

-- Have git ignore `rel` (a path in the checkout): through the repo's info/exclude, unless .gitignore or the
-- exclude file already does. False if it still isn't ignored (e.g. a `!` rule in .gitignore).
local function ignore(top, rel)
    if ignored(top, rel) then return true end
    local exclude = vim.fn.system({ 'git', '-C', top, 'rev-parse', '--git-path', 'info/exclude' }):gsub('\n$', '')
    if not vim.startswith(exclude, '/') then exclude = top .. '/' .. exclude end
    local lines = vim.fn.filereadable(exclude) == 1 and vim.fn.readfile(exclude) or {}
    vim.fn.mkdir(vim.fn.fnamemodify(exclude, ':h'), 'p')
    lines[#lines + 1] = '/' .. rel
    vim.fn.writefile(lines, exclude)
    return ignored(top, rel)
end

-- Make the folder, and the checkout's link to it, git-ignored: tmp/workfiles, or the same in the git dir if tmp
-- is a file or a link to somewhere else (or the link there can't be ignored). Every checkout gets one.
local function ensure(cur)
    vim.fn.mkdir(cur.dir, 'p')
    local loc = cur.loc
    if not loc or loc.nogit then return end
    local _, link = linked_dir(loc.top, loc.gitdir)
    if link then
        -- a link in the checkout made by hand, or before git ignored it: make sure it's ignored
        if inside(link, loc.top .. '/tmp') then ignore(loc.top, link:sub(#loc.top + 2)) end
        return
    end
    local tmp = loc.top .. '/tmp'
    local st = vim.uv.fs_lstat(tmp)
    if (not st or st.type == 'directory') and not vim.uv.fs_lstat(tmp .. '/workfiles') then
        vim.fn.mkdir(tmp, 'p')
        if vim.uv.fs_symlink(cur.dir, tmp .. '/workfiles') then
            if ignore(loc.top, 'tmp/workfiles') then return end
            vim.uv.fs_unlink(tmp .. '/workfiles')
            if not st then vim.uv.fs_rmdir(tmp) end
        end
    end
    local alt = loc.gitdir .. '/tmp/workfiles'
    vim.fn.mkdir(loc.gitdir .. '/tmp', 'p')
    if vim.uv.fs_lstat(alt) or not vim.uv.fs_symlink(cur.dir, alt) then
        vim.notify('workfiles: no link to ' .. cur.dir .. ' could be made in ' .. loc.top, vim.log.levels.WARN)
    end
end

-- <yyyymmdd>-<name>, with .md if it has no extension.
local function dated(name)
    name = vim.trim(name):gsub('%s+', '-')
    if not name:match('%.[%w]+$') then name = name .. '.md' end
    if name:match('^%d%d%d%d%d%d%d%d%-') then return name end
    return os.date('%Y%m%d-') .. name
end

---------------------------------------------------------------------------
-- tree
---------------------------------------------------------------------------

local SKIP = { ['.git'] = true, ['.DS_Store'] = true, ['__pycache__'] = true, ['node_modules'] = true }

-- { path, name, dir, mtime, kids } of a folder, kids: folders first, then files, each newest first.
-- A folder's mtime is that of its newest file.
local function scan(path, depth)
    local node = { path = path, name = vim.fn.fnamemodify(path, ':t'), dir = true, kids = {}, mtime = 0 }
    if depth > 6 then return node end
    for name, type in vim.fs.dir(path) do
        if not SKIP[name] then
            local p = path .. '/' .. name
            if type == 'link' then type = is_dir(p) and 'directory' or 'file' end
            local kid
            if type == 'directory' then
                kid = scan(p, depth + 1)
            else
                local st = vim.uv.fs_stat(p)
                kid = { path = p, name = name, mtime = st and st.mtime.sec or 0 }
            end
            node.kids[#node.kids + 1] = kid
            node.mtime = math.max(node.mtime, kid.mtime)
        end
    end
    table.sort(node.kids, function(a, b)
        if (a.dir or false) ~= (b.dir or false) then return a.dir or false end
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.name < b.name
    end)
    return node
end

---------------------------------------------------------------------------
-- panel
---------------------------------------------------------------------------

local NS = vim.api.nvim_create_namespace('workfiles')
local pane = { win = nil, buf = nil, src_win = nil, items = {}, all = false, help = false }

local HELP = {
    'Work files',
    '',
    '  <CR>               open the file (closes the panel) / open or close a folder',
    '  go                 open the file, stay in the panel',
    '  o / <Space>        open / close a folder',
    '  a / A              new file / new folder in the folder under the cursor',
    '  r / D              rename / delete (to the Trash)',
    '  y                  copy the path',
    '  p                  up to the parent folder',
    '  R                  refresh',
    '  q                  close',
    '  ?                  show / hide this help',
    '',
    'Commands',
    '  :WorkFiles[!]      this repo\'s work files (! every repo)',
    '  :WorkGrep[!]       fzf search the files (! every repo)',
    '',
    'Where',
    '  <root>/<repo>/<worktree>/, root = g:workfiles_root,',
    '  else $WORK_FILES_ROOT, else ~/workfiles. A checkout\'s tmp/workfiles links there.',
}

local function set_highlights()
    for name, target in pairs({
        WorkFilesDir = 'Directory',
        WorkFilesFile = 'Normal',
        WorkFilesDate = 'Comment',
        WorkFilesNote = 'Comment',
        WorkFilesHere = 'DiagnosticWarn',
        WorkFilesTitle = 'Title',
        WorkFilesKey = 'Special',
        WorkFilesBar = 'StatusLine',
        WorkFilesFold = 'Normal',
    }) do
        vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
end

local function pane_open() return pane.win ~= nil and vim.api.nvim_win_is_valid(pane.win) end

-- Folds come from the rows' levels: folder rows start a fold, file rows sit in their folder's.
function _G.WorkFilesFold()
    local it = pane.items[vim.v.lnum]
    if not it or it.level == 0 then return '0' end
    return it.dir and ('>' .. it.level) or tostring(it.level - 1)
end

-- What a folder row says about the folder: the worktree it belongs to is gone, or which worktrees' tmp links to it.
local function note_of(path, repo_info)
    if not repo_info then return '' end
    local links = repo_info.links[path]
    if links and #links > 0 then
        local own = repo_info.worktrees[vim.fn.fnamemodify(path, ':t')]
        if not (#links == 1 and own) then return ('  (tmp of %d worktrees)'):format(#links) end
        return ''
    end
    if vim.fn.fnamemodify(path, ':h:h') == root() and not repo_info.worktrees[vim.fn.fnamemodify(path, ':t')] then
        return '  (no worktree)'
    end
    return ''
end

local function build(tree, repo_info)
    local lines, marks, items = {}, {}, {}
    local function add(segments, item)
        local text = ''
        for _, seg in ipairs(segments) do
            if seg[2] then marks[#marks + 1] = { #lines, #text, #text + #seg[1], seg[2] } end
            text = text .. seg[1]
        end
        lines[#lines + 1] = text
        items[#items + 1] = item
    end
    if pane.help then
        for _, l in ipairs(HELP) do
            local key = l:match('^  (%S.-)%s%s')
            if l ~= '' and not l:match('^%s') then
                add({ { '" ' .. l, 'WorkFilesTitle' } }, { level = 0 })
            elseif key then
                add({ { '"   ' }, { key, 'WorkFilesKey' }, { l:sub(#key + 3), 'Comment' } }, { level = 0 })
            else
                add({ { '"' .. l, 'Comment' } }, { level = 0 })
            end
        end
        add({ { '' } }, { level = 0 })
    end
    local function walk(n, depth)
        local pad = string.rep('  ', depth)
        if n.dir then
            local here = n.path == pane.here
            add({
                { pad }, { n.name .. '/', here and 'WorkFilesHere' or 'WorkFilesDir' },
                { note_of(n.path, repo_info), 'WorkFilesNote' },
                #n.kids == 0 and { '  (empty)', 'WorkFilesNote' } or { '' },
                here and { '  ← you are here', 'WorkFilesHere' } or { '' },
            }, { path = n.path, dir = true, level = depth + 1 })
            for _, k in ipairs(n.kids) do walk(k, depth + 1) end
        else
            add({
                { pad }, { os.date('%m-%d %H:%M', n.mtime), 'WorkFilesDate' }, { '  ' }, { n.name, 'WorkFilesFile' },
            }, { path = n.path, level = depth + 1 })
        end
    end
    walk(tree, 0)
    return lines, marks, items
end

local function line_of(path)
    for i, it in ipairs(pane.items) do
        if it.path == path then return i end
    end
end

-- Worktrees of the shown repo and what their tmp links to: { worktrees = { name -> path }, links = { dir -> names } }.
local function repo_info(loc)
    if not loc then return nil end
    local info = { worktrees = loc.worktrees, links = {} }
    for name, top in pairs(loc.worktrees) do
        local dir = linked_dir(top, loc.gitdirs[name])
        if dir then
            info.links[dir] = info.links[dir] or {}
            table.insert(info.links[dir], name)
        end
    end
    return info
end

-- (Re)draw. Keeps open folders and the cursor; `target` (a path) puts the cursor there and opens the
-- folders down to it. The first time only the folders down to the cursor are open.
local function render(target)
    local opened, cur = {}, nil
    vim.api.nvim_win_call(pane.win, function()
        for i, it in ipairs(pane.items) do
            if it.dir and vim.fn.foldclosed(i) == -1 then opened[it.path] = true end
        end
        local it = pane.items[vim.fn.line('.')]
        cur = it and it.path
    end)
    local top = pane.all and root() or (root() .. '/' .. pane.repo)
    local tree = is_dir(top) and scan(top, 0) or { path = top, name = vim.fn.fnamemodify(top, ':t'), dir = true, kids = {} }
    if pane.all then
        tree.kids = vim.tbl_filter(function(k) return k.dir end, tree.kids)
    end
    local lines, marks, items = build(tree, not pane.all and not (pane.loc and pane.loc.nogit) and repo_info(pane.loc) or nil)
    pane.items = items
    vim.bo[pane.buf].modifiable = true
    vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
    vim.bo[pane.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(pane.buf, NS, 0, -1)
    for _, m in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(pane.buf, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
    if target then cur = target end
    vim.api.nvim_win_call(pane.win, function()
        vim.cmd('normal! zXzR')
        -- bottom-up, so each :foldclose closes the fold starting on that row, not an enclosing one
        for i = #pane.items, 1, -1 do
            local it = pane.items[i]
            if it.dir and it.level > 1 and not opened[it.path] then vim.cmd(i .. 'foldclose') end
        end
        local l = cur and line_of(cur) or 1
        vim.api.nvim_win_set_cursor(0, { l, 0 })
        if target then vim.cmd('normal! zv') end
    end)
end

function M.refresh()
    if pane_open() then render() end
end

-- Window to open files in; made next to the first window if every other one is pinned.
local function target_window()
    if pane.src_win and vim.api.nvim_win_is_valid(pane.src_win) then return pane.src_win end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= pane.win and not vim.wo[w].winfixbuf and vim.api.nvim_win_get_config(w).relative == '' then
            pane.src_win = w
            return w
        end
    end
    vim.cmd('aboveleft new')
    pane.src_win = vim.api.nvim_get_current_win()
    return pane.src_win
end

function M.close()
    if pane_open() then
        if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(pane.win)) > 1 then
            vim.api.nvim_win_close(pane.win, true)
        else
            vim.api.nvim_win_call(pane.win, function() vim.cmd('enew') end)
        end
    end
    pane.win, pane.buf = nil, nil
end

-- A work file's path through the link of checkout `loc` (else of another worktree of its repo), so its buffer
-- belongs to that checkout rather than to the root's repo. Unchanged if no link leads to it.
local function via_link(path, loc)
    if not loc or loc.nogit then return path end
    local tops = { { loc.top, loc.gitdir } }
    for name, top in pairs(loc.worktrees) do tops[#tops + 1] = { top, loc.gitdirs[name] } end
    for _, t in ipairs(tops) do
        local dir, link = linked_dir(t[1], t[2])
        if dir and inside(path, dir) then return link .. path:sub(#dir + 1) end
    end
    return path
end

-- Buffer of a file, whichever path it was opened by.
local function buf_of(path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= '' and vim.fn.resolve(name) == path then return b end
    end
end

local function open_file(path, stay)
    local win = target_window()
    vim.api.nvim_win_call(win, function() vim.cmd('edit ' .. vim.fn.fnameescape(via_link(path, pane.loc))) end)
    if stay then return end
    M.close()
    vim.api.nvim_set_current_win(win)
end

local function item() return pane.items[vim.api.nvim_win_get_cursor(pane.win)[1]] end

-- Folder of the row under the cursor: the folder itself, or a file's folder.
local function folder_here()
    local it = item()
    if not it or it.level == 0 then return nil end
    return it.dir and it.path or vim.fn.fnamemodify(it.path, ':h')
end

local function new_file()
    local dir = folder_here()
    if not dir then return end
    vim.ui.input({ prompt = 'New file in ' .. vim.fn.fnamemodify(dir, ':~') .. '/ (<yyyymmdd>- added): ' }, function(name)
        if not name or vim.trim(name) == '' then return end
        vim.fn.mkdir(dir, 'p')
        local path = dir .. '/' .. dated(name)
        if vim.fn.filereadable(path) == 0 then vim.fn.writefile({}, path) end
        render(path)
        open_file(path)
    end)
end

local function new_folder()
    local dir = folder_here()
    if not dir then return end
    vim.ui.input({ prompt = 'New folder in ' .. vim.fn.fnamemodify(dir, ':~') .. '/: ' }, function(name)
        if not name or vim.trim(name) == '' then return end
        local path = dir .. '/' .. vim.trim(name)
        vim.fn.mkdir(path, 'p')
        render(path)
    end)
end

local function rename()
    local it = item()
    if not it or it.level <= 1 then return end
    vim.ui.input({ prompt = 'Rename to: ', default = vim.fn.fnamemodify(it.path, ':t') }, function(name)
        if not name or vim.trim(name) == '' then return end
        local to = vim.fn.fnamemodify(it.path, ':h') .. '/' .. vim.trim(name)
        if vim.uv.fs_stat(to) then return vim.notify('workfiles: ' .. to .. ' exists', vim.log.levels.WARN) end
        local ok, err = vim.uv.fs_rename(it.path, to)
        if not ok then return vim.notify('workfiles: ' .. err, vim.log.levels.ERROR) end
        local buf = buf_of(it.path)
        if buf then vim.api.nvim_buf_set_name(buf, via_link(to, pane.loc)) end
        render(to)
    end)
end

local function delete()
    local it = item()
    if not it or it.level <= 1 then return end
    local what = vim.fn.fnamemodify(it.path, ':~') .. (it.dir and '/ and everything in it' or '')
    if vim.fn.confirm('Move ' .. what .. ' to the Trash?', '&Yes\n&No', 2) ~= 1 then return end
    if vim.fn.executable('trash') == 0 then
        return vim.notify('workfiles: deleting needs a `trash` command on $PATH', vim.log.levels.ERROR)
    end
    local out = vim.fn.system({ 'trash', it.path })
    if vim.v.shell_error ~= 0 then return vim.notify('workfiles: ' .. out, vim.log.levels.ERROR) end
    render()
end

local function toggle_help()
    pane.help = not pane.help
    render()
    if pane.help then vim.api.nvim_win_set_cursor(pane.win, { 1, 0 }) end
end

-- Newest file in a folder (top-level files first, then any folder under it), else the folder itself.
local function newest(dir)
    if not is_dir(dir) then return dir end
    local node = scan(dir, 0)
    local best
    local function walk(n)
        for _, k in ipairs(n.kids) do
            if k.dir then walk(k) elseif not best or k.mtime > best.mtime then best = k end
        end
    end
    walk(node)
    return best and best.path or dir
end

function M.toggle(all)
    if pane_open() then return M.close() end
    local cur = current()
    pane.src_win = not vim.wo.winfixbuf and vim.api.nvim_get_current_win() or nil
    pane.all, pane.items, pane.help = all, {}, false
    pane.repo, pane.loc, pane.here = cur.repo, cur.loc, cur.dir
    if not pane.loc then pane.loc = where(vim.fn.getcwd()) end
    if pane.loc.repo ~= pane.repo then pane.loc = nil end
    ensure(cur)
    pane.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[pane.buf].bufhidden = 'wipe'
    vim.bo[pane.buf].filetype = 'workfiles'
    vim.cmd('botright 15split')
    pane.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(pane.win, pane.buf)
    for opt, val in pairs({
        number = false, relativenumber = false, signcolumn = 'no', wrap = false, cursorline = true,
        winfixheight = true, foldcolumn = '0', foldmethod = 'expr', foldlevel = 0, foldtext = '',
        foldexpr = 'v:lua.WorkFilesFold()', fillchars = 'fold: ,eob: ',
        winhighlight = 'Folded:WorkFilesFold,StatusLine:WorkFilesBar',
        statusline = ' %#WorkFilesTitle#Work files%#WorkFilesBar#  '
            .. vim.fn.fnamemodify(all and root() or (root() .. '/' .. pane.repo), ':~')
            .. '   %#WorkFilesKey#<CR>%#WorkFilesBar# open  %#WorkFilesKey#a%#WorkFilesBar# new'
            .. '  %#WorkFilesKey#q%#WorkFilesBar# close  %#WorkFilesKey#?%#WorkFilesBar# help',
    }) do
        vim.wo[pane.win][opt] = val
    end
    render(newest(pane.here))

    local o = { buffer = pane.buf, silent = true, nowait = true }
    vim.keymap.set('n', '<CR>', function()
        local it = item()
        if not it or it.level == 0 then return end
        if it.dir then vim.cmd('normal! za') else open_file(it.path) end
    end, o)
    vim.keymap.set('n', 'go', function()
        local it = item()
        if it and it.level > 0 and not it.dir then open_file(it.path, true) end
    end, o)
    for _, k in ipairs({ '<Space>', 'o' }) do vim.keymap.set('n', k, 'za', o) end
    vim.keymap.set('n', 'a', new_file, o)
    vim.keymap.set('n', 'A', new_folder, o)
    vim.keymap.set('n', 'r', rename, o)
    vim.keymap.set('n', 'D', delete, o)
    vim.keymap.set('n', 'R', function() render() end, o)
    vim.keymap.set('n', 'y', function()
        local it = item()
        if not it or it.level == 0 then return end
        vim.fn.setreg('+', it.path)
        vim.fn.setreg('"', it.path)
        vim.notify(vim.fn.fnamemodify(it.path, ':~'))
    end, o)
    vim.keymap.set('n', 'p', function()
        local l = vim.fn.line('.')
        local it = pane.items[l]
        if not it or it.level == 0 then return end
        local want = it.level - 1
        for i = l - 1, 1, -1 do
            local up = pane.items[i]
            if up.dir and up.level == want then return vim.api.nvim_win_set_cursor(0, { i, 0 }) end
        end
    end, o)
    vim.keymap.set('n', 'q', function() if pane.help then toggle_help() else M.close() end end, o)
    vim.keymap.set('n', '?', toggle_help, o)
end

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------

-- A work file's path through the link of the cwd's checkout (see via_link), e.g. for a file tree to show it
-- inside the repo; any other path unchanged.
function M.link_path(path)
    local real = vim.fn.resolve(path)
    if not inside(real, root()) then return path end
    local linked = via_link(real, where(vim.fn.getcwd()))
    return linked ~= real and linked or path
end

function M.grep(query, all)
    local dir = all and root() or (root() .. '/' .. current().repo)
    if not is_dir(dir) then return vim.notify('workfiles: no work files in ' .. dir, vim.log.levels.WARN) end
    if vim.fn.exists('*fzf#vim#grep') == 0 then
        return vim.notify('workfiles: :WorkGrep needs fzf.vim and ripgrep', vim.log.levels.ERROR)
    end
    vim.fn['fzf#vim#grep'](
        'rg --column --line-number --no-heading --color=always --smart-case -- ' .. vim.fn.shellescape(query or ''),
        vim.fn['fzf#vim#with_preview']({ dir = dir }), 0)
end

set_highlights()
local group = vim.api.nvim_create_augroup('workfiles', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })
vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(ev)
        if tonumber(ev.match) == pane.src_win then pane.src_win = nil end
        vim.schedule(function()
            if pane_open() and #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(pane.win)) == 1 then
                M.close()
            end
        end)
    end,
})
-- a file saved in the shown tree appears in the panel
vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
        if pane_open() and inside(vim.fn.resolve(vim.api.nvim_buf_get_name(ev.buf)), root()) then M.refresh() end
    end,
})

return M
