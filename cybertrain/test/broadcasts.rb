# Broadcast assertions and assert_turbo_stream (spec section 9.3).
#
# A broadcast is a row of `cybertrain_messages` (Cybertrain::Stream), so
# the assertions read the table: no poller, hub or socket is needed, and
# nothing is recorded. Production code is not touched and there is no
# switch to turn on: what a test counts is the rows with an id above a
# floor, read with SELECTs on the database the test runs against.
#
# - `assert_broadcasts(stream, count) { }` reads the table's largest id
#   before the block, then counts the stream's rows above it.
# - Without a block it counts from the floor the reset hook read when the
#   test began (`Test.case_message_floor`, step 3 of the order), so a
#   broadcast of an earlier test is never counted.
# - `assert_turbo_stream(action:, target:)` reads the last response or
#   render (`Test.last_html`) with the test HTML reader. The content of a
#   `<template>` is not read (Turbo inserts it as a fragment, and the
#   assertion is about the `<turbo-stream>` elements): it is blanked byte
#   for byte first, so the reader's offsets stay those of the HTML as
#   written.
#
# The checks follow the assertions' pattern (cybertrain/test/assertions.rb,
# pre-flight R17): one `Test.check_*` each, shared by every caller.
require "cybertrain/test"
require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/stream"
require "cybertrain/turbo"
require "cybertrain/test/html_reader"
require "cybertrain/test/select"

module Cybertrain
  module Test
    # The reads behind the broadcast assertions and the reset hooks. Not API.
    module Broadcasts
      # The largest message id when the current test began; 0 when there
      # was no database or no messages table.
      @floor = 0

      # @api private
      def self.case_floor = @floor

      # @api private
      def self.case_floor=(value)
        @floor = value
      end

      # Whether the connected database has the messages table. Read with a
      # SELECT on sqlite_master: the table is never created here (as
      # Stream.ensure_installed would), so a test that broadcasts nothing
      # leaves its database as it was.
      # @api private
      def self.messages_table?
        return false unless DB.connected?

        rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'cybertrain_messages'") }
        Cast.int(rows[0]["n"]) > 0
      end

      # The largest message id now; 0 without a database or the table.
      # @api private
      def self.head_id
        return 0 unless messages_table?

        rows = DB.with { |c| c.execute("SELECT MAX(id) AS m FROM cybertrain_messages") }
        return 0 if rows.empty?

        Cast.int(rows[0]["m"])
      end

      # The payloads of `name`'s messages with an id above `floor`, oldest
      # first.
      # @api private
      def self.payloads_after(name, floor)
        out = Array.new(0) { "" }
        return out unless messages_table?

        rows = DB.with { |c| c.execute("SELECT payload FROM cybertrain_messages WHERE stream = ? AND id > ? ORDER BY id", Cast.binds(name, floor)) }
        rows.each { |r| out << Cast.str(r["payload"]) }
        out
      end

      # The reset hook (step 3): the floor of the test about to run. A
      # lambda made in a method (rule 82).
      # @api private
      def self.floor_reset
        -> {
          Broadcasts.case_floor = Broadcasts.head_id
          nil
        }
      end

      # The reset hook that forgets the previous test's response or render,
      # so assert_turbo_stream never reads it.
      # @api private
      def self.last_html_reset
        -> {
          Test.last_html = ""
          nil
        }
      end

      # `html` with the content of every `<template>` replaced by spaces,
      # byte for byte (nested templates counted; comments, `script` and
      # `style` skipped, so a "<template>" in them is not one). A template
      # with no end is left as it is.
      # @api private
      def self.blank_templates(html)
        s = html.to_s
        out = s.dup
        n = s.bytesize
        i = 0
        while i < n
          if s.getbyte(i) != 60
            i += 1
            next
          end
          skip = skipped_end(s, i)
          if skip > i
            i = skip
            next
          end
          if tag_named?(s, i, "template", false)
            open_end = HtmlReader.byte_after(s, i, ">")
            break if open_end < 0

            close = template_close(s, open_end)
            break if close < 0

            k = open_end
            while k < close
              out.setbyte(k, 32)
              k += 1
            end
            i = close + 1
            next
          end
          i += 1
        end
        out
      end

      # The byte of the `</template` that closes a template whose content
      # starts at `from`; -1 when there is none.
      # @api private
      def self.template_close(html, from)
        s = html.to_s
        n = s.bytesize
        depth = 1
        j = from
        while j < n
          if s.getbyte(j) != 60
            j += 1
            next
          end
          skip = skipped_end(s, j)
          return -1 if skip == -2
          if skip > j
            j = skip
            next
          end
          if tag_named?(s, j, "template", false)
            depth += 1
          elsif tag_named?(s, j, "template", true)
            depth -= 1
            return j if depth == 0
          end
          j += 1
        end
        -1
      end

      # At a `<`: the byte after a comment, a `script` or a `style`
      # element that starts there; `i` itself when none does; -2 when one
      # starts there and has no end.
      # @api private
      def self.skipped_end(html, i)
        s = html.to_s
        if HtmlReader.tag_kind(s, i) == 1
          close = HtmlReader.byte_after(s, i + 4, "-->")
          return close < 0 ? -2 : close
        end
        raw = ""
        raw = "script" if tag_named?(s, i, "script", false)
        raw = "style" if tag_named?(s, i, "style", false)
        return i if raw.empty?

        close = HtmlReader.raw_end(s, i + 1, raw)
        close < 0 ? -2 : close
      end

      # Whether a start (or, with `end_tag`, an end) tag named `name`
      # starts at the `<` at byte i, in any case.
      # @api private
      def self.tag_named?(html, i, name, end_tag)
        s = html.to_s
        t = name.to_s
        n = s.bytesize
        at = end_tag ? i + 2 : i + 1
        return false if end_tag && (i + 1 >= n || s.getbyte(i + 1) != 47)
        return false if at + t.bytesize > n
        return false unless s.byteslice(at, t.bytesize).downcase == t
        return true if at + t.bytesize == n

        HtmlReader.tag_name_end?(s.getbyte(at + t.bytesize))
      end

      # `append comments` for one turbo-stream element (`refresh` alone
      # when it has no target).
      # @api private
      def self.turbo_label(node)
        target = node.node_attr("target")
        return node.node_attr("action") if target.empty?

        "#{node.node_attr("action")} #{target}"
      end
    end

    # The largest message id when the current test began (read by the
    # reset hook cybertrain/test_help registers): what `assert_broadcasts`
    # without a block counts from. 0 when the database had no messages
    # table, or none was connected.
    # @return [Integer]
    # @api public
    def self.case_message_floor = Broadcasts.case_floor

    # `assert_broadcasts` / `assert_no_broadcasts`: the count of `name`'s
    # messages against `count`.
    # @api private
    def self.check_broadcasts(name, count, got)
      count_assertion
      return nil if got == count

      noun = count == 1 ? "broadcast" : "broadcasts"
      text = "Expected #{count} #{noun} on #{name.inspect}, got #{got}"
      fail_with(text)
      nil
    end

    # Every `<turbo-stream>` element of `html`, its templates' content not
    # read; fails the assertion when the HTML around them cannot be read.
    # @api private
    def self.turbo_stream_nodes(html)
      s = html.to_s
      found = Array.new(0) { HtmlNode.new("", 0, -1, 0) }
      nodes = found
      problem = ""
      begin
        nodes = HtmlReader.parse(Broadcasts.blank_templates(s))
      rescue HtmlReader::Malformed => e
        problem = e.message
      end
      unless problem == ""
        text = "assert_turbo_stream: the HTML could not be read: #{problem}\n#{html_excerpt(s)}"
        fail_with(text)
      end
      nodes.each { |node| found << node if node.node_tag == "turbo-stream" }
      found
    end

    # `assert_turbo_stream`: exactly `count` streams of `action` on
    # `target` among `streams`.
    # @api private
    # An empty `html` (no request or render yet in this test, or an empty
    # body) is said so after "none".
    def self.check_turbo_stream(action, target, count, streams, html)
      if count < 0
        message = "assert_turbo_stream: count: must be 0 or more (got #{count})"
        raise ArgumentError, message
      end
      count_assertion
      matched = 0
      seen = Array.new(0) { "" }
      streams.each do |node|
        matched += 1 if node.node_attr("action") == action && node.node_attr("target") == target
        seen << Broadcasts.turbo_label(node)
      end
      return nil if matched == count

      element = "<turbo-stream action=\"#{action}\" target=\"#{target}\">"
      list = seen.empty? ? "none" : seen.join(", ")
      list = "none (no response or render yet in this test, or an empty body)" if html.to_s.empty?
      text = if count == 1 && matched == 0
               "Expected a #{element}, found: #{list}"
             elsif count == 0
               "Expected no #{element}, found #{matched} in: #{list}"
             else
               "Expected exactly #{count} #{element}, found #{matched} in: #{list}"
             end
      fail_with(text)
      nil
    end
  end
end

# Passes when `count` messages were broadcast to `stream` (rows written to
# `cybertrain_messages`) while the block ran, or, without a block, since
# the test began; answers their payloads, oldest first. `stream` is a name
# or a record (its {Cybertrain::Stream.name_for}, `"articles:12"`).
# @example
#   payloads = assert_broadcasts(articles(:one), 1) do
#     post article_comments_path(articles(:one)), params: { comment: { body: "Hi" } }
#   end
#   assert_includes payloads[0], 'target="comments"'
# @param stream [String, Cybertrain::Model]
# @param count [Integer]
# @yield the code that broadcasts (optional)
# @return [Array<String>] the payloads counted
# @raise [ArgumentError] for a record that is not saved
# @api public
def assert_broadcasts(stream, count)
  name = Cybertrain::Stream.name_for(stream)
  floor = Cybertrain::Test.case_message_floor
  if block_given?
    floor = Cybertrain::Test::Broadcasts.head_id
    yield
  end
  payloads = Cybertrain::Test::Broadcasts.payloads_after(name, floor)
  Cybertrain::Test.check_broadcasts(name, count, payloads.length)
  payloads
end

# Passes when nothing was broadcast to `stream` while the block ran, or,
# without a block, since the test began: `assert_broadcasts(stream, 0)`.
# @param stream [String, Cybertrain::Model]
# @yield the code that must not broadcast (optional)
# @return [nil]
# @api public
def assert_no_broadcasts(stream)
  name = Cybertrain::Stream.name_for(stream)
  floor = Cybertrain::Test.case_message_floor
  if block_given?
    floor = Cybertrain::Test::Broadcasts.head_id
    yield
  end
  got = Cybertrain::Test::Broadcasts.payloads_after(name, floor).length
  Cybertrain::Test.check_broadcasts(name, 0, got)
end

# Passes when the last response (or `render_inline`) of this test holds
# exactly `count` `<turbo-stream action="..." target="...">` elements, as
# turbo-rails' assertion does (count 1 by default). `target` is a DOM id
# or a record (its dom_id, `"article_12"`). The content of the streams'
# templates is not read; the block form of turbo-rails is not offered.
# @example
#   post article_comments_path(article), params: { comment: { body: "Hi" } },
#        headers: { "Accept" => "text/vnd.turbo-stream.html" }
#   assert_turbo_stream action: "append", target: "comments"
# @param action [String]
# @param target [String, Cybertrain::Model]
# @param count [Integer]
# @return [nil]
# @raise [ArgumentError] for a negative count
# @api public
def assert_turbo_stream(action:, target:, count: 1)
  id = Cybertrain::Turbo.target_text(target)
  html = Cybertrain::Test.last_html
  streams = Cybertrain::Test.turbo_stream_nodes(html)
  Cybertrain::Test.check_turbo_stream(action.to_s, id, count, streams, html)
end
