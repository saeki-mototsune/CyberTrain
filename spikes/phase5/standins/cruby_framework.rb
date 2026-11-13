# Phase 5b spike: what lets CRuby run thread_scope.rb and error_names.rb,
# whose `require "cybertrain"` loads SQLite and zlib through Spinel's FFI
# (`ffi_lib`, which CRuby has not). Loaded with `ruby -r`: it requires the
# framework files CRuby can load, stands in for the DB pool (a transaction
# that holds a connection under the pool's Thread.current key),
# Job.handle, Lease.release and Stream::Poller.last_id, and marks the files
# it replaces as loaded so the spike's own requires do nothing. A record,
# not the framework's code.
require "json"
require "cybertrain/version"
require "cybertrain/logger"
require "cybertrain/config"
require "cybertrain/i18n"
require "cybertrain/template/parser"
require "cybertrain/cli/toolchain"
require "cybertrain/websocket"
require "cybertrain/stream/hub"

module Cybertrain
  module DB
    module Pool
      TRANSACTION_KEY = :cybertrain_db_transaction
    end

    class Error < StandardError; end

    # Answers [] and, for SQL that does not start with a keyword SQLite
    # knows (the spike's "SELEC 1"), raises as Connection#error_message words it.
    class FakeConnection
      def execute(sql, _binds = [])
        raise Error, "near \"SELEC\": syntax error (sql: #{sql})" if sql.start_with?("SELEC ")

        []
      end
    end

    def self.connect(_path, size: 4) = nil

    def self.with
      yield FakeConnection.new
    end

    def self.transaction
      conn = FakeConnection.new
      Thread.current[Pool::TRANSACTION_KEY] = conn
      yield conn
    ensure
      Thread.current[Pool::TRANSACTION_KEY] = nil
    end
  end

  module Job
    KINDS = []

    def self.handle(kind, concurrency: 0, &_block)
      KINDS << kind
      nil
    end

    def self.handler_index(kind) = KINDS.index(kind) || -1
  end

  module Lease
    def self.release(_name, _holder) = nil
  end

  module Stream
    module Poller
      def self.last_id = 0
    end
  end
end

%w[cybertrain cybertrain/lease].each do |name|
  $LOADED_FEATURES << File.expand_path("../../../#{name}.rb", __dir__)
end
