# Shared setup for the integration tests (test/*.rb): the app booted in
# the test environment on a fresh storage/test.sqlite3. Required by the
# test files, not run (`spin test` runs test/*.rb only).
ENV["CYBERTRAIN_ENV"] = "test"

require "cybertrain"
require "cybertrain/test/client"
require "cybertrain/test/jobs"
require_relative "../../config/app"
require_relative "../../gen/app"
require_relative "../../gen/migrations"

# No request log: `spin test` diffs the whole output against the
# snapshot, and "Completed 303 in 246ms" is never the same twice.
Cybertrain.config.log_level = :none

# Webhooks and e-mail the app sends are received in-process: require
# "cybertrain/test/http_receiver" or "cybertrain/test/smtp_receiver",
# then `port = receiver.start`, point the app at 127.0.0.1:port
# (HttpClient needs `Cybertrain.config.http_allow_private = true`, the
# Mailer `tls: "none"`), and read `receiver.received_request` /
# `received_message` before `receiver.stop`. Every wait is bounded.

module AppTest
  # Deletes the test database (and its WAL files), migrates a new one
  # and boots the application on it.
  def self.boot
    path = Cybertrain.config.database_path
    [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
    connection = Cybertrain::DB::Connection.new(path)
    Cybertrain::DB::Migrator.new(connection).migrate(Cybertrain::Migration.all)
    connection.close

    app = Cybertrain::Application.new(
      router: Gen::Routes.build(Cybertrain::Router.new),
      url_resolver: Gen::Routes.url_resolver
    )
    app.boot
  end

  # The authenticity_token of the first form in the last response, as
  # a browser would submit it back.
  def self.form_token(client)
    body = client.response.body
    marker = "name=\"authenticity_token\" value=\""
    at = body.index(marker)
    raise "no authenticity_token in the last response" if at.nil?

    start = at + marker.size
    stop = body.index("\"", start)
    raise "unterminated authenticity_token" if stop.nil?

    body[start, stop - start].to_s
  end

  # A user with this address and password (both normalized the way the
  # forms are).
  def self.user(email_address = "ann@example.com", password = "s3cr3t-s3cr3t")
    user = User.new(email_address: email_address)
    user.password = password
    user.save!
    user
  end

  # Signs `client` in through the form, as a browser would. Every test
  # client has the same address, so the sign-in rate limit's counts
  # are forgotten first: a suite signs in far more than ten times.
  def self.sign_in(client, email_address = "ann@example.com", password = "s3cr3t-s3cr3t")
    Cybertrain::RateLimit.reset_all!
    client.get("/session/new")
    client.post("/session", { "authenticity_token" => form_token(client),
                              "email_address" => email_address,
                              "password" => password })
  end
end

APP = AppTest.boot
