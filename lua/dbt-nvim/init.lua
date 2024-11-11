local D = {}


D.setup = function()
	vim.api.nvim_create_user_command('DbtCompile', function() D.compile() end, {})
	vim.api.nvim_create_user_command('DbtModelYaml', function() D.model_yaml() end, {})
	vim.api.nvim_create_user_command('DbtRun', function() D.run() end, {})
	vim.api.nvim_create_user_command('DbtBuild', function() D.build() end, {})
	vim.api.nvim_create_user_command('DbtRunFull', function() D.run_full() end, {})
	vim.api.nvim_create_user_command('DbtTest', function() D.test() end, {})
	vim.api.nvim_create_user_command('DbtListDownstreamModels', function() D.list_downstream_models() end, {})
	vim.api.nvim_create_user_command('DbtListUpstreamModels', function() D.list_upstream_models() end, {})
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
					local sanitized_line = sanitize_output(line)
					if not is_timestamp_line(sanitized_line) then
						table.insert(full_output, sanitized_line)
					end
					table.insert(sanitized_data, sanitized_line)
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
					local sanitized_line = sanitize_output(line)
					table.insert(sanitized_data, sanitized_line)
				end
				vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
				vim.api.nvim_buf_set_lines(buf, -1, -1, false, sanitized_data)
				vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
				scroll_to_bottom(win)
			end
		end,
		on_exit = function(_, exit_code, _)
			vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
			vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "\nCommand exited with code: " .. exit_code })
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
D.run_full = function() D._run_dbt('run','-f') end
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
	stream_command_to_buffer({ 'dbt', command, '-s', model_name , params})
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
	local cmd = "dbt list -s " .. selector .. " --output json -q --output-keys unique_id original_file_path"
	local output = get_command_output_lines(cmd)
	local entries, path_map = parse_dbt_json_lines(output)
	populate_telescope(entries, path_map, title)
end
return D

