---@meta

---@alias path string a string representing a filepath (/forward/slash)
---@alias cmd_output { stdout:string[], stderr:string[] }
---@alias results_mode 'results' | 'messages' | 'csvview'


---@class Sqlr.opts
---@field env_dir path directory containing env files
---@field col_sep string character that separates columns in command output
-- TODO: add 'csvlens'
---@field viewer 'text' | 'csvview' | fun(err:string?, results:cmd_output?)
---@field win? snacks.win.Config

-- TODO: add sqllite, duckdb, posgres
---@alias db_vendor 'sqlserver' | 'oracle' supported databases

---@class Sqlr.db_vendor
---return location list entries of the positions of each resultset start
---@field get_results_starting_lines fun(results_lines:string[]):table[]}
---this function may have side-effects, such as moving the cursor
---@field csview_pre_set_cursor? fun(s:integer, e:integer, lines:string[]):string[]}
---@field parse_errors? fun(output:{stdout:string[], stderr:string[]}):{stdout:string[], stderr:string[]}

---@class Sqlr.env
---@field name string name to use for identifying/logging/caching purposes
---@field type Sqlr.db_vendor
---@field host string server hostname
---@field port? integer port to connect on (only necessary if different from default; not used for sqlserver)
---@field user string user to connact to database as
---@field password string | fun(env:Sqlr.env):string db-user's password (or function that returns it)
---@field databases string[] list of databases (first in list will be connected by default)
---@field cmd? fun(env:Sqlr.env, db:string, lines:string[], opts:Sqlr.opts):string[]

---@class Sqlr.run_opts
---@field callback? fun(err:string?, output?:cmd_output)
---@field env? string name or absolute path of environment file
---@field db? string name of database (must be valid db for environment)
---@field silent? boolean enable to not echo status
---@field noerror boolean enable to not return error messages from sqlserver

---@class Sqlr
---@field set_env fun(env:string) set the environment to run queries against
---@field set_db fun(db:string) set the database to run queries against
---@field pick_env fun() use snacks.picker to set the environment
---@field pick_db fun() use snacks.picker to set the current database
---@field toggle_results fun(mode:results_mode) display results window
---@field run fun(sql:string|string[], opts:Sqlr.run_opts) run the given sql
---@field run fun(s:integer, e:integer, opts:Sqlr.run_opts) run indicated lines (current buffer) as sql
---@field run fun(opts:Sqlr.run_opts) run visual selection as sql
---@field run fun(arg1:string|integer|Sqlr.run_opts, arg2?: Sqlr.run_opts|integer, arg3?: Sqlr.run_opts?) run sql
