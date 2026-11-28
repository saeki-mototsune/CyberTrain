module Cybertrain
  module Gen
    # Cybertrain::Gen::Dialect -- which DB adapter the application is built
    # with, as far as the generator needs to know (docs/design.md D96). The
    # adapter is chosen when the application is built, by the entry
    # bin/NAME.rb requires (NAME is spin.toml's [package] name, as in
    # ViewRequires):
    #
    #   require "cybertrain"              SQLite
    #   require "cybertrain/mysql"        MySQL
    #   require "cybertrain/core"         SQLite, the core alone
    #   require "cybertrain/core/mysql"   MySQL, the core alone
    #
    # The last two are the first line of every `cybertrain new` application
    # (D85: the core and the subsystem lines it adds), so they pick the same
    # adapter as the whole-framework entries they stand beside.
    #
    # bin/NAME.rb is read lexically, line by line, as ViewRequires reads it:
    # `require "X"`, `require 'X'` or `require("X")` after the indentation,
    # a trailing comment allowed. The first of the four entries decides;
    # other requires (a subsystem such as "cybertrain/jobs", another
    # library) are skipped. With no MySQL entry the application is SQLite,
    # as every application was before MySQL: gen refuses none of them. So
    # is one with no spin.toml name or no bin/NAME.rb (a fixture tree).
    #
    # `for(name)` answers the Spec the emitters take, so that what is spelled
    # differently per adapter (the identifier quote, the entry require) is
    # spelled once, here. Generated code never branches on the adapter at
    # run time: each program is built for one.
    module Dialect
      SQLITE = "sqlite".freeze
      MYSQL = "mysql".freeze

      # What one adapter spells for the generator.
      class Spec
        def initialize(name)
          @name = name
        end

        # "sqlite" or "mysql".
        # @return [String]
        def name
          @name
        end

        # The require that loads the adapter ("cybertrain" is SQLite's).
        # @return [String]
        def entry
          @name == "mysql" ? "cybertrain/mysql" : "cybertrain"
        end

        # The test bundle the adapter's gen/tests.rb requires.
        # @return [String]
        def test_bundle
          @name == "mysql" ? "cybertrain/test/bundle_mysql" : "cybertrain/test/bundle"
        end

        # `ident` quoted as an SQL identifier: "x" for SQLite, `x` for MySQL,
        # the quote character doubled where the name holds one.
        # @param ident [String]
        # @return [String]
        def quote_ident(ident)
          if @name == "mysql"
            "`" + ident.gsub("`", "``") + "`"
          else
            "\"" + ident.gsub("\"", "\"\"") + "\""
          end
        end

        def mysql?
          @name == "mysql"
        end
      end

      # The Spec of "sqlite" or "mysql".
      # @param name [String]
      # @return [Cybertrain::Gen::Dialect::Spec]
      def self.for(name)
        raise ArgumentError, "unknown adapter #{name}: sqlite or mysql" unless name == SQLITE || name == MYSQL

        Spec.new(name)
      end

      # The adapter the application at `root` is built with: "sqlite" or
      # "mysql", from bin/NAME.rb's entry require. NAME is read by
      # ViewRequires.package_name, which the caller has loaded (Runner and the
      # tests do; this file requires nothing, since the CLI loads it too and
      # the gem ships only the files the CLI needs).
      # @param root [String]
      # @return [String]
      def self.detect(root)
        name = ViewRequires.package_name(root)
        return SQLITE if name.empty?

        bin = "#{root}/bin/#{name}.rb"
        return SQLITE unless File.file?(bin)

        in_source(File.read(bin))
      end

      # The adapter bin/NAME.rb's `source` is built with, as detect says it:
      # the first entry it requires, SQLite when it requires neither MySQL
      # entry.
      # @param source [String] the text of bin/NAME.rb
      # @return [String]
      def self.in_source(source)
        source.split("\n").each do |raw|
          spec = required_spec(raw.strip)
          return SQLITE if spec == "cybertrain" || spec == "cybertrain/core"
          return MYSQL if spec == "cybertrain/mysql" || spec == "cybertrain/core/mysql"
        end
        SQLITE
      end

      # The argument of a `require "x"`, `require 'x'` or `require("x")`
      # line; "" for any other line. ViewRequires reads bin/NAME.rb's
      # subsystem lines with it too, so both see the same requires.
      # @param line [String] stripped
      # @return [String]
      def self.required_spec(line)
        return "" unless line.start_with?("require")

        rest = line[7, line.size - 7]
        rest = rest[1, rest.size - 1] if rest.start_with?("(")
        rest = rest.strip
        return "" if rest.empty?

        quote = rest[0]
        return "" unless quote == "\"" || quote == "'"

        close = rest.index(quote, 1)
        return "" if close.nil?

        rest[1, close - 1]
      end

      # What gen says, after "<path>:<line>: ", of an add_index with a
      # `where:` in an application on MySQL (which has no partial index),
      # before anything is written; MySQL's DDL refuses one the same way.
      PARTIAL_INDEX = "partial indexes (where:) are not supported on MySQL".freeze

      # The 1-based lines of `source` (a migration, db/schema.rb) where an
      # `add_index` call with a `where:` other than "" starts. A call
      # continues on the next line while its parentheses or brackets are
      # open or its line ends in a comma; comments are skipped.
      # @param source [String]
      # @return [Array<Integer>]
      def self.partial_index_lines(source)
        lines = source.split("\n")
        found = Array.new(0) { 0 }
        i = 0
        while i < lines.size
          code = code_of(lines[i])
          if code.include?("add_index")
            text = +code
            j = i
            while j + 1 < lines.size && continues?(text)
              j += 1
              text << " " << code_of(lines[j])
            end
            found << i + 1 if where_given?(text)
            i = j
          end
          i += 1
        end
        found
      end

      # `line` up to a `#` outside a string literal.
      def self.code_of(line)
        quote = 0
        k = 0
        n = line.bytesize
        while k < n
          b = line.getbyte(k)
          if quote != 0
            if b == 92
              k += 1
            elsif b == quote
              quote = 0
            end
          elsif b == 34 || b == 39
            quote = b
          elsif b == 35
            return line.byteslice(0, k)
          end
          k += 1
        end
        line
      end

      # Whether a call's text goes on: an open ( or [ outside a string, or
      # a last character that is a comma.
      def self.continues?(text)
        depth = 0
        quote = 0
        k = 0
        n = text.bytesize
        while k < n
          b = text.getbyte(k)
          if quote != 0
            if b == 92
              k += 1
            elsif b == quote
              quote = 0
            end
          elsif b == 34 || b == 39
            quote = b
          elsif b == 40 || b == 91
            depth += 1
          elsif b == 41 || b == 93
            depth -= 1
          end
          k += 1
        end
        depth > 0 || text.rstrip.end_with?(",")
      end

      # Whether the text has a `where:` key (not the end of a longer name)
      # with a value other than "" or ''.
      def self.where_given?(text)
        from = 0
        while from < text.size
          at = text.index("where:", from)
          return false if at.nil?

          before = at == 0 ? " " : text[at - 1, 1]
          unless word_char?(before)
            rest = text[at + 6, text.size - at - 6].lstrip
            return !(rest.start_with?("\"\"") || rest.start_with?("''"))
          end
          from = at + 6
        end
        false
      end

      def self.word_char?(char)
        b = char.getbyte(0)
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
      end

      # The Spec of the application at `root`.
      # @param root [String]
      # @return [Cybertrain::Gen::Dialect::Spec]
      def self.of(root)
        self.for(detect(root))
      end
    end
  end
end
