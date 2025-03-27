local name = 'sqlr.client'
local M = {}

local util = require('sqlr.util')
local debug, _error = unpack({util.debug, util.error})

local Connection = require('sqlr.connection')

---attempt to get the pid of the running sqlrepl instance
---returns the pid if one found, returns an error message if there was
---a problem running `lsof` (but no error message if the process ran correctly
---but simply didn't find anything)
---@param port integer
---@return integer?
---@return string?
function M.get_server_pid(port)
  if vim.fn.executable('lsof') == 0 then
    return nil, "`lsof` required"
  end

  local command = "lsof -t -i:" .. assert(port, 'port required')
  local handle = io.popen(command)
  if not handle then
    return nil, "Failed to execute lsof"
  end

  local output = handle:read("*l") -- we only care about the first line
  local return_code = handle:close()

  if return_code then
    -- lsof returns 1 if no matching files are found
    if return_code == 1 then
        return nil, nil
    else
        return nil, "lsof exited with error code: " .. tostring(return_code)
    end
  end

  local pid = tonumber(output)
  if pid then
    debug(('sqlrepl process found. pid: %d'):format(pid))
    return pid, nil
  else
    return nil, nil
  end
end

local Client = {}
Client.__index = Client

---instantiate a new client connected to a sqlrepl server
---@param opts Sqlr.Client.opts
---@return Sqlr.Client
function Client.new(opts)
  local self = setmetatable({}, Client)

  self.opts = vim.tbl_deep_extend('keep', opts or {}, {
    host = 'localhost',
    port = 8080,
    path = '',
    bin  = 'sqlrepl',
    log  = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqlr', 'log.client.txt'),
  })

  if self.opts.host == 'localhost' then
    local pid = M.get_server_pid(self.opts.port)
    if pid then
      self.process = { pid=pid }
    else
      pid = assert(self:start_server(), ('unable to start %s server'):format(self.opts.bin))
    end
  end

  self.connections = {}

  return self
end

---write msg to logfile
---@param msg string
function Client:log(msg)
  local logdir = vim.fn.fnamemodify(self.opts.log, ':h')
  if not vim.uv.fs_stat(logdir) then
    if not pcall(vim.uv.fs_mkdir, logdir) then
      _error(('% :: Unable to make client log-directory: %s'):format(name, logdir))
      return
    end
  end

  local file, err = io.open(self.opts.log, 'w')
  if err then
    _error(('%s :: Unable to open client logfile for writing: %s'):format(name, err))
  end
  assert(file, ('%s :: Unable to open client logfile for writing'):format(name))

  file:write(msg)
  file:close()
end

---start the sqlrepl server
---@return integer pid of server process
function Client:start_server()
  local pname = vim.fn.fnamemodify(self.opts.bin, ':t:r')
  local port = self.opts.port

  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  local handle, pid, err = vim.uv.spawn(self.opts.bin,
    {
      args = { '-p', port },
      stdio = { nil, stdout, stderr },
    },
    function(code, signal)
      self.process = nil
      self:log(('%s exited with code: %d, signal: %s'):format(pname, code, signal))
    end)

  vim.uv.read_start(stdout, function(_err, data)
    if _err then
      self:log(('ERROR: %s.stdout :: %s'):format(pname, _err))
    else
      self:log(('%s.stdout :: %s'):format(pname, data))
    end
  end)

  vim.uv.read_start(stderr, function(_err, data)
    if _err then
      self:log(('ERROR: %s.stderr :: %s'):format(pname, _err))
    else
      self:log(('%s.stderr :: %s'):format(pname, data))
    end
  end)

  assert(handle, ('unable to spawn %s: %s'):format(pname, err or 'unknown error'))

  -- make sure to clean up after ourselves if we start the server
  vim.api.nvim_create_autocmd('VimLeave', {
    callback = function() vim.uv.process_kill(handle) end
  })

  self.process = { handle=handle, pid=pid }

  local msg = ('%s :: %s server started, listening on %d'):format(name, pname, port)
  debug(msg)
  self:log(msg)

  return assert(tonumber(pid), ('%s :: start_server: unable to parse pid into number: %s'):format(name, pid))
end

---start a connection for a given env/db
---@param env Sqlr.env
---@param db string
---@param initial_statements? string[] list of statements to run upon connecting (will only be run once when first connecting)
---@return Sqlr.Client.Connection
function Client:connect(env, db, initial_statements)
  local _name = 'Client:connect'
  assert(env, ('%s :: env required'):format(_name))
  assert(db, ('%s :: db required'):format(_name))

  local key = ('%s:%s'):format(env.name, db)
  local conn = self.connections[key]
  if conn then
    return conn
  end

  local connstring = type(env.connstring) == 'function' and env:connstring() or env.connstring
  conn = Connection.new(
    self.opts.host,
    self.opts.port,
    env.type,
    connstring:gsub('%{DATABASE%}', db))
  self.connections[key] = conn:connect()

  if initial_statements and #initial_statements > 0 then
    -- use internal tcp client directly because we don't need a callback here
    conn._conn:send(table.concat(initial_statements, '\n')..'\n')
  end

  return conn
end

---close a connection for a given env/db
---@param env Sqlr.env
---@param db string
function Client:disconnect(env, db)
  local _name = 'Client:disconnect'
  assert(env, ('%s :: env required'):format(_name))
  assert(db, ('%s :: db required'):format(_name))

  local key = ('%s:%s'):format(env.name, db)
  local conn = self.connections[key]
  if conn then
    conn:disconnect()
    self.connections[key] = nil
  end
end

---send sql to be evaluated run in a given env/db
---@param env Sqlr.env
---@param db string
---@param sql string
---@param callback fun(err:string?, output:Sqlr.QueryResult[])
function Client:send(env, db, sql, callback)
  local _name = 'Client:send'
  assert(env, ('%s :: env required'):format(_name))
  assert(db, ('%s :: db required'):format(_name))
  assert(sql, ('%s :: sql required'):format(_name))
  assert(callback, ('%s :: callback required'):format(_name))

  local key = ('%s:%s'):format(env.name, db)
  local conn = self.connections[key] or self:connect(env, db)
  conn:send(sql, callback)
end

M.Client = Client

return M
