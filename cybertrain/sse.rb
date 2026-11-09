module Cybertrain
  # Server-Sent Events, the reading side: {Sse::Parser} turns the chunks of
  # a streamed `text/event-stream` response into {Sse::Event}s following the
  # WHATWG parsing rules. (Cybertrain::SSE in http/sse.rb formats events for
  # a server; this module consumes them.)
  # @example
  #   parser = Cybertrain::Sse::Parser.new
  #   client.get(url) { |chunk| parser.feed(chunk) { |event| puts event.event_data } }
  #   parser.finish { |event| puts event.event_data }
  # @api public
  module Sse
    # One dispatched event. The readers carry an `event_` prefix so that no
    # other class in the program shares their names (spikes/NOTES.md rules
    # 10/34/41).
    # @api public
    class Event
      # @return [String] the `event:` field, "message" when absent or empty
      attr_reader :event_name
      # @return [String] the `data:` lines joined with "\n"
      attr_reader :event_data
      # @return [String] the last `id:` seen on the stream so far (it
      #   persists across events, as the WHATWG last event id does); ""
      #   when none
      attr_reader :event_id
      # @return [Integer] the `retry:` milliseconds given since the previous
      #   event, 0 when none
      attr_reader :event_retry_ms

      # @param name [String]
      # @param data [String]
      # @param id [String]
      # @param retry_ms [Integer]
      def initialize(name, data, id, retry_ms)
        @event_name = name
        @event_data = data
        @event_id = id
        @event_retry_ms = retry_ms
      end
    end

    # The incremental parser. Feed it chunks as they arrive (cut anywhere:
    # mid-line, between a CR and its LF, inside a multi-byte character; it
    # works on bytes and cuts lines only at CR, LF or CRLF); each complete
    # event is yielded. A line is processed as soon as its terminator
    # arrives, so a long line costs time linear in its length.
    #
    # Rules: a leading UTF-8 BOM is ignored; a line starting with ":" is a
    # comment; a line without ":" is a field with an empty value; one space
    # after the colon is dropped; unknown fields are ignored; `id` holding a
    # NUL is ignored; `retry` counts only when it is all ASCII digits (more
    # than fifteen digits are bounded to 999999999999999); a blank line
    # dispatches the event unless no `data` line was seen.
    #
    # `feed` and `finish` yield, so they hold no rescue or ensure
    # (spikes/NOTES.md rules 32/45): an exception in the block leaves the
    # parser as it was when the block was called.
    # @api public
    class Parser
      # @api private
      MAX_RETRY_DIGITS = 15
      # @api private
      MAX_RETRY = 999999999999999

      def initialize
        @line = +""
        @data = +""
        @has_data = false
        @name = +""
        @last_id = +""
        @retry_ms = 0
        @skip_lf = false
        @first_line = true
      end

      # Parses one chunk.
      # @param chunk [String] the next bytes of the stream
      # @yieldparam event [Event] each event completed by this chunk
      # @return [void]
      # @api public
      def feed(chunk)
        n = chunk.bytesize
        start = 0
        i = 0
        while i < n
          b = chunk.getbyte(i)
          if @skip_lf
            @skip_lf = false
            if b == 10
              i += 1
              start = i
              next
            end
          end
          if b == 10 || b == 13
            @line << chunk.byteslice(start, i - start) if i > start
            @skip_lf = (b == 13)
            i += 1
            start = i
            if line_done
              yield take_event
            end
          else
            i += 1
          end
        end
        @line << chunk.byteslice(start, n - start) if n > start
        nil
      end

      # Ends the stream: a final line without a terminator is read, and an
      # event that was not closed by a blank line is yielded (when it has
      # data). Leaves the parser ready for a new stream.
      # @yieldparam event [Event]
      # @return [void]
      # @api public
      def finish
        if @line.bytesize > 0
          line_done
        end
        if @has_data
          yield take_event
        end
        reset_stream
        nil
      end

      private

      def reset_stream
        @line = +""
        @data = +""
        @has_data = false
        @name = +""
        @last_id = +""
        @retry_ms = 0
        @skip_lf = false
        @first_line = true
      end

      # The event the parser has gathered, clearing the per-event state.
      def take_event
        name = @name.bytesize > 0 ? @name : "message"
        out = @data
        out = out.byteslice(0, out.bytesize - 1) if out.bytesize > 0
        ev = Event.new(name, out, @last_id, @retry_ms)
        @data = +""
        @has_data = false
        @name = +""
        @retry_ms = 0
        ev
      end

      # Processes @line (a complete line) and clears it. True when the line
      # was blank and an event with data is waiting to be taken.
      def line_done
        line = @line
        @line = +""
        if @first_line
          @first_line = false
          if line.bytesize >= 3 && line.getbyte(0) == 239 && line.getbyte(1) == 187 && line.getbyte(2) == 191
            line = line.byteslice(3, line.bytesize - 3)
          end
        end
        return @has_data if line.bytesize == 0
        return false if line.getbyte(0) == 58

        colon = line.byteindex(":")
        field = line
        value = ""
        unless colon.nil?
          field = line.byteslice(0, colon)
          from = colon + 1
          from += 1 if from < line.bytesize && line.getbyte(from) == 32
          value = line.byteslice(from, line.bytesize - from)
        end
        apply_field(field, value)
        false
      end

      def apply_field(field, value)
        if field == "data"
          @data << value
          @data << "\n"
          @has_data = true
        elsif field == "event"
          @name = value
        elsif field == "id"
          @last_id = value unless nul?(value)
        elsif field == "retry"
          @retry_ms = parse_retry(value) if digits?(value)
        end
      end

      def nul?(text)
        i = 0
        n = text.bytesize
        while i < n
          return true if text.getbyte(i) == 0
          i += 1
        end
        false
      end

      def digits?(text)
        n = text.bytesize
        return false if n == 0
        i = 0
        while i < n
          b = text.getbyte(i)
          return false if b < 48 || b > 57
          i += 1
        end
        true
      end

      # value is all ASCII digits; to_i raises on 20+ digits (NOTES rule 25),
      # so a long one is bounded first.
      def parse_retry(value)
        return MAX_RETRY if value.bytesize > MAX_RETRY_DIGITS
        value.to_i
      end
    end
  end
end
