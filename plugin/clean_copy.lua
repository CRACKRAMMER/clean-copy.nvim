if vim.g.loaded_clean_copy then return end
vim.g.loaded_clean_copy = true
-- Loading the plugin provides :CleanCopy even when setup() is omitted.
require('clean_copy')._register_command()
