class ApplicationMailer < Cybertrain::Mailer::Base
  default from: "notifications@example.com"
  layout "mailer"

  private

  def footer_note
    @footer = "Sent by the fixture app"
  end
end
