require "cybertrain/test_files"
require "cybertrain/generator/inflector"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/code_view"

module Cybertrain
  module Gen
    # One `test "<literal>" do` of a class-form class (or, in test_lines,
    # of a top-level-form file): the name as written (escapes read), its
    # method name (TestScan.method_name) and the line of the `test` call in
    # the original file, which is also the line of the `def` in the copy.
    class TestCaseInfo
      attr_reader :case_name, :case_method, :case_line

      def initialize(case_name, case_method, case_line)
        @case_name = case_name
        @case_method = case_method
        @case_line = case_line
      end
    end

    # A class-form class: `class ArticlesControllerTest <
    # ActionDispatch::IntegrationTest` (class_line is its line) and its
    # tests in file order.
    class TestClassInfo
      attr_reader :class_name, :superclass_name, :class_line, :cases

      def initialize(class_name, superclass_name, class_line, cases)
        @class_name = class_name
        @superclass_name = superclass_name
        @class_line = class_line
        @cases = cases
      end
    end

    # A top-level `def name` (helper_kind "def") or `NAME =` (helper_kind
    # "constant") of a test, helper or support file, with its line: what
    # the bundle's duplicate check reads (two files of one program must not
    # both define one).
    class TestHelperInfo
      attr_reader :helper_name, :helper_kind, :helper_line

      def initialize(helper_name, helper_kind, helper_line)
        @helper_name = helper_name
        @helper_kind = helper_kind
        @helper_line = helper_line
      end
    end

    # What TestScan found in one file under test/: test_path
    # ("test/models/article_test.rb"), test_form (:class when the file
    # holds a class-form class, else :top_level), test_classes (its
    # class-form classes), test_lines (its top-level `test "<literal>"`
    # calls, plan decision 10), test_helpers (its top-level defs and
    # constants) and copy_path ("gen/test/models/article_test.rb" for a
    # class-form file, the rewritten copy the bundle requires; "" for a
    # file the bundle requires as it is).
    class TestFile
      attr_reader :test_path, :test_form, :test_classes, :test_lines, :test_helpers, :copy_path

      def initialize(test_path, test_form, test_classes, test_lines, test_helpers, copy_path)
        @test_path = test_path
        @test_form = test_form
        @test_classes = test_classes
        @test_lines = test_lines
        @test_helpers = test_helpers
        @copy_path = copy_path
      end

      # test/test_helper.rb or a file of test/support/: loaded by the
      # bundle before the tests, holding no tests of its own to run.
      def support_file?
        @test_path == TestFiles::HELPER || @test_path.start_with?("test/support/")
      end
    end

    # The scanned files of one tree, read once: paths (scan order), their
    # sources and code views, the class-form class names and the paths gen
    # copies.
    class TestTree
      attr_reader :paths, :sources, :views, :forms, :copied

      def initialize(paths, sources, views, forms, copied)
        @paths = paths
        @sources = sources
        @views = views
        @forms = forms
        @copied = copied
      end
    end

    # The lexical scan of test/ (spec 5.2): which files are tests, which
    # classes are Rails-shaped test classes ("class form"), and the rewrite
    # of a class-form file into gen/test/<path under test/>, where every
    # `test "name" do` is a method, so that no stored block is ever run
    # through a base-class receiver (spikes/NOTES.md rule 88).
    #
    # The rewrite keeps every line where it was (plan decision 18):
    # `require "test_helper"` becomes an empty line; `test "shows it" do`
    # becomes `def test_shows_it; begin`; the n-th `setup do` of
    # ArticlesControllerTest becomes `def setup_articles_controller_test_<n>;
    # begin` (and `teardown do` likewise), and the class line gains, after a
    # `;`, one `setup` calling `super` then those methods in order, and one
    # `teardown` calling them in reverse then `super`. The closing `end` of
    # each of those methods, and of a `def setup` / `def teardown` /
    # `def test_x` the class writes itself, becomes `end; nil; end`: the
    # body sits in a `begin` (its rescue and ensure clauses too), so the
    # method answers nil on every path (pre-flight ruling R8: one return
    # type per method name across the program, rule 34); `return <value>`
    # in one is refused. Each `require_relative` is rebased for the copy's
    # directory (plan decision 20).
    #
    # Only the lines at the class body's own indentation are read: a nested
    # helper class, a helper's body and every heredoc, string and comment
    # (CodeView) are copied as they are. Whatever the rewrite cannot carry
    # over exactly is refused with "<path>:<line>: ..." (ArgumentError):
    # never a silently wrong copy or a lost test.
    module TestScan
      # The framework's test classes; an application class inheriting from
      # one of them (or from such a class, in any scanned file) is class
      # form too.
      BASES = ["ActiveSupport::TestCase", "ActionDispatch::IntegrationTest", "ViewComponent::TestCase"].freeze
      # gen/test/data.rb is the fixtures' file (TestDataEmitter): no copy
      # may take its place.
      DATA_FILE = "gen/test/data.rb".freeze
      # The last line of every copy starts with this (the sweep removes
      # only files that carry it).
      FOOTER = "# Generated by `spin run gen` from ".freeze
      DEF = "def ".freeze
      NESTED = "is nested in another class or module; define test classes at the top level of the file".freeze
      RETURN_REFUSED = "`return <value>` in a test, setup or teardown method is not supported (each answers nil, " \
                       "and gen cannot tell a return in a lambda or block from the method's own); use a bare `return`".freeze
      UNPLACED = "gen could not place this line as a test of the class; write `test \"...\" do` (or `setup do`, `teardown do`) " \
                 "directly in the class body, not inside a condition, loop, string or heredoc".freeze

      # Every scanned file of root, each a TestFile: test/test_helper.rb,
      # then test/support/**/*.rb, then TestFiles.list(root). Raises
      # ArgumentError ("<path>:<line>: ...") on what the rewrite refuses.
      def self.scan(root)
        tree = prepare(root)
        files = Array.new(0) { TestFile.new("", :top_level, [], [], [], "") }
        tree.paths.each_with_index { |path, k| files << scan_source(path, tree.sources[k], tree.views[k], tree.forms, tree.copied) }
        files
      end

      # "gen/test/<path under test/>" => the rewritten source, for every
      # scanned file that holds a class-form class (the helper and support
      # files included), in scan order.
      def self.copies(root)
        tree = prepare(root)
        out = { "" => "" }
        out.delete("")
        tree.paths.each_with_index do |path, k|
          next unless tree.copied.include?(path)

          rel = "gen/#{path}"
          if rel == DATA_FILE
            msg = "#{path}: gen/test/data.rb holds the fixtures; rename this test file"
            raise ArgumentError, msg
          end
          text = rewrite_view(tree.sources[k], tree.views[k], path, tree.forms, tree.copied)
          text = "#{text}\n" unless text.empty? || text.end_with?("\n")
          out[rel] = "#{text}#{FOOTER}#{path}. Do not edit.\n"
        end
        out
      end

      # test_ plus the name with every character outside [A-Za-z0-9_]
      # turned into "_" (spec 5.2: "shows an article" ->
      # test_shows_an_article, "日本語" -> test____).
      def self.method_name(name)
        s = name.to_s
        out = +"test_"
        s.each_char { |ch| out << (word_char?(ch) ? ch : "_") }
        out
      end

      # The class-form copy of one file standing alone: its classes are
      # class form when they inherit from BASES or from a class-form class
      # of the same file, and no other file is copied.
      def self.rewrite(file_text, path)
        view = CodeView.new(file_text)
        views = [view]
        rewrite_in(file_text, path, class_forms(views), Array.new(0) { "" })
      end

      # The copy of path (file_text) given the class-form class names of
      # every scanned file and the paths gen copies (plan decision 20).
      def self.rewrite_in(file_text, path, forms, copied)
        view = CodeView.new(file_text)
        check_classes(path, view, forms, Array.new(0) { "" }, Array.new(0) { "" })
        rewrite_view(file_text, view, path, forms, copied)
      end

      # ---- the tree ----

      def self.prepare(root)
        paths = Array.new(0) { "" }
        paths << TestFiles::HELPER if File.exist?("#{root}/#{TestFiles::HELPER}")
        TestFiles.support_files(root).each { |p| paths << p }
        TestFiles.list(root).each { |p| paths << p }
        sources = Array.new(0) { "" }
        views = Array.new(0) { CodeView.new("") }
        paths.each do |p|
          text = File.read("#{root}/#{p}")
          sources << text
          views << CodeView.new(text)
        end
        forms = class_forms(views)
        names = Array.new(0) { "" }
        places = Array.new(0) { "" }
        paths.each_with_index { |p, k| check_classes(p, views[k], forms, names, places) }
        copied = Array.new(0) { "" }
        paths.each_with_index { |p, k| copied << p if holds_form_class?(views[k], forms) }
        TestTree.new(paths, sources, views, forms, copied)
      end

      # The class-form class names: BASES, then every class opened at the
      # left margin (in any of the views) whose superclass is already one,
      # until none is added.
      def self.class_forms(views)
        names = Array.new(0) { "" }
        supers = Array.new(0) { "" }
        views.each do |view|
          view.codes.each_with_index do |code, i|
            next unless view.code_start[i] && ControllerScan.indent_of(code).zero?

            head = class_head(code.strip)
            next if head[1].empty?

            names << head[0]
            supers << head[1]
          end
        end
        forms = Array.new(0) { "" }
        BASES.each { |b| forms << b }
        added = true
        while added
          added = false
          names.each_with_index do |n, k|
            next if forms.include?(n) || !forms.include?(supers[k])

            forms << n
            added = true
          end
        end
        forms
      end

      def self.holds_form_class?(view, forms)
        view.codes.each_with_index do |code, i|
          next unless view.code_start[i] && ControllerScan.indent_of(code).zero?

          head = class_head(code.strip)
          return true if !head[1].empty? && forms.include?(head[1])
        end
        false
      end

      # The refusals that read a whole file: a class-form class opened
      # below the left margin (in a module or another class), one opened a
      # second time (names / places: "path:line" of each first opening,
      # across files), and `setup` / `teardown` / `test` in a reopened
      # framework class.
      def self.check_classes(path, view, forms, names, places)
        codes = view.codes
        codes.each_with_index do |code, i|
          next unless view.code_start[i]

          s = code.strip
          # `module Admin; class UsersTest < ActiveSupport::TestCase`.
          pieces = s.split(";")
          pieces.each_with_index do |piece, n|
            inner = class_head(piece.strip)
            next if n.zero? || inner[1].empty? || !forms.include?(inner[1])

            msg = "#{path}:#{i + 1}: #{inner[0]} #{NESTED}"
            raise ArgumentError, msg
          end
          head = class_head(s)
          next if head[0].empty?

          name = head[0]
          ind = ControllerScan.indent_of(code)
          if ind.positive?
            if head[1].empty?
              # Rails' spelling: `module ActiveSupport` / `class TestCase`.
              mod = enclosing_module(codes, view.code_start, i, ind)
              full = "#{mod}::#{name}"
              check_reopened_base(path, codes, view.code_start, i, full, ind) if !mod.empty? && BASES.include?(full)
              next
            end
            next unless forms.include?(head[1])

            msg = "#{path}:#{i + 1}: #{name} #{NESTED}"
            raise ArgumentError, msg
          end
          if head[1].empty? && BASES.include?(name)
            check_reopened_base(path, codes, view.code_start, i, name, 0)
            next
          end
          next unless forms.include?(name) && !BASES.include?(name)

          k = names.index(name)
          unless k.nil?
            msg = "#{path}:#{i + 1}: #{name} is opened again; it is opened at #{places[k]} too (open a test class once)"
            raise ArgumentError, msg
          end
          names << name
          places << "#{path}:#{i + 1}"
        end
        nil
      end

      # The name of the module whose body holds line i (indented `ind`),
      # "" when the nearest line opening a block around it is no module.
      def self.enclosing_module(codes, starts, i, ind)
        k = i - 1
        while k >= 0
          code = codes[k]
          if starts[k] && !code.strip.empty? && ControllerScan.indent_of(code) < ind
            s = code.strip
            return "" unless s.start_with?("module ")

            name = s[7, s.size - 7].to_s
            semi = name.index(";")
            name = name[0, semi].to_s unless semi.nil?
            return name.strip
          end
          k -= 1
        end
        ""
      end

      def self.check_reopened_base(path, codes, starts, start, name, ind)
        return nil if one_line_class?(codes[start].strip)

        stop = block_end(codes, start + 1, ind)
        stop = codes.size if stop < 0
        j = start + 1
        while j < stop
          s = codes[j].strip
          word = ["setup", "teardown", "test"].find { |w| call_of?(s, w) }
          if starts[j] && !word.nil?
            form = block_word?(s, word) ? "`#{word} do`" : "`#{word}`"
            msg = "#{path}:#{j + 1}: #{form} in a reopened #{name} is not supported; " \
                  "put it in an application base class (class ApplicationTest < ActiveSupport::TestCase with setup do ... end) and inherit from it"
            raise ArgumentError, msg
          end
          j += 1
        end
        nil
      end

      # s calls `word` (`setup do`, `setup :x`, `setup { }`, `test "x"`),
      # not `setup_x` or `setup = 1`.
      def self.call_of?(s, word)
        return false unless s.start_with?(word)
        return true if s.size == word.size

        nxt = s[word.size].to_s
        return false unless nxt == " " || nxt == "(" || nxt == "{"

        rest = s[word.size, s.size - word.size].to_s.lstrip
        !(rest.start_with?("=") && !rest.start_with?("=="))
      end

      # ---- one file ----

      def self.scan_source(path, text, view, forms, copied)
        lines = text.lines
        codes = view.codes
        classes = Array.new(0) { TestClassInfo.new("", "", 0, []) }
        tests = Array.new(0) { TestCaseInfo.new("", "", 0) }
        helpers = Array.new(0) { TestHelperInfo.new("", "", 0) }
        lines.each_with_index do |raw, i|
          code = codes[i]
          next unless view.code_start[i] && ControllerScan.indent_of(code).zero?

          s = code.rstrip
          if s.start_with?("def ") && !s.start_with?("def self.")
            name = def_name(s)
            helpers << TestHelperInfo.new(name, "def", i + 1) unless name.empty?
          elsif constant_line?(s)
            helpers << TestHelperInfo.new(constant_name(s), "constant", i + 1)
          else
            k = test_start(s)
            next if k < 0 || !quote?(s[k].to_s)

            rs = raw[0, s.size].to_s
            stop = literal_end(rs, k)
            next if stop < 0

            literal = rs[k, stop - k].to_s
            next unless bad_escape(literal).empty?

            value = unescape(literal)
            tests << TestCaseInfo.new(value, method_name(value), i + 1)
          end
        end
        if copied.include?(path)
          refuse_unreadable(path, view)
          scratch = Array.new(0) { "" }
          lines.each { |raw| scratch << raw }
          classes = rewrite_classes(path, lines, codes, view.code_start, scratch, forms)
        end
        form = classes.empty? ? :top_level : :class
        TestFile.new(path, form, classes, tests, helpers, copied.include?(path) ? "gen/#{path}" : "")
      end

      def self.refuse_unreadable(path, view)
        return nil if view.error_line.zero?

        msg = "#{path}:#{view.error_line}: #{view.error_text}"
        raise ArgumentError, msg
      end

      def self.rewrite_view(file_text, view, path, forms, copied)
        refuse_unreadable(path, view)
        lines = file_text.lines
        codes = view.codes
        out = Array.new(0) { "" }
        lines.each { |raw| out << raw }
        lines.each_with_index do |raw, i|
          next unless view.code_start[i]

          code = codes[i]
          ind = ControllerScan.indent_of(code)
          s = code.strip
          rs = raw[ind, s.size].to_s
          if s.start_with?("require ") || s.start_with?("require(")
            out[i] = newline(raw) if helper_require?(rs)
          elsif s.start_with?("require_relative ") || s.start_with?("require_relative(")
            out[i] = raw[0, ind].to_s + rebased_require(rs, path, i + 1, copied) + tail(raw, ind + s.size)
          end
        end
        rewrite_classes(path, lines, codes, view.code_start, out, forms)
        out.join
      end

      # Rewrites every class-form class of the file into out, then checks
      # that each line shaped like a test declaration was one of them
      # (check_placed); answers the classes.
      def self.rewrite_classes(path, lines, codes, starts, out, forms)
        classes = Array.new(0) { TestClassInfo.new("", "", 0, []) }
        placed = Array.new(0) { 0 }
        each_form_class(path, codes, starts, forms) do |start, last, name|
          head = class_head(codes[start].strip)
          classes << TestClassInfo.new(name, head[1], start + 1, rewrite_class(lines, codes, starts, out, start, last, name, path, placed))
        end
        check_placed(path, lines, placed)
        classes
      end

      # The safety net: in a class-form file, every raw line shaped like a
      # test declaration (dsl_line?) must be one the rewrite converted
      # (`placed`, 0-based); any other (inside a condition, a loop, a
      # nested class, or a string or heredoc, or one a lexical guess hid)
      # is refused, so that no test is ever silently left out.
      def self.check_placed(path, lines, placed)
        lines.each_with_index do |raw, i|
          next if placed.include?(i) || !dsl_line?(raw)

          msg = "#{path}:#{i + 1}: #{UNPLACED}"
          raise ArgumentError, msg
        end
        nil
      end

      # A raw line shaped like `test "x"`, `test(...`, `setup do`,
      # `setup {`, `setup :name` (teardown alike), whatever surrounds it.
      def self.dsl_line?(raw)
        s = raw.strip
        if s.start_with?("test")
          rest = s[4, s.size - 4].to_s
          return true if rest.start_with?("(")
          return false unless rest.start_with?(" ")

          r = rest.lstrip
          return r.start_with?("\"") || r.start_with?("'") || r.start_with?("(")
        end
        ["setup", "teardown"].each do |word|
          next unless s.start_with?(word)

          rest = s[word.size, s.size - word.size].to_s
          first = rest[0].to_s
          return false unless first == " " || first == "{" || first == "(" || first == ":"

          r = rest.lstrip
          return true if r.start_with?("{") || r.start_with?(":") || r.start_with?("(")

          return r == "do" || r.start_with?("do ") || r.start_with?("do|") || r.start_with?("do;")
        end
        false
      end

      # Yields (class line index, closing `end` index, class name) for each
      # class-form class opened at the left margin; for one opened and
      # closed on its line, both indices are that line's.
      def self.each_form_class(path, codes, starts, forms)
        i = 0
        while i < codes.size
          code = codes[i]
          s = code.strip
          head = class_head(s)
          if starts[i] && ControllerScan.indent_of(code).zero? && !head[1].empty? && forms.include?(head[1])
            if one_line_class?(s)
              yield i, i, head[0]
              i += 1
            else
              stop = block_end(codes, i + 1, 0)
              if stop < 0
                msg = "#{path}:#{i + 1}: #{head[0]} has no `end` at the left margin"
                raise ArgumentError, msg
              end
              yield i, stop - 1, head[0]
              i = stop
            end
          else
            i += 1
          end
        end
        nil
      end

      # The index after the first `end` at most `indent` deep from `from`
      # on, among code lines; -1 when there is none.
      def self.block_end(codes, from, indent)
        j = from
        while j < codes.size
          code = codes[j]
          j += 1
          line = code.strip
          next if line.empty?
          return j if ControllerScan.indent_of(code) <= indent && ControllerScan.closing_end?(line)
        end
        -1
      end

      # ["ArticlesControllerTest", "ActionDispatch::IntegrationTest"] for a
      # `class X < Y` line (code form); the superclass is "" for a class
      # opened without one; both "" for anything else (`class << self`).
      def self.class_head(s)
        return ["", ""] unless s.start_with?("class ") && !s.start_with?("class <<")

        body = s[6, s.size - 6].to_s
        semi = body.index(";")
        body = body[0, semi].to_s unless semi.nil?
        lt = body.index("<")
        return [body.strip, ""] if lt.nil?

        name = body[0, lt].to_s.strip
        sup = body[lt + 1, body.size - lt - 1].to_s.strip
        sup = sup[2, sup.size - 2].to_s if sup.start_with?("::")
        [name, sup]
      end

      # `class X < Y; end`: a class opened and closed on its line (code
      # form), not `class X < Y; include Foo`.
      def self.one_line_class?(s)
        code = s.rstrip
        return false if code.index(";").nil? || !code.end_with?("end")
        return true if code.size == 3

        before = code[code.size - 4].to_s
        before == " " || before == ";"
      end

      # The rewrite of one class-form class (lines[start] its class line,
      # lines[last] its `end`) into out; answers its tests.
      def self.rewrite_class(lines, codes, starts, out, start, last, name, path, placed)
        snake = Inflector.underscore(name).gsub("/", "_")
        cases = Array.new(0) { TestCaseInfo.new("", "", 0) }
        seen = Array.new(0) { "" }
        setups = Array.new(0) { "" }
        teardowns = Array.new(0) { "" }
        setup_do = 0
        teardown_do = 0
        def_setup = 0
        def_teardown = 0
        level = body_level(codes, starts, start, last, path)
        j = start + 1
        while j < last
          code = codes[j]
          if !starts[j] || code.strip.empty? || ControllerScan.indent_of(code) != level
            j += 1
            next
          end
          s = code.strip
          rs = lines[j][level, s.size].to_s
          k = test_start(s)
          if k >= 0 && quote?(s[k].to_s)
            stop = literal_end(rs, k)
            if stop < 0
              msg = "#{path}:#{j + 1}: a test name must be a string literal (no interpolation) in a test class"
              raise ArgumentError, msg
            end
            literal = rs[k, stop - k].to_s
            escape = bad_escape(literal)
            unless escape.empty?
              msg = "#{path}:#{j + 1}: the escape \\#{escape} in a test name is not supported; write the character itself"
              raise ArgumentError, msg
            end
            value = unescape(literal)
            meth = method_name(value)
            refuse_collision(path, j + 1, "test #{literal}", meth, cases, seen)
            cases << TestCaseInfo.new(value, meth, j + 1)
            seen << "test #{literal}"
            placed << j
            j = convert_block(lines, codes, out, j, level, DEF + meth, after_do(s, stop, path, j + 1), last, path, "test #{literal}")
          elsif call_of?(s, "test")
            msg = "#{path}:#{j + 1}: a test name must be a string literal in a test class"
            raise ArgumentError, msg
          elsif block_word?(s, "setup")
            setup_do = j + 1 if setup_do.zero?
            setups << "setup_#{snake}_#{setups.size + 1}"
            placed << j
            j = convert_block(lines, codes, out, j, level, DEF + setups.last.to_s, 8, last, path, "setup do")
          elsif block_word?(s, "teardown")
            teardown_do = j + 1 if teardown_do.zero?
            teardowns << "teardown_#{snake}_#{teardowns.size + 1}"
            placed << j
            j = convert_block(lines, codes, out, j, level, DEF + teardowns.last.to_s, 11, last, path, "teardown do")
          elsif call_of?(s, "setup") || call_of?(s, "teardown")
            refuse_other_form(s, path, j + 1)
          elsif override?(s, "setup")
            def_setup = j + 1
            j = convert_override(lines, codes, out, j, level, "setup", last, path)
          elsif override?(s, "teardown")
            def_teardown = j + 1
            j = convert_override(lines, codes, out, j, level, "teardown", last, path)
          elsif s.start_with?("#{DEF}test_") && override?(s, def_name(s))
            meth = def_name(s)
            refuse_collision(path, j + 1, "def #{meth}", meth, cases, seen)
            cases << TestCaseInfo.new(meth, meth, j + 1)
            seen << "def #{meth}"
            j = convert_override(lines, codes, out, j, level, meth, last, path)
          else
            j += 1
          end
        end
        both_refused(path, name, "setup", setup_do, def_setup)
        both_refused(path, name, "teardown", teardown_do, def_teardown)
        out[start] = class_line(lines[start], codes[start], setups, teardowns) unless setups.empty? && teardowns.empty?
        cases
      end

      # The class body's own indentation: the least of its code lines (a
      # first line indented deeper does not shift it); a body that mixes
      # tabs and spaces is refused.
      def self.body_level(codes, starts, start, last, path)
        level = -1
        tabs = false
        spaces = false
        j = start + 1
        while j < last
          code = codes[j]
          if starts[j] && !code.strip.empty?
            ind = ControllerScan.indent_of(code)
            lead = code[0, ind].to_s
            tabs ||= !lead.index("\t").nil?
            spaces ||= !lead.index(" ").nil?
            if tabs && spaces
              msg = "#{path}:#{j + 1}: the indentation mixes tabs and spaces; indent this test class with one or the other"
              raise ArgumentError, msg
            end
            level = ind if level < 0 || ind < level
          end
          j += 1
        end
        level
      end

      def self.refuse_collision(path, number, what, meth, cases, seen)
        cases.each_with_index do |c, n|
          next unless c.case_method == meth

          msg = "#{path}:#{number}: #{what} has the same method name #{meth} as #{seen[n]} (line #{c.case_line})"
          raise ArgumentError, msg
        end
        nil
      end

      def self.refuse_other_form(s, path, number)
        word = s.start_with?("setup") ? "setup" : "teardown"
        rest = s[word.size, s.size - word.size].to_s.lstrip
        rest = rest[1, rest.size - 1].to_s.lstrip if rest.start_with?("(")
        form = if rest.start_with?("{")
                 "`#{word} { ... }`"
               elsif rest.start_with?(":")
                 "`#{word} :name`"
               else
                 "`#{s}`"
               end
        msg = "#{path}:#{number}: #{form} is not supported in a test class; write `#{word} do ... end`"
        raise ArgumentError, msg
      end

      def self.both_refused(path, name, word, block_line, def_line)
        return nil if block_line.zero? || def_line.zero?

        msg = "#{path}:#{def_line}: #{name} has both `#{word} do` (line #{block_line}) and `def #{word}`; use one"
        raise ArgumentError, msg
      end

      # The class line with the combined setup / teardown after a `;`
      # (before a trailing comment).
      def self.class_line(raw, code, setups, teardowns)
        size = code.rstrip.size
        added = +""
        unless setups.empty?
          added << "; #{DEF}setup; super; "
          setups.each { |m| added << "#{m}; " }
          added << "nil; end"
        end
        unless teardowns.empty?
          added << "; #{DEF}teardown; "
          teardowns.reverse.each { |m| added << "#{m}; " }
          added << "super; nil; end"
        end
        "#{raw[0, size]}#{added}#{tail(raw, size)}"
      end

      # The index in s just after `do`, which follows the literal ending
      # before s[stop].
      def self.after_do(s, stop, path, number)
        k = stop
        k += 1 while k < s.size && s[k] == " "
        if k < s.size && s[k] == ")"
          k += 1
          k += 1 while k < s.size && s[k] == " "
        end
        rest = s[k, s.size - k].to_s
        unless rest == "do" || rest.start_with?("do ") || rest.start_with?("do;") || rest.start_with?("do|")
          msg = "#{path}:#{number}: expected `test \"name\" do` in a test class"
          raise ArgumentError, msg
        end
        k + 2
      end

      # lines[j] opens a block whose `do` ends before index `from` of its
      # code (at indentation `ind`): `head; begin` in its place and its
      # `end` as `end; nil; end`, or on one line `head; begin; body; end;
      # nil; end`. Answers the index after the block.
      def self.convert_block(lines, codes, out, j, ind, head, from, last, path, what)
        raw = lines[j]
        s = codes[j].strip
        rs = raw[ind, s.size].to_s
        rest = s[from, s.size - from].to_s.strip
        if rest.start_with?("|")
          msg = "#{path}:#{j + 1}: #{what} takes no block parameters"
          raise ArgumentError, msg
        end
        if rest.empty?
          e = closing_line(codes, j, ind, last, path, what)
          refuse_value_returns(codes, j + 1, e, path)
          refuse_block_jumps(codes, j + 1, e, path)
          out[j] = "#{raw[0, ind]}#{head}; begin#{tail(raw, ind + s.size)}"
          out[e] = end_line(lines[e], codes[e])
          return e + 1
        end
        body = one_line_body(s, rs, from)
        if body == "\n"
          msg = "#{path}:#{j + 1}: #{what} on one line must end with `end`"
          raise ArgumentError, msg
        end
        refuse_value_return(one_line_body(s, s, from), path, j + 1)
        refuse_block_jump(one_line_body(s, s, from), path, j + 1)
        out[j] = "#{raw[0, ind]}#{one_line_def(head, body)}#{tail(raw, ind + s.size)}"
        j + 1
      end

      # A class's own `def setup` / `def teardown` / `def test_x`: its body
      # in a `begin`, answering nil.
      def self.convert_override(lines, codes, out, j, ind, name, last, path)
        raw = lines[j]
        s = codes[j].strip
        rs = raw[ind, s.size].to_s
        k = 4 + name.size
        k += 2 if s[k, 2] == "()"
        after = s[k, s.size - k].to_s
        if after.empty?
          e = closing_line(codes, j, ind, last, path, "def #{name}")
          refuse_value_returns(codes, j + 1, e, path)
          out[j] = "#{raw[0, ind]}#{rs}; begin#{tail(raw, ind + s.size)}"
          out[e] = end_line(lines[e], codes[e])
          return e + 1
        end
        if after.lstrip.start_with?("=")
          eq = s.index("=", k).to_i
          refuse_value_return(s[eq + 1, s.size - eq - 1].to_s, path, j + 1)
          body = rs[eq + 1, rs.size - eq - 1].to_s.strip
          out[j] = "#{raw[0, ind]}#{one_line_def(DEF + name, body)}#{tail(raw, ind + s.size)}"
          return j + 1
        end
        body = one_line_body(s, rs, k)
        if body == "\n"
          msg = "#{path}:#{j + 1}: def #{name} on one line must end with `end`"
          raise ArgumentError, msg
        end
        refuse_value_return(one_line_body(s, s, k), path, j + 1)
        out[j] = "#{raw[0, ind]}#{one_line_def(DEF + name, body)}#{tail(raw, ind + s.size)}"
        j + 1
      end

      def self.one_line_def(head, body)
        body.empty? ? "#{head}; nil; end" : "#{head}; begin; #{body}; end; nil; end"
      end

      # The index of the `end` closing the block opened on line j.
      def self.closing_line(codes, j, ind, last, path, what)
        stop = block_end(codes, j + 1, ind)
        e = stop - 1
        unless stop > j + 1 && e < last && ControllerScan.indent_of(codes[e]) == ind
          msg = "#{path}:#{j + 1}: #{what} has no `end` at its indentation"
          raise ArgumentError, msg
        end
        after = codes[e].strip
        after = after[3, after.size - 3].to_s.strip
        unless after.empty? || after.start_with?(";")
          msg = "#{path}:#{e + 1}: the `end` closing #{what} must stand alone (nothing but a comment after it)"
          raise ArgumentError, msg
        end
        e
      end

      # `next`, `break` or `redo` heading a statement at the block body's
      # own indentation (lines from...stop): it left the block, it would
      # not leave the method the block becomes.
      def self.refuse_block_jumps(codes, from, stop, path)
        level = -1
        j = from
        while j < stop
          code = codes[j]
          s = code.strip
          unless s.empty?
            level = ControllerScan.indent_of(code) if level < 0
            refuse_block_jump(s, path, j + 1) if ControllerScan.indent_of(code) == level
          end
          j += 1
        end
        nil
      end

      def self.refuse_block_jump(s, path, number)
        ["next", "break", "redo"].each do |word|
          next unless s.start_with?(word) && !word_char?(s[word.size].to_s)

          msg = "#{path}:#{number}: `#{word}` in a test, setup or teardown body is not supported (the block is now a method); use `return`"
          raise ArgumentError, msg
        end
        nil
      end

      # `def setup`, `def setup()`, `def setup = x` or `def setup; x; end`
      # (code form; not `def setup_x`, not one with parameters).
      def self.override?(s, name)
        head = "#{DEF}#{name}"
        return false if name.empty? || !s.start_with?(head)

        after = s[head.size, s.size - head.size].to_s
        after = after[2, after.size - 2].to_s if after.start_with?("()")
        after.empty? || after.start_with?(";") || (after.lstrip.start_with?("=") && !after.lstrip.start_with?("=="))
      end

      # `setup do`, `setup do # x` or `setup do ... end` (code form).
      def self.block_word?(s, word)
        head = "#{word} do"
        return false unless s.start_with?(head)

        s.size == head.size || s[head.size] == " " || s[head.size] == ";" || s[head.size] == "|"
      end

      # An `end` line as `end; nil; end`, its indentation and trailer kept.
      def self.end_line(raw, code)
        ind = ControllerScan.indent_of(code)
        "#{raw[0, ind]}end; nil; #{raw[ind, raw.size - ind]}"
      end

      # raw's text from index `from` on (a trailing comment, the newline).
      def self.tail(raw, from)
        raw[from, raw.size - from].to_s
      end

      # The body of a block or def written on one line: `text` (the code
      # or the raw form of `code`) from index `from`, without its leading
      # `;` and its final `end`; "\n" when the line does not end with
      # `end` (judged on `code`).
      def self.one_line_body(code, text, from)
        tail_code = code[from, code.size - from].to_s.rstrip
        return "\n" unless tail_code.end_with?("end")
        return "" if tail_code.strip == "end" || tail_code.strip == ";end" || tail_code.strip == "; end"

        before = tail_code[tail_code.size - 4].to_s
        return "\n" unless before == " " || before == ";"

        stop = from + tail_code.size - 3
        body = text[from, stop - from].to_s.strip
        body = body[1, body.size - 1].to_s.strip while body.start_with?(";")
        body = body[0, body.size - 1].to_s.strip while body.end_with?(";")
        body
      end

      def self.refuse_value_returns(codes, from, stop, path)
        j = from
        while j < stop
          refuse_value_return(codes[j], path, j + 1)
          j += 1
        end
        nil
      end

      # A `return` with a value in code (strings and comments are blank
      # there); a bare `return`, `return nil` and `return if x` pass.
      def self.refuse_value_return(code, path, number)
        k = code.index("return")
        until k.nil?
          before = k.zero? ? "" : code[k - 1].to_s
          after = code[k + 6].to_s
          if !word_char?(before) && before != "." && before != ":" && !word_char?(after) && after != "?" && after != "!"
            rest = code[k + 6, code.size - k - 6].to_s.strip
            unless value_free?(rest)
              msg = "#{path}:#{number}: #{RETURN_REFUSED}"
              raise ArgumentError, msg
            end
          end
          k = code.index("return", k + 6)
        end
        nil
      end

      def self.value_free?(rest)
        return true if rest.empty? || rest.start_with?(";") || rest.start_with?("}") || rest.start_with?(")")
        return true if rest.start_with?("if ") || rest.start_with?("unless ") || rest == "end" || rest.start_with?("end ")

        return false unless rest.start_with?("nil")

        nxt = rest[3].to_s
        !word_char?(nxt)
      end

      # The index of the name's opening quote in `test "x" do` / `test("x")
      # do`, -1 when s is no `test` call with a name after it.
      def self.test_start(s)
        return -1 unless s.start_with?("test ") || s.start_with?("test(")

        k = 4
        k += 1 while k < s.size && s[k] == " "
        k += 1 if k < s.size && s[k] == "("
        k += 1 while k < s.size && s[k] == " "
        k
      end

      def self.quote?(ch)
        ch == "\"" || ch == "'"
      end

      # The index after the closing quote of the literal opening at s[k];
      # -1 when it does not close on the line or interpolates.
      def self.literal_end(s, k)
        quote = s[k].to_s
        i = k + 1
        while i < s.size
          ch = s[i].to_s
          if ch == "\\"
            i += 2
            next
          end
          return -1 if quote == "\"" && ch == "#" && s[i + 1].to_s == "{"
          return i + 1 if ch == quote

          i += 1
        end
        -1
      end

      # The letter of the first escape in a double-quoted literal that
      # unescape does not read (\u, \x, \c, \C, \M, an octal one but \0);
      # "" when there is none.
      def self.bad_escape(literal)
        return "" unless literal[0].to_s == "\""

        i = 1
        while i < literal.size - 1
          if literal[i].to_s == "\\"
            nxt = literal[i + 1].to_s
            return nxt if "uxcCM1234567".include?(nxt)

            i += 2
          else
            i += 1
          end
        end
        ""
      end

      # The value of a literal written with its quotes ("say \"hi\"" ->
      # say "hi").
      def self.unescape(literal)
        quote = literal[0].to_s
        inner = literal[1, literal.size - 2].to_s
        out = +""
        i = 0
        while i < inner.size
          ch = inner[i].to_s
          nxt = inner[i + 1].to_s
          if ch == "\\" && !nxt.empty?
            if quote == "'"
              out << "\\" unless nxt == "'" || nxt == "\\"
              out << nxt
            else
              out << escaped(nxt)
            end
            i += 2
          else
            out << ch
            i += 1
          end
        end
        out
      end

      def self.escaped(ch)
        return "\n" if ch == "n"
        return "\t" if ch == "t"
        return " " if ch == "s"
        return "\r" if ch == "r"
        return "\e" if ch == "e"
        return "\a" if ch == "a"
        return "\b" if ch == "b"
        return "\f" if ch == "f"
        return "\v" if ch == "v"
        return "\0" if ch == "0"

        ch
      end

      def self.word_char?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
      end

      # `require "test_helper"` (the bundle requires the helper first); s
      # without a comment.
      def self.helper_require?(s)
        ["require \"test_helper\"", "require 'test_helper'", "require(\"test_helper\")", "require('test_helper')"].include?(s)
      end

      # `require_relative "<target>"...` (s from the keyword on, no
      # comment) with the target rebased for the copy (plan decision 20).
      def self.rebased_require(s, path, number, copied)
        k = 16
        k += 1 while k < s.size && s[k] == " "
        k += 1 if k < s.size && s[k] == "("
        k += 1 while k < s.size && s[k] == " "
        stop = quote?(s[k].to_s) ? literal_end(s, k) : -1
        if stop < 0
          msg = "#{path}:#{number}: require_relative needs a string literal (gen rebases it for the copy under gen/test/)"
          raise ArgumentError, msg
        end
        target = rebase(path, unescape(s[k, stop - k].to_s), copied)
        "#{s[0, k]}\"#{target}\"#{s[stop, s.size - stop]}"
      end

      # The target of `require_relative target` in path, as the copy
      # gen/<path> must write it: resolved against path's directory, then
      # pointed at the copy when that file is copied too, and written
      # relative to the copy's directory.
      def self.rebase(path, target, copied)
        resolved = normalize("#{File.dirname(path)}/#{target}")
        file = resolved.end_with?(".rb") ? resolved : "#{resolved}.rb"
        dest = copied.include?(file) ? "gen/#{resolved}" : resolved
        relative_path(File.dirname("gen/#{path}"), dest)
      end

      # "test/../config/app" -> "config/app".
      def self.normalize(path)
        parts = Array.new(0) { "" }
        path.split("/").each do |part|
          next if part.empty? || part == "."

          if part == ".." && !parts.empty? && parts.last != ".."
            parts.pop
          else
            parts << part
          end
        end
        parts.join("/")
      end

      # `to` written relative to the directory `from` (both under root).
      def self.relative_path(from, to)
        a = from.split("/")
        b = to.split("/")
        n = 0
        n += 1 while n < a.size && n < b.size - 1 && a[n] == b[n]
        parts = Array.new(0) { "" }
        (a.size - n).times { parts << ".." }
        b[n, b.size - n].to_a.each { |p| parts << p }
        parts.join("/")
      end

      def self.newline(raw)
        return "\r\n" if raw.end_with?("\r\n")

        raw.end_with?("\n") ? "\n" : ""
      end

      # The name of `def name...` ("" for anything else).
      def self.def_name(s)
        out = +""
        s[4, s.size - 4].to_s.each_char do |ch|
          break unless word_char?(ch) || ch == "?" || ch == "!"

          out << ch
        end
        out
      end

      # `NAME = ...` (not `NAME == ...`).
      def self.constant_line?(s)
        first = s[0].to_s
        return false unless first >= "A" && first <= "Z"

        name = constant_name(s)
        rest = s[name.size, s.size - name.size].to_s.lstrip
        rest.start_with?("=") && !rest.start_with?("==") && !rest.start_with?("=~")
      end

      def self.constant_name(s)
        out = +""
        s.each_char do |ch|
          break unless word_char?(ch)

          out << ch
        end
        out
      end
    end
  end
end
