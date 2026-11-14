# What several of the blog's test classes read: the token of a page's
# form, the jobs table's rows, the session a cookie carries, the
# statements run, a page's Turbo stream token and the last broadcast.
# Required by test/test_helper.rb; every test starts from the fixtures
# (test/fixtures/*.yml), with the jobs, cache and messages tables empty.
module BlogTestHelper
  # The authenticity_token of the first form in body, as a browser would
  # submit it back.
  def self.form_token(body)
    marker = "name=\"authenticity_token\" value=\""
    at = body.index(marker)
    raise "no authenticity_token in the page" if at.nil?

    start = at + marker.size
    stop = body.index("\"", start)
    raise "unterminated authenticity_token" if stop.nil?

    body[start, stop - start].to_s
  end

  # A NotifyCommentJob row that has used its attempts: `failed`, which the
  # jobs page offers to retry, discard or delete.
  def self.failed_job
    id = Cybertrain::Job.enqueue("NotifyCommentJob", "{\"comment_id\":1,\"article_id\":1}")
    Cybertrain::DB.with do |c|
      c.execute("UPDATE cybertrain_jobs SET state = 'failed', attempts = 3, last_error = 'boom' WHERE id = ?", [id])
    end
    id
  end

  # A NotifyCommentJob row that has run (`done`), last updated `days_ago`
  # days ago.
  def self.done_job(days_ago)
    id = Cybertrain::Job.enqueue("NotifyCommentJob", "{\"comment_id\":1,\"article_id\":1}")
    Cybertrain::DB.with do |c|
      c.execute("UPDATE cybertrain_jobs SET state = 'done', updated_at = ? WHERE id = ?",
                Cybertrain::Cast.binds(Time.current.to_i - days_ago * 86_400, id))
    end
    id
  end

  # The state of the job row `id`; "(gone)" when there is no such row.
  def self.job_state(id)
    rows = Cybertrain::DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = ?", [id]) }
    return "(gone)" if rows.empty?

    Cybertrain::Cast.str(rows[0]["state"])
  end

  # The session a cookie jar's session cookie carries, read as the server
  # reads it.
  def self.session_of(cookies)
    key = Cybertrain::Crypto.derive_key(Cybertrain.config.secret_key_base, Cybertrain::SessionStore::SESSION_KEY_LABEL)
    Cybertrain::Session.load(cookies[Cybertrain.config.session_cookie_name].to_s, key)
  end

  # Every statement run so far, over the pool's connections (requests and
  # the test share them).
  def self.statements_run_total
    pool = Cybertrain::DB.pool
    total = 0
    i = 0
    while i < pool.size
      total += pool.connection_at(i).statements_run
      i += 1
    end
    total
  end

  # The text of body between `marker` and the next `stop` after it ("" when
  # the marker is not there).
  def self.text_after(body, marker, stop)
    at = body.index(marker)
    return "" if at.nil?

    start = at + marker.size
    finish = body.index(stop, start)
    return "" if finish.nil?

    body[start, finish - start].to_s
  end

  # Whether text is 8 lowercase hex digits (an asset digest).
  def self.hex8?(text)
    return false unless text.size == 8

    text.each_char { |ch| return false unless "0123456789abcdef".include?(ch) }
    true
  end

  # Whether text is a request id as the blog makes them: a version 4
  # UUID in lowercase hex, `xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx`.
  def self.uuid?(text)
    return false unless text.size == 36

    i = 0
    text.each_char do |ch|
      ok = if i == 8 || i == 13 || i == 18 || i == 23
             ch == "-"
           elsif i == 14
             ch == "4"
           elsif i == 19
             "89ab".include?(ch)
           else
             "0123456789abcdef".include?(ch)
           end
      return false unless ok

      i += 1
    end
    true
  end

  # The newest job row as text: [id, kind, request_id] (["", "", ""] when
  # there is none). request_id is the id of the request that enqueued it,
  # "" for a job enqueued outside a request.
  def self.last_job
    rows = Cybertrain::DB.with { |c| c.execute("SELECT id, kind, request_id FROM cybertrain_jobs ORDER BY id DESC LIMIT 1") }
    return ["", "", ""] if rows.empty?

    [Cybertrain::Cast.int(rows[0]["id"]).to_s, Cybertrain::Cast.str(rows[0]["kind"]), Cybertrain::Cast.str(rows[0]["request_id"])]
  end

  # The value of `key` in a Sentry envelope's event `extra` object, as
  # text ("" when absent). The reporter's context keys hold a dot
  # ("job.attempt"), which SentryEnvelope#sentry_field reads as a path.
  def self.sentry_extra(envelope, key)
    lines = envelope.sentry_body.split("\n")
    return "" if lines.size < 3

    value = Cybertrain::Cast.parse_json(lines[2].to_s)
    parts = ["extra", key]
    i = 0
    while i < parts.size
      part = parts[i].to_s
      case value
      when Time then return ""
      when Hash then value = value[part]
      else return ""
      end
      i += 1
    end
    case value
    when nil then ""
    when Time then ""
    when Hash then ""
    when Array then ""
    else Cybertrain::Cast.str(value)
    end
  end

  # Whether res set the locale cookie (a Set-Cookie for `locale`).
  def self.sets_locale_cookie?(res)
    res.cookies.any? { |c| c.start_with?("locale=") }
  end

  # The token a <turbo-stream-source src="/cybertrain/stream?s=TOKEN">
  # element carries.
  def self.stream_token(body)
    marker = "<turbo-stream-source src=\"/cybertrain/stream?s="
    at = body.index(marker)
    raise "no turbo-stream-source in the page" if at.nil?

    start = at + marker.size
    stop = body.index("\"", start)
    raise "unterminated turbo-stream-source" if stop.nil?

    body[start, stop - start].to_s
  end

  # The last row Cybertrain::Stream.broadcast wrote: [stream, payload].
  def self.last_broadcast
    rows = Cybertrain::DB.with { |c| c.execute("SELECT stream, payload FROM cybertrain_messages ORDER BY id DESC LIMIT 1") }
    return ["", ""] if rows.empty?

    [Cybertrain::Cast.str(rows[0]["stream"]), Cybertrain::Cast.str(rows[0]["payload"])]
  end
end
