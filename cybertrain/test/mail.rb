# cybertrain/test/mail -- the mail assertions (spec section 10, plan
# decision D13): assert_emails and assert_no_emails count the messages
# Mailer.deliveries gained, which in the test environment is where every
# delivery goes (Config#mail_delivery_method :test). As in Rails, mail
# queued with deliver_later in the block is delivered (its "cybertrain
# mail" jobs are performed) before counting. cybertrain/test_help requires
# this file and empties Mailer.deliveries before every test.
require "cybertrain/test"
require "cybertrain/test/jobs"
require "cybertrain/db"
require "cybertrain/mail_message"

module Cybertrain
  module Test
    # Reads behind the mail assertions. Not API.
    module Mail
      # The largest job id before a block, or -1 with no database
      # connected (no deliver_later can have been queued then).
      # @return [Integer]
      def self.job_floor
        return -1 unless DB.connected?

        Jobs.max_id
      end

      # Performs the "cybertrain mail" jobs queued above `floor` (none when
      # it is -1); answers how many ran. A mail job that does not end
      # `done` (a refused address, no sender) fails the test, naming
      # `helper` and the error ({Jobs.perform_after}).
      # @return [Integer]
      def self.deliver_queued(floor, helper)
        return 0 if floor < 0

        Jobs.perform_after(floor, Mailer::JOB_KIND, helper)
      end
    end

    # `assert_emails`: Rails' count, in Minitest's capitalisation.
    # @return [nil]
    def self.check_emails(expected, got)
      count_assertion
      return nil if got == expected

      text = "Expected #{expected} emails, got #{got}"
      fail_with(text)
      nil
    end
  end
end

# Passes when the block delivered `count` mails: the messages
# Mailer.deliveries gained during it, after the mail queued in it with
# deliver_later was delivered (the "cybertrain mail" jobs queued in the
# block are performed first; jobs of other kinds stay queued). A mail job
# that fails (no sender, a refused address) fails the assertion with its
# error rather than counting short: `assert_emails: the job "cybertrain
# mail" (id 2) raised ArgumentError: the from address is empty (now
# discarded)`. Without a
# block, passes when Mailer.deliveries holds `count` messages (it is
# emptied before every test).
# @example
#   assert_emails 1 do
#     post "/passwords", params: { email: "ann@example.com" }
#   end
#   assert_equal "Reset your password", Cybertrain::Mailer.deliveries.last.mail_subject
# @param count [Integer]
# @yield the code that sends the mail
# @return [nil] not the block's value: one return type per method name
#   (spikes/NOTES.md rules 10, 34)
# @raise [Cybertrain::Test::AssertionFailed] "Expected 2 emails, got 1"
# @api public
def assert_emails(count)
  before = 0
  if block_given?
    before = Cybertrain::Mailer.deliveries.size
    floor = Cybertrain::Test::Mail.job_floor
    yield
    Cybertrain::Test::Mail.deliver_queued(floor, "assert_emails")
  end
  Cybertrain::Test.check_emails(count, Cybertrain::Mailer.deliveries.size - before)
end

# Passes when the block delivered no mail: `assert_emails(0) { }`, the
# deliver_later mail queued in it included. Without a block, passes when
# Mailer.deliveries is empty.
# @example
#   assert_no_emails { post "/passwords", params: { email: "nobody@example.com" } }
# @yield the code that must send no mail
# @return [nil]
# @raise [Cybertrain::Test::AssertionFailed] "Expected 0 emails, got 1"
# @api public
def assert_no_emails
  before = 0
  if block_given?
    before = Cybertrain::Mailer.deliveries.size
    floor = Cybertrain::Test::Mail.job_floor
    yield
    Cybertrain::Test::Mail.deliver_queued(floor, "assert_no_emails")
  end
  Cybertrain::Test.check_emails(0, Cybertrain::Mailer.deliveries.size - before)
end
