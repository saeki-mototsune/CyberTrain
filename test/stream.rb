require "stringio"
require "cybertrain"
require "cybertrain/stream"
require "cybertrain/test"

# Cybertrain::Stream, compiled with the whole framework (NOTES rule 41):
# the cybertrain_messages table, broadcasts and their ids, signed tokens
# and what verify refuses, name_for, the Hub's fan-out, order, idle pop,
# unsubscribe and the backlog drop, a poller tick, prune, replay and the
# Turbo broadcast shortcuts. SQLite through FFI, so the snapshot comes from
# the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Stream = Cybertrain::Stream

Cybertrain.config.secret_key_base = "s" * 64
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

class BlogPost < Cybertrain::Model
  def self.table_name = "blog_posts"
  def model_name = "BlogPost"
end

def fresh_db
  DB.connect(":memory:")
  Stream::Poller.last_id = 0
  nil
end

def payloads_of(sub)
  out = Array.new(0) { "" }
  while true
    msg = sub.stream_pop(0.01)
    break if msg.nil?

    out << msg.message_payload
  end
  out
end

def ids_of(messages)
  out = Array.new(0) { 0 }
  messages.each { |m| out << m.message_id }
  out
end

def row_count
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_messages") }
  Cybertrain::Cast.int(rows[0]["n"])
end

def last_payload
  rows = DB.with { |c| c.execute("SELECT payload FROM cybertrain_messages ORDER BY id DESC LIMIT 1") }
  Cybertrain::Cast.str(rows[0]["payload"])
end

# The key Stream signs with: derived from the secret for this one purpose,
# so a token is never a valid session cookie.
def stream_key
  Cybertrain::Crypto.hmac_hex("s" * 64, "cybertrain/stream")
end

def flipped(token)
  last = token.getbyte(token.bytesize - 1)
  swap = last == 48 ? "1" : "0"
  out = +""
  out << token.byteslice(0, token.bytesize - 1)
  out << swap
  out
end

test "broadcast writes a row and returns increasing ids" do
  fresh_db
  first = Stream.broadcast("a", "x")
  second = Stream.broadcast("a", "y")
  assert first > 0
  assert second > first
  assert_equal 2, row_count
  assert_equal "y", last_payload
end

test "broadcast refuses an invalid stream name" do
  fresh_db
  assert_raises("ArgumentError") { Stream.broadcast("", "x") }
  assert_raises("ArgumentError") { Stream.broadcast("a\nb", "x") }
end

test "sign round-trips through verify" do
  token = Stream.sign(["articles:1", "alerts"])
  assert_equal ["articles:1", "alerts"], Stream.verify(token)
  assert_equal ["été"], Stream.verify(Stream.sign(["été"]))
end

test "verify refuses a tampered, empty or foreign token" do
  token = Stream.sign(["articles:1"])
  assert_nil Stream.verify(flipped(token))
  assert_nil Stream.verify("")
  assert_nil Stream.verify("--")
  assert_nil Stream.verify("garbage")
  # names that are fine, signed with another secret
  config = Cybertrain.config
  config.secret_key_base = "t" * 64
  foreign = Stream.sign(["articles:1"])
  config.secret_key_base = "s" * 64
  assert_nil Stream.verify(foreign)
end

test "a stream token is not a session cookie" do
  # names that join into a session's JSON payload
  token = Stream.sign(["{\"user_id\":\"1\"", "\"x\":\"y\"}"])
  assert_equal ["{\"user_id\":\"1\"", "\"x\":\"y\"}"], Stream.verify(token)
  session = Cybertrain::Session.load(token, Cybertrain::Crypto.derive_key("s" * 64, "cybertrain session"))
  assert_nil session["user_id"]
  assert_equal 0, session.keys.size
  # and a session cookie is not a stream token
  cookie = Cybertrain::Session.dump(Cybertrain::Session.new({ "a" => "b" }), Cybertrain::Crypto.derive_key("s" * 64, "cybertrain session"))
  assert_nil Stream.verify(cookie)
end

test "verify refuses tokens whose names are invalid, even when signed" do
  many = Array.new(0) { "" }
  17.times { |i| many << "s#{i}" }
  # signed by hand, as an attacker with the secret could not, to show that
  # verify checks the names too
  joined = many.join(",")
  encoded = Base64.urlsafe_encode64(joined, padding: false)
  seventeen = encoded + "--" + Cybertrain::Crypto.hmac_hex(stream_key, encoded)
  assert_nil Stream.verify(seventeen)
  long = Base64.urlsafe_encode64("x" * 201, padding: false)
  assert_nil Stream.verify(long + "--" + Cybertrain::Crypto.hmac_hex(stream_key, long))
  newline = Base64.urlsafe_encode64("a\nb", padding: false)
  assert_nil Stream.verify(newline + "--" + Cybertrain::Crypto.hmac_hex(stream_key, newline))
end

test "sign refuses what verify would" do
  assert_raises("ArgumentError") { Stream.sign([]) }
  assert_raises("ArgumentError") { Stream.sign(["x" * 201]) }
  assert_raises("ArgumentError") { Stream.sign(["a,b"]) }
  sixteen = Array.new(0) { "" }
  16.times { |i| sixteen << "s#{i}" }
  assert_equal 16, Stream.verify(Stream.sign(sixteen)).size
end

test "name_for gives table:id for a record and passes a String through" do
  post = BlogPost.new
  post.set_id(12)
  assert_equal "blog_posts:12", Stream.name_for(post)
  assert_equal "alerts", Stream.name_for("alerts")
  assert_raises("ArgumentError") { Stream.name_for(BlogPost.new) }
end

test "replay filters by stream in SQL and reads one chunk at a time" do
  fresh_db
  250.times do |i|
    Stream.broadcast("big", "b#{i}")
    Stream.broadcast("noise", "n#{i}")
  end
  first = Stream.replay(["big"], 0)
  assert_equal Stream::REPLAY_CHUNK, first.size
  assert_equal "b0", first[0].message_payload
  rest = Stream.replay(["big"], first[first.size - 1].message_id)
  assert_equal 50, rest.size
  assert_equal "b249", rest[rest.size - 1].message_payload
  assert_equal 3, Stream.replay(["big", "noise"], 0, 3).size
  assert_equal 0, Stream.replay(Array.new(0) { "" }, 0).size
end

test "a subscriber takes at most 64 waiting control messages" do
  sub = Stream::Subscriber.new(["a"], 1000)
  ok = 0
  64.times { ok += 1 if sub.stream_control(Stream::Message.new(-1, "ping", "")) }
  assert_equal 64, ok
  refute sub.control_overflow?
  refute sub.stream_control(Stream::Message.new(-1, "ping", ""))
  assert sub.control_overflow?
end

test "subscribe names are capped and subscribe_within keeps the limit" do
  hub = Stream::Hub.new(1000)
  sub = hub.subscribe(["a"])
  many = Array.new(0) { "" }
  63.times { |i| many << "n#{i}" }
  assert hub.add_names(sub, many)
  assert_equal 64, sub.name_count
  refute hub.add_names(sub, ["one more"])
  assert_equal 64, sub.name_count
  other = Stream::Hub.new(1000)
  assert !other.subscribe_within(["a"], 1).nil?
  assert other.subscribe_within(["b"], 1).nil?
  assert_equal 1, other.subscriber_count
end

test "the hub delivers to every matching subscriber in order" do
  hub = Stream::Hub.new(1000)
  ab = hub.subscribe(["a", "b"])
  b = hub.subscribe(["b"])
  hub.deliver(1, "a", "a1")
  hub.deliver(2, "b", "b2")
  hub.deliver(3, "c", "c3")
  hub.deliver(4, "a", "a4")
  assert_equal ["a1", "b2", "a4"], payloads_of(ab)
  assert_equal ["b2"], payloads_of(b)
  assert_equal 2, hub.subscriber_count
end

test "an idle pop returns nil and unsubscribe stops delivery" do
  hub = Stream::Hub.new(1000)
  sub = hub.subscribe(["a"])
  assert_nil sub.stream_pop(0.05)
  hub.unsubscribe(sub)
  assert_equal 0, hub.deliver(1, "a", "x")
  assert_nil sub.stream_pop(0.01)
  assert_equal 0, hub.subscriber_count
end

test "a subscriber whose backlog overflows is dropped" do
  hub = Stream::Hub.new(1000)
  sub = hub.subscribe(["a"])
  1000.times { |i| hub.deliver(i + 1, "a", "m") }
  refute sub.dropped?
  hub.deliver(1001, "a", "m")
  assert sub.dropped?
  assert_nil sub.stream_pop(0.01)
end

test "names can be added and removed" do
  hub = Stream::Hub.new(1000)
  sub = hub.subscribe(["a"])
  hub.add_names(sub, ["b", "a"])
  assert_equal ["a", "b"], sub.stream_names
  hub.remove_names(sub, ["a"])
  hub.deliver(1, "a", "no")
  hub.deliver(2, "b", "yes")
  assert_equal ["yes"], payloads_of(sub)
end

test "a poller tick delivers only the rows after the last id" do
  fresh_db
  hub = Stream::Hub.new(1000)
  sub = hub.subscribe(["a"])
  Stream.broadcast("a", "one")
  Stream.broadcast("b", "other")
  assert_equal 2, Stream::Poller.run_once(hub)
  assert_equal ["one"], payloads_of(sub)
  assert_equal 0, Stream::Poller.run_once(hub)
  Stream.broadcast("a", "two")
  assert_equal 1, Stream::Poller.run_once(hub)
  assert_equal ["two"], payloads_of(sub)
end

test "Poller.reset! starts after the rows already written" do
  fresh_db
  hub = Stream::Hub.new(1000)
  sub = hub.subscribe(["a"])
  Stream.broadcast("a", "before")
  Stream::Poller.reset!(hub)
  assert_equal 0, Stream::Poller.run_once(hub)
  Stream.broadcast("a", "after")
  assert_equal 1, Stream::Poller.run_once(hub)
  assert_equal ["after"], payloads_of(sub)
end

test "the replay-to-live handoff sends every row once, in id order" do
  fresh_db
  hub = Stream::Hub.new(1000)
  Stream.broadcast("a", "1")
  Stream::Poller.reset!(hub)
  # subscribe first; a row written before the replay is both replayed and
  # delivered live
  head = Stream.replay_head(0)
  sub = hub.subscribe(["a"])
  Stream.broadcast("a", "2")
  Stream::Poller.run_once(hub)
  sent = Array.new(0) { "" }
  start = Stream.replay_start(0, head)
  backlog = Stream.replay(["a"], start)
  boundary = start
  backlog.each do |m|
    sent << m.message_payload
    boundary = m.message_id
  end
  # a row written between the replay query and the first live pop
  Stream.broadcast("a", "3")
  Stream::Poller.run_once(hub)
  sub.skip_through!(boundary)
  payloads_of(sub).each { |p| sent << p }
  assert_equal ["1", "2", "3"], sent
end

test "a subscriber's cutoff is the poller's position when it subscribes" do
  hub = Stream::Hub.new(1000)
  Stream::Poller.last_id = 5
  sub = hub.subscribe(["a"])
  assert_equal 5, sub.boundary
  assert_equal 0, hub.deliver(5, "a", "delivered before")
  assert_equal 1, hub.deliver(6, "a", "after")
  assert_equal ["after"], payloads_of(sub)
  Stream::Poller.last_id = 0
end

test "a row polled before subscribing is not delivered, one not yet polled is" do
  fresh_db
  hub = Stream::Hub.new(1000)
  Stream.broadcast("a", "polled before")
  assert_equal 1, Stream::Poller.run_once(hub)
  Stream.broadcast("a", "committed before, not yet polled")
  sub = hub.subscribe(["a"])
  Stream.broadcast("a", "after")
  assert_equal 2, Stream::Poller.run_once(hub)
  assert_equal ["committed before, not yet polled", "after"], payloads_of(sub)
end

test "a replay that finds nothing leaves the boundary at after" do
  fresh_db
  hub = Stream::Hub.new(1000)
  head = Stream.broadcast("a", "head")
  Stream::Poller.reset!(hub)
  sub = hub.subscribe(["a"])
  assert_equal 0, Stream.replay(["a"], head).size
  sub.skip_through!(head)
  assert_equal head, sub.boundary
  Stream.broadcast("a", "live")
  Stream::Poller.run_once(hub)
  assert_equal ["live"], payloads_of(sub)
  # after below a pruned range: nothing to replay, live goes on from there
  DB.with { |c| c.execute("UPDATE cybertrain_messages SET created_at = ?", [Time.now.to_i - 120]) }
  Stream.prune(Time.now.to_i - 60)
  late = hub.subscribe(["a"])
  assert_equal 0, Stream.replay(["a"], 1).size
  late.skip_through!(1)
  Stream.broadcast("a", "next")
  Stream::Poller.run_once(hub)
  assert_equal ["next"], payloads_of(late)
end

test "the poller starts on a database without the messages table" do
  DB.connect(":memory:")
  Stream::Poller.last_id = 0
  hub = Stream::Hub.new(1000)
  assert_equal 0, Stream::Poller.run_once(hub)
  DB.connect(":memory:")
  assert Stream::Poller.start!(Cybertrain.config)
  assert_equal 0, Stream::Poller.last_id
  Stream::Poller.stop!
  sleep 0.2
  assert_equal 0, row_count
end

test "an after above the head is clamped to the table's head, not below it" do
  fresh_db
  hub = Stream::Hub.new(1000)
  Stream.broadcast("a", "x")
  Stream::Poller.run_once(hub)
  head = Stream.replay_head(999_999)
  sub = hub.subscribe(["a"])
  start = Stream.replay_start(999_999, head)
  assert_equal Stream.max_id, start
  assert_equal 0, Stream.replay(["a"], start).size
  sub.skip_through!(start)
  Stream.broadcast("a", "next")
  Stream::Poller.run_once(hub)
  assert_equal ["next"], payloads_of(sub)
  assert_equal 0, Stream.replay_start(0, Stream.replay_head(0))
  assert_equal(-1, Stream.replay_head(-1))
  assert_equal(-1, Stream.replay_start(-1, Stream.replay_head(-1)))
end

test "a row broadcast between the head and the subscription is replayed, not lost" do
  fresh_db
  hub = Stream::Hub.new(1000)
  Stream.broadcast("a", "x")
  Stream::Poller.run_once(hub)
  head = Stream.replay_head(999_999)
  sub = hub.subscribe(["a"])
  Stream.broadcast("a", "raced")
  Stream::Poller.run_once(hub)
  start = Stream.replay_start(999_999, head)
  assert_equal head, start
  backlog = Stream.replay(["a"], start)
  assert_equal ["raced"], backlog.map { |m| m.message_payload }
  sub.skip_through!(backlog[backlog.size - 1].message_id)
  assert_equal 0, payloads_of(sub).size
end

test "a client ahead of a lagging poller is not sent its rows again" do
  fresh_db
  hub = Stream::Hub.new(1000)
  Stream.broadcast("a", "1")
  Stream::Poller.run_once(hub)
  # rows 2 and 3 are in the table but this process's poller has not read
  # them yet; the client got them from another process
  Stream.broadcast("a", "2")
  Stream.broadcast("a", "3")
  head = Stream.replay_head(3)
  sub = hub.subscribe(["a"])
  assert_equal 1, sub.boundary
  start = Stream.replay_start(3, head)
  assert_equal 3, start
  assert_equal 0, Stream.replay(["a"], start).size
  sub.skip_through!(start)
  Stream.broadcast("a", "4")
  Stream::Poller.run_once(hub)
  assert_equal ["4"], payloads_of(sub)
end

test "prune deletes the rows older than the cutoff" do
  fresh_db
  Stream.broadcast("a", "old")
  DB.with { |c| c.execute("UPDATE cybertrain_messages SET created_at = ?", [Time.now.to_i - 120]) }
  Stream.broadcast("a", "new")
  assert_equal 1, Stream.prune(Time.now.to_i - 60)
  assert_equal 1, row_count
  assert_equal "new", last_payload
end

test "replay returns the backlog of the named streams after an id" do
  fresh_db
  first = Stream.broadcast("a", "1")
  Stream.broadcast("b", "2")
  third = Stream.broadcast("a", "3")
  Stream.broadcast("c", "4")
  assert_equal [first, third], ids_of(Stream.replay(["a"], 0))
  assert_equal [third], ids_of(Stream.replay(["a"], first))
  assert_equal 3, Stream.replay(["a", "b"], 0).size
end

test "broadcast_replace_to writes the Turbo Stream HTML" do
  fresh_db
  Stream.broadcast_replace_to("s", target: "t", html: Cybertrain::Html.safe("<p>x</p>"))
  assert_equal "<turbo-stream action=\"replace\" target=\"t\"><template><p>x</p></template></turbo-stream>", last_payload
  Stream.broadcast_append_to("s", target: "t", html: "<b>")
  assert_equal "<turbo-stream action=\"append\" target=\"t\"><template>&lt;b&gt;</template></turbo-stream>", last_payload
end

test "broadcast_replace_to with partial: keeps the partial's markup and escapes its locals" do
  fresh_db
  Cybertrain::Views.configure_embedded({ "_row.html.erb" => "<%# locals: (name:) %><li><%= name %></li>" })
  Stream.broadcast_replace_to("s", target: "t", partial: "row", locals: { name: "a <b>" })
  assert_equal "<turbo-stream action=\"replace\" target=\"t\"><template><li>a &lt;b&gt;</li></template></turbo-stream>", last_payload
end

test "the other broadcast shortcuts" do
  fresh_db
  post = BlogPost.new
  post.set_id(5)
  Stream.broadcast_update_to(post, target: post, html: "u")
  assert_equal "<turbo-stream action=\"update\" target=\"blog_post_5\"><template>u</template></turbo-stream>", last_payload
  Stream.broadcast_prepend_to("s", target: "t", html: "p")
  assert_includes last_payload, "action=\"prepend\""
  Stream.broadcast_before_to("s", target: "t", html: "b")
  assert_includes last_payload, "action=\"before\""
  Stream.broadcast_after_to("s", target: "t", html: "a")
  assert_includes last_payload, "action=\"after\""
  Stream.broadcast_remove_to("s", target: post)
  assert_equal "<turbo-stream action=\"remove\" target=\"blog_post_5\"></turbo-stream>", last_payload
  Stream.broadcast_refresh_to(post)
  assert_equal "<turbo-stream action=\"refresh\"></turbo-stream>", last_payload
  rows = DB.with { |c| c.execute("SELECT stream FROM cybertrain_messages WHERE id = (SELECT MAX(id) FROM cybertrain_messages)") }
  assert_equal "blog_posts:5", Cybertrain::Cast.str(rows[0]["stream"])
end

Cybertrain::Test.run!
