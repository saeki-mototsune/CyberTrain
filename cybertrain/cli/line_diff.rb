# A unified diff of two texts, line by line, as `diff -u` writes it and
# `patch -p1` applies it: `--- a/<path>` and `+++ b/<path>`, then hunks
# with three lines of context (`@@ -l,s +l,s @@`, the `,s` left out when
# it is 1). `generate authentication` prints one for each file it would
# write whole that exists with other content (CLI::Authentication,
# write_or_diff), so the application's owner applies the change by hand.
#
# The lines in common are a longest common subsequence (the common head
# and tail taken off first, then a table over what is left), so a change
# in the middle of a long file costs only the lines around it.
module Cybertrain
  module CLI
    module LineDiff
      CONTEXT = 3
      # Kinds of step through the two texts.
      SAME = 0
      REMOVED = 1
      ADDED = 2

      # The diff that turns old_text into new_text, or "" when they are
      # equal. A last line without a newline is followed by
      # `\ No newline at end of file`, as diff writes it.
      # @param path [String] the file's path from the application's root
      # @param old_text [String]
      # @param new_text [String]
      # @return [String]
      def self.unified(path, old_text, new_text)
        before = as_utf8(old_text.to_s)
        after = as_utf8(new_text.to_s)
        return "" if before == after

        a = lines_of(before)
        b = lines_of(after)
        kinds = Array.new(0) { 0 }
        froms = Array.new(0) { 0 }
        tos = Array.new(0) { 0 }
        diff_steps(a, b, kinds, froms, tos)

        out = +""
        out << "--- a/#{path}\n"
        out << "+++ b/#{path}\n"
        n = kinds.size
        k = 0
        while k < n
          if kinds[k] == SAME
            k += 1
            next
          end
          # A hunk: up to CONTEXT steps before this change, then changes
          # whose gap of same lines is at most twice CONTEXT, then up to
          # CONTEXT steps after the last of them.
          first = k - CONTEXT
          first = 0 if first < 0
          last = k
          j = k + 1
          while j < n
            if kinds[j] != SAME
              last = j
            elsif j - last > 2 * CONTEXT
              break
            end
            j += 1
          end
          stop = last + CONTEXT + 1
          stop = n if stop > n
          out << hunk(a, b, kinds, froms, tos, first, stop)
          k = stop
        end
        out
      end

      # text read as UTF-8 (File.read under a C locale answers US-ASCII,
      # which cannot be joined to the generator's UTF-8 text).
      # @param text [String]
      # @return [String]
      def self.as_utf8(text)
        s = text.to_s
        s.encoding.to_s == "UTF-8" ? s : s.dup.force_encoding("UTF-8")
      end

      # text cut into lines, each with its newline (the last one may have
      # none).
      def self.lines_of(text)
        s = text.to_s
        out = Array.new(0) { "" }
        start = 0
        while start < s.size
          eol = s.index("\n", start)
          if eol.nil?
            out << s[start, s.size - start].to_s
            start = s.size
          else
            out << s[start, eol + 1 - start].to_s
            start = eol + 1
          end
        end
        out
      end

      # Fills kinds, froms and tos with the steps from a to b: each step's
      # kind and the index of its line in a (SAME, REMOVED) or b (ADDED);
      # froms holds a's index, tos b's, for every step (the next line's
      # where the step has none on that side).
      def self.diff_steps(a, b, kinds, froms, tos)
        head = 0
        head += 1 while head < a.size && head < b.size && a[head] == b[head]
        tail = 0
        tail += 1 while tail < a.size - head && tail < b.size - head && a[a.size - 1 - tail] == b[b.size - 1 - tail]
        n = a.size - head - tail
        m = b.size - head - tail
        # table[i * (m + 1) + j]: the longest common subsequence of a's
        # middle from i and b's middle from j.
        width = m + 1
        table = Array.new((n + 1) * width) { 0 }
        i = n - 1
        while i >= 0
          j = m - 1
          while j >= 0
            table[i * width + j] = if a[head + i] == b[head + j]
                                     table[(i + 1) * width + j + 1] + 1
                                   else
                                     down = table[(i + 1) * width + j]
                                     right = table[i * width + j + 1]
                                     down >= right ? down : right
                                   end
            j -= 1
          end
          i -= 1
        end

        x = 0
        while x < head
          push_step(kinds, froms, tos, SAME, x, x)
          x += 1
        end
        i = 0
        j = 0
        while i < n || j < m
          if i < n && j < m && a[head + i] == b[head + j]
            push_step(kinds, froms, tos, SAME, head + i, head + j)
            i += 1
            j += 1
          elsif i < n && (j >= m || table[(i + 1) * width + j] >= table[i * width + j + 1])
            push_step(kinds, froms, tos, REMOVED, head + i, head + j)
            i += 1
          else
            push_step(kinds, froms, tos, ADDED, head + i, head + j)
            j += 1
          end
        end
        x = 0
        while x < tail
          push_step(kinds, froms, tos, SAME, head + n + x, head + m + x)
          x += 1
        end
        nil
      end

      def self.push_step(kinds, froms, tos, kind, from, to)
        kinds << kind
        froms << from
        tos << to
        nil
      end

      # The `@@` line and the lines of steps first...stop.
      def self.hunk(a, b, kinds, froms, tos, first, stop)
        old_count = 0
        new_count = 0
        body = +""
        k = first
        while k < stop
          kind = kinds[k]
          if kind == SAME
            old_count += 1
            new_count += 1
            body << hunk_line(" ", a[froms[k]])
          elsif kind == REMOVED
            old_count += 1
            body << hunk_line("-", a[froms[k]])
          else
            new_count += 1
            body << hunk_line("+", b[tos[k]])
          end
          k += 1
        end
        out = +""
        out << "@@ -" << hunk_range(froms[first], old_count) << " +" << hunk_range(tos[first], new_count) << " @@\n"
        out << body
        out
      end

      # `l,s` (1-based), `l` alone when s is 1, and the line before when s
      # is 0, as diff writes it.
      def self.hunk_range(index, count)
        return "#{index},0" if count == 0
        return (index + 1).to_s if count == 1

        "#{index + 1},#{count}"
      end

      def self.hunk_line(mark, line)
        text = line.to_s
        return "#{mark}#{text}" if text.end_with?("\n")

        "#{mark}#{text}\n\\ No newline at end of file\n"
      end
    end
  end
end
