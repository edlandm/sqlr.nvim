---@meta

---@alias path string string representing a file path
---@alias results_mode 'results' | 'messages' | 'csvview'

---@class Sqlr.opts
---@field env_dir path directory containing env files
---@field col_sep string character that separates columns in command output
-- TODO: add 'csvlens'
---@field viewer 'text' | 'csvview' | fun(err:string?, results:Sqlr.QueryResult[])
---@field win? snacks.win.Config
---@field client? Sqlr.Client.opts configuration for the client that talks to sqlrepl

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
---@field connstring string|fun(self:Sqlr.env):string database connection string or function that creates it
---@field databases string[] list of databases (first in list will be connected by default)

---@class Sqlr.run_opts
---@field callback? fun(err:string?, output?:Sqlr.QueryResult[])
---@field env? string name or absolute path of environment file
---@field db? string name of database (must be valid db for environment)
---@field silent? boolean enable to not echo status

---@class Sqlr.Client.opts
---@field port? integer port that the sqlrepl server is running on
---@field host? string hostname of remote server (leave nil if running locally)
---@field path? string path after host:port if behind a reverse proxy
---@field bin?  string path to binary (if running locally and not in $PATH)
---@field log?  string path to log file

---@class Sqlr.Client
---@field opts Sqlr.Client.opts
---@field setup fun(opts?:Sqlr.Client.opts)
---@field pid? integer process-id of sqlrepl server
---@field connections table<string, Sqlr.Client.Connection>
---@field get_server_pid fun(self:Sqlr.Client):integer?
---@field start_server fun(self:Sqlr.Client):integer?
---@field connect fun(self:Sqlr.Client, env:Sqlr.env, db:string, initial_statements?:string[]):Sqlr.Client.Connection
---@field disconnect fun(self:Sqlr.Client, env:Sqlr.env, db:string)
---@field send fun(self:Sqlr.Client, env:Sqlr.env, db:string, callback: fun(err:string?, output?:Sqlr.QueryResult[]))

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
---@field client Sqlr.Client the client that manages connections to environments/databases
