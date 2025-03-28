local socket = require('socket')
local json = require('rxi-json-lua')
local protocol = require('sqlr.protocol')

---@alias tcp.connection table value returned from socket.tcp():connect()
---@alias Sqlr.QueryResult.Row { values:string[] }

---@class Sqlr.QueryResult
---@field columns string[]
---@field rows Sqlr.QueryResult.Row[]
---@field message string
---@field error string

---@class Sqlr.Client.Connection
---@field host string hostname of database server
---@field port integer port for db connection
---@field dbtype db_vendor
---@field connstring string string
---@field queue [string, function][] queue of sql+callback tuples
---@field _conn tcp.connection
---@field is_processing boolean
---@field spinner? table field to hold the fidget spinner handle (if using)
--- methods
---@field new fun(host:string, port:integer, dbtype:db_vendor, connstring:string):Sqlr.Client.Connection
---@field connect fun(self:Sqlr.Client.Connection):Sqlr.Client.Connection returns tcp socket connection, sets self._conn
---@field disconnect fun(self:Sqlr.Client.Connection)
---@field send fun(self:Sqlr.Client.Connection, sql:string, callback: fun(err: string?, results:Sqlr.QueryResult[]))

local Connection = {}
Connection.__index = Connection

function Connection.new(host, port, dbtype, connstring)
  local self = setmetatable({}, Connection)
  self.host = host
  self.port = port
  self.dbtype = dbtype
  self.connstring = connstring
  self.queue = {}
  return self
end

function Connection:connect()
  if not self._conn then
    local conn = socket.tcp()
    local ok, err = conn:connect(self.host, self.port)
    assert(ok,
      ('Connection :: unable to connect to %s:%d - %s'):format(self.host, self.port, err))

    -- Construct the JSON request for DBParams
    local db_params = {
      dbtype = self.dbtype,
      connstring = self.connstring,
    }
    local params_json = json.encode(db_params)
    conn:send(params_json .. '\n')

    conn:settimeout(0) -- make non-blocking
    self._conn = conn
  end
  return self
end

---read exactly `n` bytes from socket
---@param conn tcp.connection
---@param n integer
---@return string? error
---@return string data that was read
local function read_bytes(conn, n)
  local data = ''
  while #data < n do
    local chunk, err = conn:receive(n - #data)
    if data == '' and err == 'timeout' then
      return err, data
    end
    if not chunk then
      return 'Failed to read data', data
    end
    data = data..chunk
  end
  return nil, data
end

---convert 4 bytes (big-endian) to a number
---@param bytes string
---@return integer
local function bytes_to_number(bytes)
  local n = 0
  for i = 1, #bytes do
    n = n * 256 + string.byte(bytes,i)
  end
  return n
end

---read 4 bytes from the socket to get the length of the next result object
---@param conn tcp.connection
---@return string? error
---@return integer? length of bytes in the response
local function read_length_bytes(conn)
  local err, length_bytes = read_bytes(conn, 4)
  if err then
    if err == 'timeout' then
      return
    end
    return err, nil
  elseif not length_bytes then
    return 'Failed to read length prefix', nil
  end
  return nil, bytes_to_number(length_bytes)
end

---send `sql` to the server in background process, `callback` handles response/error
---@param sql string
---@param callback fun(err: string?, results:Sqlr.QueryResult[])
function Connection:send(sql, callback)
  local name = 'Connection:send'
  assert(sql, ('%s :: sql required'):format(name))
  assert(callback, ('%s :: callback required'):format(name))

  table.insert(self.queue, { sql, callback })
  if not self.is_processing then
    self:process_request()
  end
end

local function start_spinner(conn)
  local ok, progress = pcall(require, 'fidget.progress')
  if not ok then
    vim.notify('SQLR :: Running SQL...', vim.log.levels.INFO)
    return
  end

  conn.spinner = progress.handle.create({
    message = 'Running SQL...',
    lsp_client = { name = 'SQLR.'..conn.dbtype },
  })
end

local function stop_spinner(conn)
  if not conn.spinner then return end
  conn.spinner:finish()
  conn.spinner = nil
end

function Connection:process_request()
  local name = 'Connection:process_request'
  if #self.queue == 0 then
    self.is_processing = false
    stop_spinner(self)
    return
  end

  self.is_processing = true
  start_spinner(self)

  local sql, callback = unpack(table.remove(self.queue, 1))

  if not self._conn then
    self:connect()
  end

  local conn = assert(self._conn, ('%s :: Unable to connect to server'):format(name))
  -- use char(29) (group separator) to signal end of batch
  conn:send(('%s\n%s\n'):format(sql, string.char(29)))

  local timer = vim.uv.new_timer()

  vim.notify(('%s :: request sent, awaiting response'):format(name), vim.log.levels.TRACE, {})
  local results = {}
  local function await_response()
    local err, length_bytes = read_length_bytes(conn)
    if not err and not length_bytes then -- server has not responded yet
      return
    elseif err then
      vim.notify(('%s :: %s'):format(name, err), vim.log.levels.TRACE, {})
      timer:stop()
      return
    end

    while length_bytes do
      local result
      err, result = read_bytes(conn, length_bytes)
      if err then
        vim.notify(('%s :: %s'):format(name, err), vim.log.levels.TRACE, {})
        timer:stop()
        callback(err, nil)
        self:process_request()
        return
      end

      vim.notify(('%s :: read %d bytes, got: %s'):format(name, length_bytes, result), vim.log.levels.TRACE, {})
      if length_bytes == 1 and result == string.char(29) then -- end of batch
        vim.notify(('%s :: end of batch'):format(name, length_bytes, result), vim.log.levels.TRACE, {})
        timer:stop()
        local _results = vim.tbl_map(protocol.parse_result, results)
        callback(nil, _results)
        self:process_request()
        return
      end

      table.insert(results, result)
      err, length_bytes = read_length_bytes(conn)
    end
  end

  timer:start(0, 200, vim.schedule_wrap(await_response))
end

function Connection:disconnect()
  if self._conn then
    self._conn:close()
    self._conn = nil
  end
  -- clear queue so that if we reconnect we don't start-up with any surprises
  self.queue = {}
end

return Connection
