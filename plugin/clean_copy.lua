if vim.g.loaded_clean_copy then return end
vim.g.loaded_clean_copy = true
-- Loading registers :CopyClean and :CopyCleanParsers without calling setup().
require('clean_copy')._register_command()
