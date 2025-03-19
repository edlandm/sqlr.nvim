local name = 'sqlr'
package.loaded[name] = {}
local M = package.loaded[name]

---@type {loclist?: table[]}
M.results = {}

-- UTILITY FUNCTIONS =========================================================
local function not_empty(str)
  return str ~= vim.NIL and vim.fn.empty(str) == 0
end

---determine if the given window is visible in the current tabpage
---@param win integer window id
---@return boolean true if window is visible/displayed
local function is_window_visible_in_current_tab(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local current_tab = vim.api.nvim_get_current_tabpage()

  for _, winnr in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if winnr == win then
      return true
    end
  end

  return false
end

-- SET ENVIRONMENT/DATABASE ==================================================
---create notification showing the selected env:database
function M.env_info()
  local msg
  if not M.env then
    msg = 'No Environment selected'
  elseif not M.db then
    msg = 'No Database Selected'
  else
    msg = ('Using %s:%s'):format(M.env.name, M.db)
  end
  vim.notify(msg, vim.log.levels.INFO, {})
end

---return `s` only if it is a supported database vendor
---@param s string
---@return Sqlr.db_vendor?
local function val_env_type(s)
  -- TODO: add sqlite, posgres, duckdb
  if vim.tbl_contains({ 'sqlserver', 'oracle' }, s) then
    return s
  end
end

---attempt to find and load the environment based on the provided name
---@param env_name string either filename or absolute path of environment file
---@return Sqlr.env?
local function get_env(env_name)
  local _name = name .. '.set_env'
  local file
  local stat = vim.uv.fs_stat(env_name)
  if stat then
    file = env_name
  else
    local found_envs = vim.fs.find({vim.fn.expand(env_name), env_name..'.lua'}, {
      type = 'file',
      path = M.opts.env_dir,
      limit = 1,
    })

    if #found_envs == 0 then
      vim.notify(('%s: Unable to find environment "%s"'):format(name, env_name), "error", {})
      return
    end
    file = found_envs[1]
  end

  local chunk, err = loadfile(file)
  assert(chunk, ('%s :: failed to load %s as lua: %s'):format(_name, file, err))

  local env = chunk()
  assert(env, ('%s :: %s did not return anything'):format(_name, file))

  for _, field in ipairs({ 'type', 'host', 'user', 'password', 'databases' }) do
    assert(env[field], ('%s :: %s does not define required field: %s'):format(_name, file, field))
    assert(env[field] ~= '', ('%s :: %s: %s cannot be empty'):format(_name, file, field))
  end

  local env_type = val_env_type(env.type)
  assert(env_type,
    ('%s :: %s has invalid type: "%s"'):format(_name, file, env.type))
  env.type = env_type

  assert(type(env.databases) == 'table' and #env.databases > 0,
    ('%s :: %s: no databases defined'):format(_name, file))

  env.name = vim.fn.fnamemodify(file, ':t:r')
  return env
end

---find and globally set the given environment file (lua)
---@param env_name path name (with extension) of file in opts.env_dir
function M.set_env(env_name)
  local _name = name..'.set_env'
  local ok, env = pcall(get_env, env_name)
  if not ok or not env then
    vim.notify(('%s :: unable to load environment "%s"'):format(_name, env_name), vim.log.levels.ERROR, {})
    return
  end
  M.env = env
  M.db = env.databases[1]
  M.env_info()
end

---return the filenames of all of the files found in M.opts.env_dir
---@return table
local function get_env_files()
  local files = {}
  for item, type in vim.fs.dir(M.opts.env_dir) do
    if type == 'file' then
      table.insert(files, item)
    end
  end
  return files
end

---use snacks.picker to fuzzy-find and select an env file in M.opts.env_dir
function M.pick_env()
  local success, picker = pcall(require, 'snacks.picker')
  if not success then
    vim.notify(('%s :: snacks.nvim required for picker functionality'):format(name), "error", {})
    return
  end

  local files = get_env_files()

  picker.pick {
    source = 'Sqlr Environments',
    layout = 'vscode',
    items = vim.tbl_map(function(file)
      return {
        text = file,
        file = vim.fs.joinpath(M.opts.env_dir, file),
      }
    end, files),
    actions = {
      open = {
        name = 'Open Env Directory',
        action = function (self)
          self:close()
          vim.cmd({ cmd = 'split', args = { M.opts.env_dir } })
        end
      },
      edit = {
        name = 'Edit Selected Environment File',
        action = function (self, item)
          self:close()
          vim.cmd({ cmd = 'split', args = { item.file } })
        end
      },
    },
    confirm = function(p, item)
      p:close()
      M.set_env(item.file)
    end,
    win = {
      input = {
        keys = {
          ['<C-o>'] = { 'open', mode = { 'n', 'i' } },
          ['<C-e>'] = { 'edit', mode = { 'n', 'i' } },
        },
      },
    },
  }
end

---set the given database to be used for queries
---@param db_name string one of the database names defined in `env`
function M.set_db(db_name)
  local _name = name .. '.set_db'
  assert(M.env, ('%s :: env not set'):format(_name))
  assert(db_name and db_name ~= '', ('%s :: db required'):format(_name))

  local found
  for _, db in ipairs(M.env.databases) do
    if db_name == db then
      found = db_name
      break
    end
  end

  if not found then
    vim.notify(('%s :: "%s" database not defined for %s'):format(name, db_name, M.env.name))
    return
  end

  M.db = db_name
  M.env_info()
end

function M.pick_db()
  local success, picker = pcall(require, 'snacks.picker')
  if not success then
    vim.notify(('%s :: snacks.nvim required for picker functionality'):format(name), "error", {})
    return
  end

  if not M.env then
    vim.notify(('%s :: Select an environment first'):format(name), "error", {})
    return
  end

  picker.pick {
    source = 'Sqlr Environments',
    layout = 'vscode',
    items = vim.tbl_map(function(db)
      return { text = db, file = db }
    end, M.env.databases),
    confirm = function(p, item)
      p:close()
      M.set_db(item.text)
    end,
  }
end

-- RUN SQL & VIEW RESULTS ====================================================
---try to parse sql result lines into deliminated values for csvlens
---@param lines string[]
---@param sep string
---@return string? error
---@return string[]? lines
local function sqlserver_rowset_to_csv(lines, sep)
  local _name = name..'.sqlserver_rowset_to_csv'
  if #lines < 2 then
    return ('%s :: at least three lines expected'):format(_name)
  end

  --[[
    col1 id name $ headers
    ---- -- -----$ spacers
    val   1 peter$ rows
    ...
  --]]

  if lines[1]:match('rows affected%)$') then
    table.remove(lines, 1)
  end

  local header = table.remove(lines, 1)
  local spacers = table.remove(lines, 1)

  ---@type { range: [integer, integer], name: string }[]
  local columns = {}
  local start = 1
  for match in string.gmatch(spacers, '%-+') do
    local _end = start + #match
    local colname = string.sub(header, start, _end)
    table.insert(columns, {
      name = vim.trim(colname),
      range = { start, _end },
    })
    start = _end + 1
  end

  ---@type string[]
  local header_row = {}
  for _, col in ipairs(columns) do
    table.insert(header_row, col.name)
  end

  ---@type string[]
  local results = { table.concat(header_row, sep) }

  for i, line in ipairs(lines) do
    if line:match('^%s*$') then
      break
    end

    local row = {}
    for _, col in ipairs(columns) do
      local s, e = unpack(col.range)
      local val = string.sub(line, s, e)
      table.insert(row, vim.trim(val))
    end

    if #row ~= #columns then
      return ('%s :: row[%d] has an incorrect number of columns. Expected<%d> Got<%d>\n%s'):format(_name, i, #row, #columns, line)
    end

    table.insert(results, table.concat(row, sep))
  end

  return nil, results
end

---made the line more compact and replace col-sep with '|' for readability
---@param s string
---@return string
local function loclist_prettify(s)
  local text = s:gsub('%s*'..M.opts.col_sep..'%s*', '|')
  return text
end

---@type {[db_vendor]: Sqlr.db_vendor}
local vendors = {
  sqlserver = {
    get_results_starting_lines = function(results_lines)
      -- sqlcmd results look like this:
      --[[
      col1 id name $ headers
      ---- -- -----$ spacers
      val   1 peter$ rows
      ...
      --]]
      -- so we can just look for the spacers line and then grab the one before it
      local lines = {}
      for i, line in ipairs(results_lines) do
        if line:match('^%-%-+') then
          local lnum = i-1
          -- sometimes queries return scalars without headers, in this case, we
          -- need to grab the line after the spacer line
          if i == 1 or results_lines[i-1]:match('^%s*$') then
            lnum = i+1
          end
          local text = loclist_prettify(results_lines[lnum])
          table.insert(lines, { lnum = lnum, bufnr = M.buffers.results, text = text })
        end
      end
      return lines
    end,
    csview_pre_set_cursor = function (s, e, lines)
      ---@diagnostic disable-next-line
      if #lines <= 2 then -- scalar without header
        vim.api.nvim_win_set_cursor(0, {e, 0})
        lines = { lines[#lines] }
        return lines
      end
      if lines[1]:match('rows affected%)') then
        vim.api.nvim_win_set_cursor(0, {s+1, 0})
      else
        vim.api.nvim_win_set_cursor(0, {s, 0})
      end
      local err, csv_lines = sqlserver_rowset_to_csv(lines, M.opts.col_sep)
      if not csv_lines then
        vim.notify(err, vim.log.levels.DEBUG, {})
        return lines
      end
      return csv_lines
    end,
    parse_errors = function(output)
      local _output = {
        stdout = {},
        stderr = output.stderr,
      }

      for _, line in ipairs(output.stdout) do
        if line:match('%(%d+ rows? affected%)')
        then
          table.insert(_output.stderr, line)
        else
          if not line:match('^No errors%.') then
            table.insert(_output.stdout, line)
          end
        end
      end

      return output
    end
  },
  oracle = {
    get_results_starting_lines = function(results_lines)
      -- sqlplus results look like this:
      --[[
      col1	col2
      val1	val2


      col1	col2
      val1	val2
      --]]
      -- so we have to look for wherever we find two empty lines in a row and then
      -- grab the next non-empty line
      local lines = {}
      -- we add the first line manually because there are no empty lines before it
      table.insert(lines, { lnum = 1, bufnr = M.buffers.results, text = loclist_prettify(results_lines[1]) })
      for i, line in ipairs(results_lines) do
        if line:match('^$') and (i+1 <= #results_lines and not results_lines[i+1]:match('^$')) then
          table.insert(lines, { lnum = i+1, bufnr = M.buffers.results, text = loclist_prettify(results_lines[i+1]) })
        end
      end
      return lines
    end,
    parse_errors = function(output)
      local cleaned_output = {
        stdout = {},
        stderr = output.stderr,
      }

      for _, line in ipairs(output.stdout) do
        if line:match('^SP%d%-%d+')
        or line:match('^%d+ rows selected')
        then
          table.insert(cleaned_output.stderr, line)
        else
          if not line:match('^No errors%.') then
            table.insert(cleaned_output.stdout, line)
          end
        end
      end

      return cleaned_output
    end
  }
}

---create a popup window in which to display lines (start hidden)
---@param buf integer bufffer id
---@param opts? snacks.win.Config
---@returns snacks.win
local function create_popup_window(buf, opts)
  local winopts = {
    style = 'split',
    relative = 'win',
    position = 'bottom',
    height = #vim.api.nvim_buf_get_lines(buf, 0, -1, true),
    max_height = vim.api.nvim_win_get_height(0) / 2,
    row = 1,
    col = 0,
    enter = false,
    show = false,
    ft = 'scratch',
    fixbuf = true,
    buf = buf,
    keys = {
      q = "hide",
    },
  }

  if opts then
    ---@diagnostic disable-next-line
    winopts = vim.tbl_deep_extend('keep', opts, winopts)
  end

  if type(M.opts.win) == 'table' then
    ---@diagnostic disable-next-line
    winopts = vim.tbl_deep_extend('keep', M.opts.win, winopts)
  end

  -- use splitkeep='screen' just for this split so that the top window (if
  -- horizontal split) doesn't scroll; it looks weird/disorienting
  local _splitkeep = vim.o.splitkeep
  vim.o.splitkeep = 'screen'
  local win = require('snacks').win(winopts)
  vim.o.splitkeep = _splitkeep
  return win
end

---display the popup results window
---@param mode 'results' | 'messages' | 'csvview'
function M.toggle_results(mode)
  if not M.buffers or not M.windows then
    vim.notify(('%s :: No results to show'):format(name), vim.log.levels.ERROR, {})
    return
  end

  local _name = name..'.toggle_results'
  if mode then
    local buf = assert(M.buffers[mode], ('%s :: invalid mode "%s"'):format(_name, mode))
    local win = M.windows.results
    if not win.closed then
      win:close()
    end
    win.opts.height = #vim.api.nvim_buf_get_lines(buf, 0, -1, true)
    win:show()
    win:set_title(mode:upper())
    win:set_buf(buf)

    if buf == M.buffers.results and M.results.loclist then
      vim.fn.setloclist(M.windows.results.win, M.results.loclist)
    end
    M.windows.results:focus()
    return
  end

  M.windows.results:toggle()

  local is_visible = is_window_visible_in_current_tab(M.windows.results.win)
  local has_lines = vim.fn.empty(M.results.loclist) == 0
  if is_visible and has_lines then
    vim.fn.setloclist(M.windows.results.win, M.results.loclist)
    M.windows.results:focus()
  end
end

---select the current/nearest resultset (paragraph) and open in csvview
local function csvview_cursor()
  -- select nearest paragraph and exit visual mode so that '< & '> are set
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes('vip<esc>', true, false, true),
    'itx',
    false)

  local s, _ = unpack(vim.api.nvim_buf_get_mark(0, '<'))
  local e, _ = unpack(vim.api.nvim_buf_get_mark(0, '>'))
  local lines = vim.api.nvim_buf_get_lines(0, s-1, e, true)

  local handler = vendors[M.env.type].csview_pre_set_cursor
  if handler then
    lines = handler(s, e, lines)
  else
    vim.api.nvim_win_set_cursor(0, {s, 0})
  end

  vim.api.nvim_buf_set_lines(M.buffers.csvview, 0, -1, true, lines)

  M.toggle_results('csvview')

  -- ensure that csview is enabled and refreshed for the current buffer contents
  local buf = M.buffers.csvview
  local csvview = require('csvview')
  if csvview.is_enabled(buf) then
    -- refresh
    csvview.disable(buf)
    csvview.enable(buf, { delimiter = M.opts.col_sep })
  else
    csvview.enable(buf, { delimiter = M.opts.col_sep })
  end
end

---perform all of the buffer-specific setup for working with csvview
local function csvview_setup()
  local buf = M.buffers.csvview
  vim.api.nvim_set_option_value('filetype', 'tsv', { scope = 'local', buf = buf })

  vim.api.nvim_buf_set_keymap(M.buffers.results, 'n', '<cr>', '', {
    desc = 'display current resultset in csvview buffer',
    callback = csvview_cursor,
  })

  vim.api.nvim_buf_set_keymap(M.buffers.results, 'v', '<cr>', '', {
    desc = 'display selection in csvview buffer',
    callback = function()
      -- exit visual mode so that '< & '> are set
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes('<esc>', true, false, true),
        'itx',
        false)

      local s, _ = unpack(vim.api.nvim_buf_get_mark(0, '<'))
      local e, _ = unpack(vim.api.nvim_buf_get_mark(0, '>'))
      local lines = vim.api.nvim_buf_get_lines(0, s-1, e, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)

      M.toggle_results('csvview')
    end
  })

  vim.api.nvim_buf_set_keymap(buf, 'n', '<esc>', '', {
    desc = 'exit csvview (return to raw Results view)',
    callback = function() M.toggle_results('results') end,
  })

  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
    desc = 'close results window',
    callback = function() M.windows.results:hide() end,
  })

  vim.api.nvim_buf_set_keymap(buf, 'n', '<a-j>', '', {
    desc = 'Jump to next resultset',
    callback = function()
      M.toggle_results('results')
      local ok = pcall(vim.cmd.lbelow)
      if not ok then
        vim.cmd('lfirst')
      end
      csvview_cursor()
    end,
  })

  vim.api.nvim_buf_set_keymap(buf, 'n', '<a-k>', '', {
    desc = 'Jump to previous resultset',
    callback = function()
      M.toggle_results('results')
      local ok = pcall(vim.cmd.labove)
      if not ok then
        vim.cmd('llast')
      end
      csvview_cursor()
    end,
  })
end

---default results-viewer
---@param err string? error message, if any
---@param results? cmd_output the stdout and stdin from the command
local function view_results(err, results)
  if err then
    vim.notify('Sqlr: ' .. err, vim.log.levels.ERROR, {})
    return
  end

  if not results then
    return
  end

  if not M.buffers then
    M.buffers = {
      results  = vim.api.nvim_create_buf(true, true),
      messages = vim.api.nvim_create_buf(true, true),
    }

    vim.api.nvim_set_option_value('filetype', 'sqlresults', { scope = 'local', buf = M.buffers.results })

    if M.opts.viewer == 'csvview' then
      M.buffers.csvview = vim.api.nvim_create_buf(true, true)
      csvview_setup()
    end

    for key, buf in pairs(M.buffers) do
      vim.api.nvim_set_option_value('buftype', 'nofile', { scope = 'local', buf = buf })

      vim.api.nvim_buf_set_keymap(buf, 'n', 'R', '', {
        desc = 'Toggle Results View',
        callback = function()
          if buf == M.buffers.results then
            return
          end
          M.toggle_results('results')
        end
      })
      vim.api.nvim_buf_set_keymap(buf, 'n', 'M', '', {
        desc = 'Toggle Messages View',
        callback = function()
          if buf == M.buffers.messages then
            return
          end
          M.toggle_results('messages')
        end
      })
    end
  end

  if not M.windows then
    M.windows = {}
  end

  vim.api.nvim_set_option_value('readonly', false, { scope = 'local', buf = M.buffers.results })
  vim.api.nvim_buf_set_lines(M.buffers.results, 0, -1, true, results.stdout)
  vim.api.nvim_set_option_value('readonly', true, { scope = 'local', buf = M.buffers.results })

  vim.api.nvim_set_option_value('readonly', false, { scope = 'local', buf = M.buffers.messages })
  vim.api.nvim_buf_set_lines(M.buffers.messages, 0, -1, true, results.stderr)
  vim.api.nvim_set_option_value('readonly', true, { scope = 'local', buf = M.buffers.messages })

  local buf = M.buffers.results
  if #results.stdout == 0 and #results.stderr > 0 then
    buf = M.buffers.messages
  end

  if not M.windows.results then
    M.windows.results = create_popup_window(buf)
  end

  if buf == M.buffers.messages then
    vim.notify(('%s :: Showing Messages'):format(name), vim.log.levels.INFO, {})
    M.toggle_results('messages')
    print('Showing Messages')
    return
  end

  -- populate location list with the beginning of each resultset
  M.results.loclist = vendors[M.env.type].get_results_starting_lines(results.stdout)
  M.toggle_results('results')

  local count_resultsets = #vim.fn.getloclist(M.windows.results.win)
  if count_resultsets == 1 then
    print('SQL Ran Successfully')
  else
    print(('SQL Ran Successfully. %d result-sets returned'):format(count_resultsets))
  end

  -- automatically open csvview
  if M.opts.viewer == 'csvview' then
    vim.cmd('silent! lfirst')
    csvview_cursor()
  end

  -- TODO: add support for csvlens
end

---@diagnostic disable

---run the given sql
---@param sql string|string[]
---@param opts Sqlr.run_opts
local function run(sql, opts) end

---run the indicated range of the current buffer as sql
---@param s integer
---@param e integer
---@param opts Sqlr.run_opts
local function run(s, e, opts) end

---run the visual selection as sql
---@param opts Sqlr.run_opts
local function run(opts) end

---@diagnostic enable

---run sql; can be supplied as:
--- - a string
--- - a list of strings (lines, in that case)
--- - a range of lines (start, end) of the current buffer
--- - the current visual selection (NOTE: whole lines will always be selected)
---@param arg1  string|string[]|integer|Sqlr.run_opts
---@param arg2? Sqlr.run_opts|integer
---@param arg3? Sqlr.run_opts?
function M.run(arg1, arg2, arg3)
  local _name = name .. '.run'
  local lines
  local _opts
  if type(arg1) == 'string' and (arg2 == nil or type(arg2) == 'table') then
    vim.notify(('%s :: sql passed as string'):format(_name), vim.log.levels.DEBUG, {})
    lines = vim.split(arg1, '\n')
    _opts = arg2 or {}
  elseif type(arg1) == 'table' and type(arg1[1]) == 'string' and (arg2 == nil or type(arg2) == 'table') then
    vim.notify(('%s :: sql passed as list of lines'):format(_name), vim.log.levels.DEBUG, {})
    lines = arg1
    _opts = arg2 or {}
  elseif type(arg1) == 'number' and type(arg2) == 'number' and (arg3 == nil or type(arg3) == 'table') then
    vim.notify(('%s :: sql indicated with range'):format(_name), vim.log.levels.DEBUG, {})
    local s = arg1
    local e = arg2
    if s > 0 then
      s = s-1
    end
    lines = vim.api.nvim_buf_get_lines(0, s, e, true)
    _opts = arg3 or {}
  else
    vim.notify(('%s :: determining sql from visual selection'):format(_name), vim.log.levels.DEBUG, {})
    assert(arg1 == nil or type(arg1) == 'table', ('%s :: unexpected argument: %s'):format(_name, vim.inspect(arg1)))
    _opts = arg1 or {}

    -- leave visual mode so that '< and '> get set
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<esc>', true, false, true),
      'itx',
      false)

    local s = vim.api.nvim_buf_get_mark(0, '<')
    local e = vim.api.nvim_buf_get_mark(0, '>')
    assert(s[1] > 0, '< mark not set')
    assert(e[1] > 0, '> mark not set')

    lines = vim.api.nvim_buf_get_lines(0, s[1]-1, e[1], true)
  end

  assert(lines and type(lines) == 'table',
    ('%s :: unable to get lines'):format(_name))
  assert(#lines > 0,
    ('%s :: lines cannot empty'):format(_name))
  assert(type(lines[1]) == 'string',
    ('%s :: lines must be a list of strings'):format(_name))

  local opts = vim.tbl_deep_extend('keep', _opts or {}, {
    callback = view_results
  })

  local env, db
  if opts.env then
    local ok
    ok, env = pcall(get_env, opts.env)
    if not ok or not env then
      vim.notify(('%s :: unable to load environment "%s"'):format(_name, opts.env), vim.log.levels.ERROR, {})
      return
    end
    db = opts.db or env.databases[1]
  else
    env = M.env
    db = M.db
  end

  -- TODO: It would be cool to open the env/db picker in this case (if has snacks)
  -- so that the user can stay in the groove
  assert(env, 'Environment not set')
  assert(db,  'Database not set')

  vim.notify(('%s :: running sql'):format(_name), vim.log.levels.DEBUG)
  if not opts.silent then
    print('Running SQL...')
  end

  ---@type string
  local password
  if type(env.password) == 'function' then
    password = env:password()
  else
    ---@type string
    password = env.password ---@diagnostic disable-line it's a string, damnit
  end

  ---@type string[]
  local cmd
  if env.cmd then
    cmd = env.cmd(env, db, lines, M.opts)
  elseif env.type == 'sqlserver' then
    cmd = {
      'sqlcmd',
      '-C', -- trust server certificate
      -- '-W', -- trim spaces (leave this off)
      '-r', '1', -- print all messages to stderr (even those that are not errors)
      '-S', env.host,
      '-d', db,
      '-U', env.user,
      '-P', password,
      '-s', M.opts.col_sep,
      '-Q', vim.fn.join(lines, '\n'),
    }
    if opts.noerror then
      table.insert(cmd, '-n')
    end
  elseif env.type == 'oracle' then
      cmd = {
        'sqlplus',
        '-F', -- fast
        '-S', -- silent
        '-M', ("CSV ON DELIMITER '%s' QUOTE OFF"):format(M.opts.col_sep), -- markup as csv
        '-nologintime',
        ('%s/%s@%s/%s'):format(env.user, password, env.host, db),
      }
      table.insert(lines, 1, "SET NULL 'NULL';")
      table.insert(lines, 1, "SET SERVEROUTPUT ON SIZE 1000000;")
      table.insert(lines, 1, "SET SQLBLANKLINES ON;")
      table.insert(lines, 1, "SET FEEDBACK ON;")
      table.insert(lines, "SHOW ERRORS;")
  end

  -- dd { cmd=cmd, lines=lines }
  local out_lines, err_lines = {}, {}
  local jid = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or vim.fn.empty(data) == 1 then
        return
      end

      -- remove empty lines from the beginning
      while #data > 0 and data[1]:match('^%s*$') do
        table.remove(data, 1)
      end

      -- remove empty lines from the end
      while #data > 0 and data[#data]:match('^%s*$') do
        table.remove(data, #data)
      end

      if #data > 0 then
        out_lines = data
      end
    end,
    on_stderr = function(_, data)
      if not data or vim.fn.empty(data) == 1 then
        return
      end

      -- remove empty lines from the beginning
      while #data > 0 and  data[1]:match('^%s*$') do
        table.remove(data, 1)
      end

      -- remove empty lines from the end
      while #data > 0 and data[#data]:match('^%s*$') do
        table.remove(data, #data)
      end

      if #data > 0 then
        err_lines = data
      end
    end,
    on_exit = function(_, exit_code, event_type)
      vim.cmd({ cmd='echo', args = { '""' }}) -- clear status line
      vim.notify(('%s :: ran with exit code: %d'):format(_name, exit_code), vim.log.levels.DEBUG)
      if exit_code ~= 0 then
        vim.notify(('%s :: command returned non-zero exit code: %d (%s)'):format(_name, exit_code, event_type), vim.log.levels.ERROR)
      elseif vim.fn.empty(out_lines) == 1 and vim.fn.empty(err_lines) == 1 then
        if not opts.silent then
          -- this is okay, but we notify the user so they know the sql ran
          vim.notify(('%s :: query ran and produced no output'):format(_name), vim.log.levels.INFO)
        end
        return
      end

      -- some vendors (oracle/sqlplus) don't print error messages to stderr,
      -- so we might need to do a little pre-processing
      local output = {stdout=out_lines, stderr=err_lines}
      local parse_errors = vendors[env.type].parse_errors
      if parse_errors then
        output = parse_errors(output)
      end

      return opts.callback(nil, output)
    end
  })

  vim.fn.chansend(jid, lines)
  vim.fn.chanclose(jid, 'stdin')
end

-- SETUP =====================================================================
local completion_functions = {
  environment = function()
    return vim.tbl_map(
      function(f) return vim.fn.fnamemodify(f, ':r') end,
      get_env_files())
  end,
  database = function()
    if M.env then
      return M.env.databases
    end
  end,
}

--- Create commands
--- - SqlrSetEnv
--- - SqlrSetDb
local function create_user_commands()
  vim.api.nvim_buf_create_user_command(0, 'SqlrSetEnv',
    function(opts) M.set_env(vim.trim(opts.args)) end,
    {
      desc = 'Set the environment to use for database connections',
      nargs = 1,
      complete = completion_functions.environment,
    })

  vim.api.nvim_buf_create_user_command(0, 'SqlrSetDb',
    function(opts) M.set_db(vim.trim(opts.args)) end,
    {
      desc = 'Set the database to connect to',
      nargs = 1,
      complete = completion_functions.database,
    })
end

---@type Sqlr.opts
M.opts = {
  env_dir = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqlr', 'env'),
  col_sep = string.char(9), -- tab character
  viewer  = view_results,
}

-- TODO: link buffers to environments
-- If I open up one buffer and connect to DB1, and then open up another buffer
-- and connect to DB2 (in the same env or different), returning to the first
-- buffer and running a query should be executed against DB1
-- Opening new sql buffers can be defaulted to the same env/db used by the
-- previous buffer

-- TODO: allow the ability to set variables (tied to a buffer)
-- I'd like the abitily to parse a buffer and generate a form for any
-- undeclared variables

---perform setup, pre-select env/db if SQLR_ENV or SQLR_DB env vars set
---@param opts Sqlr.opts
---@return Sqlr
function M.setup(opts)
  local _opts = vim.tbl_deep_extend('keep', opts or {}, M.opts)
  M.opts = _opts

  local _name = name .. '.setup'

  -- expand path once to avoid having to do it every time
  local env_dir = vim.fn.expand(M.opts.env_dir)

  local stat, err = vim.uv.fs_stat(env_dir)
  assert(stat, ('%s :: %s'):format(_name, err))
  assert(stat.type == 'directory', ('%s :: %s is not a directory'):format(_name, env_dir))

  M.opts.env_dir = env_dir

  local env_file = vim.fn.getenv('SQLR_ENV')
  if not_empty(env_file) then
    M.set_env(env_file)
  end

  local db = vim.fn.getenv('SQLR_DB')
  if not_empty(db) then
    M.set_db(db)
  end

  local group = vim.api.nvim_create_augroup('sqlr', {})
  vim.api.nvim_create_autocmd('FileType', {
    pattern  = { 'sql', 'sqlresults' },
    group    = group,
    callback = create_user_commands,
  })
  vim.api.nvim_create_autocmd('BufNew', {
    pattern  = { '*.sql', '*.sqlresults' },
    group    = group,
    callback = create_user_commands,
  })

  return M
end

---@type Sqlr
return M
