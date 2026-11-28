# cybertrain/db: the database layer with the SQLite adapter (the entry every
# SQLite application and test has always required). The adapter-independent
# part is cybertrain/db/base; an adapter's entry, not a core file, names the
# adapter (script/check-db-adapter).
require "cybertrain/db/base"
require "cybertrain/db/sqlite"
