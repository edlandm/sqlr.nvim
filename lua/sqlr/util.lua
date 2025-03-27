local M = {}

function M.debug(msg)
  vim.notify(msg, vim.log.levels.DEBUG, {})
end

function M.info(msg)
  vim.notify(msg, vim.log.levels.INFO, {})
end

function M.error(msg)
  vim.notify(msg, vim.log.levels.ERROR, {})
end

return M
