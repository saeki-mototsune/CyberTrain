# Cybertrain::MailMessage -- one mail, built now and sent later or at once:
# what a generated mailer method returns, so application code reads as in
# Rails:
#
#     PasswordsMailer.reset(user, url).deliver_later
#
# The class is in cybertrain/mailer/mail_message.rb (its fields and
# deliver_now, which cybertrain/mailer.rb needs for Mailer.deliveries) and
# cybertrain/mailer/later.rb (deliver_later, which needs the job queue);
# requiring this file loads both.
require "cybertrain/mailer"
require "cybertrain/mailer/later"
