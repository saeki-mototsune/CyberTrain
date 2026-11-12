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
      # keeps every file under it. Anything else (an unknown option, `-n`
      # with no value, a path that is no test file) answers an Args whose
      # arg_error says so. A later `-n` replaces an earlier one.
      # @param argv [Array<String>]
      # @param files [Array<String>]
      # @param root [String]
      # @return [Cybertrain::Test::Args]
      def self.parse(argv, files, root)
        picked = Array.new(0) { "" }
        name = ""
        pattern = ""
        i = 0
        while i < argv.length
          arg = argv[i]
          if arg == "-n"
            value = i + 1 < argv.length ? argv[i + 1] : ""
            return refused("-n needs a name or /text/") if value.empty?

            if value.length >= 2 && value.start_with?("/") && value.end_with?("/")
              pattern = value[1, value.length - 2].to_s
              name = ""
            else
              name = value
              pattern = ""
            end
            i += 2
          elsif arg.start_with?("-")
            return refused("unknown option #{arg}")
          else
            matched = matching_files(arg, files, root)
            return refused("no test file at #{arg}") if matched.empty?

            matched.each { |f| picked << f unless picked.include?(f) }
            i += 1
          end
        end
        Args.new(picked, name, pattern, "")
      end

      def self.refused(reason)
        Args.new(Array.new(0) { "" }, "", "", reason)
      end

      # The files of `files` that `arg` names: the file itself, or every
      # file under the directory it names.
      def self.matching_files(arg, files, root)
        rel = arg
        rel = rel[2, rel.length - 2].to_s while rel.start_with?("./")
        prefix = root.end_with?("/") ? root : "#{root}/"
        rel = rel[prefix.length, rel.length - prefix.length].to_s if !root.empty? && rel.start_with?(prefix)
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

      # The method name of a test: `test_` and the name with every
      # character outside [A-Za-z0-9_] turned into `_` (spec 5.2; the same
      # rule as gen's rewrite).
      # @param name [String]
      # @return [String]
      def self.method_for(name)
        out = +"test_"
        name.each_char do |ch|
          word = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
          out << (word ? ch : "_")
        end
        out
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
