# Throwaway spike (2026-11, spikes/NOTES.md "CRuby preview spike, 2026-11"):
# the Spinel FFI DSL (`ffi_lib`, `ffi_source`, `ffi_func`, `ffi_const`,
# `ffi_read_ptr`, and the `malloc` / `free` the FFI modules declare) on
# Module, through Fiddle, so the framework's three FFI files load and run
# under CRuby. Loaded with `ruby -r <repo>/spikes/preview/shim ...`.
#
# Not the shim the plan builds (that is cybertrain/preview/, Task 2); this
# one exists to answer the "known points" of the design's section 7.
#
# * Pointers are Integer addresses (0 for NULL), as Spinel hands them over.
#   A nil :ptr or :str argument is NULL.
# * A module's `ffi_source` texts are compiled with `cc -shared -fPIC`,
#   linked against its `ffi_lib`, at the first *call* of any of its
#   functions (not at the first `ffi_func`: sqlite_ffi.rb declares sources
#   after its first ffi_func). The shared object is cached under
#   CYBERTRAIN_PREVIEW_CACHE (default: $TMPDIR/cybertrain-preview-spike) by a
#   digest of the sources, the flags and `cc --version`.
# * `sp_ffi_bin_len` is declared in the compiled unit as a static
#   thread-local int with an accessor; a :binstr call reads it right after
#   the call, on the same thread, and copies that many bytes.
# * `blocking:` is accepted and ignored.
require "fiddle"
require "digest"
require "fileutils"
require "tmpdir"

# Spinel's Strings are UTF-8 whatever the locale; CRuby's File.read tags
# text with the locale's encoding (US-ASCII under LANG unset or C), and a
# US-ASCII String with non-ASCII bytes is never == to the UTF-8 one.
# CRuby sets the locale's encoding after the -r libraries load and before
# it compiles the main script, so it is set again when that script is
# compiled (the real preview passes `-E UTF-8` on its command line instead).
Encoding.default_external = Encoding::UTF_8
TracePoint.new(:script_compiled) do |tp|
  Encoding.default_external = Encoding::UTF_8
  tp.disable
end.enable
# A `ruby` the program spawns (the tests' CRuby branch re-runs $0 in a
# child) loads this shim too.
unless ENV["RUBYOPT"].to_s.include?(File.expand_path(__FILE__))
  ENV["RUBYOPT"] = "#{ENV['RUBYOPT']} -r#{File.expand_path(__FILE__)}".strip
end

module CybertrainPreviewSpike
  CC = ENV["CC"] || "cc"
  CACHE = ENV["CYBERTRAIN_PREVIEW_CACHE"] || File.join(Dir.tmpdir, "cybertrain-preview-spike")
  BIN_LEN_ACCESSOR = "cybertrain_preview_bin_len"
  PRELUDE = <<~C
    #include <stddef.h>
    static _Thread_local int sp_ffi_bin_len;
    int #{BIN_LEN_ACCESSOR}(void) { return sp_ffi_bin_len; }
  C
  TYPES = {
    ptr: Fiddle::TYPE_VOIDP, str: Fiddle::TYPE_VOIDP, binstr: Fiddle::TYPE_VOIDP,
    int: Fiddle::TYPE_INT, long: Fiddle::TYPE_LONG, size_t: Fiddle::TYPE_SIZE_T,
    double: Fiddle::TYPE_DOUBLE, void: Fiddle::TYPE_VOID
  }.freeze

  @cc_version = nil
  @lib_handles = {}

  class << self
    def cc_version
      @cc_version ||= `#{CC} --version 2>&1`.lines.first.to_s.strip
    end

    # The platform's shared library for `ffi_lib name`.
    def lib_handle(name)
      @lib_handles[name] ||= begin
        candidates = ["lib#{name}.so", "lib#{name}.so.0", "lib#{name}.so.1", "lib#{name}.dylib"]
        handle = nil
        candidates.each do |file|
          handle = Fiddle.dlopen(file)
          break
        rescue Fiddle::DLError
          next
        end
        raise LoadError, "ffi_lib #{name}: none of #{candidates.join(', ')} could be opened" unless handle

        handle
      end
    end

    # Compiles a module's sources into a cached shared object; returns its path.
    def compile(sources, lib)
      source = PRELUDE + sources.join("\n")
      flags = ["-shared", "-fPIC", "-O2"]
      links = lib ? ["-l#{lib}"] : []
      key = Digest::SHA256.hexdigest([source, flags, links, cc_version].join("\0"))[0, 16]
      FileUtils.mkdir_p(CACHE)
      so = File.join(CACHE, "ffi-#{key}.so")
      return so if File.exist?(so)

      c = File.join(CACHE, "ffi-#{key}.c")
      File.write(c, source)
      tmp = "#{so}.#{Process.pid}.tmp"
      ok = system(CC, *flags, "-o", tmp, c, *links)
      raise LoadError, "ffi_source: #{CC} failed on #{c}" unless ok

      File.rename(tmp, so)
      so
    end

    def arg(type, value)
      case type
      when :str
        return 0 if value.nil?

        # A NUL-terminated copy: a Ruby String's buffer is not always
        # terminated (a shared substring), and C reads :str up to the NUL
        # unless it is given a length.
        value.to_s.b << "\0"
      when :ptr, :binstr
        value.nil? ? 0 : value
      else
        value
      end
    end
  end

  # Per-module state: sources, lib, compiled handle, bound functions.
  class Binding
    attr_reader :sources

    def initialize(mod)
      @mod = mod
      @sources = []
      @lib = nil
      @handle = nil
      @functions = {}
    end

    def lib=(name)
      @lib = name
    end

    def add_source(text)
      @sources << text
      @handle = nil
      @functions.clear
    end

    def compiled
      return nil if @sources.empty?

      @handle ||= Fiddle.dlopen(CybertrainPreviewSpike.compile(@sources, @lib))
    end

    def address(name)
      [compiled, @lib && CybertrainPreviewSpike.lib_handle(@lib), Fiddle::Handle::DEFAULT].each do |h|
        next if h.nil?

        begin
          return h.sym(name.to_s)
        rescue Fiddle::DLError
          next
        end
      end
      raise NotImplementedError, "ffi_func #{@mod}.#{name}: no exported symbol #{name} (static, or missing)"
    end

    def function(name, args, ret)
      @functions[name] ||= Fiddle::Function.new(address(name), args.map { |t| TYPES.fetch(t) }, TYPES.fetch(ret))
    end

    def bin_len_function
      @bin_len ||= Fiddle::Function.new(compiled.sym(BIN_LEN_ACCESSOR), [], Fiddle::TYPE_INT)
    end

    def call(name, args, ret, values)
      raise ArgumentError, "#{@mod}.#{name}: #{values.size} for #{args.size}" if values.size != args.size

      converted = values.each_with_index.map { |v, i| CybertrainPreviewSpike.arg(args[i], v) }
      result = function(name, args, ret).call(*converted)
      case ret
      when :ptr then result.to_i
      when :str
        address = result.to_i
        # Spinel's Strings are UTF-8 (rule 27): tag the copy so it compares,
        # concatenates and prints as the compiled program's would.
        address == 0 ? nil : result.to_s.force_encoding(Encoding::UTF_8)
      when :binstr
        len = bin_len_function.call
        address = result.to_i
        address == 0 || len <= 0 ? "".b : Fiddle::Pointer.new(address)[0, len]
      when :void then nil
      else result
      end
    end
  end
end

class Module
  def __preview_binding
    @__preview_binding ||= CybertrainPreviewSpike::Binding.new(self)
  end

  def ffi_lib(name)
    __preview_binding.lib = name
    nil
  end

  def ffi_source(text)
    __preview_binding.add_source(text)
    nil
  end

  def ffi_func(name, args, ret, blocking: false)
    binding = __preview_binding
    define_singleton_method(name) { |*values| binding.call(name, args, ret, values) }
    nil
  end

  def ffi_const(name, value)
    const_set(name, value)
    nil
  end

  # `ffi_read_ptr :read_ptr, offset`: read_ptr(addr) is *(void **)(addr + offset).
  def ffi_read_ptr(name, offset)
    define_singleton_method(name) { |addr| Fiddle::Pointer.new(addr + offset)[0, Fiddle::SIZEOF_VOIDP].unpack1("J") }
    nil
  end
end
