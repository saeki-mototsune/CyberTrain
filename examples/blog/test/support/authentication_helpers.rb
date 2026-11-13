# Helpers for the authentication tests (cybertrain generate
# authentication): mail sent to an SMTP receiver in this process, the link
# a mail carries, and a Session row moved back in time. Required by the
# test files, not run.
require "cybertrain/test/smtp_receiver"
require_relative "app_test"

# Runs the block with the app's mail going to a receiver on 127.0.0.1
# (Config#smtp_*: plain text, from noreply@example.com, and
# mail_delivery_method :smtp, where the test environment would store the
# mail in Mailer.deliveries), then stops the receiver and puts the
# settings back, also when the block fails (an assertion raises). A mail
# sent with deliver_later goes out when the test runs the jobs
# (perform_enqueued_jobs).
def with_smtp_receiver
  receiver = Cybertrain::Test::SmtpReceiver.new
  port = receiver.start
  c = Cybertrain.config
  host = c.smtp_host
  given_port = c.smtp_port
  tls = c.smtp_tls
  from = c.smtp_from
  delivery = c.mail_delivery_method
  begin
    c.mail_delivery_method = :smtp
    c.smtp_host = "127.0.0.1"
    c.smtp_port = port
    c.smtp_tls = "none"
    c.smtp_from = "noreply@example.com"
    yield receiver
  ensure
    receiver.stop
    c.smtp_host = host
    c.smtp_port = given_port
    c.smtp_tls = tls
    c.smtp_from = from
    c.mail_delivery_method = delivery
  end
  nil
end

# The first http:// or https:// link in the text of the last mail the
# receiver got (waiting at most 5 seconds for it); "" when none came.
def last_mail_link(receiver)
  messages = receiver.received_messages
  return "" if messages.empty?

  text = messages.last.message_parts["text"].to_s
  start = text.index("https://")
  plain = text.index("http://")
  start = plain if start.nil? || (!plain.nil? && plain < start)
  return "" if start.nil?

  stop = start
  while stop < text.size && text[stop] != " " && text[stop] != "\r" && text[stop] != "\n"
    stop += 1
  end
  text[start, stop - start].to_s
end

# A Session row as if it had started, and last been used, `seconds`
# ago.
def backdate_session(row, seconds)
  at = Time.at(Time.current.to_i - seconds).utc
  row.update_columns(created_at: at, last_active_at: at)
  nil
end

# Runs the block with Config#env, hosts_from_env and the base_url
# setting given (and Cybertrain.logger writing errors to log, unless it
# is nil), then puts them back, also when the block fails.
def with_config(env, hosts, base_url, log = nil)
  c = Cybertrain.config
  saved_env = c.env
  saved_hosts = c.hosts_from_env
  saved_base_url = c.string_setting(:base_url)
  saved_logger = Cybertrain.logger
  begin
    c.env = env
    c.hosts_from_env = hosts
    c.set_string_setting(:base_url, base_url)
    Cybertrain.logger = Cybertrain::Logger.new(log, :error) unless log.nil?
    yield
  ensure
    c.env = saved_env
    c.hosts_from_env = saved_hosts
    c.set_string_setting(:base_url, saved_base_url)
    Cybertrain.logger = saved_logger
  end
  nil
end

# with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
NO_HOSTS = Array.new(0) { "" }
