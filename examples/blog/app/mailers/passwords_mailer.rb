# The password reset mail (cybertrain generate authentication): its HTML is
# app/views/mail/_password_reset.html.erb, its subject and text come from
# the dictionary (passwords_mailer.reset.subject, mail.password_reset.*),
# in the locale of the request that asked for it.
#
# Written by the generator; it is yours to change.
module PasswordsMailer
  # The mail to user with url, the link PasswordsController#create built (a
  # mailer has no request to take the site's address from). Its sender is
  # Config#smtp_from (CYBERTRAIN_SMTP_FROM).
  def self.reset(user, url)
    address = user.email_address.to_s
    html = Cybertrain::Views.render_mail("mail/password_reset", user: user, url: url)
    greeting = I18n.t("mail.password_reset.greeting", { email_address: address })
    text = +""
    text << greeting << "\n\n"
    text << I18n.t("mail.password_reset.intro") << "\n" << url << "\n\n"
    text << I18n.t("mail.password_reset.ignore") << "\n"
    subject = I18n.t("passwords_mailer.reset.subject")
    Cybertrain::MailMessage.new(to: address, subject: subject, body: text, html: html)
  end
end
