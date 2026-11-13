require "cybertrain/test"
require "cybertrain/sentry_dsn"

# Cybertrain::SentryDsn (spec section 13.4, plan Task 4): the DSN that turns
# the Sentry sender on, `scheme://key[:secret]@host[:port][/path]/<id>`,
# read by a byte scan. Refused DSNs say why and never echo the key (it is
# public in Sentry's model, still kept out of logs like any credential).
# Plain Ruby, no FFI: the snapshot comes from CRuby or the compiled binary
# alike.

# True when `text` contains `part` (include?, kept to one place).
def mentions?(text, part)
  text.include?(part)
end

test "a DSN's key, project and endpoint" do
  d = Cybertrain::SentryDsn.from_text("https://abc@o1.ingest.sentry.io/42")
  assert_equal "abc", d.dsn_public_key
  assert_equal "42", d.dsn_project_id
  assert_equal "https://o1.ingest.sentry.io/api/42/envelope/", d.dsn_endpoint
  assert_equal "http://127.0.0.1:9000/sentry/api/7/envelope/", Cybertrain::SentryDsn.from_text("http://k@127.0.0.1:9000/sentry/7").dsn_endpoint
  assert_equal "abc", Cybertrain::SentryDsn.from_text("https://abc:secret@h/1").dsn_public_key
  assert_equal "", Cybertrain::SentryDsn.problem("https://abc@o1.ingest.sentry.io/42")
end

test "a longer path, a bracketed IPv6 host and a port" do
  d = Cybertrain::SentryDsn.from_text("http://k-1_x@[::1]:8000/a/b.c/~d/123")
  assert_equal "k-1_x", d.dsn_public_key
  assert_equal "123", d.dsn_project_id
  assert_equal "http://[::1]:8000/a/b.c/~d/api/123/envelope/", d.dsn_endpoint
  assert_equal "https://h:65535/api/9/envelope/", Cybertrain::SentryDsn.from_text("https://k@h:65535/9").dsn_endpoint
  assert_equal "https://h:1/api/9/envelope/", Cybertrain::SentryDsn.from_text("https://k@h:1/9").dsn_endpoint
end

test "what a DSN may not be" do
  assert_equal "the scheme must be https or http", Cybertrain::SentryDsn.problem("ftp://a@h/1")
  assert_equal "no public key before the @", Cybertrain::SentryDsn.problem("https://h/1")
  assert_equal "no host", Cybertrain::SentryDsn.problem("https://a@/1")
  assert_equal "no project id", Cybertrain::SentryDsn.problem("https://a@h/")
  assert_equal "no project id", Cybertrain::SentryDsn.problem("https://a@h")
  assert_equal "the project id must be digits", Cybertrain::SentryDsn.problem("https://a@h/x1")
  assert_equal "a query or a fragment is not allowed", Cybertrain::SentryDsn.problem("https://a@h/1?x=1")
end

test "what a DSN may not be, where the brief is silent" do
  assert_equal "the DSN is empty", Cybertrain::SentryDsn.problem("")
  assert_equal "the scheme must be https or http", Cybertrain::SentryDsn.problem("HTTPS://a@h/1")
  assert_equal "the scheme must be https or http", Cybertrain::SentryDsn.problem("https:/a@h/1")
  assert_equal "the scheme must be https or http", Cybertrain::SentryDsn.problem("a@h/1")
  assert_equal "a query or a fragment is not allowed", Cybertrain::SentryDsn.problem("https://a@h/1#top")
  blank = "a space, a control character or a non-ASCII byte is not allowed"
  assert_equal blank, Cybertrain::SentryDsn.problem("https://a@h/1 ")
  assert_equal blank, Cybertrain::SentryDsn.problem("https://a@h/1\n")
  assert_equal blank, Cybertrain::SentryDsn.problem("https://a\r\n@h/1")
  assert_equal blank, Cybertrain::SentryDsn.problem("https://a@h\t/1")
  assert_equal blank, Cybertrain::SentryDsn.problem("https://a@h/1\x7f")
  assert_equal blank, Cybertrain::SentryDsn.problem("https://a@h\xC3\xA9/1")
  assert_equal "no public key before the @", Cybertrain::SentryDsn.problem("https://:secret@h/1")
  assert_equal "no public key before the @", Cybertrain::SentryDsn.problem("https://@h/1")
  # The key goes into X-Sentry-Auth: nothing that could end or add a field.
  key_chars = "the public key may hold only letters, digits, - and _"
  assert_equal key_chars, Cybertrain::SentryDsn.problem("https://a,sentry_key=b@h/1")
  assert_equal key_chars, Cybertrain::SentryDsn.problem("https://a%40@h/1")
  host_chars = "the host may hold only letters, digits, . and - (or an IPv6 address in brackets)"
  assert_equal host_chars, Cybertrain::SentryDsn.problem("https://a@b@h/1")
  assert_equal host_chars, Cybertrain::SentryDsn.problem("https://a@h_x/1")
  assert_equal host_chars, Cybertrain::SentryDsn.problem("https://a@[::1/1")
  assert_equal host_chars, Cybertrain::SentryDsn.problem("https://a@[::g]/1")
  assert_equal host_chars, Cybertrain::SentryDsn.problem("https://a@[::1]x/1")
  assert_equal "no host", Cybertrain::SentryDsn.problem("https://a@[]/1")
  assert_equal "no host", Cybertrain::SentryDsn.problem("https://a@:80/1")
  port = "the port must be a number from 1 to 65535"
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@h:/1")
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@h:0/1")
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@h:65536/1")
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@h:999999/1")
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@h:8x/1")
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@h:1:2/1")
  assert_equal port, Cybertrain::SentryDsn.problem("https://a@[::1]:/1")
  assert_equal "the path may hold only letters, digits, -, ., _, ~ and /", Cybertrain::SentryDsn.problem("https://a@h/a%2e/1")
  assert_equal "no project id", Cybertrain::SentryDsn.problem("https://a@h/1/")
  assert_equal "the project id must be digits", Cybertrain::SentryDsn.problem("https://a@h/1.5")
end

test "from_text raises ArgumentError with the problem" do
  assert_equal "no public key before the @",
               assert_raises("ArgumentError") { Cybertrain::SentryDsn.from_text("https://h/1") }
end

test "no problem names the key" do
  secret_key = "topsecretkey"
  texts = ["https://topsecretkey@/1", "https://topsecretkey@h/", "https://topsecretkey@h/x",
           "https://topsecretkey@h:0/1", "https://topsecretkey@h_x/1", "https://topsecretkey@h/1?q",
           "https://topsecretkey!@h/1", "https://topsecretkey:pw@h/a%/1", "ftp://topsecretkey@h/1",
           "https://topsecretkey@h/1 "]
  i = 0
  while i < texts.size
    why = Cybertrain::SentryDsn.problem(texts[i])
    refute why.empty?, texts[i]
    refute mentions?(why, secret_key), why
    i += 1
  end
end
Cybertrain::Test.run!
