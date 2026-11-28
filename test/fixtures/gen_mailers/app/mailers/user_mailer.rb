# The fixture's mailer class: positional and keyword parameters, params,
# attachments (one inline), a guard that skips the mail, a subject from
# the action's name, and a body without views. The views read Strings (a
# template reads a model's attributes, not a plain object's methods).
class UserMailer < ApplicationMailer
  def welcome(user, greeting = "Hello", copy: false)
    @name = user.name
    @greeting = greeting
    footer_note
    attachments["terms.pdf"] = "%PDF-1.4 terms"
    attachments.inline["logo.png"] = "\x89PNG\r\n".b
    @logo = attachments["logo.png"].url
    mail(to: copy ? "#{user.email_address}, copy@example.com" : user.email_address, subject: "#{greeting}, #{user.name}")
  end

  def reset
    @user = params[:user]
    @url = params[:url]
    return if @user.name == "skip"

    mail(to: @user.email_address)
  end

  def plain_note(to)
    mail(to: to, subject: "Note", from: "other@example.com", body: "Just text & <plain>\n")
  end

  def empty_note(to)
    mail(to: to, subject: "Empty", body: "")
  end

  # Its text view renders a partial that exists only as HTML.
  def html_partial_only(to)
    mail(to: to, subject: "Partial")
  end

  private def helper_not_an_action
    nil
  end
end
