# The text edits the generators share: indenting a chunk written flush,
# and putting a chunk after, before or in place of a line of a source file.
# Strings in, a new String out; nothing here reads or writes a file.
#
# Loaded by scaffold.rb, whose InvalidArgument the functions raise (the
# name is looked up when one raises, so this file requires nothing).
module Cybertrain
  module CLI
    module SourceEdit
      # `text` with two spaces in front of every non-blank line: the
      # generators' heredocs are written flush (`<<~` strips their
      # indentation), and what goes inside a class body or a draw block is
      # indented here.
      def self.indent(text)
        margin(text, 2)
      end

      # `text` with `spaces` spaces before every non-blank line: a chunk
      # written flush, moved to where splice puts it (inside a method's
      # `if`, say).
      def self.margin(text, spaces)
        pad = " " * spaces
        out = +""
        text.each_line { |line| out << (line == "\n" ? line : "#{pad}#{line}") }
        out
      end

      # `source` with `block` (its own lines, each ending in a newline)
      # inserted right after the first line containing `marker`.
      def self.insert_after_line(source, marker, block)
        at = source.index(marker)
        raise InvalidArgument, "no `#{marker}` line to insert after" if at.nil?

        eol = source.index("\n", at)
        eol = source.size if eol.nil?
        updated = +""
        updated << source[0, eol] << "\n"
        updated << block
        rest = source[eol + 1, source.size - eol - 1].to_s
        updated << rest
        updated << "\n" unless updated.end_with?("\n")
        updated
      end

      # `source` with `block` inserted right before the first line that
      # starts with `marker`.
      def self.insert_before_line(source, marker, block)
        start = line_start(source, marker)
        raise InvalidArgument, "no line starting with `#{marker}` to insert before" if start < 0

        updated = +""
        updated << source[0, start].to_s
        updated << block
        updated << source[start, source.size - start].to_s
        updated
      end

      # Where the first line that starts with `marker` starts, or -1.
      def self.line_start(source, marker)
        return 0 if source.start_with?(marker)

        found = source.index("\n#{marker}")
        found.nil? ? -1 : found + 1
      end

      # Where the line holding offset `at` of source starts.
      def self.line_start_before(source, at)
        found = at > 0 ? source.rindex("\n", at - 1) : nil
        found.nil? ? 0 : found + 1
      end

      # `text` with the whole line that holds `mark` (a placeholder line in
      # one of a generator's templates, wherever it is indented) replaced by
      # `chunk`: lines of their own, each ending in a newline and indented
      # as the file needs, or "" to drop the line. What --confirmable adds
      # to a file the other modes write too goes in this way.
      def self.splice(text, mark, chunk)
        at = text.index(mark)
        raise InvalidArgument, "no `#{mark}` in the template" if at.nil?

        start = line_start_before(text, at)
        stop = text.index("\n", at)
        stop = stop.nil? ? text.size : stop + 1
        out = +""
        out << text[0, start].to_s << chunk << text[stop, text.size - stop].to_s
        out
      end
    end
  end
end
