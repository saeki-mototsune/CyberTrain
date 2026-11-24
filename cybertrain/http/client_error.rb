# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/client_error and the Cybertrain:: names of
# spinel-http/client_error.rb as constant aliases (the same class objects).
require "spinel-http/client_error"
require "cybertrain/http/extra_faults"
require "cybertrain/http/query"
require "cybertrain/http/response"
