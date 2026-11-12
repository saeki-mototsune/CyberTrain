require "cybertrain/test_files"
require "cybertrain/generator/inflector"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/concern_scan"

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

    # The lexical scan of test/ (spec 5.2): which files are tests, which
    # classes are Rails-shaped test classes ("class form"), and the rewrite
    # of a class-form file into gen/test/<path under test/>, where every
    # `test "name" do` is a method, so that no stored block is ever run
    # through a base-class receiver (spikes/NOTES.md rule 88).
    #
    # The rewrite keeps every line where it was (plan decision 18):
    # `require "test_helper"` becomes an empty line; `test "shows it" do`
    # becomes `def test_shows_it`; the n-th `setup do` of
    # ArticlesControllerTest becomes `def setup_articles_controller_test_<n>`
    # (and `teardown do` likewise), and the class line gains, after a `;`,
    # one `setup` calling `super` then those methods in order, and one
    # `teardown` calling them in reverse then `super`. Each of those
    # methods, and a `def setup` / `def teardown` the class writes itself,
    # ends in `nil; end` (pre-flight ruling R8: one return type per method
    # name across the program, rule 34). Each `require_relative` is rebased
    # for the copy's directory (plan decision 20). Blocks are found by
    # indentation (ConcernScan.skip_block), as for concerns.
    module TestScan
      # The framework's test classes; an application class inheriting from
      # one of them (or from such a class, in any scanned file) is class
      # form too.
      BASES = ["ActiveSupport::TestCase", "ActionDispatch::IntegrationTest", "ViewComponent::TestCase"].freeze
      # gen/test/data.rb is the fixtures' file (TestDataEmitter): no copy
      # may take its place.
      DATA_FILE = "gen/test/data.rb".freeze
      DEF = "def ".freeze

      # Every scanned file of root, each a TestFile: test/test_helper.rb,
      # then test/support/**/*.rb, then TestFiles.list(root). Raises
      # ArgumentError ("<path>:<line>: ...") on what the rewrite refuses.
      def self.scan(root)
        paths = scanned_paths(root)
        sources = read_all(root, paths)
        forms = class_forms(paths, sources)
        copied = copied_paths(paths, sources, forms)
        files = Array.new(0) { TestFile.new("", :top_level, [], [], [], "") }
        paths.each_with_index { |path, k| files << scan_source(path, sources[k], forms, copied) }
        files
      end

      # "gen/test/<path under test/>" => the rewritten source, for every
      # scanned file that holds a class-form class (the helper and support
      # files included), in scan order.
      def self.copies(root)
        paths = scanned_paths(root)
        sources = read_all(root, paths)
        forms = class_forms(paths, sources)
        copied = copied_paths(paths, sources, forms)
        out = { "" => "" }
        out.delete("")
        paths.each_with_index do |path, k|
          next unless copied.include?(path)

          rel = "gen/#{path}"
          if rel == DATA_FILE
            msg = "#{path}: gen/test/data.rb holds the fixtures; rename this test file"
            raise ArgumentError, msg
          end
          text = rewrite_in(sources[k], path, forms, copied)
          text = "#{text}\n" unless text.empty? || text.end_with?("\n")
          out[rel] = "#{text}# Generated by `spin run gen` from #{path}. Do not edit.\n"
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
        paths = [path]
        sources = [file_text]
        rewrite_in(file_text, path, class_forms(paths, sources), Array.new(0) { "" })
      end

      # The copy of path (file_text) given the class-form class names of
      # every scanned file and the paths gen copies (plan decision 20).
      def self.rewrite_in(file_text, path, forms, copied)
        lines = file_text.lines
        out = Array.new(0) { "" }
        lines.each { |raw| out << raw }
        lines.each_with_index do |raw, i|
          ind = ControllerScan.indent_of(raw)
          s = raw.strip
          if helper_require?(s)
            out[i] = newline(raw)
          elsif s.start_with?("require_relative ") || s.start_with?("require_relative(")
            out[i] = raw[0, ind].to_s + rebased_require(raw[ind, raw.size - ind].to_s, path, i + 1, copied)
          end
        end
        each_form_class(lines, forms) { |start, last, name| rewrite_class(lines, out, start, last, name, path) }
        out.join
      end

      # ---- the scan ----

      def self.scanned_paths(root)
        paths = Array.new(0) { "" }
        paths << TestFiles::HELPER if File.exist?("#{root}/#{TestFiles::HELPER}")
        TestFiles.support_files(root).each { |p| paths << p }
        TestFiles.list(root).each { |p| paths << p }
        paths
      end

      def self.read_all(root, paths)
        sources = Array.new(0) { "" }
        paths.each { |p| sources << File.read("#{root}/#{p}") }
        sources
      end

      # The class-form class names: BASES, then every class (of any of the
      # sources) whose superclass is already one, until none is added.
      def self.class_forms(paths, sources)
        names = Array.new(0) { "" }
        supers = Array.new(0) { "" }
        sources.each do |text|
          text.lines.each do |raw|
            next unless ControllerScan.indent_of(raw).zero?

            head = class_head(raw.strip)
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

      # The paths among `paths` whose source holds a class-form class.
      def self.copied_paths(paths, sources, forms)
        copied = Array.new(0) { "" }
        paths.each_with_index { |p, k| copied << p if holds_form_class?(sources[k], forms) }
        copied
      end

      def self.holds_form_class?(text, forms)
        text.lines.each do |raw|
          next unless ControllerScan.indent_of(raw).zero?

          head = class_head(raw.strip)
          return true if !head[1].empty? && forms.include?(head[1])
        end
        false
      end

      def self.scan_source(path, text, forms, copied)
        lines = text.lines
        classes = Array.new(0) { TestClassInfo.new("", "", 0, []) }
        tests = Array.new(0) { TestCaseInfo.new("", "", 0) }
        helpers = Array.new(0) { TestHelperInfo.new("", "", 0) }
        scratch = Array.new(0) { "" }
        lines.each { |raw| scratch << raw }
        lines.each_with_index do |raw, i|
          next unless ControllerScan.indent_of(raw).zero?

          s = raw.strip
          if s.start_with?("def ") && !s.start_with?("def self.")
            name = def_name(s)
            helpers << TestHelperInfo.new(name, "def", i + 1) unless name.empty?
          elsif constant_line?(s)
            helpers << TestHelperInfo.new(constant_name(s), "constant", i + 1)
          else
            k = test_start(s)
            next if k < 0 || !quote?(s[k].to_s)

            stop = literal_end(s, k)
            next if stop < 0

            value = unescape(s[k, stop - k].to_s)
            tests << TestCaseInfo.new(value, method_name(value), i + 1)
          end
        end
        each_form_class(lines, forms) do |start, last, name|
          head = class_head(lines[start].strip)
          classes << TestClassInfo.new(name, head[1], start + 1, rewrite_class(lines, scratch, start, last, name, path))
        end
        form = classes.empty? ? :top_level : :class
        TestFile.new(path, form, classes, tests, helpers, copied.include?(path) ? "gen/#{path}" : "")
      end

      # Yields (class line index, closing `end` index, class name) for each
      # class-form class opened at the left margin; for one opened and
      # closed on its line, both indices are that line's.
      def self.each_form_class(lines, forms)
        i = 0
        while i < lines.size
          raw = lines[i]
          s = raw.strip
          head = class_head(s)
          if ControllerScan.indent_of(raw).zero? && !head[1].empty? && forms.include?(head[1])
            stop = one_line_class?(s) ? i + 1 : ConcernScan.skip_block(lines, i + 1, 0)
            yield i, stop == i + 1 ? i : stop - 1, head[0]
            i = stop
          else
            i += 1
          end
        end
        nil
      end

      # ["ArticlesControllerTest", "ActionDispatch::IntegrationTest"] for a
      # `class X < Y` line; the superclass is "" for a line that opens no
      # class with one (a reopened class, `class << self`, anything else).
      def self.class_head(s)
        return ["", ""] unless s.start_with?("class ") && !s.start_with?("class <<")

        code = code_part(s)
        body = code[6, code.size - 6].to_s
        semi = body.index(";")
        body = body[0, semi].to_s unless semi.nil?
        lt = body.index("<")
        return [body.strip, ""] if lt.nil?

        name = body[0, lt].to_s.strip
        sup = body[lt + 1, body.size - lt - 1].to_s.strip
        sup = sup[2, sup.size - 2].to_s if sup.start_with?("::")
        [name, sup]
      end

      # `class X < Y; end`: a class opened and closed on its line.
      def self.one_line_class?(s)
        !code_part(s).index(";").nil?
      end

      # s without a trailing ` # comment`.
      def self.code_part(s)
        k = s.index(" #")
        k.nil? ? s : s[0, k].to_s.rstrip
      end

      # The rewrite of one class-form class (lines[start] its class line,
      # lines[last] its `end`) into out; answers its tests.
      def self.rewrite_class(lines, out, start, last, name, path)
        snake = Inflector.underscore(name).gsub("/", "_")
        cases = Array.new(0) { TestCaseInfo.new("", "", 0) }
        literals = Array.new(0) { "" }
        setups = Array.new(0) { "" }
        teardowns = Array.new(0) { "" }
        setup_do = 0
        teardown_do = 0
        def_setup = 0
        def_teardown = 0
        j = start + 1
        while j < last
          s = lines[j].strip
          k = test_start(s)
          if k >= 0 && quote?(s[k].to_s)
            stop = literal_end(s, k)
            if stop < 0
              msg = "#{path}:#{j + 1}: a test name must be a string literal (no interpolation) in a test class"
              raise ArgumentError, msg
            end
            literal = s[k, stop - k].to_s
            value = unescape(literal)
            meth = method_name(value)
            cases.each_with_index do |c, n|
              next unless c.case_method == meth

              msg = "#{path}:#{j + 1}: test #{literal} has the same method name #{meth} as test #{literals[n]} (line #{c.case_line})"
              raise ArgumentError, msg
            end
            cases << TestCaseInfo.new(value, meth, j + 1)
            literals << literal
            j = convert_block(lines, out, j, DEF + meth, block_rest(s, stop, path, j + 1), path, "test #{literal}")
          elsif k >= 0 && block_line?(s)
            msg = "#{path}:#{j + 1}: a test name must be a string literal in a test class"
            raise ArgumentError, msg
          elsif block_word?(s, "setup")
            setup_do = j + 1 if setup_do.zero?
            setups << "setup_#{snake}_#{setups.size + 1}"
            j = convert_block(lines, out, j, DEF + setups.last.to_s, s[8, s.size - 8].to_s.strip, path, "setup do")
          elsif block_word?(s, "teardown")
            teardown_do = j + 1 if teardown_do.zero?
            teardowns << "teardown_#{snake}_#{teardowns.size + 1}"
            j = convert_block(lines, out, j, DEF + teardowns.last.to_s, s[11, s.size - 11].to_s.strip, path, "teardown do")
          elsif override?(s, "setup")
            def_setup = j + 1
            j = convert_override(lines, out, j, "setup", path)
          elsif override?(s, "teardown")
            def_teardown = j + 1
            j = convert_override(lines, out, j, "teardown", path)
          else
            j += 1
          end
        end
        both_refused(path, name, "setup", setup_do, def_setup)
        both_refused(path, name, "teardown", teardown_do, def_teardown)
        out[start] = class_line(lines[start], setups, teardowns) unless setups.empty? && teardowns.empty?
        cases
      end

      def self.both_refused(path, name, word, block_line, def_line)
        return nil if block_line.zero? || def_line.zero?

        msg = "#{path}:#{def_line}: #{name} has both `#{word} do` (line #{block_line}) and `def #{word}`; use one"
        raise ArgumentError, msg
      end

      # The class line with the combined setup / teardown after a `;`
      # (before a trailing comment).
      def self.class_line(raw, setups, teardowns)
        line = raw.chomp
        code = code_part(line)
        comment = line[code.size, line.size - code.size].to_s
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
        "#{code}#{added}#{comment}#{newline(raw)}"
      end

      # What follows the literal ending before s[stop]: `do` and the rest
      # of the line after it.
      def self.block_rest(s, stop, path, number)
        t = s[stop, s.size - stop].to_s.lstrip
        t = t[1, t.size - 1].to_s.lstrip if t.start_with?(")")
        unless t == "do" || t.start_with?("do ") || t.start_with?("do;")
          msg = "#{path}:#{number}: expected `test \"name\" do` in a test class"
          raise ArgumentError, msg
        end
        t[2, t.size - 2].to_s.strip
      end

      # lines[j] is `<word> do` (rest: what follows `do`): `head` in its
      # place, its `end` as `nil; end`, or on one line `head; body; nil;
      # end`. Answers the index after the block.
      def self.convert_block(lines, out, j, head, rest, path, what)
        raw = lines[j]
        ind = ControllerScan.indent_of(raw)
        pre = raw[0, ind].to_s
        if rest.start_with?("|")
          msg = "#{path}:#{j + 1}: #{what} takes no block parameters"
          raise ArgumentError, msg
        end
        if rest.empty? || rest.start_with?("#")
          stop = ConcernScan.skip_block(lines, j + 1, ind)
          e = stop - 1
          unless e > j && e < lines.size && ControllerScan.closing_end?(lines[e].strip)
            msg = "#{path}:#{j + 1}: #{what} has no `end` at its indentation"
            raise ArgumentError, msg
          end
          out[j] = "#{pre}#{head}#{rest.empty? ? "" : " #{rest}"}#{newline(raw)}"
          out[e] = nil_end(lines[e])
          return stop
        end
        body = one_line_body(rest)
        if body == "\n"
          msg = "#{path}:#{j + 1}: #{what} on one line must end with `end`"
          raise ArgumentError, msg
        end
        out[j] = "#{pre}#{head}; #{body.empty? ? "" : "#{body}; "}nil; end#{newline(raw)}"
        j + 1
      end

      # A class's own `def setup` (or teardown): its value made nil.
      def self.convert_override(lines, out, j, word, path)
        raw = lines[j]
        ind = ControllerScan.indent_of(raw)
        pre = raw[0, ind].to_s
        s = code_part(raw.strip)
        after = s[4 + word.size, s.size - 4 - word.size].to_s
        after = after[2, after.size - 2].to_s if after.start_with?("()")
        if after.lstrip.start_with?("=")
          expr = after.lstrip
          expr = expr[1, expr.size - 1].to_s.strip
          out[j] = "#{pre}#{DEF}#{word}; #{expr}; nil; end#{newline(raw)}"
          return j + 1
        end
        if after.start_with?(";")
          body = one_line_body(after)
          if body == "\n"
            msg = "#{path}:#{j + 1}: def #{word} on one line must end with `end`"
            raise ArgumentError, msg
          end
          out[j] = "#{pre}#{DEF}#{word}; #{body.empty? ? "" : "#{body}; "}nil; end#{newline(raw)}"
          return j + 1
        end
        stop = ConcernScan.skip_block(lines, j + 1, ind)
        e = stop - 1
        unless e > j && e < lines.size && ControllerScan.closing_end?(lines[e].strip)
          msg = "#{path}:#{j + 1}: def #{word} has no `end` at its indentation"
          raise ArgumentError, msg
        end
        out[e] = nil_end(lines[e])
        stop
      end

      # `def setup`, `def setup()`, `def setup = x` or `def setup; x; end`
      # (not `def setup_x`, not one with parameters).
      def self.override?(s, word)
        head = "#{DEF}#{word}"
        return false unless s.start_with?(head)

        after = code_part(s)[head.size, s.size].to_s
        after = after[2, after.size - 2].to_s if after.start_with?("()")
        after.empty? || after.start_with?(";") || after.lstrip.start_with?("=") && !after.lstrip.start_with?("==")
      end

      # `setup do`, `setup do # x` or `setup do ... end`.
      def self.block_word?(s, word)
        head = "#{word} do"
        return false unless s.start_with?(head)

        s.size == head.size || s[head.size] == " " || s[head.size] == ";" || s[head.size] == "|"
      end

      # An `end` line as `nil; end`, its indentation and trailer kept.
      def self.nil_end(raw)
        ind = ControllerScan.indent_of(raw)
        "#{raw[0, ind]}nil; #{raw[ind, raw.size - ind]}"
      end

      # The body of `... end` written on one line ("" when empty), "\n"
      # when it does not end with `end`.
      def self.one_line_body(rest)
        code = code_part(rest).strip
        return "\n" unless code.end_with?("end")
        return "" if code == "end"

        before = code[code.size - 4, 1].to_s
        return "\n" unless before == " " || before == ";"

        body = code[0, code.size - 3].to_s.strip
        body = body[1, body.size - 1].to_s.strip while body.start_with?(";")
        body = body[0, body.size - 1].to_s.strip while body.end_with?(";")
        body
      end

      # The index of the name's opening quote in `test "x" do` / `test("x")
      # do`, -1 when s is no `test` call.
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

      # A line ending in `do` (a block opened with a computed name).
      def self.block_line?(s)
        code = code_part(s)
        code.end_with?(" do") || !code.index(" do |").nil?
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
            elsif nxt == "n"
              out << "\n"
            elsif nxt == "t"
              out << "\t"
            else
              out << nxt
            end
            i += 2
          else
            out << ch
            i += 1
          end
        end
        out
      end

      def self.word_char?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
      end

      # `require "test_helper"` (the bundle requires the helper first).
      def self.helper_require?(s)
        code = code_part(s)
        ["require \"test_helper\"", "require 'test_helper'", "require(\"test_helper\")", "require('test_helper')"].include?(code)
      end

      # `require_relative "<target>"...` (s from the keyword on) with the
      # target rebased for the copy (plan decision 20).
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
