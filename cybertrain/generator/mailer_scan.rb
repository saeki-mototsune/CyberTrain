require "cybertrain/generator/source_text"
require "cybertrain/generator/inflector"
require "cybertrain/generator/helper_scan"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/job_scan"

module Cybertrain
  module Gen
    # One action of a mailer class: its name, its parameter list as
    # written between the parentheses (`user, greeting = "Hi", copy: false`,
    # "" for none), and the arguments that pass those parameters on
    # (`user, greeting, copy: copy`).
    class MailerAction
      attr_reader :action_name, :action_params, :action_args

      def initialize(action_name, action_params, action_args)
        @action_name = action_name
        @action_params = action_params
        @action_args = action_args
      end
    end

    # What the scan found for one mailer class (docs/design.md D98): its
    # full name and file, its superclass's full name
    # ("Cybertrain::Mailer::Base", "ApplicationMailer" or another mailer),
    # its public actions, the instance variables its methods assign, its
    # `default from:` expression ("" without one), its `layout` (the name;
    # "" for `layout false`; layout_declared false without the line), and
    # the keyword of each enclosing name segment (JobInfo#scope_keywords).
    class MailerInfo
      attr_reader :mailer_file, :mailer_name, :mailer_super, :mailer_actions, :mailer_ivars, :mailer_from,
                  :mailer_layout_name, :mailer_layout_declared, :mailer_scopes

      def initialize(mailer_file, mailer_name, mailer_super, mailer_actions, mailer_ivars, mailer_from,
                     mailer_layout_name, mailer_layout_declared, mailer_scopes)
        @mailer_file = mailer_file
        @mailer_name = mailer_name
        @mailer_super = mailer_super
        @mailer_actions = mailer_actions
        @mailer_ivars = mailer_ivars
        @mailer_from = mailer_from
        @mailer_layout_name = mailer_layout_name
        @mailer_layout_declared = mailer_layout_declared
        @mailer_scopes = mailer_scopes
      end
    end

    # Reads app/mailers/**/*.rb as text (docs/design.md D4, D98), as JobScan
    # reads app/jobs: every class that descends from Cybertrain::Mailer::Base
    # (directly, through ApplicationMailer, or through another mailer
    # class), wherever it sits in a file. Per class: the public instance
    # `def`s (its actions; everything after a `private` or `protected` line
    # up to a `public` one is skipped, and so is `private def x`), each
    # with its parameter list on its line (or continued over the lines its
    # parentheses stay open), the `@name =` assignments of its whole body,
    # `default from: EXPR` on one line, and `layout "name"` / `layout
    # false`. A module (the mailers `generate authentication` writes) or a
    # class that descends from none of these is left alone. A superclass
    # must load before its subclass: application_mailer.rb loads first,
    # then the other files in path order.
    module MailerScan
      class Error < StandardError
      end

      BASE = "Cybertrain::Mailer::Base"

      # The instance methods Mailer::Base defines and gen/mailers.rb writes:
      # an action may not take one of these names (script/check-reserved-names
      # keeps the list in step with cybertrain/mailer/base.rb).
      RESERVED_ACTIONS = ["action_name", "attachments", "mail", "mailer_class_name", "mailer_default_from",
                          "mailer_layout", "mailer_path", "mailer_result", "mailer_setup", "params", "view_assigns"]

      # The class methods gen/mailers.rb writes, Mailer::Base's macros, and
      # the class's own constructor: no action may be named so either.
      RESERVED_CLASS_METHODS = ["default", "default_subject", "layout", "new", "with"]

      def self.empty_action
        MailerAction.new("", "", "")
      end

      def self.empty_info
        MailerInfo.new("", "", "", Array.new(0) { empty_action }, Array.new(0) { "" }, "", "", false, Array.new(0) { "" })
      end

      # Every mailer class under dir (app/mailers), in load order.
      def self.scan_dir(dir)
        infos = Array.new(0) { empty_info }
        files = SourceText.ruby_files(dir)
        return infos if files.empty?

        base_file = "#{dir}/application_mailer.rb"
        ordered = Array.new(0) { "" }
        ordered << base_file if files.include?(base_file)
        files.each { |path| ordered << path unless path == base_file }
        spans = Array.new(0) { JobScan.empty_class }
        ordered.each { |path| JobScan.class_definitions(path, File.read(path)).each { |d| spans << d } }
        parents = mailer_parents(spans)
        spans.each_with_index do |d, i|
          next if parents[i] == ""

          check_parent(d, spans, parents[i], ordered)
          infos << scan_body(d, File.read(d.defined_file).lines, parents[i])
        end
        infos
      end

      # Per span, its superclass's full name when it is a mailer class (BASE
      # or another span that is one), else "" (JobScan.job_parents' fixed
      # point).
      def self.mailer_parents(spans)
        parents = Array.new(0) { "" }
        spans.each { parents << "" }
        changed = true
        while changed
          changed = false
          spans.each_with_index do |d, i|
            next unless parents[i] == ""

            parent = mailer_parent(d, spans, parents)
            next if parent == ""

            parents[i] = parent
            changed = true
          end
        end
        parents
      end

      def self.mailer_parent(d, spans, parents)
        written = d.defined_super
        return "" if written == ""

        name = written.start_with?("::") ? written[2, written.size - 2].to_s : written
        return BASE if name == BASE

        JobScan.lexical_candidates(written, d.defined_name).each do |candidate|
          spans.each_with_index do |other, j|
            next unless other.defined_name == candidate

            return parents[j] == "" ? "" : candidate
          end
        end
        ""
      end

      # A mailer whose mailer superclass loads after it is refused.
      def self.check_parent(d, spans, parent, ordered)
        return nil if parent == BASE

        spans.each do |p|
          next unless p.defined_name == parent
          return nil if p.defined_file == d.defined_file && p.defined_line < d.defined_line
          return nil if p.defined_file != d.defined_file && ordered.index(p.defined_file).to_i < ordered.index(d.defined_file).to_i

          message = "#{d.defined_file}:#{d.defined_line}: #{d.defined_super} is defined in #{p.defined_file}, which does not " \
                    "load before this mailer -- define it in app/mailers/application_mailer.rb, above it in this file, " \
                    "or in a file that sorts before this one"
          raise Error, message
        end
        nil
      end

      # The body of mailer class `d`: its actions, macros and ivars, with
      # nested classes and modules skipped (a nested mailer is a span of
      # its own) and method bodies read for ivars only.
      def self.scan_body(d, lines, parent)
        file = d.defined_file
        class_indent = d.defined_indent
        skip_indent = -1
        def_indent = -1
        hidden = false
        actions = Array.new(0) { empty_action }
        ivars = Array.new(0) { "" }
        from = ""
        layout_name = ""
        layout_declared = false
        lineno = d.defined_line
        while !d.defined_one_line && lineno < lines.size
          raw = lines[lineno]
          lineno += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = SourceText.indent_of(raw)
          if skip_indent >= 0
            skip_indent = -1 if indent == skip_indent && SourceText.closing_end?(line)
            next
          end
          break if indent <= class_indent && SourceText.closing_end?(line)

          ControllerScan.ivar_names(raw).each { |n| ivars << n unless ivars.include?(n) }
          if def_indent >= 0
            def_indent = -1 if indent <= def_indent && SourceText.closing_end?(line)
            next
          end
          if SourceText.opens_block?(line)
            skip_indent = indent unless SourceText.one_line_block?(line)
            next
          end
          if line == "private" || line == "protected"
            hidden = true
            next
          end
          if line == "public"
            hidden = false
            next
          end
          text = line
          inline_hidden = false
          inline_public = false
          words = ["private ", "protected ", "public "]
          w = 0
          while w < words.size
            word = words[w]
            if text.start_with?(word) && text[word.size, text.size - word.size].to_s.lstrip.start_with?("def ")
              inline_hidden = word != "public "
              inline_public = word == "public "
              text = text[word.size, text.size - word.size].to_s.lstrip
            end
            w += 1
          end
          if text.start_with?("def ")
            joined = text
            j = lineno
            while HelperScan.open_parens(joined) > 0 && j < lines.size
              joined = "#{joined} #{lines[j].to_s.strip}"
              j += 1
            end
            name = ModelScan.def_name(joined)
            if (inline_public || !hidden) && !inline_hidden && action_name?(name)
              actions << action_at(file, lineno, joined, name)
            elsif text.start_with?("def self.")
              reserved_class_method!(file, lineno, text)
            end
            def_indent = indent if ModelScan.def_opens_body?(joined)
            lineno = j if j > lineno
            next
          end
          if macro?(line, "default")
            raise Error, "#{file}:#{lineno}: default is declared twice" unless from == ""

            from = default_from(file, lineno, line)
          elsif macro?(line, "layout")
            layout_name = layout_value(file, lineno, line)
            layout_declared = true
          end
        end
        MailerInfo.new(file, d.defined_name, parent, actions, ivars, from, layout_name, layout_declared, d.defined_scopes)
      end

      # A name an action may have: a plain method name (not a setter, an
      # operator or `initialize`); a reserved one raises.
      def self.action_name?(name)
        return false if name == "" || name == "initialize" || name.end_with?("=")

        first = name[0, 1]
        first == "_" || (first >= "a" && first <= "z")
      end

      # The MailerAction of a `def` (its parameter list joined over lines).
      def self.action_at(file, lineno, text, name)
        if RESERVED_ACTIONS.include?(name) || RESERVED_CLASS_METHODS.include?(name)
          message = "#{file}:#{lineno}: #{name} is a method of Cybertrain::Mailer::Base or one gen/mailers.rb writes; " \
                    "give the action another name"
          raise Error, message
        end
        rest = text[4, text.size - 4].to_s.lstrip
        rest = rest[name.size, rest.size - name.size].to_s
        params = ""
        if rest.start_with?("(")
          params = HelperScan.inside_parens(rest).strip
        elsif rest.start_with?(" ") && !rest.lstrip.start_with?("=") && !rest.lstrip.start_with?(";") &&
              !rest.lstrip.start_with?("#") && rest.strip != ""
          params = MailerScan.before_semicolon(HelperScan.strip_comment(rest)).strip
        end
        args = Array.new(0) { "" }
        HelperScan.split_params(params).each do |raw_param|
          param = raw_param.strip
          next if param == ""

          if param.start_with?("*") || param.start_with?("&") || param == "..."
            message = "#{file}:#{lineno}: #{name}: a mailer action takes named parameters only (no *, ** or &), " \
                      "so gen/mailers.rb can pass them on"
            raise Error, message
          end
          km = param.match(/\A([a-z_]\w*):/)
          if km
            args << "#{km[1]}: #{km[1]}"
          else
            om = param.match(/\A([a-z_]\w*)/)
            raise Error, "#{file}:#{lineno}: #{name}: cannot read the parameter '#{param}'" if om.nil?

            args << om[1].to_s
          end
        end
        MailerAction.new(name, params, args.join(", "))
      end

      # `text` up to its first `;` outside quotes and brackets (the end of a
      # parenthesis-free parameter list: `def welcome user; mail(...); end`).
      def self.before_semicolon(text)
        depth = 0
        quote = ""
        i = 0
        while i < text.size
          ch = text[i, 1]
          if quote != ""
            quote = "" if ch == quote
          elsif ch == "\"" || ch == "'"
            quote = ch
          elsif ch == "(" || ch == "[" || ch == "{"
            depth += 1
          elsif ch == ")" || ch == "]" || ch == "}"
            depth -= 1
          elsif ch == ";" && depth <= 0
            return text[0, i].to_s
          end
          i += 1
        end
        text
      end

      # `def self.with` and the like collide with the generated class methods.
      def self.reserved_class_method!(file, lineno, text)
        name = ModelScan.word_at(text, 9)
        return nil unless RESERVED_CLASS_METHODS.include?(name)

        raise Error, "#{file}:#{lineno}: #{name} is a class method gen/mailers.rb writes into every mailer; give the method another name"
      end

      # Whether `line` calls `word` as a macro (`default from: ...`,
      # `layout("mailer")`), not a local of that name.
      def self.macro?(line, word)
        return false unless line.start_with?(word)

        rest = line[word.size, line.size - word.size].to_s
        return false unless rest.start_with?(" ") || rest.start_with?("(")

        tail = rest.lstrip
        !(tail.start_with?("=") && !tail.start_with?("=>")) && !tail.start_with?(".")
      end

      # The expression of `default from: EXPR` (one line, from: alone).
      def self.default_from(file, lineno, line)
        bad = "#{file}:#{lineno}: #{line} -- write `default from: \"address\"` on one line (only from: is read)"
        text = HelperScan.strip_comment(line).strip
        raise Error, bad if ModelScan.continued?(text)

        rest = text["default".size, text.size - "default".size].to_s.strip
        if rest.start_with?("(")
          raise Error, bad unless rest.end_with?(")")

          rest = rest[1, rest.size - 2].to_s.strip
        end
        parts = HelperScan.split_params(rest)
        raise Error, bad unless parts.size == 1

        piece = parts[0].to_s.strip
        raise Error, bad unless piece.start_with?("from:")

        value = piece[5, piece.size - 5].to_s.strip
        raise Error, bad if value == ""

        value
      end

      # `layout "mailer"` -> "mailer"; `layout false` -> "".
      def self.layout_value(file, lineno, line)
        text = HelperScan.strip_comment(line).strip
        rest = text["layout".size, text.size - "layout".size].to_s.strip
        if rest.start_with?("(") && rest.end_with?(")")
          rest = rest[1, rest.size - 2].to_s.strip
        end
        return "" if rest == "false"

        size = ModelScan.quoted_literal?(rest) ? ModelScan.literal_size(rest) : 0
        if size == 0 || size != rest.size
          raise Error, "#{file}:#{lineno}: #{line} -- write layout \"name\" (a literal String) or layout false"
        end

        ModelScan.literal_text(rest).to_s
      end

      # The subject a mail without one gets when the dictionary has none
      # ("welcome_email" -> "Welcome email"), as Mailer::Base.default_subject
      # writes it.
      def self.humanized(action)
        words = action.tr("_", " ")
        return "" if words.empty?

        "#{words[0, 1].to_s.upcase}#{words[1, words.size - 1]}"
      end

      # The view directory of a mailer ("Admin::NoticeMailer" -> "admin/notice_mailer").
      def self.view_path(name)
        Inflector.underscore(name)
      end

      # The mailers `info` inherits from, nearest first.
      def self.ancestors(info, infos)
        out = Array.new(0) { empty_info }
        name = info.mailer_super
        while name != BASE && out.size < infos.size
          found = false
          infos.each do |other|
            next unless other.mailer_name == name

            out << other
            name = other.mailer_super
            found = true
            break
          end
          break unless found
        end
        out
      end
    end
  end
end
