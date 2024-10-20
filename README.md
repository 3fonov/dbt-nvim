# dbt-nvim

A Neovim plugin for working with dbt (Data Build Tool) projects.

### Features

-	Run dbt models (dbt run)
-	Test models (dbt test)
-	Compile models (dbt compile)
-	Generate model.yaml for a model using [dbt-codegen](https://github.com/dbt-labs/dbt-codegen?tab=readme-ov-file#generate_model_yaml-source)
-	List upstream and downstream dependencies with Telescope integration

### Installation

Using packer.nvim:
```
use {
  '3fonov/nvim-dbt-plugin',
  requires = { 'nvim-telescope/telescope.nvim', 'nvim-lua/plenary.nvim' }
}
```

Using vim-plug:
```
Plug '3fonov/nvim-dbt-plugin'
```

Using lazy:
```
{
  "3fonov/dbt-nvim"
}
```
### Usage

**Commands**

Run command inside .sql file in dbt project dir. Commands will create new buffer. You can close it with Q key.

-	:DbtCompile: Compile the current model
-	:DbtRun: Run the current model
-	:DbtRunFull: Run the current model with -f flag
-	:DbtTest: Test the current model
-	:DbtModelYaml: Generate model.yaml for the current model
-	:DbtListUpstreamModels: List upstream models with Telescope
-	:DbtListDownstreamModels: List downstream models with Telescope

**Setup Keybindings**

You can setup commands in your config like this:

```
-- DBT
vim.keymap.set('n', '<leader>dc', ':DbtCompile<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>dy', ':DbtModelYaml<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>dr', ':DbtRun<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>df', ':DbtRunFull<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>dt', ':DbtTest<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>d+', ':DbtListUpstreamModels<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>d-', ':DbtListDownstreamModels<CR>', { noremap = true, silent = true })
```


