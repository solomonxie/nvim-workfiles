-- Commands only; lua/workfiles is loaded the first time one runs.
if vim.g.loaded_workfiles then return end
vim.g.loaded_workfiles = true

local function wf() return require('workfiles') end

vim.api.nvim_create_user_command('WorkFiles', function(o) wf().toggle(o.bang) end,
    { bang = true, desc = "Toggle the work-files panel (! every repo)" })
vim.api.nvim_create_user_command('WorkGrep', function(o) wf().grep(o.args, o.bang) end,
    { nargs = '?', bang = true, desc = "fzf search this repo's work files (! every repo)" })
