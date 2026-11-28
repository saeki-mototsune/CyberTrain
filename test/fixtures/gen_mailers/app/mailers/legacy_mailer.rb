# A mailer module (the form `generate authentication` writes): not a class,
# so gen writes nothing for it.
module LegacyMailer
  def self.ping(to)
    Cybertrain::MailMessage.new(to: to, subject: "Ping", body: "ping\n")
  end
end
