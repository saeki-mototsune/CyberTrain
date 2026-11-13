# Cybertrain::Test::Args -- the run-time arguments of `cybertrain test`
# and of the bundle it compiles (spec section 8, plan decision 11): file or
# directory arguments keep the tests of those files, `-n NAME` keeps a test
# whose name or method name is NAME, `-n /TEXT/` one whose name or method
# name contains TEXT; both combine. No requires beyond the standard
# library: the CLI checks the arguments with it before compiling, and the
# compiled bundle filters with it, so the two never disagree.
module Cybertrain
  module Test
    # The parsed arguments: arg_files (the bundled files kept; empty for
    # all), arg_name (`-n NAME`, "" for none), arg_pattern (the TEXT of
    # `-n /TEXT/`, "" for none) and arg_error ("" when the arguments are
    # good, else the reason printed under {USAGE}, exit status 2).
    # @api private
    class Args
      USAGE = "usage: cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]".freeze
      # What `test/x_test.rb:14` (the place a FAIL line prints) is refused with.
      LINE_FILTER = "line filters are not supported; give the file, and -n for the name".freeze
      # The characters `-n /TEXT/` refuses in TEXT ({pattern_problem}).
      REGEXP_CHARACTERS = ["^", "$", "\\", "*", "+", "[", "]", "{", "}", "|"].freeze
      # The line a run prints when a filter kept no test (the run still
      # exits 0: 0 tests is not a failure, spec section 8).
      NOTHING_MATCHED = "no test matched the filter".freeze
      # The digits of a method name's `_u<hex>` ({method_for}).
      HEX = "0123456789abcdef".freeze

      attr_reader :arg_files, :arg_name, :arg_pattern, :arg_error

      def initialize(arg_files, arg_name, arg_pattern, arg_error)
        @arg_files = arg_files
        @arg_name = arg_name
        @arg_pattern = arg_pattern
        @arg_error = arg_error
      end

      # Parses argv against `files` (the application's test files,
      # "test/models/article_test.rb", ...; Cybertrain::TestFiles.list) of
      # the application at `root`. A file argument may be written
      # `./test/x_test.rb` or as an absolute path under root; a directory
      # keeps every file under it; after `--` every argument is a file or
      # directory, even one starting with `-`. Anything else (an unknown
      # option, `-n` with no value, `-n /TEXT/` whose TEXT holds a regexp
      # character, FILE:LINE, a path that is no test file) answers an Args
      # whose arg_error says so. A later `-n` replaces an earlier one.
      # @param argv [Array<String>]
      # @param files [Array<String>]
      # @param root [String]
      # @return [Cybertrain::Test::Args]
      def self.parse(argv, files, root)
        picked = Array.new(0) { "" }
        name = ""
        pattern = ""
        options = true
        i = 0
        while i < argv.length
          arg = argv[i]
          if options && arg == "--"
            options = false
            i += 1
          elsif options && arg == "-n"
            value = i + 1 < argv.length ? argv[i + 1] : ""
            return refused("-n needs a name or /text/") if value.empty?

            return refused("-n needs a name or /text/") if value == "//"

            if value.length >= 2 && value.start_with?("/") && value.end_with?("/")
              pattern = value[1, value.length - 2].to_s
              problem = pattern_problem(pattern)
              return refused(problem) unless problem.empty?

              name = ""
            else
              name = value
              pattern = ""
            end
            i += 2
          elsif options && arg.start_with?("-")
            return refused("unknown option #{arg}")
          else
            matched = matching_files(arg, files, root)
            return refused(line_filter?(arg, files, root) ? LINE_FILTER : "no test file at #{arg}") if matched.empty?

            matched.each { |f| picked << f unless picked.include?(f) }
            i += 1
          end
        end
        Args.new(picked, name, pattern, "")
      end

      def self.refused(reason)
        Args.new(Array.new(0) { "" }, "", "", reason)
      end

      # Why `-n /TEXT/` is refused, "" when it is not: TEXT holds a
      # character only a regexp means something by (Rails' `-n /x/` is a
      # regexp; here the text between the slashes is a plain substring).
      # `.`, `?` and parentheses are taken as themselves: test names hold
      # them.
      # @param pattern [String]
      # @return [String]
      def self.pattern_problem(pattern)
        bad = ""
        plain = +""
        pattern.each_char do |ch|
          if REGEXP_CHARACTERS.include?(ch)
            bad = ch if bad.empty?
          else
            plain << ch
          end
        end
        return "" if bad.empty?

        hint = plain.empty? ? "" : " (-n /#{plain}/)"
        "-n /#{pattern}/: the text between the slashes is a plain substring of the test name, not a regexp " \
          "(#{bad} would be looked for as itself); write the text to look for#{hint}"
      end

      # Whether arg is FILE:LINE (the place a FAIL line prints) naming one
      # of `files`.
      def self.line_filter?(arg, files, root)
        colon = -1
        digits = true
        k = arg.length - 1
        while k >= 0
          ch = arg[k].to_s
          if ch == ":"
            colon = k
            break
          end
          digits = false unless ch >= "0" && ch <= "9"
          k -= 1
        end
        return false if colon <= 0 || colon == arg.length - 1 || !digits

        !matching_files(arg[0, colon].to_s, files, root).empty?
      end

      # The files of `files` that `arg` names: the file itself, or every
      # file under the directory it names.
      def self.matching_files(arg, files, root)
        rel = arg
        rel = rel[2, rel.length - 2].to_s while rel.start_with?("./")
        prefix = root.end_with?("/") ? root : "#{root}/"
        if !root.empty? && rel.start_with?(prefix)
          rel = rel[prefix.length, rel.length - prefix.length].to_s
        elsif !root.empty? && rel.start_with?("/")
          # The same place spelled through a symlink (macOS's /var is
          # /private/var; Dir.pwd answers the real spelling).
          real_root = real_path(root)
          real_prefix = real_root.end_with?("/") ? real_root : "#{real_root}/"
          real = real_path(rel)
          rel = real[real_prefix.length, real.length - real_prefix.length].to_s if real.start_with?(real_prefix)
        end
        rel = rel[0, rel.length - 1].to_s while rel.length > 1 && rel.end_with?("/")
        out = Array.new(0) { "" }
        if files.include?(rel)
          out << rel
          return out
        end
        under = "#{rel}/"
        files.each { |f| out << f if f.start_with?(under) }
        out
      end

      # path with every symlink resolved: File.realpath of its longest
      # existing part, the rest appended as written. The comparisons of the
      # CLI and the bundle use it, so /var/... and /private/var/... (or a
      # checkout reached through a link) are one place.
      # @param path [String]
      # @return [String]
      def self.real_path(path)
        return File.realpath(path) if File.exist?(path)

        parent = File.dirname(path)
        return path if parent == path

        base = real_path(parent)
        base.end_with?("/") ? "#{base}#{File.basename(path)}" : "#{base}/#{File.basename(path)}"
      end

      # The method name of a test (spec 5.2; gen's rewrite uses this one):
      # `test_` and the name with every ASCII character outside
      # [A-Za-z0-9_] turned into `_` and every other character into
      # `_u<hex>`, the lowercase hex of its code point ("ログ" ->
      # test__u30ed_u30b0), so that names in another script do not
      # collide. Read byte by byte as UTF-8, the same under Spinel and
      # CRuby whatever the String's encoding tag; a byte that starts no
      # well-formed sequence is `_u<hex>` of the byte.
      # @param name [String]
      # @return [String]
      def self.method_for(name)
        s = name.to_s
        out = +"test_"
        n = s.bytesize
        i = 0
        while i < n
          b = s.getbyte(i).to_i
          if b < 128
            word = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95
            out << (word ? s.byteslice(i, 1).to_s : "_")
            i += 1
          else
            size = utf8_size(b)
            code = utf8_code(s, i, size)
            if code < 0
              size = 1
              code = b
            end
            out << "_u" << hex(code)
            i += size
          end
        end
        out
      end

      # How many bytes the UTF-8 sequence led by byte b takes (1 for a byte
      # that leads none).
      def self.utf8_size(b)
        return 2 if b >= 0xC2 && b <= 0xDF
        return 3 if b >= 0xE0 && b <= 0xEF
        return 4 if b >= 0xF0 && b <= 0xF4

        1
      end

      # The code point of the `size`-byte sequence at s's byte i; -1 when
      # it is cut short or malformed (or size is 1: no lead byte).
      def self.utf8_code(text, i, size)
        s = text.to_s
        return -1 if size < 2 || i + size > s.bytesize

        b = s.getbyte(i).to_i
        code = size == 2 ? b & 0x1F : (size == 3 ? b & 0x0F : b & 0x07)
        k = 1
        while k < size
          c = s.getbyte(i + k).to_i
          return -1 if c < 0x80 || c > 0xBF

          code = (code << 6) | (c & 0x3F)
          k += 1
        end
        code
      end

      # n in lowercase hex ("3042").
      def self.hex(n)
        return "0" if n.zero?

        digits = +""
        v = n
        while v.positive?
          digits = "#{HEX[v % 16]}#{digits}"
          v /= 16
        end
        digits
      end

      # Whether a file or name filter was given (a run that keeps no test
      # then prints {NOTHING_MATCHED}).
      # @return [Boolean]
      def filtered?
        !@arg_files.empty? || !@arg_name.empty? || !@arg_pattern.empty?
      end

      # Whether the test `name` (method `meth`) of `file` is kept.
      # @param file [String]
      # @param name [String]
      # @param meth [String]
      # @return [Boolean]
      def keep?(file, name, meth)
        return false unless @arg_files.empty? || @arg_files.include?(file)
        return name == @arg_name || meth == @arg_name unless @arg_name.empty?
        return !name.index(@arg_pattern).nil? || !meth.index(@arg_pattern).nil? unless @arg_pattern.empty?

        true
      end
    end
  end
end
