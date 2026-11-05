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

test "verify refuses tokens whose names are invalid, even when signed" do
  many = Array.new(0) { "" }
  17.times { |i| many << "s#{i}" }
  # signed by hand, as an attacker with the secret could not, to show that
  # verify checks the names too
  joined = many.join(",")
  encoded = Base64.urlsafe_encode64(joined, padding: false)
  seventeen = encoded + "--" + Cybertrain::Crypto.hmac_hex("s" * 64, encoded)
  assert_nil Stream.verify(seventeen)
  long = Base64.urlsafe_encode64("x" * 201, padding: false)
  assert_nil Stream.verify(long + "--" + Cybertrain::Crypto.hmac_hex("s" * 64, long))
  newline = Base64.urlsafe_encode64("a\nb", padding: false)
  assert_nil Stream.verify(newline + "--" + Cybertrain::Crypto.hmac_hex("s" * 64, newline))
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
