require "digest"
require "fiddle"
require "open3"
require "rbconfig"

module Cybertrain
  module Preview
    # The C compiler failed on an ffi_source; the message is its output.
    # Assigned, not a `class ... Error <` line: test/gen_jobs.rb lists the
    # Error classes under cybertrain/ by reading the sources, and
    # Gen::JobScan::FRAMEWORK_ERRORS names the ones a compiled program has.
    # This one exists only under CRuby.
    CompileError = Class.new(StandardError)

    # Compiles C source into a shared library and keeps it by content, so a
    # restart of the dev server does not pay for the compiler again.
    module FFILibrary
      @built = 0

      # How every library is compiled (the output and the -l flags follow).
      FLAGS = ["-shared", "-fPIC", "-O2"].freeze

      class << self
        # How many libraries this process has compiled (not found cached).
        attr_reader :built

        # Path of the shared library for `source` linked against `libs` (names
        # as `ffi_lib` takes them, "sqlite3" for -lsqlite3). It is
        # <cache_dir>/<digest>.so, the digest covering the source, the
        # libraries, the compiler's own version line, FLAGS and the
        # machine's architecture (a project directory shared by two
        # machines), so changing any of them compiles again; an existing
        # file is returned as it is (open_library checks that it loads).
        def build(source, libs, cache_dir)
          path = File.join(cache_dir, "#{key(source, libs)}.so")
          return path if File.exist?(path)

          # Compiled to a name of its own and renamed, so two processes
          # starting together never load a half-written library.
          partial = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
          command = [compiler, *FLAGS, "-x", "c", "-", "-o", partial, *libs.map { |name| "-l#{name}" }]
          begin
            output, status = Open3.capture2e(*command, stdin_data: source)
          rescue Errno::ENOENT => e
            raise CompileError, "the C compiler #{compiler} could not be run: #{e.message}"
          end
          unless status.success?
            File.delete(partial) if File.exist?(partial)
            raise CompileError, "#{command.join(' ')} failed:\n#{output}"
          end
          File.rename(partial, path)
          @built += 1
          path
        end

        # The library for `source`, built (or found) and opened. A cached
        # file that cannot be loaded (damaged, or another machine's) is
        # removed and built once more; if that one does not load either,
        # Fiddle's error is raised.
        # @return [Fiddle::Handle]
        def open_library(source, libs, cache_dir)
          path = build(source, libs, cache_dir)
          begin
            return Fiddle.dlopen(path)
          rescue Fiddle::DLError
            File.delete(path) if File.exist?(path)
          end
          Fiddle.dlopen(build(source, libs, cache_dir))
        end

        private

        def compiler
          ENV["CC"] || "cc"
        end

        def compiler_version
          @compiler_version ||= begin
            output, = Open3.capture2e(compiler, "--version")
            output.lines.first.to_s.strip
          rescue Errno::ENOENT
            ""
          end
        end

        def key(source, libs, version = compiler_version, arch = RbConfig::CONFIG["arch"])
          Digest::SHA256.hexdigest([source, libs.join(","), version, FLAGS.join(" "), arch].join("\0"))
        end
      end
    end
  end
end
