require "cybertrain/generator/controller_scan"
require "cybertrain/generator/model_scan"

module Cybertrain
  module Gen
    # One `retry_on` / `discard_on` line of a job class (spec section 3).
    # policy_kind is "retry" or "discard"; exception_class the class the
    # generated `rescue` arm names, in full (`Stuck` written inside
    # `NestedJob` is "NestedJob::Stuck"); wait_base the seconds of `wait:`
    # (3 when not given, Rails' default), or 0 with polynomial true for
    # `wait: :polynomially_longer`; attempts the `attempts:` (5 when not
    # given); a discard line has 0, false, 0. line places error messages.
    class PolicyInfo
      attr_reader :policy_kind, :exception_class, :wait_base, :polynomial, :attempts, :line

      def initialize(policy_kind, exception_class, wait_base, polynomial, attempts, line)
        @policy_kind = policy_kind
        @exception_class = exception_class
        @wait_base = wait_base
        @polynomial = polynomial
        @attempts = attempts
        @line = line
      end
    end

    # What the scan found for one job class: the class (full name), its
    # superclass's full name ("Cybertrain::Job::Base", "ApplicationJob" or
    # another job class: `LeafJob < MidJob`), its policies in declaration
    # order (retry and discard interleaved), its `limits_concurrency`
    # (`to:`, 0 without the line; `key:`, "" without one), whether it
    # defines `perform` and `retries_exhausted`, and the keyword ("module"
    # or "class") of each enclosing name segment, outermost first
    # (["module"] for Admin::ReportJob), which the emitter reopens.
    class JobInfo
      attr_reader :file, :class_name, :superclass_name, :policies, :concurrency_to, :concurrency_key,
                  :has_perform, :has_exhausted_hook, :scope_keywords

      def initialize(file, class_name, superclass_name, policies, concurrency_to, concurrency_key, has_perform,
                     has_exhausted_hook, scope_keywords)
        @file = file
        @class_name = class_name
        @superclass_name = superclass_name
        @policies = policies
        @concurrency_to = concurrency_to
        @concurrency_key = concurrency_key
        @has_perform = has_perform
        @has_exhausted_hook = has_exhausted_hook
        @scope_keywords = scope_keywords
      end
    end

    # A `class X` line somewhere under app/: its full name, file and line,
    # its superclass as written ("" without one), its indent, whether the
    # class is one line (`class X < Y; end`), and the keyword of each
    # enclosing name segment (JobInfo#scope_keywords).
    class DefinedClass
      attr_reader :defined_name, :defined_file, :defined_line, :defined_super, :defined_indent,
                  :defined_one_line, :defined_scopes

      def initialize(defined_name, defined_file, defined_line, defined_super, defined_indent, defined_one_line, defined_scopes)
        @defined_name = defined_name
        @defined_file = defined_file
        @defined_line = defined_line
        @defined_super = defined_super
        @defined_indent = defined_indent
        @defined_one_line = defined_one_line
        @defined_scopes = defined_scopes
      end
    end

    # Reads app/jobs/**/*.rb as text (spec section 2.2), as ComponentScan
    # reads app/components: every class that descends from
    # Cybertrain::Job::Base (directly, through ApplicationJob, or through
    # another job class: `LeafJob < MidJob`), wherever it sits in a file
    # (several per file, nested in a module or a class), with one
    # `retry_on` / `discard_on` / `limits_concurrency` macro per line with
    # literal values, and the `def perform` / `def retries_exhausted`
    # lines. A class that descends from none of these is skipped (a helper
    # may live there). A job inherits its ancestors' policies (its own
    # arms first, then each ancestor's outward) and the nearest limit; a
    # superclass must load before its subclass. ApplicationJob itself is
    # scanned but is not a job: JobsEmitter writes nothing for it.
    #
    # Every exception class a macro names must be defined in the program
    # before the job's class body evaluates it (spikes/NOTES.md rule 89: a
    # `rescue` arm naming an undefined qualified class is matched by its
    # last segment under Spinel and can swallow every exception): a core
    # class (CORE_ERRORS), a framework one (FRAMEWORK_ERRORS, whose file
    # gen/app.rb requires before the jobs), or an application class defined
    # under app/models, in app/jobs/application_job.rb, or in the job's own
    # file above the macro. Anything else raises Error.
    module JobScan
      class Error < StandardError
      end

      BASE = "Cybertrain::Job::Base"
      CLASS_LINE = /\A\s*class\s+([A-Z][\w:]*)\s*(?:<\s*([A-Z:][\w:]*))?/
      MODULE_LINE = /\A\s*module\s+([A-Z][\w:]*)\s*(?:;|\z|#)/
      MACROS = ["retry_on", "discard_on", "limits_concurrency"]

      # The class methods gen/jobs.rb writes into every job class: a job
      # may not define them itself (script/check-reserved-names keeps this
      # in step with jobs_emitter.rb).
      RESERVED_CLASS_METHODS = ["job_kind", "perform_at", "perform_in", "perform_later", "perform_now", "run_job"]

      # StandardError and its core subclasses, which every program has.
      CORE_ERRORS = ["StandardError", "ArgumentError", "EncodingError", "EOFError", "FloatDomainError", "FrozenError",
                     "IndexError", "IOError", "KeyError", "NameError", "NoMethodError", "RangeError", "RegexpError",
                     "RuntimeError", "StopIteration", "ThreadError", "TypeError", "ZeroDivisionError"]

      # The framework's exception classes (every `class <Name>Error < ...`
      # under cybertrain/ outside the generator and the CLI), each with the
      # file under cybertrain/ that defines it. test/gen_jobs.rb checks the
      # list against the source.
      FRAMEWORK_ERRORS = [
        ["Cybertrain::DB::Error", "db/error"],
        ["Cybertrain::Encryptor::Error", "encryptor"],
        ["Cybertrain::HttpClient::Error", "http_client"],
        ["Cybertrain::HttpClient::TimeoutError", "http_client"],
        ["Cybertrain::HttpClient::RefusedError", "http_client"],
        ["Cybertrain::HttpClient::TLSError", "http_client"],
        ["Cybertrain::HttpClient::BlockedAddressError", "http_client"],
        ["Cybertrain::HttpClient::TooLargeError", "http_client"],
        ["Cybertrain::HttpClient::TooManyRedirectsError", "http_client"],
        ["Cybertrain::HttpClient::BadResponseError", "http_client"],
        ["Cybertrain::HttpParser::ParseError", "http/parser"],
        ["Cybertrain::Mailer::Error", "mailer"],
        ["Cybertrain::Mailer::TimeoutError", "mailer"],
        ["Cybertrain::Mailer::ConnectError", "mailer"],
        ["Cybertrain::Mailer::TLSError", "mailer"],
        ["Cybertrain::Mailer::ProtocolError", "mailer"],
        ["Cybertrain::Mailer::InsecureError", "mailer"],
        ["Cybertrain::Mailer::RejectedError", "mailer"],
        ["Cybertrain::Net::Error", "net/socket"],
        ["Cybertrain::Net::TimeoutError", "net/socket"],
        ["Cybertrain::Net::ConnectError", "net/socket"],
        ["Cybertrain::Net::TlsError", "net/socket"],
        ["Cybertrain::Net::BlockedError", "net/socket"],
        ["Cybertrain::Net::LimitError", "net/socket"],
        ["Cybertrain::Net::ProtocolError", "net/socket"],
        ["Cybertrain::Template::SyntaxError", "template/ast"],
        ["Cybertrain::Template::RuntimeError", "template/ast"],
        ["Cybertrain::Template::CallSyntaxError", "template/ast"],
        ["Cybertrain::WebSocket::Error", "websocket/frame"],
        ["Cybertrain::WebSocket::TimeoutError", "websocket/frame"],
        ["Cybertrain::WebSocket::RefusedError", "websocket/frame"],
        ["Cybertrain::WebSocket::TLSError", "websocket/frame"],
        ["Cybertrain::WebSocket::BlockedAddressError", "websocket/frame"],
        ["Cybertrain::WebSocket::HandshakeError", "websocket/frame"],
        ["Cybertrain::WebSocket::ProtocolError", "websocket/frame"],
        ["Cybertrain::WebSocket::TooLargeError", "websocket/frame"],
        ["Cybertrain::WebSocket::ClosedError", "websocket/frame"]
      ]

      # The files of FRAMEWORK_ERRORS that `require "cybertrain"` already
      # loads (cybertrain.rb requires cybertrain/db, which requires
      # db/error; http/parser; cybertrain/template, which requires
      # template/ast): gen/app.rb writes no require for them.
      PRELOADED_FILES = ["db/error", "http/parser", "template/ast"]

      # The file (under cybertrain/, without .rb) defining a framework
      # exception class; "" for any other name.
      def self.framework_file(name)
        FRAMEWORK_ERRORS.each { |pair| return pair[1] if pair[0] == name }
        ""
      end

      # The framework files gen/app.rb must require for the jobs'
      # policies (PRELOADED_FILES left out), each once, sorted.
      def self.framework_files(infos)
        files = Array.new(0) { "" }
        infos.each do |info|
          info.policies.each do |policy|
            file = framework_file(policy.exception_class)
            next if file == "" || files.include?(file) || PRELOADED_FILES.include?(file)

            files << file
          end
        end
        files.sort
      end

      # A JobInfo with nothing in it (class_name ""): a typed placeholder.
      def self.empty_info
        JobInfo.new("", "", "", Array.new(0) { PolicyInfo.new("", "", 0, false, 0, 0) }, 0, "", false, false, Array.new(0) { "" })
      end

      # Every job class under dir (app/jobs), in load order:
      # application_job.rb first, then the other files in path order, each
      # file's classes in line order.
      def self.scan_dir(dir)
        infos = Array.new(0) { empty_info }
        jobs = ControllerScan.ruby_files(dir)
        return infos if jobs.empty?

        app = File.dirname(dir)
        base_file = "#{dir}/application_job.rb"
        models = ControllerScan.ruby_files("#{app}/models")
        defined = Array.new(0) { empty_class }
        ControllerScan.ruby_files(app).each do |path|
          class_definitions(path, File.read(path)).each { |d| defined << d }
        end
        ordered = Array.new(0) { "" }
        ordered << base_file if jobs.include?(base_file)
        jobs.each { |path| ordered << path unless path == base_file }
        spans = Array.new(0) { empty_class }
        ordered.each { |path| defined.each { |d| spans << d if d.defined_file == path } }
        parents = job_parents(spans)
        spans.each_with_index do |d, i|
          check_parent(d, spans, parents[i], ordered)
          next if parents[i] == ""

          lines = File.read(d.defined_file).lines
          infos << scan_body(d, lines, parents[i], defined, models, base_file)
        end
        infos.each do |info|
          next if info.class_name == "ApplicationJob" || inherits_perform?(info, infos)

          message = "#{info.file}: #{info.class_name} defines no perform(args); a job class needs one " \
                    "(Cybertrain::Job::Base#perform raises NotImplementedError)"
          raise Error, message
        end
        infos
      end

      # Whether the job or one of its ancestors defines perform.
      def self.inherits_perform?(info, infos)
        return true if info.has_perform

        ancestors(info, infos).each { |a| return true if a.has_perform }
        false
      end

      # A DefinedClass with nothing in it: a typed placeholder.
      def self.empty_class
        DefinedClass.new("", "", 0, "", 0, false, Array.new(0) { "" })
      end

      # The job classes `info` inherits from, nearest first (ApplicationJob
      # included); Cybertrain::Job::Base is not in the list.
      def self.ancestors(info, infos)
        out = Array.new(0) { empty_info }
        name = info.superclass_name
        while name != BASE && out.size < infos.size
          found = false
          infos.each do |other|
            next unless other.class_name == name

            out << other
            name = other.superclass_name
            found = true
            break
          end
          break unless found
        end
        out
      end

      # Per span, the full name of its superclass when it is a job class
      # (BASE, or another span that is one), else "": repeated until
      # nothing changes, so a grandchild is found whatever the order.
      def self.job_parents(spans)
        parents = Array.new(0) { "" }
        spans.each { parents << "" }
        changed = true
        while changed
          changed = false
          spans.each_with_index do |d, i|
            next unless parents[i] == ""

            parent = job_parent(d, spans, parents)
            next if parent == ""

            parents[i] = parent
            changed = true
          end
        end
        parents
      end

      # The superclass of span `d` as a job class's full name, or "": the
      # name as written, looked up from d's innermost namespace out.
      def self.job_parent(d, spans, parents)
        written = d.defined_super
        return "" if written == ""

        name = written.start_with?("::") ? written[2, written.size - 2].to_s : written
        return BASE if name == BASE

        lexical_candidates(written, d.defined_name).each do |candidate|
          spans.each_with_index do |other, j|
            next unless other.defined_name == candidate

            return parents[j] == "" ? "" : candidate
          end
        end
        ""
      end

      # The full names `written` may mean inside class `class_name`,
      # innermost first (`Stuck` in Admin::ReportJob: Admin::ReportJob::Stuck,
      # Admin::Stuck, Stuck); only itself when it starts with `::`.
      def self.lexical_candidates(written, class_name)
        top = written.start_with?("::")
        name = top ? written[2, written.size - 2].to_s : written
        candidates = Array.new(0) { "" }
        unless top
          scopes = class_name.split("::")
          scopes.pop
          while scopes.size > 0
            candidates << "#{scopes.join("::")}::#{name}"
            scopes.pop
          end
        end
        candidates << name
        candidates
      end

      # Refuses a class written `< ApplicationJob` when no ApplicationJob
      # is defined, and a job whose job superclass loads after it.
      def self.check_parent(d, spans, parent, ordered)
        written = d.defined_super
        if parent == "" && (written == "ApplicationJob" || written == "::ApplicationJob")
          spans.each { |other| return nil if other.defined_name == "ApplicationJob" }
          message = "#{d.defined_file}:#{d.defined_line}: #{d.defined_name} inherits ApplicationJob, " \
                    "which app/jobs/application_job.rb does not define"
          raise Error, message
        end
        return nil if parent == "" || parent == BASE

        spans.each do |p|
          next unless p.defined_name == parent
          return nil if p.defined_file == d.defined_file && p.defined_line < d.defined_line
          return nil if p.defined_file != d.defined_file && ordered.index(p.defined_file).to_i < ordered.index(d.defined_file).to_i

          message = "#{d.defined_file}:#{d.defined_line}: #{written} is defined in #{p.defined_file}, which does not load " \
                    "before this job -- define it in app/jobs/application_job.rb, above it in this file, " \
                    "or in a file that sorts before this one"
          raise Error, message
        end
        nil
      end

      # The body of job class `d` (its file's `lines`): its macros, perform
      # and retries_exhausted, with nested classes, modules and method
      # bodies skipped (a nested job class is a span of its own).
      def self.scan_body(d, lines, parent, defined, models, base_file)
        file = d.defined_file
        class_name = d.defined_name
        class_indent = d.defined_indent
        skip_indent = -1
        def_indent = -1
        policies = Array.new(0) { PolicyInfo.new("", "", 0, false, 0, 0) }
        concurrency_to = 0
        concurrency_key = ""
        concurrency_line = 0
        has_perform = false
        has_hook = false
        lineno = d.defined_line
        while !d.defined_one_line && lineno < lines.size
          raw = lines[lineno]
          lineno += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ModelScan.indent_of(raw)
          if skip_indent >= 0
            skip_indent = -1 if indent == skip_indent && ModelScan.closing_end?(line)
            next
          end
          break if indent <= class_indent && ModelScan.closing_end?(line)

          if def_indent >= 0
            def_indent = -1 if indent == def_indent && ModelScan.closing_end?(line)
            next
          end
          if ModelScan.opens_block?(line)
            skip_indent = indent unless ModelScan.one_line_block?(line)
            next
          end
          macro = macro_name(line)
          if macro == "retry_on" || macro == "discard_on"
            policies << policy_on(file, line, lineno, macro, class_name, defined, models, base_file)
          elsif macro == "limits_concurrency"
            if concurrency_line > 0
              message = "#{file}:#{lineno}: limits_concurrency is declared twice (first on line #{concurrency_line})"
              raise Error, message
            end
            names = Array.new(0) { "" }
            values = Array.new(0) { "" }
            macro_options(file, line, lineno, macro, names, values)
            concurrency_to = 1
            names.each_with_index do |name, i|
              if name == "to"
                concurrency_to = positive_int(file, line, lineno, values[i])
              elsif name == "key" && ModelScan.quoted_literal?(values[i]) && values[i].size > 2
                concurrency_key = ModelScan.literal_text(values[i])
              else
                raise Error, shape(file, line, lineno)
              end
            end
            concurrency_line = lineno
          else
            reserved_class_method!(file, line, lineno)
            name = ModelScan.def_name(line)
            has_perform = true if name == "perform"
            has_hook = true if name == "retries_exhausted"
          end
          def_indent = indent if ModelScan.def_opens_body?(line)
        end
        JobInfo.new(file, class_name, parent, policies, concurrency_to, concurrency_key, has_perform, has_hook, d.defined_scopes)
      end

      # "retry_on", "discard_on" or "limits_concurrency" when the line calls
      # that macro; "" otherwise (`retry_on = 1` and `retry_on.x` are code).
      def self.macro_name(line)
        MACROS.each do |m|
          next unless line.start_with?(m)

          rest = line[m.size, line.size - m.size].to_s
          next unless rest == "" || rest.start_with?(" ") || rest.start_with?("(")

          tail = rest.lstrip
          next if (tail.start_with?("=") && !tail.start_with?("=>")) || tail.start_with?(".")

          return m
        end
        ""
      end

      def self.shape(file, line, lineno)
        "#{file}:#{lineno}: #{line.strip} -- write retry_on/discard_on/limits_concurrency on one line with literal values"
      end

      # Refuses `def self.<name>` for a class method gen/jobs.rb writes.
      def self.reserved_class_method!(file, line, lineno)
        return nil unless line.start_with?("def self.")

        name = ModelScan.word_at(line, 9)
        return nil unless RESERVED_CLASS_METHODS.include?(name)

        message = "#{file}:#{lineno}: #{name} is generated into every job class (gen/jobs.rb); give the method another name"
        raise Error, message
      end

      # A literal Integer of 1 or more, else the shape Error.
      def self.positive_int(file, line, lineno, value)
        raise Error, shape(file, line, lineno) unless digits?(value)

        n = value.to_i
        raise Error, shape(file, line, lineno) if n < 1

        n
      end

      def self.digits?(text)
        return false if text == ""

        text.each_char { |ch| return false unless ch >= "0" && ch <= "9" }
        true
      end

      # One retry_on / discard_on line as a PolicyInfo.
      def self.policy_on(file, line, lineno, macro, class_name, defined, models, base_file)
        names = Array.new(0) { "" }
        values = Array.new(0) { "" }
        klass = macro_options(file, line, lineno, macro, names, values)
        resolved = resolve_class(file, lineno, klass, class_name, defined, models, base_file)
        return PolicyInfo.new("discard", resolved, 0, false, 0, lineno) if macro == "discard_on" && names.empty?
        raise Error, shape(file, line, lineno) if macro == "discard_on"

        wait = 3
        polynomial = false
        attempts = 5
        names.each_with_index do |name, i|
          value = values[i]
          if name == "wait" && value == ":polynomially_longer"
            wait = 0
            polynomial = true
          elsif name == "wait" && digits?(value)
            wait = value.to_i
          elsif name == "attempts"
            attempts = positive_int(file, line, lineno, value)
          else
            raise Error, shape(file, line, lineno)
          end
        end
        PolicyInfo.new("retry", resolved, wait, polynomial, attempts, lineno)
      end

      # Reads `macro Klass, name: value, ...` (or `macro(...)`;
      # limits_concurrency has no Klass): the option names and literal
      # values into `names` / `values` (each name once), returning the
      # class as written ("" for limits_concurrency). A value is digits, a
      # Symbol, a String without escapes or interpolation, true or false;
      # anything else (a block, a lambda, `5.minutes`, `:wait => 5`, a
      # trailing comment, a line continued on the next) is the shape Error.
      def self.macro_options(file, line, lineno, macro, names, values)
        bad = shape(file, line, lineno)
        text = line.strip
        raise Error, bad if ModelScan.continued?(text)

        rest = text[macro.size, text.size - macro.size].to_s.strip
        if rest.start_with?("(")
          raise Error, bad unless rest.end_with?(")")

          rest = rest[1, rest.size - 2].to_s.strip
        end
        klass = ""
        unless macro == "limits_concurrency"
          klass = constant_path_at(rest)
          raise Error, bad unless constant_path?(klass)

          rest = rest[klass.size, rest.size - klass.size].to_s.lstrip
        end
        first = true
        while rest != ""
          if klass != "" || !first
            raise Error, bad unless rest.start_with?(",")

            rest = rest[1, rest.size - 1].to_s.lstrip
          end
          first = false
          name = ModelScan.word_at(rest, 0)
          raise Error, bad if name == "" || rest[name.size, 1] != ":" || rest[name.size + 1, 1] == ":"
          raise Error, bad if names.include?(name)

          rest = rest[name.size + 1, rest.size - name.size - 1].to_s.lstrip
          size = value_size(rest)
          raise Error, bad if size == 0

          names << name
          values << rest[0, size].to_s
          rest = rest[size, rest.size - size].to_s.lstrip
        end
        raise Error, bad if macro == "limits_concurrency" && names.empty?

        klass
      end

      # The length of the literal at the start of text: digits, or
      # ModelScan.literal_size's Symbol / String / true / false.
      def self.value_size(text)
        word = ModelScan.word_at(text, 0)
        return word.size if digits?(word)
        return 0 if word != "" && word != "true" && word != "false"

        ModelScan.literal_size(text)
      end

      # The constant path at the start of text ("Cybertrain::Mailer::TimeoutError").
      def self.constant_path_at(text)
        out = +""
        text.each_char do |ch|
          break unless ModelScan.word_char?(ch) || ch == ":"

          out << ch
        end
        out
      end

      # "A::B" or "::A": segments that are constant names.
      def self.constant_path?(text)
        body = text.start_with?("::") ? text[2, text.size - 2].to_s : text
        return false if body == ""

        body.split("::", -1).each { |seg| return false unless ModelScan.constant_name?(seg) }
        true
      end

      # The full name of the class `written` names on line `lineno` of
      # `file` inside the class `class_name`, looked up as Ruby does from
      # the innermost namespace out ("Stuck" in NestedJob is
      # NestedJob::Stuck when that is defined), accepting only a class that
      # loads before the job's body (see the module comment).
      def self.resolve_class(file, lineno, written, class_name, defined, models, base_file)
        name = written.start_with?("::") ? written[2, written.size - 2].to_s : written
        candidates = lexical_candidates(written, "#{class_name}::_")
        candidates.each do |candidate|
          return candidate if candidate == name && (CORE_ERRORS.include?(name) || framework_file(name) != "")

          elsewhere = ""
          defined.each do |d|
            next unless d.defined_name == candidate
            return candidate if loads_before?(d, file, lineno, models, base_file)

            elsewhere = d.defined_file if elsewhere == ""
          end
          next if elsewhere == ""

          message = "#{file}:#{lineno}: #{written} is defined in #{elsewhere}, which does not load before this job -- " \
                    "define it in app/models, app/jobs/application_job.rb or this file"
          raise Error, message
        end
        message = "#{file}:#{lineno}: #{written} is not a class this program defines (spikes/NOTES.md rule 89)"
        raise Error, message
      end

      # Whether the class line `d` has run when line `lineno` of `file`
      # (a job's macro) is evaluated: gen/app.rb loads app/models, then
      # application_job.rb, then the other jobs.
      def self.loads_before?(d, file, lineno, models, base_file)
        return true if models.include?(d.defined_file)
        return d.defined_line < lineno if d.defined_file == file
        return true if d.defined_file == base_file

        false
      end

      # Every `class X` line of a file with its full name (the enclosing
      # `module` / `class` lines by indentation), its superclass as written
      # and the keyword of each enclosing segment, skipping those inside a
      # `class << self`.
      def self.class_definitions(file, source)
        out = Array.new(0) { empty_class }
        names = Array.new(0) { "" }
        keywords = Array.new(0) { "" }
        indents = Array.new(0) { 0 }
        lineno = 0
        source.each_line do |raw|
          lineno += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ModelScan.indent_of(raw)
          if !indents.empty? && indent <= indents.last && ModelScan.closing_end?(line)
            names.pop
            keywords.pop
            indents.pop
            next
          end
          one_line = ModelScan.one_line_block?(line)
          if line.start_with?("class <<") || line.start_with?("class<<")
            unless one_line
              names << "<<"
              keywords << "class"
              indents << indent
            end
            next
          end
          mm = raw.match(MODULE_LINE)
          cm = mm.nil? ? raw.match(CLASS_LINE) : nil
          next if mm.nil? && cm.nil?

          own = mm.nil? ? cm[1].to_s : mm[1].to_s
          if mm.nil? && !names.include?("<<")
            scopes = Array.new(0) { "" }
            (names + [own]).each_with_index do |n, k|
              segs = n.split("::")
              segs.each_with_index do |_seg, m|
                last_of_entry = m == segs.size - 1
                next if k == names.size && last_of_entry

                scopes << (last_of_entry ? keywords[k].to_s : "module")
              end
            end
            out << DefinedClass.new((names + [own]).join("::"), file, lineno, cm[2].to_s, indent, one_line, scopes)
          end
          next if one_line

          names << own
          keywords << (mm.nil? ? "class" : "module")
          indents << indent
        end
        out
      end
    end
  end
end
