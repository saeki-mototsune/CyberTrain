# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/query and the Cybertrain:: names of
# spinel-http/query.rb as constant aliases (the same class objects).
require "spinel-http/query"
require "cybertrain/http/params"

module Cybertrain
  Query = SpinelHttp::Query
  QueryInvalid = SpinelHttp::QueryInvalid
  QueryLimitExceeded = SpinelHttp::QueryLimitExceeded
  QueryTooDeep = SpinelHttp::QueryTooDeep
  QueryTooMany = SpinelHttp::QueryTooMany
  QueryMalformed = SpinelHttp::QueryMalformed
end
