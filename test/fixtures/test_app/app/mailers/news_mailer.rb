# The mail test/mailers/news_mailer_test.rb checks (spec section 10): a
# mailer method answers a Cybertrain::MailMessage, sent with deliver_now
# or deliver_later.
module NewsMailer
  def self.published(article)
    Cybertrain::MailMessage.new(to: "readers@example.com", subject: "New: #{article.title}",
                                body: "#{article.title}\n", from: "news@example.com")
  end
end
