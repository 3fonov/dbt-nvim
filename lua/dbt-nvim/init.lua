local D = {}
local uv = vim.uv or vim.loop
local manifest_cache = {}


D.setup = function()
	vim.api.nvim_create_user_command('DbtCompile', function() D.compile() end, {})
	vim.api.nvim_create_user_command('DbtModelYaml', function() D.model_yaml() end, {})
	vim.api.nvim_create_user_command('DbtRun', function() D.run() end, {})
	vim.api.nvim_create_user_command('DbtBuild', function() D.build() end, {})
	vim.api.nvim_create_user_command('DbtRunFull', function() D.run_full() end, {})
	vim.api.nvim_create_user_command('DbtTest', function() D.test() end, {})
	vim.api.nvim_create_user_command('DbtListDownstreamModels', function() D.list_downstream_models() end, {})
	vim.api.nvim_create_user_command('DbtListUpstreamModels', function() D.list_upstream_models() end, {})
	vim.api.nvim_create_user_command('DbtGoToDefinition', function() D.goto_definition() end, {})

	vim.api.nvim_create_autocmd('FileType', {
		pattern = 'sql',
		callback = function(args)
			D._maybe_attach_buffer(args.buf)
		end,
	})
end


local function notify(level, msg)
	if vim.notify and vim.log and vim.log.levels then
		vim.notify(msg, vim.log.levels[level] or vim.log.levels.INFO)
	else
		print(msg)
	end
end

local function join_paths(root, rel)
	if rel:match('^%a:[\\/]') or rel:sub(1, 1) == '/' then
		return rel
	end
	if vim.fs and vim.fs.joinpath then
		return vim.fs.normalize(vim.fs.joinpath(root, rel))
	end
	local separator = package.config:sub(1, 1)
	local path = root .. separator .. rel
	return vim.fn.fnamemodify(path, ':p')
end

local function read_file(path)
	local fd = io.open(path, 'r')
	if not fd then return nil end
	local content = fd:read('*a')
	fd:close()
	return content
end

local function get_project_root(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == '' then return nil end
	local dir = vim.fn.fnamemodify(name, ':p:h')
	local root
	if vim.fs and vim.fs.find then
		local found = vim.fs.find('dbt_project.yml', { upward = true, path = dir })
		if found and #found > 0 then
			root = vim.fn.fnamemodify(found[1], ':p:h')
		end
	end
	if not root then
		local project = vim.fn.findfile('dbt_project.yml', dir .. ';')
		if project ~= '' then
			root = vim.fn.fnamemodify(project, ':p:h')
		end
	end
	return root
end

local function get_manifest_index(root)
	local manifest_path = join_paths(root, 'target/manifest.json')
	local stat = uv and uv.fs_stat(manifest_path) or nil
	if not stat then
		return nil, 'dbt manifest not found. Run dbt compile to generate it.'
	end
	local mtime = stat.mtime and (stat.mtime.sec or stat.mtime) or 0
	local cached = manifest_cache[manifest_path]
	if cached and cached.mtime == mtime then
		return cached.index
	end
	local content = read_file(manifest_path)
	if not content then
		return nil, 'Unable to read dbt manifest at ' .. manifest_path
	end
	local ok, manifest = pcall(vim.fn.json_decode, content)
	if not ok then
		return nil, 'Failed to parse dbt manifest.json'
	end
	local index = { models = {}, sources = {} }
	for _, node in pairs(manifest.nodes or {}) do
		if node.resource_type == 'model' and node.original_file_path and node.name then
			local absolute = join_paths(root, node.original_file_path)
			index.models[node.name] = absolute
			if node.package_name then
				index.models[node.package_name .. '.' .. node.name] = absolute
			end
		end
	end
	for _, node in pairs(manifest.sources or {}) do
		if node.source_name and node.name and node.original_file_path then
			local absolute = join_paths(root, node.original_file_path)
			local key = string.format('%s:%s', node.source_name, node.name)
			index.sources[key] = absolute
		end
	end
	manifest_cache[manifest_path] = { mtime = mtime, index = index }
	return index
end

local function find_model_reference(line, column)
	local pattern = "ref%(%s*['\"]([^'\"]+)['\"]%s*%)"
	local search_from = 1
	while true do
		local s, e, name = line:find(pattern, search_from)
		if not s then break end
		if column >= s and column <= e then
			local package, model = name:match('^([^.]+)%.(.+)$')
			if package and model then
				return { type = 'model', full = name, key = model }
			end
			return { type = 'model', full = name, key = name }
		end
		search_from = e + 1
	end
end

local function find_source_reference(line, column)
	local pattern = "source%(%s*['\"]([^'\"]+)['\"]%s*,%s*['\"]([^'\"]+)['\"]%s*%)"
	local search_from = 1
	while true do
		local s, e, source_name, table_name = line:find(pattern, search_from)
		if not s then break end
		if column >= s and column <= e then
			return { type = 'source', source = source_name, name = table_name, full = source_name .. ':' .. table_name }
		end
		search_from = e + 1
	end
end

local function find_reference_under_cursor()
	local line = vim.api.nvim_get_current_line()
	local _, col = unpack(vim.api.nvim_win_get_cursor(0))
	local column = col + 1
	return find_model_reference(line, column) or find_source_reference(line, column)
end

D.goto_definition = function()
	local ref = find_reference_under_cursor()
	if not ref then return false end
	local bufnr = vim.api.nvim_get_current_buf()
	local ok, root = pcall(vim.api.nvim_buf_get_var, bufnr, 'dbt_project_root')
	if not ok or not root then
		root = get_project_root(bufnr)
		if root then
			pcall(vim.api.nvim_buf_set_var, bufnr, 'dbt_project_root', root)
		end
	end
	if not root then
		notify('WARN', 'Not inside a dbt project (missing dbt_project.yml).')
		return false
	end
	local index, err = get_manifest_index(root)
	if not index then
		if err then notify('WARN', err) end
		return false
	end
	local target
	if ref.type == 'model' then
		target = index.models[ref.full] or index.models[ref.key]
	else
		target = index.sources[ref.full]
	end
	if not target or vim.fn.filereadable(target) == 0 then
		notify('WARN', 'Definition not found for ' .. ref.full .. '.')
		return false
	end
	vim.cmd('edit ' .. vim.fn.fnameescape(target))
	return true
end

D._maybe_attach_buffer = function(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == '' or vim.fn.fnamemodify(name, ':e') ~= 'sql' then return end
	local root = get_project_root(bufnr)
	if not root then return end
	local ok, attached = pcall(vim.api.nvim_buf_get_var, bufnr, 'dbt_gd_attached')
	if ok and attached then return end
	pcall(vim.api.nvim_buf_set_var, bufnr, 'dbt_project_root', root)
	vim.keymap.set('n', 'gd', function()
		if not D.goto_definition() then
			vim.cmd('normal! gd')
		end
	end, { buffer = bufnr, silent = true })
	vim.api.nvim_buf_set_var(bufnr, 'dbt_gd_attached', true)
end



-- Get the model name from the current file if it's an SQL file
D.get_model_name = function()
	local ext = vim.fn.expand('%:e')
	if ext ~= 'sql' then return nil end
	return vim.fn.expand('%:t:r')
end

-- Create a split buffer to show command output
local function create_split_buffer()
	local buf = vim.api.nvim_create_buf(false, true) -- false for not listed, true for scratch buffer
	vim.cmd('belowright split')
	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':q<CR>', { noremap = true, silent = true })
	vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
	vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
	return buf
end


-- Scroll to the bottom of the window
local function scroll_to_bottom(win)
	local last_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	vim.api.nvim_win_set_cursor(win, { last_line, 0 })
end

-- Remove control characters like ANSI escape codes
local function sanitize_output(line)
	return string.gsub(line, "\27%[[%d;]*[A-Za-z]", "")
end

-- Check if a line starts with a timestamp (like '21:17:09')
local function is_timestamp_line(line)
	return string.match(line, "^%d%d:%d%d:%d%d")
end

local current_job_id = nil
-- Stream command output to a buffer
local function stream_command_to_buffer(cmd)
	local buf = create_split_buffer()
	local win = vim.api.nvim_get_current_win()
	local full_output = {}

	current_job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data, _)
			if data then
				local sanitized_data = {}
				for _, line in ipairs(data) do
					if line ~= nil then
						local sanitized_line = sanitize_output(line):gsub('\r', '')
						for _, segment in ipairs(vim.split(sanitized_line, '\n', { plain = true, trimempty = false })) do
							if not is_timestamp_line(segment) then
								table.insert(full_output, segment)
							end
							table.insert(sanitized_data, segment)
						end
					end
				end
				vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
				vim.api.nvim_buf_set_lines(buf, -1, -1, false, sanitized_data)
				vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
				scroll_to_bottom(win)
			end
		end,
		on_stderr = function(_, data, _)
			if data then
				local sanitized_data = {}
				for _, line in ipairs(data) do
					if line ~= nil then
						local sanitized_line = sanitize_output(line):gsub('\r', '')
						for _, segment in ipairs(vim.split(sanitized_line, '\n', { plain = true, trimempty = false })) do
							table.insert(sanitized_data, segment)
						end
					end
				end
				vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
				vim.api.nvim_buf_set_lines(buf, -1, -1, false, sanitized_data)
				vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
				scroll_to_bottom(win)
			end
		end,
		on_exit = function(_, exit_code, _)
			vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
			vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "Command exited with code: " .. exit_code })
			vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
			scroll_to_bottom(win)
		end,
	})

	if current_job_id <= 0 then
		print("Failed to start job!")
	end
end

-- dbt command functions
D.run = function() D._run_dbt('run') end
D.build = function() D._run_dbt('build') end
D.run_full = function() D._run_dbt('run', '--full-refresh') end
D.test = function() D._run_dbt('test') end
D.compile = function() D._run_dbt('compile') end
D.model_yaml = function()
	local model_name = D.get_model_name()
	if model_name == nil then return end
	local command = { 'dbt', 'run-operation', 'generate_model_yaml', '--args', '{"model_names": ["' .. model_name .. '"]}' }
	stream_command_to_buffer(command)
end

-- Helper to run dbt commands with model selector
D._run_dbt = function(command, params)
	local model_name = D.get_model_name()
	if model_name == nil then return end
	local cmd = { 'dbt', command }
	if params then
		if type(params) == 'table' then
			vim.list_extend(cmd, params)
		else
			table.insert(cmd, params)
		end
	end
	vim.list_extend(cmd, { '-s', model_name })
	stream_command_to_buffer(cmd)
end

-- Telescope-related functionality
local actions = require('telescope.actions')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local action_state = require('telescope.actions.state')

-- Get command output lines
local function get_command_output_lines(cmd)
	local handle = io.popen(cmd)
	local result = {}
	if handle then
		for line in handle:lines() do
			table.insert(result, line)
		end
		handle:close()
	end
	return result
end

-- Parse dbt JSON lines and return formatted entries
local function parse_dbt_json_lines(output_lines)
	local entries = {}
	local path_map = {}
	for _, line in ipairs(output_lines) do
		if line ~= "" then
			local entry = vim.fn.json_decode(line)
			local formatted_entry = entry.unique_id
			table.insert(entries, formatted_entry)
			path_map[formatted_entry] = entry.original_file_path
		end
	end
	return entries, path_map
end

-- Populate telescope with dbt list output
local function populate_telescope(entries, path_map, title)
	pickers.new({}, {
		prompt_title = title,
		finder = finders.new_table { results = entries },
		sorter = conf.generic_sorter({}),
		attach_mappings = function(_, _)
			actions.select_default:replace(function(prompt_bufnr)
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				local file_to_open = path_map[selection[1]]
				if file_to_open then
					vim.cmd("edit " .. file_to_open)
				else
					print("No file path found for the selected entry.")
				end
			end)
			return true
		end,
	}):find()
end

-- List Upstream/Downstream models using dbt list --output json
D.list_upstream_models = function() D._list_models('<selector>+', 'Upstream Models') end
D.list_downstream_models = function() D._list_models('+<selector>', 'Downstream Models') end

D._list_models = function(selector, title)
	local model_name = D.get_model_name()
	if model_name == nil then return end
	local selector_with_model = selector:gsub('<selector>', model_name)
	local escaped_selector = vim.fn.shellescape(selector_with_model)
	local cmd = string.format(
		"dbt list -s %s --output json -q --output-keys unique_id original_file_path",
		escaped_selector
	)
	local output = get_command_output_lines(cmd)
	local entries, path_map = parse_dbt_json_lines(output)
	populate_telescope(entries, path_map, title)
end
return D
