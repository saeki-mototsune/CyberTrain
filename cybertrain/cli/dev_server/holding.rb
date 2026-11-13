# What `cybertrain server` answers while no child can serve (HOLDING in
# docs/superpowers/specs/2026-11-12-cruby-preview-design.md section 6): gen
# failed, the CRuby child could not boot or stopped, or `cybertrain build`
# holds its lock. The supervisor itself accepts on the listener then and
# answers every request with a 503 page that shows the error and what it is
# waiting for, and refreshes itself, so the browser comes back on its own
# once a child serves again. CRuby only, never compiled by Spinel; it needs
# nothing outside the standard library.
module Cybertrain
  module CLI
    module DevServer
      module Holding
        # How long a held connection may take to send its request head, and
        # how long a closed one is read for before it is closed: a socket
        # closed with unread bytes is reset, and the client then loses the
        # page it was sent.
        HEAD_WAIT = 1.0
        DRAIN_WAIT = 1.0
        # A request head longer than this is answered without waiting for
        # its end: the page is the same whatever was asked.
        HEAD_LIMIT = 65_536

        # A complete HTTP/1.1 response: 503, Retry-After: 1, Connection:
        # close, and an HTML page with the title, the text, what the
        # supervisor waits for, and a refresh every two seconds.
        # @param title [String]
        # @param text [String] the error (gen's output, what is known about the child)
        # @param waiting_for [String]
        # @return [String]
        def self.page(title, text, waiting_for)
          body = <<~HTML
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta http-equiv="refresh" content="2">
            <title>#{escape(title)}</title>
            <style>
            body { font-family: system-ui, sans-serif; margin: 2rem; color: #1f2937; }
            pre { background: #f3f4f6; padding: 1rem; white-space: pre-wrap; overflow-wrap: anywhere; }
            .note { color: #6b7280; font-size: 0.9rem; }
            </style>
            </head>
            <body>
            <h1>#{escape(title)}</h1>
            <pre>#{escape(text)}</pre>
            <p>Waiting for: #{escape(waiting_for)}</p>
            <p class="note">This page is the supervisor's: the preview runs the application under CRuby and hands the port to the compiled binary once its background build succeeds.
            cybertrain server --spinel runs the compiled loop only.</p>
            </body>
            </html>
          HTML
          head = ["HTTP/1.1 503 Service Unavailable",
                  "Content-Type: text/html; charset=utf-8",
                  "Retry-After: 1",
                  "Cache-Control: no-store",
                  "Connection: close",
                  "Content-Length: #{body.bytesize}"]
          "#{head.join("\r\n")}\r\n\r\n#{body}"
        end

        # The five characters that matter in HTML text and attributes.
        def self.escape(text)
          text.to_s.gsub(/[&<>"']/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;", "'" => "&#39;")
        end

        # The connections the supervisor accepted while holding. Nothing here
        # blocks: the driver calls #accept and #serve on every tick, and a
        # connection is answered once its request head has arrived (or after
        # HEAD_WAIT, or at #flush), then read until the client closes (or
        # DRAIN_WAIT) and closed.
        class Desk
          Held = Struct.new(:socket, :since, :head)

          def initialize
            @waiting = []
            @draining = []
          end

          # Takes every connection the listener has queued.
          # @param listener [TCPServer]
          def accept(listener)
            loop do
              socket = listener.accept_nonblock(exception: false)
              break if socket == :wait_readable

              @waiting << Held.new(socket, now, +"")
            end
            nil
          rescue SystemCallError, IOError
            nil
          end

          # Answers the connections whose request head is in with page.
          def serve(page)
            @waiting.dup.each do |held|
              read_into(held)
              answer(held, page) if held.head.nil? || held.head.include?("\r\n\r\n") ||
                                   held.head.bytesize > HEAD_LIMIT || now - held.since >= HEAD_WAIT
            end
            drain
            nil
          end

          # Answers every waiting connection with page at once (holding
          # ends), then drains.
          def flush(page)
            @waiting.dup.each { |held| answer(held, page) }
            drain
            nil
          end

          # The sockets IO.select should wake the driver for.
          def ios
            (@waiting + @draining).map(&:socket)
          end

          def close
            (@waiting + @draining).each { |held| held.socket.close unless held.socket.closed? }
            @waiting.clear
            @draining.clear
            nil
          end

          # Closes the answered connections whose client has closed, or that
          # have been read for DRAIN_WAIT. Called on every tick, holding or
          # not, so that a page given at release_hold is not left open.
          def drain
            @draining.dup.each do |held|
              done = now - held.since >= DRAIN_WAIT
              begin
                done ||= held.socket.read_nonblock(16_384, exception: false).nil?
              rescue SystemCallError, IOError
                done = true
              end
              next unless done

              held.socket.close unless held.socket.closed?
              @draining.delete(held)
            end
            nil
          end

          private

          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          # Appends what has arrived; a head of nil means the client closed.
          def read_into(held)
            return if held.head.nil?

            chunk = held.socket.read_nonblock(16_384, exception: false)
            if chunk.nil?
              held.head = nil
            elsif chunk.is_a?(String)
              held.head << chunk
            end
          rescue SystemCallError, IOError
            held.head = nil
          end

          def answer(held, page)
            @waiting.delete(held)
            begin
              held.socket.write(page)
              held.socket.close_write
            rescue SystemCallError, IOError
              held.socket.close unless held.socket.closed?
              return
            end
            held.since = now
            @draining << held
          end

        end
      end
    end
  end
end
