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
#   test began (`Test.case_message_floor`, step 3 of the order, after the
#   bundle's clear of the tables), so a broadcast of an earlier test is
#   never counted.
# - Rows the poller prunes are not counted: the poller runs only in a
#   server a test boots itself (`Application#serve`), never in-process,
#   and prunes by `Config#stream_retention` against the Clock, so a test
#   that serves and then travels far ahead can lose rows it broadcast
#   before the travel. Count before travelling, or use the block form.
# - `assert_turbo_stream(action:, target:)` reads the last response or
#   render (`Test.last_html`) with the test HTML reader; a response must be
#   `text/vnd.turbo-stream.html`, as turbo-rails checks. The content of a
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


      # `html` with the content of every `<template>` replaced by spaces,
      # byte for byte, so the reader's offsets stay those of the HTML as
      # written. The scan tokenises as HtmlReader.parse does, through the
      # reader's own functions: comments and declarations end where
      # {HtmlReader.markup_end} says, start tags (quoted attribute values,
      # `script` / `style` raw text, `textarea` / `title` text) are read by
      # {HtmlReader.read_start_tag}, so a `</template>` inside any of them
      # does not end a template. Only end tags are lenient: one closes the
      # nearest open element of its name (or nothing), because a template's
      # content need not be balanced. When the reader cannot tokenise the
      # HTML (an unterminated tag, comment or quoted value, `<div/>`), it is
      # answered unchanged, so the reader reports the problem itself.
      # @api private
      def self.blank_templates(html)
        s = html.to_s
        out = s.dup
        n = s.bytesize
        nodes = Array.new(0) { HtmlNode.new("", 0, -1, 0) }
        stack = Array.new(0) { 0 }
        content_from = -1
        i = 0
        while i < n
          if s.getbyte(i) != 60
            i += 1
            next
          end
          kind = HtmlReader.tag_kind(s, i)
          if kind == 0
            i += 1
          elsif kind == 1 || kind == 2
            close = HtmlReader.markup_end(s, i, kind, HtmlReader.in_foreign?(nodes, stack))
            return s if close < 0

            i = close
          elsif kind == 3
            j = i + 2
            j += 1 while j < n && !HtmlReader.tag_name_end?(s.getbyte(j))
            tag = s.byteslice(i + 2, j - i - 2).downcase
            j += 1 while j < n && s.getbyte(j) != 62
            return s if j >= n

            close_open(nodes, stack, tag)
            if tag == "template" && content_from >= 0 && !template_open?(nodes, stack)
              k = content_from
              while k < i
                out.setbyte(k, 32)
                k += 1
              end
              content_from = -1
            end
            i = j + 1
          else
            after = start_tag_end(s, i, nodes, stack)
            return s if after < 0

            opened = !stack.empty? && stack[stack.length - 1] == nodes.length - 1
            content_from = after if content_from < 0 && opened && nodes[nodes.length - 1].node_tag == "template"
            i = after
          end
        end
        out
      end

      # HtmlReader.read_start_tag at byte i; -1 when it refuses the tag.
      # @api private
      def self.start_tag_end(html, i, nodes, stack)
        s = html.to_s
        after = -1
        begin
          after = HtmlReader.read_start_tag(s, i, nodes, stack)
        rescue HtmlReader::Malformed
          after = -1
        end
        after
      end

      # Pops the open elements down to and including the nearest one named
      # `tag`; nothing when none is open.
      # @api private
      def self.close_open(nodes, stack, tag)
        k = stack.length - 1
        k -= 1 while k >= 0 && nodes[stack[k]].node_tag != tag
        stack.pop while k >= 0 && stack.length > k
        nil
      end

      # Whether a template is among the open elements.
      # @api private
      def self.template_open?(nodes, stack)
        k = 0
        while k < stack.length
          return true if nodes[stack[k]].node_tag == "template"

          k += 1
        end
        false
      end

      # `append comments` for one turbo-stream element: `refresh` alone when
      # it has no target, `remove targets=.x` for one with `targets`.
      # @api private
      def self.turbo_label(node)
        action = node.node_attr("action")
        target = node.node_attr("target")
        return "#{action} #{target}" unless target.empty?
        return "#{action} targets=#{node.node_attr("targets")}" if node.node_attr?("targets")

        action
      end

      # The media type of a Content-Type value, lower-cased, without its
      # parameters (`text/vnd.turbo-stream.html`).
      # @api private
      def self.media_type(content_type)
        text = content_type.to_s
        cut = text.index(";")
        text = text[0, cut] unless cut.nil?
        text.strip.downcase
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

    # What assert_turbo_stream fails with when the running test has neither
    # requested a page nor called `render_inline` (as assert_select).
    NO_TURBO_STREAM_YET = "assert_turbo_stream: No response yet. Request a page or call render_inline first."

    # The media type a Turbo Stream response has.
    TURBO_STREAM_MEDIA = "text/vnd.turbo-stream.html"

    # Before `assert_turbo_stream` reads the last HTML: something was
    # rendered or requested in this test, and a response (not a
    # `render_inline`) is a Turbo Stream, as turbo-rails' integration
    # assertion checks (`response.media_type`).
    # @api private
    def self.check_turbo_source
      unless last_html?
        text = NO_TURBO_STREAM_YET
        fail_with(text)
      end
      return nil unless last_html_response?

      media = Broadcasts.media_type(last_content_type)
      return nil if media == TURBO_STREAM_MEDIA

      shown = last_content_type.empty? ? "no Content-Type" : last_content_type.inspect
      text = "assert_turbo_stream: expected a #{TURBO_STREAM_MEDIA} response, got #{shown}"
      fail_with(text)
      nil
    end

    # `assert_turbo_stream`: exactly `count` streams of `action` on
    # `target` among `streams`. A `target` of "" matches a stream that has
    # none (`refresh`).
    # @api private
    def self.check_turbo_stream(action, target, count, streams)
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
#
# Only rows still in the table are counted. In-process nothing deletes
# them, but a test that boots a real server (`Application#serve`) runs its
# poller, which prunes rows older than `Config#stream_retention` by the
# Clock: after `travel_to` far ahead, rows broadcast before the travel can
# be gone, so a count without a block comes out low and
# `assert_no_broadcasts` passes. Count before travelling, or wrap the
# broadcasting code in the block.
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
# without a block, since the test began: `assert_broadcasts(stream, 0)`
# (and, as it, blind to rows a real server's poller pruned).
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
# or a record (its dom_id, `"article_12"`); `""` matches a stream with no
# target (`refresh`). After an integration request the response must be
# `text/vnd.turbo-stream.html` (turbo-rails' media type check; its
# `status: :ok` check is not made: assert the status with
# `assert_response`). With nothing requested or rendered in this test it
# fails ("No response yet"). The content of the streams' templates is not
# read; turbo-rails' block form and `targets:` are not offered.
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
  Cybertrain::Test.check_turbo_source
  streams = Cybertrain::Test.turbo_stream_nodes(Cybertrain::Test.last_html)
  Cybertrain::Test.check_turbo_stream(action.to_s, id, count, streams)
end
