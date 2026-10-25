# Cybertrain::Test::SmtpReceiver -- a plain-text SMTP server on 127.0.0.1
# that plays the server side of a delivery (220, EHLO, MAIL, RCPT, DATA,
# QUIT) and records what the application sent through Cybertrain::Mailer
# (`tls: "none"`). Any step can be scripted to fail, so the application's
# handling of a rejected delivery can be tested too. See
# cybertrain/test/receiver.rb for how every wait is bounded.
require "cybertrain/test/receiver"

module Cybertrain
  module Test
    # What one SMTP connection carried.
    # @api public
    class ReceivedMessage
      # @return [String] the MAIL FROM address, without the angle brackets
      # @api public
      attr_reader :envelope_from

      # @return [Array<String>] the RCPT TO addresses the receiver accepted
      # @api public
      attr_reader :envelope_recipients

      # @return [String] the message as it was sent after DATA: headers, a
      #   blank line, the body, CRLF line endings, dot-stuffing undone, the
      #   final "." line removed; "" when no message was accepted
      # @api public
      attr_reader :message_data

      # @return [Array<String>] every command line the client sent, in order
      #   ("EHLO localhost", "MAIL FROM:<a@example.com>", ..., "QUIT"); the
      #   message itself is in {#message_data}, not here
      # @api public
      attr_reader :transcript

      def initialize(from, recipients, data, transcript)
        @envelope_from = from
        @envelope_recipients = recipients
        @message_data = data
        @transcript = transcript
      end

      # Whether a message was accepted (the 250 after the data was sent).
      # @return [Boolean]
      # @api public
      def delivered?
        !@message_data.empty?
      end

      # The message body: what follows the blank line after the headers.
      # @return [String]
      # @api public
      def message_body
        at = @message_data.byteindex("\r\n\r\n")
        return "" if at.nil?

        @message_data.byteslice(at + 4, @message_data.bytesize - at - 4)
      end

      # The value of the first message header named `name` (any case),
      # unfolded; "" when there is none.
      # @param name [String]
      # @return [String]
      # @api public
      def message_header(name)
        wanted = name.to_s.downcase
        data = @message_data
        stop = data.byteindex("\r\n\r\n")
        stop = data.bytesize if stop.nil?
        pos = 0
        found = false
        value = String.new
        while pos < stop
          eol = data.byteindex("\r\n", pos)
          eol = stop if eol.nil? || eol > stop
          line = data.byteslice(pos, eol - pos)
          pos = eol + 2
          continued = line.start_with?(" ") || line.start_with?("\t")
          if found
            break unless continued

            value << " " << line.strip
          elsif !continued
            colon = line.byteindex(":")
            if !colon.nil? && line.byteslice(0, colon).downcase == wanted
              found = true
              value << line.byteslice(colon + 1, line.bytesize - colon - 1).strip
            end
          end
        end
        value
      end
    end

    # A receiver for e-mail in a test: `start` binds a port on 127.0.0.1,
    # the application delivers to it with `tls: "none"`, {#received_message} returns
    # what arrived. It accepts `max` connections (1 by default), one
    # {ReceivedMessage} each.
    #
    # `reject:` makes a step fail with the reply given, to test how the
    # application handles a refused delivery. Its keys are `:greeting`,
    # `:ehlo`, `:mail`, `:rcpt`, `:data` (the reply to DATA) and `:message`
    # (the reply after the message was sent).
    # @example
    #   require "cybertrain/test/smtp_receiver"
    #
    #   test "the welcome mail" do
    #     smtp = Cybertrain::Test::SmtpReceiver.new
    #     port = smtp.start
    #     mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
    #     Welcome.deliver(mailer, "ann@example.com")   # the code under test
    #     mail = smtp.received_message                          # waits at most 5 s; nil if nothing came
    #     smtp.stop
    #     assert_equal ["ann@example.com"], mail.envelope_recipients
    #     assert_equal "Welcome", mail.message_header("Subject")
    #   end
    # @example a refused recipient
    #   smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
    # @api public
    class SmtpReceiver < Receiver
      # The largest message the receiver reads.
      MAX_MESSAGE_BYTES = 10_485_760

      # A command line longer than this ends the connection (RFC 5321 allows
      # 512 bytes; AUTH lines may be longer).
      MAX_COMMAND_BYTES = 4096

      # A typed empty Hash for the `reject:` default (spikes/NOTES.md rule 9).
      def self.no_rejections
        h = { greeting: "" }
        h.delete(:greeting)
        h
      end

      # @param reject [Hash{Symbol => String}] steps to refuse, each with the
      #   whole reply line to send ("550 5.1.1 no such user")
      # @param eight_bit_mime [Boolean] offer 8BITMIME in the EHLO reply
      # @param auth [Boolean] offer AUTH PLAIN and accept any credentials
      #   (the AUTH line, credentials included, is in the transcript)
      # @param max [Integer] how many connections (one message each) to accept
      # @param accept_window [Numeric] seconds to wait for each connection
      #   before the receiver gives up and closes its port
      # @param read_timeout [Numeric] seconds of silence that end a connection
      # @param name [String] the server name in the greeting and EHLO reply
      # @api public
      def initialize(reject: SmtpReceiver.no_rejections, eight_bit_mime: true, auth: false, max: 1,
                     accept_window: 10.0, read_timeout: 5.0, name: "receiver.test")
        super(max, accept_window, read_timeout)
        @reject_greeting = reject[:greeting].to_s
        @reject_ehlo = reject[:ehlo].to_s
        @reject_mail = reject[:mail].to_s
        @reject_rcpt = reject[:rcpt].to_s
        @reject_data = reject[:data].to_s
        @reject_message = reject[:message].to_s
        @eight_bit_mime = eight_bit_mime ? true : false
        @offer_auth = auth ? true : false
        @server_name = name.to_s
        @messages = Array.new(0) { ReceivedMessage.new("", Array.new(0) { "" }, "", Array.new(0) { "" }) }
        @lock = Mutex.new
        # The connection in progress (one at a time, on the receiver's thread).
        @from = ""
        @recipients = Array.new(0) { "" }
        @data = ""
        @commands = Array.new(0) { "" }
      end

      # The first message, waiting at most `wait` seconds for its connection
      # to end (the client's QUIT, or the connection closing).
      # @param wait [Numeric]
      # @return [ReceivedMessage, nil] nil when none arrived in time
      # @api public
      def received_message(wait = 5.0)
        return nil unless await_count(1, wait)

        @messages[0]
      end

      # The messages that arrived, waiting at most `wait` seconds for `count`
      # of them (0: the receiver's `max`). Fewer when the time ran out.
      # @param count [Integer]
      # @param wait [Numeric]
      # @return [Array<ReceivedMessage>]
      # @api public
      def received_messages(count = 0, wait = 5.0)
        await_count(count > 0 ? count : @max, wait)
        out = Array.new(0) { ReceivedMessage.new("", Array.new(0) { "" }, "", Array.new(0) { "" }) }
        n = received_count
        i = 0
        while i < n
          out << @messages[i]
          i += 1
        end
        out
      end

      def received_count
        n = 0
        @lock.synchronize { n = @messages.size }
        n
      end

      # One connection: the dialogue until QUIT, the client going away or
      # going silent; then the record of it.
      def serve_connection(sock)
        @from = ""
        @recipients = Array.new(0) { "" }
        @data = ""
        @commands = Array.new(0) { "" }
        rx_converse(sock)
        record = ReceivedMessage.new(@from, @recipients, @data, @commands)
        @lock.synchronize { @messages << record }
        nil
      end

      def rx_converse(sock)
        if @reject_greeting.empty?
          reply(sock, "220 #{@server_name} ESMTP ready")
        else
          reply(sock, @reject_greeting)
        end
        while marker_ready?(sock, "\r\n", MAX_COMMAND_BYTES)
          line = cut_to("\r\n")
          @commands << line
          break unless answer_command(sock, line)
        end
        nil
      end

      # Answers one command line; false once the connection should end.
      def answer_command(sock, line)
        verb = SmtpReceiver.verb_of(line)
        case verb
        when "EHLO", "HELO"
          reply(sock, @reject_ehlo.empty? ? ehlo_reply(verb == "EHLO") : @reject_ehlo)
        when "MAIL"
          if @reject_mail.empty?
            @from = SmtpReceiver.address_in(line)
            @recipients = Array.new(0) { "" }
            reply(sock, "250 2.1.0 Ok")
          else
            reply(sock, @reject_mail)
          end
        when "RCPT"
          if @reject_rcpt.empty?
            @recipients << SmtpReceiver.address_in(line)
            reply(sock, "250 2.1.5 Ok")
          else
            reply(sock, @reject_rcpt)
          end
        when "DATA"
          return true if answer_data(sock)
          return false
        when "AUTH"
          reply(sock, @offer_auth ? "235 2.7.0 Authentication successful" : "502 5.5.1 AUTH not available")
        when "RSET"
          @from = ""
          @recipients = Array.new(0) { "" }
          reply(sock, "250 2.0.0 Ok")
        when "NOOP"
          reply(sock, "250 2.0.0 Ok")
        when "STARTTLS"
          reply(sock, "454 4.7.0 TLS not available")
        when "QUIT"
          reply(sock, "221 2.0.0 Bye")
          return false
        else
          reply(sock, "502 5.5.2 Command not recognized")
        end
        true
      end

      # DATA: the 354 (or the scripted rejection), the message up to the
      # "." line, then the 250 (or the rejection). False when the message
      # never ended.
      def answer_data(sock)
        if @recipients.empty?
          reply(sock, "554 5.5.1 No valid recipients")
          return true
        end
        unless @reject_data.empty?
          reply(sock, @reject_data)
          return true
        end

        reply(sock, "354 End data with <CR><LF>.<CR><LF>")
        if unread_starts_at_end?(sock)
          cut_bytes(3)
          payload = ""
        else
          return false unless marker_ready?(sock, "\r\n.\r\n", MAX_MESSAGE_BYTES)

          payload = cut_to("\r\n.\r\n")
        end
        if @reject_message.empty?
          @data = SmtpReceiver.unstuff(payload)
          reply(sock, "250 2.0.0 Ok: queued")
        else
          reply(sock, @reject_message)
        end
        true
      end

      # Whether the message is empty: the "." line straight after the 354.
      def unread_starts_at_end?(sock)
        return false unless bytes_ready?(sock, 3)

        unread_starts?(".\r\n")
      end

      def ehlo_reply(extended)
        out = String.new
        if extended
          out << "250-" << @server_name << " greets you\r\n"
          out << "250-8BITMIME\r\n" if @eight_bit_mime
          out << "250-AUTH PLAIN\r\n" if @offer_auth
          out << "250 HELP"
        else
          out << "250 " << @server_name
        end
        out
      end

      def reply(sock, text)
        line = String.new
        line << text << "\r\n"
        sock.write(line)
        nil
      end

      # "MAIL FROM:<a@b>" -> "MAIL", uppercased.
      def self.verb_of(line)
        s = line.to_s
        stop = s.byteindex(" ")
        stop = s.bytesize if stop.nil?
        s.byteslice(0, stop).upcase
      end

      # The address between the first "<" and the ">" after it, "" when
      # there is none ("MAIL FROM:<>" is the null sender).
      def self.address_in(line)
        s = line.to_s
        open = s.byteindex("<")
        return "" if open.nil?

        close = s.byteindex(">", open)
        return "" if close.nil?

        s.byteslice(open + 1, close - open - 1)
      end

      # The message lines with dot-stuffing undone (a line starting with
      # ".." loses one dot), each ending in CRLF.
      def self.unstuff(payload)
        s = payload.to_s
        out = String.new
        pos = 0
        total = s.bytesize
        while pos < total
          eol = s.byteindex("\r\n", pos)
          eol = total if eol.nil?
          from = pos
          from += 1 if s.byteslice(pos, 2) == ".."
          out << s.byteslice(from, eol - from) << "\r\n"
          pos = eol + 2
        end
        out
      end
    end
  end
end
