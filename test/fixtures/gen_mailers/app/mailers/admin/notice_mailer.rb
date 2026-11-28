module Admin
  class NoticeMailer < ApplicationMailer
    layout false

    def report(count)
      @count = count
      mail(to: "admin@example.com", subject: "Report")
    end
  end
end
