require "test_helper"

# Mail in tests (spec section 10): stored in Mailer.deliveries, counted by
# assert_emails, and jobs run inline by perform_enqueued_jobs with a block.
class NewsMailerTest < ApplicationTest
  test "mail is stored, not sent" do
    assert_emails 1 do
      NewsMailer.published(write_article("Hello")).deliver_now
    end
    assert_equal "New: Hello", Cybertrain::Mailer.deliveries.last.mail_subject
  end

  test "deliveries start empty and deliver_later counts" do
    assert_emails 0
    assert_emails(1) { NewsMailer.published(write_article("Later")).deliver_later }
    assert_no_emails { write_article("Quiet") }
  end

  test "a job queued in the block runs, and the mail it queues" do
    entry = write_article("Inline")
    assert_equal 2, perform_enqueued_jobs { AnnounceJob.perform_later({ "article_id" => entry.id }) }
    assert_equal 1, Cybertrain::Mailer.deliveries.size
    assert_equal "readers@example.com", Cybertrain::Mailer.deliveries[0].mail_to
  end
end
