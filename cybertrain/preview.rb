# The CRuby preview: the framework's own files run under CRuby instead of the
# Spinel-compiled binary, so a change can be tried without a compile. Loaded
# with `ruby -E UTF-8 -r cybertrain/preview ...`. CRuby only: nothing the
# compiler sees (cybertrain.rb, cybertrain/cli.rb, ...) may require it.
#
# What it adds is the `ffi_*` DSL on Module (cybertrain/preview/ffi.rb), which
# Spinel provides natively and which the SQLite, gzip and re-exec files use,
# the C compiler step behind it (ffi_library.rb), and the failure file the dev
# supervisor reads (failure.rb).

begin
  require "fiddle"
rescue LoadError
  raise LoadError, "the CRuby preview needs the fiddle library (it is a bundled gem since Ruby 3.5: gem install fiddle)"
end

module Cybertrain
  module Preview
    CACHE_SUBDIRECTORY = File.join("tmp", "cybertrain-dev", "ffi")

    # Where compiled FFI libraries are kept: under the current directory, so a
    # project's cache goes with the project. Created on demand, 0700, by
    # FFILibrary.build, which also refuses one another user owns or may
    # write to.
    def self.cache_dir
      File.join(Dir.pwd, CACHE_SUBDIRECTORY)
    end
  end
end

require "cybertrain/preview/ffi_library"
require "cybertrain/preview/ffi"
require "cybertrain/preview/failure"

Cybertrain::Preview::Failure.install!
