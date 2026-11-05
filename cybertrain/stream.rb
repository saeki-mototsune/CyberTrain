require "json"
require "base64"
require "cybertrain/http/query"
require "cybertrain/logger"
require "cybertrain/cast"
require "cybertrain/config"
require "cybertrain/crypto"
require "cybertrain/db"
require "cybertrain/html"
require "cybertrain/model"
require "cybertrain/views"
require "cybertrain/turbo"
require "cybertrain/stream/hub"

module Cybertrain
  # Cybertrain::Stream -- the pub/sub behind the realtime endpoint
  # (docs/design.md D37). A broadcast is a row in the application's own
  # SQLite database, in the `cybertrain_messages` table the framework creates
  # itself (`CREATE TABLE IF NOT EXISTS`) and leaves out of `db/schema.rb`;
  # every web process polls the table ({Stream::Poller}, every
  # {Config#stream_poll_ms} ms) and hands new rows to the browsers
  # subscribed to their stream through {Stream::Endpoint} (Server-Sent
  # Events or a WebSocket). So a broadcast from a job, a scheduled task, a
  # feed callback or another process reaches every page, in one order.
  #
  #   # in an action, a job or a Main.command:
  #   Cybertrain::Stream.broadcast_append_to("alerts", target: "alerts", html: Cybertrain::Html.safe("<li>Hi</li>"))
  #
  #   <%# in a template: subscribes this page (Turbo picks the messages up) %>
  #   <%= turbo_stream_from "alerts" %>
  #
  # A page may read a stream only when it was rendered with a signed token
  # naming it ({Stream.sign}, what `turbo_stream_from` writes): the endpoint
  # checks the signature, never the session (as Turbo's signed stream
  # names). A per-user stream is `Stream.name_for(current_user)`, rendered
  # only on that user's pages.
  # @api public
  module Stream
    TABLE = "cybertrain_messages"

    TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_messages (" \
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
                "stream TEXT NOT NULL, " \
                "payload TEXT NOT NULL, " \
                "created_at INTEGER NOT NULL); " \
                "CREATE INDEX IF NOT EXISTS index_cybertrain_messages_on_stream_and_id " \
                "ON cybertrain_messages (stream, id);"

    # A stream name is 1..MAX_NAME_BYTES bytes, with no control character
    # and no comma (the separator inside a token).
    MAX_NAME_BYTES = 200
    # The most names one token may carry.
    MAX_NAMES = 16
    # The hex HMAC-SHA256 at the end of a token, and its "--" before it.
    SIGNATURE_LENGTH = 64

    # The DB.generation the table was last ensured for; -1 for never.
    @installed_generation = -1
    # The process's hub: made on first use with Config#stream_max_backlog.
    @hub = nil

    # Adds a message to `name`: one row, delivered to every subscriber of
    # the stream (in this process and every other one polling the same
    # database) within about {Config#stream_poll_ms}. Inside a
    # {DB.transaction} the message is sent only if the transaction commits.
    # @param name [String] the stream ({Stream.name_for} for a record)
    # @param payload [String] what the subscribers receive: Turbo Stream
    #   HTML, JSON or any text
    # @return [Integer] the message id
    # @raise [ArgumentError] for an invalid stream name
    # @api public
    def self.broadcast(name, payload)
      stream = name.to_s
      raise ArgumentError, "Stream.broadcast: invalid stream name #{stream.inspect}" unless Stream.valid_name?(stream)

      ensure_installed
      binds = Cast.binds(stream, payload.to_s, Time.now.to_i)
      id = 0
      DB.with do |c|
        c.execute("INSERT INTO cybertrain_messages (stream, payload, created_at) VALUES (?, ?, ?)", binds)
        id = c.last_insert_id
      end
      id
    end

    # The stream name of a record, `"articles:12"` (its table and id); a
    # String is returned as it is.
    # @param record_or_string [Model, String]
    # @return [String]
    # @api public
    def self.name_for(record_or_string)
      case record_or_string
      when Cybertrain::Model
        raise ArgumentError, "Stream.name_for: the record is not saved (it has no id)" if record_or_string.id.to_i == 0

        table = record_or_string.class.table_name
        id = record_or_string.id.to_s
        "#{table}:#{id}"
      else
        record_or_string.to_s
      end
    end

    # A token naming `names`: base64url of the names joined by ",", then
    # "--", then the hex HMAC-SHA256 of that text keyed with
    # {Config#secret_key_base}. Tokens do not expire; changing the secret
    # invalidates all of them.
    # @param names [Array<String>]
    # @return [String]
    # @raise [ArgumentError] for no names, more than {MAX_NAMES}, or an
    #   invalid name
    # @api public
    def self.sign(names)
      raise ArgumentError, "Stream.sign: no stream names" if names.empty?
      raise ArgumentError, "Stream.sign: more than #{MAX_NAMES} stream names" if names.size > MAX_NAMES

      i = 0
      while i < names.size
        name = names[i].to_s
        raise ArgumentError, "Stream.sign: invalid stream name #{name.inspect}" unless Stream.valid_name?(name)

        i += 1
      end
      joined = names.join(",")
      encoded = Base64.urlsafe_encode64(joined, padding: false)
      signature = Crypto.hmac_hex(Stream.secret, encoded)
      out = +""
      out << encoded
      out << "--"
      out << signature
      out
    end

    # The names a token carries, or nil when its signature is wrong or
    # missing, or a name in it is invalid.
    # @param token [String]
    # @return [Array<String>, nil]
    # @api public
    def self.verify(token)
      names = Stream.verified_names(token)
      return nil if names.empty?

      names
    end

    # Stream.verify as a typed Array: empty when the token does not verify.
    def self.verified_names(token)
      none = Array.new(0) { "" }
      text = token.to_s
      len = text.bytesize
      return none if len < SIGNATURE_LENGTH + 3
      return none unless text.byteslice(len - SIGNATURE_LENGTH - 2, 2) == "--"

      encoded = text.byteslice(0, len - SIGNATURE_LENGTH - 2)
      signature = text.byteslice(len - SIGNATURE_LENGTH, SIGNATURE_LENGTH)
      return none unless Stream.base64?(encoded)

      expected = Crypto.hmac_hex(Stream.secret, encoded)
      return none unless Crypto.secure_compare(signature, expected)

      joined = Stream.decode64(encoded)
      return none if joined.empty?

      parts = joined.split(",")
      return none if parts.size > MAX_NAMES

      out = Array.new(0) { "" }
      i = 0
      while i < parts.size
        name = parts[i].to_s
        return none unless Stream.valid_name?(name)

        out << name
        i += 1
      end
      out
    end

    # 1..MAX_NAME_BYTES bytes, valid UTF-8, no control character (bytes
    # 0..31 and 127), no comma.
    # @param name [String]
    # @return [Boolean]
    def self.valid_name?(name)
      s = name.to_s
      n = s.bytesize
      return false if n < 1 || n > MAX_NAME_BYTES
      return false unless Query.utf8!(s).valid_encoding?

      i = 0
      while i < n
        b = s.getbyte(i)
        return false if b < 32 || b == 127 || b == 44

        i += 1
      end
      true
    end

    def self.secret
      Cybertrain.config.resolve_secret!
    end

    # The urlsafe alphabet without padding.
    def self.base64?(text)
      i = 0
      while i < text.bytesize
        b = text.getbyte(i)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 95
        return false unless ok

        i += 1
      end
      true
    end

    # A Sec-WebSocket-Key: the standard base64 of 16 bytes (24 characters,
    # the last two "==").
    def self.base64_key?(text)
      return false unless text.bytesize == 24 && text.end_with?("==")

      i = 0
      while i < 22
        b = text.getbyte(i)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 43 || b == 47
        return false unless ok

        i += 1
      end
      true
    end

    # Pads the text back up (Base64.urlsafe_decode64 is not relied on to
    # accept unpadded input under Spinel, as in Password.decode); "" for
    # text no padding fixes.
    def self.decode64(text)
      padded = text.dup
      padded << "=" while padded.bytesize % 4 != 0
      Base64.urlsafe_decode64(padded)
    rescue ArgumentError
      ""
    end

    # Creates the table and its index if they are missing. {Stream.broadcast}
    # and the poller call it once per connected database.
    # @return [nil]
    # @api public
    def self.install!
      DB.with { |c| c.exec_script(TABLE_SQL) }
      # As Job.install!: a CREATE inside a transaction that rolls back is
      # gone again, so only one outside a transaction is remembered.
      pool = DB.pool
      @installed_generation = DB.generation if !pool.nil? && pool.held_index < 0
      nil
    end

    # install! unless it already ran since the last DB.connect.
    def self.ensure_installed
      install! unless @installed_generation == DB.generation
      nil
    end

    # Deletes the messages created before `before` (epoch seconds); the
    # poller runs it every minute with {Config#stream_retention}.
    # @param before [Integer] epoch seconds
    # @return [Integer] how many rows were deleted
    # @api public
    def self.prune(before)
      ensure_installed
      count = 0
      DB.with do |c|
        c.execute("DELETE FROM cybertrain_messages WHERE created_at < ?", [before])
        count = c.changes
      end
      count
    end

    # The largest message id, 0 for an empty table.
    # @return [Integer]
    def self.max_id
      ensure_installed
      rows = DB.with { |c| c.execute("SELECT MAX(id) AS m FROM cybertrain_messages") }
      return 0 if rows.empty?

      Cast.int(rows[0]["m"])
    end

    # The messages after `after_id`, oldest first, at most `limit`.
    # @return [Array<Message>]
    def self.messages_after(after_id, limit)
      ensure_installed
      rows = DB.with do |c|
        c.execute("SELECT id, stream, payload FROM cybertrain_messages WHERE id > ? ORDER BY id LIMIT ?", [after_id, limit])
      end
      out = Array.new(0) { Message.new(0, "", "") }
      i = 0
      while i < rows.size
        row = rows[i]
        out << Message.new(Cast.int(row["id"]), Cast.str(row["stream"]), Cast.str(row["payload"]))
        i += 1
      end
      out
    end

    # Rows one replay query reads: a connection writes each chunk before
    # it asks for the next, so a long backlog never sits in memory whole.
    REPLAY_CHUNK = 200

    # The messages of `names` still in the table with an id above
    # `after_id`, oldest first, at most `limit` (one chunk): what a
    # reconnecting client missed (`Last-Event-ID`, `?after=`). Filtered in
    # SQL on the (stream, id) index. The endpoint pages through the backlog
    # with it, from the last id it sent, until a chunk comes back short or
    # passes the subscriber's cursor; retention is what bounds it.
    # @param names [Array<String>]
    # @param after_id [Integer]
    # @param limit [Integer]
    # @return [Array<Message>]
    # @api public
    def self.replay(names, after_id, limit = REPLAY_CHUNK)
      out = Array.new(0) { Message.new(0, "", "") }
      return out if names.empty?

      ensure_installed
      marks = +""
      binds = Cast.binds
      i = 0
      while i < names.size
        marks << ", " if i > 0
        marks << "?"
        binds << Cast.to_sql(names[i])
        i += 1
      end
      binds << Cast.to_sql(after_id)
      binds << Cast.to_sql(limit)
      sql = +"SELECT id, stream, payload FROM cybertrain_messages WHERE stream IN ("
      sql << marks
      sql << ") AND id > ? ORDER BY id LIMIT ?"
      rows = DB.with { |c| c.execute(sql, binds) }
      i = 0
      while i < rows.size
        row = rows[i]
        out << Message.new(Cast.int(row["id"]), Cast.str(row["stream"]), Cast.str(row["payload"]))
        i += 1
      end
      out
    end

    # A loop of == rather than include? (spikes/NOTES.md rule 29).
    def self.name_in?(names, name)
      i = 0
      while i < names.size
        return true if names[i] == name

        i += 1
      end
      false
    end

    # Where a replay for a new subscriber starts: the client's `after`
    # (Last-Event-ID, ?after=) clamped to the poller cursor the subscriber
    # took at subscribe (Subscriber#boundary), so an id above the head
    # (another database, a pruned table) still lets the next broadcast
    # through; -1 (no replay) stays -1. The handoff boundary is then
    # max(this, the largest replayed id).
    # @param after [Integer]
    # @param sub [Subscriber]
    # @return [Integer]
    def self.replay_start(after, sub)
      return after if after < 0

      cursor = sub.boundary
      after < cursor ? after : cursor
    end

    # The process's hub ({Hub}), made on first use.
    # @return [Hub]
    def self.hub
      built = @hub
      if built.nil?
        built = Hub.new(Cybertrain.config.stream_max_backlog)
        @hub = built
      end
      built
    end

    # --- Turbo Stream broadcasts (turbo-rails' broadcast_*_to) ------------

    # Renders the content (`html:` as given, escaped unless a SafeString;
    # or `partial:` with `locals:` through {Views.render_partial}; or
    # `component:` through {Views.render_component}), wraps it in a
    # `<turbo-stream action="replace">` for `target` ({Turbo.replace}) and
    # broadcasts it to `stream` (a name or a record, {Stream.name_for}).
    # @example
    #   Cybertrain::Stream.broadcast_replace_to(article, target: article, partial: "articles/article", locals: { article: article })
    # @return [Integer] the message id
    # @api public
    def self.broadcast_replace_to(stream, target:, html: "", partial: "", locals: {}, component: nil)
      content = Stream.render_content(html, partial, locals, component)
      Stream.broadcast(Stream.name_for(stream), Turbo.replace(target, content).to_s)
    end

    # As {.broadcast_replace_to}, with `action="update"`.
    # @api public
    def self.broadcast_update_to(stream, target:, html: "", partial: "", locals: {}, component: nil)
      content = Stream.render_content(html, partial, locals, component)
      Stream.broadcast(Stream.name_for(stream), Turbo.update(target, content).to_s)
    end

    # As {.broadcast_replace_to}, with `action="append"`.
    # @api public
    def self.broadcast_append_to(stream, target:, html: "", partial: "", locals: {}, component: nil)
      content = Stream.render_content(html, partial, locals, component)
      Stream.broadcast(Stream.name_for(stream), Turbo.append(target, content).to_s)
    end

    # As {.broadcast_replace_to}, with `action="prepend"`.
    # @api public
    def self.broadcast_prepend_to(stream, target:, html: "", partial: "", locals: {}, component: nil)
      content = Stream.render_content(html, partial, locals, component)
      Stream.broadcast(Stream.name_for(stream), Turbo.prepend(target, content).to_s)
    end

    # As {.broadcast_replace_to}, with `action="before"`.
    # @api public
    def self.broadcast_before_to(stream, target:, html: "", partial: "", locals: {}, component: nil)
      content = Stream.render_content(html, partial, locals, component)
      Stream.broadcast(Stream.name_for(stream), Turbo.before(target, content).to_s)
    end

    # As {.broadcast_replace_to}, with `action="after"`.
    # @api public
    def self.broadcast_after_to(stream, target:, html: "", partial: "", locals: {}, component: nil)
      content = Stream.render_content(html, partial, locals, component)
      Stream.broadcast(Stream.name_for(stream), Turbo.after(target, content).to_s)
    end

    # `<turbo-stream action="remove" target="...">` to `stream`.
    # @return [Integer] the message id
    # @api public
    def self.broadcast_remove_to(stream, target:)
      Stream.broadcast(Stream.name_for(stream), Turbo.remove(target).to_s)
    end

    # `<turbo-stream action="refresh">` to `stream`: the pages reload
    # themselves (Turbo 8's morphing refresh).
    # @return [Integer] the message id
    # @api public
    def self.broadcast_refresh_to(stream)
      Stream.broadcast(Stream.name_for(stream), Turbo.refresh.to_s)
    end

    # The HTML a broadcast_*_to sends: a component, else a partial, else
    # `html` (escaped unless it is a SafeString).
    def self.render_content(html, partial, locals, component)
      unless component.nil?
        rendered = Views.render_component(component)
        return SafeString.of(rendered)
      end
      unless partial.empty?
        rendered = Views.render_partial(partial, locals)
        return SafeString.of(rendered)
      end
      text = Html.out(html)
      SafeString.of(text)
    end
  end
end

require "cybertrain/stream/poller"
