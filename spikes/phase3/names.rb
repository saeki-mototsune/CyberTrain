# Phase 3 spike, check 6 (spec section 14): the names phase 3 adds that
# already exist on another receiver, compiled together with the whole
# framework and with the existing definitions reached at run time (NOTES
# rules 10 / 34 / 41 / 36). The cache, the SSE parser, Job::Base, Job::Run,
# Job.register, two job classes with their generated half, and
# HttpClient#request / Response#json_hash are stand-ins with the spec's
# names and return types, not the implementation. A record, not a test.
#
# Pairs exercised (new here -> existing):
#   Cache.read String|nil   -> BlobStore.read String
#   Cache.write Boolean     -> BlobStore.write nil, BodyWriter#write nil
#   Cache.delete Boolean    -> BlobStore.delete Boolean, Session#delete String|nil,
#                              Test::Client#delete Response, Router#delete
#   Cache.clear nil         -> Session#clear, Errors#clear nil
#   Cache.exist? Boolean    -> BlobStore.exist? Boolean
#   Cache.increment Integer -> Relation#increment Integer (defined, not reached)
#   Cache.prune Integer     -> Stream.prune Integer
#   Job::Base#perform nil   -> Mailer#perform, HttpClient#perform
#   Job.register nil        -> Migration / RateLimit / Background / Test.register
#   HttpClient#request      -> Test::Client#request (another Response class)
#   Response#json_hash Hash -> Cast.json_hash Hash
#   Sse::Event#data String  -> Test::Upload#data String
#   Sse::Event#event_id String -> Stream::Endpoint.event_id Integer
#   Sse::Parser#feed { |event| } (new)
#
# Run (Spinel 2026.11.04.7026, from spikes/phase3/; the whole framework
# links SQLite through FFI, so compiled only):
#   spinel $(spin flags) names.rb -o /tmp/names && /tmp/names
# Output:
#   db connected: true
#   cache read miss: nil
#   cache write: true / unless_exist: false
#   cache read: "v1", exist?: true
#   cache fetch: computed then computed
#   cache fetch_hash: {"usd" => 1} then {"usd" => 1}
#   cache increment: 1 6
#   cache prune: 1
#   cache delete: true false
#   cache after clear: nil
#   BlobStore read: blob, exist?: true, delete: true
#   Session#delete: "1", nil
#   Errors#clear: true
#   Stream.prune: 0
#   Test::Client get: 200 deleted 7
#   Test::Client delete: Invalid authenticity token
#   Test::Client request: Invalid authenticity token
#   HttpClient get: 200 json_hash {"price" => 42}
#   HttpClient request PUT: 200 PUT
#   Cast.json_hash: {"a" => 1}
#   Mailer delivered: true
#   jobs: welcome 1, welcome 2, report all, discarded bad scope
#   job kinds: WelcomeJob ReportJob, registered 2
#   Base#perform: NotImplementedError: Cybertrain::Job::Base#perform
#   sse: price|"1\n2"|9|-1 ; message|"plain"|9|-1
#   Stream::Endpoint.event_id: 13
#   UploadedFile#data: bytes
require "stringio"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/mailer"
require "cybertrain/http_client"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
ENV["CYBERTRAIN_ENV"] = "test"

module Cybertrain
  # The cache's names and return types (spec section 7), over the
  # application database.
  module Cache
    TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, " \
                "expires_at INTEGER, updated_at INTEGER NOT NULL)"

    def self.install!
      DB.with { |c| c.exec_script(TABLE_SQL) }
      nil
    end

    def self.read(key)
      now = Time.now.to_i
      rows = DB.with { |c| c.execute("SELECT value FROM cybertrain_cache WHERE key = ? AND (expires_at IS NULL OR expires_at >= ?)", [key.to_s, now]) }
      return nil if rows.empty?

      Cast.str(rows[0]["value"])
    end

    def self.write(key, value, expires_in: 0, unless_exist: false)
      now = Time.now.to_i
      expires = expires_in > 0 ? now + expires_in : nil
      if unless_exist && !read(key).nil?
        return false
      end

      DB.with do |c|
        c.execute("INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) VALUES (?, ?, ?, ?) " \
                  "ON CONFLICT (key) DO UPDATE SET value = excluded.value, expires_at = excluded.expires_at, " \
                  "updated_at = excluded.updated_at", Cast.binds(key.to_s, value.to_s, expires, now))
      end
      true
    end

    def self.delete(key)
      n = 0
      DB.with do |c|
        c.execute("DELETE FROM cybertrain_cache WHERE key = ?", [key.to_s])
        n = c.changes
      end
      n > 0
    end

    def self.exist?(key)
      !read(key).nil?
    end

    def self.clear
      DB.with { |c| c.execute("DELETE FROM cybertrain_cache") }
      nil
    end

    def self.increment(key, by: 1)
      now = Time.now.to_i
      rows = DB.with do |c|
        c.execute("INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) VALUES (?, ?, NULL, ?) " \
                  "ON CONFLICT (key) DO UPDATE SET value = CAST(value AS INTEGER) + ?, updated_at = ? RETURNING value",
                  [key.to_s, by.to_s, now, by, now])
      end
      Cast.int(rows[0]["value"])
    end

    def self.prune(now)
      n = 0
      DB.with do |c|
        c.execute("DELETE FROM cybertrain_cache WHERE expires_at < ?", [now])
        n = c.changes
      end
      n
    end

    def self.fetch(key, expires_in: 0)
      hit = read(key)
      return hit unless hit.nil?

      value = yield
      write(key, value, expires_in: expires_in)
      value
    end

    def self.fetch_hash(key, expires_in: 0)
      hit = read(key)
      return Cast.json_hash(hit) unless hit.nil?

      value = yield
      write(key, JSON.generate(value), expires_in: expires_in)
      value
    end
  end

  # The SSE parser's names (spec section 8).
  module Sse
    class Event
      attr_reader :event_name, :data, :event_id, :retry_ms

      def initialize(event_name, data, event_id, retry_ms)
        @event_name = event_name
        @data = data
        @event_id = event_id
        @retry_ms = retry_ms
      end
    end

    class Parser
      def initialize
        @buffer = String.new
        @name = ""
        @lines = Array.new(0) { "" }
        @last_id = ""
        @retry = -1
      end

      # LF line ends only in the stand-in; the real parser takes CR / CRLF.
      def feed(chunk)
        @buffer << chunk.to_s
        while true
          at = @buffer.index("\n")
          break if at.nil?

          line = @buffer.byteslice(0, at)
          @buffer = @buffer.byteslice(at + 1, @buffer.bytesize - at - 1)
          if line.empty?
            unless @lines.empty?
              yield Event.new(@name.empty? ? "message" : @name, @lines.join("\n"), @last_id, @retry)
            end
            @lines = Array.new(0) { "" }
            @name = ""
          elsif !line.start_with?(":")
            colon = line.index(":")
            field = colon.nil? ? line : line.byteslice(0, colon)
            value = colon.nil? ? "" : line.byteslice(colon + 1, line.bytesize - colon - 1)
            value = value.byteslice(1, value.bytesize - 1) if value.start_with?(" ")
            case field
            when "event" then @name = value
            when "data" then @lines << value
            when "id" then @last_id = value
            when "retry" then @retry = value.to_i
            end
          end
        end
        nil
      end
    end
  end

  module Job
    # Job::Run's prefixed readers (spec section 2.2).
    class Run
      attr_reader :run_id, :run_kind, :run_payload, :run_attempts

      def initialize(id, kind, payload, attempts)
        @run_id = id
        @run_kind = kind
        @run_payload = payload
        @run_attempts = attempts
      end

      def run_args
        Cast.json_hash(@run_payload)
      end
    end

    class Registration
      attr_reader :reg_kind, :reg_block, :reg_concurrency

      def initialize(kind, block, concurrency)
        @reg_kind = kind
        @reg_block = block
        @reg_concurrency = concurrency
      end
    end

    REGISTRATIONS = Array.new(0) { Registration.new("", nil, 0) }

    def self.register(kind, concurrency: 0, concurrency_key: "", max_attempts: 5, &block)
      raise ArgumentError, "Job.register: the kind is empty" if kind.empty?

      REGISTRATIONS << Registration.new(kind, block, concurrency)
      nil
    end

    def self.run_registered(kind, run)
      i = 0
      while i < REGISTRATIONS.size
        reg = REGISTRATIONS[i]
        reg.reg_block.call(run) if reg.reg_kind == kind
        i += 1
      end
      nil
    end

    class Base
      def perform(args)
        raise NotImplementedError, "#{self.class.name}#perform"
      end

      def retries_exhausted(error)
        nil
      end

      def self.retry_on(klass, wait: 0, attempts: 5)
        nil
      end

      def self.discard_on(klass)
        nil
      end
    end
  end

  class HttpClient
    def request(verb, url, body: "", content_type: "", headers: NO_HEADERS)
      perform(verb, url, body, content_type, headers)
    end

    class Response
      def json_hash
        Cast.json_hash(@body)
      end
    end
  end
end

DONE = Array.new(0) { "" }

# app/jobs (the class bodies).
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5

  def perform(args)
    DONE << "welcome #{Cybertrain::Cast.int(args["user_id"])}"
    nil
  end
end

class ReportJob < Cybertrain::Job::Base
  discard_on ArgumentError

  def perform(args)
    text = "bad scope"
    raise ArgumentError, text if Cybertrain::Cast.str(args["scope"]) == "bad"

    DONE << "report #{Cybertrain::Cast.str(args["scope"])}"
    nil
  end
end

# gen/jobs.rb (the generated half).
class WelcomeJob
  def self.job_kind = "WelcomeJob"

  def self.perform_now(args)
    new.perform(args)
    nil
  end

  def self.run_job(run)
    job = new
    begin
      job.perform(run.run_args)
    rescue Cybertrain::Mailer::TimeoutError => e
      job.retries_exhausted(e)
    end
    nil
  end
end
Cybertrain::Job.register("WelcomeJob", concurrency: 1, concurrency_key: "user_id") { |run| WelcomeJob.run_job(run) }

class ReportJob
  def self.job_kind = "ReportJob"

  def self.perform_now(args)
    new.perform(args)
    nil
  end

  def self.run_job(run)
    job = new
    begin
      job.perform(run.run_args)
    rescue ArgumentError => e
      DONE << "discarded #{e.message}"
    end
    nil
  end
end
Cybertrain::Job.register("ReportJob") { |run| ReportJob.run_job(run) }

# An application with a session action, driven through Test::Client
# (Session#delete / #clear, Test::Client#delete / #request reached).
class SessionsController < Cybertrain::Controller
  def show
    session[:user_id] = "7"
    old = session.delete(:user_id)
    session.clear
    render plain: "deleted #{old}"
  end

  def destroy
    render plain: "destroyed"
  end
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/s", "s") { |ctx| SessionsController.new(ctx).process(:show) { |c| c.show } }
ROUTER.delete("/s", "s_delete") { |ctx| SessionsController.new(ctx).process(:destroy) { |c| c.destroy } }

config = Cybertrain::Config.new
config.env = "test"
config.database_path = ":memory:"
config.pool_size = 1
config.secret_key_base = "names-spike-secret"
APP = Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args) { "/" }, config: config)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

puts "db connected: #{Cybertrain::DB.connected?}"

# The cache.
Cybertrain::Cache.install!
C = Cybertrain::Cache
puts "cache read miss: #{C.read("k").inspect}"
puts "cache write: #{C.write("k", "v1")} / unless_exist: #{C.write("k", "v2", unless_exist: true)}"
puts "cache read: #{C.read("k").inspect}, exist?: #{C.exist?("k")}"
puts "cache fetch: #{C.fetch("f") { "computed" }} then #{C.fetch("f") { "again" }}"
puts "cache fetch_hash: #{C.fetch_hash("h") { { "usd" => 1 } }} then #{C.fetch_hash("h") { { "usd" => 2 } }}"
puts "cache increment: #{C.increment("n")} #{C.increment("n", by: 5)}"
C.write("old", "x", expires_in: 1)
puts "cache prune: #{C.prune(Time.now.to_i + 10)}"
puts "cache delete: #{C.delete("k")} #{C.delete("k")}"
C.clear
puts "cache after clear: #{C.read("f").inspect}"

# The same names on the existing receivers.
Cybertrain::BlobStore.root = "tmp/names_spike_blobs"
key = Cybertrain::BlobStore.new_key
Cybertrain::BlobStore.write(key, "blob")
puts "BlobStore read: #{Cybertrain::BlobStore.read(key)}, exist?: #{Cybertrain::BlobStore.exist?(key)}, delete: #{Cybertrain::BlobStore.delete(key)}"
Dir.rmdir("tmp/names_spike_blobs/#{key[0, 2]}")
Dir.rmdir("tmp/names_spike_blobs")
s = Cybertrain::Session.new({ "a" => "1" })
puts "Session#delete: #{s.delete("a").inspect}, #{s.delete("a").inspect}"
s.clear
errors = Cybertrain::Errors.new
errors.add(:title, "is blank")
errors.clear
puts "Errors#clear: #{errors.empty?}"
puts "Stream.prune: #{Cybertrain::Stream.prune(0)}"
res = CLIENT.get("/s")
puts "Test::Client get: #{res.status} #{res.body}"
puts "Test::Client delete: #{CLIENT.delete("/s").body}"
puts "Test::Client request: #{CLIENT.request("DELETE", "/s").body}"

# HttpClient#perform through get / request, and Response#json_hash.
rx = Cybertrain::Test::HttpReceiver.new(body: "{\"price\":42}", max: 2)
rx.start
http = Cybertrain::HttpClient.new(timeout: 2, deadline: 5, allow_private: true)
got = http.get(rx.url("/p"))
puts "HttpClient get: #{got.status} json_hash #{got.json_hash}"
put = http.request("PUT", rx.url("/p"), body: "x", content_type: "text/plain")
puts "HttpClient request PUT: #{put.status} #{rx.received_requests(2)[1].http_method}"
rx.stop
puts "Cast.json_hash: #{Cybertrain::Cast.json_hash("{\"a\":1}")}"

# Mailer#perform through deliver.
smtp = Cybertrain::Test::SmtpReceiver.new
port = smtp.start
Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com", timeout: 2, deadline: 5)
                  .deliver(to: "bob@example.org", subject: "names", body: "b")
puts "Mailer delivered: #{smtp.received_message.delivered?}"
smtp.stop

# Jobs: perform_now, and run_job through the registered stored blocks.
WelcomeJob.perform_now({ "user_id" => 1 })
Cybertrain::Job.run_registered("WelcomeJob", Cybertrain::Job::Run.new(1, "WelcomeJob", "{\"user_id\":2}", 1))
Cybertrain::Job.run_registered("ReportJob", Cybertrain::Job::Run.new(2, "ReportJob", "{\"scope\":\"all\"}", 1))
Cybertrain::Job.run_registered("ReportJob", Cybertrain::Job::Run.new(3, "ReportJob", "{\"scope\":\"bad\"}", 1))
puts "jobs: #{DONE.join(", ")}"
puts "job kinds: #{WelcomeJob.job_kind} #{ReportJob.job_kind}, registered #{Cybertrain::Job::REGISTRATIONS.size}"
begin
  Cybertrain::Job::Base.new.perform({ "x" => 1 })
rescue NotImplementedError => e
  puts "Base#perform: #{e.class.name}: #{e.message}"
end

# The SSE parser, fed in pieces that split a line.
events = Array.new(0) { "" }
parser = Cybertrain::Sse::Parser.new
["event: price\nda", "ta: 1\ndata: 2\nid: 9\n\n: comment\n", "data: plain\n\n"].each do |chunk|
  parser.feed(chunk) { |ev| events << "#{ev.event_name}|#{ev.data.inspect}|#{ev.event_id}|#{ev.retry_ms}" }
end
puts "sse: #{events.join(" ; ")}"
puts "Stream::Endpoint.event_id: #{Cybertrain::Stream::Endpoint.event_id("12") + 1}"
up = Cybertrain::Test::Upload.new("f", "a.txt", "text/plain", "bytes")
puts "UploadedFile#data: #{up.data}"
