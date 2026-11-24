# The two tools of an application, build/bin/gen and build/bin/db, reused
# for as long as what they are compiled from is unchanged (docs/design.md
# D12, the 2026-11-24 note). spin rebuilds an executable when any *.rb of
# the package is newer than it, and both tools write Ruby files: the
# migrator db/schema.rb, the generator gen/**. So a `cybertrain db
# migrate` left both binaries stale by spin's rule, and the `db status`
# after it compiled the two again, minutes for programs identical to the
# ones on disk.
#
# ToolBinary lists the files a tool is compiled from (bin/<tool>.rb and
# what its requires reach, {sources}), records the list beside the binary
# when spin has built it ({build}), and answers whether the binary is
# still that build ({fresh?}): then the CLI runs build/bin/<tool> itself
# and spin is not asked. The list is read from the sources, not asked of
# the compiler (the compiler has no such output, and its analysis is most
# of the compile), so it errs one way only: a require it cannot follow as
# written means "not known", and spin decides as before. Plain Ruby: runs
# under CRuby (the gem) and compiles under Spinel (bin/cybertrain.rb).
require "cybertrain/shell"
require "cybertrain/cli/templates"

module Cybertrain
  module CLI
    module ToolBinary
      # Beside the binary: what it was built from ({inputs_record}).
      RECORD = ".inputs".freeze

      # The files a program is compiled from, or why they are not known.
      class Sources
        # @return [Array<String>] absolute paths, the entry first
        attr_reader :files
        # @return [String] "" when the list is complete, else
        #   "<path>:<line>: <reason>"
        attr_reader :problem

        def initialize
          @files = Array.new(0) { "" }
          @problem = ""
        end

        def add(path)
          @files << path unless @files.include?(path)
          nil
        end

        # Keeps the first reason.
        def refuse(reason)
          @problem = reason if @problem.empty?
          nil
        end

        def known?
          @problem.empty?
        end
      end

      def self.binary(root, tool)
        "#{root}/build/bin/#{tool}"
      end

      # How spin builds the tool: debug mode, as every command builds gen
      # and db (Shell::TOOL_SPIN).
      def self.build_command(tool)
        "#{Shell::TOOL_SPIN} build #{tool}"
      end

      # The binary itself, in the application's directory; words is the
      # arguments, already quoted for sh ("" for none).
      def self.direct_command(tool, words)
        words.empty? ? "./build/bin/#{tool}" : "./build/bin/#{tool} #{words}"
      end

      # `spin flags` in root.
      def self.spin_flags_in(root)
        `cd #{Shell.quote(root)} && spin flags`
      end

      # The `-I` directories of `spin flags` output, in order, absolute
      # (a relative one is relative to root).
      def self.load_path(root, flags)
        base = File.expand_path(root)
        out = Array.new(0) { "" }
        words = flags.split
        i = 0
        while i < words.size
          if words[i] == "-I" && i + 1 < words.size
            dir = File.expand_path(words[i + 1], base)
            out << dir unless out.include?(dir)
            i += 2
          else
            i += 1
          end
        end
        out
      end

      # What bin/<tool>.rb of root is compiled from.
      # @param root [String]
      # @param tool [String] "gen" or "db"
      # @param flags [String] the `spin flags` output
      # @return [Sources]
      def self.sources_of(root, tool, flags)
        sources("#{File.expand_path(root)}/bin/#{tool}.rb", load_path(root, flags))
      end

      # entry and every file its requires reach: `require_relative "x"`
      # beside the requiring file, `require "x"` in each of dirs that has
      # it (every one: more files than the compiler takes is the safe
      # side). A name no directory has is the toolchain's (json, date:
      # `spin flags --deps` covers the toolchain) or a file not written
      # yet, which changes the list when it appears. A line {requirement}
      # cannot read, or a file that is missing or unreadable, makes the
      # list not known.
      # @param entry [String]
      # @param dirs [Array<String>]
      # @return [Sources]
      def self.sources(entry, dirs)
        out = Sources.new
        out.add(File.expand_path(entry))
        i = 0
        while i < out.files.size && out.known?
          scan_file(out.files[i], dirs, out)
          i += 1
        end
        out
      end

      def self.scan_file(path, dirs, out)
        unless File.file?(path)
          out.refuse("#{path}: no such file")
          return nil
        end
        lines = File.binread(path).split("\n")
        number = 0
        while number < lines.size
          line = lines[number]
          number += 1
          # What follows is data, not program.
          return nil if line == "__END__"

          found = requirement(line)
          next if found.empty?

          name = found[1, found.size - 1].to_s
          if found.start_with?("?") || name.start_with?("/") || name.start_with?(".") && found.start_with?("R")
            out.refuse("#{path}:#{number}: a require this check cannot follow")
            return nil
          end
          name = "#{name}.rb" unless name.end_with?(".rb")
          if found.start_with?("L")
            target = File.expand_path(name, File.dirname(path))
            out.add(target) if File.file?(target)
          else
            dirs.each do |dir|
              target = "#{dir}/#{name}"
              out.add(target) if File.file?(target)
            end
          end
        end
        nil
      end

      # What one line of a Ruby file says about requires: "" (nothing),
      # "R<name>" (`require "<name>"`), "L<name>" (`require_relative
      # "<name>"`) or "?" (it may load a file this cannot name).
      #
      # Only a line that starts with the word and gives one string literal
      # with no escape or interpolation is followed, with or without
      # parentheses, an `if`/`unless` modifier (taken as true) or a
      # comment. The word anywhere else is "?" unless it is certainly no
      # call of Kernel's: inside a quoted string or a comment, a method's
      # name (`def require`, `params.require`), a symbol or a keyword
      # (`:require`, `require:`), or alone with nothing after it. Text is
      # read a line at a time, so the body of a heredoc or of a `%w[]`
      # list counts as program: that gives "?" or one file too many,
      # never one too few.
      #
      # Not seen: `load` (the compiler refuses it), and a require after a
      # literal this does not read on the same line: a regexp or a `%`
      # literal that holds a quote or " #" before `; require "x"`.
      # @param line [String]
      # @return [String]
      def self.requirement(line)
        text = line.end_with?("\r") ? line[0, line.size - 1].to_s : line
        size = text.bytesize
        start = 0
        start += 1 while start < size && blank?(text.getbyte(start).to_i)
        return "" if start == size || text.getbyte(start).to_i == 35

        i = start
        quote = 0
        quoted_word = false
        while i < size
          b = text.getbyte(i).to_i
          if quote != 0
            if b == 92
              i += 2
            else
              if b == quote
                quote = 0
              elsif !word_at(text, i).empty?
                quoted_word = true
              end
              i += 1
            end
            next
          end
          if b == 34 || b == 39 || b == 96
            quote = b
            i += 1
            next
          end
          # A comment to the end of the line.
          break if b == 35 && blank?(text.getbyte(i - 1).to_i)

          word = word_at(text, i)
          if word.empty?
            i += 1
            next
          end
          unless not_a_call?(text, start, i, word)
            return i == start ? literal(text, i, word) : "?"
          end

          i += word.bytesize
        end
        # A quote still open: the line was not read as Ruby reads it.
        return "?" if quote != 0 && quoted_word

        ""
      end

      def self.blank?(byte)
        byte == 32 || byte == 9
      end

      # A byte of an identifier (a letter, a digit, "_" or a byte of a
      # multibyte character).
      def self.name_byte?(byte)
        (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95 || byte >= 128
      end

      # "require_relative" or "require" when that word starts at i (not
      # the middle or the start of a longer name, not @require, $require,
      # require? or require!), else "".
      def self.word_at(text, i)
        return "" unless text.getbyte(i).to_i == 114

        if i > 0
          before = text.getbyte(i - 1).to_i
          return "" if name_byte?(before) || before == 64 || before == 36
        end
        word = ""
        word = "require" if text[i, 7] == "require"
        word = "require_relative" if text[i, 16] == "require_relative"
        return "" if word.empty?

        after = text.getbyte(i + word.bytesize).to_i
        return "" if name_byte?(after) || after == 63 || after == 33

        word
      end

      # Whether word at i is certainly not a call of Kernel's require: see
      # {requirement}.
      def self.not_a_call?(text, start, i, word)
        size = text.bytesize
        after = i + word.bytesize
        # `require: x`, a keyword or a Hash key (`require::X` is a call).
        return true if text.getbyte(after).to_i == 58 && text.getbyte(after + 1).to_i != 58

        rest = after
        rest += 1 while rest < size && blank?(text.getbyte(rest).to_i)
        # The bare word: a require needs an argument.
        return true if rest == size
        return false if i == start

        before = text.getbyte(i - 1).to_i
        # `:require`, a symbol (`Kernel::require` is a call).
        return text.getbyte(i - 2).to_i != 58 || i - 2 < start if before == 58
        # `x.require`, another object's method (`Kernel.require` is a call).
        return !text[0, i - 1].to_s.end_with?("Kernel") if before == 46

        # `def require`.
        head = i
        head -= 1 while head > start && blank?(text.getbyte(head - 1).to_i)
        head < i && text[0, head].to_s.end_with?("def") && (head - 3 == start || !name_byte?(text.getbyte(head - 4).to_i))
      end

      # The line from its first word (word, at i) as one string literal
      # required: "R<name>" or "L<name>", else "?".
      def self.literal(text, i, word)
        size = text.bytesize
        j = i + word.bytesize
        j += 1 while j < size && blank?(text.getbyte(j).to_i)
        paren = text.getbyte(j).to_i == 40
        if paren
          j += 1
          j += 1 while j < size && blank?(text.getbyte(j).to_i)
        end
        quote = text.getbyte(j).to_i
        return "?" unless quote == 34 || quote == 39

        close = j + 1
        while close < size && text.getbyte(close).to_i != quote
          byte = text.getbyte(close).to_i
          # An escape or an interpolation: not a name as written.
          return "?" if byte == 92 || byte == 35

          close += 1
        end
        return "?" if close >= size || close == j + 1

        name = text[j + 1, close - j - 1].to_s
        j = close + 1
        j += 1 while j < size && blank?(text.getbyte(j).to_i)
        if paren
          return "?" unless text.getbyte(j).to_i == 41

          j += 1
          j += 1 while j < size && blank?(text.getbyte(j).to_i)
        end
        rest = text[j, size - j].to_s
        unless rest.empty? || rest.start_with?("#")
          return "?" unless rest.start_with?("if ") || rest.start_with?("unless ")
          # A second statement on the line that requires.
          return "?" if rest.include?("require")
        end
        (word == "require" ? "R" : "L") + name
      end

      # What a tool's binary is built from besides its sources' contents:
      # the build command, the `spin flags` output (which framework
      # checkout and which load path), spin.toml and spin.lock as they
      # are, and the paths of the sources. A different record (a repointed
      # dependency, a require added or removed, a required file that
      # appeared or went) means a build, whatever the files' times say.
      # @param root [String]
      # @param tool [String]
      # @param flags [String] the `spin flags` output
      # @param files [Array<String>] Sources#files
      # @return [String]
      def self.inputs_record(root, tool, flags, files)
        out = +"build: #{build_command(tool)}\nflags: #{flags.strip}\n"
        out << "spin.toml:\n" << file_text("#{root}/spin.toml")
        out << "spin.lock:\n" << file_text("#{root}/spin.lock")
        out << "sources:\n"
        files.sort.each { |path| out << path << "\n" }
        out
      end

      # path's contents, or "(none)\n".
      def self.file_text(path)
        File.file?(path) ? File.read(path) : "(none)\n"
      end

      # Whether build/bin/<tool> is the binary {build} recorded and can
      # run as it is: it and its record exist, the sources are known, the
      # record is what {inputs_record} gives now, and no source and no
      # toolchain file (`spin flags --deps`) is newer than the record,
      # whose time is the start of that build. Any failure to find out is
      # false, which costs at most the build spin would have run.
      # @param root [String]
      # @param tool [String]
      # @return [Boolean]
      def self.fresh?(root, tool)
        record = "#{binary(root, tool)}#{RECORD}"
        return false unless File.file?(binary(root, tool)) && File.file?(record)

        flags = spin_flags_in(root)
        found = sources_of(root, tool, flags)
        return false unless found.known?
        return false unless File.read(record) == inputs_record(root, tool, flags, found.files)

        built = mtime_ns(record)
        found.files.each do |path|
          return false if mtime_ns(path) > built
        end
        `cd #{Shell.quote(root)} && spin flags --deps`.split.each do |path|
          return false if mtime_ns(path) > built
        end
        true
      rescue StandardError
        false
      end

      # Has spin build the tool (runner.run_step) and records what it was
      # built from; true when the binary can run. The record is written
      # before the build starts and kept only when it succeeds, so its
      # time is the start: a source edited during the build is newer than
      # it. A binary whose record no longer holds goes first: spin reuses
      # a binary newer than its sources, and the one a source was edited
      # under is that. With no record there is nothing to say the binary
      # is wrong, and spin decides. When the sources are not known no
      # record is kept, and every run asks spin, as before this check.
      # @param root [String]
      # @param tool [String]
      # @param runner [#run_step]
      # @return [Boolean]
      def self.build(root, tool, runner)
        record = "#{binary(root, tool)}#{RECORD}"
        pending = "#{record}.tmp"
        text = record_text(root, tool)
        if File.exist?(record)
          File.delete(record)
          File.delete(binary(root, tool)) if File.exist?(binary(root, tool))
        end
        unless text.empty?
          Templates.mkdir_p("#{root}/build/bin")
          File.write(pending, text)
        end
        unless runner.run_step(root, build_command(tool))
          File.delete(pending) if File.exist?(pending)
          return false
        end
        File.rename(pending, record) if File.exist?(pending)
        true
      end

      # {inputs_record} for the tool as it is now, or "" when its sources
      # are not known or cannot be read.
      def self.record_text(root, tool)
        flags = spin_flags_in(root)
        found = sources_of(root, tool, flags)
        return "" unless found.known?

        inputs_record(root, tool, flags, found.files)
      rescue StandardError
        ""
      end

      # path's mtime in nanoseconds, -1 when it is no file.
      def self.mtime_ns(path)
        return -1 unless File.file?(path)

        t = File.mtime(path)
        t.to_i * 1_000_000_000 + t.nsec
      end
    end
  end
end
