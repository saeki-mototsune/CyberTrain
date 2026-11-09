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

    # What the scan found in one app/jobs file: the job class, its
    # superclass as written ("Cybertrain::Job::Base" or "ApplicationJob"),
    # its policies in declaration order (retry and discard interleaved),
    # its `limits_concurrency` (`to:`, 0 without the line; `key:`, ""
    # without one), and whether it defines `perform` and
    # `retries_exhausted`.
    class JobInfo
      attr_reader :file, :class_name, :superclass_name, :policies, :concurrency_to, :concurrency_key,
                  :has_perform, :has_exhausted_hook

      def initialize(file, class_name, superclass_name, policies, concurrency_to, concurrency_key, has_perform, has_exhausted_hook)
        @file = file
        @class_name = class_name
        @superclass_name = superclass_name
        @policies = policies
        @concurrency_to = concurrency_to
        @concurrency_key = concurrency_key
        @has_perform = has_perform
        @has_exhausted_hook = has_exhausted_hook
      end

      # Whether it inherits from ApplicationJob (and so its policies too).
      def application_job_child?
        @superclass_name == "ApplicationJob" || @superclass_name == "::ApplicationJob"
      end
    end

    # A `class X` line somewhere under app/: its full name, file and line.
    class DefinedClass
      attr_reader :defined_name, :defined_file, :defined_line

      def initialize(defined_name, defined_file, defined_line)
        @defined_name = defined_name
        @defined_file = defined_file
        @defined_line = defined_line
      end
    end

    # Reads app/jobs/**/*.rb as text (spec section 2.2), as ComponentScan
    # reads app/components: the `class X < Cybertrain::Job::Base` (or
    # `< ApplicationJob`) line, one `retry_on` / `discard_on` /
    # `limits_concurrency` macro per line with literal values, and the
    # `def perform` / `def retries_exhausted` lines. A class that inherits
    # from neither base is skipped (a helper may live there). ApplicationJob
    # itself is scanned (its macros apply to its subclasses) but is not a
    # job: JobsEmitter writes nothing for it.
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

      BASES = ["Cybertrain::Job::Base", "::Cybertrain::Job::Base", "ApplicationJob", "::ApplicationJob"]
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

      # The framework's exception classes, each with the file under
      # cybertrain/ that defines it: `require "cybertrain"` loads none of
      # these files, so gen/app.rb requires the ones the jobs name
      # (Manifest).
      FRAMEWORK_ERRORS = [
        ["Cybertrain::Mailer::Error", "mailer"],
        ["Cybertrain::Mailer::TimeoutError", "mailer"],
        ["Cybertrain::Mailer::ConnectError", "mailer"],
        ["Cybertrain::Mailer::TLSError", "mailer"],
        ["Cybertrain::Mailer::ProtocolError", "mailer"],
        ["Cybertrain::Mailer::InsecureError", "mailer"],
        ["Cybertrain::Mailer::RejectedError", "mailer"],
        ["Cybertrain::HttpClient::Error", "http_client"],
        ["Cybertrain::HttpClient::TimeoutError", "http_client"],
        ["Cybertrain::HttpClient::RefusedError", "http_client"],
        ["Cybertrain::HttpClient::TLSError", "http_client"],
        ["Cybertrain::HttpClient::BlockedAddressError", "http_client"],
        ["Cybertrain::HttpClient::TooLargeError", "http_client"],
        ["Cybertrain::HttpClient::BadResponseError", "http_client"],
        ["Cybertrain::Net::Error", "net/socket"],
        ["Cybertrain::Net::TimeoutError", "net/socket"],
        ["Cybertrain::Net::ConnectError", "net/socket"],
        ["Cybertrain::Net::TlsError", "net/socket"],
        ["Cybertrain::Net::BlockedError", "net/socket"],
        ["Cybertrain::Net::LimitError", "net/socket"],
        ["Cybertrain::Net::ProtocolError", "net/socket"]
      ]

      # The file (under cybertrain/, without .rb) defining a framework
      # exception class; "" for any other name.
      def self.framework_file(name)
        FRAMEWORK_ERRORS.each { |pair| return pair[1] if pair[0] == name }
        ""
      end

      # The framework files the jobs' policies need, each once, sorted.
      def self.framework_files(infos)
        files = Array.new(0) { "" }
        infos.each do |info|
          info.policies.each do |policy|
            file = framework_file(policy.exception_class)
            files << file unless file == "" || files.include?(file)
          end
        end
        files.sort
      end

      # A JobInfo with nothing in it (class_name ""): a typed placeholder.
      def self.empty_info
        JobInfo.new("", "", "", Array.new(0) { PolicyInfo.new("", "", 0, false, 0, 0) }, 0, "", false, false)
      end

      # Every job class under dir (app/jobs), application_job.rb first,
      # then the other files in path order.
      def self.scan_dir(dir)
        infos = Array.new(0) { empty_info }
        jobs = ControllerScan.ruby_files(dir)
        return infos if jobs.empty?

        app = File.dirname(dir)
        base_file = "#{dir}/application_job.rb"
        models = ControllerScan.ruby_files("#{app}/models")
        defined = Array.new(0) { DefinedClass.new("", "", 0) }
        ControllerScan.ruby_files(app).each do |path|
          class_definitions(path, File.read(path)).each { |d| defined << d }
        end
        ordered = Array.new(0) { "" }
        ordered << base_file if jobs.include?(base_file)
        jobs.each { |path| ordered << path unless path == base_file }
        base_perform = false
        ordered.each do |path|
          info = scan_source(path, File.read(path), defined, models, base_file)
          next if info.nil?

          if info.class_name == "ApplicationJob"
            base_perform = info.has_perform
          elsif !info.has_perform && !(base_perform && info.application_job_child?)
            message = "#{path}: #{info.class_name} defines no perform(args); a job class needs one " \
                      "(Cybertrain::Job::Base#perform raises NotImplementedError)"
            raise Error, message
          end
          infos << info
        end
        infos
      end

      # The job class of one file, or nil when the file has none. `defined`
      # are the class lines under app/, `models` the app/models files,
      # `base_file` the path of app/jobs/application_job.rb.
      def self.scan_source(file, source, defined, models, base_file)
        modules = Array.new(0) { "" }
        module_indents = Array.new(0) { 0 }
        class_name = ""
        superclass = ""
        class_indent = -1
        skip_indent = -1
        def_indent = -1
        policies = Array.new(0) { PolicyInfo.new("", "", 0, false, 0, 0) }
        concurrency_to = 0
        concurrency_key = ""
        concurrency_line = 0
        has_perform = false
        has_hook = false
        lineno = 0
        source.each_line do |raw|
          lineno += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ModelScan.indent_of(raw)
          if skip_indent >= 0
            skip_indent = -1 if indent == skip_indent && ModelScan.closing_end?(line)
            next
          end
          if class_name == ""
            if !module_indents.empty? && indent <= module_indents.last && ModelScan.closing_end?(line)
              modules.pop
              module_indents.pop
              next
            end
            mm = raw.match(MODULE_LINE)
            if mm && !ModelScan.one_line_block?(line)
              modules << mm[1].to_s
              module_indents << indent
              next
            end
            cm = raw.match(CLASS_LINE)
            next if cm.nil?

            if BASES.include?(cm[2].to_s)
              class_name = (modules + [cm[1].to_s]).join("::")
              superclass = cm[2].to_s
              class_indent = indent
            elsif !ModelScan.one_line_block?(line)
              # Another class (an error class above the job): skip its body.
              skip_indent = indent
            end
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
        return nil if class_name == ""

        JobInfo.new(file, class_name, superclass, policies, concurrency_to, concurrency_key, has_perform, has_hook)
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
        top = written.start_with?("::")
        name = top ? written[2, written.size - 2].to_s : written
        candidates = Array.new(0) { "" }
        unless top
          scopes = class_name.split("::")
          while scopes.size > 0
            candidates << "#{scopes.join("::")}::#{name}"
            scopes.pop
          end
        end
        candidates << name
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
      # `module` / `class` lines by indentation), skipping those inside a
      # `class << self`.
      def self.class_definitions(file, source)
        out = Array.new(0) { DefinedClass.new("", "", 0) }
        names = Array.new(0) { "" }
        indents = Array.new(0) { 0 }
        lineno = 0
        source.each_line do |raw|
          lineno += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ModelScan.indent_of(raw)
          if !indents.empty? && indent <= indents.last && ModelScan.closing_end?(line)
            names.pop
            indents.pop
            next
          end
          one_line = ModelScan.one_line_block?(line)
          if line.start_with?("class <<") || line.start_with?("class<<")
            unless one_line
              names << "<<"
              indents << indent
            end
            next
          end
          mm = raw.match(MODULE_LINE)
          cm = mm.nil? ? raw.match(CLASS_LINE) : nil
          next if mm.nil? && cm.nil?

          own = mm.nil? ? cm[1].to_s : mm[1].to_s
          full = (names + [own]).join("::")
          out << DefinedClass.new(full, file, lineno) if mm.nil? && !names.include?("<<")
          next if one_line

          names << own
          indents << indent
        end
        out
      end
    end
  end
end
