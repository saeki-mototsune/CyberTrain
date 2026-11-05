module Cybertrain
  # Server-Sent Events formatting (the text/event-stream format of the HTML
  # standard): one event per call, ready for {Sink#write}.
  # @example
  #   stream do |out|
  #     out.write(Cybertrain::SSE.event(JSON.generate({ "price" => 12 }), event: "tick", id: "7"))
  #   end
  # @api public
  module SSE
    # One event: `event:`, `id:` and `retry:` lines when given, then one
    # `data:` line per line of `data` (a CR, LF or CRLF in it starts a new
    # `data:` line, so the payload cannot end the event early), then the
    # blank line.
    # @param data [String]
    # @param event [String] the event type ("" for the default `message`)
    # @param id [String] the last-event id the browser sends back on reconnect
    # @param retry_ms [Integer] the reconnection delay, 0 to leave it out
    # @return [String]
    # @raise [ArgumentError] when event or id holds a CR or LF
    # @api public
    def self.event(data, event: "", id: "", retry_ms: 0)
      SSE.check_field("event", event)
      SSE.check_field("id", id)
      out = +""
      unless event.empty?
        out << "event: "
        out << event
        out << "\n"
      end
      unless id.empty?
        out << "id: "
        out << id
        out << "\n"
      end
      if retry_ms > 0
        out << "retry: "
        out << retry_ms.to_s
        out << "\n"
      end
      # Returned and appended, never filled through a parameter: a buffer
      # appended to directly loses what helpers append to it (NOTES rule 66).
      out << SSE.data_lines(data.to_s)
      out << "\n"
      out
    end

    # A comment line (`: text`), which a browser ignores: what keeps a proxy
    # from timing out an idle stream.
    # @param text [String] without CR or LF
    # @return [String]
    def self.comment(text)
      SSE.check_field("comment", text)
      out = +": "
      out << text
      out << "\n\n"
      out
    end

    def self.check_field(name, value)
      if value.include?("\n") || value.include?("\r")
        raise ArgumentError, "SSE #{name} must not contain CR or LF"
      end
      nil
    end

    # `data: <line>\n` for every line of text; byte offsets throughout
    # (spikes/NOTES.md rule 27).
    def self.data_lines(text)
      out = +""
      n = text.bytesize
      start = 0
      i = 0
      while i < n
        b = text.getbyte(i)
        if b == 10 || b == 13
          out << "data: "
          out << text.byteslice(start, i - start)
          out << "\n"
          i += 1 if b == 13 && i + 1 < n && text.getbyte(i + 1) == 10
          start = i + 1
        end
        i += 1
      end
      out << "data: "
      out << text.byteslice(start, n - start)
      out << "\n"
      out
    end
  end
end
