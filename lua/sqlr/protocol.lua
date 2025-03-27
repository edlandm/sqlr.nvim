local pb = require('pb')
local protoc = require('protoc')
local p = protoc.new()
local script_dir = debug.getinfo(1).source:match("@?(.*/)") or ""
p:loadfile(script_dir .. 'sqlrepl.proto')

local M = {}

---attempt to parse binary data into a QueryResult
---@param data string
---@return Sqlr.QueryResult
function M.parse_result(data)
  return pb.decode('protocol.QueryResult', data)
end

return M
