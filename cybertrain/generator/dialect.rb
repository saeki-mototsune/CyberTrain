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
      # entry. Only a line that begins as code counts (entry_lines): one
      # inside a heredoc or an =begin block is text.
      # @param source [String] the text of bin/NAME.rb
      # @return [String]
      def self.in_source(source)
        numbers = entry_lines(source)
        return SQLITE if numbers.empty?

        entry_adapter(required_spec(source.lines[numbers[0] - 1].strip))
      end

      # The SQLite entries and the MySQL ones.
      SQLITE_ENTRIES = ["cybertrain", "cybertrain/core"].freeze
      MYSQL_ENTRIES = ["cybertrain/mysql", "cybertrain/core/mysql"].freeze

      # "mysql" for a MySQL entry, else "sqlite".
      # @param spec [String]
      # @return [String]
      def self.entry_adapter(spec)
        MYSQL_ENTRIES.include?(spec) ? MYSQL : SQLITE
      end

      # The 1-based numbers of the lines of `source` that require an entry
      # (SQLITE_ENTRIES, MYSQL_ENTRIES), among the lines that are code: a
      # heredoc's body, an =begin ... =end block or the text after __END__
      # that holds such a line (a command's help text) is not a require.
      # Heredocs are found as Ruby opens them (`<<~ID`, `<<-ID`, `<<ID` with
      # ID uppercase, or a quoted ID) outside string literals and comments.
      # @param source [String]
      # @return [Array<Integer>]
      def self.entry_lines(source)
        raws = source.split("\n")
        found = Array.new(0) { 0 }
        # The heredocs still to be read: their IDs, and whether the closing
        # line may be indented (<<~ and <<-).
        tags = Array.new(0) { "" }
        indented = Array.new(0) { false }
        in_doc = false
        i = 0
        while i < raws.size
          raw = raws[i]
          if in_doc
            in_doc = false if raw.start_with?("=end")
          elsif !tags.empty?
            done = indented[0] ? raw.strip == tags[0] : raw == tags[0]
            if done
              tags.shift
              indented.shift
            end
          elsif raw.start_with?("=begin")
            in_doc = true
          elsif raw == "__END__"
            return found
          else
            spec = required_spec(raw.strip)
            found << i + 1 if SQLITE_ENTRIES.include?(spec) || MYSQL_ENTRIES.include?(spec)
            heredoc_openers(code_of(raw), tags, indented)
          end
          i += 1
        end
        found
      end

      # Appends to `tags` (and `indented`) the heredocs `code` (one line,
      # its comment cut) opens, in order.
      # @param code [String]
      # @param tags [Array<String>]
      # @param indented [Array<Boolean>]
      # @return [nil]
      def self.heredoc_openers(code, tags, indented)
        blanked = without_strings(code)
        from = 0
        while from < blanked.size
          at = blanked.index("<<", from)
          return nil if at.nil?

          k = at + 2
          squiggly = k < code.size && (code[k, 1] == "~" || code[k, 1] == "-")
          k += 1 if squiggly
          first = k < code.size ? code[k, 1] : ""
          if first == "\"" || first == "'" || first == "`"
            close = code.index(first, k + 1)
            unless close.nil?
              tags << code[k + 1, close - k - 1].to_s
              indented << squiggly
              from = close + 1
              next
            end
          elsif first != "" && word_char?(first) && (squiggly || upper_or_underscore?(first))
            stop = k
            while stop < code.size && word_char?(code[stop, 1])
              stop += 1
            end
            tags << code[k, stop - k].to_s
            indented << squiggly
            from = stop
            next
          end
          from = at + 2
        end
        nil
      end

      # Why `source` (bin/NAME.rb, `rel` its path) names no single adapter:
      # "<rel>:<n>: ..." when it requires both a SQLite entry and a MySQL
      # one (the program would hold both adapters, and the generator could
      # not tell which it is built with); "" otherwise.
      # @param source [String]
      # @param rel [String]
      # @return [String]
      def self.entry_conflict(source, rel)
        raws = source.lines
        sqlite_at = 0
        mysql_at = 0
        entry_lines(source).each do |n|
          if entry_adapter(required_spec(raws[n - 1].strip)) == MYSQL
            mysql_at = n if mysql_at == 0
          elsif sqlite_at == 0
            sqlite_at = n
          end
        end
        return "" if sqlite_at == 0 || mysql_at == 0

        first = sqlite_at < mysql_at ? sqlite_at : mysql_at
        "#{rel}:#{first}: requires both a SQLite entry (line #{sqlite_at}) and a MySQL one (line #{mysql_at}); " \
          "keep one of them, the first line of the file"
      end

      # entry_conflict of the application at `root`'s bin/NAME.rb ("" when
      # there is no such file).
      # @param root [String]
      # @return [String]
      def self.entry_conflict_of(root)
        name = ViewRequires.package_name(root)
        return "" if name.empty?

        rel = "bin/#{name}.rb"
        return "" unless File.file?("#{root}/#{rel}")

        entry_conflict(File.read("#{root}/#{rel}"), rel)
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
      # `add_index` call with a `where:` (or `:where =>`) other than "", ''
      # or nil starts. Only the code counts, not the text of its string
      # literals or its comments, so a name or a message holding "where:"
      # or "add_index" is none. A call continues on the next line while its
      # parentheses, brackets or braces are open, its line ends in a comma
      # or a backslash, or the next line starts with a comma. A `**opts`
      # that holds a where: is not seen here; the DDL refuses it at `db
      # migrate`.
      # @param source [String]
      # @return [Array<Integer>]
      def self.partial_index_lines(source)
        lines = source.split("\n")
        found = Array.new(0) { 0 }
        i = 0
        while i < lines.size
          code = code_of(lines[i])
          if without_strings(code).include?("add_index")
            text = +code
            j = i
            while j + 1 < lines.size && (continues?(text) || code_of(lines[j + 1]).lstrip.start_with?(","))
              j += 1
              text << " " << code_of(lines[j])
            end
            found << i + 1 if where_given?(without_strings(text))
            i = j
          end
          i += 1
        end
        found
      end

      # `code` with the inside of each "..." or '...' literal turned into
      # spaces, one per byte (the quotes are kept): `"where: x"` reads as
      # `"        "`, and `""` stays `""`.
      def self.without_strings(code)
        out = +""
        quote = 0
        start = 0
        k = 0
        n = code.bytesize
        while k < n
          b = code.getbyte(k)
          if quote != 0
            if b == quote
              out << (" " * (k - start)) << code.byteslice(k, 1)
              quote = 0
              start = k + 1
            elsif b == 92
              k += 1
            end
          elsif b == 34 || b == 39
            out << code.byteslice(start, k + 1 - start)
            quote = b
            start = k + 1
          end
          k += 1
        end
        stop = k > n ? n : k
        out << (quote != 0 ? " " * (stop - start) : code.byteslice(start, stop - start))
        out
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

      # Whether a call's text goes on: an open (, [ or { outside a string,
      # or a last character that is a comma or a backslash.
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
          elsif b == 40 || b == 91 || b == 123
            depth += 1
          elsif b == 41 || b == 93 || b == 125
            depth -= 1
          end
          k += 1
        end
        last = text.rstrip
        depth > 0 || last.end_with?(",") || last.end_with?("\\")
      end

      # Whether `text` (a call, its string literals blanked) has a `where:`
      # key (not the end of a longer name) or a `:where =>` one, with a
      # value other than "", '' or nil.
      def self.where_given?(text)
        from = 0
        while from < text.size
          at = text.index("where", from)
          return false if at.nil?

          before = at == 0 ? " " : text[at - 1, 1]
          after = at + 5
          value = ""
          keyed = false
          if !word_char?(before) && before != ":" && text[after, 1] == ":"
            value = text[after + 1, text.size - after - 1].to_s.lstrip
            keyed = true
          elsif before == ":" && (at < 2 || !word_char?(text[at - 2, 1]))
            arrow = text[after, text.size - after].to_s.lstrip
            if arrow.start_with?("=>")
              value = arrow[2, arrow.size - 2].to_s.lstrip
              keyed = true
            end
          end
          return !no_condition?(value) if keyed

          from = after
        end
        false
      end

      # A where: value that makes no partial index: "", '' or nil.
      def self.no_condition?(value)
        return true if value.start_with?("\"\"") || value.start_with?("''")
        return false unless value.start_with?("nil")

        value.size == 3 || !word_char?(value[3, 1])
      end

      # A..Z or _: what a bare `<<ID` heredoc starts with.
      def self.upper_or_underscore?(char)
        b = char.getbyte(0)
        (b >= 65 && b <= 90) || b == 95
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
