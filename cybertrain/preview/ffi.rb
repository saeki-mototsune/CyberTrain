require "fiddle"

module Cybertrain
  module Preview
    # A type the DSL knows in Spinel but the preview does not translate.
    class Unsupported < StandardError
    end

    # What one module declared through the ffi_* DSL, and the Fiddle side of
    # it. The library is built and opened at the first call of one of the
    # module's functions, not at the first `ffi_func`: sqlite_ffi.rb declares
    # most of its `ffi_source` after its first `ffi_func`, and the compiled
    # unit must hold all of them.
    class FFIModule
      # Spinel's FFI types. Pointers are Integer addresses (0 for NULL), as
      # Spinel hands them over; :str and :binstr are C pointers that become
      # Strings on the way back.
      TYPES = {
        ptr: Fiddle::TYPE_VOIDP, str: Fiddle::TYPE_VOIDP, binstr: Fiddle::TYPE_VOIDP,
        int: Fiddle::TYPE_INT, long: Fiddle::TYPE_LONG, size_t: Fiddle::TYPE_SIZE_T,
        double: Fiddle::TYPE_DOUBLE, void: Fiddle::TYPE_VOID
      }.freeze

      # Prepended to the module's C. A :binstr function leaves the byte count
      # of its result in sp_ffi_bin_len; the variable is thread-local and
      # file-local so that threads calling at once (Fiddle releases the GVL
      # around a call) and several compiled libraries never share it, and the
      # accessor lets the shim read it on the calling thread.
      PRELUDE = <<~C
        #include <stddef.h>
        static __thread int sp_ffi_bin_len;
        int cybertrain_preview_bin_len(void) { return sp_ffi_bin_len; }
      C

      @all = []

      class << self
        attr_reader :all
      end

      attr_reader :libs, :sources

      def initialize(mod)
        @mod = mod
        @libs = []
        @sources = []
        @handles = nil
        @bin_len = nil
        @functions = {}
        FFIModule.all << self
      end

      def add_lib(name)
        @libs << name.to_s
        clear_handles
      end

      def add_source(text)
        @sources << text
        clear_handles
      end

      def check_types(name, arg_types, return_type)
        (arg_types + [return_type]).each do |type|
          next if TYPES.key?(type)

          raise Unsupported, "ffi_func :#{name}: type :#{type} is not implemented by the CRuby preview"
        end
      end

      # Builds the module's own library; the path, or nil without ffi_source.
      def build
        return nil if @sources.empty?

        FFILibrary.build(source, @libs, Preview.cache_dir)
      end

      # The module's whole C unit.
      def source
        PRELUDE + @sources.join("\n")
      end

      def call(name, arg_types, return_type, values)
        if values.size != arg_types.size
          raise ArgumentError, "#{@mod}.#{name}: wrong number of arguments (given #{values.size}, expected #{arg_types.size})"
        end

        converted = values.each_with_index.map { |value, i| argument(arg_types[i], value) }
        result = function(name, arg_types, return_type).call(*converted)
        case return_type
        when :ptr then result.to_i
        when :str then string_at(result.to_i)
        when :binstr then bytes_at(result.to_i)
        when :void then nil
        else result
        end
      end

      private

      def clear_handles
        @handles = nil
        @bin_len = nil
        @functions.clear
      end

      def argument(type, value)
        case type
        when :str
          return 0 if value.nil?

          # A NUL-terminated copy: a Ruby String's buffer is not always
          # terminated (a shared substring), and C reads a :str to its NUL.
          "#{value.to_s.b}\0"
        when :ptr, :binstr
          value.nil? ? 0 : value
        else
          value
        end
      end

      # Spinel's Strings are UTF-8 whatever the locale, so a :str result is
      # tagged so; NULL is nil, as `sqlite3_column_text` gives it compiled.
      def string_at(address)
        return nil if address.zero?

        Fiddle::Pointer.new(address).to_s.force_encoding(Encoding::UTF_8)
      end

      # A :binstr result is as long as the function said (sp_ffi_bin_len),
      # NULs included, and carries no encoding.
      def bytes_at(address)
        length = bin_len_function.call
        return "".b if address.zero? || length <= 0

        Fiddle::Pointer.new(address)[0, length]
      end

      # Symbols are looked up in the compiled library first, then in the
      # ffi_lib ones, then in the process (libc's malloc and free).
      def handles
        @handles ||= begin
          list = []
          list << FFILibrary.open_library(source, @libs, Preview.cache_dir) unless @sources.empty?
          @libs.each { |name| list << open_lib(name) }
          list << Fiddle::Handle::DEFAULT
        end
      end

      def open_lib(name)
        candidates = ["lib#{name}.so", "lib#{name}.so.0", "lib#{name}.so.1", "lib#{name}.dylib"]
        candidates.each do |file|
          return Fiddle.dlopen(file)
        rescue Fiddle::DLError
          next
        end
        raise LoadError, "ffi_lib #{name}: none of #{candidates.join(', ')} could be opened"
      end

      def function(name, arg_types, return_type)
        @functions[name] ||= Fiddle::Function.new(
          address(name), arg_types.map { |t| TYPES.fetch(t) }, TYPES.fetch(return_type)
        )
      end

      def address(name)
        handles.each do |handle|
          return handle.sym(name.to_s)
        rescue Fiddle::DLError
          next
        end
        raise NotImplementedError, "ffi_func #{@mod}.#{name}: no exported symbol #{name} (a static function, or missing)"
      end

      def bin_len_function
        @bin_len ||= begin
          handle = handles.first
          Fiddle::Function.new(handle.sym("cybertrain_preview_bin_len"), [], Fiddle::TYPE_INT)
        rescue Fiddle::DLError
          raise NotImplementedError, "#{@mod}: a :binstr function needs the module to declare an ffi_source"
        end
      end
    end

    # Compiles the library of every module loaded so far and answers how many
    # compilations that took (0 when the cache already held them all). The
    # playground image calls it so that a container starts with them built.
    def self.warm!
      before = FFILibrary.built
      FFIModule.all.each(&:build)
      FFILibrary.built - before
    end
  end
end

# The DSL, on Module as in Spinel.
class Module
  def ffi_lib(name)
    __cybertrain_ffi.add_lib(name)
    nil
  end

  def ffi_source(text)
    __cybertrain_ffi.add_source(text)
    nil
  end

  def ffi_func(name, arg_types, return_type, blocking: false)
    ffi = __cybertrain_ffi
    ffi.check_types(name, arg_types, return_type)
    # `blocking:` tells Spinel to release its GVL around the call; Fiddle
    # always releases CRuby's, so there is nothing to do.
    define_singleton_method(name) { |*values| ffi.call(name, arg_types, return_type, values) }
    nil
  end

  def ffi_const(name, value)
    __cybertrain_ffi
    const_set(name, value)
    nil
  end

  # `ffi_read_ptr :name, offset`: name(address) is *(void **)(address + offset).
  def ffi_read_ptr(name, offset)
    __cybertrain_ffi
    define_singleton_method(name) do |address|
      Fiddle::Pointer.new(address + offset)[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
    end
    nil
  end

  private

  # The module's DSL state, created by its first ffi_* call, which also gives
  # it `malloc` and `free` (a module that declares them itself, as the FFI
  # files do, replaces these).
  def __cybertrain_ffi
    @__cybertrain_ffi ||= begin
      define_singleton_method(:malloc) { |size| Fiddle.malloc(size).to_i }
      define_singleton_method(:free) { |address| Fiddle.free(address); nil }
      Cybertrain::Preview::FFIModule.new(self)
    end
  end
end
