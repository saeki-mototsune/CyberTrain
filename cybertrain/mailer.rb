# Cybertrain::Mailer -- plain-text e-mail through an SMTP server, with every
# wait bounded.
#
# Built on the same socket layer as the outbound HTTP client
# (cybertrain/net/socket.rb): a non-blocking connect, reads through a byte
# buffer fed by read_nonblock, bounded writes, and each wait limited by a
# per-wait timeout and by the delivery's overall deadline. A stalled SMTP
# server therefore never holds an OS worker (with the default
# SPINEL_WORKERS=1, the whole web server).
#
# The dialogue is RFC 5321's, the minimal client: the 220 greeting, EHLO,
# STARTTLS (the default mode, port 587) and EHLO again, AUTH PLAIN when a
# user is configured, MAIL FROM, one RCPT TO per recipient, DATA (CRLF line
# endings, dot-stuffed, ended by "."), QUIT. Implicit TLS (port 465) wraps
# the connection before the greeting; plain text (port 25) sends no
# credentials to anything but a loopback address. No pipelining, no
# SMTPUTF8 (addresses are ASCII), no AUTH LOGIN or CRAM-MD5.
#
# TLS needs `require "cybertrain/net/tls"` (Spinel's openssl package); this
# file does not require it, like cybertrain/http_client.rb.
#
# The password is never part of an error message, a log line or the boot
# banner; the only place it travels is the AUTH PLAIN command, over TLS
# (or to a loopback address).
require "base64"
require "cybertrain/config"
require "cybertrain/net/socket"

module Cybertrain
  # Sends plain-text e-mail through an SMTP server.
  # @example config from the environment (CYBERTRAIN_SMTP_HOST, ...)
  #   require "cybertrain/mailer"
  #   require "cybertrain/net/tls"
  #
  #   begin
  #     Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
  #   rescue Cybertrain::Mailer::Error => e
  #     Cybertrain.logger.warn("mail: #{e.message}") # never contains the password
  #   end
  # @example explicit settings
  #   mailer = Cybertrain::Mailer.new(host: "smtp.example.com", user: "app", password: ENV["SMTP_PASSWORD"].to_s,
  #                                   from: "noreply@example.com")
  #   mailer.deliver(to: "a@example.com, b@example.com", subject: "Report", body: text)
  # @api public
  class Mailer
    # The base of every error a delivery raises. Messages name the server
    # (host:port) and the step, never the password.
    # @api public
    class Error < StandardError
    end

    # Connecting, a TLS step, a read or a write took longer than `timeout`,
    # or the whole delivery longer than `deadline`.
    # @api public
    class TimeoutError < Error
    end

    # The connection could not be made (refused, unreachable, the host name
    # did not resolve) or was reset.
    # @api public
    class ConnectError < Error
    end

    # TLS was needed and failed: the handshake (including a certificate that
    # does not verify), a server that does not offer STARTTLS, or the TLS
    # layer not being required (`require "cybertrain/net/tls"`).
    # @api public
    class TLSError < Error
    end

    # The server's replies are not SMTP, are too long, or the connection
    # closed in the middle of the dialogue.
    # @api public
    class ProtocolError < Error
    end

    # Credentials would travel in plain text: `tls: "none"` with a user, to
    # an address that is not loopback. Raised before anything is sent.
    # @api public
    class InsecureError < Error
    end

    # The server answered a step with a code other than the one that step
    # needs (a 4xx or 5xx): a greeting of 421, a 535 to AUTH, a 550 to RCPT.
    # @api public
    class RejectedError < Error
      # The SMTP reply code, e.g. 550.
      # @return [Integer]
      # @api public
      attr_reader :smtp_code

      def initialize(message, code)
        super(message)
        @smtp_code = code
      end
    end

    # A server reply: its code and the text of each line (code and
    # separator removed). Internal.
    class SmtpReply
      attr_reader :reply_code, :reply_lines

      def initialize(code, lines)
        @reply_code = code
        @reply_lines = lines
      end

      # "550 5.1.1 no such user", the lines joined with " / ", at most
      # MAX_REPLY_SHOWN bytes and printable ASCII only (a reply goes into an
      # error message, which goes into a log).
      def reply_summary
        text = String.new
        text << @reply_code.to_s
        i = 0
        while i < @reply_lines.size
          text << (i == 0 ? " " : " / ")
          text << @reply_lines[i]
          i += 1
        end
        Mailer.printable(text, MAX_REPLY_SHOWN)
      end
    end

    # One connection's state: the stream (plain, then TLS after STARTTLS)
    # and the reader buffering it. Internal.
    class SmtpSession
      def initialize(stream, timer, label)
        @stream = stream
        @timer = timer
        @session_label = label
        @reader = Net::Reader.new(stream, timer)
      end

      def session_label
        @session_label
      end

      # Continues on `stream` (TLS over the same connection).
      def switch_stream(stream)
        @stream = stream
        @reader = Net::Reader.new(stream, @timer)
        nil
      end

      # Bytes the server sent that no reply has consumed yet.
      def pending_bytes
        @reader.buffered
      end

      def send_command(line)
        wire = String.new
        wire << line
        wire << "\r\n"
        @stream.stream_write(wire, @timer)
        nil
      end

      def send_data(data)
        @stream.stream_write(data, @timer)
        nil
      end

      # One reply, all its lines. Raises Net::ProtocolError for a line that
      # does not start with a code, or a multi-line reply that changes it.
      # @return [SmtpReply]
      def read_reply
        lines = Array.new(0) { "" }
        code = -1
        while true
          line = @reader.read_line(MAX_REPLY_LINE_BYTES)
          s = line.to_s # NOTES rule 62
          n = s.bytesize
          raise Net::ProtocolError, "#{@session_label}: the server's reply is not SMTP" unless Mailer.reply_line?(s)

          this_code = (s.getbyte(0) - 48) * 100 + (s.getbyte(1) - 48) * 10 + (s.getbyte(2) - 48)
          raise Net::ProtocolError, "#{@session_label}: a multi-line reply changed its code" if code >= 0 && this_code != code

          code = this_code
          text = n > 4 ? s.byteslice(4, n - 4) : ""
          lines << text
          raise Net::LimitError, "#{@session_label}: a reply of more than #{MAX_REPLY_LINES} lines" if lines.size > MAX_REPLY_LINES
          return SmtpReply.new(code, lines) if n == 3 || s.getbyte(3) == 32
        end
        SmtpReply.new(code, lines)
      end

      def close_session
        @stream.stream_close
        nil
      end
    end

    # RFC 5321 allows 512 bytes; servers send longer EHLO lines.
    MAX_REPLY_LINE_BYTES = 4096
    MAX_REPLY_LINES = 100
    MAX_REPLY_SHOWN = 300
    MAX_RECIPIENTS = 100
    # RFC 5321 4.5.3.1: 64 for the local part, 254 in all (a path is 256
    # with its angle brackets).
    MAX_LOCAL_PART_BYTES = 64
    MAX_ADDRESS_BYTES = 254
    MAX_SUBJECT_BYTES = 998
    # A line of a message may be 998 bytes before its CRLF (RFC 5322 2.1.1).
    MAX_LINE_BYTES = 998
    # Raw bytes per RFC 2047 encoded word: 60 base64 characters, a word of
    # 72 with its "=?UTF-8?B?" and "?=".
    ENCODED_WORD_BYTES = 45

    # @return [String] the SMTP server
    # @api public
    attr_reader :mail_host
    # @return [Integer] its port
    # @api public
    attr_reader :mail_port
    # @return [String] the AUTH user, "" for none
    # @api public
    attr_reader :mail_user
    # @return [String] the default sender address
    # @api public
    attr_reader :mail_from
    # @return [String] "starttls", "tls" or "none"
    # @api public
    attr_reader :mail_tls
    # @return [Float] seconds any one wait may take
    # @api public
    attr_reader :mail_timeout
    # @return [Float] seconds a whole delivery may take
    # @api public
    attr_reader :mail_deadline

    # The port a mode uses when none is configured: 587 (submission) for
    # starttls, 465 (submissions) for tls, 25 for none.
    # @param tls [String]
    # @return [Integer]
    # @api public
    def self.default_port(tls)
      return 465 if tls == "tls"
      return 25 if tls == "none"

      587
    end

    # Each setting defaults to {Config}'s (`smtp_host`, `smtp_port`, ...,
    # from the CYBERTRAIN_SMTP_* environment variables).
    # @param host [String] the SMTP server's name (or an IP address; TLS
    #   checks the certificate against this name, so give a name for TLS)
    # @param port [Integer] 0 for the mode's port ({.default_port})
    # @param user [String] the AUTH PLAIN user; "" sends no AUTH
    # @param password [String] never logged or shown
    # @param from [String] the sender address {#deliver} uses by default
    # @param tls [String] "starttls" (the default), "tls" (implicit TLS) or
    #   "none" (plain text; refuses to send credentials except to loopback)
    # @param timeout [Numeric] seconds for each wait. Default 10.
    # @param deadline [Numeric] seconds for a whole delivery, name
    #   resolution included. Default 60.
    # @param helo [String] the name sent with EHLO. Default "localhost".
    # @raise [ArgumentError] an empty host, an unknown mode, a port out of
    #   range, a timeout that is not positive
    # @api public
    def initialize(host: Cybertrain.config.smtp_host, port: Cybertrain.config.smtp_port,
                   user: Cybertrain.config.smtp_user, password: Cybertrain.config.smtp_password,
                   from: Cybertrain.config.smtp_from, tls: Cybertrain.config.smtp_tls,
                   timeout: 10, deadline: 60, helo: "localhost")
      @mail_host = host.to_s.downcase
      @mail_tls = tls.to_s.downcase
      @mail_user = user.to_s
      @password = password.to_s
      @mail_from = from.to_s
      @mail_timeout = timeout.to_f
      @mail_deadline = deadline.to_f
      @helo_name = helo.to_s
      raise ArgumentError, "no SMTP host: set CYBERTRAIN_SMTP_HOST (Config#smtp_host) or pass host:" if @mail_host.empty?
      raise ArgumentError, "the SMTP host name is malformed" unless Mailer.host_name?(@mail_host)
      unless @mail_tls == "starttls" || @mail_tls == "tls" || @mail_tls == "none"
        raise ArgumentError, "tls must be \"starttls\", \"tls\" or \"none\""
      end
      raise ArgumentError, "the EHLO name is malformed" unless Mailer.host_name?(@helo_name)

      configured_port = port.to_i
      raise ArgumentError, "the SMTP port must be from 1 to 65535 (0 for the mode's)" if configured_port < 0 || configured_port > 65_535

      @mail_port = configured_port == 0 ? Mailer.default_port(@mail_tls) : configured_port
      raise ArgumentError, "timeout must be positive" unless @mail_timeout > 0.0
      raise ArgumentError, "deadline must be positive" unless @mail_deadline > 0.0
    end

    # Sends one message with the settings in {Config} (`Mailer.new`'s
    # defaults).
    # @param to [String] one address, or several separated by commas
    # @param subject [String] UTF-8; non-ASCII is RFC 2047-encoded
    # @param body [String] UTF-8 plain text, any line endings
    # @param from [String] the sender; "" for Config#smtp_from
    # @return [String] the server's reply to the message ("250 2.0.0 Ok:
    #   queued as ...")
    # @raise [Error] a subclass; ArgumentError for an address, subject or body refused
    # @api public
    def self.deliver(to:, subject:, body:, from: "")
      Mailer.new.deliver(to: to, subject: subject, body: body, from: from)
    end

    # Sends one message.
    # @param to [String] one address, or several separated by commas
    # @param subject [String] UTF-8; non-ASCII is RFC 2047-encoded
    # @param body [String] UTF-8 plain text, any line endings
    # @param from [String] the sender; "" for the mailer's `from:`
    # @return [String] the server's reply to the message
    # @raise [Error] a subclass; ArgumentError for an address, subject or body refused
    # @api public
    def deliver(to:, subject:, body:, from: "")
      given = from.to_s
      sender = given.empty? ? @mail_from : given
      Mailer.check_address(sender, "from")
      recipients = Mailer.split_recipients(to.to_s)
      title = subject.to_s
      Mailer.check_subject(title)
      text = Mailer.normalize_body(body.to_s)
      perform(sender, recipients, title, text)
    end

    # The Net errors translated into the Mailer's, in a method that takes no
    # block (NOTES rules 32, 45), told apart by rescue clause (rule 47).
    def perform(sender, recipients, title, text)
      begin
        exchange(sender, recipients, title, text)
      rescue Net::TimeoutError => e
        raise TimeoutError, e.message
      rescue Net::TlsError => e
        raise TLSError, e.message
      rescue Net::ConnectError => e
        raise ConnectError, e.message
      rescue Net::LimitError => e
        raise ProtocolError, e.message
      rescue Net::ProtocolError => e
        raise ProtocolError, e.message
      end
    end

    # "smtp.example.com:587", what error messages name.
    def mail_label
      @mail_host.include?(":") ? "[#{@mail_host}]:#{@mail_port}" : "#{@mail_host}:#{@mail_port}"
    end

    def exchange(sender, recipients, title, text)
      label = mail_label
      if @mail_tls != "none" && !Net.tls_connector.tls_ready?
        raise Net::TlsError, "#{label}: tls \"#{@mail_tls}\" needs the TLS layer: require \"cybertrain/net/tls\" (Spinel's openssl package)"
      end

      timer = Net::Timer.new(label, @mail_timeout, @mail_deadline)
      endpoint = Net.resolve(@mail_host, @mail_port, label)
      timer.wait_limit("resolving the host name") # the deadline, after the blocking lookup
      if @mail_tls == "none" && !@mail_user.empty? && Net::Address.blocked_reason(endpoint.endpoint_ip) != "loopback"
        refusal = "#{label}: refusing to send credentials in plain text to #{endpoint.endpoint_ip}; " \
                  "use tls \"starttls\" or \"tls\" (tls \"none\" authenticates to loopback only)"
        raise InsecureError, refusal
      end

      tcp = Net::TcpStream.connect_to(endpoint, @mail_port, label, timer)
      # Bound to a local before SmtpSession.new gets it (NOTES rule 58).
      first_stream = Mailer.open_stream(tcp, @mail_host, timer, @mail_tls == "tls")
      session = SmtpSession.new(first_stream, timer, label)
      begin
        converse(session, tcp, timer, sender, recipients, title, text)
      ensure
        session.close_session
      end
    end

    # The plain stream, or TLS over it.
    def self.open_stream(tcp, host, timer, wrap)
      return tcp unless wrap

      Net.tls_connector.tls_wrap(tcp, host, timer)
    end

    def converse(session, tcp, timer, sender, recipients, title, text)
      Mailer.expect(session, session.read_reply, 220, "the greeting")
      caps = ehlo(session)
      if @mail_tls == "starttls"
        unless Mailer.capability?(caps, "STARTTLS")
          raise Net::TlsError, "#{session.session_label}: the server does not offer STARTTLS; use tls \"tls\" (port 465) or \"none\""
        end

        session.send_command("STARTTLS")
        Mailer.expect(session, session.read_reply, 220, "STARTTLS")
        # Bytes after the 220 arrived in plain text and would be read as if
        # they had come over TLS (the STARTTLS command injection of
        # CVE-2011-0411's kind): refuse them.
        if session.pending_bytes > 0
          raise Net::ProtocolError, "#{session.session_label}: the server sent data after its STARTTLS reply"
        end

        session.switch_stream(Mailer.open_stream(tcp, @mail_host, timer, true))
        caps = ehlo(session)
      end
      authenticate(session, caps) unless @mail_user.empty?
      eight_bit = Mailer.capability?(caps, "8BITMIME")
      encoding = Mailer.body_encoding(text, eight_bit)
      mail_from = String.new
      mail_from << "MAIL FROM:<" << sender << ">"
      mail_from << " BODY=8BITMIME" if encoding == "8bit"
      session.send_command(mail_from)
      Mailer.expect(session, session.read_reply, 250, "MAIL FROM")
      i = 0
      while i < recipients.size
        rcpt = String.new
        rcpt << "RCPT TO:<" << recipients[i] << ">"
        session.send_command(rcpt)
        reply = session.read_reply
        Mailer.expect(session, reply, 250, "RCPT TO <#{recipients[i]}>") unless reply.reply_code == 251
        i += 1
      end
      session.send_command("DATA")
      Mailer.expect(session, session.read_reply, 354, "DATA")
      message = Mailer.build_message(sender, recipients, title, text, Mailer.date_header(Time.now), encoding)
      session.send_data(Mailer.dot_stuff(message))
      accepted = session.read_reply
      Mailer.expect(session, accepted, 250, "the message")
      Mailer.quit_quietly(session)
      accepted.reply_summary
    end

    # EHLO, and the capability lines of its reply (the first line is the
    # server's name), uppercased.
    def ehlo(session)
      command = String.new
      command << "EHLO " << @helo_name
      session.send_command(command)
      reply = session.read_reply
      Mailer.expect(session, reply, 250, "EHLO")
      caps = Array.new(0) { "" }
      i = 1
      while i < reply.reply_lines.size
        caps << reply.reply_lines[i].upcase
        i += 1
      end
      caps
    end

    # AUTH PLAIN with the initial response (RFC 4616): base64 of
    # "\0user\0password". Built with <<, never interpolated: a NUL cuts an
    # interpolated String under Spinel (NOTES rule 60).
    def authenticate(session, caps)
      unless Mailer.auth_plain?(caps)
        raise Net::ProtocolError, "#{session.session_label}: the server does not offer AUTH PLAIN"
      end

      raw = String.new
      raw << "\0" << @mail_user << "\0" << @password
      command = String.new
      command << "AUTH PLAIN " << Base64.strict_encode64(raw)
      session.send_command(command)
      Mailer.expect(session, session.read_reply, 235, "AUTH (authentication)")
      nil
    end

    # QUIT, and its 221 if it comes; the message is already accepted, so a
    # failure here is not one of the delivery's.
    def self.quit_quietly(session)
      session.send_command("QUIT")
      session.read_reply
      nil
    rescue Net::Error
      nil
    end

    # Raises RejectedError unless the reply has the code the step needs.
    def self.expect(session, reply, code, step)
      return nil if reply.reply_code == code

      text = "#{session.session_label}: #{step} rejected: #{reply.reply_summary}"
      raise RejectedError.new(text, reply.reply_code)
    end

    # "NNN", "NNN text" or "NNN-text" with NNN from 200 to 599.
    def self.reply_line?(line)
      s = line.to_s # NOTES rule 62
      n = s.bytesize
      return false if n < 3

      i = 0
      while i < 3
        b = s.getbyte(i)
        return false if b < 48 || b > 57

        i += 1
      end
      first = s.getbyte(0)
      return false if first < 50 || first > 53
      return true if n == 3

      sep = s.getbyte(3)
      sep == 32 || sep == 45
    end

    # Whether an EHLO capability line starts with `keyword`.
    def self.capability?(caps, keyword)
      i = 0
      while i < caps.size
        line = caps[i]
        return true if line == keyword || line.start_with?("#{keyword} ")

        i += 1
      end
      false
    end

    # Whether "AUTH ..." (or the old "AUTH=...") lists PLAIN.
    def self.auth_plain?(caps)
      i = 0
      while i < caps.size
        line = caps[i]
        if line.start_with?("AUTH ") || line.start_with?("AUTH=")
          words = line.byteslice(5, line.bytesize - 5).split(" ")
          j = 0
          while j < words.size
            return true if words[j] == "PLAIN"

            j += 1
          end
        end
        i += 1
      end
      false
    end

    # ---- addresses ----------------------------------------------------------

    # Raises ArgumentError unless `address` is a bare ASCII address
    # (local@domain): no display name, angle brackets, spaces, CR or LF,
    # commas, quotes or other characters that could end the SMTP command or
    # the header it goes into. The message never repeats the address (a
    # header-injection attempt is a CRLF and a header).
    def self.check_address(address, field)
      problem = Mailer.address_problem(address)
      raise ArgumentError, "the #{field} address #{problem}" unless problem.empty?

      nil
    end

    # "" when the address is acceptable, else why not.
    def self.address_problem(address)
      s = address.to_s # NOTES rule 62
      n = s.bytesize
      return "is empty" if n == 0
      return "is longer than #{MAX_ADDRESS_BYTES} bytes" if n > MAX_ADDRESS_BYTES

      at = -1
      i = 0
      while i < n
        b = s.getbyte(i)
        return "contains CR or LF" if b == 13 || b == 10
        return "contains a space, a control character or a non-ASCII byte" if b <= 32 || b >= 127
        return "contains a character not allowed in a bare address (<>()[],;:\\\")" if Mailer.special_byte?(b)

        if b == 64
          return "contains more than one @" if at >= 0

          at = i
        end
        i += 1
      end
      return "has no @" if at < 0
      return "has an empty local part" if at == 0
      return "has an empty domain" if at == n - 1
      return "has a local part longer than #{MAX_LOCAL_PART_BYTES} bytes" if at > MAX_LOCAL_PART_BYTES

      ""
    end

    # RFC 5322 specials other than "@" and ".".
    def self.special_byte?(b)
      b == 60 || b == 62 || b == 40 || b == 41 || b == 91 || b == 93 || b == 44 || b == 59 || b == 58 || b == 92 || b == 34
    end

    # "a@x, b@y" into its addresses, each checked; at least one, at most
    # MAX_RECIPIENTS.
    # @return [Array<String>]
    def self.split_recipients(to)
      list = Array.new(0) { "" }
      parts = to.to_s.split(",")
      i = 0
      while i < parts.size
        address = parts[i].strip
        unless address.empty?
          Mailer.check_address(address, "to")
          list << address
        end
        i += 1
      end
      raise ArgumentError, "no recipient (to: is empty)" if list.empty?
      raise ArgumentError, "more than #{MAX_RECIPIENTS} recipients" if list.size > MAX_RECIPIENTS

      list
    end

    # A host name or IPv4 literal: letters, digits, "-", ".", "_"; or an
    # IPv6 literal (hex digits, ":", ".").
    def self.host_name?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return false if n == 0 || n > 253

      i = 0
      while i < n
        b = s.getbyte(i)
        ok = (b >= 48 && b <= 58) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95
        return false unless ok

        i += 1
      end
      true
    end

    # ---- the message ----------------------------------------------------------

    # Raises ArgumentError for a subject with CR, LF or NUL (header
    # injection), invalid UTF-8, or more than MAX_SUBJECT_BYTES bytes.
    def self.check_subject(subject)
      s = subject.to_s # NOTES rule 62
      raise ArgumentError, "the subject is longer than #{MAX_SUBJECT_BYTES} bytes" if s.bytesize > MAX_SUBJECT_BYTES

      i = 0
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        raise ArgumentError, "the subject contains CR, LF or NUL" if b == 13 || b == 10 || b == 0
        i += 1
      end
      raise ArgumentError, "the subject is not valid UTF-8" unless Mailer.utf8?(s)

      nil
    end

    # Valid UTF-8 whatever the String's tag (a binary String under CRuby is
    # checked as UTF-8 too; NOTES rule 52).
    def self.utf8?(text)
      s = text.to_s
      u = s.encoding.to_s == "UTF-8" ? s : s.dup.force_encoding("UTF-8")
      u.valid_encoding?
    end

    # The body with every line ending (CRLF, LF, a lone CR) made CRLF, and
    # a final CRLF. Raises ArgumentError for invalid UTF-8 or a NUL byte.
    def self.normalize_body(body)
      s = body.to_s # NOTES rule 62
      raise ArgumentError, "the body is not valid UTF-8" unless Mailer.utf8?(s)

      out = String.new
      n = s.bytesize
      start = 0
      i = 0
      while i < n
        b = s.getbyte(i)
        raise ArgumentError, "the body contains a NUL byte" if b == 0

        if b == 13 || b == 10
          out << s.byteslice(start, i - start) if i > start
          out << "\r\n"
          i += 1 if b == 13 && i + 1 < n && s.getbyte(i + 1) == 10
          start = i + 1
        end
        i += 1
      end
      out << s.byteslice(start, n - start) if n > start
      out << "\r\n" unless out.end_with?("\r\n")
      out
    end

    # "7bit" for ASCII lines of at most MAX_LINE_BYTES, "8bit" for UTF-8
    # ones when the server advertises 8BITMIME, else "base64".
    def self.body_encoding(text, eight_bit_ok)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      ascii = true
      line = 0
      i = 0
      while i < n
        b = s.getbyte(i)
        if b == 10
          line = 0
        elsif b != 13
          line += 1
          return "base64" if line > MAX_LINE_BYTES

          ascii = false if b >= 128
        end
        i += 1
      end
      return "7bit" if ascii
      return "8bit" if eight_bit_ok

      "base64"
    end

    # "Sun, 25 Oct 2026 09:05:00 +0000" (RFC 5322 3.3), in UTC.
    def self.date_header(time)
      time.getutc.strftime("%a, %d %b %Y %H:%M:%S +0000")
    end

    # The whole message: headers, a blank line and the body, every line
    # ending CRLF (not yet dot-stuffed). `text` is normalize_body's.
    # @return [String]
    def self.build_message(sender, recipients, subject, text, date, encoding)
      to_header = Mailer.to_header(recipients)
      subject_header = Mailer.subject_header(subject)
      body = encoding == "base64" ? Mailer.base64_lines(text) : text
      out = String.new
      out << "Date: " << date << "\r\n"
      out << "From: " << sender << "\r\n"
      out << to_header
      out << subject_header
      out << "MIME-Version: 1.0\r\n"
      out << "Content-Type: text/plain; charset=UTF-8\r\n"
      out << "Content-Transfer-Encoding: " << encoding << "\r\n"
      out << "\r\n"
      out << body
      out
    end

    # "To: a@x, b@y\r\n", folded before an address that would take the
    # line past 78 characters.
    def self.to_header(recipients)
      out = String.new
      out << "To: "
      width = 4
      i = 0
      while i < recipients.size
        address = recipients[i]
        if i > 0
          if width + 2 + address.bytesize > 78
            out << ",\r\n "
            width = 1
          else
            out << ", "
            width += 2
          end
        end
        out << address
        width += address.bytesize
        i += 1
      end
      out << "\r\n"
      out
    end

    # "Subject: text\r\n": the text as it is when it is printable ASCII
    # without "=?", else RFC 2047 B-encoded words of at most
    # ENCODED_WORD_BYTES bytes each, split between UTF-8 characters, one per
    # folded line.
    def self.subject_header(subject)
      s = subject.to_s # NOTES rule 62
      out = String.new
      out << "Subject: "
      if Mailer.plain_subject?(s)
        out << s
        out << "\r\n"
        return out
      end
      n = s.bytesize
      start = 0
      first = true
      while start < n
        stop = start + ENCODED_WORD_BYTES
        if stop >= n
          stop = n
        else
          # Back off continuation bytes (10xxxxxx): never split a character.
          stop -= 1 while stop > start && (s.getbyte(stop) & 0xC0) == 0x80
        end
        piece = s.byteslice(start, stop - start)
        out << "\r\n " unless first
        out << "=?UTF-8?B?" << Base64.strict_encode64(piece) << "?="
        first = false
        start = stop
      end
      out << "\r\n"
      out
    end

    # Printable ASCII (and tab), no "=?", short enough for one line.
    def self.plain_subject?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return false if n > 900
      return false unless s.index("=?").nil?

      i = 0
      while i < n
        b = s.getbyte(i)
        return false if (b < 32 && b != 9) || b >= 127

        i += 1
      end
      true
    end

    # The body in base64, 76 characters a line (RFC 2045 6.8).
    def self.base64_lines(text)
      encoded = Base64.strict_encode64(text.to_s)
      out = String.new
      n = encoded.bytesize
      i = 0
      while i < n
        size = n - i
        size = 76 if size > 76
        out << encoded.byteslice(i, size)
        out << "\r\n"
        i += size
      end
      out
    end

    # The DATA payload: a "." doubled at the start of every line (RFC 5321
    # 4.5.2) and the terminating ".\r\n". `message` ends with CRLF.
    def self.dot_stuff(message)
      s = message.to_s # NOTES rule 62
      out = String.new
      n = s.bytesize
      start = 0
      while start < n
        out << "." if s.getbyte(start) == 46
        newline = s.byteindex("\n", start)
        stop = newline.nil? ? n : newline + 1
        out << s.byteslice(start, stop - start)
        start = stop
      end
      out << ".\r\n"
      out
    end

    # `text` with every byte that is not printable ASCII as "?", cut to
    # `max` bytes.
    def self.printable(text, max)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      n = max if n > max
      out = String.new
      i = 0
      while i < n
        b = s.getbyte(i)
        if b >= 32 && b < 127
          out << s.byteslice(i, 1)
        else
          out << "?"
        end
        i += 1
      end
      out
    end
  end
end
