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

    # The cache of compiled libraries is not safe to load from: another
    # user owns the directory, or a group or others may write to it.
    # Assigned for the same reason as CompileError.
    CacheError = Class.new(StandardError)

    # Compiles C source into a shared library and keeps it by content, so a
    # restart of the dev server does not pay for the compiler again.
    #
    # A cached library is loaded into the developer's process with
    # Fiddle.dlopen, which runs its code, so nothing is loaded from the
    # cache unless the directory and the file belong to this process's
    # effective user and neither is writable by its group or others
    # (decision P26 of docs/superpowers/plans/2026-11-12-cruby-preview-plan.md).
    # A missing directory is made 0700, a new library is written 0700 (read
    # for dlopen, and the execute bit cc gives a shared object). A directory
    # that fails the check is an error that names it and what is wrong, and
    # nothing is compiled elsewhere instead: under the dev server the child
    # then fails to boot (its first SQLite call loads a library) and the
    # supervisor's 503 page shows the message. A file that fails, in a
    # directory that passed, is removed and compiled once more. The check
    # reads the owner and the mode bits, which Linux and macOS (the
    # platforms the framework targets) both have.
    module FFILibrary
      @built = 0

      # How every library is compiled (the output and the -l flags follow).
      FLAGS = ["-shared", "-fPIC", "-O2"].freeze

      # The mode of a directory this module creates and of a library it
      # writes: the owner's alone.
      DIRECTORY_MODE = 0o700
      LIBRARY_MODE = 0o700

      # The mode bits that let a group or others write.
      SHARED_WRITE = 0o022

      class << self
        # How many libraries this process has compiled (not found cached).
        attr_reader :built

        # Path of the shared library for `source` linked against `libs` (names
        # as `ffi_lib` takes them, "sqlite3" for -lsqlite3). It is
        # <cache_dir>/<digest>.so, the digest covering the source, the
        # libraries, the compiler's own version line, FLAGS and the
        # machine's architecture (a project directory shared by two
        # machines), so changing any of them compiles again; an existing
        # file that passes the ownership check is returned as it is
        # (open_library checks that it loads); one that does not is removed
        # and compiled again. The directory is created when missing and must
        # pass the check itself (CacheError otherwise).
        def build(source, libs, cache_dir)
          secure_directory(cache_dir)
          path = File.join(cache_dir, "#{key(source, libs)}.so")
          stat = begin
            File.stat(path)
          rescue Errno::ENOENT
            nil
          end
          return path if stat && problem(stat).nil?

          # Ours to remove: the directory passed, so it is this user's and
          # nobody else can have put the file there or replace it now.
          File.delete(path) if stat
          compile(source, libs, path)
          unsafe = problem(File.stat(path))
          raise CacheError, "#{path} #{unsafe} right after it was compiled; the CRuby preview does not load it" if unsafe

          path
        end

        # Creates `dir` when it is missing (0700; its parents as the umask
        # makes them, since only this last directory holds what is loaded),
        # then raises CacheError unless it is this user's alone. An existing
        # directory is never chmod-ed: what it holds was written while it
        # was open to others, so the developer decides, and the message
        # says how.
        def secure_directory(dir)
          unless File.directory?(dir)
            require "fileutils"
            FileUtils.mkdir_p(File.dirname(dir))
            begin
              Dir.mkdir(dir, DIRECTORY_MODE)
            rescue Errno::EEXIST
              nil # another process made it meanwhile: checked below like any other
            end
          end
          unsafe = problem(File.stat(dir))
          return dir if unsafe.nil?

          raise CacheError,
                "the CRuby preview's library cache #{dir} #{unsafe}, so no compiled library is loaded from it " \
                "(remove the directory, and it is made again for this user alone)"
        end

        # Why a file or directory with this stat (anything with #uid and
        # #mode, a File::Stat) is unsafe to load from for the effective user
        # `euid`; nil when it is safe.
        # @return [String, nil]
        def problem(stat, euid = Process.euid)
          if stat.uid != euid
            "is owned by uid #{stat.uid}, not by this process's user (uid #{euid})"
          elsif stat.mode & SHARED_WRITE != 0
            format("is writable by its group or others (mode %04o)", stat.mode & 0o7777)
          end
        end

        # Compiles `source` into `path`: to a name of its own first, then
        # renamed, so two processes starting together never load a
        # half-written library.
        def compile(source, libs, path)
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
          File.chmod(LIBRARY_MODE, partial)
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
