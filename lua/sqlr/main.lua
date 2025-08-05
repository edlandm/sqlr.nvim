local name = 'sqlr'
package.loaded[name] = {}
local M = package.loaded[name]

local client= require('sqlr.client')

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
---@param s string|Sqlr.db_vendor
---@return Sqlr.db_vendor?
local function val_env_type(s)
  -- TODO: add sqlite, posgres, duckdb
  if vim.tbl_contains({ 'sqlserver', 'oracle' }, s) then
    ---@type Sqlr.db_vendor
    return s
  end
end

---attempt to find and load the environment based on the provided name
---@param env_name string either filename or absolute path of environment file
---@return Sqlr.env?
local function get_env(env_name)
  local _name = name .. '.get_env'
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

  for _, field in ipairs({ 'type', 'connstring', 'databases' }) do
    assert(env[field], ('%s :: %s does not define required field: %s'):format(_name, file, field))
    assert(vim.fn.empty(env[field]) == 0, ('%s :: %s: %s cannot be empty'):format(_name, file, field))
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
    vim.notify(('%s :: unable to load environment "%s": %s'):format(_name, env_name, env), vim.log.levels.ERROR, {})
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
    end,
    batch_separator = 'GO',
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
    end,
    batch_separator = '/';
  }
}

---create a popup window in which to display lines (start hidden)
---@param buf integer bufffer id
---@param opts? snacks.win.Config
---@returns snacks.win
local function create_popup_window(buf, opts)
  local winopts = {
    style = 'split',
    relative = 'editor',
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
    winopts = vim.tbl_deep_extend('keep', opts or {}, winopts)
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
    local win = M.windows.results or create_popup_window(buf)
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

  local buf = M.buffers.csvview or M.buffers.results
  local win = M.windows.results or create_popup_window(buf)
  win:toggle()

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
  local csvview_opts = {
    view = {
      delimiter = M.opts.col_sep,
      header_lnum = 1,
    }
  }
  if csvview.is_enabled(buf) then
    -- refresh
    csvview.disable(buf)
    csvview.enable(buf, csvview_opts)
  else
    csvview.enable(buf, csvview_opts)
  end
end

---yank the current result-set from the results-csv-view and format it as
---a SELECT statement such as one that can be used for inserting into a table
---TODO: make work for SQL Server (currently only works for PL/SQL)
local function yank_csv_to_select()
  local lines = vim.api.nvim_buf_get_lines(M.buffers.csvview, 0, -1, true)

  local records = vim.tbl_map(function(line)
    return vim.split(line, '\t')
  end, lines)

  local fields = table.remove(records, 1)

  local out_lines = {};
  local function append(line) table.insert(out_lines, line) end
  local indent = '    '
  for i, record in ipairs(records) do
    if #record ~= #fields then
      vim.notify(('line: expected %d fields, got: %d'):format(i+1, #record, #fields), vim.log.levels.ERROR, {})
      return
    end

    -- need to first loop through each record to determine which is the
    -- longest so that I can align the column aliases in the output
    local longest = 0
    for j=1, #record do
      local field = record[j]
      if field == '<nil>' then
        field = 'NULL'
      elseif field == '' then
        field = "''"
      elseif field:match('%D') and not field:match('^%-[[0-9]%.]+') then
        field = ("'%s'"):format(field)
      end
      if #field > longest then longest = #field end
      record[j] = field
    end

    append('SELECT')
    for j, field in ipairs(record) do
      local comma = j == 1 and ' ' or ','
      local fieldname = fields[j]
      local padding = vim.fn['repeat'](' ', longest - #field)
      append(('%s%s%s%s AS %s'):format(indent, comma, field, padding, fieldname))
    end

    local semicolon = i == #records and ';' or ''
    append('FROM DUAL' .. semicolon)
    if semicolon == '' then
      append('UNION ALL')
    end
  end

  assert(0 == vim.fn.setreg('', out_lines, 'l'),
    'failed to insert out_lines into unnamed register')
  vim.notify('Yank: results -> SELECT', vim.log.levels.INFO, {})
end

---perform all of the buffer-specific setup for working with csvview
local function csvview_setup()
  local buf = M.buffers.csvview
  vim.api.nvim_set_option_value('filetype', 'tsv', { scope = 'local', buf = buf })
  vim.api.nvim_buf_set_keymap(M.buffers.csvview, 'n', '<c-y>', '', {
    desc = 'yank results and format as select statement (useful for inserting records into a table)',
    callback = yank_csv_to_select,
  })

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

---convert an array of bytes to hexadecimal string
---@param s string looks like '[191 80 150 109 118 147 67 12 224 83 199 130 189 10 120 144]'
---@return string still a string, but formatted correctly
local function string_to_guid(s)
  local nums = {}
  for num in s:gmatch('%d+') do
    table.insert(nums, tonumber(num))
  end
  local hex = vim.tbl_map(function(d) return string.format('%02X', d) end, nums)
  return string.format('%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s',
    hex[1], hex[2],  hex[3],  hex[4],  hex[5],  hex[6],  hex[7],  hex[8],
    hex[9], hex[10], hex[11], hex[12], hex[13], hex[14], hex[15], hex[16])
end

---render certain values as more human-readible strings
---@param val string
---@return string
local function db_val_to_string(val)
  val = val:gsub('\n', ' ')
  if val:match('^%[[%d ]+%]$') then --possible guid
    local ok, guid = pcall(string_to_guid, val)
    if ok then
      return guid
    end
  end
  return val
end

local function init_buffers()
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

    for _, buf in pairs(M.buffers) do
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
end

---default results-viewer
---@param err string? error message, if any
---@param results Sqlr.QueryResult[]
local function view_results(err, results)
  if err then
    vim.notify('Sqlr: ' .. err, vim.log.levels.ERROR, {})
    return
  end

  if not results then
    return
  end

  init_buffers()

  if not M.windows then
    M.windows = {}
  end

  local results_lines = {}
  local messages_lines = {}
  for _, result in ipairs(results) do
    if result.message and vim.fn.empty(result.message) == 0 then
      for _, line in ipairs(vim.split(result.message, '\n')) do
        table.insert(messages_lines, line)
      end
    end

    if result.error and vim.fn.empty(result.error) == 0 then
      for _, line in ipairs(vim.split(result.error, '\n')) do
        table.insert(messages_lines, 'ERROR: '..line)
      end
    end

    if not result.columns or vim.fn.empty(result.columns) == 1 then
      break
    end

    if #results_lines > 0 then
      table.insert(results_lines, '')
    end

    table.insert(results_lines, table.concat(result.columns, M.opts.col_sep))
    for _, row in ipairs(result.rows) do
      table.insert(results_lines, table.concat(vim.tbl_map(db_val_to_string, row.values), M.opts.col_sep))
    end
  end

  vim.api.nvim_set_option_value('readonly', false, { scope = 'local', buf = M.buffers.results })
  vim.api.nvim_buf_set_lines(M.buffers.results, 0, -1, true, results_lines)
  vim.api.nvim_set_option_value('readonly', true, { scope = 'local', buf = M.buffers.results })

  vim.api.nvim_set_option_value('readonly', false, { scope = 'local', buf = M.buffers.messages })
  vim.api.nvim_buf_set_lines(M.buffers.messages, 0, -1, true, messages_lines)
  vim.api.nvim_set_option_value('readonly', true, { scope = 'local', buf = M.buffers.messages })

  local buf = M.buffers.results
  if #results_lines == 0 and #messages_lines > 0 then
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
  M.results.loclist = vendors[M.env.type].get_results_starting_lines(results_lines)
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

---Parses a range of lines in a buffer into a list of SQL statements using Treesitter.
---@param buf_id integer The buffer ID.
---@param start_line? integer Start line number (1-indexed).
---@param end_line? integer End line number (1-indexed, inclusive).
---@return string[] A list of SQL statements.
local function parse_sql_statements(buf_id, start_line, end_line)
  local parser = vim.treesitter.get_parser(buf_id, 'sql')
  if not parser then
    return {}
  end

  local tree = parser:parse()[1]

  local query = vim.treesitter.query.parse('sql', [[
    (statement) @statement
    (block) @block
    (program) @program
    ]])

  local start_row = start_line and start_line - 1 or 0
  local end_row = end_line and end_line - 1 or vim.api.nvim_buf_line_count(buf_id) - 1

  local results = {}
  for capture_name, node in query:iter_captures(tree:root(), buf_id) do
    local s_row, _, e_row, _ = node:range()

    -- Check if the node is fully contained in the range (end-inclusive)
    local is_node_after_start = start_row <= s_row
    local is_node_before_end = end_row >= e_row
    if is_node_after_start and is_node_before_end then
      table.insert(results, {
        node = node,
        capture_name = capture_name,
      })
    end
  end

  -- Remove results that are contained inside of other results.  Loop backwards.
  for i = #results, 1, -1 do
    local current_node = results[i].node
    local current_s_row, _, current_e_row, _ = current_node:range()

    for j = i - 1, 1, -1 do
      local other_node = results[j].node
      local other_s_row, _, other_e_row, _ = other_node:range()

      --If the "other" node completely contains the "current" node, remove the "current" node
      if other_s_row <= current_s_row and other_e_row >= current_e_row then
        table.remove(results, i)
        break
      end
    end
  end

  local statements = {}
  for i = 1, #results do
    local node = results[i].node
    local s_row, s_col, e_row, e_col = node:range()

    local text = vim.api.nvim_buf_get_text(buf_id, s_row, s_col, e_row, e_col, {})
    local trimmed_lines = vim.tbl_map(function(s)
      local rtrimmed = (s:gsub('%s*%-%-.*$', ''))
      local ltrimmed = (rtrimmed:gsub('^%s*', ''))
      return ltrimmed
    end, text)
    local statement_text = table.concat(trimmed_lines, ' ')
    table.insert(statements, statement_text)
  end
  return statements
end

---lookup the given env/database from opts or fallback to currently selected
---@param opts Sqlr.run_opts
---@return Sqlr.env environment
---@return string database
local function get_exec_env(opts)
  local _name = name..'.get_exec_env'
  ---@type Sqlr.env, string
  local env, db = M.env, M.db
  if opts.env then
    local ok, _env
    ok, _env = pcall(get_env, opts.env)
    assert(ok, ('%s :: unable to load environment "%s": %s'):format(_name, opts.env, _env))
    env = assert(_env, ('failed to load environment: %s'):format(opts.env))
    db = opts.db or env.databases[1]
  end
  return env, db
end

---run sql and display results; can be supplied as:
--- - a string (expected to contain only one statement)
--- - a list of strings (lines, in that case)
--- - a range of lines (start, end) of the current buffer
--- - the current visual selection (NOTE: whole lines will always be selected)
---@param opts Sqlr.run_opts?
---@param s? string|integer sql or start of range
---@param e? integer end of range
function M.run(opts, s, e)
  local _name = name .. '.run'

  opts = vim.tbl_deep_extend('keep', opts or {}, {
    callback = view_results
  })

  ---@type Sqlr.env, string
  local env, db = get_exec_env(opts)

  assert(env, 'Environment not set')
  assert(db,  'Database not set')

  local statements
  if s then
    if type(s) == 'string' then
      vim.notify(('%s :: passed sql as string'):format(_name), vim.log.levels.TRACE, {})
      statements = { (s:gsub('\n', '\r')) }
    else
      vim.notify(('%s :: passed range'):format(_name), vim.log.levels.TRACE, {})
      if not e or e == -1 then
        e = vim.api.nvim_buf_line_count(0)
      end
      statements = parse_sql_statements(0, s, e)
    end
  else -- get range from visual selection
    vim.notify(('%s :: determining sql from visual selection'):format(_name), vim.log.levels.TRACE, {})

    -- leave visual mode so that '< and '> get set
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<esc>', true, false, true),
      'itx',
      false)

    s = vim.api.nvim_buf_get_mark(0, '<')[1]
    e = vim.api.nvim_buf_get_mark(0, '>')[1]
    assert(s > 0, '< mark not set')
    assert(e > 0, '> mark not set')

    statements = parse_sql_statements(0, s-1, e)
  end

  assert(statements and #statements > 0, 'No statements provided/found')

  local data = table.concat(statements, '\n')
  M.client
    :connect(env, db)
    :send(data, opts.callback)
    -- :send(data, function(err, results) dd { err, results } end)
    --[[
    :send(data, function(err, results)
        dd { err, results }
        opts.callback(err, results)
      end)
    --]]
end

local function default_exec_callback(err, results)
  if err then
    vim.notify('Sqlr: ' .. err, vim.log.levels.ERROR, {})
    return
  end

  if not results then
    vim.notify('Executed Successfully', vim.log.levels.INFO, {})
    return
  end

  local messages_lines = {}
  for _, result in ipairs(results) do
    if result.message and vim.fn.empty(result.message) == 0 then
      for _, line in ipairs(vim.split(result.message, '\n')) do
        table.insert(messages_lines, line)
      end
    end

    if result.error and vim.fn.empty(result.error) == 0 then
      for _, line in ipairs(vim.split(result.error, '\n')) do
        table.insert(messages_lines, 'ERROR: '..line)
      end
    end
  end

  if #messages_lines == 0 then
    vim.notify('Executed Successfully', vim.log.levels.INFO, {})
    return
  end

  init_buffers()

  if not M.windows then
    M.windows = {}
  end

  vim.api.nvim_set_option_value('readonly', false, { scope = 'local', buf = M.buffers.messages })
  vim.api.nvim_buf_set_lines(M.buffers.messages, 0, -1, true, messages_lines)
  vim.api.nvim_set_option_value('readonly', true, { scope = 'local', buf = M.buffers.messages })

  if not M.windows.results then
    M.windows.results = create_popup_window(M.buffers.messages)
  end

  vim.notify(('%s :: Showing Messages'):format(name), vim.log.levels.INFO, {})
  M.toggle_results('messages')
  print('Showing Messages')
end

---execute sql (expecting no results); can be supplied as:
--- - a string (expected to contain only one statement)
--- - a list of strings (lines, in that case)
--- - a range of lines (start, end) of the current buffer
--- - the current visual selection (NOTE: whole lines will always be selected)
---@param opts Sqlr.run_opts?
---@param s? string|integer sql or start of range
---@param e? integer end of range
function M.exec(opts, s, e)
  local _name = name .. '.run'

  opts = vim.tbl_deep_extend(
    'keep',
    opts or {},
    { callback = default_exec_callback }
  )

  ---@type Sqlr.env, string
  local env, db = get_exec_env(opts)

  assert(env, 'Environment not set')
  assert(db,  'Database not set')

  local lines
  if s then
    if type(s) == 'string' then
      vim.notify(('%s :: passed sql as string'):format(_name), vim.log.levels.TRACE, {})
      lines = { (s:gsub('\n', '\r')) }
    elseif type(s) == 'table' then
      lines = s
    else
      vim.notify(('%s :: passed range'):format(_name), vim.log.levels.TRACE, {})
      if not e or e == -1 then
        e = vim.api.nvim_buf_line_count(0)
      end
      lines = vim.api.nvim_buf_get_lines(0, s, e, true)
    end
  else -- get range from visual selection
    vim.notify(('%s :: determining sql from visual selection'):format(_name), vim.log.levels.TRACE, {})

    -- leave visual mode so that '< and '> get set
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<esc>', true, false, true),
      'itx',
      false)

    s = vim.api.nvim_buf_get_mark(0, '<')[1]
    e = vim.api.nvim_buf_get_mark(0, '>')[1]
    assert(s > 0, '< mark not set')
    assert(e > 0, '> mark not set')

    lines = vim.api.nvim_buf_get_lines(0, s-1, e, true)
  end

  assert(lines and #lines > 0, 'No sql provided')

  -- wrap the message in \x02 and \x03 to tell the server to execute all
  -- of the lines as one, instead of executing statement-by-statement
  local batch_separator = vendors[env.type].batch_separator
  local data
  if batch_separator then
    --emulate SSMS and Oracle SQL Developer behavior of using tokens
    --like 'GO' and '/' to separate batches in the same script/worksheet
    batch_separator = '^%s*' .. batch_separator .. '%s*$'
    local batches = {}
    local batch = ''
    for _, line in ipairs(lines) do
      if line:match(batch_separator) then
        table.insert(batches, '\x02\n' .. batch .. '\x03')
        batch = ''
      else
        batch = batch .. line .. '\n'
      end
    end
    if #batch > 0 then
      table.insert(batches, '\x02\n' .. batch .. '\x03')
    end
    data = table.concat(batches, '')
  else
    data = '\x02\n' .. table.concat(lines, '\n') .. '\x03'
  end

  M.client
    :connect(env, db)
    :send(data, opts.callback)
    -- :send(data, function(err, results) dd { err, results } end)
    --[[
    :send(data, function(err, results)
        dd { err, results }
        opts.callback(err, results)
      end)
    --]]
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
  connections = function()
    local names = {}
    for k, _ in pairs(M.client.connections) do
      table.insert(names, k)
    end
    return names
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

  vim.api.nvim_buf_create_user_command(0, 'SqlrConnectionReset',
    function(opts)
      if not M.client then return end

      local cname = vim.trim(opts.args or '')
      if not cname or cname == '' then return end

      local conn = M.client.connections[cname]
      if not conn then return end

      conn:disconnect()
      conn.is_processing = false
      conn.queue = {}
      conn:connect()
      conn:process_request() -- since we cleared the queue, this will stop the spinner
    end,
    {
      desc = 'Reset the given connection (cancelling all queued queries if any)',
      nargs = 1,
      complete = completion_functions.connections,
    })

  vim.api.nvim_buf_create_user_command(0, 'SqlrRestartServer',
    function()
      if not M.client then return end
      if not M.client.process then
        vim.notify('Unable to stop sqlrepl server process (is it running locally?)')
        return
      end

      vim.notify('SQLR: Stopping Server', vim.log.levels.INFO, {})
      M.client:stop_server()

      for _, conn in pairs(M.client.connections) do
        conn:disconnect()
        conn.is_processing = false
        conn.queue = {}
        conn:process_request() -- since we cleared the queue, this will stop the spinner
      end

      M.client = client.Client.new(M.opts.client)
      vim.notify('SQLR: Server Restarted', vim.log.levels.INFO, {})
    end,
    {
      desc = 'Restart the sqlrepl server (only works if running locally)',
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

  M.client = client.Client.new(opts.client or {})

  return M
end

--@type Sqlr
return M
